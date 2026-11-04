//! Claude's tools (SPEC.md, Claude Code integration), run on the main loop against the live app.
//! A tool that changes the photo answers with the new view: what's open, the recipe, and a
//! screenshot of the rendered photo drawn with the same pipeline.
const std = @import("std");
const Io = std.Io;
const core = @import("photo-core");
const Recipe = core.Recipe;

const App = @import("app.zig");
const Mcp = @import("mcp.zig");
const Sheet = @import("sheet.zig");
const Library = @import("library.zig");

const log = std.log.scoped(.tools);

pub const screenshot_edge = 1024;
// The page answers a screenshot within a frame or two, or after loading a photo.
const screenshot_timeout_ms = 15_000;

pub const instructions =
    \\Doka is the photo editor open on this computer; these tools edit the photo on its screen, live.
    \\- Call get_view before editing: it shows the open photo, its current edits and a screenshot.
    \\- Make one change at a time with set_edits, then look at the screenshot it returns before the next.
    \\- Your edits show on the user's screen as you make them; they undo them with Ctrl+Z, one step at a time.
    \\- Edits never touch the original file: they are a recipe the app keeps beside it. Exports always
    \\  keep the camera, lens and date metadata; leave GPS as it is unless asked.
    \\- Looks are .cube LUTs (list_looks); shaders are small GLSL effects (list_shaders, save_shader).
    \\  Use a look for the colour base, a shader for character on top.
    \\- To change part of the photo ("darken the sky", "lift the subject"), use masks in set_edits. Look at
    \\  the screenshot, place the mask, then call get_view with show_mask to check where it landed.
    \\- For a person or object, mask_subject follows its outline: give points on it, and points on what it
    \\  wrongly took, and look at the red in the screenshot it returns. Gradients don't need the download.
    \\- Asked to choose photos: look through the folder with contact_sheet (30 at a time is about 300 px each),
    \\  each numbered with its position; everywhere a tool takes photos, those numbers work. Then compare
    \\  the candidates on a sheet of 6 to 12. Take one of a burst, and variety over near-copies. Each line has
    \\  a sharpness number: of the sharpest part, only worth comparing within a scene. Keep your choice with
    \\  pick_photos; it stays, and the user sees it. Don't edit what you chose unless asked.
    \\- Edit one photo at a time: open_photo it, then set_edits as above. Change one mask with edit_mask, not the whole list.
    \\- A screenshot is small. Before you call something sharp or clean, or a mask's edge good, look with get_view zoom; check a
    \\  mask you placed by eye with show_mask; and judge a finished edit with get_view compare.
    \\- Afterwards, tell the user briefly what you changed.
;

