//! Claude's tools (SPEC.md, Claude Code integration), run on the main loop against the live app.
//! A tool that changes the photo answers with the new view: what's open, the recipe, and a
//! screenshot of the rendered photo that the page draws with the same pipeline.
const std = @import("std");
const Io = std.Io;
const core = @import("photo-core");
const Recipe = core.Recipe;

const App = @import("app.zig");
const Mcp = @import("mcp.zig");
const Window = @import("window.zig");

const log = std.log.scoped(.tools);

pub const screenshot_edge = 1024;
// The page answers a screenshot within a frame or two, or after loading a photo.
const screenshot_timeout_ms = 15_000;

pub const instructions =
    \\Doka is the photo editor open on this computer; these tools edit the photo on its screen, live.
    \\- Call get_view before editing: it shows the open photo, its current edits and a screenshot.
    \\- Make one change at a time with set_edits, then look at the screenshot it returns before the next.
    \\- Say in set_edits' note, in a few words, what you changed ("Film look 70%, highlights −15"); the
    \\  user sees it with Keep / Undo buttons, and can undo it.
    \\- Edits never touch the original file: they are a recipe the app keeps beside it. Exports always
    \\  keep the camera, lens and date metadata; leave GPS as it is unless asked.
    \\- Looks are .cube LUTs (list_looks); shaders are small GLSL effects (list_shaders, save_shader).
    \\  Use a look for the colour base, a shader for character on top.
    \\- Afterwards, tell the user briefly what you changed.
;

// The tools Claude Code lists. Recipe fields and ranges as in SPEC.md, Recipe format.
pub const definitions =
    \\[
    \\{"name":"get_view","title":"See the open photo",
    \\ "description":"What the user sees now: the folder, the open photo (name, camera, lens, exposure), the active tab, the photo's current edits (only values that differ from the default), any change of yours awaiting Keep/Undo, and a screenshot of the rendered photo.",
    \\ "inputSchema":{"type":"object","properties":{}}},
    \\{"name":"set_edits","title":"Edit the open photo",
    \\ "description":"Changes the open photo's edits, live. Give only the fields to change; everything else stays. Set a field to its default (0, or look name 'none') to remove it. Returns the new view with a screenshot. Ranges: exposure -5..5 (stops); temperature, tint, contrast, highlights, shadows, saturation -100..100; look.strength, halation, vignette, grain.amount, grain.size, detail.sharpen, detail.noise 0..100; colour bands (reds, oranges, yellows, greens, blues, purples) hue/sat/light -100..100; crop.rect [x,y,w,h] 0..1 of the rotated photo, crop.rotate 0/90/180/270, crop.straighten -45..45 degrees, crop.aspect original|free|1:1|4:5|3:2|16:9. shaders replaces the whole list: [{name, strength 0..100, enabled, params:{name:value}}].",
    \\ "inputSchema":{"type":"object","properties":{
    \\  "edits":{"type":"object","properties":{"exposure":{"type":"number","minimum":-5,"maximum":5},"temperature":{"type":"number","minimum":-100,"maximum":100},"tint":{"type":"number","minimum":-100,"maximum":100},"contrast":{"type":"number","minimum":-100,"maximum":100},"highlights":{"type":"number","minimum":-100,"maximum":100},"shadows":{"type":"number","minimum":-100,"maximum":100},"saturation":{"type":"number","minimum":-100,"maximum":100}}},
    \\  "look":{"type":"object","properties":{"name":{"type":"string","description":"A .cube file from list_looks, or 'none'"},"strength":{"type":"number","minimum":0,"maximum":100}}},
    \\  "shaders":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"strength":{"type":"number"},"enabled":{"type":"boolean"},"params":{"type":"object","additionalProperties":{"type":"number"}}},"required":["name"]}},
    \\  "colour":{"type":"object","description":"Per-colour mixer: {band: {hue, sat, light}}","additionalProperties":{"type":"object","properties":{"hue":{"type":"number"},"sat":{"type":"number"},"light":{"type":"number"}}}},
    \\  "halation":{"type":"number","minimum":0,"maximum":100},
    \\  "vignette":{"type":"number","minimum":0,"maximum":100},
    \\  "grain":{"type":"object","properties":{"amount":{"type":"number","minimum":0,"maximum":100},"size":{"type":"number","minimum":0,"maximum":100}}},
    \\  "detail":{"type":"object","properties":{"sharpen":{"type":"number","minimum":0,"maximum":100},"noise":{"type":"number","minimum":0,"maximum":100}}},
    \\  "crop":{"type":"object","properties":{"aspect":{"type":"string"},"straighten":{"type":"number"},"rotate":{"type":"number"},"flip":{"type":"boolean"},"rect":{"type":"array","items":{"type":"number"},"minItems":4,"maxItems":4}}},
    \\  "note":{"type":"string","description":"What you changed, in a few words, shown to the user beside Keep / Undo"}}}},
    \\{"name":"open_photo","title":"Open another photo",
    \\ "description":"Opens a photo of the folder by name (its path in the folder, or just the file name), or the next or previous one. Returns the new view.",
    \\ "inputSchema":{"type":"object","properties":{"name":{"type":"string"},"direction":{"type":"string","enum":["next","previous"]}}}},
    \\{"name":"list_photos","title":"List the folder's photos",
    \\ "description":"The open folder's photos, in order, each with whether it has edits.",
    \\ "inputSchema":{"type":"object","properties":{}}},
    \\{"name":"undo","title":"Undo the last change",
    \\ "description":"Undoes the last change to the open photo, whoever made it. Returns the new view.",
    \\ "inputSchema":{"type":"object","properties":{}}},
    \\{"name":"export","title":"Export photos",
    \\ "description":"Exports the open photo, or the named ones, with their edits, to the export folder (camera, lens, exposure and date always kept). Options default to the app's export settings.",
    \\ "inputSchema":{"type":"object","properties":{"names":{"type":"array","items":{"type":"string"}},"format":{"type":"string","enum":["jpeg","png"]},"quality":{"type":"number","minimum":50,"maximum":100},"long_edge":{"type":"number","description":"Longest side in pixels; 0 = original size"},"gps":{"type":"boolean","description":"Keep the GPS location (default: the app's setting)"}}}}
    \\]
