//! The running app's state, the single source of truth (SPEC.md): the open folder, the photo on
//! screen, every photo's edits and history. The page and Claude both change it through here;
//! the page shows what it says. Main loop only.
const std = @import("std");
const Io = std.Io;
const core = @import("photo-core");
const Recipe = core.Recipe;

const Window = @import("window.zig");
const Images = @import("images.zig");
const Pool = @import("jobs.zig");
const Session = @import("session.zig");
const Settings = @import("settings.zig");
const folders = @import("folder.zig");
const gpu = @import("gpu.zig");
const Mcp = @import("mcp.zig");
const tools = @import("tools.zig");
const Library = @import("library.zig");
const Exporter = @import("exporter.zig");

const App = @This();

const log = std.log.scoped(.app);

// Recipes reach the disk this long after the last change: a drag saves once, at the end.
pub const save_delay_ms = 400;
// About a screen's long edge: the stage never shows upscaled pixels, and a slider redraws ~4 MP.
pub const default_preview_edge = 2048;

gpa: std.mem.Allocator,
io: Io,
env: *const std.process.Environ.Map,
window: *Window,
images: *Images,
pool: *Pool,
library: *Library,
exporter: Exporter = undefined,
config_dir: []const u8,
settings_arena: std.heap.ArenaAllocator,
settings: Settings,
folder: ?Folder = null,
current: ?usize = null,
preview_edge: u32 = default_preview_edge,
save_timer: c_uint = 0,
dirty: ?*Session = null,
dirty_rel: []const u8 = "",
// Hooks for the window's modes: `zig build probe` and `--shot`.
probe: bool = false,
shot: ?[:0]const u8 = null,
shot_tab: []const u8 = "",
shot_script: ?[]const u8 = null,
// A test run (probe, shot, offscreen): settings stay as they are.
ephemeral: bool = false,
// `--shots DIR`: a picture after each of Claude's tool calls.
shots_dir: ?[]const u8 = null,
shots_taken: u32 = 0,
gpu_report: ?gpu.Report = null,
exit_code: u8 = 0,
// When main started, for "first photo in N ms" (SPEC.md, Performance targets).
started: i96 = 0,
first_frame_logged: bool = false,
// The page's active tab, for get_view.
tab: []const u8 = "adjust",
screenshots: std.ArrayList(tools.Screenshot) = .empty,
next_screenshot: u32 = 1,
asks: std.ArrayList(Asked) = .empty,

pub const Folder = struct {
    arena: std.heap.ArenaAllocator,
    path: [:0]const u8,
    dir: Io.Dir,
    photos: []folders.Photo,
    sessions: std.StringHashMapUnmanaged(*Session) = .empty,

    pub fn name(f: *const Folder) []const u8 {
        return std.fs.path.basename(f.path);
    }

    pub fn index(f: *const Folder, rel: []const u8) ?usize {
        for (f.photos, 0..) |p, i| if (std.mem.eql(u8, p.rel, rel)) return i;
        return null;
    }
};

pub fn deinit(app: *App) void {
    for (app.screenshots.items) |shot| app.gpa.free(shot.text);
    app.screenshots.deinit(app.gpa);
    app.asks.deinit(app.gpa);
    app.flush();
    app.closeFolder();
    app.settings_arena.deinit();
}

fn closeFolder(app: *App) void {
    var f = &(app.folder orelse return);
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
}

pub fn openFolder(app: *App, path: []const u8) !void {
    var real_buf: [std.c.PATH_MAX]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&real_buf, "{s}", .{path});
    var resolved: [std.c.PATH_MAX]u8 = undefined;
    const real = std.mem.span(std.c.realpath(path_z, &resolved) orelse return error.FileNotFound);

    var dir = try Io.Dir.cwd().openDir(app.io, real, .{ .iterate = true });
    errdefer dir.close(app.io);
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const photos = try folders.scan(app.io, a, app.gpa, dir);

    app.flush();
    app.closeFolder();
    app.folder = .{ .arena = arena, .path = try a.dupeZ(u8, real), .dir = dir, .photos = photos };
    try app.images.setRoot(real);
    log.info("opened {s}: {d} photos", .{ real, photos.len });

    app.settings.last_folder = try app.settings_arena.allocator().dupe(u8, real);
    app.saveSettings();
    if (photos.len > 0) try app.open(0);
}