// The tools Claude Code lists. Recipe fields and ranges as in SPEC.md, Recipe format.
pub const definitions =
    \\[
    \\{"name":"get_view","title":"See the open photo",
    \\ "description":"What the user sees now: the folder, the open photo (name, camera, lens, exposure), the active tab, the photo's current edits (only values that differ from the default), a screenshot of the rendered photo, and its tones measured at full screenshot size: % of clipped highlights (any channel at 255, and per channel), % of crushed shadows, mean brightness and a 16-bin histogram. Give show_mask (a mask's position in the recipe's masks, from 0) to see that mask painted red in the screenshot, to check where it is; nothing in the photo changes. Give zoom to judge what a small picture hides: focus, skin, noise, a mask's edge (with show_mask). Give compare to judge the edit against the original. Neither measures tones.",
    \\ "inputSchema":{"type":"object","properties":{"show_mask":{"type":"integer","minimum":0},"zoom":{"type":"object","description":"Look in detail: at [x,y], 0..1 of the screenshot you saw (the photo as cropped), and size, how much to show as a share of its long edge (0.2 by default; about 0.1 for a face). Up to 100%, the photo's own pixels.","properties":{"at":{"type":"array","items":{"type":"number"},"minItems":2,"maxItems":2},"size":{"type":"number","minimum":0.01,"maximum":1}},"required":["at"]},"compare":{"type":"boolean","description":"The original on the left, with the edits on the right, the same crop and place"}}}},
    \\{"name":"set_edits","title":"Edit the open photo",
    \\ "description":"Changes the open photo's edits, live. Give only the fields to change; everything else stays. Set a field to its default (0, or look name 'none') to remove it. Give `photo` (the name get_view shows) and nothing changes if another photo is open by now. Returns the new view with a screenshot. Ranges: exposure -5..5 (stops); temperature, tint, contrast, highlights, shadows, whites, blacks, vibrance, saturation -100..100 (whites and blacks move only the ends of the tones; vibrance goes easy on what's vivid and on skin); curve [[in,out],...] 0..1, up to 12, the whole photo's tone curve in display values, before the look; look.strength, halation, vignette, grain.amount, grain.size, detail.sharpen, detail.noise 0..100; colour bands (reds, oranges, yellows, greens, blues, purples) hue/sat/light -100..100; crop.rect [x,y,w,h] 0..1 of the rotated photo, crop.rotate 0/90/180/270 (clockwise), crop.straighten -45..45 degrees (+ turns the photo clockwise, - counter-clockwise), crop.aspect original|free|1:1|4:5|3:2|16:9 (literal: 4:5 is portrait). Give crop.aspect and/or crop.focus [x,y] (0..1, the point to keep in the middle) without a rect and the app fits the biggest crop of that aspect around it. shaders replaces the whole list: [{name, strength 0..100, enabled, params:{name:value}}]. masks also replaces the whole list, up to 8: part of the photo with edits of its own, applied after the look, in order; [] removes them. Each mask: name (shown to the user, like 'Sky'), enabled, shape whole|linear|radial, invert (everything but what's selected), edits and colour as above, blur 0..100 (a lens-like blur, up to 2.5% of the long edge; what's outside the mask doesn't bleed in), and what selects: linear: from [x,y] (full effect) and to [x,y] (fades to nothing there); radial: centre [x,y], radius [rx,ry] as shares of the photo's width and height, feather 0..100 (% of the radius it fades over, inwards from the edge); any shape: brightness {min,max} 0..100 (0 black, 100 white) and hue {centre, width} in degrees (reds 25, oranges 60, yellows 100, greens 145, blues 250, purples 315; width to each side, 0 = any colour; greys never match a hue). Limits read the original photo, so other edits don't move them. Mask coordinates are 0..1 of the whole photo as decoded, upright, (0,0) top-left: NOT of the crop or rotated view, so with a crop or rotation in the recipe convert from what the screenshot shows.",
    \\ "inputSchema":{"type":"object","properties":{
    \\  "edits":{"type":"object","properties":{"exposure":{"type":"number","minimum":-5,"maximum":5},"temperature":{"type":"number","minimum":-100,"maximum":100},"tint":{"type":"number","minimum":-100,"maximum":100},"contrast":{"type":"number","minimum":-100,"maximum":100},"highlights":{"type":"number","minimum":-100,"maximum":100},"shadows":{"type":"number","minimum":-100,"maximum":100},"whites":{"type":"number","minimum":-100,"maximum":100},"blacks":{"type":"number","minimum":-100,"maximum":100},"vibrance":{"type":"number","minimum":-100,"maximum":100},"saturation":{"type":"number","minimum":-100,"maximum":100}}},
    \\  "curve":{"type":"array","maxItems":12,"description":"The whole photo's tone curve, [[in,out],...], 0..1, black to white; [] or null is straight","items":{"type":"array","items":{"type":"number"},"minItems":2,"maxItems":2}},
    \\  "look":{"type":"object","properties":{"name":{"type":"string","description":"A .cube file from list_looks, or 'none'"},"strength":{"type":"number","minimum":0,"maximum":100}}},
    \\  "shaders":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"strength":{"type":"number"},"enabled":{"type":"boolean"},"params":{"type":"object","additionalProperties":{"type":"number"}}},"required":["name"]}},
    \\  "colour":{"type":"object","description":"Per-colour mixer: {band: {hue, sat, light}}","additionalProperties":{"type":"object","properties":{"hue":{"type":"number"},"sat":{"type":"number"},"light":{"type":"number"}}}},
    \\  "halation":{"type":"number","minimum":0,"maximum":100},
    \\  "vignette":{"type":"number","minimum":0,"maximum":100},
    \\  "grain":{"type":"object","properties":{"amount":{"type":"number","minimum":0,"maximum":100},"size":{"type":"number","minimum":0,"maximum":100}}},
    \\  "detail":{"type":"object","properties":{"sharpen":{"type":"number","minimum":0,"maximum":100},"noise":{"type":"number","minimum":0,"maximum":100}}},
    \\  "masks":{"type":"array","maxItems":8,"items":{"type":"object","properties":{"name":{"type":"string"},"enabled":{"type":"boolean"},"shape":{"type":"string","enum":["whole","linear","radial"]},"from":{"type":"array","items":{"type":"number"},"minItems":2,"maxItems":2},"to":{"type":"array","items":{"type":"number"},"minItems":2,"maxItems":2},"centre":{"type":"array","items":{"type":"number"},"minItems":2,"maxItems":2},"radius":{"type":"array","items":{"type":"number"},"minItems":2,"maxItems":2},"feather":{"type":"number","minimum":0,"maximum":100},"brightness":{"type":"object","properties":{"min":{"type":"number","minimum":0,"maximum":100},"max":{"type":"number","minimum":0,"maximum":100}}},"hue":{"type":"object","properties":{"centre":{"type":"number","minimum":0,"maximum":360},"width":{"type":"number","minimum":0,"maximum":180}}},"invert":{"type":"boolean"},"blur":{"type":"number","minimum":0,"maximum":100},"edits":{"type":"object"},"colour":{"type":"object"}}}},
    \\  "crop":{"type":"object","properties":{"aspect":{"type":"string"},"focus":{"type":"array","items":{"type":"number"},"minItems":2,"maxItems":2},"straighten":{"type":"number"},"rotate":{"type":"number"},"flip":{"type":"boolean"},"rect":{"type":"array","items":{"type":"number"},"minItems":4,"maxItems":4}}},
    \\  "photo":{"type":"string","description":"The photo you mean to edit; refused if another one is open"}}}},
    \\{"name":"edit_mask","title":"Change one mask",
    \\ "description":"Changes one mask of the open photo, and leaves the others alone: only the fields given change, edits and colour field by field. mask is its position from 0, or its name. Fields as a mask in set_edits; a subject's outline changes through mask_subject. remove true takes the mask away. show true paints it red in the answer. Returns the new view.",
    \\ "inputSchema":{"type":"object","properties":{"mask":{"type":["integer","string"],"description":"Its position from 0, or its name"},"remove":{"type":"boolean"},"show":{"type":"boolean"},"name":{"type":"string"},"enabled":{"type":"boolean"},"from":{"type":"array"},"to":{"type":"array"},"centre":{"type":"array"},"radius":{"type":"array"},"feather":{"type":"number"},"brightness":{"type":"object"},"hue":{"type":"object"},"invert":{"type":"boolean"},"blur":{"type":"number"},"edits":{"type":"object"},"colour":{"type":"object"},"photo":{"type":"string","description":"The photo you mean to edit; refused if another one is open"}},"required":["mask"]}},
    \\{"name":"mask_subject","title":"Mask a person or object",
    \\ "description":"Finds a person or object from points on it, follows its outline, and adds it as a mask with these edits (or changes the mask at position `mask`). Takes a second or two the first time on a photo, far less after. Returns the view with that mask painted red: check it, and call again with `mask` and more points if it took too much or too little. Points are [x,y], 0..1 of the whole photo as decoded, upright, (0,0) top-left: NOT of the crop or rotated view. Everything else as a mask in set_edits. Needs scripts/subject-model.py to have been run once.",
    \\ "inputSchema":{"type":"object","properties":{"points":{"type":"array","description":"Points on the subject","items":{"type":"array","items":{"type":"number"},"minItems":2,"maxItems":2}},"exclude":{"type":"array","description":"Points on what doesn't belong","items":{"type":"array","items":{"type":"number"},"minItems":2,"maxItems":2}},"mask":{"type":"integer","minimum":0,"description":"Change this mask, from 0, instead of adding one"},"name":{"type":"string","description":"Shown to the user, like 'Portrait'"},"invert":{"type":"boolean"},"blur":{"type":"number","minimum":0,"maximum":100},"brightness":{"type":"object"},"hue":{"type":"object"},"edits":{"type":"object"},"colour":{"type":"object"},"photo":{"type":"string","description":"The photo you mean to edit; refused if another one is open"}},"required":["points"]}},
    \\{"name":"open_photo","title":"Open another photo",
    \\ "description":"Opens a photo of the folder by name (its path in the folder, or just the file name), by its position, or the next or previous one. Returns the new view.",
    \\ "inputSchema":{"type":"object","properties":{"name":{"type":"string"},"position":{"type":"integer","minimum":1},"direction":{"type":"string","enum":["next","previous"]}}}},
    \\{"name":"list_photos","title":"List the folder's photos",
    \\ "description":"The open folder's photos, in order, each with whether it has edits (and for edited ones, whether the user or Claude changed it last, and when).",
    \\ "inputSchema":{"type":"object","properties":{"edited_only":{"type":"boolean","description":"Only the photos with edits"}}}},
    \\{"name":"contact_sheet","title":"See many photos at once",
    \\ "description":"Up to 30 photos in one picture, drawn with their edits, each marked with its position in the folder; and a line per photo with its name, time, exposure, a sharpness number (of its sharpest part, whatever that is: not necessarily the face. Higher is sharper, only worth comparing between shots of the same scene; get_view zoom tells you for sure), who edited it and whether it is picked. The fewer you ask for, the bigger they are: 20 is good for looking through a folder, 6 to 12 for comparing faces or sharpness. Give photos, or walk the folder from start (a position; 1 by default) for count photos (20 by default), only those edited, unedited or picked if you ask. The text says what start to use next. Nothing changes, and the open photo stays open.",
    \\ "inputSchema":{"type":"object","properties":{"photos":{"description":"Positions or names; or \"picked\" for the folder's picks, or \"selected\" for what the user Ctrl-clicked","anyOf":[{"type":"array","items":{"type":["integer","string"]}},{"type":"string","enum":["picked","selected"]}]},"start":{"type":"integer","minimum":1},"count":{"type":"integer","minimum":1,"maximum":30},"only":{"type":"string","enum":["edited","unedited","picked"]}}}},
    \\{"name":"pick_photos","title":"Keep a choice of photos",
    \\ "description":"Makes these photos the folder's picks, in place of any before: how to keep what you chose. Picks stay after a restart and when the user clicks around; each has a mark in the sidebar, and its Picked filter shows only them. The user can change them with P. An empty list clears them. Nothing else changes: nothing is edited. Use \"picked\" for photos in contact_sheet or export.",
    \\ "inputSchema":{"type":"object","properties":{"photos":{"type":"array","items":{"type":["integer","string"]},"description":"Positions or names"}},"required":["photos"]}},
    \\{"name":"undo","title":"Undo the last change",
    \\ "description":"Undoes the last change to the open photo, one step, whoever made it. Returns the new view.",
    \\ "inputSchema":{"type":"object","properties":{"photo":{"type":"string","description":"The photo you mean; refused if another one is open"}}}},
    \\{"name":"export","title":"Export photos",
    \\ "description":"Exports the open photo, or those named, with their edits (camera, lens, exposure and date always kept). Options default to the app's export settings; the folder defaults to ~/Pictures/Doka. An export never overwrites a file: -2, -3… is added. aspect (with focus) crops this export only; the recipe stays as it is.",
    \\ "inputSchema":{"type":"object","properties":{"names":{"description":"Positions or names; or \"picked\" or \"selected\"","anyOf":[{"type":"array","items":{"type":["integer","string"]}},{"type":"string","enum":["picked","selected"]}]},"folder":{"type":"string","description":"Absolute path; created if missing"},"name":{"type":"string","description":"File name without extension; with several photos, put before each photo's own name"},"aspect":{"type":"string","description":"1:1, 4:5, 3:2, 16:9 or original: a crop for this export only"},"focus":{"type":"array","items":{"type":"number"},"description":"[x, y] 0..1 to centre that crop on"},"format":{"type":"string","enum":["jpeg","png"]},"quality":{"type":"number","minimum":50,"maximum":100},"long_edge":{"type":"number","description":"Longest side in pixels; 0 = original size"},"gps":{"type":"boolean","description":"Keep the GPS location (default: the app's setting)"}}}},
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
    \\ "description":"Turns the open photo's colour settings (adjustments, look and colour-only shaders; not masks, crop, grain, halation or vignette) into a new .cube LUT in the looks folder, usable anywhere.",
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
        error.ModelMissing => "this needs its download once: the user runs scripts/subject-model.py and restarts Doka",
        error.TooManyMasks => "a photo holds at most 8 masks",
        error.TooManyPoints => "a mask takes at most 16 points",
        error.NothingSelected => "the user hasn't selected any photos: they Ctrl-click at least two in the sidebar",
        error.NothingPicked => "this folder has no picks yet: see pick_photos",
        error.NoPhotos => "no photos match",
        error.NotASubject => "the mask at that position isn't a subject mask",
        error.NoSuchMask => "the recipe has no mask at that position; they count from 0",
        error.InvalidEnumTag => "a mask's shape is whole, linear or radial",
        error.LengthMismatch => "a mask's points are [x, y]",
        error.ExportBusy => "an export is already running",
        error.BadArguments => "missing or wrong arguments (see the tool's description)",
        error.FolderNotAbsolute => "the export folder must be an absolute path",
        else => @errorName(err),
    };
}

