//! The photos in an opened folder: every JPEG under it, subfolders included, by path. Hidden
//! folders (`.photo-editor` among them) are skipped.
const std = @import("std");
const Io = std.Io;
const core = @import("photo-core");

pub const Photo = struct {
    // Relative to the root, '/'-separated: "2024 Japan/P1010001.JPG".
    rel: []const u8,
    edited: bool,
};

pub fn isPhoto(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".jpg") or std.ascii.endsWithIgnoreCase(name, ".jpeg");
}

/// Strings and the list live in `arena`.
pub fn scan(io: Io, arena: std.mem.Allocator, gpa: std.mem.Allocator, root: Io.Dir) ![]Photo {
    var list: std.ArrayList(Photo) = .empty;
    var walker = try root.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.basename.len > 0 and entry.basename[0] == '.') continue;
        switch (entry.kind) {
            .directory => try walker.enter(io, entry),
            .file, .sym_link => if (isPhoto(entry.basename)) try list.append(arena, .{
                .rel = try arena.dupe(u8, entry.path),
                .edited = core.store.edited(io, root, gpa, entry.path),
            }),
            else => {},
        }
    }
    std.mem.sort(Photo, list.items, {}, struct {
        fn lessThan(_: void, a: Photo, b: Photo) bool {
            return std.mem.lessThan(u8, a.rel, b.rel);
        }
    }.lessThan);
    return list.items;
}
