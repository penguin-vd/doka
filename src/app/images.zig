//! Photos and thumbnails for the page, decoded off the main loop.
//!   app://ui/photo/<rel>?edge=2048  linear half floats (decode.linear), for the GPU pipeline
//!   app://ui/thumb/<rel>            a small JPEG, cached in <root>/.photo-editor/thumbs/
//! The photo on screen and its neighbours stay decoded, so switching is instant.
const std = @import("std");
const Io = std.Io;
const core = @import("photo-core");
const Window = @import("window.zig");
const Pool = @import("jobs.zig");
const c = @import("c.zig");

const Images = @This();

const log = std.log.scoped(.images);

pub const thumb_size = 320;
// Four: the photo, both neighbours, and the one being left.
pub const cache_size = 4;
// photo/ responses start with width, height, full width, full height: u32 little-endian.
pub const header_len = 16;

gpa: std.mem.Allocator,
io: Io,
pool: *Pool,
// The open folder; tasks keep their own copy.
root: ?[:0]const u8 = null,
// Bumped on every folder change, so a late task from the old folder is dropped.
generation: u32 = 0,
cache: [cache_size]?Entry = @splat(null),
use_clock: u64 = 0,
in_flight: std.ArrayList(*Decode) = .empty,

const Entry = struct {
    rel: []u8,
    edge: u32,
    linear: core.decode.Linear,
    last_use: u64,
};

pub fn deinit(self: *Images) void {
    self.clear();
    self.in_flight.deinit(self.gpa);
    if (self.root) |r| self.gpa.free(r);
}

pub fn setRoot(self: *Images, root: []const u8) !void {
    self.clear();
    if (self.root) |r| self.gpa.free(r);
    self.root = try self.gpa.dupeZ(u8, root);
    self.generation +%= 1;
}

fn clear(self: *Images) void {
    for (&self.cache) |*slot| if (slot.*) |*e| {
        self.gpa.free(e.rel);
        e.linear.deinit(self.gpa);
        slot.* = null;
    };
}

/// Serves `photo/…` and `thumb/…`; false when the path is neither.
pub fn handle(self: *Images, request: *Window.Request, path: []const u8) bool {
    const kind: enum { photo, thumb } = if (std.mem.startsWith(u8, path, "photo/")) .photo else if (std.mem.startsWith(u8, path, "thumb/")) .thumb else return false;
    const encoded = path[std.mem.indexOfScalar(u8, path, '/').? + 1 ..];
    const rel = @import("ui.zig").percentDecode(self.gpa, encoded) catch null orelse {
        Window.fail(request, 400, "bad path");
        return true;
    };
    defer self.gpa.free(rel);
    core.store.checkRelative(rel) catch {
        Window.fail(request, 400, "bad path");
        return true;
    };
    if (self.root == null) {
        Window.fail(request, 404, "no folder open");
        return true;
    }
    switch (kind) {
        .photo => {
            const edge = std.fmt.parseInt(u32, Window.query(request, "edge") orelse "0", 10) catch 0;
            self.photo(request, rel, edge) catch Window.fail(request, 500, "decode failed");
        },
        .thumb => self.thumb(request, rel) catch Window.fail(request, 500, "thumbnail failed"),
    }
    return true;
}

fn photo(self: *Images, request: *Window.Request, rel: []const u8, edge: u32) !void {
    if (self.lookup(rel, edge)) |e| return respondLinear(request, &e.linear);
    const d = try self.decode(rel, edge, .urgent);
    Window.hold(request);
    try d.waiting.append(self.gpa, request);
}

/// Decodes a photo before the page asks for it.
pub fn prefetch(self: *Images, rel: []const u8, edge: u32, priority: Pool.Priority) void {
    if (self.root == null or self.lookup(rel, edge) != null) return;
    _ = self.decode(rel, edge, priority) catch |err| log.warn("prefetch {s}: {t}", .{ rel, err });
}

/// The decoded photo when it's cached, for export.
pub fn lookup(self: *Images, rel: []const u8, edge: u32) ?*Entry {
    for (&self.cache) |*slot| if (slot.*) |*e| {
        if (e.edge == edge and std.mem.eql(u8, e.rel, rel)) {
            self.use_clock += 1;
            e.last_use = self.use_clock;
            return e;
        }
    };
    return null;
}

fn decode(self: *Images, rel: []const u8, edge: u32, priority: Pool.Priority) !*Decode {
    for (self.in_flight.items) |d| if (d.edge == edge and std.mem.eql(u8, d.rel, rel)) return d;
    const d = try self.gpa.create(Decode);
    errdefer self.gpa.destroy(d);
    d.* = .{
        .images = self,
        .generation = self.generation,
        .rel = try self.gpa.dupe(u8, rel),
        .path = try std.fmt.allocPrintSentinel(self.gpa, "{s}/{s}", .{ self.root.?, rel }, 0),
        .edge = edge,
    };
    try self.in_flight.append(self.gpa, d);
    self.pool.submit(&d.task, priority);
    return d;
}

