//! The page's files, served to the webview at app://ui/<path>. Built in by build.zig (addUi).
const std = @import("std");

pub const File = struct {
    path: []const u8,
    mime: [:0]const u8,
    bytes: []const u8,
};

pub const scheme = "app";
pub const start = "app://ui/index.html";

pub const files = [_]File{
    .{ .path = "index.html", .mime = "text/html", .bytes = @embedFile("index.html") },
    .{ .path = "style.css", .mime = "text/css", .bytes = @embedFile("style.css") },
    .{ .path = "main.js", .mime = "text/javascript", .bytes = @embedFile("main.js") },
};

/// The file an app:// URI names, if the page has one.
pub fn find(uri: []const u8) ?File {
    const prefix = scheme ++ "://ui/";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    const rest = uri[prefix.len..];
    const path = rest[0 .. std.mem.indexOfAny(u8, rest, "?#") orelse rest.len];
    for (files) |f| if (std.mem.eql(u8, f.path, path)) return f;
    return null;
}
