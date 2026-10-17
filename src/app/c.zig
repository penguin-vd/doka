//! The C we call for the window, declared by hand: webview, and the few WebKitGTK, GTK and GLib
//! calls webview doesn't wrap. Zig 0.16's translate-c can't read GLib's headers.

pub const Webview = *opaque {};
pub const WebKitWebView = opaque {};
pub const WebKitSettings = opaque {};
pub const WebKitWebContext = opaque {};
pub const WebKitURISchemeRequest = opaque {};
pub const GInputStream = opaque {};
pub const GError = opaque {};

pub const BindFn = *const fn (id: [*:0]const u8, request: [*:0]const u8, ctx: ?*anyopaque) callconv(.c) void;
pub const SchemeFn = *const fn (request: *WebKitURISchemeRequest, ctx: ?*anyopaque) callconv(.c) void;
pub const SourceFn = *const fn (ctx: ?*anyopaque) callconv(.c) c_int;

// webview_native_handle_kind_t
pub const handle_window = 0;
pub const handle_browser = 2;
pub const hint_none = 0;
// WebKitHardwareAccelerationPolicy: ON_DEMAND, ALWAYS, NEVER
pub const hardware_acceleration_always = 1;

pub extern fn webview_create(debug: c_int, window: ?*anyopaque) ?Webview;
pub extern fn webview_destroy(w: Webview) c_int;
pub extern fn webview_run(w: Webview) c_int;
pub extern fn webview_terminate(w: Webview) c_int;
pub extern fn webview_get_window(w: Webview) ?*anyopaque;
pub extern fn webview_get_native_handle(w: Webview, kind: c_int) ?*anyopaque;
pub extern fn webview_set_title(w: Webview, title: [*:0]const u8) c_int;
pub extern fn webview_set_size(w: Webview, width: c_int, height: c_int, hint: c_int) c_int;
pub extern fn webview_navigate(w: Webview, url: [*:0]const u8) c_int;
pub extern fn webview_bind(w: Webview, name: [*:0]const u8, f: BindFn, ctx: ?*anyopaque) c_int;
pub extern fn webview_return(w: Webview, id: [*:0]const u8, status: c_int, result: [*:0]const u8) c_int;

pub extern fn webkit_web_view_get_settings(view: *WebKitWebView) *WebKitSettings;
pub extern fn webkit_web_view_get_context(view: *WebKitWebView) *WebKitWebContext;
pub extern fn webkit_settings_set_hardware_acceleration_policy(settings: *WebKitSettings, policy: c_int) void;
pub extern fn webkit_settings_set_enable_webgl(settings: *WebKitSettings, enabled: c_int) void;
pub extern fn webkit_web_context_register_uri_scheme(ctx: *WebKitWebContext, scheme: [*:0]const u8, f: SchemeFn, data: ?*anyopaque, destroy: ?*const anyopaque) void;
pub extern fn webkit_uri_scheme_request_get_uri(request: *WebKitURISchemeRequest) [*:0]const u8;
pub extern fn webkit_uri_scheme_request_finish(request: *WebKitURISchemeRequest, stream: *GInputStream, length: i64, mime: [*:0]const u8) void;
pub extern fn webkit_uri_scheme_request_finish_error(request: *WebKitURISchemeRequest, err: *GError) void;

pub extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
pub extern fn gtk_widget_hide(widget: *anyopaque) void;
pub extern fn g_memory_input_stream_new_from_data(data: [*]const u8, len: isize, destroy: ?*const anyopaque) *GInputStream;
pub extern fn g_object_unref(object: *anyopaque) void;
pub extern fn g_quark_from_static_string(s: [*:0]const u8) u32;
pub extern fn g_error_new_literal(domain: u32, code: c_int, message: [*:0]const u8) *GError;
pub extern fn g_error_free(err: *GError) void;
pub extern fn g_timeout_add_seconds(seconds: c_uint, f: SourceFn, ctx: ?*anyopaque) c_uint;
