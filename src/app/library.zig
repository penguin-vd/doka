//! Looks and shaders on disk (SPEC.md, Looks and shaders):
//!   ~/.config/doka/looks/<name>.cube            a LUT; drop one in and it's there
//!   ~/.config/doka/shaders/<name>/shader.glsl   `vec3 effect(vec3 c)` (ui/glsl/effect.glsl)
//!   ~/.config/doka/shaders/<name>/shader.json   {"description", "params": [{name, label, default, min, max}], "needs": []}
//! Both folders are watched: a file added or edited by hand reaches the page at once. A shader's
//! last five versions are kept in its .versions/ when Claude replaces it.
const std = @import("std");
const Io = std.Io;
const c = @import("c.zig");
const Window = @import("window.zig");

const Library = @This();

const log = std.log.scoped(.library);

pub const versions_kept = 5;
pub const max_cube = 64 << 20;
pub const max_shader = 256 << 10;
// Edits arrive as several file events; the page hears once they've settled.
const settle_ms = 250;

gpa: std.mem.Allocator,
io: Io,
looks_dir: [:0]const u8,
shaders_dir: [:0]const u8,
monitors: std.ArrayList(*c.GFileMonitor) = .empty,
settle_timer: c_uint = 0,
// Called on the main loop when something on disk changed.
on_change: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque) void } = null,

pub fn init(gpa: std.mem.Allocator, io: Io, config_dir: []const u8) !Library {
    const looks = try std.fs.path.joinZ(gpa, &.{ config_dir, "looks" });
    const shaders = try std.fs.path.joinZ(gpa, &.{ config_dir, "shaders" });
    Io.Dir.cwd().createDirPath(io, looks) catch |err| log.warn("can't create {s}: {t}", .{ looks, err });
    Io.Dir.cwd().createDirPath(io, shaders) catch |err| log.warn("can't create {s}: {t}", .{ shaders, err });
    var lib: Library = .{ .gpa = gpa, .io = io, .looks_dir = looks, .shaders_dir = shaders };
    lib.seedStarters();
    return lib;
}

/// The shaders the app comes with (src/app/starter/).
pub const starters = [_]struct { name: []const u8, glsl: []const u8, json: []const u8 }{
    .{ .name = "split-tone", .glsl = @embedFile("starter/split-tone.glsl"), .json = @embedFile("starter/split-tone.json") },
    .{ .name = "bloom", .glsl = @embedFile("starter/bloom.glsl"), .json = @embedFile("starter/bloom.json") },
    .{ .name = "light-leak", .glsl = @embedFile("starter/light-leak.glsl"), .json = @embedFile("starter/light-leak.json") },
    .{ .name = "clarity", .glsl = @embedFile("starter/clarity.glsl"), .json = @embedFile("starter/clarity.json") },
    .{ .name = "dehaze", .glsl = @embedFile("starter/dehaze.glsl"), .json = @embedFile("starter/dehaze.json") },
};

// Which starters the folder has had, so one deleted stays deleted.
const seeded_file = ".starters";

// Each starter goes into the shaders folder once.
fn seedStarters(lib: *Library) void {
    var scratch: std.heap.ArenaAllocator = .init(lib.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var dir = Io.Dir.cwd().openDir(lib.io, lib.shaders_dir, .{}) catch return;
    defer dir.close(lib.io);
    const had = dir.readFileAlloc(lib.io, seeded_file, a, .limited(4096)) catch "";
    var list: std.ArrayList(u8) = .empty;
    list.appendSlice(a, had) catch return;
    for (starters) |st| {
        var lines = std.mem.tokenizeScalar(u8, had, '\n');
        const seen = while (lines.next()) |l| {
            if (std.mem.eql(u8, l, st.name)) break true;
        } else false;
        if (seen) continue;
        if (dir.access(lib.io, st.name, .{})) |_| {} else |_| {
            lib.saveShader(a, st.name, st.glsl, st.json, 0) catch |err| log.warn("starter shader {s}: {t}", .{ st.name, err });
        }
        list.print(a, "{s}\n", .{st.name}) catch return;
    }
    dir.writeFile(lib.io, .{ .sub_path = seeded_file, .data = list.items }) catch {};
}

pub fn deinit(lib: *Library) void {
    lib.unwatch();
    lib.monitors.deinit(lib.gpa);
    lib.gpa.free(lib.looks_dir);
    lib.gpa.free(lib.shaders_dir);
}

/// A name that is one plain file or folder name: no paths, nothing hidden.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '.') return false;
    for (name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == ' ')) return false;
    return std.mem.indexOf(u8, name, "..") == null;
}

