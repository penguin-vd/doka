const std = @import("std");
const testing = std.testing;

const Recipe = @import("recipe.zig");
const store = @import("store.zig");
const encode = @import("encode.zig");

test "a recipe writes only what differs from the default" {
    var r: Recipe = .{ .updatedAt = "2026-10-16T13:30:00Z" };
    r.edits.exposure = 0.3;
    r.grain.amount = 25;
    const json = try r.writeAlloc(testing.allocator);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(
        \\{
        \\  "version": 1,
        \\  "edits": {
        \\    "exposure": 0.3
        \\  },
        \\  "grain": {
        \\    "amount": 25
        \\  },
        \\  "updatedBy": "user",
        \\  "updatedAt": "2026-10-16T13:30:00Z"
        \\}
    , json);
}

test "the spec's example recipe reads, and writes back the same" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try Recipe.parse(a,
        \\{"version":1,"edits":{"exposure":0.3,"temperature":6,"tint":0,"contrast":8,"highlights":-20,"shadows":25,"saturation":5},
        \\"look":{"name":"classic-chrome.cube","strength":80},
        \\"shaders":[{"name":"split-tone","strength":60,"params":{"shadows":0.5,"highlights":0.7}}],
        \\"colour":{"greens":{"hue":8,"sat":-15,"light":0},"blues":{"hue":0,"sat":-10,"light":-5}},
        \\"halation":15,"grain":{"amount":25,"size":40},"detail":{"sharpen":30,"noise":15},
        \\"crop":{"aspect":"4:5","straighten":-2,"rotate":0,"flip":false,"rect":[0.1,0.0,0.8,1.0]},
        \\"updatedBy":"claude","updatedAt":"2026-10-16T13:30:00Z"}
    );
    try testing.expectEqual(.claude, r.updatedBy);
    try testing.expectEqual(-20, r.edits.highlights);
    try testing.expectEqualStrings("classic-chrome.cube", r.look.name);
    try testing.expectEqual(0.7, r.shaders[0].params.map.get("highlights").?);
    try testing.expectEqual(-15, r.colour.greens.sat);
    const again = try Recipe.parse(a, try r.writeAlloc(a));
    try testing.expectEqualDeep(r.edits, again.edits);
    try testing.expectEqualDeep(r.crop, again.crop);
    try testing.expectEqual(r.shaders[0].params.map.get("shadows"), again.shaders[0].params.map.get("shadows"));
}

test "a patch changes only the fields it names, and null resets one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var base: Recipe = .{};
    base.edits.exposure = 1;
    base.edits.contrast = 10;
    base.halation = 20;
    const patch = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"edits":{"exposure":0.5},"halation":null,"look":{"name":"film.cube"}}
    , .{});
    const r = try Recipe.apply(a, base, patch);
    try testing.expectEqual(0.5, r.edits.exposure);
    try testing.expectEqual(10, r.edits.contrast);
    try testing.expectEqual(0, r.halation);
    try testing.expectEqualStrings("film.cube", r.look.name);
    try testing.expectEqual(100, r.look.strength);
}

test "out-of-range values are clamped, not refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try Recipe.parse(arena.allocator(),
        \\{"edits":{"exposure":9,"contrast":-300},"crop":{"aspect":"7:3","rotate":100,"rect":[0.9,0.5,0.5,2]},"grain":{"amount":-4}}
    );
    try testing.expectEqual(5, r.edits.exposure);
    try testing.expectEqual(-100, r.edits.contrast);
    try testing.expectEqualStrings("original", r.crop.aspect);
    try testing.expectEqual(90, r.crop.rotate);
    try testing.expectApproxEqAbs(0.1, r.crop.rect[2], 1e-6);
    try testing.expectApproxEqAbs(0.5, r.crop.rect[3], 1e-6);
    try testing.expectEqual(0, r.grain.amount);
}

test "a recipe newer than the app is refused" {
    try testing.expectError(error.NewerRecipeVersion, Recipe.parse(testing.allocator, "{\"version\":2}"));
}

