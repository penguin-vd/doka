//! Where a folder keeps its edits: `<root>/.photo-editor/`, mirroring the photos' paths, so the
//! photos stay untouched and the edits move with the folder.
//!   trip/photo-04.jpg → .photo-editor/recipes/trip/photo-04.jpg.json
//!                       .photo-editor/thumbs/trip/photo-04.jpg
//! Subject masks are pictures with made-up names: .photo-editor/masks/0123abc.png
const std = @import("std");
const Io = std.Io;
const Recipe = @import("recipe.zig");
const vips = @import("vips.zig");

pub const dir_name = ".photo-editor";

/// A photo's path relative to the root, as the store and the app name it. Rejects anything that
/// could leave the root.
pub fn checkRelative(rel: []const u8) error{BadPath}!void {
    if (rel.len == 0 or rel[0] == '/') return error.BadPath;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return error.BadPath;
    }
}

pub fn recipePath(gpa: std.mem.Allocator, rel: []const u8) ![]u8 {
    try checkRelative(rel);
    return std.fmt.allocPrint(gpa, dir_name ++ "/recipes/{s}.json", .{rel});
}

pub fn thumbPath(gpa: std.mem.Allocator, rel: []const u8) ![]u8 {
    try checkRelative(rel);
    return std.fmt.allocPrint(gpa, dir_name ++ "/thumbs/{s}", .{rel});
}

/// The photo's recipe, or null when it has none (it's unedited). Strings live in `arena`.
pub fn load(io: Io, arena: std.mem.Allocator, root: Io.Dir, rel: []const u8) !?Recipe {
    const path = try recipePath(arena, rel);
    const json = root.readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try Recipe.parse(arena, json);
}

/// Writes the recipe; an unedited one deletes the file instead, so deleting a recipe and resetting
/// a photo are the same thing.
pub fn save(io: Io, gpa: std.mem.Allocator, root: Io.Dir, rel: []const u8, recipe: Recipe) !void {
    const path = try recipePath(gpa, rel);
    defer gpa.free(path);
    if (recipe.isDefault()) {
        root.deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }
    const json = try recipe.writeAlloc(gpa);
    defer gpa.free(json);
    try writeAtomic(io, gpa, root, path, json);
}

const picks_path = dir_name ++ "/picks.json";

/// The photos picked in this folder, by path. Strings live in `arena`.
pub fn loadPicks(io: Io, arena: std.mem.Allocator, root: Io.Dir) ![]const []const u8 {
    const json = root.readFileAlloc(io, picks_path, arena, .limited(1 << 24)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    return std.json.parseFromSliceLeaky([]const []const u8, arena, json, .{ .allocate = .alloc_always });
}

/// None picked is no file, as an unedited photo has no recipe.
pub fn savePicks(io: Io, gpa: std.mem.Allocator, root: Io.Dir, names: []const []const u8) !void {
    if (names.len == 0) {
        root.deleteFile(io, picks_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }
    const json = try std.json.Stringify.valueAlloc(gpa, names, .{ .whitespace = .indent_1 });
    defer gpa.free(json);
    try writeAtomic(io, gpa, root, picks_path, json);
}

/// Writes through a temporary file and a rename, so a crash never leaves half a file.
pub fn writeAtomic(io: Io, gpa: std.mem.Allocator, root: Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try root.createDirPath(io, dir);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp);
    try root.writeFile(io, .{ .sub_path = tmp, .data = data });
    try root.rename(tmp, root, path, io);
}

/// A subject mask's name: comes from a recipe, so it mustn't be able to point anywhere else.
pub fn validMaskName(name: []const u8) bool {
    const extension = ".png";
    if (name.len == 0) return true;
    if (name.len > 64 or name.len <= extension.len or !std.mem.endsWith(u8, name, extension)) return false;
    for (name[0 .. name.len - extension.len]) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn maskPath(gpa: std.mem.Allocator, name: []const u8) ![:0]u8 {
    if (name.len == 0 or !validMaskName(name)) return error.BadPath;
    return std.fmt.allocPrintSentinel(gpa, dir_name ++ "/masks/{s}", .{name}, 0);
}

/// Saves a subject mask: width × height, one byte each.
pub fn saveMask(io: Io, gpa: std.mem.Allocator, root: Io.Dir, name: []const u8, pixels: []const u8, width: u32, height: u32) !void {
    const path = try maskPath(gpa, name);
    defer gpa.free(path);
    const img = vips.c.vips_image_new_from_memory_copy(pixels.ptr, pixels.len, @intCast(width), @intCast(height), 1, .uchar) orelse return vips.fail();
    defer vips.unref(img);
    var buf: ?[*]u8 = null;
    var len: usize = 0;
    try vips.check(vips.c.vips_image_write_to_buffer(img, ".png", &buf, &len, "compression", @as(c_int, 6), vips.end));
    const png = buf.?[0..len];
    defer vips.freeMemory(png);
    try writeAtomic(io, gpa, root, path, png);
}

pub const MaskPicture = struct { width: u32, height: u32, pixels: []u8 };

/// A saved subject mask from the folder at `root`; `pixels` are for `gpa` to free.
pub fn loadMask(gpa: std.mem.Allocator, root: []const u8, name: []const u8) !MaskPicture {
    const rel = try maskPath(gpa, name);
    defer gpa.free(rel);
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ root, rel }, 0);
    defer gpa.free(path);
    const img = vips.c.vips_image_new_from_file(path, vips.end) orelse return error.NoMaskFile;
    defer vips.unref(img);
    const width = vips.width(img);
    const height = vips.height(img);
    if (vips.bands(img) != 1) return error.NoMaskFile;
    const memory = try vips.toMemory(img);
    defer vips.freeMemory(memory);
    if (memory.len != @as(usize, width) * height) return error.NoMaskFile;
    return .{ .width = width, .height = height, .pixels = try gpa.dupe(u8, memory) };
}

pub fn edited(io: Io, root: Io.Dir, gpa: std.mem.Allocator, rel: []const u8) bool {
    const path = recipePath(gpa, rel) catch return false;
    defer gpa.free(path);
    root.access(io, path, .{}) catch return false;
    return true;
}