pub const Param = struct {
    name: []const u8,
    label: []const u8 = "",
    default: f64 = 0,
    min: f64 = 0,
    max: f64 = 1,
};

pub const ShaderJson = struct {
    description: []const u8 = "",
    params: []const Param = &.{},
    needs: []const []const u8 = &.{},
};

/// Writes `{"looks": [...], "shaders": [...]}`: every look's name and title, every shader with its
/// settings and source. Strings are read into `a`.
pub fn write(lib: *Library, a: std.mem.Allocator, s: *std.json.Stringify) !void {
    try s.beginObject();
    try s.objectField("looks");
    try s.beginArray();
    for (try lib.lookNames(a)) |name| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(name);
        try s.objectField("title");
        try s.write(lib.lookTitle(a, name));
        try s.objectField("version");
        try s.write(lib.stamp(a, lib.looks_dir, name));
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("shaders");
    try s.beginArray();
    for (try lib.shaderNames(a)) |name| {
        const shader = lib.readShader(a, name) catch |err| {
            log.warn("shader {s}: {t}", .{ name, err });
            continue;
        };
        try s.beginObject();
        try s.objectField("name");
        try s.write(name);
        try s.objectField("description");
        try s.write(shader.json.description);
        try s.objectField("params");
        try s.write(shader.json.params);
        try s.objectField("needs");
        try s.write(shader.json.needs);
        try s.objectField("source");
        try s.write(shader.source);
        try s.objectField("version");
        try s.write(lib.stamp(a, lib.shaders_dir, try std.fs.path.join(a, &.{ name, "shader.glsl" })) + lib.stamp(a, lib.shaders_dir, try std.fs.path.join(a, &.{ name, "shader.json" })));
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

// The file's modification time: the page reloads what changed.
fn stamp(lib: *Library, a: std.mem.Allocator, dir: []const u8, name: []const u8) i64 {
    const path = std.fs.path.join(a, &.{ dir, name }) catch return 0;
    const st = Io.Dir.cwd().statFile(lib.io, path, .{}) catch return 0;
    return @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_ms));
}

fn sorted(names: *std.ArrayList([]const u8)) void {
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(x, y);
        }
    }.lessThan);
}

pub fn lookNames(lib: *Library, a: std.mem.Allocator) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(lib.io, lib.looks_dir, .{ .iterate = true }) catch return names.items;
    defer dir.close(lib.io);
    var it = dir.iterate();
    while (try it.next(lib.io)) |e| {
        if (e.kind != .file or !std.ascii.endsWithIgnoreCase(e.name, ".cube") or !validName(e.name)) continue;
        try names.append(a, try a.dupe(u8, e.name));
    }
    sorted(&names);
    return names.items;
}

// The .cube's TITLE, or its name without the extension.
fn lookTitle(lib: *Library, a: std.mem.Allocator, name: []const u8) []const u8 {
    const fallback = name[0 .. name.len - ".cube".len];
    const path = std.fs.path.join(a, &.{ lib.looks_dir, name }) catch return fallback;
    var file = Io.Dir.cwd().openFile(lib.io, path, .{}) catch return fallback;
    defer file.close(lib.io);
    var buf: [1024]u8 = undefined;
    const n = file.readPositionalAll(lib.io, &buf, 0) catch return fallback;
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "TITLE")) {
            const t = std.mem.trim(u8, line["TITLE".len..], " \t\"");
            if (t.len > 0) return a.dupe(u8, t) catch fallback;
        }
    }
    return fallback;
}