test "an unedited recipe is default; any change makes it not" {
    var r: Recipe = .{ .updatedBy = .claude, .updatedAt = "now" };
    try testing.expect(r.isDefault());
    r.crop.flip = true;
    try testing.expect(!r.isDefault());
}

test "recipes and thumbnails mirror the photo's path under .photo-editor" {
    const p = try store.recipePath(testing.allocator, "trip/photo-04.jpg");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings(".photo-editor/recipes/trip/photo-04.jpg.json", p);
    try testing.expectError(error.BadPath, store.recipePath(testing.allocator, "../outside.jpg"));
    try testing.expectError(error.BadPath, store.recipePath(testing.allocator, "/etc/passwd"));
    try testing.expectError(error.BadPath, store.thumbPath(testing.allocator, "a//b.jpg"));
}

test "a recipe saved and loaded comes back; reset deletes the file" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var r: Recipe = .{};
    r.edits.shadows = 25;
    try store.save(io, testing.allocator, tmp.dir, "trip/a.jpg", r);
    try testing.expect(store.edited(io, tmp.dir, testing.allocator, "trip/a.jpg"));
    const back = (try store.load(io, arena.allocator(), tmp.dir, "trip/a.jpg")).?;
    try testing.expectEqual(25, back.edits.shadows);
    try store.save(io, testing.allocator, tmp.dir, "trip/a.jpg", .{});
    try testing.expect(!store.edited(io, tmp.dir, testing.allocator, "trip/a.jpg"));
    try testing.expectEqual(null, try store.load(io, arena.allocator(), tmp.dir, "trip/a.jpg"));
}

test "updatedAt is ISO 8601 in UTC" {
    var buf: [20]u8 = undefined;
    try testing.expectEqualStrings("2026-10-16T13:30:00Z", Recipe.timestamp(&buf, 1792157400));
}

test "GPS leaves an XMP packet, written either way, and nothing else does" {
    const xmp =
        \\<rdf:Description exif:GPSLatitude="52,22.1N" exif:ExposureTime="1/200"
        \\ exif:GPSLongitude='4,53.9E'><exif:GPSAltitude>3/1</exif:GPSAltitude><tiff:Make>OLYMPUS</tiff:Make>
        \\<exif:GPSTimeStamp/></rdf:Description>
    ;
    const clean = try encode.withoutXmpGps(testing.allocator, xmp);
    defer testing.allocator.free(clean);
    try testing.expect(std.mem.indexOf(u8, clean, "GPS") == null);
    try testing.expect(std.mem.indexOf(u8, clean, "exif:ExposureTime=\"1/200\"") != null);
    try testing.expect(std.mem.indexOf(u8, clean, "<tiff:Make>OLYMPUS</tiff:Make>") != null);
}

test "an aspect and a focus point make a crop" {
    // A 3:2 landscape photo, 4:5 around a point right of the middle: full height, as wide as 4:5 allows.
    const r = Recipe.fitCrop(.{ 0, 0, 1, 1 }, Recipe.aspectRatio("4:5", .{ 3000, 2000 }), .{ 0.6, 0.5 }, .{ 3000, 2000 });
    try testing.expectApproxEqAbs(1.0, r[3], 1e-6);
    try testing.expectApproxEqAbs(0.8 * 2000.0 / 3000.0, r[2], 1e-6);
    try testing.expectApproxEqAbs(0.6 - r[2] / 2, r[0], 1e-6);
    // Too near the edge: it stops at the edge.
    const e = Recipe.fitCrop(.{ 0, 0, 1, 1 }, Recipe.aspectRatio("1:1", .{ 3000, 2000 }), .{ 0.99, 0.5 }, .{ 3000, 2000 });
    try testing.expectApproxEqAbs(1.0, e[0] + e[2], 1e-6);
    // Free keeps the crop's size and moves it.
    const f = Recipe.fitCrop(.{ 0.1, 0.1, 0.5, 0.5 }, Recipe.aspectRatio("free", .{ 3, 2 }), .{ 0.5, 0.5 }, .{ 3, 2 });
    try testing.expectEqual([4]f32{ 0.25, 0.25, 0.5, 0.5 }, f);
    try testing.expectEqual(1.5, Recipe.aspectRatio("original", .{ 3, 2 }).?);
}
