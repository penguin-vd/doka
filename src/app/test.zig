const std = @import("std");
const testing = std.testing;

const gpu = @import("gpu.zig");
const ui = @import("ui.zig");

test "a GPU report with float targets on the RTX passes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try gpu.parse(arena.allocator(),
        \\[{"webgl2":true,"renderer":"NVIDIA GeForce RTX 3080/PCIe/SSE2","float_render":true,
        \\"float_readback":true,"half_float_render":true,"float_linear":true,"max_texture_size":32768,"extra":1}]
    );
    try testing.expect(r.ok());
    try testing.expectEqual(32768, r.max_texture_size);
}

test "a GPU report fails without float targets or on a software renderer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(!(try gpu.parse(a, "[{\"webgl2\":true,\"renderer\":\"NVIDIA\",\"float_render\":false}]")).ok());
    try testing.expect(!(try gpu.parse(a,
        \\[{"webgl2":true,"renderer":"llvmpipe (LLVM 20.1, 256 bits)","float_render":true,"float_readback":true}]
    )).ok());
    try testing.expectError(error.BadReport, gpu.parse(a, "[]"));
}

test "app:// URIs find the page's files" {
    try testing.expectEqualStrings("text/html", std.mem.span(ui.find(ui.start).?.mime));
    try testing.expectEqualStrings("main.js", ui.find("app://ui/main.js?v=2").?.path);
    try testing.expect(ui.find("app://ui/../secret") == null);
    try testing.expect(ui.find("app://ui/photo/a.jpg") == null);
    try testing.expect(ui.find("https://ui/index.html") == null);
}

test "percent-encoded paths decode, bad escapes don't" {
    const d = (try ui.percentDecode(testing.allocator, "2024%20Japan/P1.JPG")).?;
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("2024 Japan/P1.JPG", d);
    try testing.expectEqual(null, try ui.percentDecode(testing.allocator, "bad%2"));
    try testing.expectEqual(null, try ui.percentDecode(testing.allocator, "bad%zz"));
}

const Session = @import("session.zig");
const folders = @import("folder.zig");

fn patch(a: std.mem.Allocator, json: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
}

test "one slider drag undoes in one step; a new gesture is a new step" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Session.init(testing.allocator, .{});
    defer s.deinit();
    for ([_][]const u8{ "{\"edits\":{\"exposure\":0.1}}", "{\"edits\":{\"exposure\":0.2}}", "{\"edits\":{\"exposure\":0.3}}" }) |p| {
        _ = try s.change(a, .{ .patch = try patch(a, p), .gesture = 7, .now = 0 });
    }
    _ = try s.change(a, .{ .patch = try patch(a, "{\"edits\":{\"contrast\":10}}"), .gesture = 8, .now = 0 });
    try testing.expect(try s.undo());
    try testing.expectEqual(0.3, (try s.recipe(a)).edits.exposure);
    try testing.expectEqual(0, (try s.recipe(a)).edits.contrast);
    try testing.expect(try s.undo());
    try testing.expectEqual(0, (try s.recipe(a)).edits.exposure);
    try testing.expect(!try s.undo());
    try testing.expect(try s.redo());
    try testing.expectEqual(0.3, (try s.recipe(a)).edits.exposure);
}

test "an edit after undo drops what could be redone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Session.init(testing.allocator, .{});
    defer s.deinit();
    _ = try s.change(a, .{ .patch = try patch(a, "{\"halation\":10}"), .now = 0 });
    _ = try s.undo();
    _ = try s.change(a, .{ .patch = try patch(a, "{\"halation\":20}"), .now = 0 });
    try testing.expect(!s.canRedo());
}

test "Claude's changes undo together from the bar, and Keep clears the bar" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s = try Session.init(testing.allocator, .{});
    defer s.deinit();
    _ = try s.change(a, .{ .patch = try patch(a, "{\"edits\":{\"exposure\":0.3}}"), .now = 0 });
    _ = try s.change(a, .{ .patch = try patch(a, "{\"look\":{\"name\":\"film.cube\",\"strength\":70}}"), .by = .claude, .now = 1, .note = "film look 70%" });
    const r = try s.change(a, .{ .patch = try patch(a, "{\"grain\":{\"amount\":25}}"), .by = .claude, .now = 2, .note = "grain 25" });
    try testing.expectEqual(.claude, r.updatedBy);
    try testing.expectEqualStrings("film look 70%; grain 25", s.claude_note.items);
    try testing.expect(try s.undoClaude());
    const back = try s.recipe(a);
    try testing.expectEqual(0.3, back.edits.exposure);
    try testing.expectEqualStrings("none", back.look.name);
    try testing.expect(!s.claudePending());
    // Redo brings Claude's version back.
    try testing.expect(try s.redo());
    try testing.expectEqual(25, (try s.recipe(a)).grain.amount);

    _ = try s.change(a, .{ .patch = try patch(a, "{\"halation\":5}"), .by = .claude, .now = 3 });
    s.keepClaude();
    try testing.expect(!s.claudePending());
    try testing.expect(!try s.undoClaude());
    try testing.expectEqual(5, (try s.recipe(a)).halation);
}