/// Remembers the settings, except in `--shot` and `--probe`: a test run mustn't change the next start.
pub fn saveSettings(app: *App) void {
    if (app.ephemeral) return;
    app.settings.save(app.io, app.gpa, app.config_dir) catch |err| log.warn("settings not saved: {t}", .{err});
}

pub fn open(app: *App, index: usize) !void {
    const f = &(app.folder orelse return error.NoFolder);
    if (index >= f.photos.len) return error.NoSuchPhoto;
    app.flush();
    app.current = index;
    _ = try app.session(index);
    // The photo before the page asks for it (start-up), and its neighbours, so ← and → don't wait.
    app.images.prefetch(f.photos[index].rel, app.preview_edge, .urgent);
    if (index + 1 < f.photos.len) app.images.prefetch(f.photos[index + 1].rel, app.preview_edge, .background);
    if (index > 0) app.images.prefetch(f.photos[index - 1].rel, app.preview_edge, .background);
}

/// The photo's session, loaded from its recipe the first time.
pub fn session(app: *App, index: usize) !*Session {
    const f = &(app.folder orelse return error.NoFolder);
    const rel = f.photos[index].rel;
    if (f.sessions.get(rel)) |s| return s;
    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();
    const recipe = core.store.load(app.io, scratch.allocator(), f.dir, rel) catch |err| blk: {
        log.warn("recipe for {s} unreadable ({t}); starting fresh", .{ rel, err });
        break :blk null;
    } orelse Recipe{};
    const s = try app.gpa.create(Session);
    errdefer app.gpa.destroy(s);
    s.* = try Session.init(app.gpa, recipe);
    try f.sessions.put(app.gpa, rel, s);
    return s;
}

pub fn currentSession(app: *App) !*Session {
    return app.session(app.current orelse return error.NoPhoto);
}

pub fn now(app: *App) u64 {
    const ns = Io.Timestamp.now(app.io, .real).nanoseconds;
    return @intCast(@divFloor(ns, std.time.ns_per_s));
}

/// The current photo's edits changed: save soon, and mark it edited or not.
pub fn changed(app: *App) void {
    const f = &(app.folder orelse return);
    const i = app.current orelse return;
    const s = app.currentSession() catch return;
    if (app.dirty != null and app.dirty.? != s) app.flush();
    app.dirty = s;
    app.dirty_rel = f.photos[i].rel;
    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();
    if (s.recipe(scratch.allocator())) |r| {
        f.photos[i].edited = !r.isDefault();
    } else |_| {}
    if (app.save_timer != 0) Window.cancel(app.save_timer);
    app.save_timer = Window.after(save_delay_ms, onSaveTimer, app);
}

fn onSaveTimer(ctx: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.save_timer = 0;
    app.flush();
    return 0;
}

/// Writes the pending recipe now.
pub fn flush(app: *App) void {
    if (app.save_timer != 0) {
        Window.cancel(app.save_timer);
        app.save_timer = 0;
    }
    const s = app.dirty orelse return;
    app.dirty = null;
    const f = &(app.folder orelse return);
    var scratch: std.heap.ArenaAllocator = .init(app.gpa);
    defer scratch.deinit();
    const r = s.recipe(scratch.allocator()) catch return;
    core.store.save(app.io, app.gpa, f.dir, app.dirty_rel, r) catch |err| log.err("recipe for {s} not saved: {t}", .{ app.dirty_rel, err });
}

