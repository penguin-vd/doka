//! A camera JPEG to linear light for the GPU: the embedded ICC profile (sRGB when there is none)
//! to linear Rec.709 primaries (libvips' scRGB), as half floats, RGB interleaved, upright.
const std = @import("std");
const vips = @import("vips.zig");
const c = vips.c;

pub const Linear = struct {
    width: u32,
    height: u32,
    // Upright size of the original, before any shrinking.
    full_width: u32,
    full_height: u32,
    // f16 bit patterns, width * height * 3; WebGL's HALF_FLOAT takes them as a Uint16Array.
    rgb: []u16,

    pub fn deinit(self: *Linear, gpa: std.mem.Allocator) void {
        gpa.free(self.rgb);
    }
};

/// The photo at `long_edge` pixels on its longest side (never enlarged), or full size for 0.
pub fn linear(gpa: std.mem.Allocator, path: [:0]const u8, long_edge: u32) !Linear {
    const header = c.vips_image_new_from_file(path, "access", vips.access_sequential, vips.end) orelse return vips.fail();
    const orientation = vips.int(header, "orientation") orelse 1;
    const sideways = orientation >= 5 and orientation <= 8;
    const full_w = if (sideways) vips.height(header) else vips.width(header);
    const full_h = if (sideways) vips.width(header) else vips.height(header);
    vips.unref(header);

    // JPEG shrink-on-load does most of the work for a preview: 1/2, 1/4 or 1/8 while decoding.
    const longest = @max(full_w, full_h);
    var shrink: c_int = 1;
    while (long_edge > 0 and shrink < 8 and longest / @as(u32, @intCast(shrink * 2)) >= long_edge) shrink *= 2;
    var out: ?*vips.Image = null;
    try vips.check(c.vips_jpegload(path, &out, "shrink", shrink, vips.end));
    var img = out.?;
    img = try vips.step(img, c.vips_autorot, .{});
    img = try toScrgb(img);
    defer vips.unref(img);
    // Resized in linear light, so fine detail keeps its brightness.
    const now_long = @max(vips.width(img), vips.height(img));
    if (long_edge > 0 and now_long > long_edge) {
        const scale = @as(f64, @floatFromInt(long_edge)) / @as(f64, @floatFromInt(now_long));
        img = try vips.step(img, c.vips_resize, .{scale});
    }

    const floats = try vips.toMemory(img);
    defer vips.freeMemory(floats);
    const src: []align(1) const f32 = std.mem.bytesAsSlice(f32, floats);
    const rgb = try gpa.alloc(u16, src.len);
    for (src, rgb) |v, *h| h.* = @bitCast(@as(f16, @floatCast(v)));
    return .{ .width = vips.width(img), .height = vips.height(img), .full_width = full_w, .full_height = full_h, .rgb = rgb };
}

/// Any decoded JPEG to 3-band float scRGB, through its embedded profile when it has one.
pub fn toScrgb(in: *vips.Image) !*vips.Image {
    var img = in;
    if (vips.has(img, "icc-profile-data")) {
        img = try vips.step(img, c.vips_icc_import, .{ "embedded", @as(c_int, 1), "pcs", vips.pcs_xyz, "intent", vips.intent_relative });
    } else if (vips.bands(img) < 3) {
        img = try vips.step(img, c.vips_colourspace, .{vips.Interpretation.srgb});
    }
    return vips.step(img, c.vips_colourspace, .{vips.Interpretation.scrgb});
}

/// Camera and exposure, for the app and Claude: "OLYMPUS E-P7 · M.14-42mm · 1/200 s f/5.6 ISO 200".
pub const Info = struct {
    make: []const u8 = "",
    model: []const u8 = "",
    lens: []const u8 = "",
    exposure: []const u8 = "",
    aperture: []const u8 = "",
    iso: []const u8 = "",
    focal_length: []const u8 = "",
    taken: []const u8 = "",
    width: u32 = 0,
    height: u32 = 0,
};

pub fn info(arena: std.mem.Allocator, path: [:0]const u8) !Info {
    const img = c.vips_image_new_from_file(path, "access", vips.access_sequential, vips.end) orelse return vips.fail();
    defer vips.unref(img);
    const orientation = vips.int(img, "orientation") orelse 1;
    const sideways = orientation >= 5 and orientation <= 8;
    const field = struct {
        fn get(a: std.mem.Allocator, i: *vips.Image, names: []const [*:0]const u8) ![]const u8 {
            for (names) |n| if (vips.string(i, n)) |s| return a.dupe(u8, s);
            return "";
        }
    }.get;
    return .{
        .make = try field(arena, img, &.{"exif-ifd0-Make"}),
        .model = try field(arena, img, &.{"exif-ifd0-Model"}),
        .lens = try field(arena, img, &.{"exif-ifd2-LensModel"}),
        .exposure = try field(arena, img, &.{"exif-ifd2-ExposureTime"}),
        .aperture = try field(arena, img, &.{"exif-ifd2-FNumber"}),
        .iso = try field(arena, img, &.{ "exif-ifd2-ISOSpeedRatings", "exif-ifd2-PhotographicSensitivity" }),
        .focal_length = try field(arena, img, &.{"exif-ifd2-FocalLength"}),
        .taken = try field(arena, img, &.{ "exif-ifd2-DateTimeOriginal", "exif-ifd0-DateTime" }),
        .width = if (sideways) vips.height(img) else vips.width(img),
        .height = if (sideways) vips.width(img) else vips.height(img),
    };
}

/// A small upright sRGB JPEG for the folder grid, `size` pixels on its longest side.
/// Free with `vips.freeMemory`.
pub fn thumbnail(path: [:0]const u8, size: u32) ![]u8 {
    var out: ?*vips.Image = null;
    try vips.check(c.vips_thumbnail(path, &out, @as(c_int, @intCast(size)), "height", @as(c_int, @intCast(size)), "size", vips.size_down, vips.end));
    defer vips.unref(out.?);
    var buf: ?[*]u8 = null;
    var len: usize = 0;
    try vips.check(c.vips_image_write_to_buffer(out.?, ".jpg", &buf, &len, "Q", @as(c_int, 82), "keep", vips.keep_none, vips.end));
    return buf.?[0..len];
}
