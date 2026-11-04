//! The recipe's look and shaders, loaded into a pipeline from ~/.config/doka/. A .cube is about 1 MB of
//! text, too slow for the main loop, so the window parses them on a worker: `prepareSoon` leaves the old look in place until
//! the new one's ready, and `on_ready` says when. Export and screenshots wait (`prepare`).
const std = @import("std");
const Io = std.Io;
const core = @import("photo-core");
const Library = @import("library.zig");
const Pool = @import("jobs.zig");
const Pipeline = @import("pipeline.zig");
const Cube = @import("cube.zig");
const Recipe = core.Recipe;

const Looks = @This();

const log = std.log.scoped(.looks);

// Parsed looks kept: the one in use and the last few tried.
const kept = 4;

gpa: std.mem.Allocator,
library: *Library,
pool: ?*Pool = null,
on_ready: ?*const fn () void = null,
// The look in the pipeline now.
loaded: []u8 = "",
// Shaders that don't compile, with the compiler's message: tried once until the files change.
broken: std.StringHashMapUnmanaged([:0]u8) = .empty,
// `broken` changed: the panel showing it looks again.
broken_changed: bool = false,
cache: [kept]?Entry = @splat(null),
clock: u64 = 0,
loading: ?[]u8 = null,

const Entry = struct { name: []u8, cube: ?Cube, last_use: u64 };

pub const Found = union(enum) { loading, missing, ready: *const Cube };

fn cached(self: *Looks, name: []const u8) ?*Entry {
    for (&self.cache) |*slot| if (slot.*) |*e| if (std.mem.eql(u8, e.name, name)) {
        self.clock += 1;
        e.last_use = self.clock;
        return e;
    };
    return null;
}

fn store(self: *Looks, name: []u8, cube: ?Cube) void {
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
        self.gpa.free(e.name);
        if (e.cube) |*c| c.deinit(self.gpa);
    }
    self.clock += 1;
    self.cache[oldest] = .{ .name = name, .cube = cube, .last_use = self.clock };
}

/// A look's parsed cube; when it isn't here it's parsed on a worker, and `on_ready` says when.
pub fn find(self: *Looks, name: []const u8) Found {
    if (self.cached(name)) |e| return if (e.cube) |*c| .{ .ready = c } else .missing;
    if (self.loading != null) return .loading;
    const task = self.gpa.create(Parse) catch return .missing;
    const owned = self.gpa.dupe(u8, name) catch return .missing;
    task.* = .{ .looks = self, .name = owned };
    self.loading = owned;
    self.pool.?.submit(&task.task, .urgent);
    return .loading;
}

/// The looks folder changed: what's parsed may be stale.
pub fn clear(self: *Looks) void {
    for (&self.cache) |*slot| if (slot.*) |*e| {
        self.gpa.free(e.name);
        if (e.cube) |*c| c.deinit(self.gpa);
        slot.* = null;
    };
    var it = self.broken.iterator();
    while (it.next()) |e| {
        self.gpa.free(e.key_ptr.*);
        self.gpa.free(e.value_ptr.*);
    }
    self.broken.clearRetainingCapacity();
    self.forget();
}

/// Why this shader isn't running, if it doesn't compile.
pub fn shaderError(self: *const Looks, name: []const u8) ?[:0]const u8 {
    return self.broken.get(name);
}

const Parse = struct {
    task: Pool.Task = .{ .run = run, .done = done },
    looks: *Looks,
    name: []u8,
    cube: ?Cube = null,

    fn run(task: *Pool.Task) void {
        const t: *Parse = @fieldParentPtr("task", task);
        t.cube = t.looks.read(t.name) catch |err| blk: {
            log.warn("look {s}: {t}", .{ t.name, err });
            break :blk null;
        };
    }

    fn done(task: *Pool.Task) void {
        const t: *Parse = @fieldParentPtr("task", task);
        const self = t.looks;
        defer self.gpa.destroy(t);
        self.loading = null;
        self.store(t.name, t.cube);
        if (self.on_ready) |f| f();
    }
};