// The page's calls: `await rpc(method, params)` in ui/rpc.ts.

pub fn onRpc(id: [*:0]const u8, request: [*:0]const u8, ctx: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    const ok = if (app.dispatch(a, std.mem.span(request), &out.writer)) true else |err| blk: {
        log.err("rpc {s}: {t}", .{ std.mem.span(request)[0..@min(80, std.mem.len(request))], err });
        out.clearRetainingCapacity();
        out.writer.print("\"{t}\"", .{err}) catch {};
        break :blk false;
    };
    out.writer.writeByte(0) catch return;
    const json = out.written();
    app.window.reply(id, ok, json[0 .. json.len - 1 :0]);
}

fn dispatch(app: *App, a: std.mem.Allocator, request: []const u8, w: *Io.Writer) !void {
    const args = try std.json.parseFromSliceLeaky([]std.json.Value, a, request, .{});
    if (args.len < 1 or args[0] != .string) return error.BadRequest;
    const method = args[0].string;
    const params: std.json.Value = if (args.len > 1) args[1] else .null;

    if (eql(method, "state")) return app.writeState(a, w);
    if (eql(method, "openFolder")) {
        if (string(params, "path")) |p| {
            try app.openFolder(p);
        } else {
            const start: ?[:0]const u8 = if (app.folder) |f| f.path else null;
            const chosen = app.window.chooseFolder(start) orelse return w.writeAll("null");
            defer @import("c.zig").g_free(chosen);
            try app.openFolder(std.mem.span(chosen));
        }
        return app.writeState(a, w);
    }
    if (eql(method, "open")) {
        const f = &(app.folder orelse return error.NoFolder);
        const rel = string(params, "rel") orelse return error.BadRequest;
        try app.open(f.index(rel) orelse return error.NoSuchPhoto);
        return app.writePhoto(a, w);
    }
    if (eql(method, "edit")) {
        const s = try app.currentSession();
        const gesture: u64 = if (field(params, "gesture")) |g| (if (g == .integer) @intCast(g.integer) else 0) else 0;
        _ = try s.change(a, .{ .patch = field(params, "patch") orelse return error.BadRequest, .gesture = gesture, .now = app.now() });
        app.changed();
        return app.writePhoto(a, w);
    }
    if (eql(method, "undo") or eql(method, "redo") or eql(method, "keep") or eql(method, "undoClaude")) {
        const s = try app.currentSession();
        const moved = if (eql(method, "undo")) try s.undo() else if (eql(method, "redo")) try s.redo() else if (eql(method, "keep")) blk: {
            s.keepClaude();
            break :blk false;
        } else try s.undoClaude();
        if (moved) app.changed();
        return app.writePhoto(a, w);
    }
    if (eql(method, "gpu")) {
        const r = try std.json.parseFromValueLeaky(gpu.Report, a, params, .{ .ignore_unknown_fields = true });
        app.onGpu(r);
        // The probe also compiles the shaders the app comes with.
        var s: std.json.Stringify = .{ .writer = w };
        try s.beginObject();
        try s.objectField("probe");
        try s.write(app.probe);
        try s.objectField("starters");
        try s.beginArray();
        if (app.probe) for (Library.starters) |st| try s.write(.{ .name = st.name, .glsl = st.glsl, .json = st.json });
        try s.endArray();
        return s.endObject();
    }
    if (eql(method, "selftest")) {
        app.onSelfTest(try std.json.parseFromValueLeaky([]const gpu.TestResult, a, params, .{ .ignore_unknown_fields = true }));
        return w.writeAll("null");
    }
    if (eql(method, "tab")) {
        const t = string(params, "tab") orelse "adjust";
        for ([_][]const u8{ "adjust", "looks", "crop" }) |known| if (eql(t, known)) {
            app.tab = known;
        };
        return w.writeAll("null");
    }
    if (eql(method, "screenshot")) {
        const id: u32 = if (field(params, "id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
        const tones = if (field(params, "tones")) |t| (if (t == .object) try std.json.Stringify.valueAlloc(a, t, .{}) else "") else "";
        app.screenshotDone(id, string(params, "data") orelse "", tones);
        return w.writeAll("null");
    }
    if (eql(method, "answer")) {
        const id: u32 = if (field(params, "id")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
        app.answered(id, params);
        return w.writeAll("null");
    }
    if (eql(method, "library")) {
        var s: std.json.Stringify = .{ .writer = w };
        return app.library.write(a, &s);
    }
    if (eql(method, "export")) {
        const f = &(app.folder orelse return error.NoFolder);
        var options = app.settings.@"export";
        if (field(params, "options")) |o| options = try std.json.parseFromValueLeaky(Settings.Export, a, o, .{ .ignore_unknown_fields = true });
        // What the dialog chose becomes the default next time.
        if (field(params, "remember")) |r| if (r == .bool and r.bool) {
            const keep = app.settings_arena.allocator();
            app.settings.@"export" = options;
            app.settings.@"export".folder = try keep.dupe(u8, options.folder);
            app.settings.@"export".suffix = try keep.dupe(u8, options.suffix);
            app.saveSettings();
        };
        var rels: std.ArrayList([]const u8) = .empty;
        if (field(params, "rels")) |list| if (list == .array) for (list.array.items) |r| if (r == .string) try rels.append(a, r.string);
        if (rels.items.len == 0) if (app.current) |i| try rels.append(a, f.photos[i].rel);
        try app.exporter.start(rels.items, options, .page, .{});
        return w.writeAll("null");
    }
    if (eql(method, "settings")) {
        var s: std.json.Stringify = .{ .writer = w };
        try s.beginObject();
        try s.objectField("export");
        try s.write(app.settings.@"export");
        try s.objectField("defaultFolder");
        try s.write(try Settings.defaultExportFolder(a, app.env));
        try s.objectField("looksFolder");
        try s.write(app.library.looks_dir);
        try s.objectField("shadersFolder");
        try s.write(app.library.shaders_dir);
        try s.objectField("mcp");
        try s.write(Mcp.url);
        return s.endObject();
    }
    if (eql(method, "ready")) {
        app.onReady();
        return w.writeAll("null");
    }
    if (eql(method, "log")) {
        const msg = string(params, "message") orelse "";
        if (eql(string(params, "level") orelse "", "error")) log.err("page: {s}", .{msg}) else log.info("page: {s}", .{msg});
        return w.writeAll("null");
    }
    return error.UnknownMethod;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn field(v: std.json.Value, name: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(name);
}

fn string(v: std.json.Value, name: []const u8) ?[]const u8 {
    const f = field(v, name) orelse return null;
    return if (f == .string) f.string else null;
}

pub fn writeState(app: *App, a: std.mem.Allocator, w: *Io.Writer) !void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("folder");
    if (app.folder) |*f| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(f.name());
        try s.objectField("path");
        try s.write(f.path);
        try s.objectField("photos");
        try s.beginArray();
        for (f.photos) |p| {
            try s.beginObject();
            try s.objectField("rel");
            try s.write(p.rel);
            try s.objectField("edited");
            try s.write(p.edited);
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
    } else try s.write(null);
    try s.objectField("photo");
    try app.writePhotoValue(a, &s);
    try s.objectField("shotTab");
    try s.write(app.shot_tab);
    try s.objectField("previewEdge");
    try s.write(app.preview_edge);
    try s.endObject();
}

pub fn writePhoto(app: *App, a: std.mem.Allocator, w: *Io.Writer) !void {
    var s: std.json.Stringify = .{ .writer = w };
    try app.writePhotoValue(a, &s);
}

fn writePhotoValue(app: *App, a: std.mem.Allocator, s: *std.json.Stringify) !void {
    const f = &(app.folder orelse return s.write(null));
    const i = app.current orelse return s.write(null);
    const sess = try app.session(i);
    const rel = f.photos[i].rel;
    const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ f.path, rel }, 0);
    const info = core.decode.info(a, path) catch core.decode.Info{};
    try s.beginObject();
    try s.objectField("rel");
    try s.write(rel);
    try s.objectField("index");
    try s.write(i);
    try s.objectField("edited");
    try s.write(f.photos[i].edited);
    try s.objectField("info");
    try s.write(info);
    try s.objectField("recipe");
    try s.beginWriteRaw();
    try s.writer.writeAll(sess.json);
    s.endWriteRaw();
    try s.objectField("canUndo");
    try s.write(sess.canUndo());
    try s.objectField("canRedo");
    try s.write(sess.canRedo());
    try s.objectField("claude");
    if (sess.claudePending()) {
        try s.beginObject();
        try s.objectField("note");
        try s.write(sess.claude_note.items);
        try s.objectField("changes");
        try s.write(sess.claude_changes);
        try s.endObject();
    } else try s.write(null);
    try s.endObject();
}

/// Tells the page something changed outside it (Claude, a file on disk): `doka.event(name, payload)`.
pub fn emit(app: *App, name: []const u8, payload_json: []const u8) void {
    var js: std.ArrayList(u8) = .empty;
    defer js.deinit(app.gpa);
    js.print(app.gpa, "window.doka && window.doka.event(\"{s}\", {s});\x00", .{ name, payload_json }) catch return;
    app.window.eval(js.items[0 .. js.items.len - 1 :0]);
}

/// The folder or photo changed outside the page: send it everything.
pub fn emitState(app: *App) void {
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    var out: Io.Writer.Allocating = .init(arena.allocator());
    app.writeState(arena.allocator(), &out.writer) catch return;
    app.emit("state", out.written());
}

/// The photo on screen changed outside the page: send it its new state.
pub fn emitPhoto(app: *App) void {
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    var out: Io.Writer.Allocating = .init(arena.allocator());
    app.writePhoto(arena.allocator(), &out.writer) catch return;
    app.emit("photo", out.written());
}

fn onGpu(app: *App, r: gpu.Report) void {
    app.gpu_report = r;
    log.info("WebGL2 {s}: float render {}, float readback {}, half float {}, float linear {}, max texture {d}", .{
        if (r.ok()) "ok" else "NOT OK", r.float_render, r.float_readback, r.half_float_render, r.float_linear, r.max_texture_size,
    });
    if (r.@"error".len > 0) log.err("{s}", .{r.@"error"});
    if (!r.ok()) app.exit_code = 1;
}

// `zig build probe`: the pipeline's tests on the GPU (ui/selftest.ts).
fn onSelfTest(app: *App, results: []const gpu.TestResult) void {
    var failed: usize = 0;
    for (results) |r| {
        if (r.ok) continue;
        failed += 1;
        log.err("pipeline: {s}: {s}", .{ r.name, r.detail });
    }
    if (results.len == 0 or failed > 0) app.exit_code = 1;
    log.info("pipeline: {d} of {d} tests passed", .{ results.len - failed, results.len });
    app.window.terminate();
}

// The page has drawn what it was asked to: in `--shot`, run the script if any, then take the picture.
fn onReady(app: *App) void {
    if (!app.first_frame_logged) {
        app.first_frame_logged = true;
        const ms = @divFloor(Io.Timestamp.now(app.io, .awake).nanoseconds - app.started, std.time.ns_per_ms);
        log.info("first frame {d} ms after start", .{ms});
    }
    if (app.shot == null) return;
    if (app.shot_script) |script| {
        app.shot_script = null;
        const js = std.fmt.allocPrintSentinel(app.gpa, "Promise.resolve().then(async () => {{ {s} }}).catch((e) => window.rpc('log', {{ level: 'error', message: String(e) }})).finally(() => setTimeout(() => window.rpc('ready'), 400));", .{script}, 0) catch return;
        defer app.gpa.free(js);
        app.window.eval(js);
        return;
    }
    // Let the last frame reach the compositor.
    _ = Window.after(300, takeShot, app);
}

fn takeShot(ctx: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.window.snapshot(app.shot.?, shotDone, app) catch app.window.terminate();
    return 0;
}

fn shotDone(ctx: ?*anyopaque, ok: bool) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (ok) log.info("shot saved to {s}", .{app.shot.?}) else {
        log.err("shot failed", .{});
        app.exit_code = 1;
    }
    app.window.terminate();
}