;

const Context = struct {
    app: *App,
    gpa: std.mem.Allocator,
};

/// Runs `call` on the main loop; the result goes back through `call.finish`.
pub fn run(app: *App, call: *Mcp.Call) void {
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const args = std.json.parseFromSliceLeaky(std.json.Value, a, call.arguments, .{}) catch .null;
    dispatch(app, a, call, args) catch |err| {
        const msg = std.fmt.allocPrint(a, "{s} failed: {s}", .{ call.name, explain(err) }) catch "failed";
        call.finish(Mcp.textResult(app.gpa, msg, true) catch return);
    };
}

fn explain(err: anyerror) []const u8 {
    return switch (err) {
        error.NoFolder => "no folder is open in the app",
        error.NoPhoto => "no photo is open",
        error.NoSuchPhoto => "no photo by that name in the open folder (see list_photos)",
        error.AmbiguousName => "more than one photo has that name; give its path in the folder",
        error.UnknownField => "set_edits got a field it doesn't know (see its description)",
        error.UnknownTool => "no such tool",
        else => @errorName(err),
    };
}

fn dispatch(app: *App, a: std.mem.Allocator, call: *Mcp.Call, args: std.json.Value) !void {
    const name = call.name;
    if (eql(name, "get_view")) return view(app, a, call, null);
    if (eql(name, "list_photos")) return listPhotos(app, a, call);
    if (eql(name, "set_edits")) {
        const s = try app.currentSession();
        if (args != .object) return error.BadArguments;
        var patch = try args.object.clone(a);
        var note: []const u8 = "";
        if (patch.fetchOrderedRemove("note")) |n| if (n.value == .string) {
            note = n.value.string;
        };
        var it = patch.iterator();
        while (it.next()) |e| if (!isRecipeField(e.key_ptr.*)) return error.UnknownField;
        try validate(Recipe, .{ .object = patch });
        if (note.len == 0) note = try summarize(a, .{ .object = patch });
        _ = try s.change(a, .{ .patch = .{ .object = patch }, .by = .claude, .now = app.now(), .note = note });
        app.changed();
        app.emitPhoto();
        return view(app, a, call, null);
    }
    if (eql(name, "open_photo")) {
        const f = &(app.folder orelse return error.NoFolder);
        const i = if (string(args, "name")) |n| try find(f, n) else if (string(args, "direction")) |d| blk: {
            const cur = app.current orelse 0;
            if (eql(d, "next")) break :blk @min(cur + 1, f.photos.len - 1);
            if (eql(d, "previous")) break :blk cur -| 1;
            return error.BadArguments;
        } else return error.BadArguments;
        try app.open(i);
        app.emitState();
        return view(app, a, call, null);
    }
    if (eql(name, "undo")) {
        const s = try app.currentSession();
        if (!try s.undo()) return call.finish(try Mcp.textResult(app.gpa, "Nothing to undo.", false));
        app.changed();
        app.emitPhoto();
        return view(app, a, call, "Undid the last change.");
    }
    if (eql(name, "export")) return app.exportForClaude(call, args);
    return error.UnknownTool;
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn string(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .string) f.string else null;
}

