//! The app's window: webview over WebKitGTK. Everything the page loads comes from app://ui/,
//! answered by the app (`Handler`): its own files, photos, thumbnails, looks.
const std = @import("std");
const c = @import("c.zig");
const ui = @import("ui.zig");

const Window = @This();

pub const title = "Doka";
pub const width = 1440;
pub const height = 900;
pub const min_width = 960;
pub const min_height = 600;

w: c.Webview,
view: *c.WebKitWebView,

pub const Mode = enum {
    visible,
    // Never mapped: `zig build probe`.
    hidden,
    // Rendered in a GtkOffscreenWindow: `--shot`, a picture of the app off the screen.
    offscreen,
};

pub const Options = struct {
    // The inspector (right-click, Inspect) and console lines on stdout.
    debug: bool = false,
    mode: Mode = .visible,
};

/// Answers an app:// request; it must finish it (now or later) with `respond` or `fail`.
pub const Handler = struct {
    ctx: *anyopaque,
    handle: *const fn (ctx: *anyopaque, request: *Request) void,
};

pub const Request = c.WebKitURISchemeRequest;

pub fn init(options: Options, handler: *const Handler) !Window {
    // WebKit's DMA-BUF renderer kills the window on NVIDIA's driver under Wayland (Gdk "Error 71").
    // Set unless the environment already says otherwise.
    _ = c.setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "1", 0);
    // webview starts GTK itself, but the offscreen window has to exist before it.
    if (c.gtk_init_check(null, null) == 0) return error.NoDisplay;
    const parent: ?*anyopaque = if (options.mode == .offscreen) c.gtk_offscreen_window_new() else null;
    const w = c.webview_create(@intFromBool(options.debug), parent) orelse return error.NoWindow;
    _ = c.webview_set_title(w, title);
    _ = c.webview_set_size(w, min_width, min_height, c.hint_min);
    _ = c.webview_set_size(w, width, height, c.hint_none);
    const view: *c.WebKitWebView = @ptrCast(c.webview_get_native_handle(w, c.handle_browser) orelse return error.NoWebView);
    // The whole pipeline is WebGL2; never let WebKit fall back to software compositing.
    const settings = c.webkit_web_view_get_settings(view);
    c.webkit_settings_set_hardware_acceleration_policy(settings, c.hardware_acceleration_always);
    c.webkit_settings_set_enable_webgl(settings, 1);
    const context = c.webkit_web_view_get_context(view);
    const security = c.webkit_web_context_get_security_manager(context);
    c.webkit_security_manager_register_uri_scheme_as_secure(security, ui.scheme);
    c.webkit_security_manager_register_uri_scheme_as_cors_enabled(security, ui.scheme);
    c.webkit_web_context_register_uri_scheme(context, ui.scheme, serve, @constCast(handler), null);
    if (options.mode == .hidden) if (c.webview_get_window(w)) |window| c.gtk_widget_hide(window);
    // An offscreen window draws only once shown; it still never reaches the screen.
    if (parent) |p| {
        c.gtk_widget_set_size_request(p, width, height);
        c.gtk_widget_show_all(p);
    }
    _ = c.webview_navigate(w, ui.start);
    return .{ .w = w, .view = view };
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

pub fn gtkWindow(self: *Window) ?*anyopaque {
    return c.webview_get_window(self.w);
}

/// `window.<name>(...)` in the page calls `callback`, which answers with `reply`.
pub fn bind(self: *Window, name: [:0]const u8, callback: c.BindFn, ctx: *anyopaque) void {
    _ = c.webview_bind(self.w, name, callback, ctx);
}

pub fn reply(self: *Window, id: [*:0]const u8, ok: bool, json: [:0]const u8) void {
    _ = c.webview_return(self.w, id, if (ok) 0 else 1, json);
}

/// Runs JavaScript in the page. Main loop only.
pub fn eval(self: *Window, js: [:0]const u8) void {
    _ = c.webview_eval(self.w, js);
}

/// Calls `callback(ctx)` once on the main loop after `ms`; it returns 0 to not repeat.
pub fn after(ms: c_uint, callback: c.SourceFn, ctx: ?*anyopaque) c_uint {
    return c.g_timeout_add(ms, callback, ctx);
}

pub fn cancel(source: c_uint) void {
    _ = c.g_source_remove(source);
}

/// The window as a PNG, then `done(ctx, ok)`.
pub fn snapshot(self: *Window, png: [:0]const u8, done: *const fn (ctx: ?*anyopaque, ok: bool) void, ctx: ?*anyopaque) !void {
    const Shot = struct {
        view: *c.WebKitWebView,
        png: [:0]const u8,
        done: *const fn (ctx: ?*anyopaque, ok: bool) void,
        ctx: ?*anyopaque,

        fn finished(_: ?*anyopaque, result: *c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
            const shot: *@This() = @ptrCast(@alignCast(data));
            defer std.heap.c_allocator.destroy(shot);
            const surface = c.webkit_web_view_get_snapshot_finish(shot.view, result, null) orelse return shot.done(shot.ctx, false);
            defer c.cairo_surface_destroy(surface);
            shot.done(shot.ctx, c.cairo_surface_write_to_png(surface, shot.png) == 0);
        }
    };
    const shot = try std.heap.c_allocator.create(Shot);
    shot.* = .{ .view = self.view, .png = png, .done = done, .ctx = ctx };
    c.webkit_web_view_get_snapshot(self.view, c.snapshot_visible, 0, null, Shot.finished, shot);
}

