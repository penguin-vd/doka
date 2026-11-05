//! Photos and thumbnails, decoded off the main loop. The photo on screen and its neighbours stay
//! decoded, so switching is instant; thumbnails are cached in <root>/.photo-editor/thumbs/ and, the
//! ones lately in view, in memory.
const std = @import("std");
const Io = std.Io;
const core = @import("photo-core");
const Pool = @import("jobs.zig");
const memory = @import("memory.zig");
const gtk = @import("gtk.zig");

const Photos = @This();

const log = std.log.scoped(.photos);

pub const thumb_size = 320;
// Four: the photo, both neighbours, and the one being left.
const cache_size = 4;
// Thumbnails kept as textures: a few screens' worth.
const textures_kept = 240;

gpa: std.mem.Allocator,
io: Io,
pool: *Pool,
root: ?[:0]const u8 = null,
// Bumped with each folder: a late task from the old one is dropped.
generation: u32 = 0,
cache: [cache_size]?Entry = @splat(null),
use_clock: u64 = 0,
in_flight: std.ArrayList(*Decode) = .empty,
textures: std.StringHashMapUnmanaged(Texture) = .empty,
asked: std.StringHashMapUnmanaged(void) = .empty,
on_decoded: *const fn (rel: []const u8, edge: u32, ok: bool) void,
on_thumb: *const fn (rel: []const u8, texture: *anyopaque) void,

const Entry = struct { rel: []u8, edge: u32, linear: core.decode.Linear, last_use: u64 };
const Texture = struct { texture: *anyopaque, last_use: u64 };

pub fn setRoot(self: *Photos, root: []const u8) !void {
    self.clear();
    if (self.root) |r| self.gpa.free(r);
    self.root = try self.gpa.dupeZ(u8, root);
    self.generation +%= 1;
}

fn clear(self: *Photos) void {
    for (&self.cache) |*slot| if (slot.*) |*e| {
        self.gpa.free(e.rel);
        e.linear.deinit(self.gpa);
        slot.* = null;
    };
    var it = self.textures.iterator();
    while (it.next()) |e| {
        gtk.g_object_unref(e.value_ptr.texture);
        self.gpa.free(e.key_ptr.*);
    }
    self.textures.clearRetainingCapacity();
    var asked = self.asked.keyIterator();
    while (asked.next()) |k| self.gpa.free(k.*);
    self.asked.clearRetainingCapacity();
}

/// The decoded photo, if it's here. Good until the next decode finishes.
pub fn lookup(self: *Photos, rel: []const u8, edge: u32) ?*Entry {
    for (&self.cache) |*slot| if (slot.*) |*e| {
        if (e.edge == edge and std.mem.eql(u8, e.rel, rel)) {
            self.use_clock += 1;
            e.last_use = self.use_clock;
            return e;
        }
    };
    return null;
}

/// Decodes a photo; `on_decoded` says when it's ready (at once if it's already here).
pub fn request(self: *Photos, rel: []const u8, edge: u32, priority: Pool.Priority) void {
    if (self.root == null) return;
    if (self.lookup(rel, edge) != null) return self.on_decoded(rel, edge, true);
    for (self.in_flight.items) |d| if (d.edge == edge and std.mem.eql(u8, d.rel, rel)) {
        if (priority == .urgent) {
            self.pool.promote(&d.task);
            d.wanted = true;
        }
        return;
    };
    self.decode(rel, edge, priority) catch |err| {
        log.err("decode {s}: {t}", .{ rel, err });
        self.on_decoded(rel, edge, false);
    };
}

fn decode(self: *Photos, rel: []const u8, edge: u32, priority: Pool.Priority) !void {
    const d = try self.gpa.create(Decode);
    errdefer self.gpa.destroy(d);
    d.* = .{
        .photos = self,
        .generation = self.generation,
        .rel = try self.gpa.dupe(u8, rel),
        .path = try std.fmt.allocPrintSentinel(self.gpa, "{s}/{s}", .{ self.root.?, rel }, 0),
        .edge = edge,
        .wanted = priority == .urgent,
    };
    try self.in_flight.append(self.gpa, d);
    self.pool.submit(&d.task, priority);
}

const Decode = struct {
    task: Pool.Task = .{ .run = run, .done = done },
    photos: *Photos,
    generation: u32,
    rel: []u8,
    path: [:0]u8,
    edge: u32,
    // Someone's waiting, as opposed to decoded ahead.
    wanted: bool,
    result: ?core.decode.Linear = null,

    fn run(task: *Pool.Task) void {
        const d: *Decode = @fieldParentPtr("task", task);
        d.result = core.decode.linear(d.photos.gpa, d.path, d.edge) catch |err| blk: {
            log.err("decode {s}: {t}", .{ d.rel, err });
            break :blk null;
        };
    }

    fn done(task: *Pool.Task) void {
        const d: *Decode = @fieldParentPtr("task", task);
        const self = d.photos;
        for (self.in_flight.items, 0..) |x, i| if (x == d) {
            _ = self.in_flight.swapRemove(i);
            break;
        };
        self.gpa.free(d.path);
        defer self.gpa.destroy(d);
        // A decode's float buffers (tens of MB) go back to the system, not to glibc's arenas.
        defer memory.trim();
        if (d.generation != self.generation) {
            if (d.result) |*lin| lin.deinit(self.gpa);
            self.gpa.free(d.rel);
            return;
        }
        const ok = d.result != null;
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const name = name_buf[0..d.rel.len];
        @memcpy(name, d.rel);
        const edge = d.edge;
        const wanted = d.wanted;
        if (d.result) |lin| self.store(d.rel, edge, lin) else self.gpa.free(d.rel);
        if (wanted or ok) self.on_decoded(name, edge, ok);
    }
};