// Claude's side: the MCP server's calls arrive here on the main loop (mcp.zig).

pub fn onMcpCall(ctx: *anyopaque, call: *Mcp.Call) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    if (app.shots_dir) |dir| {
        app.shots_taken += 1;
        const png = std.fmt.allocPrintSentinel(app.settings_arena.allocator(), "{s}/{d:0>2}-{s}.png", .{ dir, app.shots_taken, call.name }, 0) catch null;
        if (png) |p| pending_shot = p;
        // After the page has drawn the change.
        _ = Window.after(1500, takeToolShot, app);
    }
    tools.run(app, call);
}

var pending_shot: ?[:0]const u8 = null;

fn takeToolShot(ctx: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(ctx));
    const png = pending_shot orelse return 0;
    app.window.snapshot(png, struct {
        fn done(_: ?*anyopaque, ok: bool) void {
            if (!ok) log.warn("shot failed", .{});
        }
    }.done, null) catch {};
    return 0;
}

pub fn onMcpActivity(ctx: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.emit("claude", "{}");
}

/// Asks the page to draw the open photo for Claude; the call is answered when it does.
pub fn requestScreenshot(app: *App, shot: tools.Screenshot) void {
    var s = shot;
    s.id = app.next_screenshot;
    app.next_screenshot +%= 1;
    s.timer = Window.after(15_000, onScreenshotTimeout, @ptrFromInt(@as(usize, s.id)));
    app.screenshots.append(app.gpa, s) catch {
        tools.finishScreenshot(app, s, "", "");
        return;
    };
    screenshot_owner = app;
    var buf: [64]u8 = undefined;
    app.emit("screenshot", std.fmt.bufPrint(&buf, "{{\"id\":{d},\"edge\":{d}}}", .{ s.id, tools.screenshot_edge }) catch unreachable);
}

