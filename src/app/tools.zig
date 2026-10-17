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
const Library = @import("library.zig");

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
    \\ "inputSchema":{"type":"object","properties":{"names":{"type":"array","items":{"type":"string"}},"format":{"type":"string","enum":["jpeg","png"]},"quality":{"type":"number","minimum":50,"maximum":100},"long_edge":{"type":"number","description":"Longest side in pixels; 0 = original size"},"gps":{"type":"boolean","description":"Keep the GPS location (default: the app's setting)"}}}},
    \\{"name":"list_looks","title":"List looks",
    \\ "description":"The installed looks: .cube LUTs in the looks folder, by file name (use it as look.name in set_edits) and title.",
    \\ "inputSchema":{"type":"object","properties":{}}},
    \\{"name":"list_shaders","title":"List shaders",
    \\ "description":"The installed shaders, with their descriptions and parameters.",
    \\ "inputSchema":{"type":"object","properties":{}}},
    \\{"name":"get_shader","title":"Read a shader",
    \\ "description":"A shader's GLSL source and its shader.json (description, params, needs).",
    \\ "inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}},
    \\{"name":"save_shader","title":"Write a shader",
    \\ "description":"Creates or replaces a shader, then applies it to the open photo and returns the view. The source defines `vec3 effect(vec3 c)` on display-encoded sRGB colour (0..1); helpers luma(c), srgbDecode(c), srgbEncode(c), hash12(vec2) are there. Each param is a `uniform float u_<name>` (declared for you) with a slider. To look at neighbouring pixels use texture(u_image, v_uv + offset * u_texel); u_resolution is the render's size in pixels. needs: [\\\"depth\\\"] gives u_depth (0 near, 1 far; flat until depth arrives). It's compiled first: a shader with errors is not saved and the errors come back. The previous version is kept (the last five).",
    \\ "inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"letters, digits, - and _"},"source":{"type":"string"},"description":{"type":"string"},"params":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"label":{"type":"string"},"default":{"type":"number"},"min":{"type":"number"},"max":{"type":"number"}},"required":["name"]}},"needs":{"type":"array","items":{"type":"string"}},"strength":{"type":"number","description":"0..100 on the open photo, default 100"},"apply":{"type":"boolean","description":"Add it to the open photo (default true)"}},"required":["name","source"]}},
    \\{"name":"delete_shader","title":"Delete a shader",
    \\ "description":"Removes a shader from the shaders folder.",
    \\ "inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}},
    \\{"name":"bake_look","title":"Bake the colour into a look",
    \\ "description":"Turns the open photo's colour settings (adjustments, look and colour-only shaders; not crop, grain, halation or vignette) into a new .cube LUT in the looks folder, usable anywhere.",
    \\ "inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"File name; .cube is added"},"size":{"type":"number","enum":[33,65]}},"required":["name"]}}
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
        error.BadName => "names are letters, digits, spaces, - and _",
        error.BadParamName => "a parameter name must be a GLSL name (letters, digits, _)",
        error.NoSuchShader, error.FileNotFound => "no such shader (see list_shaders)",
        error.ExportBusy => "an export is already running",
        error.BadArguments => "missing or wrong arguments (see the tool's description)",
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
    if (eql(name, "list_looks") or eql(name, "list_shaders")) return listLibrary(app, a, call, eql(name, "list_looks"));
    if (eql(name, "get_shader")) {
        const sh = try app.library.readShader(a, string(args, "name") orelse return error.BadArguments);
        const text = try std.fmt.allocPrint(a, "shader.json:\n{s}\n\nshader.glsl:\n{s}", .{ sh.json_text, sh.source });
        return call.finish(try Mcp.textResult(app.gpa, text, false));
    }
    if (eql(name, "save_shader")) return saveShader(app, a, call, args);
    if (eql(name, "delete_shader")) {
        const n = string(args, "name") orelse return error.BadArguments;
        try app.library.deleteShader(n);
        return call.finish(try Mcp.textResult(app.gpa, try std.fmt.allocPrint(a, "Deleted the shader {s}.", .{n}), false));
    }
    if (eql(name, "bake_look")) return bakeLook(app, a, call, args);
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

fn listLibrary(app: *App, a: std.mem.Allocator, call: *Mcp.Call, looks: bool) !void {
    var out: Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_1 } };
    try s.beginObject();
    try s.objectField("folder");
    try s.write(if (looks) app.library.looks_dir else app.library.shaders_dir);
    if (looks) {
        try s.objectField("looks");
        try s.write(try app.library.lookNames(a));
    } else {
        try s.objectField("shaders");
        try s.beginArray();
        for (try app.library.shaderNames(a)) |n| {
            const sh = app.library.readShader(a, n) catch continue;
            try s.write(.{ .name = n, .description = sh.json.description, .params = sh.json.params, .needs = sh.json.needs });
        }
        try s.endArray();
    }
    try s.endObject();
    call.finish(try Mcp.textResult(app.gpa, out.written(), false));
}

// save_shader waits for the page to compile it.
const PendingShader = struct {
    call: *Mcp.Call,
    name: []u8,
    source: []u8,
    json: []u8,
    strength: f32,
    apply: bool,

    fn free(p: *PendingShader, gpa: std.mem.Allocator) void {
        gpa.free(p.name);
        gpa.free(p.source);
        gpa.free(p.json);
        gpa.destroy(p);
    }
};

fn saveShader(app: *App, a: std.mem.Allocator, call: *Mcp.Call, args: std.json.Value) !void {
    const name = string(args, "name") orelse return error.BadArguments;
    const source = string(args, "source") orelse return error.BadArguments;
    if (!Library.validName(name)) return error.BadName;
    var def: Library.ShaderJson = .{ .description = string(args, "description") orelse "" };
    if (args.object.get("params")) |p| def.params = std.json.parseFromValueLeaky([]const Library.Param, a, p, .{ .ignore_unknown_fields = true }) catch return error.BadArguments;
    if (args.object.get("needs")) |n| def.needs = std.json.parseFromValueLeaky([]const []const u8, a, n, .{}) catch return error.BadArguments;
    for (def.params) |p| if (!Library.validParam(p.name)) return error.BadParamName;
    const json = try std.json.Stringify.valueAlloc(a, def, .{ .whitespace = .indent_2 });
    const strength: f32 = if (args.object.get("strength")) |v| switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => 100,
    } else 100;
    const apply = if (args.object.get("apply")) |v| v != .bool or v.bool else true;

    const pending = try app.gpa.create(PendingShader);
    pending.* = .{ .call = call, .name = try app.gpa.dupe(u8, name), .source = try app.gpa.dupe(u8, source), .json = try app.gpa.dupe(u8, json), .strength = strength, .apply = apply };
    const fields = try std.fmt.allocPrint(a, "\"name\":{f},\"source\":{f},\"def\":{s}", .{ std.json.fmt(name, .{}), std.json.fmt(source, .{}), json });
    app.ask("compileShader", fields, pending, compiled, 10_000);
}

fn compiled(ctx: *anyopaque, app: *App, a: std.mem.Allocator, answer: std.json.Value) void {
    const p: *PendingShader = @ptrCast(@alignCast(ctx));
    defer p.free(app.gpa);
    const finish = struct {
        fn text(call: *Mcp.Call, gpa: std.mem.Allocator, t: []const u8, is_error: bool) void {
            call.finish(Mcp.textResult(gpa, t, is_error) catch return);
        }
    }.text;
    if (answer == .null) return finish(p.call, app.gpa, "The app didn't compile the shader (no answer from the page).", true);
    if (string(answer, "error")) |err| if (err.len > 0) {
        const t = std.fmt.allocPrint(a, "The shader didn't compile, so nothing was saved. Lines count from the top of your source.\n{s}", .{err}) catch err;
        return finish(p.call, app.gpa, t, true);
    };
    app.library.saveShader(a, p.name, p.source, p.json, app.now()) catch |err| {
        return finish(p.call, app.gpa, std.fmt.allocPrint(a, "Compiled, but saving failed: {t}", .{err}) catch "saving failed", true);
    };
    // The page hears now, not when the file watcher settles: the screenshot needs the new version.
    app.emit("library", "{}");
    if (!p.apply or app.current == null) return finish(p.call, app.gpa, "Saved.", false);

    // On the open photo: added at the end, or this one's strength changed.
    const s = app.currentSession() catch return finish(p.call, app.gpa, "Saved.", false);
    const r = s.recipe(a) catch return finish(p.call, app.gpa, "Saved.", false);
    var list: std.ArrayList(Recipe.ShaderUse) = .empty;
    var found = false;
    for (r.shaders) |use| {
        var u = use;
        if (eql(use.name, p.name)) {
            found = true;
            u.strength = p.strength;
            u.enabled = true;
        }
        list.append(a, u) catch return;
    }
    if (!found) list.append(a, .{ .name = p.name, .strength = p.strength }) catch return;
    const patch_text = std.fmt.allocPrint(a, "{{\"shaders\":{f}}}", .{std.json.fmt(list.items, .{})}) catch return;
    const patch = std.json.parseFromSliceLeaky(std.json.Value, a, patch_text, .{}) catch return;
    const note = std.fmt.allocPrint(a, "shader {s} {d}%", .{ p.name, p.strength }) catch "";
    _ = s.change(a, .{ .patch = patch, .by = .claude, .now = app.now(), .note = note }) catch return;
    app.changed();
    app.emitPhoto();
    view(app, a, p.call, "Saved and applied.") catch |err| finish(p.call, app.gpa, @errorName(err), true);
}

const PendingBake = struct { call: *Mcp.Call, name: []u8 };

fn bakeLook(app: *App, a: std.mem.Allocator, call: *Mcp.Call, args: std.json.Value) !void {
    _ = try app.currentSession();
    const raw = string(args, "name") orelse return error.BadArguments;
    const name = if (std.ascii.endsWithIgnoreCase(raw, ".cube")) raw else try std.fmt.allocPrint(a, "{s}.cube", .{raw});
    if (!Library.validName(name)) return error.BadName;
    const size: u32 = if (args.object.get("size")) |v| (if (v == .integer and v.integer == 65) 65 else 33) else 33;
    const pending = try app.gpa.create(PendingBake);
    pending.* = .{ .call = call, .name = try app.gpa.dupe(u8, name) };
    app.ask("bakeLook", try std.fmt.allocPrint(a, "\"size\":{d},\"title\":{f}", .{ size, std.json.fmt(name[0 .. name.len - 5], .{}) }), pending, baked, 20_000);
}

fn baked(ctx: *anyopaque, app: *App, a: std.mem.Allocator, answer: std.json.Value) void {
    const p: *PendingBake = @ptrCast(@alignCast(ctx));
    defer {
        app.gpa.free(p.name);
        app.gpa.destroy(p);
    }
    const cube = string(answer, "cube") orelse "";
    const t, const is_error = if (cube.len == 0)
        .{ "The page couldn't bake the look.", true }
    else if (app.library.saveLook(a, p.name, cube)) |_|
        .{ std.fmt.allocPrint(a, "Baked {s} into the looks folder; use it with set_edits look.name \"{s}\".", .{ p.name, p.name }) catch "Baked.", false }
    else |err|
        .{ std.fmt.allocPrint(a, "Baking worked, saving failed: {t}", .{err}) catch "saving failed", true };
    p.call.finish(Mcp.textResult(app.gpa, t, is_error) catch return);
}
