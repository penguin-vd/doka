//! Rendered pixels to a file, with the original's metadata: its EXIF block byte for byte (see
//! exif.zig), XMP and IPTC copied, the output's ICC profile embedded. GPS goes only when asked.
//! The original is never written: `save` refuses to write over its source.
const std = @import("std");
const Io = std.Io;
const vips = @import("vips.zig");
const exif = @import("exif.zig");
const c = vips.c;

pub const Format = enum {
    jpeg,
    // 16 bits, so a pushed edit doesn't band. TIFF isn't offered: libvips' TIFF writer drops EXIF
    // fields, and an export never loses metadata.
    png,

    pub fn extension(f: Format) []const u8 {
        return switch (f) {
            .jpeg => ".jpg",
            .png => ".png",
        };
    }

    pub fn bits(f: Format) u8 {
        return if (f == .jpeg) 8 else 16;
    }
};

pub const Space = enum {
    srgb,
    p3,

    fn profileName(s: Space) [*:0]const u8 {
        return switch (s) {
            .srgb => "srgb",
            .p3 => "p3",
        };
    }

    fn exifColourSpace(s: Space) u16 {
        return switch (s) {
            .srgb => 1,
            .p3 => 0xFFFF,
        };
    }
};

pub const Options = struct {
    format: Format = .jpeg,
    quality: u8 = 90,
    // Longest side in pixels; 0 keeps the rendered size.
    long_edge: u32 = 0,
    keep_metadata: bool = true,
    keep_gps: bool = true,
    space: Space = .srgb,
};

/// Display-encoded RGB in `Options.space`, interleaved, at `format.bits()` per channel.
pub const Pixels = struct {
    width: u32,
    height: u32,
    data: union(enum) {
        u8: []const u8,
        u16: []const u16,
    },
};

pub fn save(io: Io, gpa: std.mem.Allocator, source: [:0]const u8, pixels: Pixels, options: Options, out_path: [:0]const u8) !void {
    if (samePath(source, out_path)) return error.WouldOverwriteOriginal;
    const bytes: []const u8, const format: vips.Format = switch (pixels.data) {
        .u8 => |d| .{ d, .uchar },
        .u16 => |d| .{ std.mem.sliceAsBytes(d), .ushort },
    };
    if (bytes.len != @as(usize, pixels.width) * pixels.height * 3 * @as(usize, if (format == .uchar) 1 else 2)) return error.BadPixels;
    if ((format == .uchar) != (options.format.bits() == 8)) return error.BadPixels;

    const src = c.vips_image_new_from_file(source, "access", vips.access_sequential, vips.end) orelse return vips.fail();
    defer vips.unref(src);
    var img = c.vips_image_new_from_memory_copy(bytes.ptr, bytes.len, @intCast(pixels.width), @intCast(pixels.height), 3, format) orelse return vips.fail();
    img = try vips.step(img, c.vips_copy, .{
        "interpretation", @intFromEnum(if (format == .uchar) vips.Interpretation.srgb else vips.Interpretation.rgb16),
        "xres",           c.vips_image_get_xres(src),
        "yres",           c.vips_image_get_yres(src),
    });
    const longest = @max(pixels.width, pixels.height);
    if (options.long_edge > 0 and longest > options.long_edge) {
        const scale = @as(f64, @floatFromInt(options.long_edge)) / @as(f64, @floatFromInt(longest));
        img = try vips.step(img, c.vips_resize, .{scale});
    }
    defer vips.unref(img);

    if (options.keep_metadata) {
        if (vips.blob(src, "iptc-data")) |iptc| c.vips_image_set_blob_copy(img, "iptc-data", iptc.ptr, iptc.len);
        if (vips.blob(src, "xmp-data")) |xmp| {
            const clean = try cleanXmp(gpa, xmp, options.keep_gps);
            defer gpa.free(clean);
            c.vips_image_set_blob_copy(img, "xmp-data", clean.ptr, clean.len);
        }
    }
    const icc = try vips.profile(options.space.profileName());
    c.vips_image_set_blob_copy(img, "icc-profile-data", icc.ptr, icc.len);

    // libvips writes everything but EXIF; the EXIF block goes in afterwards, untouched by libexif.
    const keep = if (options.keep_metadata) vips.keep_xmp | vips.keep_iptc | vips.keep_icc else vips.keep_icc;
    var buf: ?[*]u8 = null;
    var len: usize = 0;
    try vips.check(switch (options.format) {
        .jpeg => c.vips_image_write_to_buffer(img, ".jpg", &buf, &len, "Q", @as(c_int, options.quality), "optimize_coding", @as(c_int, 1), "keep", keep, vips.end),
        .png => c.vips_image_write_to_buffer(img, ".png", &buf, &len, "compression", @as(c_int, 6), "keep", keep, vips.end),
    });
    const encoded = buf.?[0..len];
    defer vips.freeMemory(encoded);

    var file: []const u8 = encoded;
    var spliced: ?[]u8 = null;
    defer if (spliced) |sp| gpa.free(sp);
    if (options.keep_metadata) if (vips.blob(src, "exif-data")) |original| {
        const tiff = try exif.prepare(gpa, original, .{
            .width = vips.width(img),
            .height = vips.height(img),
            .colour_space = options.space.exifColourSpace(),
            .keep_gps = options.keep_gps,
        });
        defer gpa.free(tiff);
        spliced = switch (options.format) {
            .jpeg => try exif.intoJpeg(gpa, encoded, tiff),
            .png => try exif.intoPng(gpa, encoded, tiff),
        };
        file = spliced.?;
    };

    const tmp = try std.fmt.allocPrint(gpa, "{s}.part", .{out_path});
    defer gpa.free(tmp);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = file });
    try Io.Dir.renameAbsolute(tmp, out_path, io);
}