fn dispatch(app: *App, a: std.mem.Allocator, call: *Mcp.Call, args: std.json.Value) !void {
    const name = call.name;
    if (eql(name, "get_view")) {
        const show: ?usize = if (args == .object) if (args.object.get("show_mask")) |v| switch (v) {
            .integer => |i| if (i >= 0) @intCast(i) else return error.BadArguments,
            else => return error.BadArguments,
        } else null else null;
        if (show) |i| {
            const s = app.currentSession() orelse return error.NoPhoto;
            if (i >= (try s.recipe(a)).masks.len) return error.NoSuchMask;
        }
        if (args == .object and (args.object.get("zoom") != null or args.object.get("compare") != null)) return closeupView(app, a, call, args, show);
        return viewShowing(app, a, call, null, show);
    }
    if (eql(name, "list_photos")) return listPhotos(app, a, call, if (args == .object) if (args.object.get("edited_only")) |v| v == .bool and v.bool else false else false);
    if (eql(name, "set_edits")) {
        const s = (app.currentSession() orelse return error.NoPhoto);
        if (args != .object) return error.BadArguments;
        if (!try samePhoto(app, a, call, args)) return;
        var patch = try args.object.clone(a);
        _ = patch.orderedRemove("photo");
        if (patch.getPtr("crop")) |crop| if (crop.* == .object) {
            const r = try s.recipe(a);
            try fitCropPatch(app, a, app.current.?, r.crop, &crop.object);
        };
        var it = patch.iterator();
        while (it.next()) |e| if (!isRecipeField(e.key_ptr.*)) return error.UnknownField;
        try validate(Recipe, .{ .object = patch });
        _ = try s.change(a, .{ .patch = .{ .object = patch }, .by = .claude, .now = app.now() });
        app.changed();
        app.hooks.edited.?();
        return view(app, a, call, null);
    }
    if (eql(name, "mask_subject")) return maskSubject(app, a, call, args);
    if (eql(name, "edit_mask")) return editMask(app, a, call, args);
    if (eql(name, "open_photo")) {
        const f = &(app.folder orelse return error.NoFolder);
        const position: ?std.json.Value = if (args == .object) args.object.get("position") else null;
        const i = if (position) |v| try findValue(f, v) else if (string(args, "name")) |n| try find(f, n) else if (string(args, "direction")) |d| blk: {
            const cur = app.current orelse 0;
            if (eql(d, "next")) break :blk @min(cur + 1, f.photos.len - 1);
            if (eql(d, "previous")) break :blk cur -| 1;
            return error.BadArguments;
        } else return error.BadArguments;
        try app.open(i);
        app.hooks.photo_changed.?();
        return view(app, a, call, null);
    }
    if (eql(name, "contact_sheet")) return contactSheet(app, a, call, args);
    if (eql(name, "pick_photos")) {
        if (args != .object or args.object.get("photos") == null) return error.BadArguments;
        const indices = try photoList(app, a, args, "photos");
        try app.setPicks(indices);
        app.hooks.picks_changed.?();
        var out: Io.Writer.Allocating = .init(a);
        try out.writer.print("{d} photos are the folder's picks now; the user sees them marked in the sidebar, and on its Picked filter.", .{indices.len});
        for (indices) |i| try out.writer.print("\n{d}  {s}", .{ i + 1, app.folder.?.photos[i].rel });
        return call.finish(try Mcp.textResult(app.gpa, out.written(), false));
    }
    if (eql(name, "undo")) {
        const s = (app.currentSession() orelse return error.NoPhoto);
        if (!try samePhoto(app, a, call, args)) return;
        if (!try s.undo()) return call.finish(try Mcp.textResult(app.gpa, "Nothing to undo.", false));
        app.changed();
        app.hooks.edited.?();
        return view(app, a, call, "Undid the last change.");
    }
    if (eql(name, "export")) return app.hooks.export_for_claude.?(call, args);
    if (eql(name, "list_looks") or eql(name, "list_shaders")) return listLibrary(app, a, call, eql(name, "list_looks"));
    if (eql(name, "get_shader")) {
        const sh = try app.library.?.readShader(a, string(args, "name") orelse return error.BadArguments);
        const text = try std.fmt.allocPrint(a, "shader.json:\n{s}\n\nshader.glsl:\n{s}", .{ sh.json_text, sh.source });
        return call.finish(try Mcp.textResult(app.gpa, text, false));
    }
    if (eql(name, "save_shader")) return saveShader(app, a, call, args);
    if (eql(name, "delete_shader")) {
        const n = string(args, "name") orelse return error.BadArguments;
        try app.library.?.deleteShader(n);
        return call.finish(try Mcp.textResult(app.gpa, try std.fmt.allocPrint(a, "Deleted the shader {s}.", .{n}), false));
    }
    if (eql(name, "bake_look")) return bakeLook(app, a, call, args);
    return error.UnknownTool;
}

