//! What's open: the folder, the photo, its edits and undo. No window in here, so it can be tested
//! without one. Recipes save a moment after the last change (the window's timer calls `flush`).
const std = @import("std");
const Io = std.Io;
const core = @import("photo-core");
const folders = @import("folder.zig");
const Session = @import("session.zig");
const Settings = @import("settings.zig");
const Library = @import("library.zig");
const Mcp = @import("mcp.zig");
const Recipe = core.Recipe;

const App = @This();

const log = std.log.scoped(.app);

pub const Photo = folders.Photo;

pub const Folder = struct {
    arena: std.heap.ArenaAllocator,
    path: [:0]const u8,
    dir: Io.Dir,
    photos: []Photo,
    sessions: std.StringHashMapUnmanaged(*Session) = .empty,

    pub fn name(f: *const Folder) []const u8 {
        return std.fs.path.basename(f.path);
    }

    pub fn index(f: *const Folder, rel: []const u8) ?usize {
        for (f.photos, 0..) |p, i| if (std.mem.eql(u8, p.rel, rel)) return i;
        return null;
    }
};

gpa: std.mem.Allocator,
io: Io,
config_dir: []const u8 = "",
settings: Settings = .{},
settings_arena: ?*std.heap.ArenaAllocator = null,
folder: ?Folder = null,
current: ?usize = null,
// Bumped per folder: a background scan of the one before answers to nobody.
generation: u32 = 0,
dirty: ?struct { session: *Session, rel: []const u8 } = null,
// What the sidebar shows, and ← → walk through. The open photo always stays in.
status: Status = .all,
day: []const u8 = "",
library: ?*Library = null,
subject: ?*@import("subject.zig") = null,
// The active tab, for get_view.
tab: []const u8 = "adjust",
hooks: Hooks = .{},

pub const Status = enum { all, edited, unedited, picked };

/// How Claude's tools reach the window.
pub const Hooks = struct {
    edited: ?*const fn () void = null,
    photo_changed: ?*const fn () void = null,
    library_changed: ?*const fn () void = null,
    screenshot: ?*const fn (shot: Shot) void = null,
    export_for_claude: ?*const fn (call: *Mcp.Call, args: std.json.Value) anyerror!void = null,
    // The compiler's message, or null when it compiled.
    compile_shader: ?*const fn (a: std.mem.Allocator, params: []const Library.Param, source: []const u8) []const u8 = null,
    bake: ?*const fn (a: std.mem.Allocator, title: []const u8, size: u32) anyerror![]const u8 = null,
    // A contact sheet of these photos answers the call, under the text.
    sheet: ?*const fn (call: *Mcp.Call, indices: []const u32, lead: []const u8) anyerror!void = null,
    // The photos Ctrl-clicked in the sidebar.
    selected: ?*const fn (a: std.mem.Allocator) anyerror![]const u32 = null,
    picks_changed: ?*const fn () void = null,
    // A look at the open photo in detail, or before and after, answers the call.
    closeup: ?*const fn (request: Closeup) anyerror!void = null,
};

pub const Closeup = struct {
    call: *Mcp.Call,
    // Goes under the picture; the closeup frees it.
    text: []u8,
    index: usize,
    // Where to look, 0..1 of the photo as its crop shows it, and how much: a share of its long edge.
    at: ?[2]f32 = null,
    size: f32 = 0.2,
    // The original beside the edit.
    compare: bool = false,
    show_mask: ?usize = null,
};

pub const Shot = struct {
    call: *Mcp.Call,
    text: []u8,
    // This mask painted red in the screenshot.
    show_mask: ?usize = null,
};

pub fn deinit(app: *App) void {
    app.flush();
    app.closeFolder();
}

pub fn closeFolder(app: *App) void {
    const f = &(app.folder orelse return);
    var it = f.sessions.valueIterator();
    while (it.next()) |s| {
        s.*.deinit();
        app.gpa.destroy(s.*);
    }
    f.sessions.deinit(app.gpa);
    f.dir.close(app.io);
    f.arena.deinit();
    app.folder = null;
    app.current = null;
    app.generation +%= 1;
}