// Takes ownership of `rel` and `linear`.
fn store(self: *Photos, rel: []u8, edge: u32, linear: core.decode.Linear) void {
    var oldest: usize = 0;
    var oldest_use: u64 = std.math.maxInt(u64);
    for (self.cache, 0..) |slot, i| {
        const use = if (slot) |e| e.last_use else 0;
        if (use < oldest_use) {
            oldest = i;
            oldest_use = use;
        }
    }
    if (self.cache[oldest]) |*e| {
        self.gpa.free(e.rel);
        e.linear.deinit(self.gpa);
    }
    self.use_clock += 1;
    self.cache[oldest] = .{ .rel = rel, .edge = edge, .linear = linear, .last_use = self.use_clock };
}

/// The thumbnail if it's in memory; otherwise it's made or read, and `on_thumb` brings it.
pub fn thumb(self: *Photos, rel: []const u8) ?*anyopaque {
    if (self.textures.getPtr(rel)) |t| {
        self.use_clock += 1;
        t.last_use = self.use_clock;
        return t.texture;
    }
    if (self.asked.contains(rel) or self.root == null) return null;
    self.startThumb(rel) catch |err| log.err("thumbnail {s}: {t}", .{ rel, err });
    return null;
}

fn startThumb(self: *Photos, rel: []const u8) !void {
    const key = try self.gpa.dupe(u8, rel);
    errdefer self.gpa.free(key);
    try self.asked.put(self.gpa, key, {});
    const t = try self.gpa.create(Thumb);
    t.* = .{ .photos = self, .generation = self.generation, .root = try self.gpa.dupe(u8, self.root.?), .rel = try self.gpa.dupe(u8, rel) };
    self.pool.submit(&t.task, .background);
}

const Thumb = struct {
    task: Pool.Task = .{ .run = run, .done = done },
    photos: *Photos,
    generation: u32,
    root: []u8,
    rel: []u8,
    texture: ?*anyopaque = null,

    fn run(task: *Pool.Task) void {
        const t: *Thumb = @fieldParentPtr("task", task);
        t.texture = t.make() catch |err| blk: {
            log.err("thumbnail {s}: {t}", .{ t.rel, err });
            break :blk null;
        };
    }

    // GTK's own JPEG reader, here on a worker: it's safe off the main loop.
    fn make(t: *Thumb) !*anyopaque {
        const self = t.photos;
        const gpa = self.gpa;
        const io = self.io;
        var root = try Io.Dir.cwd().openDir(io, t.root, .{});
        defer root.close(io);
        const cached = try core.store.thumbPath(gpa, t.rel);
        defer gpa.free(cached);
        const bytes = blk: {
            if (root.readFileAlloc(io, cached, gpa, .limited(1 << 20))) |file| {
                defer gpa.free(file);
                break :blk gtk.g_bytes_new(file.ptr, file.len);
            } else |_| {}
            const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ t.root, t.rel }, 0);
            defer gpa.free(path);
            const jpeg = try core.decode.thumbnail(path, thumb_size);
            core.store.writeAtomic(io, gpa, root, cached, jpeg) catch |err| log.warn("thumbnail cache {s}: {t}", .{ t.rel, err });
            // libvips' buffer is g_malloc'd.
            break :blk gtk.g_bytes_new_take(jpeg.ptr, jpeg.len);
        };
        defer gtk.g_bytes_unref(bytes);
        var err: ?*gtk.GError = null;
        return gtk.gdk_texture_new_from_bytes(bytes, &err) orelse {
            log.err("thumbnail {s}: {s}", .{ t.rel, err.?.message });
            return error.BadThumbnail;
        };
    }

    fn done(task: *Pool.Task) void {
        const t: *Thumb = @fieldParentPtr("task", task);
        const self = t.photos;
        defer {
            self.gpa.free(t.root);
            self.gpa.free(t.rel);
            self.gpa.destroy(t);
            memory.trim();
        }
        if (t.generation != self.generation) {
            if (t.texture) |x| gtk.g_object_unref(x);
            return;
        }
        if (self.asked.fetchRemove(t.rel)) |k| self.gpa.free(k.key);
        const texture = t.texture orelse return;
        self.keep(t.rel, texture) catch {
            gtk.g_object_unref(texture);
            return;
        };
        self.on_thumb(t.rel, texture);
    }
};

fn keep(self: *Photos, rel: []const u8, texture: *anyopaque) !void {
    if (self.textures.count() >= textures_kept) {
        var oldest: ?[]const u8 = null;
        var oldest_use: u64 = std.math.maxInt(u64);
        var it = self.textures.iterator();
        while (it.next()) |e| if (e.value_ptr.last_use < oldest_use) {
            oldest_use = e.value_ptr.last_use;
            oldest = e.key_ptr.*;
        };
        if (self.textures.fetchRemove(oldest.?)) |gone| {
            gtk.g_object_unref(gone.value.texture);
            self.gpa.free(gone.key);
        }
    }
    self.use_clock += 1;
    try self.textures.put(self.gpa, try self.gpa.dupe(u8, rel), .{ .texture = texture, .last_use = self.use_clock });
}