const SubjectCall = struct {
    app: *App,
    call: *Mcp.Call,
    // The mask's own fields as JSON, and its place in the list, or null for a new one.
    fields: []u8,
    index: ?usize,
};

fn appendPoints(a: std.mem.Allocator, list: *std.ArrayList([3]f32), v: ?std.json.Value, label: f32) !void {
    const value = v orelse return;
    if (value != .array) return error.BadArguments;
    for (value.array.items) |item| {
        if (item != .array or item.array.items.len != 2) return error.BadArguments;
        var point: [3]f32 = .{ 0, 0, label };
        for (item.array.items, 0..) |n, i| point[i] = switch (n) {
            .integer => |x| @floatFromInt(x),
            .float => |x| @floatCast(x),
            else => return error.BadArguments,
        };
        try list.append(a, point);
    }
}

fn closeupView(app: *App, a: std.mem.Allocator, call: *Mcp.Call, args: std.json.Value, show: ?usize) !void {
    const index = app.current orelse return error.NoPhoto;
    var request: App.Closeup = .{ .call = call, .text = undefined, .index = index, .show_mask = show };
    if (args.object.get("compare")) |v| request.compare = v == .bool and v.bool;
    if (args.object.get("zoom")) |zoom| {
        if (zoom != .object) return error.BadArguments;
        const at = zoom.object.get("at") orelse return error.BadArguments;
        if (at != .array or at.array.items.len != 2) return error.BadArguments;
        var point: [2]f32 = undefined;
        for (at.array.items, &point) |item, *o| o.* = std.math.clamp(try number(item), 0, 1);
        request.at = point;
        if (zoom.object.get("size")) |v| request.size = try number(v);
    }
    var out: Io.Writer.Allocating = .init(a);
    if (request.compare) try out.writer.writeAll("On the left the original, on the right with the edits.\n");
    if (request.at != null) try out.writer.print("In detail, around [{d:.2},{d:.2}] of the photo as cropped.\n", .{ request.at.?[0], request.at.?[1] });
    try writeView(app, a, &out.writer);
    request.text = try app.gpa.dupe(u8, out.written());
    errdefer app.gpa.free(request.text);
    return app.hooks.closeup.?(request);
}