// The timer's only context is the id; the app is one per process.
var screenshot_owner: ?*App = null;

fn onScreenshotTimeout(ctx: ?*anyopaque) callconv(.c) c_int {
    const app = screenshot_owner orelse return 0;
    const id: u32 = @intCast(@intFromPtr(ctx));
    for (app.screenshots.items) |*s| if (s.id == id) {
        s.timer = 0;
    };
    log.warn("the page didn't draw a screenshot in time", .{});
    app.screenshotDone(id, "", "");
    return 0;
}

fn screenshotDone(app: *App, id: u32, jpeg_base64: []const u8, tones: []const u8) void {
    for (app.screenshots.items, 0..) |s, i| if (s.id == id) {
        _ = app.screenshots.swapRemove(i);
        if (s.timer != 0) Window.cancel(s.timer);
        tools.finishScreenshot(app, s, jpeg_base64, tones);
        return;
    };
}

/// The export tool: the named photos (or the open one), with the app's settings unless overridden.
pub fn exportForClaude(app: *App, call: *Mcp.Call, args: std.json.Value) !void {
    const f = &(app.folder orelse return error.NoFolder);
    var options = app.settings.@"export";
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var rels: std.ArrayList([]const u8) = .empty;
    var extras: Exporter.Extras = .{};
    if (args == .object) {
        if (args.object.get("names")) |names| if (names == .array) for (names.array.items) |n| {
            if (n != .string) continue;
            try rels.append(a, f.photos[try tools.find(f, n.string)].rel);
        };
        if (args.object.get("format")) |v| if (v == .string) {
            options.format = std.meta.stringToEnum(core.encode.Format, v.string) orelse return error.BadFormat;
        };
        if (args.object.get("quality")) |v| if (v == .integer) {
            options.quality = @intCast(std.math.clamp(v.integer, 50, 100));
        };
        if (args.object.get("long_edge")) |v| if (v == .integer) {
            options.long_edge = @intCast(std.math.clamp(v.integer, 0, 100_000));
        };
        if (args.object.get("gps")) |v| if (v == .bool) {
            options.keep_gps = v.bool;
        };
        if (args.object.get("folder")) |v| if (v == .string) {
            if (!std.fs.path.isAbsolute(v.string)) return error.FolderNotAbsolute;
            options.folder = v.string;
        };
        if (args.object.get("name")) |v| if (v == .string) {
            extras.name = v.string;
            // A name of its own needs no "-edit".
            options.suffix = "";
        };
        if (args.object.get("aspect") != null or args.object.get("focus") != null) {
            var crop: std.json.ObjectMap = .empty;
            if (args.object.get("aspect")) |v| try crop.put(a, "aspect", v);
            if (args.object.get("focus")) |v| try crop.put(a, "focus", v);
            extras.crop = .{ .object = crop };
        }
    }
    if (rels.items.len == 0) rels.append(a, f.photos[app.current orelse return error.NoPhoto].rel) catch {};
    // Exports always keep the camera, lens and date (SPEC.md).
    options.keep_metadata = true;
    try app.exporter.start(rels.items, options, .{ .claude = call }, extras);
}

