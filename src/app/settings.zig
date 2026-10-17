//! What the app remembers between runs, in ~/.config/doka/settings.json: the last folder and the
//! export defaults. Looks and shaders live beside it (looks/, shaders/).
const std = @import("std");
const Io = std.Io;
const core = @import("photo-core");

const Settings = @This();

last_folder: []const u8 = "",
@"export": Export = .{},

pub const Export = struct {
    format: core.encode.Format = .jpeg,
    quality: u8 = 90,
    // 0 = original size.
    long_edge: u32 = 0,
    keep_metadata: bool = true,
    keep_gps: bool = true,
    space: core.encode.Space = .srgb,
    // Empty: ~/Pictures/Doka.
    folder: []const u8 = "",
    // Added to the photo's name: "P4270251-edit.jpg".
    suffix: []const u8 = "-edit",
};

pub const file_name = "settings.json";

/// $XDG_CONFIG_HOME/doka, or ~/.config/doka.
pub fn configDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |x| if (x.len > 0) return std.fs.path.join(arena, &.{ x, "doka" });
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(arena, &.{ home, ".config", "doka" });
}

pub fn defaultExportFolder(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(arena, &.{ home, "Pictures", "Doka" });
}

/// The saved settings, or the defaults when there are none or they don't read.
pub fn load(io: Io, arena: std.mem.Allocator, dir: []const u8) Settings {
    const path = std.fs.path.join(arena, &.{ dir, file_name }) catch return .{};
    const json = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 16)) catch return .{};
    return std.json.parseFromSliceLeaky(Settings, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch .{};
}

pub fn save(s: Settings, io: Io, gpa: std.mem.Allocator, dir: []const u8) !void {
    const json = try std.json.Stringify.valueAlloc(gpa, s, .{ .whitespace = .indent_2 });
    defer gpa.free(json);
    var d = try Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    defer d.close(io);
    try core.store.writeAtomic(io, gpa, d, file_name, json);
}