fn number(v: std.json.Value) !f32 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => error.BadArguments,
    };
}

fn editMask(app: *App, a: std.mem.Allocator, call: *Mcp.Call, args: std.json.Value) !void {
    const s = app.currentSession() orelse return error.NoPhoto;
    if (args != .object) return error.BadArguments;
    if (!try samePhoto(app, a, call, args)) return;
    const r = try s.recipe(a);
    const which = args.object.get("mask") orelse return error.BadArguments;
    const index: usize = switch (which) {
        .integer => |i| if (i >= 0 and i < r.masks.len) @intCast(i) else return error.NoSuchMask,
        .string => |name| for (r.masks, 0..) |m, i| {
            if (std.ascii.eqlIgnoreCase(m.name, name)) break i;
        } else return error.NoSuchMask,
        else => return error.BadArguments,
    };
    var fields = try args.object.clone(a);
    for ([_][]const u8{ "mask", "photo", "show" }) |key| _ = fields.orderedRemove(key);
    const remove = fields.fetchOrderedRemove("remove");
    // A subject's picture and the points that found it go together: mask_subject changes them.
    for ([_][]const u8{ "file", "points", "shape" }) |key| if (fields.get(key) != null) return error.BadArguments;
    try validate(Recipe.Mask, .{ .object = fields });
    var list = try std.json.parseFromSliceLeaky(std.json.Value, a, try std.json.Stringify.valueAlloc(a, r.masks, .{}), .{});
    if (remove != null and remove.?.value == .bool and remove.?.value.bool) {
        _ = list.array.orderedRemove(index);
    } else {
        try Recipe.mergeInto(a, &list.array.items[index], .{ .object = fields });
    }
    var patch: std.json.ObjectMap = .empty;
    try patch.put(a, "masks", list);
    _ = try s.change(a, .{ .patch = .{ .object = patch }, .by = .claude, .now = app.now() });
    app.changed();
    app.hooks.edited.?();
    const shown = if (args.object.get("show")) |v| v == .bool and v.bool else false;
    return viewShowing(app, a, call, null, if (shown and remove == null) index else null);
}

fn maskSubject(app: *App, a: std.mem.Allocator, call: *Mcp.Call, args: std.json.Value) !void {
    const s = app.currentSession() orelse return error.NoPhoto;
    if (args != .object) return error.BadArguments;
    if (!try samePhoto(app, a, call, args)) return;
    const subject = app.subject orelse return error.ModelMissing;
    if (!subject.available()) return error.ModelMissing;
    const r = try s.recipe(a);
    const index: ?usize = if (args.object.get("mask")) |v| switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else return error.BadArguments,
        else => return error.BadArguments,
    } else null;
    if (index) |i| {
        if (i >= r.masks.len) return error.NoSuchMask;
        if (r.masks[i].shape != .subject) return error.NotASubject;
    } else if (r.masks.len >= Recipe.max_masks) return error.TooManyMasks;
    var fields = try args.object.clone(a);
    var points: std.ArrayList([3]f32) = .empty;
    // A mask being changed keeps the points that found it.
    if (index) |i| try points.appendSlice(a, r.masks[i].points);
    try appendPoints(a, &points, fields.get("points"), 1);
    try appendPoints(a, &points, fields.get("exclude"), 0);
    if (points.items.len == 0) return error.BadArguments;
    if (points.items.len > Recipe.max_mask_points) return error.TooManyPoints;
    for ([_][]const u8{ "points", "exclude", "mask", "photo" }) |key| _ = fields.orderedRemove(key);
    try validate(Recipe.Mask, .{ .object = fields });
    const f = &(app.folder orelse return error.NoFolder);
    const rel = app.currentRel() orelse return error.NoPhoto;
    const pending = try app.gpa.create(SubjectCall);
    errdefer app.gpa.destroy(pending);
    pending.* = .{ .app = app, .call = call, .index = index, .fields = try std.json.Stringify.valueAlloc(app.gpa, std.json.Value{ .object = fields }, .{}) };
    errdefer app.gpa.free(pending.fields);
    try subject.ask(.{ .path = try std.fmt.allocPrint(a, "{s}/{s}", .{ f.path, rel }), .root = f.path, .rel = rel, .points = points.items, .ctx = pending, .done = subjectFound });
}