fn isRecipeField(name: []const u8) bool {
    inline for (@typeInfo(Recipe).@"struct".fields) |f| {
        if (eql(f.name, name) and !eql(name, "version") and !eql(name, "updatedBy") and !eql(name, "updatedAt")) return true;
    }
    return false;
}

/// Every key in `v` names a field of `T`, at any depth: a typo fails instead of being ignored.
pub fn validate(comptime T: type, v: std.json.Value) !void {
    switch (@typeInfo(T)) {
        .@"struct" => |st| {
            if (@hasField(T, "map")) return; // shader params: any names
            if (v != .object) return;
            var it = v.object.iterator();
            outer: while (it.next()) |e| {
                inline for (st.fields) |f| if (eql(f.name, e.key_ptr.*)) {
                    try validate(f.type, e.value_ptr.*);
                    continue :outer;
                };
                return error.UnknownField;
            }
        },
        .pointer => |p| if (p.child != u8 and v == .array) for (v.array.items) |item| try validate(p.child, item),
        else => {},
    }
}

/// A photo by its path in the folder, or by file name when that's unique.
pub fn find(f: *const App.Folder, name: []const u8) !usize {
    if (f.index(name)) |i| return i;
    var found: ?usize = null;
    for (f.photos, 0..) |p, i| {
        const base = std.fs.path.basename(p.rel);
        if (std.ascii.eqlIgnoreCase(base, name) or std.ascii.eqlIgnoreCase(p.rel, name)) {
            if (found != null) return error.AmbiguousName;
            found = i;
        }
    }
    return found orelse error.NoSuchPhoto;
}

/// "exposure 0.3, grain amount 25": the change in words, when Claude gave no note.
pub fn summarize(a: std.mem.Allocator, patch: std.json.Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try summarizeInto(a, &out, "", patch);
    return out.items;
}

fn summarizeInto(a: std.mem.Allocator, out: *std.ArrayList(u8), prefix: []const u8, v: std.json.Value) !void {
    switch (v) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                const key = if (eql(prefix, "edits") or prefix.len == 0) e.key_ptr.* else try std.fmt.allocPrint(a, "{s} {s}", .{ prefix, e.key_ptr.* });
                try summarizeInto(a, out, key, e.value_ptr.*);
            }
        },
        else => {
            if (out.items.len > 0) try out.appendSlice(a, ", ");
            try out.print(a, "{s} {f}", .{ prefix, std.json.fmt(v, .{}) });
        },
    }
}