pub fn shaderNames(lib: *Library, a: std.mem.Allocator) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(lib.io, lib.shaders_dir, .{ .iterate = true }) catch return names.items;
    defer dir.close(lib.io);
    var it = dir.iterate();
    while (try it.next(lib.io)) |e| {
        if (e.kind != .directory or !validName(e.name)) continue;
        try names.append(a, try a.dupe(u8, e.name));
    }
    sorted(&names);
    return names.items;
}

pub const Shader = struct { source: []const u8, json_text: []const u8, json: ShaderJson };

pub fn readShader(lib: *Library, a: std.mem.Allocator, name: []const u8) !Shader {
    if (!validName(name)) return error.BadName;
    var dir = try lib.shaderDir(name);
    defer dir.close(lib.io);
    const source = try dir.readFileAlloc(lib.io, "shader.glsl", a, .limited(max_shader));
    const json_text = dir.readFileAlloc(lib.io, "shader.json", a, .limited(max_shader)) catch |err| switch (err) {
        error.FileNotFound => "{}",
        else => return err,
    };
    const json = try std.json.parseFromSliceLeaky(ShaderJson, a, json_text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    for (json.params) |p| if (!validParam(p.name)) return error.BadParamName;
    return .{ .source = source, .json_text = json_text, .json = json };
}

/// A parameter becomes `uniform float u_<name>`: it must be a GLSL name.
pub fn validParam(name: []const u8) bool {
    if (name.len == 0 or name.len > 32 or !std.ascii.isAlphabetic(name[0])) return false;
    for (name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}

fn shaderDir(lib: *Library, name: []const u8) !Io.Dir {
    var root = try Io.Dir.cwd().openDir(lib.io, lib.shaders_dir, .{});
    defer root.close(lib.io);
    return root.openDir(lib.io, name, .{});
}

/// Writes a shader, the old one kept in .versions/ (the newest five).
pub fn saveShader(lib: *Library, a: std.mem.Allocator, name: []const u8, source: []const u8, json_text: []const u8, now_s: u64) !void {
    if (!validName(name)) return error.BadName;
    var root = try Io.Dir.cwd().openDir(lib.io, lib.shaders_dir, .{});
    defer root.close(lib.io);
    var dir = try root.createDirPathOpen(lib.io, name, .{});
    defer dir.close(lib.io);
    if (dir.readFileAlloc(lib.io, "shader.glsl", a, .limited(max_shader))) |old_source| {
        const old_json = dir.readFileAlloc(lib.io, "shader.json", a, .limited(max_shader)) catch "{}";
        try dir.createDirPath(lib.io, ".versions");
        const stem = try std.fmt.allocPrint(a, ".versions/{d}", .{now_s});
        try dir.writeFile(lib.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}.glsl", .{stem}), .data = old_source });
        try dir.writeFile(lib.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}.json", .{stem}), .data = old_json });
        try lib.pruneVersions(a, dir);
    } else |_| {}
    const core = @import("photo-core");
    try core.store.writeAtomic(lib.io, a, dir, "shader.json", json_text);
    try core.store.writeAtomic(lib.io, a, dir, "shader.glsl", source);
}

fn pruneVersions(lib: *Library, a: std.mem.Allocator, dir: Io.Dir) !void {
    var versions = try dir.openDir(lib.io, ".versions", .{ .iterate = true });
    defer versions.close(lib.io);
    var stems: std.ArrayList(u64) = .empty;
    var it = versions.iterate();
    while (try it.next(lib.io)) |e| {
        if (!std.mem.endsWith(u8, e.name, ".glsl")) continue;
        const n = std.fmt.parseInt(u64, e.name[0 .. e.name.len - 5], 10) catch continue;
        try stems.append(a, n);
    }
    std.mem.sort(u64, stems.items, {}, std.sort.desc(u64));
    if (stems.items.len <= versions_kept) return;
    for (stems.items[versions_kept..]) |n| {
        versions.deleteFile(lib.io, try std.fmt.allocPrint(a, "{d}.glsl", .{n})) catch {};
        versions.deleteFile(lib.io, try std.fmt.allocPrint(a, "{d}.json", .{n})) catch {};
    }
}

pub fn deleteShader(lib: *Library, name: []const u8) !void {
    if (!validName(name)) return error.BadName;
    var root = try Io.Dir.cwd().openDir(lib.io, lib.shaders_dir, .{});
    defer root.close(lib.io);
    root.access(lib.io, name, .{}) catch return error.NoSuchShader;
    try root.deleteTree(lib.io, name);
}

pub fn saveLook(lib: *Library, a: std.mem.Allocator, name: []const u8, cube: []const u8) !void {
    if (!validName(name) or !std.ascii.endsWithIgnoreCase(name, ".cube")) return error.BadName;
    var dir = try Io.Dir.cwd().openDir(lib.io, lib.looks_dir, .{});
    defer dir.close(lib.io);
    try @import("photo-core").store.writeAtomic(lib.io, a, dir, name, cube);
}

/// Serves `looks/<name>.cube`; false when the path isn't one.
pub fn handle(lib: *Library, request: *Window.Request, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "looks/")) return false;
    var arena: std.heap.ArenaAllocator = .init(lib.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const name = @import("ui.zig").percentDecode(a, path["looks/".len..]) catch null orelse {
        Window.fail(request, 400, "bad name");
        return true;
    };
    if (!validName(name)) {
        Window.fail(request, 400, "bad name");
        return true;
    }
    const full = std.fs.path.join(a, &.{ lib.looks_dir, name }) catch return true;
    const bytes = Io.Dir.cwd().readFileAlloc(lib.io, full, a, .limited(max_cube)) catch {
        Window.fail(request, 404, "no such look");
        return true;
    };
    Window.respond(request, bytes, "text/plain");
    return true;
}

/// Watches both folders and every shader's folder; `on_change` hears about edits.
pub fn watch(lib: *Library) void {
    lib.unwatch();
    var arena: std.heap.ArenaAllocator = .init(lib.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    lib.watchDir(lib.looks_dir);
    lib.watchDir(lib.shaders_dir);
    for (lib.shaderNames(a) catch &.{}) |name| {
        const p = std.fs.path.joinZ(a, &.{ lib.shaders_dir, name }) catch continue;
        lib.watchDir(p);
    }
}

fn watchDir(lib: *Library, path: [:0]const u8) void {
    const file = c.g_file_new_for_path(path);
    defer c.g_object_unref(file);
    const monitor = c.g_file_monitor_directory(file, c.monitor_watch_moves, null, null) orelse return;
    _ = c.g_signal_connect_data(monitor, "changed", @ptrCast(&onFileEvent), lib, null, 0);
    lib.monitors.append(lib.gpa, monitor) catch c.g_object_unref(monitor);
}

fn unwatch(lib: *Library) void {
    for (lib.monitors.items) |m| c.g_object_unref(m);
    lib.monitors.clearRetainingCapacity();
}

fn onFileEvent(_: *c.GFileMonitor, _: *c.GFile, _: ?*c.GFile, _: c_int, ctx: ?*anyopaque) callconv(.c) void {
    const lib: *Library = @ptrCast(@alignCast(ctx));
    if (lib.settle_timer != 0) Window.cancel(lib.settle_timer);
    lib.settle_timer = Window.after(settle_ms, onSettled, lib);
}

fn onSettled(ctx: ?*anyopaque) callconv(.c) c_int {
    const lib: *Library = @ptrCast(@alignCast(ctx));
    lib.settle_timer = 0;
    // A shader folder may have come or gone.
    lib.watch();
    if (lib.on_change) |h| h.f(h.ctx);
    return 0;
}