fn subjectFound(ctx: *anyopaque, _: u64, rel: []const u8, points: []const [3]f32, file: ?[]const u8, failure: ?anyerror) void {
    const pending: *SubjectCall = @ptrCast(@alignCast(ctx));
    const app = pending.app;
    const call = pending.call;
    defer {
        app.gpa.free(pending.fields);
        app.gpa.destroy(pending);
    }
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    applySubject(app, a, pending, rel, points, file, failure) catch |err| {
        const msg = std.fmt.allocPrint(a, "mask_subject failed: {s}", .{explain(err)}) catch "mask_subject failed";
        call.finish(Mcp.textResult(app.gpa, msg, true) catch return);
    };
}

fn applySubject(app: *App, a: std.mem.Allocator, pending: *const SubjectCall, rel: []const u8, points: []const [3]f32, file: ?[]const u8, failure: ?anyerror) !void {
    const name = file orelse return failure.?;
    const open = app.currentRel() orelse return error.NoPhoto;
    if (!eql(open, rel)) {
        const text = try std.fmt.allocPrint(a, "Nothing changed: the open photo is {s} now, not {s}.", .{ open, rel });
        return pending.call.finish(try Mcp.textResult(app.gpa, text, true));
    }
    const s = app.currentSession() orelse return error.NoPhoto;
    const r = try s.recipe(a);
    var mask = try std.json.parseFromSliceLeaky(Recipe.Mask, a, pending.fields, .{ .allocate = .alloc_always });
    mask.shape = .subject;
    mask.file = name;
    mask.points = points;
    var list: std.ArrayList(Recipe.Mask) = .empty;
    try list.appendSlice(a, r.masks);
    const at = if (pending.index) |i| blk: {
        if (i >= list.items.len or list.items[i].shape != .subject) return error.NoSuchMask;
        // Fields it wasn't given stay as they were.
        const old = list.items[i];
        const given = try std.json.parseFromSliceLeaky(std.json.Value, a, pending.fields, .{});
        inline for (@typeInfo(Recipe.Mask).@"struct".fields) |field| {
            if (given.object.get(field.name) == null and !eql(field.name, "shape") and !eql(field.name, "file") and !eql(field.name, "points")) {
                @field(mask, field.name) = @field(old, field.name);
            }
        }
        list.items[i] = mask;
        break :blk i;
    } else blk: {
        if (mask.name.len == 0) mask.name = "Subject";
        if (list.items.len >= Recipe.max_masks) return error.TooManyMasks;
        try list.append(a, mask);
        break :blk list.items.len - 1;
    };
    const json = try std.json.Stringify.valueAlloc(a, .{ .masks = list.items }, .{});
    const patch = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    _ = try s.change(a, .{ .patch = patch, .by = .claude, .now = app.now() });
    app.changed();
    app.hooks.edited.?();
    return viewShowing(app, a, pending.call, "The mask is painted red in this screenshot.", at);
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

/// With `photo` given, the open photo must be that one: the user may have moved on meanwhile.
fn samePhoto(app: *App, a: std.mem.Allocator, call: *Mcp.Call, args: std.json.Value) !bool {
    const want = string(args, "photo") orelse return true;
    const f = &(app.folder orelse return error.NoFolder);
    const open = f.photos[app.current orelse return error.NoPhoto].rel;
    if (std.ascii.eqlIgnoreCase(open, want) or std.ascii.eqlIgnoreCase(std.fs.path.basename(open), want)) return true;
    const text = try std.fmt.allocPrint(a, "Nothing changed: the open photo is {s}, not {s}. The user may have switched photos; open_photo it first, or ask.", .{ open, want });
    call.finish(try Mcp.textResult(app.gpa, text, true));
    return false;
}

/// A crop patch with an `aspect` or a `focus` but no `rect` gets the rect worked out: the biggest
/// crop of that aspect around the focus (or the current crop's middle). `focus` isn't kept.
pub fn fitCropPatch(app: *App, a: std.mem.Allocator, index: usize, current: Recipe.Crop, crop: *std.json.ObjectMap) !void {
    const focus_value = crop.fetchOrderedRemove("focus");
    if (crop.get("rect") != null) return;
    const aspect_value = crop.get("aspect");
    if (focus_value == null and aspect_value == null) return;
    const aspect = if (aspect_value) |v| (if (v == .string) v.string else return error.BadArguments) else current.aspect;
    const rotate: u16 = if (crop.get("rotate")) |v| switch (v) {
        .integer => |i| @intCast(@mod(i, 360)),
        else => current.rotate,
    } else current.rotate;
    const f = &(app.folder orelse return error.NoFolder);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ f.path, f.photos[index].rel }, 0);
    const info = try core.decode.info(a, path);
    const turned = (rotate / 90) % 2 == 1;
    const size: [2]f64 = .{ @floatFromInt(if (turned) info.height else info.width), @floatFromInt(if (turned) info.width else info.height) };
    const c = current.rect;
    var focus: [2]f64 = .{ c[0] + c[2] / 2, c[1] + c[3] / 2 };
    if (focus_value) |fv| {
        if (fv.value != .array or fv.value.array.items.len != 2) return error.BadArguments;
        for (fv.value.array.items, 0..) |v, i| focus[i] = switch (v) {
            .integer => |n| @floatFromInt(n),
            .float => |x| x,
            else => return error.BadArguments,
        };
    }
    const rect = Recipe.fitCrop(c, Recipe.aspectRatio(aspect, size), focus, size);
    var list = std.json.Array.init(a);
    for (rect) |v| try list.append(.{ .float = v });
    try crop.put(a, "rect", .{ .array = list });
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

// A position in the folder, from 1, or a name.
fn findValue(f: *const App.Folder, v: std.json.Value) !usize {
    return switch (v) {
        .string => |n| find(f, n),
        .integer => |position| if (position >= 1 and position <= f.photos.len) @intCast(position - 1) else error.NoSuchPhoto,
        else => error.BadArguments,
    };
}

