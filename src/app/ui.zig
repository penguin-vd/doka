//! The page's own files, built in from ui/ (build.zig, addUi) and served at app://ui/<path>.
const std = @import("std");
const table = @import("ui_files").files;

pub const File = struct {
    path: []const u8,
    mime: [*:0]const u8,
    bytes: []const u8,
};

pub const scheme = "app";
pub const base = "app://ui/";
pub const start = base ++ "index.html";

const mimes = [_]struct { []const u8, [*:0]const u8 }{
    .{ ".html", "text/html" },
    .{ ".css", "text/css" },
    .{ ".js", "text/javascript" },
    .{ ".glsl", "text/plain" },
    .{ ".svg", "image/svg+xml" },
};

pub fn mimeOf(path: []const u8) [*:0]const u8 {
    for (mimes) |m| if (std.mem.endsWith(u8, path, m[0])) return m[1];
    return "application/octet-stream";
}

/// The page file an app:// URI names, if it is one.
pub fn find(uri: []const u8) ?File {
    if (!std.mem.startsWith(u8, uri, base)) return null;
    const rest = uri[base.len..];
    const path = rest[0 .. std.mem.indexOfAny(u8, rest, "?#") orelse rest.len];
    inline for (table) |entry| {
        if (std.mem.eql(u8, entry[0], path)) return .{ .path = entry[0], .mime = mimeOf(entry[0]), .bytes = entry[1] };
    }
    return null;
}

/// %xx decoded; returns null for a malformed escape.
pub fn percentDecode(gpa: std.mem.Allocator, s: []const u8) !?[]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, s.len);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '%') {
            out.appendAssumeCapacity(s[i]);
            continue;
        }
        if (i + 2 >= s.len) {
            out.deinit(gpa);
            return null;
        }
        const byte = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch {
            out.deinit(gpa);
            return null;
        };
        out.appendAssumeCapacity(byte);
        i += 2;
    }
    return try out.toOwnedSlice(gpa);
}
