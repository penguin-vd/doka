//! Where a folder keeps its edits: `<root>/.photo-editor/`, mirroring the photos' paths, so the
//! photos stay untouched and the edits move with the folder.
//!   trip/photo-04.jpg → .photo-editor/recipes/trip/photo-04.jpg.json
//!                       .photo-editor/thumbs/trip/photo-04.jpg
const std = @import("std");
const Io = std.Io;
const Recipe = @import("recipe.zig");

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

/// Writes through a temporary file and a rename, so a crash never leaves half a file.
pub fn writeAtomic(io: Io, gpa: std.mem.Allocator, root: Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try root.createDirPath(io, dir);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp);
    try root.writeFile(io, .{ .sub_path = tmp, .data = data });
    try root.rename(tmp, root, path, io);
}

pub fn edited(io: Io, root: Io.Dir, gpa: std.mem.Allocator, rel: []const u8) bool {
    const path = recipePath(gpa, rel) catch return false;
    defer gpa.free(path);
    root.access(io, path, .{}) catch return false;
    return true;
}
