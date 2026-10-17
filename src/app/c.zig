//! The C we call for the window, declared by hand: webview, and the WebKitGTK, GTK, GLib and cairo
//! calls webview doesn't wrap. Zig 0.16's translate-c can't read GLib's headers. Add a declaration
//! when you need one, checked against /usr/include/webkitgtk-4.1 and glib-2.0.

pub const Webview = *opaque {};
pub const WebKitWebView = opaque {};
pub const WebKitSettings = opaque {};
pub const WebKitWebContext = opaque {};
pub const WebKitSecurityManager = opaque {};
pub const WebKitURISchemeRequest = opaque {};
pub const WebKitURISchemeResponse = opaque {};
pub const GInputStream = opaque {};
pub const GError = extern struct { domain: u32, code: c_int, message: [*:0]const u8 };
pub const GFile = opaque {};
pub const GFileMonitor = opaque {};
pub const GAsyncResult = opaque {};
pub const CairoSurface = opaque {};

pub const BindFn = *const fn (id: [*:0]const u8, request: [*:0]const u8, ctx: ?*anyopaque) callconv(.c) void;
pub const SchemeFn = *const fn (request: *WebKitURISchemeRequest, ctx: ?*anyopaque) callconv(.c) void;
pub const SourceFn = *const fn (ctx: ?*anyopaque) callconv(.c) c_int;
pub const DestroyFn = *const fn (data: ?*anyopaque) callconv(.c) void;
pub const AsyncFn = *const fn (source: ?*anyopaque, result: *GAsyncResult, ctx: ?*anyopaque) callconv(.c) void;
pub const MonitorFn = *const fn (monitor: *GFileMonitor, file: *GFile, other: ?*GFile, event: c_int, ctx: ?*anyopaque) callconv(.c) void;

// webview_native_handle_kind_t
pub const handle_window = 0;
pub const handle_browser = 2;
pub const hint_none = 0;
pub const hint_min = 1;
// WebKitHardwareAccelerationPolicy: ON_DEMAND, ALWAYS, NEVER
pub const hardware_acceleration_always = 1;
// GtkFileChooserAction: OPEN, SAVE, SELECT_FOLDER
pub const chooser_select_folder = 2;
pub const response_accept = -3;
// WebKitSnapshotRegion: VISIBLE, FULL_DOCUMENT
pub const snapshot_visible = 0;
// GFileMonitorFlags: WATCH_MOVES
pub const monitor_watch_moves = 1 << 3;
pub const g_source_remove_value = 0;
pub const g_source_continue_value = 1;

pub extern fn webview_create(debug: c_int, window: ?*anyopaque) ?Webview;
pub extern fn webview_destroy(w: Webview) c_int;
pub extern fn webview_run(w: Webview) c_int;
pub extern fn webview_terminate(w: Webview) c_int;
pub extern fn webview_get_window(w: Webview) ?*anyopaque;
pub extern fn webview_get_native_handle(w: Webview, kind: c_int) ?*anyopaque;
pub extern fn webview_set_title(w: Webview, title: [*:0]const u8) c_int;
pub extern fn webview_set_size(w: Webview, width: c_int, height: c_int, hint: c_int) c_int;
pub extern fn webview_navigate(w: Webview, url: [*:0]const u8) c_int;
pub extern fn webview_eval(w: Webview, js: [*:0]const u8) c_int;
pub extern fn webview_bind(w: Webview, name: [*:0]const u8, f: BindFn, ctx: ?*anyopaque) c_int;
pub extern fn webview_return(w: Webview, id: [*:0]const u8, status: c_int, result: [*:0]const u8) c_int;