/// The open-folder dialog (the desktop's own, through the portal when there is one).
pub fn chooseFolder(self: *Window, start: ?[:0]const u8) ?[*:0]u8 {
    const dialog = c.gtk_file_chooser_native_new("Open folder", self.gtkWindow(), c.chooser_select_folder, "Open", "Cancel");
    defer c.g_object_unref(dialog);
    if (start) |s| _ = c.gtk_file_chooser_set_current_folder(dialog, s);
    if (c.gtk_native_dialog_run(dialog) != c.response_accept) return null;
    return c.gtk_file_chooser_get_filename(dialog);
}

fn serve(request: *Request, ctx: ?*anyopaque) callconv(.c) void {
    const uri = std.mem.span(c.webkit_uri_scheme_request_get_uri(request));
    if (ui.find(uri)) |file| return respond(request, file.bytes, file.mime);
    const handler: *const Handler = @ptrCast(@alignCast(ctx));
    handler.handle(handler.ctx, request);
}

/// The request's path after app://ui/, e.g. "photo/trip/a.jpg" (still percent-encoded).
pub fn path(request: *Request) []const u8 {
    const uri = std.mem.span(c.webkit_uri_scheme_request_get_uri(request));
    const rest = uri[@min(uri.len, ui.base.len)..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '?') orelse rest.len];
}

/// The query string's value for `key`, if present.
pub fn query(request: *Request, key: []const u8) ?[]const u8 {
    const uri = std.mem.span(c.webkit_uri_scheme_request_get_uri(request));
    const q = uri[(std.mem.indexOfScalar(u8, uri, '?') orelse return null) + 1 ..];
    var it = std.mem.splitScalar(u8, q, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        if (std.mem.eql(u8, pair[0..eq], key)) return if (eq < pair.len) pair[eq + 1 ..] else "";
    }
    return null;
}

pub fn isPost(request: *Request) bool {
    const method = c.webkit_uri_scheme_request_get_http_method(request) orelse return false;
    return std.mem.eql(u8, std.mem.span(method), "POST");
}

/// A POST's body, read whole.
pub fn body(request: *Request, gpa: std.mem.Allocator, max: usize) ![]u8 {
    const stream = c.webkit_uri_scheme_request_get_http_body(request) orelse return gpa.alloc(u8, 0);
    defer c.g_object_unref(stream);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [1 << 16]u8 = undefined;
    while (true) {
        var got: usize = 0;
        if (c.g_input_stream_read_all(stream, &chunk, chunk.len, &got, null, null) == 0) return error.ReadFailed;
        if (out.items.len + got > max) return error.TooLarge;
        try out.appendSlice(gpa, chunk[0..got]);
        if (got < chunk.len) break;
    }
    return out.toOwnedSlice(gpa);
}

/// Finishes the request with a copy of `bytes`.
pub fn respond(request: *Request, bytes: []const u8, mime: [*:0]const u8) void {
    const copy = c.malloc(@max(bytes.len, 1)) orelse return fail(request, 500, "out of memory");
    @memcpy(copy[0..bytes.len], bytes);
    respondOwned(request, copy[0..bytes.len], mime);
}

/// Finishes the request with `bytes` from `c.malloc`, which the stream frees when done.
pub fn respondOwned(request: *Request, bytes: []u8, mime: [*:0]const u8) void {
    const stream = c.g_memory_input_stream_new_from_data(bytes.ptr, @intCast(bytes.len), c.free);
    defer c.g_object_unref(stream);
    const response = c.webkit_uri_scheme_response_new(stream, @intCast(bytes.len));
    defer c.g_object_unref(response);
    c.webkit_uri_scheme_response_set_content_type(response, mime);
    c.webkit_uri_scheme_response_set_status(response, 200, null);
    c.webkit_uri_scheme_request_finish_with_response(request, response);
}

pub fn fail(request: *Request, code: c_int, message: [*:0]const u8) void {
    const err = c.g_error_new_literal(c.g_quark_from_static_string("doka"), code, message);
    defer c.g_error_free(err);
    c.webkit_uri_scheme_request_finish_error(request, err);
}

/// Keeps a request alive past its handler, to finish it from a background task.
pub fn hold(request: *Request) void {
    _ = c.g_object_ref(request);
}

pub fn release(request: *Request) void {
    c.g_object_unref(request);
}