/// Opens a folder and its first photo; subfolders are included.
pub fn openFolder(app: *App, path: [:0]const u8) !void {
    var resolved: [std.c.PATH_MAX]u8 = undefined;
    const real = std.mem.span(std.c.realpath(path, &resolved) orelse return error.FileNotFound);
    // First: the scan below reads which photos have a recipe, this one's perhaps among them.
    app.flush();
    var dir = try Io.Dir.cwd().openDir(app.io, real, .{ .iterate = true });
    errdefer dir.close(app.io);
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const photos = try folders.scan(app.io, a, app.gpa, dir);
    const owned = try a.dupeZ(u8, real);
    app.closeFolder();
    app.folder = .{ .arena = arena, .path = owned, .dir = dir, .photos = photos };
    app.loadPicks();
    app.remember(owned);
    if (photos.len > 0) try app.open(0);
}

// The next start opens this folder.
fn remember(app: *App, path: []const u8) void {
    const settings_arena = app.settings_arena orelse return;
    app.settings.last_folder = settings_arena.allocator().dupe(u8, path) catch return;
    app.saveSettings();
}

pub fn saveSettings(app: *App) void {
    if (app.config_dir.len == 0) return;
    app.settings.save(app.io, app.gpa, app.config_dir) catch |err| log.warn("settings not saved: {t}", .{err});
}

pub fn open(app: *App, index: usize) !void {
    const f = &(app.folder orelse return error.NoFolder);
    if (index >= f.photos.len) return error.NoSuchPhoto;
    app.flush();
    app.current = index;
    _ = try app.session(index);
}

/// The photo's edits, loaded from its recipe the first time.
pub fn session(app: *App, index: usize) !*Session {
    const f = &(app.folder orelse return error.NoFolder);
    const rel = f.photos[index].rel;
    if (f.sessions.get(rel)) |s| return s;
    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();
    const start = core.store.load(app.io, scratch.allocator(), f.dir, rel) catch |err| blk: {
        log.warn("recipe for {s} unreadable ({t}); starting fresh", .{ rel, err });
        break :blk null;
    } orelse Recipe{};
    const s = try app.gpa.create(Session);
    errdefer app.gpa.destroy(s);
    s.* = try Session.init(app.gpa, start);
    try f.sessions.put(app.gpa, rel, s);
    return s;
}

pub fn currentSession(app: *App) ?*Session {
    const i = app.current orelse return null;
    return app.session(i) catch null;
}

pub fn currentRel(app: *const App) ?[]const u8 {
    const f = &(app.folder orelse return null);
    return f.photos[app.current orelse return null].rel;
}

/// The open photo's recipe, its strings in `arena`.
pub fn recipe(app: *App, arena: std.mem.Allocator) !Recipe {
    const s = app.currentSession() orelse return error.NoPhoto;
    return s.recipe(arena);
}

pub fn now(app: *App) u64 {
    return @intCast(@divFloor(Io.Timestamp.now(app.io, .real).nanoseconds, std.time.ns_per_s));
}

/// Changes the open photo's recipe with a JSON patch; edits with the same `gesture` undo together.
pub fn edit(app: *App, patch_json: []const u8, gesture: u64) !void {
    const s = app.currentSession() orelse return error.NoPhoto;
    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const patch = try std.json.parseFromSliceLeaky(std.json.Value, a, patch_json, .{});
    _ = try s.change(a, .{ .patch = patch, .gesture = gesture, .now = app.now() });
    app.changed();
}

pub fn undo(app: *App) !bool {
    const s = app.currentSession() orelse return false;
    const moved = try s.undo();
    if (moved) app.changed();
    return moved;
}

pub fn redo(app: *App) !bool {
    const s = app.currentSession() orelse return false;
    const moved = try s.redo();
    if (moved) app.changed();
    return moved;
}

// Marks the open photo for saving, and edited or not.
pub fn changed(app: *App) void {
    const f = &(app.folder orelse return);
    const i = app.current orelse return;
    const s = app.currentSession() orelse return;
    if (app.dirty != null and app.dirty.?.session != s) app.flush();
    app.dirty = .{ .session = s, .rel = f.photos[i].rel };
    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();
    if (s.recipe(scratch.allocator())) |r| {
        f.photos[i].edited = !r.isDefault();
    } else |_| {}
}

/// Writes the pending recipe now.
pub fn flush(app: *App) void {
    const d = app.dirty orelse return;
    app.dirty = null;
    const f = &(app.folder orelse return);
    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();
    const r = d.session.recipe(scratch.allocator()) catch return;
    core.store.save(app.io, app.gpa, f.dir, d.rel, r) catch |err| log.err("recipe for {s} not saved: {t}", .{ d.rel, err });
}