/// The photos a tool's argument means: positions and names, or "picked" or "selected". In the order given, once each.
pub fn photoList(app: *App, a: std.mem.Allocator, args: std.json.Value, key: []const u8) ![]const u32 {
    const f = &(app.folder orelse return error.NoFolder);
    const v = args.object.get(key) orelse return error.BadArguments;
    if (v == .string) {
        if (eql(v.string, "picked")) {
            const picks = try app.picks(a);
            if (picks.len == 0) return error.NothingPicked;
            return picks;
        }
        if (!eql(v.string, "selected")) return error.BadArguments;
        const picked = try app.hooks.selected.?(a);
        if (picked.len == 0) return error.NothingSelected;
        return picked;
    }
    if (v != .array) return error.BadArguments;
    var out: std.ArrayList(u32) = .empty;
    for (v.array.items) |item| {
        const i: u32 = @intCast(try findValue(f, item));
        if (std.mem.indexOfScalar(u32, out.items, i) == null) try out.append(a, i);
    }
    return out.items;
}

fn intArg(args: std.json.Value, key: []const u8, default: i64) !i64 {
    if (args != .object) return default;
    const v = args.object.get(key) orelse return default;
    return if (v == .integer) v.integer else error.BadArguments;
}

fn contactSheet(app: *App, a: std.mem.Allocator, call: *Mcp.Call, args: std.json.Value) !void {
    const f = &(app.folder orelse return error.NoFolder);
    const total = f.photos.len;
    if (args == .object and args.object.get("photos") != null) {
        const indices = try photoList(app, a, args, "photos");
        const more = if (indices.len > Sheet.max_photos) try std.fmt.allocPrint(a, " Only the first {d} fit; ask for the rest separately.", .{Sheet.max_photos}) else "";
        return app.hooks.sheet.?(call, indices, try std.fmt.allocPrint(a, "{d} of the {d} photos in {s}. The number on each is its position in the folder.{s}", .{ indices.len, total, f.name(), more }));
    }
    const count: usize = @intCast(std.math.clamp(try intArg(args, "count", 20), 1, Sheet.max_photos));
    const start = try intArg(args, "start", 1);
    if (start < 1 or start > total) return error.NoSuchPhoto;
    const only = string(args, "only");
    if (only) |o| if (!eql(o, "edited") and !eql(o, "unedited") and !eql(o, "picked")) return error.BadArguments;
    const wanted = struct {
        fn check(p: App.Photo, o: ?[]const u8) bool {
            const kind = o orelse return true;
            if (eql(kind, "picked")) return p.picked;
            return p.edited == eql(kind, "edited");
        }
    }.check;
    var indices: std.ArrayList(u32) = .empty;
    var i: usize = @intCast(start - 1);
    while (i < total and indices.items.len < count) : (i += 1) {
        if (!wanted(f.photos[i], only)) continue;
        try indices.append(a, @intCast(i));
    }
    // Is anything left past these?
    var next = i;
    while (next < total and !wanted(f.photos[next], only)) next += 1;
    if (indices.items.len == 0) return error.NoPhotos;
    const after = if (next < total) try std.fmt.allocPrint(a, "Next: start {d}.", .{next + 1}) else try a.dupe(u8, "That's the end of the folder.");
    return app.hooks.sheet.?(call, indices.items, try std.fmt.allocPrint(a, "{d} photos from {s}, which has {d}. The number on each is its position in the folder. {s}", .{ indices.items.len, f.name(), total, after }));
}

fn listPhotos(app: *App, a: std.mem.Allocator, call: *Mcp.Call, edited_only: bool) !void {
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
        if (edited_only and !p.edited) continue;
        try s.beginObject();
        try s.objectField("name");
        try s.write(p.rel);
        try s.objectField("edited");
        try s.write(p.edited);
        if (p.picked) {
            try s.objectField("picked");
            try s.write(true);
        }
        if (p.edited) if (core.store.load(app.io, a, f.dir, p.rel) catch null) |r| {
            try s.objectField("updatedBy");
            try s.write(r.updatedBy);
            try s.objectField("updatedAt");
            try s.write(r.updatedAt);
        };
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    call.finish(try Mcp.textResult(app.gpa, out.written(), false));
}

/// The view as text, then a screenshot of it (`finishScreenshot`).
pub fn view(app: *App, a: std.mem.Allocator, call: *Mcp.Call, lead: ?[]const u8) !void {
    return viewShowing(app, a, call, lead, null);
}

fn viewShowing(app: *App, a: std.mem.Allocator, call: *Mcp.Call, lead: ?[]const u8, show_mask: ?usize) !void {
    var out: Io.Writer.Allocating = .init(a);
    if (lead) |l| try out.writer.print("{s}\n", .{l});
    try writeView(app, a, &out.writer);
    const text = try app.gpa.dupe(u8, out.written());
    if (app.current == null) {
        defer app.gpa.free(text);
        return call.finish(try Mcp.textResult(app.gpa, text, false));
    }
    app.hooks.screenshot.?(.{ .call = call, .text = text, .show_mask = show_mask });
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
        if (f.photos[i].picked) {
            try s.objectField("picked");
            try s.write(true);
        }
        try s.objectField("camera");
        try s.write(try std.fmt.allocPrint(a, "{s} {s} · {s} · {s} s · f/{s} · ISO {s} · {s} mm · {d}×{d} · taken {s}", .{
            info.make, info.model, info.lens, info.exposure, info.aperture, info.iso, info.focal_length, info.width, info.height, info.taken,
        }));
        try s.objectField("recipe");
        try s.beginWriteRaw();
        try s.writer.writeAll(sess.json);
        s.endWriteRaw();
    } else {
        try s.objectField("photo");
        try s.write(null);
    }
    try s.endObject();
}

/// A view waiting for its screenshot.
pub const Screenshot = App.Shot;

