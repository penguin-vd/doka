//! libvips, started once per process. Its C API is declared here by hand, only what we call:
//! Zig 0.16's translate-c can't read GLib's headers. Optional arguments are C varargs, name then
//! value, ended by a null; ints go as `c_int`, booleans as `c_int`, doubles as `f64`.
const std = @import("std");

const log = std.log.scoped(.vips);

pub const Image = opaque {};
pub const Blob = opaque {};

pub const Version = struct { major: c_int, minor: c_int };

// VipsBandFormat
pub const Format = enum(c_int) { uchar = 0, ushort = 2, float = 6 };
// VipsInterpretation
pub const Interpretation = enum(c_int) { b_w = 1, srgb = 22, rgb16 = 25, scrgb = 28 };
pub const access_sequential: c_int = 1;
pub const pcs_xyz: c_int = 1;
pub const intent_relative: c_int = 1;
pub const size_down: c_int = 2;
pub const keep_none: c_int = 0;
pub const keep_xmp: c_int = 1 << 1;
pub const keep_iptc: c_int = 1 << 2;
pub const keep_icc: c_int = 1 << 3;

pub const end: ?*anyopaque = null;

pub fn init(argv0: [*:0]const u8) error{VipsInit}!void {
    // The openslide module is optional and usually missing; its load warning is noise.
    _ = c.g_log_set_handler("VIPS", log_warning, onWarning, null);
    if (c.vips_init(argv0) != 0) return error.VipsInit;
    // libvips keeps recent operations' results to reuse; this app never asks twice, and the cache
    // would hold decoded photos (hundreds of MB) for nothing.
    c.vips_cache_set_max(0);
    c.vips_cache_set_max_mem(0);
}

// libvips can't start again after this, so only at exit.
pub fn shutdown() void {
    c.vips_shutdown();
}

pub fn version() Version {
    return .{ .major = c.vips_version(0), .minor = c.vips_version(1) };
}

/// Turns a libvips failure into `error.Vips`, logging its message.
pub fn check(result: c_int) error{Vips}!void {
    if (result == 0) return;
    const message = std.mem.trimEnd(u8, std.mem.span(c.vips_error_buffer()), "\n");
    log.err("{s}", .{message});
    c.vips_error_clear();
    return error.Vips;
}

/// The error for a libvips call that returned null, logging its message.
pub fn fail() error{Vips} {
    check(-1) catch |err| return err;
    unreachable;
}

pub fn unref(image: *Image) void {
    c.g_object_unref(image);
}

pub fn width(image: *Image) u32 {
    return @intCast(c.vips_image_get_width(image));
}

pub fn height(image: *Image) u32 {
    return @intCast(c.vips_image_get_height(image));
}

pub fn bands(image: *Image) u32 {
    return @intCast(c.vips_image_get_bands(image));
}

pub fn has(image: *Image, name: [*:0]const u8) bool {
    return c.vips_image_get_typeof(image, name) != 0;
}

/// A string field, or one EXIF tag's text up to its parenthesised details ("1/200 (1/200 sec., ...").
pub fn string(image: *Image, name: [*:0]const u8) ?[]const u8 {
    if (!has(image, name)) return null;
    var out: [*:0]const u8 = undefined;
    if (c.vips_image_get_string(image, name, &out) != 0) {
        c.vips_error_clear();
        return null;
    }
    const s = std.mem.span(out);
    return std.mem.trim(u8, s[0 .. std.mem.indexOf(u8, s, " (") orelse s.len], " ");
}

pub fn int(image: *Image, name: [*:0]const u8) ?c_int {
    if (!has(image, name)) return null;
    var out: c_int = 0;
    if (c.vips_image_get_int(image, name, &out) != 0) {
        c.vips_error_clear();
        return null;
    }
    return out;
}

pub fn blob(image: *Image, name: [*:0]const u8) ?[]const u8 {
    if (!has(image, name)) return null;
    var data: [*]const u8 = undefined;
    var len: usize = 0;
    if (c.vips_image_get_blob(image, name, &data, &len) != 0) {
        c.vips_error_clear();
        return null;
    }
    return data[0..len];
}

/// The image's pixels, copied out; free with `freeMemory`.
pub fn toMemory(image: *Image) error{Vips}![]u8 {
    var len: usize = 0;
    const data = c.vips_image_write_to_memory(image, &len) orelse return fail();
    return data[0..len];
}

pub fn freeMemory(bytes: []u8) void {
    c.g_free(bytes.ptr);
}

/// The names of every field on the image, built-in ones included.
pub fn fieldNames(gpa: std.mem.Allocator, image: *Image) ![][]const u8 {
    const names = c.vips_image_get_fields(image);
    defer c.g_strfreev(names);
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |n| gpa.free(n);
        list.deinit(gpa);
    }
    var i: usize = 0;
    while (names[i]) |name| : (i += 1) try list.append(gpa, try gpa.dupe(u8, std.mem.span(name)));
    return list.toOwnedSlice(gpa);
}

/// One of libvips' built-in ICC profiles ("srgb", "p3"), owned by libvips for the process.
pub fn profile(name: [*:0]const u8) error{Vips}![]const u8 {
    var b: ?*Blob = null;
    try check(c.vips_profile_load(name, &b, end));
    var len: usize = 0;
    const data: [*]const u8 = @ptrCast(c.vips_area_get_data(b.?, &len, null, null, null));
    // Kept: the profile is small, there are two, and callers hold the slice.
    return data[0..len];
}