pub fn isGps(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "exif-ifd3-");
}

/// The XMP for an export: upright (tiff:Orientation 1), and without GPS unless kept.
pub fn cleanXmp(gpa: std.mem.Allocator, xmp: []const u8, keep_gps: bool) ![]u8 {
    const no_gps = if (keep_gps) try gpa.dupe(u8, xmp) else try withoutXmpGps(gpa, xmp);
    for ([_][]const u8{ "tiff:Orientation=\"", "tiff:Orientation='", "<tiff:Orientation>" }) |key| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, no_gps, from, key)) |at| {
            from = at + key.len;
            if (from < no_gps.len and std.ascii.isDigit(no_gps[from])) no_gps[from] = '1';
        }
    }
    return no_gps;
}

/// The XMP packet without its `exif:GPS…` properties, written as attributes or as elements.
pub fn withoutXmpGps(gpa: std.mem.Allocator, xmp: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < xmp.len) {
        const rest = xmp[i..];
        const at = std.mem.indexOf(u8, rest, "exif:GPS") orelse {
            try out.appendSlice(gpa, rest);
            break;
        };
        const start = i + at;
        var name_end = start;
        while (name_end < xmp.len and (std.ascii.isAlphanumeric(xmp[name_end]) or xmp[name_end] == ':' or xmp[name_end] == '_')) name_end += 1;
        const name = xmp[start..name_end];
        if (start > 0 and xmp[start - 1] == '<') {
            // <exif:GPSLatitude>…</exif:GPSLatitude>, or <exif:GPSLatitude …/>
            const close = try std.fmt.allocPrint(gpa, "</{s}>", .{name});
            defer gpa.free(close);
            const self_close = std.mem.indexOfPos(u8, xmp, name_end, ">") orelse xmp.len - 1;
            const end = if (xmp[self_close - 1] == '/') self_close + 1 else if (std.mem.indexOfPos(u8, xmp, name_end, close)) |e| e + close.len else xmp.len;
            try out.appendSlice(gpa, xmp[i .. start - 1]);
            i = end;
        } else if (name_end < xmp.len and xmp[name_end] == '=') {
            // exif:GPSLatitude="…"
            const quote = xmp[name_end + 1];
            const end = (std.mem.indexOfScalarPos(u8, xmp, name_end + 2, quote) orelse xmp.len - 1) + 1;
            try out.appendSlice(gpa, std.mem.trimEnd(u8, xmp[i..start], " \t\r\n"));
            i = end;
        } else {
            try out.appendSlice(gpa, xmp[i..name_end]);
            i = name_end;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn samePath(a: [:0]const u8, b: [:0]const u8) bool {
    var buf_a: [std.c.PATH_MAX]u8 = undefined;
    var buf_b: [std.c.PATH_MAX]u8 = undefined;
    const real_a = std.c.realpath(a, &buf_a) orelse return false;
    const real_b = std.c.realpath(b, &buf_b) orelse return false;
    return std.mem.eql(u8, std.mem.span(real_a), std.mem.span(real_b));
}
