const std = @import("std");
const builtin = @import("builtin");
const core = @import("photo-core");

const App = @import("app/app.zig");
const Window = @import("app/window.zig");
const Images = @import("app/images.zig");
const Pool = @import("app/jobs.zig");
const Settings = @import("app/settings.zig");
const Mcp = @import("app/mcp.zig");
const tools = @import("app/tools.zig");

const log = std.log.scoped(.doka);

// Long enough for a cold WebKit start; the page reports in well under a second when it works.
const probe_timeout_ms = 15_000;
const shot_timeout_ms = 30_000;

const usage =
    \\doka [folder]            the editor, on that folder (or the last one)
    \\doka --probe             check WebGL2 float render targets in a hidden window, then quit
    \\doka --shot out.png [folder] [--tab adjust|looks|crop] [--photo rel] [--eval js]
    \\                         a picture of the window, drawn off the screen, then quit;
    \\                         --eval runs js in the page first (ui/main.ts, window.test)
    \\doka --offscreen [--shots DIR] [folder]
    \\                         the app with its MCP server, drawn off the screen; --shots saves a
    \\                         picture of it after each of Claude's tool calls
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    var folder: ?[]const u8 = null;
    var probe = false;
    var shot: ?[:0]const u8 = null;
    var tab: []const u8 = "";
    var photo: ?[]const u8 = null;
    var script: ?[]const u8 = null;
    var offscreen = false;
    var shots_dir: ?[]const u8 = null;
    var it = try init.minimal.args.iterateAllocator(arena);
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--probe")) {
            probe = true;
        } else if (std.mem.eql(u8, arg, "--shot")) {
            shot = it.next() orelse return fail(usage);
        } else if (std.mem.eql(u8, arg, "--tab")) {
            tab = it.next() orelse return fail(usage);
        } else if (std.mem.eql(u8, arg, "--offscreen")) {
            offscreen = true;
        } else if (std.mem.eql(u8, arg, "--shots")) {
            shots_dir = it.next() orelse return fail(usage);
        } else if (std.mem.eql(u8, arg, "--eval")) {
            script = it.next() orelse return fail(usage);
        } else if (std.mem.eql(u8, arg, "--photo")) {
            photo = it.next() orelse return fail(usage);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return fail(usage);
        } else folder = arg;
    }

    try core.vips.init("doka");
    defer core.vips.shutdown();

    var pool: Pool = .{ .io = init.io };
    try pool.start();
    defer pool.stop();
    var images: Images = .{ .gpa = gpa, .io = init.io, .pool = &pool };
    defer images.deinit();

    const config_dir = try Settings.configDir(arena, init.environ_map);
    var settings_arena: std.heap.ArenaAllocator = .init(gpa);
    const settings = Settings.load(init.io, settings_arena.allocator(), config_dir);

    var window: Window = undefined;
    var app: App = .{
        .gpa = gpa,
        .io = init.io,
        .window = &window,
        .images = &images,
        .config_dir = config_dir,
        .settings_arena = settings_arena,
        .settings = settings,
        .probe = probe,
        .shot = shot,
        .shot_tab = tab,
        .shot_script = script,
        .ephemeral = probe or shot != null or offscreen,
        .shots_dir = shots_dir,
    };
    defer app.deinit();

    const handler: Window.Handler = .{ .ctx = &app, .handle = serve };
    const mode: Window.Mode = if (probe) .hidden else if (shot != null or offscreen) .offscreen else .visible;
    window = try Window.init(.{ .debug = builtin.mode == .Debug, .mode = mode }, &handler);
    defer window.deinit();
    window.bind("rpc", App.onRpc, &app);

    if (!probe) {
        const start = folder orelse if (app.settings.last_folder.len > 0) app.settings.last_folder else null;
        if (start) |path| app.openFolder(path) catch |err| log.warn("can't open {s}: {t}", .{ path, err });
        if (photo) |rel| if (app.folder) |*f| if (f.index(rel)) |i| app.open(i) catch {};
    }
    // Claude's way in; not for the probe or a shot, which may run beside the real app.
    var mcp: Mcp = .{ .gpa = gpa, .io = init.io, .handler = .{
        .ctx = &app,
        .call = App.onMcpCall,
        .activity = App.onMcpActivity,
        .tools = tools.definitions,
        .instructions = tools.instructions,
    } };
    if (!probe and shot == null) mcp.start() catch |err| log.warn("MCP server not started ({t}): is the app already open?", .{err});

    if (probe or shot != null) _ = Window.after(if (probe) probe_timeout_ms else shot_timeout_ms, onTimeout, &app);
    window.run();

    if (probe and app.gpu_report == null) {
        log.err("no GPU report", .{});
        return 1;
    }
    return app.exit_code;
}

fn serve(ctx: *anyopaque, request: *Window.Request) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    const path = Window.path(request);
    if (app.images.handle(request, path)) return;
    Window.fail(request, 404, "not found");
}

fn onTimeout(ctx: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(ctx));
    log.err("timed out waiting for the page", .{});
    app.exit_code = 1;
    app.window.terminate();
    return 0;
}

fn fail(text: []const u8) u8 {
    std.debug.print("{s}", .{text});
    return 2;
}