pub const c = struct {
    pub const MapFn = *const fn (image: *Image, name: [*:0]const u8, value: *anyopaque, ctx: ?*anyopaque) callconv(.c) ?*anyopaque;
    const LogFn = *const fn (domain: ?[*:0]const u8, level: c_int, message: [*:0]const u8, ctx: ?*anyopaque) callconv(.c) void;

    extern fn vips_init(argv0: [*:0]const u8) c_int;
    extern fn vips_shutdown() void;
    extern fn vips_version(flag: c_int) c_int;
    extern fn vips_cache_set_max(max: c_int) void;
    extern fn vips_cache_set_max_mem(max: usize) void;
    extern fn vips_error_buffer() [*:0]const u8;
    extern fn vips_error_clear() void;

    pub extern fn vips_image_new_from_file(name: [*:0]const u8, ...) ?*Image;
    pub extern fn vips_image_new_from_memory_copy(data: *const anyopaque, size: usize, width: c_int, height: c_int, bands: c_int, format: Format) ?*Image;
    extern fn vips_image_write_to_memory(image: *Image, size: *usize) ?[*]u8;
    pub extern fn vips_image_write_to_buffer(image: *Image, suffix: [*:0]const u8, buf: *?[*]u8, size: *usize, ...) c_int;
    extern fn vips_image_get_width(image: *Image) c_int;
    extern fn vips_image_get_height(image: *Image) c_int;
    extern fn vips_image_get_bands(image: *Image) c_int;
    pub extern fn vips_image_get_interpretation(image: *Image) c_int;
    extern fn vips_image_get_typeof(image: *Image, name: [*:0]const u8) usize;
    pub extern fn vips_image_get_string(image: *Image, name: [*:0]const u8, out: *[*:0]const u8) c_int;
    extern fn vips_image_get_int(image: *Image, name: [*:0]const u8, out: *c_int) c_int;
    extern fn vips_image_get_blob(image: *Image, name: [*:0]const u8, data: *[*]const u8, len: *usize) c_int;
    extern fn vips_image_get_fields(image: *Image) [*:null]?[*:0]u8;
    pub extern fn vips_image_set(image: *Image, name: [*:0]const u8, value: *anyopaque) void;
    pub extern fn vips_image_get_xres(image: *Image) f64;
    pub extern fn vips_image_get_yres(image: *Image) f64;
    pub extern fn vips_image_set_string(image: *Image, name: [*:0]const u8, value: [*:0]const u8) void;
    pub extern fn vips_image_set_int(image: *Image, name: [*:0]const u8, value: c_int) void;
    pub extern fn vips_image_set_blob_copy(image: *Image, name: [*:0]const u8, data: *const anyopaque, len: usize) void;
    pub extern fn vips_image_remove(image: *Image, name: [*:0]const u8) c_int;
    pub extern fn vips_image_map(image: *Image, f: MapFn, ctx: ?*anyopaque) ?*anyopaque;
    extern fn vips_profile_load(name: [*:0]const u8, out: *?*Blob, ...) c_int;
    extern fn vips_area_get_data(area: *Blob, len: *usize, n: ?*c_int, ty: ?*usize, sizeof_type: ?*usize) ?*anyopaque;

    pub extern fn vips_jpegload(filename: [*:0]const u8, out: *?*Image, ...) c_int;
    pub extern fn vips_thumbnail(filename: [*:0]const u8, out: *?*Image, width: c_int, ...) c_int;
    pub extern fn vips_autorot(image: *Image, out: *?*Image, ...) c_int;
    pub extern fn vips_resize(image: *Image, out: *?*Image, scale: f64, ...) c_int;
    pub extern fn vips_icc_import(image: *Image, out: *?*Image, ...) c_int;
    pub extern fn vips_colourspace(image: *Image, out: *?*Image, space: Interpretation, ...) c_int;
    pub extern fn vips_copy(image: *Image, out: *?*Image, ...) c_int;
    pub extern fn vips_extract_band(image: *Image, out: *?*Image, band: c_int, ...) c_int;

    extern fn g_object_unref(object: *anyopaque) void;
    extern fn g_free(mem: ?*anyopaque) void;
    extern fn g_strfreev(list: [*:null]?[*:0]u8) void;
    extern fn g_log_set_handler(domain: [*:0]const u8, levels: c_int, f: LogFn, ctx: ?*anyopaque) c_uint;
};

// G_LOG_LEVEL_WARNING
const log_warning: c_int = 1 << 4;

fn onWarning(_: ?[*:0]const u8, _: c_int, message: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
    const m = std.mem.span(message);
    if (std.mem.indexOf(u8, m, "vips-modules") != null) return;
    log.warn("{s}", .{m});
}

/// Runs a libvips operation that makes one new image from `in`, taking `in`'s reference:
/// `img = try step(img, c.vips_autorot, .{})`.
pub fn step(in: *Image, op: anytype, args: anytype) error{Vips}!*Image {
    defer unref(in);
    var out: ?*Image = null;
    try check(@call(.auto, op, .{ in, &out } ++ args ++ .{end}));
    return out.?;
}