fn read(self: *Looks, name: []const u8) !Cube {
    if (!Library.validName(name)) return error.BadName;
    const path = try std.fs.path.join(self.gpa, &.{ self.library.looks_dir, name });
    defer self.gpa.free(path);
    const text = try Io.Dir.cwd().readFileAlloc(self.library.io, path, self.gpa, .limited(Library.max_cube));
    defer self.gpa.free(text);
    return Cube.parse(self.gpa, text);
}

/// Brings the pipeline in line with the recipe, waiting for the look. Something missing or broken is
/// left out, and said.
pub fn prepare(self: *Looks, p: *Pipeline, r: Recipe) void {
    if (!std.mem.eql(u8, r.look.name, self.loaded)) {
        if (std.mem.eql(u8, r.look.name, Recipe.no_look)) {
            p.setLook(null);
        } else if (self.cached(r.look.name)) |e| {
            p.setLook(if (e.cube) |*c| c else null);
        } else if (self.read(r.look.name)) |cube| {
            var owned = cube;
            p.setLook(&owned);
            if (self.gpa.dupe(u8, r.look.name)) |name| self.store(name, owned) else |_| owned.deinit(self.gpa);
        } else |err| {
            log.warn("look {s}: {t}", .{ r.look.name, err });
            p.setLook(null);
        }
        self.setLoaded(r.look.name);
    }
    self.prepareShaders(p, r);
}

/// The same without waiting: the old look stays until the new one's parsed.
pub fn prepareSoon(self: *Looks, p: *Pipeline, r: Recipe) void {
    if (!std.mem.eql(u8, r.look.name, self.loaded)) {
        if (std.mem.eql(u8, r.look.name, Recipe.no_look)) {
            p.setLook(null);
            self.setLoaded(r.look.name);
        } else switch (self.find(r.look.name)) {
            .loading => {},
            .missing => {
                p.setLook(null);
                self.setLoaded(r.look.name);
            },
            .ready => |c| {
                p.setLook(c);
                self.setLoaded(r.look.name);
            },
        }
    }
    self.prepareShaders(p, r);
}

fn prepareShaders(self: *Looks, p: *Pipeline, r: Recipe) void {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    for (r.shaders) |use| {
        if (p.hasShader(use.name) or self.broken.contains(use.name)) continue;
        self.loadShader(p, scratch.allocator(), use.name) catch |err| {
            log.warn("shader {s}: {t} {s}", .{ use.name, err, Pipeline.last_error });
            // A missing one says so in its row already, and may yet arrive.
            if (err != error.ShaderCompile and err != error.ShaderLink) continue;
            self.remember(use.name, Pipeline.last_error) catch {};
        };
    }
}

fn remember(self: *Looks, name: []const u8, message: []const u8) !void {
    const key = try self.gpa.dupe(u8, name);
    errdefer self.gpa.free(key);
    const value = try self.gpa.dupeZ(u8, message);
    errdefer self.gpa.free(value);
    try self.broken.put(self.gpa, key, value);
    self.broken_changed = true;
}

/// What's in the pipeline may be stale: the next `prepare` loads it again.
pub fn forget(self: *Looks) void {
    self.setLoaded("?");
}

fn setLoaded(self: *Looks, name: []const u8) void {
    if (self.loaded.len > 0) self.gpa.free(self.loaded);
    self.loaded = self.gpa.dupe(u8, name) catch "";
}

fn loadShader(self: *Looks, p: *Pipeline, a: std.mem.Allocator, name: []const u8) !void {
    const shader = try self.library.readShader(a, name);
    const params = try a.alloc(Pipeline.Param, shader.json.params.len);
    for (shader.json.params, params) |from, *to| to.* = .{ .name = from.name, .default = @floatCast(from.default) };
    try p.setShader(name, try p.compileShader(params, shader.source));
}
