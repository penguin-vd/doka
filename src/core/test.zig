//! photo-core against real camera JPEGs: copies of a few library photos in testdata/photos/
//! (CLAUDE.md). Without them these tests are skipped.
const std = @import("std");
const testing = std.testing;

const vips = @import("vips.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");

const photos = "testdata/photos";
// Orientation 1, sRGB without a profile, a GPS block.
const plain = photos ++ "/P4270251.JPG";
// An embedded (Adobe RGB) profile.
const tagged = photos ++ "/P5070015.jpg";

fn start() !void {
    try vips.init("doka-test");
    std.Io.Dir.cwd().access(testing.io, plain, .{}) catch return error.SkipZigTest;
}

test "libvips links and starts" {
    try vips.init("doka-test");
    const v = vips.version();
    // 8.15 is the oldest with the `keep` option the export relies on.
    try testing.expect(v.major == 8 and v.minor >= 15);
}

test "a preview decodes to linear half floats at the asked size, upright" {
    try start();
    var lin = try decode.linear(testing.allocator, plain, 1024);
    defer lin.deinit(testing.allocator);
    try testing.expectEqual(1024, @max(lin.width, lin.height));
    try testing.expectEqual(lin.width * lin.height * 3, lin.rgb.len);
    try testing.expectEqual(5184, lin.full_width);
    var sum: f64 = 0;
    for (lin.rgb) |h| sum += @as(f16, @bitCast(h));
    const mean = sum / @as(f64, @floatFromInt(lin.rgb.len));
    // Linear light: a normal exposure averages well below the 0.5 of its sRGB code values.
    try testing.expect(mean > 0.005 and mean < 0.5);
}

test "an untagged JPEG and one tagged sRGB decode to the same linear values" {
    try start();
    var out: ?*vips.Image = null;
    try vips.check(vips.c.vips_jpegload(plain, &out, "shrink", @as(c_int, 8), vips.end));
    const as_srgb = try vips.step(out.?, vips.c.vips_copy, .{});
    const icc = try vips.profile("srgb");
    vips.c.vips_image_set_blob_copy(as_srgb, "icc-profile-data", icc.ptr, icc.len);
    vips.c.vips_image_set_int(as_srgb, "orientation", 1);
    const through_icc = try decode.toScrgb(as_srgb);
    defer vips.unref(through_icc);
    try vips.check(vips.c.vips_jpegload(plain, &out, "shrink", @as(c_int, 8), vips.end));
    const direct = try decode.toScrgb(out.?);
    defer vips.unref(direct);
    const a = try vips.toMemory(through_icc);
    defer vips.freeMemory(a);
    const b = try vips.toMemory(direct);
    defer vips.freeMemory(b);
    const fa: []align(1) const f32 = std.mem.bytesAsSlice(f32, a);
    const fb: []align(1) const f32 = std.mem.bytesAsSlice(f32, b);
    var worst: f32 = 0;
    for (fa, fb) |x, y| worst = @max(worst, @abs(x - y) / @max(y, 0.01));
    try testing.expect(worst < 0.03);
}

test "a photo with an embedded profile decodes" {
    try start();
    var lin = try decode.linear(testing.allocator, tagged, 512);
    defer lin.deinit(testing.allocator);
    try testing.expectEqual(512, @max(lin.width, lin.height));
}

test "camera and exposure come from EXIF" {
    try start();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const i = try decode.info(arena.allocator(), plain);
    try testing.expectEqualStrings("OLYMPUS CORPORATION", i.make);
    try testing.expectEqualStrings("E-P7", i.model);
    try testing.expect(std.mem.indexOf(u8, i.lens, "14-42mm") != null);
    try testing.expect(i.taken.len > 0 and i.exposure.len > 0);
    try testing.expectEqualStrings("3.5", try decode.rational(arena.allocator(), "35/10"));
    try testing.expectEqualStrings("1/250", i.exposure);
}

test "a thumbnail is a small JPEG" {
    try start();
    const jpg = try decode.thumbnail(plain, 256);
    defer vips.freeMemory(jpg);
    try testing.expect(std.mem.startsWith(u8, jpg, "\xff\xd8"));
    try testing.expect(jpg.len < 64 * 1024);
}

const Export = struct {
    tmp: testing.TmpDir,
    path: [:0]u8,

    fn deinit(e: *Export) void {
        testing.allocator.free(e.path);
        e.tmp.cleanup();
    }
};

fn exportOf(source: [:0]const u8, options: encode.Options) !Export {
    var tmp = testing.tmpDir(.{});
    errdefer tmp.cleanup();
    var cwd_buf: [std.c.PATH_MAX]u8 = undefined;
    const cwd = std.mem.sliceTo(std.c.getcwd(&cwd_buf, cwd_buf.len).?, 0);
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/.zig-cache/tmp/{s}/out{s}", .{ cwd, tmp.sub_path, options.format.extension() }, 0);
    errdefer testing.allocator.free(path);
    const w = 600;
    const h = 400;
    switch (options.format.bits()) {
        8 => {
            var px: [w * h * 3]u8 = undefined;
            for (&px, 0..) |*p, i| p.* = @truncate(i);
            try encode.save(testing.io, testing.allocator, source, .{ .width = w, .height = h, .data = .{ .u8 = &px } }, options, path);
        },
        else => {
            const px = try testing.allocator.alloc(u16, w * h * 3);
            defer testing.allocator.free(px);
            for (px, 0..) |*p, i| p.* = @truncate(i * 97);
            try encode.save(testing.io, testing.allocator, source, .{ .width = w, .height = h, .data = .{ .u16 = px } }, options, path);
        },
    }
    return .{ .tmp = tmp, .path = path };
}