pub extern fn webkit_web_view_get_settings(view: *WebKitWebView) *WebKitSettings;
pub extern fn webkit_web_view_get_context(view: *WebKitWebView) *WebKitWebContext;
pub extern fn webkit_web_view_get_snapshot(view: *WebKitWebView, region: c_int, options: c_int, cancellable: ?*anyopaque, f: AsyncFn, ctx: ?*anyopaque) void;
pub extern fn webkit_web_view_get_snapshot_finish(view: *WebKitWebView, result: *GAsyncResult, err: ?*?*GError) ?*CairoSurface;
pub extern fn webkit_settings_set_hardware_acceleration_policy(settings: *WebKitSettings, policy: c_int) void;
pub extern fn webkit_settings_set_enable_webgl(settings: *WebKitSettings, enabled: c_int) void;
pub extern fn webkit_web_context_register_uri_scheme(ctx: *WebKitWebContext, scheme: [*:0]const u8, f: SchemeFn, data: ?*anyopaque, destroy: ?DestroyFn) void;
pub extern fn webkit_web_context_get_security_manager(ctx: *WebKitWebContext) *WebKitSecurityManager;
pub extern fn webkit_security_manager_register_uri_scheme_as_secure(sm: *WebKitSecurityManager, scheme: [*:0]const u8) void;
pub extern fn webkit_security_manager_register_uri_scheme_as_cors_enabled(sm: *WebKitSecurityManager, scheme: [*:0]const u8) void;
pub extern fn webkit_uri_scheme_request_get_uri(request: *WebKitURISchemeRequest) [*:0]const u8;
pub extern fn webkit_uri_scheme_request_get_path(request: *WebKitURISchemeRequest) [*:0]const u8;
pub extern fn webkit_uri_scheme_request_get_http_method(request: *WebKitURISchemeRequest) ?[*:0]const u8;
pub extern fn webkit_uri_scheme_request_get_http_body(request: *WebKitURISchemeRequest) ?*GInputStream;
pub extern fn webkit_uri_scheme_request_finish_error(request: *WebKitURISchemeRequest, err: *GError) void;
pub extern fn webkit_uri_scheme_request_finish_with_response(request: *WebKitURISchemeRequest, response: *WebKitURISchemeResponse) void;
pub extern fn webkit_uri_scheme_response_new(stream: *GInputStream, length: i64) *WebKitURISchemeResponse;
pub extern fn webkit_uri_scheme_response_set_content_type(response: *WebKitURISchemeResponse, mime: [*:0]const u8) void;
pub extern fn webkit_uri_scheme_response_set_status(response: *WebKitURISchemeResponse, code: c_uint, reason: ?[*:0]const u8) void;

pub extern fn gtk_init_check(argc: ?*c_int, argv: ?*anyopaque) c_int;
pub extern fn gtk_widget_hide(widget: *anyopaque) void;
pub extern fn gtk_widget_show_all(widget: *anyopaque) void;
pub extern fn gtk_widget_set_size_request(widget: *anyopaque, width: c_int, height: c_int) void;
pub extern fn gtk_offscreen_window_new() *anyopaque;
pub extern fn gtk_file_chooser_native_new(title: [*:0]const u8, parent: ?*anyopaque, action: c_int, accept: ?[*:0]const u8, cancel: ?[*:0]const u8) *anyopaque;
pub extern fn gtk_native_dialog_run(dialog: *anyopaque) c_int;
pub extern fn gtk_file_chooser_get_filename(chooser: *anyopaque) ?[*:0]u8;
pub extern fn gtk_file_chooser_set_current_folder(chooser: *anyopaque, folder: [*:0]const u8) c_int;

pub extern fn g_memory_input_stream_new_from_data(data: ?*const anyopaque, len: isize, destroy: ?DestroyFn) *GInputStream;
pub extern fn g_input_stream_read_all(stream: *GInputStream, buffer: [*]u8, count: usize, read: *usize, cancellable: ?*anyopaque, err: ?*?*GError) c_int;
pub extern fn g_object_ref(object: *anyopaque) *anyopaque;
pub extern fn g_object_unref(object: *anyopaque) void;
pub extern fn g_quark_from_static_string(s: [*:0]const u8) u32;
pub extern fn g_error_new_literal(domain: u32, code: c_int, message: [*:0]const u8) *GError;
pub extern fn g_error_free(err: *GError) void;
pub extern fn g_free(mem: ?*anyopaque) void;
pub extern fn g_timeout_add(ms: c_uint, f: SourceFn, ctx: ?*anyopaque) c_uint;
pub extern fn g_timeout_add_seconds(seconds: c_uint, f: SourceFn, ctx: ?*anyopaque) c_uint;
pub extern fn g_idle_add(f: SourceFn, ctx: ?*anyopaque) c_uint;
pub extern fn g_source_remove(id: c_uint) c_int;
pub extern fn g_file_new_for_path(path: [*:0]const u8) *GFile;
pub extern fn g_file_monitor_directory(file: *GFile, flags: c_int, cancellable: ?*anyopaque, err: ?*?*GError) ?*GFileMonitor;
pub extern fn g_file_get_path(file: *GFile) ?[*:0]u8;
pub extern fn g_signal_connect_data(instance: *anyopaque, signal: [*:0]const u8, handler: *const anyopaque, data: ?*anyopaque, destroy: ?*const anyopaque, flags: c_int) c_ulong;

pub extern fn cairo_surface_write_to_png(surface: *CairoSurface, filename: [*:0]const u8) c_int;
pub extern fn cairo_surface_destroy(surface: *CairoSurface) void;

pub extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
pub extern fn malloc(size: usize) ?[*]u8;
pub extern fn free(ptr: ?*anyopaque) void;