/// The screenshot (base64 JPEG, or empty when it couldn't draw): the call's answer.
pub fn finishScreenshot(app: *App, shot: Screenshot, jpeg_base64: []const u8, tones: []const u8) void {
    defer app.gpa.free(shot.text);
    // The rendered photo's numbers after the view: clipping, mean, histogram.
    const text = if (tones.len > 0)
        std.fmt.allocPrint(app.gpa, "{s}\nTones of the rendered photo (% of pixels; histogram darkest first, 16 bins): {s}", .{ shot.text, tones }) catch return
    else
        app.gpa.dupe(u8, shot.text) catch return;
    defer app.gpa.free(text);
    const result = if (jpeg_base64.len > 0)
        std.fmt.allocPrint(app.gpa, "{{\"content\":[{{\"type\":\"text\",\"text\":{f}}},{{\"type\":\"image\",\"data\":\"{s}\",\"mimeType\":\"image/jpeg\"}}],\"isError\":false}}", .{ std.json.fmt(text, .{}), jpeg_base64 })
    else
        Mcp.textResult(app.gpa, text, false);
    shot.call.finish(result catch return log.err("out of memory", .{}));
}

fn listLibrary(app: *App, a: std.mem.Allocator, call: *Mcp.Call, looks: bool) !void {
    var out: Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_1 } };
    try s.beginObject();
    try s.objectField("folder");
    try s.write(if (looks) app.library.?.looks_dir else app.library.?.shaders_dir);
    if (looks) {
        try s.objectField("looks");
        try s.write(try app.library.?.lookNames(a));
    } else {
        try s.objectField("shaders");
        try s.beginArray();
        for (try app.library.?.shaderNames(a)) |n| {
            const sh = app.library.?.readShader(a, n) catch continue;
            try s.write(.{ .name = n, .description = sh.json.description, .params = sh.json.params, .needs = sh.json.needs });
        }
        try s.endArray();
    }
    try s.endObject();
    call.finish(try Mcp.textResult(app.gpa, out.written(), false));
}

// save_shader compiles it first; what doesn't compile isn't saved.
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
    var answer: std.json.ObjectMap = .empty;
    try answer.put(a, "error", .{ .string = app.hooks.compile_shader.?(a, def.params, source) });
    compiled(pending, app, a, .{ .object = answer });
}

fn compiled(ctx: *anyopaque, app: *App, a: std.mem.Allocator, answer: std.json.Value) void {
    const p: *PendingShader = @ptrCast(@alignCast(ctx));
    defer p.free(app.gpa);
    const finish = struct {
        fn text(call: *Mcp.Call, gpa: std.mem.Allocator, t: []const u8, is_error: bool) void {
            call.finish(Mcp.textResult(gpa, t, is_error) catch return);
        }
    }.text;
    if (answer == .null) return finish(p.call, app.gpa, "The app didn't compile the shader (no OpenGL context yet).", true);
    if (string(answer, "error")) |err| if (err.len > 0) {
        const t = std.fmt.allocPrint(a, "The shader didn't compile, so nothing was saved. Lines count from the top of your source.\n{s}", .{err}) catch err;
        return finish(p.call, app.gpa, t, true);
    };
    app.library.?.saveShader(a, p.name, p.source, p.json, app.now()) catch |err| {
        return finish(p.call, app.gpa, std.fmt.allocPrint(a, "Compiled, but saving failed: {t}", .{err}) catch "saving failed", true);
    };
    // The page hears now, not when the file watcher settles: the screenshot needs the new version.
    app.hooks.library_changed.?();
    if (!p.apply or app.current == null) return finish(p.call, app.gpa, "Saved.", false);

    // On the open photo: added at the end, or this one's strength changed.
    const s = app.currentSession() orelse return finish(p.call, app.gpa, "Saved.", false);
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
    _ = s.change(a, .{ .patch = patch, .by = .claude, .now = app.now() }) catch return;
    app.changed();
    app.hooks.edited.?();
    view(app, a, p.call, "Saved and applied.") catch |err| finish(p.call, app.gpa, @errorName(err), true);
}

const PendingBake = struct { call: *Mcp.Call, name: []u8 };

fn bakeLook(app: *App, a: std.mem.Allocator, call: *Mcp.Call, args: std.json.Value) !void {
    _ = (app.currentSession() orelse return error.NoPhoto);
    const raw = string(args, "name") orelse return error.BadArguments;
    const name = if (std.ascii.endsWithIgnoreCase(raw, ".cube")) raw else try std.fmt.allocPrint(a, "{s}.cube", .{raw});
    if (!Library.validName(name)) return error.BadName;
    const size: u32 = if (args.object.get("size")) |v| (if (v == .integer and v.integer == 65) 65 else 33) else 33;
    const pending = try app.gpa.create(PendingBake);
    pending.* = .{ .call = call, .name = try app.gpa.dupe(u8, name) };
    var answer: std.json.ObjectMap = .empty;
    const cube = app.hooks.bake.?(a, name[0 .. name.len - 5], size) catch "";
    try answer.put(a, "cube", .{ .string = cube });
    baked(pending, app, a, .{ .object = answer });
}

fn baked(ctx: *anyopaque, app: *App, a: std.mem.Allocator, answer: std.json.Value) void {
    const p: *PendingBake = @ptrCast(@alignCast(ctx));
    defer {
        app.gpa.free(p.name);
        app.gpa.destroy(p);
    }
    const cube = string(answer, "cube") orelse "";
    const t, const is_error = if (cube.len == 0)
        .{ "The app couldn't bake the look.", true }
    else if (app.library.?.saveLook(a, p.name, cube)) |_|
        .{ std.fmt.allocPrint(a, "Baked {s} into the looks folder; use it with set_edits look.name \"{s}\".", .{ p.name, p.name }) catch "Baked.", false }
    else |err|
        .{ std.fmt.allocPrint(a, "Baking worked, saving failed: {t}", .{err}) catch "saving failed", true };
    p.call.finish(Mcp.textResult(app.gpa, t, is_error) catch return);
}