const Decode = struct {
    task: Pool.Task = .{ .run = run, .done = done },
    images: *Images,
    generation: u32,
    rel: []u8,
    path: [:0]u8,
    edge: u32,
    result: ?core.decode.Linear = null,
    waiting: std.ArrayList(*Window.Request) = .empty,

    fn run(task: *Pool.Task) void {
        const d: *Decode = @fieldParentPtr("task", task);
        d.result = core.decode.linear(d.images.gpa, d.path, d.edge) catch |err| blk: {
            log.err("decode {s}: {t}", .{ d.rel, err });
            break :blk null;
        };
    }

    fn done(task: *Pool.Task) void {
        const d: *Decode = @fieldParentPtr("task", task);
        const self = d.images;
        for (self.in_flight.items, 0..) |x, i| if (x == d) {
            _ = self.in_flight.swapRemove(i);
            break;
        };
        for (d.waiting.items) |request| {
            if (d.result) |*lin| respondLinear(request, lin) else Window.fail(request, 500, "decode failed");
            Window.release(request);
        }
        d.waiting.deinit(self.gpa);
        self.gpa.free(d.path);
        if (d.result != null and d.generation == self.generation) {
            self.store(d.rel, d.edge, d.result.?);
        } else {
            if (d.result) |*lin| lin.deinit(self.gpa);
            self.gpa.free(d.rel);
        }
        self.gpa.destroy(d);
        // A decode's float buffers (tens of MB) go back to the system, not to glibc's per-thread arenas.
        _ = malloc_trim(0);
    }
};

pub extern fn malloc_trim(pad: usize) c_int;

// Takes ownership of `rel` and `linear`.
fn store(self: *Images, rel: []u8, edge: u32, linear: core.decode.Linear) void {
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

fn respondLinear(request: *Window.Request, lin: *const core.decode.Linear) void {
    const pixels = std.mem.sliceAsBytes(lin.rgb);
    const buf = c.malloc(header_len + pixels.len) orelse return Window.fail(request, 500, "out of memory");
    for ([_]u32{ lin.width, lin.height, lin.full_width, lin.full_height }, 0..) |v, i| std.mem.writeInt(u32, buf[i * 4 ..][0..4], v, .little);
    @memcpy(buf[header_len..][0..pixels.len], pixels);
    Window.respondOwned(request, buf[0 .. header_len + pixels.len], "application/octet-stream");
}

fn thumb(self: *Images, request: *Window.Request, rel: []const u8) !void {
    const t = try self.gpa.create(Thumb);
    errdefer self.gpa.destroy(t);
    t.* = .{
        .images = self,
        .request = request,
        .io = self.io,
        .root = try self.gpa.dupe(u8, self.root.?),
        .rel = try self.gpa.dupe(u8, rel),
    };
    Window.hold(request);
    self.pool.submit(&t.task, .background);
}

const Thumb = struct {
    task: Pool.Task = .{ .run = run, .done = done },
    images: *Images,
    request: *Window.Request,
    io: Io,
    root: []u8,
    rel: []u8,
    jpeg: ?[]u8 = null,

    fn run(task: *Pool.Task) void {
        const t: *Thumb = @fieldParentPtr("task", task);
        t.jpeg = t.make() catch |err| blk: {
            log.err("thumbnail {s}: {t}", .{ t.rel, err });
            break :blk null;
        };
    }

    // The cached one, or a new one written to the cache. The bytes are from `c.malloc`.
    fn make(t: *Thumb) ![]u8 {
        const gpa = t.images.gpa;
        var root = try Io.Dir.cwd().openDir(t.io, t.root, .{});
        defer root.close(t.io);
        const cached = try core.store.thumbPath(gpa, t.rel);
        defer gpa.free(cached);
        if (root.readFileAlloc(t.io, cached, gpa, .limited(1 << 20))) |bytes| {
            defer gpa.free(bytes);
            const out = c.malloc(bytes.len) orelse return error.OutOfMemory;
            @memcpy(out[0..bytes.len], bytes);
            return out[0..bytes.len];
        } else |_| {}
        const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ t.root, t.rel }, 0);
        defer gpa.free(path);
        const jpeg = try core.decode.thumbnail(path, thumb_size);
        core.store.writeAtomic(t.io, gpa, root, cached, jpeg) catch |err| log.warn("thumbnail cache {s}: {t}", .{ t.rel, err });
        // libvips' buffer is g_malloc'd; GLib's allocator is malloc.
        return jpeg;
    }

    fn done(task: *Pool.Task) void {
        const t: *Thumb = @fieldParentPtr("task", task);
        const gpa = t.images.gpa;
        if (t.jpeg) |j| Window.respondOwned(t.request, j, "image/jpeg") else Window.fail(t.request, 500, "thumbnail failed");
        Window.release(t.request);
        gpa.free(t.root);
        gpa.free(t.rel);
        gpa.destroy(t);
        _ = malloc_trim(0);
    }
};