fn open(path: [:0]const u8) !*vips.Image {
    return vips.c.vips_image_new_from_file(path, vips.end) orelse vips.fail();
}

/// Every EXIF field of the original that must come through an export unchanged.
fn expectExifKept(original: [:0]const u8, exported: [:0]const u8, gps: bool) !void {
    const a = try open(original);
    defer vips.unref(a);
    const b = try open(exported);
    defer vips.unref(b);
    const names = try vips.fieldNames(testing.allocator, a);
    defer {
        for (names) |n| testing.allocator.free(n);
        testing.allocator.free(names);
    }
    // What an export rightly changes: the size, the orientation (the pixels are upright), the
    // embedded thumbnail (it shows the unedited photo), and the colour space the profile names.
    const changes = [_][]const u8{
        "exif-ifd0-Orientation", "exif-ifd2-PixelXDimension", "exif-ifd2-PixelYDimension",
        "exif-ifd2-ColorSpace",  "exif-ifd1-",
    };
    var checked: usize = 0;
    for (names) |name| {
        if (!std.mem.startsWith(u8, name, "exif-ifd")) continue;
        if (for (changes) |ch| {
            if (std.mem.startsWith(u8, name, ch)) break true;
        } else false) continue;
        const name_z = try testing.allocator.dupeZ(u8, name);
        defer testing.allocator.free(name_z);
        if (!gps and encode.isGps(name)) {
            try testing.expect(!vips.has(b, name_z));
            continue;
        }
        var va: [*:0]const u8 = undefined;
        var vb: [*:0]const u8 = undefined;
        _ = vips.c.vips_image_get_string(a, name_z, &va);
        if (vips.c.vips_image_get_string(b, name_z, &vb) != 0) {
            std.debug.print("lost in export: {s}\n", .{name});
            return error.MetadataLost;
        }
        try testing.expectEqualStrings(std.mem.span(va), std.mem.span(vb));
        checked += 1;
    }
    // Every field but the few above (24 on the RawTherapee export, 70 straight from the camera).
    try testing.expect(checked > 15);
    try testing.expectEqual(1, vips.int(b, "orientation") orelse 1);
    try testing.expect(vips.has(b, "icc-profile-data"));
}

test "export keeps every EXIF field: camera, lens, exposure, date, maker notes, GPS" {
    try start();
    var e = try exportOf(plain, .{});
    defer e.deinit();
    try expectExifKept(plain, e.path, true);
    const b = try open(e.path);
    defer vips.unref(b);
    try testing.expect(vips.has(b, "exif-ifd3-GPSVersionID"));
    try testing.expectEqualStrings("E-P7", vips.string(b, "exif-ifd0-Model").?);
    // libexif would have cut Olympus' maker note to 144 bytes; it must come through whole.
    try testing.expectEqualStrings("17040 bytes undefined data", vips.string(b, "exif-ifd2-MakerNote").?);
}

test "export without GPS drops the GPS block and nothing else" {
    try start();
    var e = try exportOf(plain, .{ .keep_gps = false });
    defer e.deinit();
    try expectExifKept(plain, e.path, false);
    const b = try open(e.path);
    defer vips.unref(b);
    const names = try vips.fieldNames(testing.allocator, b);
    defer {
        for (names) |n| testing.allocator.free(n);
        testing.allocator.free(names);
    }
    for (names) |n| try testing.expect(!encode.isGps(n));
}

test "export embeds the output profile, not the original's, and says so in EXIF" {
    try start();
    var e = try exportOf(tagged, .{ .format = .png, .space = .p3 });
    defer e.deinit();
    try expectExifKept(tagged, e.path, true);
    const b = try open(e.path);
    defer vips.unref(b);
    const p3 = try vips.profile("p3");
    try testing.expectEqualSlices(u8, p3, vips.blob(b, "icc-profile-data").?);
    try testing.expectEqualStrings("65535", vips.string(b, "exif-ifd2-ColorSpace").?);
}

test "PNG export keeps the metadata too" {
    try start();
    var e = try exportOf(plain, .{ .format = .png });
    defer e.deinit();
    try expectExifKept(plain, e.path, true);
}

test "export with metadata off keeps only the colour profile" {
    try start();
    var e = try exportOf(plain, .{ .keep_metadata = false });
    defer e.deinit();
    const b = try open(e.path);
    defer vips.unref(b);
    try testing.expect(!vips.has(b, "exif-ifd0-Model"));
    try testing.expect(vips.has(b, "icc-profile-data"));
}

test "export never writes over the original" {
    try start();
    var px = [_]u8{0} ** (4 * 4 * 3);
    try testing.expectError(error.WouldOverwriteOriginal, encode.save(testing.io, testing.allocator, plain, .{ .width = 4, .height = 4, .data = .{ .u8 = &px } }, .{}, plain));
}

test "a photo tagged as turned decodes upright" {
    try start();
    var out: ?*vips.Image = null;
    try vips.check(vips.c.vips_jpegload(plain, &out, "shrink", @as(c_int, 8), vips.end));
    defer vips.unref(out.?);
    vips.c.vips_image_set_int(out.?, "orientation", 6);
    var buf: ?[*]u8 = null;
    var len: usize = 0;
    try vips.check(vips.c.vips_image_write_to_buffer(out.?, ".jpg", &buf, &len, vips.end));
    defer vips.freeMemory(buf.?[0..len]);
    var e = try exportOf(plain, .{});
    defer e.deinit();
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = e.path, .data = buf.?[0..len] });
    var lin = try decode.linear(testing.allocator, e.path, 0);
    defer lin.deinit(testing.allocator);
    try testing.expectEqual(vips.height(out.?), lin.width);
    try testing.expectEqual(vips.width(out.?), lin.height);
    try testing.expectEqual(lin.width, lin.full_width);
}