// Asking the page and waiting for its answer: compiling a shader, baking a look.

pub const Asked = struct {
    id: u32,
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, app: *App, a: std.mem.Allocator, answer: std.json.Value) void,
    timer: c_uint = 0,
};

/// Sends `doka.event(event, {"id": N, …payload})`; `f` gets the page's `answer`, or null after `timeout_ms`.
pub fn ask(app: *App, event: []const u8, payload_fields: []const u8, ctx: *anyopaque, f: @FieldType(Asked, "f"), timeout_ms: c_uint) void {
    const id = app.next_screenshot;
    app.next_screenshot +%= 1;
    the_app = app;
    const timer = Window.after(timeout_ms, onAskTimeout, @ptrFromInt(@as(usize, id)));
    app.asks.append(app.gpa, .{ .id = id, .ctx = ctx, .f = f, .timer = timer }) catch {
        Window.cancel(timer);
        return f(ctx, app, app.gpa, .null);
    };
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const payload = std.fmt.allocPrint(arena.allocator(), "{{\"id\":{d}{s}{s}}}", .{ id, if (payload_fields.len > 0) "," else "", payload_fields }) catch return;
    app.emit(event, payload);
}

var the_app: ?*App = null;

fn onAskTimeout(ctx: ?*anyopaque) callconv(.c) c_int {
    const app = the_app orelse return 0;
    const id: u32 = @intCast(@intFromPtr(ctx));
    for (app.asks.items) |*q| if (q.id == id) {
        q.timer = 0;
    };
    log.warn("the page didn't answer in time", .{});
    app.answered(id, .null);
    return 0;
}

fn answered(app: *App, id: u32, value: std.json.Value) void {
    for (app.asks.items, 0..) |q, i| if (q.id == id) {
        _ = app.asks.swapRemove(i);
        if (q.timer != 0) Window.cancel(q.timer);
        var arena: std.heap.ArenaAllocator = .init(app.gpa);
        defer arena.deinit();
        q.f(q.ctx, app, arena.allocator(), value);
        return;
    };
}

/// Something in the looks or shaders folder changed: the page reloads its list.
pub fn onLibraryChange(ctx: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.emit("library", "{}");
}