fn listPhotos(app: *App, a: std.mem.Allocator, call: *Mcp.Call) !void {
    const f = &(app.folder orelse return error.NoFolder);
    var out: Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_1 } };
    try s.beginObject();
    try s.objectField("folder");
    try s.write(f.path);
    try s.objectField("open");
    try s.write(if (app.current) |i| f.photos[i].rel else null);
    try s.objectField("photos");
    try s.beginArray();
    for (f.photos) |p| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(p.rel);
        try s.objectField("edited");
        try s.write(p.edited);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    call.finish(try Mcp.textResult(app.gpa, out.written(), false));
}

/// The view as text, then the page's screenshot of it (`Screenshot.done`).
pub fn view(app: *App, a: std.mem.Allocator, call: *Mcp.Call, lead: ?[]const u8) !void {
    var out: Io.Writer.Allocating = .init(a);
    if (lead) |l| try out.writer.print("{s}\n", .{l});
    try writeView(app, a, &out.writer);
    const text = try app.gpa.dupe(u8, out.written());
    if (app.current == null) {
        defer app.gpa.free(text);
        return call.finish(try Mcp.textResult(app.gpa, text, false));
    }
    app.requestScreenshot(.{ .call = call, .text = text });
}

fn writeView(app: *App, a: std.mem.Allocator, w: *Io.Writer) !void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    const f = app.folder orelse {
        try s.objectField("folder");
        try s.write(null);
        try s.objectField("hint");
        try s.write("No folder is open; ask the user to open one in the app.");
        return s.endObject();
    };
    try s.objectField("folder");
    try s.write(f.path);
    try s.objectField("tab");
    try s.write(app.tab);
    if (app.current) |i| {
        const sess = try app.session(i);
        const rel = f.photos[i].rel;
        const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ f.path, rel }, 0);
        const info = core.decode.info(a, path) catch core.decode.Info{};
        try s.objectField("photo");
        try s.write(rel);
        try s.objectField("position");
        try s.print("\"{d} of {d}\"", .{ i + 1, f.photos.len });
        try s.objectField("camera");
        try s.write(try std.fmt.allocPrint(a, "{s} {s} · {s} · {s} s · f/{s} · ISO {s} · {s} mm · {d}×{d} · taken {s}", .{
            info.make, info.model, info.lens, info.exposure, info.aperture, info.iso, info.focal_length, info.width, info.height, info.taken,
        }));
        try s.objectField("recipe");
        try s.beginWriteRaw();
        try s.writer.writeAll(sess.json);
        s.endWriteRaw();
        try s.objectField("awaitingKeepOrUndo");
        try s.write(if (sess.claudePending()) sess.claude_note.items else null);
    } else {
        try s.objectField("photo");
        try s.write(null);
    }
    try s.endObject();
}

/// A view waiting for its screenshot.
pub const Screenshot = struct {
    call: *Mcp.Call,
    // Owned by the app's allocator.
    text: []u8,
    id: u32 = 0,
    timer: c_uint = 0,
};

/// The page's screenshot (base64 JPEG, or empty when it couldn't draw): the call's answer.
pub fn finishScreenshot(app: *App, shot: Screenshot, jpeg_base64: []const u8) void {
    defer app.gpa.free(shot.text);
    const result = if (jpeg_base64.len > 0)
        std.fmt.allocPrint(app.gpa, "{{\"content\":[{{\"type\":\"text\",\"text\":{f}}},{{\"type\":\"image\",\"data\":\"{s}\",\"mimeType\":\"image/jpeg\"}}],\"isError\":false}}", .{ std.json.fmt(shot.text, .{}), jpeg_base64 })
    else
        Mcp.textResult(app.gpa, shot.text, false);
    shot.call.finish(result catch return log.err("out of memory", .{}));
}