test "a folder lists its JPEGs, subfolders included, hidden ones not" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for ([_][]const u8{ "b.jpg", "a.JPG", "trip/c.jpeg", ".photo-editor/thumbs/a.JPG", ".hidden/d.jpg", "notes.txt", "trip/e.png" }) |p| {
        if (std.fs.path.dirname(p)) |d| try tmp.dir.createDirPath(io, d);
        try tmp.dir.writeFile(io, .{ .sub_path = p, .data = "x" });
    }
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const photos = try folders.scan(io, arena.allocator(), testing.allocator, tmp.dir);
    try testing.expectEqual(3, photos.len);
    try testing.expectEqualStrings("a.JPG", photos[0].rel);
    try testing.expectEqualStrings("b.jpg", photos[1].rel);
    try testing.expectEqualStrings("trip/c.jpeg", photos[2].rel);
}

const tools = @import("tools.zig");
const Mcp = @import("mcp.zig");

test "set_edits refuses a field the recipe doesn't have, at any depth" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Recipe = @import("photo-core").Recipe;
    try tools.validate(Recipe, try patch(a, "{\"edits\":{\"exposure\":1},\"colour\":{\"greens\":{\"hue\":3}},\"shaders\":[{\"name\":\"x\",\"params\":{\"anything\":1}}]}"));
    try testing.expectError(error.UnknownField, tools.validate(Recipe, try patch(a, "{\"edits\":{\"bogus\":1}}")));
    try testing.expectError(error.UnknownField, tools.validate(Recipe, try patch(a, "{\"colour\":{\"teal\":{\"hue\":1}}}")));
    try testing.expectError(error.UnknownField, tools.validate(Recipe, try patch(a, "{\"shaders\":[{\"name\":\"x\",\"strenght\":1}]}")));
}

test "a change without a note is summed up in words" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("exposure 0.3, grain amount 25", try tools.summarize(a, try patch(a, "{\"edits\":{\"exposure\":0.3},\"grain\":{\"amount\":25}}")));
}

test "MCP answers only its own host" {
    try testing.expect(Mcp.hostAllowed("127.0.0.1:7777"));
    try testing.expect(Mcp.hostAllowed("localhost:7777"));
    try testing.expect(!Mcp.hostAllowed("evil.example:7777"));
    try testing.expect(!Mcp.hostAllowed("127.0.0.1.evil.example"));
}

test "Claude's tool list is valid JSON, one entry per tool with a schema" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const list = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), tools.definitions, .{});
    const want = [_][]const u8{ "get_view", "set_edits", "open_photo", "list_photos", "undo", "export", "list_looks", "list_shaders", "get_shader", "save_shader", "delete_shader", "bake_look" };
    try testing.expectEqual(want.len, list.array.items.len);
    for (list.array.items, want) |t, name| {
        try testing.expectEqualStrings(name, t.object.get("name").?.string);
        try testing.expectEqualStrings("object", t.object.get("inputSchema").?.object.get("type").?.string);
    }
}

const Library = @import("library.zig");

test "look and shader names can't leave their folder" {
    try testing.expect(Library.validName("split-tone"));
    try testing.expect(Library.validName("Portra 400.cube"));
    try testing.expect(!Library.validName("../x"));
    try testing.expect(!Library.validName(".versions"));
    try testing.expect(!Library.validName("a/b"));
    try testing.expect(Library.validParam("shadows"));
    try testing.expect(!Library.validParam("2x"));
    try testing.expect(!Library.validParam("a;b"));
}

test "a shader saved twice keeps the old version, and only the newest five" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [std.c.PATH_MAX]u8 = undefined;
    const cwd = std.mem.sliceTo(std.c.getcwd(&cwd_buf, cwd_buf.len).?, 0);
    const config = try std.fmt.allocPrint(testing.allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd, tmp.sub_path });
    defer testing.allocator.free(config);
    var lib = try Library.init(testing.allocator, io, config);
    defer lib.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..8) |i| try lib.saveShader(a, "tone", try std.fmt.allocPrint(a, "vec3 effect(vec3 c) {{ return c * {d}.0; }}", .{i}), "{\"description\":\"t\"}", i);
    const sh = try lib.readShader(a, "tone");
    try testing.expect(std.mem.indexOf(u8, sh.source, "7.0") != null);
    var versions = try tmp.dir.openDir(io, "shaders/tone/.versions", .{ .iterate = true });
    defer versions.close(io);
    var n: usize = 0;
    var it = versions.iterate();
    while (try it.next(io)) |e| if (std.mem.endsWith(u8, e.name, ".glsl")) {
        n += 1;
    };
    try testing.expectEqual(Library.versions_kept, n);
    try lib.deleteShader("tone");
    // A new shaders folder starts with the spec's example.
    const left = try lib.shaderNames(a);
    try testing.expectEqual(1, left.len);
    try testing.expectEqualStrings("split-tone", left[0]);
}

const Exporter = @import("exporter.zig");

test "an export never takes a name that's already there" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [std.c.PATH_MAX]u8 = undefined;
    const cwd = std.mem.sliceTo(std.c.getcwd(&cwd_buf, cwd_buf.len).?, 0);
    const folder = try std.fmt.allocPrint(testing.allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd, tmp.sub_path });
    defer testing.allocator.free(folder);
    const first = try Exporter.outputPath(testing.allocator, io, folder, "trip/P1.JPG", "-edit", ".jpg");
    defer testing.allocator.free(first);
    try testing.expect(std.mem.endsWith(u8, first, "/P1-edit.jpg"));
    try tmp.dir.writeFile(io, .{ .sub_path = "P1-edit.jpg", .data = "x" });
    const second = try Exporter.outputPath(testing.allocator, io, folder, "trip/P1.JPG", "-edit", ".jpg");
    defer testing.allocator.free(second);
    try testing.expect(std.mem.endsWith(u8, second, "/P1-edit-2.jpg"));
}
