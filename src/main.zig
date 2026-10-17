const std = @import("std");
const builtin = @import("builtin");
const core = @import("photo-core");

const Window = @import("app/window.zig");
const gpu = @import("app/gpu.zig");

const log = std.log.scoped(.doka);

// Long enough for a cold WebKit start; the page reports in well under a second when it works.
const probe_timeout_s = 15;

const App = struct {
    window: *Window,
    arena: std.mem.Allocator,
    probe: bool,
    report: ?gpu.Report = null,

    fn onGpu(id: [*:0]const u8, request: [*:0]const u8, ctx: ?*anyopaque) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(ctx));
        app.window.reply(id, "null");
        const r = gpu.parse(app.arena, std.mem.span(request)) catch |err| {
            log.err("unreadable GPU report: {t}", .{err});
            return;
        };
        app.report = r;
        const verdict = if (r.ok()) "ok" else "NOT OK";
        log.info("WebGL2 {s}: {s}", .{ verdict, r.renderer });
        log.info("float render {}, float readback {}, half float {}, float linear {}, max texture {d}", .{
            r.float_render, r.float_readback, r.half_float_render, r.float_linear, r.max_texture_size,
        });
        if (r.@"error".len > 0) log.err("{s}", .{r.@"error"});
        if (app.probe) app.window.terminate();
    }

    fn onTimeout(ctx: ?*anyopaque) callconv(.c) c_int {
        const app: *App = @ptrCast(@alignCast(ctx));
        log.err("no GPU report after {d} s", .{probe_timeout_s});
        app.window.terminate();
        return 0;
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var probe = false;
    var it = try init.minimal.args.iterateAllocator(arena);
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--probe")) probe = true;
    }

    try core.vips.init("doka");
    defer core.vips.shutdown();

    var window = try Window.init(.{ .debug = builtin.mode == .Debug, .hidden = probe });
    defer window.deinit();
    var app: App = .{ .window = &window, .arena = arena, .probe = probe };
    window.bind("reportGpu", App.onGpu, &app);
    if (probe) Window.after(probe_timeout_s, App.onTimeout, &app);
    window.run();

    if (probe) {
        const r = app.report orelse return error.NoGpuReport;
        if (!r.ok()) return error.NoFloatRenderTargets;
    }
}
