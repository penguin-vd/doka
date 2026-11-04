//! .cube LUT files (Adobe/Resolve 3D LUT format): a lattice of output colours, red fastest.
const std = @import("std");

const Cube = @This();

title: []const u8 = "",
size: u32,
min: [3]f32 = .{ 0, 0, 0 },
max: [3]f32 = .{ 1, 1, 1 },
// size³ × RGB.
data: []f32,

pub fn deinit(c: *Cube, gpa: std.mem.Allocator) void {
    gpa.free(c.title);
    gpa.free(c.data);
}

fn three(parts: *std.mem.TokenIterator(u8, .any)) ![3]f32 {
    var out: [3]f32 = undefined;
    for (&out) |*v| {
        v.* = try std.fmt.parseFloat(f32, parts.next() orelse return error.BadCube);
        if (!std.math.isFinite(v.*)) return error.BadCube;
    }
    return out;
}

pub fn parse(gpa: std.mem.Allocator, text: []const u8) !Cube {
    var title: []const u8 = "";
    var size: u32 = 0;
    var min = [3]f32{ 0, 0, 0 };
    var max = [3]f32{ 1, 1, 1 };
    var values: std.ArrayList(f32) = .empty;
    errdefer values.deinit(gpa);
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        var parts = std.mem.tokenizeAny(u8, line, " \t");
        const key = parts.peek().?;
        if (std.ascii.eqlIgnoreCase(key, "TITLE")) {
            title = std.mem.trim(u8, line[5..], " \t\"");
        } else if (std.ascii.eqlIgnoreCase(key, "LUT_3D_SIZE")) {
            _ = parts.next();
            size = try std.fmt.parseInt(u32, parts.next() orelse return error.BadCube, 10);
        } else if (std.ascii.eqlIgnoreCase(key, "DOMAIN_MIN")) {
            _ = parts.next();
            min = try three(&parts);
        } else if (std.ascii.eqlIgnoreCase(key, "DOMAIN_MAX")) {
            _ = parts.next();
            max = try three(&parts);
        } else if (std.ascii.eqlIgnoreCase(key, "LUT_1D_SIZE")) {
            return error.OneDimensionalLut;
        } else if (std.ascii.isDigit(key[0]) or key[0] == '-' or key[0] == '+' or key[0] == '.') {
            try values.appendSlice(gpa, &try three(&parts));
        }
    }
    if (size < 2 or size > 256) return error.BadSize;
    if (values.items.len != @as(usize, size) * size * size * 3) return error.WrongCount;
    const data = try values.toOwnedSlice(gpa);
    errdefer gpa.free(data);
    return .{ .title = try gpa.dupe(u8, title), .size = size, .min = min, .max = max, .data = data };
}

/// A .cube's text: what bake_look writes.
pub fn write(gpa: std.mem.Allocator, title: []const u8, size: u32, rgb: []const f32) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("TITLE \"{s}\"\nLUT_3D_SIZE {d}\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n", .{ title, size });
    for (0..@as(usize, size) * size * size) |i| try w.print("{d:.6} {d:.6} {d:.6}\n", .{ rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2] });
    return out.toOwnedSlice();
}

test "a .cube reads, and what's written reads back the same" {
    const gpa = std.testing.allocator;
    const text = "# made up\nTITLE \"Two\"\r\nLUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n";
    var c = try parse(gpa, text);
    defer c.deinit(gpa);
    try std.testing.expectEqualStrings("Two", c.title);
    try std.testing.expectEqual(2, c.size);
    try std.testing.expectEqual(1, c.data[3]);
    const again = try write(gpa, "Two", 2, c.data);
    defer gpa.free(again);
    var d = try parse(gpa, again);
    defer d.deinit(gpa);
    try std.testing.expectEqualSlices(f32, c.data, d.data);
}

test "a .cube that isn't right is refused" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.WrongCount, parse(gpa, "LUT_3D_SIZE 2\n0 0 0\n"));
    try std.testing.expectError(error.BadSize, parse(gpa, "0 0 0\n"));
    try std.testing.expectError(error.OneDimensionalLut, parse(gpa, "LUT_1D_SIZE 4\n"));
}