fn loadPicks(app: *App) void {
    const f = &(app.folder orelse return);
    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();
    const names = core.store.loadPicks(app.io, scratch.allocator(), f.dir) catch |err| {
        log.warn("picks unreadable: {t}", .{err});
        return;
    };
    // A photo that's gone since is just not picked any more.
    for (names) |name| if (f.index(name)) |i| {
        f.photos[i].picked = true;
    };
}

fn savePicks(app: *App) !void {
    const f = &(app.folder orelse return error.NoFolder);
    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    for (f.photos) |p| if (p.picked) try names.append(a, p.rel);
    try core.store.savePicks(app.io, a, f.dir, names.items);
}

/// The folder's picks, in its order.
pub fn picks(app: *const App, a: std.mem.Allocator) ![]const u32 {
    const f = &(app.folder orelse return error.NoFolder);
    var out: std.ArrayList(u32) = .empty;
    for (f.photos, 0..) |p, i| if (p.picked) try out.append(a, @intCast(i));
    return out.items;
}

/// These photos are the picks now, and no others.
pub fn setPicks(app: *App, indices: []const u32) !void {
    const f = &(app.folder orelse return error.NoFolder);
    for (f.photos) |*p| p.picked = false;
    for (indices) |i| f.photos[i].picked = true;
    try app.savePicks();
}

/// P: the open photo in or out of the picks.
pub fn togglePick(app: *App) !void {
    const f = &(app.folder orelse return error.NoFolder);
    const i = app.current orelse return error.NoPhoto;
    f.photos[i].picked = !f.photos[i].picked;
    try app.savePicks();
}

pub fn matches(app: *const App, p: Photo) bool {
    const status = switch (app.status) {
        .all => true,
        .edited => p.edited,
        .unedited => !p.edited,
        .picked => p.picked,
    };
    return status and (app.day.len == 0 or std.mem.eql(u8, p.day, app.day));
}

pub fn filtered(app: *const App) bool {
    return app.status != .all or app.day.len > 0;
}

/// Indices of the photos to show, in order, into `out`.
pub fn shown(app: *const App, gpa: std.mem.Allocator, out: *std.ArrayList(u32)) !void {
    out.clearRetainingCapacity();
    const f = &(app.folder orelse return);
    for (f.photos, 0..) |p, i| {
        if (i == app.current or app.matches(p)) try out.append(gpa, @intCast(i));
    }
}

/// Fills in the days a scan found, in the folder's order: "" where there's no date.
pub fn setDays(app: *App, days: []const [10]u8) !void {
    const f = &(app.folder orelse return);
    const a = f.arena.allocator();
    for (f.photos, days) |*p, *d| {
        if (d[0] != 0) p.day = try a.dupe(u8, d);
    }
}

const testing = std.testing;

fn testApp(tmp: *testing.TmpDir, path_buf: *[std.c.PATH_MAX]u8) !struct { App, [:0]const u8 } {
    const io = testing.io;
    for ([_][]const u8{ "b.jpg", "a.JPG", "trip/c.jpeg" }) |p| {
        if (std.fs.path.dirname(p)) |d| try tmp.dir.createDirPath(io, d);
        try tmp.dir.writeFile(io, .{ .sub_path = p, .data = "not really a photo" });
    }
    const n = try tmp.dir.realPathFile(io, ".", path_buf);
    path_buf[n] = 0;
    return .{ .{ .gpa = testing.allocator, .io = io }, path_buf[0..n :0] };
}

test "a folder opens on its first photo, in order" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.c.PATH_MAX]u8 = undefined;
    var app, const path = try testApp(&tmp, &buf);
    defer app.deinit();
    try app.openFolder(path);
    try testing.expectEqual(3, app.folder.?.photos.len);
    try testing.expectEqualStrings("a.JPG", app.currentRel().?);
    try app.open(2);
    try testing.expectEqualStrings("trip/c.jpeg", app.currentRel().?);
    try testing.expectError(error.NoSuchPhoto, app.open(3));
}

