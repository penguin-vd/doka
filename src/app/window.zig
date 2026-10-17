//! The app's window: webview over WebKitGTK, its page served from memory at app://ui/.
const std = @import("std");
const c = @import("c.zig");
const ui = @import("ui.zig");

const Window = @This();

pub const title = "Doka";
pub const width = 1440;
pub const height = 900;

w: c.Webview,

pub const Options = struct {
    // The inspector (right-click, Inspect) and console lines on stdout.
    debug: bool = false,
    // `zig build probe` checks the GPU without a window on screen.
    hidden: bool = false,
};

pub fn init(options: Options) !Window {
    // WebKit's DMA-BUF renderer kills the window on NVIDIA's driver under Wayland (Gdk "Error 71").
    // Set unless the environment already says otherwise.
    _ = c.setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "1", 0);
    const w = c.webview_create(@intFromBool(options.debug), null) orelse return error.NoWindow;
    _ = c.webview_set_title(w, title);
    _ = c.webview_set_size(w, width, height, c.hint_none);
    const view: *c.WebKitWebView = @ptrCast(c.webview_get_native_handle(w, c.handle_browser) orelse return error.NoWebView);
    // The whole pipeline is WebGL2; never let WebKit fall back to software compositing.
    const settings = c.webkit_web_view_get_settings(view);
    c.webkit_settings_set_hardware_acceleration_policy(settings, c.hardware_acceleration_always);
    c.webkit_settings_set_enable_webgl(settings, 1);
    c.webkit_web_context_register_uri_scheme(c.webkit_web_view_get_context(view), ui.scheme, serve, null, null);
    if (options.hidden) if (c.webview_get_window(w)) |window| c.gtk_widget_hide(window);
    _ = c.webview_navigate(w, ui.start);
    return .{ .w = w };
}

pub fn deinit(self: *Window) void {
    _ = c.webview_destroy(self.w);
}

pub fn run(self: *Window) void {
    _ = c.webview_run(self.w);
}

pub fn terminate(self: *Window) void {
    _ = c.webview_terminate(self.w);
}

/// `window.<name>(...)` in the page calls `callback`, which answers with `reply`.
pub fn bind(self: *Window, name: [:0]const u8, callback: c.BindFn, ctx: *anyopaque) void {
    _ = c.webview_bind(self.w, name, callback, ctx);
}

pub fn reply(self: *Window, id: [*:0]const u8, json: [:0]const u8) void {
    _ = c.webview_return(self.w, id, 0, json);
}

/// Calls `callback(ctx)` once on the main loop after `seconds`; it returns 0 to not repeat.
pub fn after(seconds: c_uint, callback: c.SourceFn, ctx: *anyopaque) void {
    _ = c.g_timeout_add_seconds(seconds, callback, ctx);
}

fn serve(request: *c.WebKitURISchemeRequest, _: ?*anyopaque) callconv(.c) void {
    const uri = std.mem.span(c.webkit_uri_scheme_request_get_uri(request));
    const file = ui.find(uri) orelse {
        const err = c.g_error_new_literal(c.g_quark_from_static_string("doka"), 404, "not found");
        defer c.g_error_free(err);
        c.webkit_uri_scheme_request_finish_error(request, err);
        return;
    };
    const stream = c.g_memory_input_stream_new_from_data(file.bytes.ptr, @intCast(file.bytes.len), null);
    defer c.g_object_unref(stream);
    c.webkit_uri_scheme_request_finish(request, stream, @intCast(file.bytes.len), file.mime);
}