test "an edit marks the photo, undoes and redoes, and is there after reopening" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.c.PATH_MAX]u8 = undefined;
    var app, const path = try testApp(&tmp, &buf);
    defer app.deinit();
    try app.openFolder(path);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try app.edit("{\"edits\":{\"exposure\":0.5}}", 1);
    try app.edit("{\"edits\":{\"exposure\":0.8}}", 1);
    try testing.expect(app.folder.?.photos[0].edited);
    try testing.expectEqual(0.8, (try app.recipe(a)).edits.exposure);
    // One drag, one undo.
    try testing.expect(try app.undo());
    try testing.expectEqual(0, (try app.recipe(a)).edits.exposure);
    try testing.expect(!app.folder.?.photos[0].edited);
    try testing.expect(try app.redo());
    try testing.expectEqual(0.8, (try app.recipe(a)).edits.exposure);
    try testing.expect(!try app.redo());

    // Moving to another photo saves this one.
    try app.open(1);
    try testing.expectEqual(0, (try app.recipe(a)).edits.exposure);
    try app.openFolder(path);
    try testing.expect(app.folder.?.photos[0].edited);
    try testing.expectEqual(0.8, (try app.recipe(a)).edits.exposure);
}

test "picks stay after reopening, and a filter shows only them" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.c.PATH_MAX]u8 = undefined;
    var app, const path = try testApp(&tmp, &buf);
    defer app.deinit();
    try app.openFolder(path);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(0, (try app.picks(a)).len);
    try app.setPicks(&.{ 2, 1 });
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, try app.picks(a));
    // They replace those before; P adds and takes away the open one.
    try app.setPicks(&.{2});
    try app.togglePick();
    try testing.expectEqualSlices(u32, &.{ 0, 2 }, try app.picks(a));
    try app.togglePick();
    try app.togglePick();
    try app.openFolder(path);
    try testing.expectEqualSlices(u32, &.{ 0, 2 }, try app.picks(a));
    app.status = .picked;
    try app.open(1);
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(testing.allocator);
    try app.shown(testing.allocator, &out);
    // The open photo always stays in.
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, out.items);
    try app.open(0);
    try app.shown(testing.allocator, &out);
    try testing.expectEqualSlices(u32, &.{ 0, 2 }, out.items);
    // A photo that's gone is no trouble; none left, no file.
    try tmp.dir.deleteFile(testing.io, "trip/c.jpeg");
    try app.openFolder(path);
    try testing.expectEqualSlices(u32, &.{0}, try app.picks(a));
    try app.setPicks(&.{});
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, ".photo-editor/picks.json", .{}));
    // No edit came of any of it.
    for (app.folder.?.photos) |p| try testing.expect(!p.edited);
}

test "the original files are never written to" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.c.PATH_MAX]u8 = undefined;
    var app, const path = try testApp(&tmp, &buf);
    defer app.deinit();
    try app.openFolder(path);
    try app.edit("{\"edits\":{\"contrast\":20}}", 0);
    app.flush();
    var read: [64]u8 = undefined;
    const bytes = try tmp.dir.readFile(testing.io, "a.JPG", &read);
    try testing.expectEqualStrings("not really a photo", bytes);
}

test "filters narrow what is shown, and the open photo always stays" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.c.PATH_MAX]u8 = undefined;
    var app, const path = try testApp(&tmp, &buf);
    defer app.deinit();
    try app.openFolder(path);
    const f = &app.folder.?;
    f.photos[1].edited = true;
    f.photos[1].day = "d1";
    f.photos[2].day = "d2";
    var out: std.ArrayList(u32) = .empty;
    defer out.deinit(testing.allocator);
    try app.shown(testing.allocator, &out);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, out.items);
    app.status = .edited;
    try app.shown(testing.allocator, &out);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, out.items);
    app.status = .unedited;
    app.day = "d2";
    try app.shown(testing.allocator, &out);
    try testing.expectEqualSlices(u32, &.{ 0, 2 }, out.items);
}

test "days fill in by position" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [std.c.PATH_MAX]u8 = undefined;
    var app, const path = try testApp(&tmp, &buf);
    defer app.deinit();
    try app.openFolder(path);
    const none: [10]u8 = @splat(0);
    try app.setDays(&.{ "2026-08-07".*, none, "2026-08-08".* });
    try testing.expectEqualStrings("2026-08-07", app.folder.?.photos[0].day);
    try testing.expectEqualStrings("", app.folder.?.photos[1].day);
    try testing.expectEqualStrings("2026-08-08", app.folder.?.photos[2].day);
}
