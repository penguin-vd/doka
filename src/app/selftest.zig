//! The pipeline's tests, on the GPU, with no window: small made-up images go through the real
//! shaders; what comes back is checked to the 8-bit level. `zig build probe-native`.
const std = @import("std");
const core = @import("photo-core");
const gl = @import("gl.zig");
const gtk = @import("gtk.zig");
const Pipeline = @import("pipeline.zig");
const Cube = @import("cube.zig");
const Exporter = @import("exporter.zig");
const cropping = @import("crop.zig");
const App = @import("app.zig");
const Canvas = @import("canvas.zig");
const MasksPanel = @import("masks_panel.zig");
const CurvePanel = @import("curve_panel.zig");
const Sheet = @import("sheet.zig");
const Slider = @import("slider.zig");
const Library = @import("library.zig");
const Looks = @import("looks.zig");
const Subject = @import("subject.zig");
const Pool = @import("jobs.zig");
const Mcp = @import("mcp.zig");
const tools = @import("tools.zig");
const Recipe = core.Recipe;

const gpa = std.heap.c_allocator;

/// GTK's own OpenGL setup without a window; true when it's OpenGL ES.
pub fn context() !bool {
    if (gtk.gtk_init_check() == 0) return error.NoDisplay;
    const display = gtk.gdk_display_get_default() orelse return error.NoDisplay;
    var err: ?*gtk.GError = null;
    const c = gtk.gdk_display_create_gl_context(display, &err) orelse {
        std.debug.print("no OpenGL: {s}\n", .{err.?.message});
        return error.NoContext;
    };
    if (gtk.gdk_gl_context_realize(c, &err) == 0) {
        std.debug.print("no OpenGL: {s}\n", .{err.?.message});
        return error.NoContext;
    }
    gtk.gdk_gl_context_make_current(c);
    return gtk.gdk_gl_context_get_use_es(c) != 0;
}

fn half(v: f32) u16 {
    return @bitCast(@as(f16, @floatCast(v)));
}

fn decode(c: f32) f32 {
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

fn encode(l: f32) f32 {
    return if (l <= 0.0031308) 12.92 * l else 1.055 * std.math.pow(f32, l, 1.0 / 2.4) - 0.055;
}

const Picture = struct { px: []u8, w: usize, h: usize };

const Ctx = struct {
    p: *Pipeline,
    arena: std.mem.Allocator,
    io: std.Io,

    fn recipe(c: Ctx, json: []const u8) Recipe {
        return Recipe.parse(c.arena, json) catch @panic("a test's recipe doesn't parse");
    }

    // Renders `linear` (w×h RGB) with the recipe, returns the 8-bit RGBA output.
    fn run(c: Ctx, w: usize, h: usize, linear: []const f32, json: []const u8, view: ?[4]f32) !Picture {
        const halves = try c.arena.alloc(u16, linear.len);
        for (linear, halves) |v, *o| o.* = half(v);
        try c.p.setSource(@intCast(w), @intCast(h), halves.ptr);
        return c.draw(c.recipe(json), view);
    }

    fn draw(c: Ctx, r: Recipe, view: ?[4]f32) !Picture {
        var size = c.p.outputSize(r, false);
        if (view) |v| {
            size[0] = @intFromFloat(@round(@as(f32, @floatFromInt(size[0])) * v[2]));
            size[1] = @intFromFloat(@round(@as(f32, @floatFromInt(size[1])) * v[3]));
        }
        var t = try Pipeline.target(size[0], size[1], gl.RGBA8, gl.UNSIGNED_BYTE);
        defer t.free();
        c.p.render(r, .{ .fbo = t.fbo, .width = size[0], .height = size[1], .view = view orelse .{ 0, 0, 1, 1 } });
        const w: usize = @intCast(size[0]);
        const h: usize = @intCast(size[1]);
        const px = try c.arena.alloc(u8, w * h * 4);
        gl.glBindFramebuffer(gl.FRAMEBUFFER, t.fbo);
        gl.glReadPixels(0, 0, size[0], size[1], gl.RGBA, gl.UNSIGNED_BYTE, px.ptr);
        return .{ .px = px, .w = w, .h = h };
    }
};

fn grey(a: std.mem.Allocator, values: []const f32) ![]f32 {
    const out = try a.alloc(f32, values.len * 3);
    for (values, 0..) |v, i| @memset(out[i * 3 ..][0..3], v);
    return out;
}

// Six distinct pixels, 3 wide, 2 high: the geometry tests follow them.
const colours = [6][3]f32{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 }, .{ 1, 1, 0 }, .{ 0, 1, 1 }, .{ 1, 0, 1 } };

fn six() [18]f32 {
    var out: [18]f32 = undefined;
    for (colours, 0..) |c, i| for (c, 0..) |v, k| {
        out[i * 3 + k] = v * 0.8;
    };
    return out;
}

// Which of the six a pixel shows, or null.
fn which(r: Picture, x: usize, y: usize) ?usize {
    const i = (y * r.w + x) * 4;
    outer: for (colours, 0..) |c, n| {
        for (c, 0..) |v, k| {
            const want: i32 = if (v != 0) 231 else 0;
            if (@abs(@as(i32, r.px[i + k]) - want) > 2) continue :outer;
        }
        return n;
    }
    return null;
}

fn ramp(a: std.mem.Allocator) ![]f32 {
    const out = try a.alloc(f32, 256 * 3);
    for (0..256) |i| {
        const f: f32 = 255;
        out[i * 3] = decode(@as(f32, @floatFromInt(i)) / f);
        out[i * 3 + 1] = decode(@as(f32, @floatFromInt((i * 7) % 256)) / f);
        out[i * 3 + 2] = decode(@as(f32, @floatFromInt(255 - i)) / f);
    }
    return out;
}

fn expect(ok: bool, comptime why: []const u8, args: anytype) !void {
    if (ok) return;
    std.debug.print("    " ++ why ++ "\n", args);
    return error.Failed;
}

const tests = .{
    .{ "all sliders at 0 change nothing", allZero },
    .{ "exposure +1 doubles the light below the shoulder", exposure },
    .{ "pushed highlights roll off to white without clipping early", rollOff },
    .{ "highlights -100 darkens white, shadows +100 lifts black", highlightsShadows },
    .{ "saturation -100 is grey", saturation },
    .{ "temperature warms: more red, less blue", temperature },
    .{ "whites move the bright end, blacks the dark end, and neither moves the middle", whitesBlacks },
    .{ "blacks lift pure black evenly, with no jump and no colour cast", blacksLift },
    .{ "vibrance lifts dull colours more than vivid ones, and skin less than other colours", vibrance },
    .{ "the tone curve shapes the tones, and goes into a baked look", toneCurve },
    .{ "an exported photo with a curve and the new sliders matches the preview", curveExport },
    .{ "rotate 90 turns clockwise", rotate },
    .{ "flip mirrors left to right", flip },
    .{ "crop keeps the rectangle asked for", cropRect },
    .{ "straighten + turns the photo clockwise", straighten },
    .{ "a zoomed view shows that part of the photo", zoomed },
    .{ "moving the view shows the same as developing afresh, and new edits still apply", moved },
    .{ "an identity look changes nothing", identityLook },
    .{ "a shader runs, and a broken one is refused with its error", shaderRuns },
    .{ "a baked look reproduces the colour settings", baked },
    .{ "the starter shaders compile and run", starters },
    .{ "a mask with no edits changes nothing, and its pass adds no error of its own", maskNothing },
    .{ "a whole-photo mask does what the same slider does, one implementation", maskSameMaths },
    .{ "a gradient changes one side and not the other, along its direction", maskGradient },
    .{ "an ellipse changes what's inside it, its radii along width and height", maskRadial },
    .{ "a brightness limit selects by brightness", maskBrightness },
    .{ "a colour limit selects by hue, and leaves greys", maskHue },
    .{ "invert selects everything else", maskInvert },
    .{ "limits read the original photo: other edits don't move them", maskLimitsOriginal },
    .{ "masks add up, and a switched-off one does nothing", maskStack },
    .{ "a mask stays on its pixels, where the handles say, through crop, turn, flip and straighten", maskStays },
    .{ "a mask's blur softens what's inside it, leaves the rest, and is the same size at any render size", maskBlur },
    .{ "a blurred background doesn't take colour from the person in front of it", maskBlurNoBleed },
    .{ "showing a mask paints it red, and only when asked", maskShown },
    .{ "an exported photo with masks matches the preview", maskExport },
    .{ "a saved subject mask selects its pixels, through crop, export and a fresh start; a missing one selects nothing", maskStored },
    .{ "clicking a person in a real photo finds them and not the whole photo", subjectFinds },
    .{ "clicking on the photo and Claude's mask_subject both make a saved mask, off the main loop", subjectEndToEnd },
    .{ "the layers panel adds, edits, moves, follows undo and removes masks", maskPanel },
    .{ "a shader that doesn't compile is tried once and says why, until it's fixed", brokenShader },
    .{ "the keys and a limit's drag do what they say on the layers", maskKeys },
    .{ "a press on the photo takes hold of the right thing, with the pointer to match", canvasPresses },
    .{ "a contact sheet shows the photos with their edits and numbers; picks are kept and nothing else changes", contactSheet },
    .{ "the curve panel adds, moves and takes away points, and leaves a straight curve out of the recipe", curvePanel },
    .{ "an export through the pipeline keeps camera, lens, date and exposure, and the original is untouched", exportKeepsMetadata },
};

fn allZero(c: Ctx) !void {
    const r = try c.run(256, 1, try ramp(c.arena), "{}", null);
    var worst: i32 = 0;
    for (0..256) |i| {
        const n: i32 = @intCast(i);
        worst = @max(worst, @as(i32, @intCast(@abs(@as(i32, r.px[i * 4]) - n))));
        worst = @max(worst, @as(i32, @intCast(@abs(@as(i32, r.px[i * 4 + 1]) - @mod(n * 7, 256)))));
        worst = @max(worst, @as(i32, @intCast(@abs(@as(i32, r.px[i * 4 + 2]) - (255 - n)))));
    }
    try expect(worst <= 1, "off by {d} levels", .{worst});
}

fn exposure(c: Ctx) !void {
    const r = try c.run(1, 1, try grey(c.arena, &.{0.05}), "{\"edits\":{\"exposure\":1}}", null);
    const want: i32 = @intFromFloat(@round(encode(0.1) * 255));
    try expect(@abs(@as(i32, r.px[0]) - want) <= 1, "got {d}, want {d}", .{ r.px[0], want });
}

fn rollOff(c: Ctx) !void {
    const r = try c.run(4, 1, try grey(c.arena, &.{ 0.25, 0.5, 0.75, 1 }), "{\"edits\":{\"exposure\":2}}", null);
    const v = [4]u8{ r.px[0], r.px[4], r.px[8], r.px[12] };
    try expect(v[0] < v[1] and v[1] < v[2] and v[2] < v[3] and v[3] >= 254, "got {any}", .{v});
}

fn highlightsShadows(c: Ctx) !void {
    const hi = (try c.run(1, 1, try grey(c.arena, &.{1}), "{\"edits\":{\"highlights\":-100}}", null)).px[0];
    const sh = (try c.run(1, 1, try grey(c.arena, &.{0.005}), "{\"edits\":{\"shadows\":100}}", null)).px[0];
    const base: i32 = @intFromFloat(@round(encode(0.005) * 255));
    try expect(hi < 230 and sh > base + 10, "white {d}, shadow {d} (from {d})", .{ hi, sh, base });
}

fn saturation(c: Ctx) !void {
    const r = try c.run(1, 1, &.{ 0.6, 0.1, 0.05 }, "{\"edits\":{\"saturation\":-100}}", null);
    const m = @max(r.px[0], r.px[1], r.px[2]) - @min(r.px[0], r.px[1], r.px[2]);
    try expect(m <= 2, "got {any}", .{r.px[0..3]});
}

fn temperature(c: Ctx) !void {
    const r = try c.run(1, 1, try grey(c.arena, &.{0.2}), "{\"edits\":{\"temperature\":50}}", null);
    try expect(r.px[0] > r.px[1] and r.px[1] > r.px[2], "got {any}", .{r.px[0..3]});
}

fn whitesBlacks(c: Ctx) !void {
    const tones = [_]f32{ 0.003, 0.18, 0.8, 1 };
    const base = try c.run(4, 1, try grey(c.arena, &tones), "{}", null);
    const dark = try c.run(4, 1, try grey(c.arena, &tones), "{\"edits\":{\"whites\":-100,\"blacks\":-100}}", null);
    const bright = try c.run(4, 1, try grey(c.arena, &tones), "{\"edits\":{\"whites\":100,\"blacks\":100}}", null);
    try expect(dark.px[12] < 225 and dark.px[8] < base.px[8] and bright.px[8] > base.px[8], "whites: white {d}, light {d} / {d} / {d}", .{ dark.px[12], dark.px[8], base.px[8], bright.px[8] });
    try expect(dark.px[0] == 0 and bright.px[0] > base.px[0] + 20, "blacks: {d} / {d} / {d}", .{ dark.px[0], base.px[0], bright.px[0] });
    const middle = [3]u8{ dark.px[4], base.px[4], bright.px[4] };
    try expect(@abs(@as(i32, middle[0]) - middle[1]) <= 1 and @abs(@as(i32, middle[2]) - middle[1]) <= 1, "the middle moved: {any}", .{middle});
}

fn blacksLift(c: Ctx) !void {
    const r = try c.run(3, 1, &.{ 0, 0, 0, 0.0005, 0.0005, 0.0005, 0.002, 0.0005, 0.0005 }, "{\"edits\":{\"blacks\":100}}", null);
    const black = r.px[0..3];
    try expect(black[0] > 20 and black[0] == black[1] and black[1] == black[2], "black {any}", .{black});
    try expect(@abs(@as(i32, r.px[4]) - black[0]) <= 3, "a jump next to black: {d} and {d}", .{ black[0], r.px[4] });
    const reddish = r.px[8..11];
    try expect(channelSpread(reddish) < 20, "a dark colour blown up: {any}", .{reddish});
}

fn channelSpread(px: []const u8) i32 {
    return @as(i32, @max(px[0], px[1], px[2])) - @min(px[0], px[1], px[2]);
}

fn vibrance(c: Ctx) !void {
    // A dull blue, a vivid blue, and a skin tone as dull as the dull blue.
    const pixels = [_]f32{ 0.20, 0.22, 0.28, 0.02, 0.05, 0.9, 0.28, 0.22, 0.20 };
    const base = try c.run(3, 1, &pixels, "{}", null);
    const more = try c.run(3, 1, &pixels, "{\"edits\":{\"vibrance\":100}}", null);
    const less = try c.run(3, 1, &pixels, "{\"edits\":{\"vibrance\":-100}}", null);
    const dull = channelSpread(more.px[0..3]) - channelSpread(base.px[0..3]);
    const vivid = channelSpread(more.px[4..7]) - channelSpread(base.px[4..7]);
    const skin = channelSpread(more.px[8..11]) - channelSpread(base.px[8..11]);
    try expect(dull > 8 and dull > 2 * vivid, "dull +{d}, vivid +{d}", .{ dull, vivid });
    try expect(skin > 0 and skin * 3 < dull * 2, "skin +{d}, dull +{d}", .{ skin, dull });
    try expect(channelSpread(less.px[0..3]) < channelSpread(base.px[0..3]), "-100 didn't mute", .{});
    const g = try c.run(1, 1, try grey(c.arena, &.{0.2}), "{\"edits\":{\"vibrance\":100}}", null);
    try expect(channelSpread(g.px[0..3]) <= 1, "grey took on colour: {any}", .{g.px[0..3]});
}

fn toneCurve(c: Ctx) !void {
    const tones = [_]f32{ decode(0.25), decode(0.5), decode(0.75) };
    const r = try c.run(3, 1, try grey(c.arena, &tones), "{\"curve\":[[0,0],[0.25,0.1],[0.75,0.9],[1,1]]}", null);
    const want = [3]i32{ 26, 128, 230 };
    for (want, 0..) |w, i| try expect(@abs(@as(i32, r.px[i * 4]) - w) <= 5, "tone {d}: {d}, want {d}", .{ i, r.px[i * 4], w });
    // Black and white ends can move: a faded black.
    const faded = try c.run(1, 1, try grey(c.arena, &.{0}), "{\"curve\":[[0,0.2],[1,1]]}", null);
    try expect(@abs(@as(i32, faded.px[0]) - 51) <= 2, "faded black {d}", .{faded.px[0]});
    // Before the look, and in a baked one.
    const lattice = try c.p.bakeLattice(gpa, c.recipe("{\"curve\":[[0,0.2],[1,1]]}"), 9);
    defer gpa.free(lattice);
    try expect(@abs(lattice[0] - 0.2) < 0.02, "baked black {d}", .{lattice[0]});
}

fn curveExport(c: Ctx) !void {
    const json = "{\"curve\":[[0.25,0.2],[0.75,0.8]],\"edits\":{\"whites\":30,\"blacks\":-20,\"vibrance\":20},\"detail\":{\"sharpen\":20}}";
    const preview = try c.run(256, 1, try ramp(c.arena), json, null);
    const px = try Exporter.renderPixels(c.p, gpa, c.recipe(json), 8, false);
    defer gpa.free(px.data);
    var worst: i32 = 0;
    for (0..256) |i| for (0..3) |k| {
        worst = @max(worst, @as(i32, @intCast(@abs(@as(i32, px.data[i * 3 + k]) - preview.px[i * 4 + k]))));
    };
    try expect(worst <= 1, "off by {d} levels", .{worst});
}

fn rotate(c: Ctx) !void {
    const pixels = six();
    const r = try c.run(3, 2, &pixels, "{\"crop\":{\"rotate\":90}}", null);
    try expect(r.w == 2 and r.h == 3, "size {d}x{d}", .{ r.w, r.h });
    // Clockwise: the bottom-left pixel comes to the top-left.
    const got = [4]?usize{ which(r, 0, 0), which(r, 1, 0), which(r, 0, 2), which(r, 1, 2) };
    try expect(got[0] == 3 and got[1] == 0 and got[2] == 5 and got[3] == 2, "got {any}", .{got});
}

fn flip(c: Ctx) !void {
    const pixels = six();
    const r = try c.run(3, 2, &pixels, "{\"crop\":{\"flip\":true}}", null);
    const got = [3]?usize{ which(r, 0, 0), which(r, 2, 0), which(r, 0, 1) };
    try expect(got[0] == 2 and got[1] == 0 and got[2] == 5, "got {any}", .{got});
}

fn cropRect(c: Ctx) !void {
    const pixels = six();
    const r = try c.run(3, 2, &pixels, "{\"crop\":{\"rect\":[0.6666667,0,0.3333333,1]}}", null);
    try expect(r.w == 1 and r.h == 2, "size {d}x{d}", .{ r.w, r.h });
    try expect(which(r, 0, 0) == 2 and which(r, 0, 1) == 5, "got {any} {any}", .{ which(r, 0, 0), which(r, 0, 1) });
}

fn straighten(c: Ctx) !void {
    // A white dot right of the middle goes down when the photo turns clockwise.
    const n = 21;
    const img = try c.arena.alloc(f32, n * n * 3);
    for (0..n) |y| for (0..n) |x| {
        @memset(img[(y * n + x) * 3 ..][0..3], if (x == 15 and y == 10) 1 else 0.02);
    };
    const r = try c.run(n, n, img, "{\"crop\":{\"straighten\":30}}", null);
    var best: u8 = 0;
    var bx: usize = 0;
    var by: usize = 0;
    for (0..r.h) |y| for (0..r.w) |x| {
        const v = r.px[(y * r.w + x) * 4];
        if (v > best) {
            best = v;
            bx = x;
            by = y;
        }
    };
    try expect(by > 12 and bx > 10, "the dot went to {d},{d}", .{ bx, by });
}

fn zoomed(c: Ctx) !void {
    const pixels = six();
    const r = try c.run(3, 2, &pixels, "{}", .{ 2.0 / 3.0, 0, 1.0 / 3.0, 1 });
    try expect(which(r, 0, 0) == 2 and which(r, 0, 1) == 5, "got {any} {any}", .{ which(r, 0, 0), which(r, 0, 1) });
}

fn moved(c: Ctx) !void {
    const size = 8;
    var image: [size * size * 3]f32 = undefined;
    for (0..size * size) |i| {
        const f: f32 = @floatFromInt(i);
        image[i * 3] = f / 64;
        image[i * 3 + 1] = 0.5 - f / 128;
        image[i * 3 + 2] = 0.2;
    }
    var halves: [image.len]u16 = undefined;
    for (image, &halves) |v, *o| o.* = half(v);
    const w: c_int = size;
    try c.p.setSource(w, w, &halves);
    const bright = c.recipe("{\"edits\":{\"exposure\":1}}");
    const left = [4]f32{ 0, 0, 0.5, 0.5 };
    const right = [4]f32{ 0.5, 0.5, 0.5, 0.5 };
    _ = try c.draw(bright, left);
    const reused = try c.draw(bright, right);
    try c.p.setSource(w, w, &halves);
    const fresh = try c.draw(bright, right);
    try expect(std.mem.eql(u8, reused.px, fresh.px), "the moved view differs", .{});
    const dark = try c.draw(c.recipe("{\"edits\":{\"exposure\":-1}}"), right);
    try expect(!std.mem.eql(u8, dark.px, reused.px), "a new edit was ignored", .{});
}

fn identityLook(c: Ctx) !void {
    const n: usize = 17;
    const data = try c.arena.alloc(f32, n * n * n * 3);
    const m: f32 = @floatFromInt(n - 1);
    for (0..n) |b| for (0..n) |g| for (0..n) |red| {
        const i = (b * n * n + g * n + red) * 3;
        data[i] = @as(f32, @floatFromInt(red)) / m;
        data[i + 1] = @as(f32, @floatFromInt(g)) / m;
        data[i + 2] = @as(f32, @floatFromInt(b)) / m;
    };
    const cube: Cube = .{ .size = @intCast(n), .data = data };
    c.p.setLook(&cube);
    defer c.p.setLook(null);
    const r = try c.run(256, 1, try ramp(c.arena), "{\"look\":{\"name\":\"identity.cube\",\"strength\":100}}", null);
    var worst: i32 = 0;
    for (0..256) |i| {
        const v: i32 = @intCast(i);
        worst = @max(worst, @as(i32, @intCast(@abs(@as(i32, r.px[i * 4]) - v))));
        worst = @max(worst, @as(i32, @intCast(@abs(@as(i32, r.px[i * 4 + 2]) - (255 - v)))));
    }
    try expect(worst <= 1, "off by {d} levels", .{worst});
}

fn shaderRuns(c: Ctx) !void {
    const params = [_]Pipeline.Param{.{ .name = "amount", .default = 1 }};
    try c.p.setShader("invert", try c.p.compileShader(&params, "vec3 effect(vec3 c) { return mix(c, 1.0 - c, u_amount); }"));
    defer c.p.setShader("invert", null) catch {};
    const r = try c.run(1, 1, try grey(c.arena, &.{0}), "{\"shaders\":[{\"name\":\"invert\",\"strength\":100}]}", null);
    try expect(r.px[0] >= 250, "inverted black gave {d}", .{r.px[0]});
    if (c.p.compileShader(&params, "vec3 effect(vec3 c) { return nope; }")) |_| {
        return expect(false, "a broken shader compiled", .{});
    } else |err| {
        try expect(err == error.ShaderCompile and std.mem.indexOf(u8, Pipeline.last_error, "nope") != null, "wrong error: {t} {s}", .{ err, Pipeline.last_error });
    }
}

fn baked(c: Ctx) !void {
    const black = [_]u16{ 0, 0, 0 };
    try c.p.setSource(1, 1, &black);
    const lattice = try c.p.bakeLattice(gpa, c.recipe("{\"edits\":{\"saturation\":-100}}"), 9);
    defer gpa.free(lattice);
    // Pure red's lattice point, made grey.
    const i = 8 * 3;
    try expect(@abs(lattice[i] - lattice[i + 1]) < 0.01, "red became {any}", .{lattice[i..][0..3]});
}

fn level(r: Picture, x: usize, y: usize) i32 {
    return r.px[(y * r.w + x) * 4];
}

fn near(a: i32, b: i32, by: u32) bool {
    return @abs(a - b) <= by;
}

fn maskNothing(c: Ctx) !void {
    const plain = try c.run(256, 1, try ramp(c.arena), "{}", null);
    const empty = try c.run(256, 1, try ramp(c.arena), "{\"masks\":[{\"shape\":\"linear\"},{\"shape\":\"radial\"}]}", null);
    try expect(std.mem.eql(u8, plain.px, empty.px), "an empty mask changed the photo", .{});
    // An edit too small to see runs the whole pass: to linear, the sliders, and back.
    const pass = try c.run(256, 1, try ramp(c.arena), "{\"masks\":[{\"edits\":{\"exposure\":0.00001}}]}", null);
    var worst: u32 = 0;
    for (plain.px, pass.px) |a, b| worst = @max(worst, @abs(@as(i32, a) - b));
    try expect(worst <= 1, "the pass moved a value by {d} levels", .{worst});
}

fn maskSameMaths(c: Ctx) !void {
    const image = try ramp(c.arena);
    const edits = "\"edits\":{\"exposure\":0.7,\"contrast\":20,\"shadows\":15,\"temperature\":-10,\"saturation\":30}";
    const global = try c.run(256, 1, image, "{" ++ edits ++ "}", null);
    const masked = try c.run(256, 1, image, "{\"masks\":[{" ++ edits ++ "}]}", null);
    var worst: u32 = 0;
    for (global.px, masked.px) |a, b| worst = @max(worst, @abs(@as(i32, a) - b));
    try expect(worst <= 2, "off by {d} levels", .{worst});
}

fn maskGradient(c: Ctx) !void {
    const n = 21;
    const img = try c.arena.alloc(f32, n * n * 3);
    @memset(img, 0.1);
    const base = try c.run(n, n, img, "{}", null);
    const down = try c.run(n, n, img, "{\"masks\":[{\"shape\":\"linear\",\"from\":[0.5,0],\"to\":[0.5,0.5],\"edits\":{\"exposure\":1}}]}", null);
    const b = level(base, 10, 20);
    try expect(level(down, 10, 0) > b + 30, "the top didn't change: {d} from {d}", .{ level(down, 10, 0), b });
    try expect(level(down, 10, 5) > b and level(down, 10, 5) < level(down, 10, 0), "no fade: {d}", .{level(down, 10, 5)});
    try expect(near(level(down, 10, 15), b, 1) and near(level(down, 10, 20), b, 1), "the bottom changed: {d}", .{level(down, 10, 20)});
    try expect(near(level(down, 0, 0), level(down, 20, 0), 1), "a top-down gradient varies across", .{});
    const across = try c.run(n, n, img, "{\"masks\":[{\"shape\":\"linear\",\"from\":[1,0.5],\"to\":[0.5,0.5],\"edits\":{\"exposure\":1}}]}", null);
    try expect(level(across, 20, 10) > b + 30 and near(level(across, 2, 10), b, 1), "right {d}, left {d}", .{ level(across, 20, 10), level(across, 2, 10) });
}

fn maskRadial(c: Ctx) !void {
    const n = 41;
    const img = try c.arena.alloc(f32, n * n * 3);
    @memset(img, 0.1);
    const base = level(try c.run(n, n, img, "{}", null), 0, 0);
    const r = try c.run(n, n, img, "{\"masks\":[{\"shape\":\"radial\",\"centre\":[0.5,0.5],\"radius\":[0.4,0.1],\"feather\":10,\"edits\":{\"exposure\":1}}]}", null);
    try expect(level(r, 20, 20) > base + 30, "the middle didn't change", .{});
    try expect(level(r, 30, 20) > base + 30, "inside the wide radius didn't change", .{});
    try expect(near(level(r, 20, 30), base, 1), "outside the short radius changed: {d}", .{level(r, 20, 30)});
    try expect(near(level(r, 0, 0), base, 1), "the corner changed", .{});
}

fn maskBrightness(c: Ctx) !void {
    const image = try grey(c.arena, &.{ 0.01, 0.7 });
    const base = try c.run(2, 1, image, "{}", null);
    const bright = try c.run(2, 1, image, "{\"masks\":[{\"brightness\":{\"min\":50},\"edits\":{\"exposure\":-1}}]}", null);
    try expect(near(level(bright, 0, 0), level(base, 0, 0), 1) and level(bright, 1, 0) < level(base, 1, 0) - 30, "got {d}, {d}", .{ level(bright, 0, 0), level(bright, 1, 0) });
    const dark = try c.run(2, 1, image, "{\"masks\":[{\"brightness\":{\"max\":50},\"edits\":{\"exposure\":1}}]}", null);
    try expect(level(dark, 0, 0) > level(base, 0, 0) + 10 and near(level(dark, 1, 0), level(base, 1, 0), 1), "got {d}, {d}", .{ level(dark, 0, 0), level(dark, 1, 0) });
}

// Blue, red, grey.
const three = [9]f32{ 0.05, 0.1, 0.5, 0.5, 0.05, 0.03, 0.2, 0.2, 0.2 };

fn maskHue(c: Ctx) !void {
    const base = try c.run(3, 1, &three, "{}", null);
    const r = try c.run(3, 1, &three, "{\"masks\":[{\"hue\":{\"centre\":250,\"width\":45},\"edits\":{\"exposure\":-1}}]}", null);
    const blue = r.px[2];
    try expect(blue < base.px[2] - 30, "blue stayed: {d} from {d}", .{ blue, base.px[2] });
    try expect(near(level(r, 1, 0), level(base, 1, 0), 1), "red changed", .{});
    try expect(near(level(r, 2, 0), level(base, 2, 0), 1), "grey changed", .{});
}

fn maskInvert(c: Ctx) !void {
    const base = try c.run(3, 1, &three, "{}", null);
    const r = try c.run(3, 1, &three, "{\"masks\":[{\"hue\":{\"centre\":250,\"width\":45},\"invert\":true,\"edits\":{\"exposure\":-1}}]}", null);
    try expect(near(r.px[2], base.px[2], 1), "blue changed: {d} from {d}", .{ r.px[2], base.px[2] });
    try expect(level(r, 1, 0) < level(base, 1, 0) - 30, "red stayed", .{});
    try expect(level(r, 2, 0) < level(base, 2, 0) - 20, "grey stayed", .{});
}

fn maskLimitsOriginal(c: Ctx) !void {
    // 0.1 is under the limit in the photo, over it after two stops of exposure.
    const image = try grey(c.arena, &.{0.1});
    const pushed = level(try c.run(1, 1, image, "{\"edits\":{\"exposure\":2}}", null), 0, 0);
    try expect(pushed > 150, "the test's premise: {d}", .{pushed});
    const masked = level(try c.run(1, 1, image, "{\"edits\":{\"exposure\":2},\"masks\":[{\"brightness\":{\"min\":60},\"edits\":{\"exposure\":-2}}]}", null), 0, 0);
    try expect(near(masked, pushed, 1), "the limit followed the edit: {d} from {d}", .{ masked, pushed });
}

fn maskStack(c: Ctx) !void {
    const image = try grey(c.arena, &.{0.03});
    const once = "{\"edits\":{\"exposure\":2}}";
    const want = level(try c.run(1, 1, image, once, null), 0, 0);
    const both = level(try c.run(1, 1, image, "{\"masks\":[{\"edits\":{\"exposure\":1}},{\"edits\":{\"exposure\":1}}]}", null), 0, 0);
    try expect(near(both, want, 2), "got {d}, want {d}", .{ both, want });
    const base = level(try c.run(1, 1, image, "{}", null), 0, 0);
    const off = level(try c.run(1, 1, image, "{\"masks\":[{\"enabled\":false,\"edits\":{\"exposure\":3}}]}", null), 0, 0);
    try expect(near(off, base, 1), "a switched-off mask changed it: {d}", .{off});
}

fn maskStays(c: Ctx) !void {
    const w = 120;
    const h = 80;
    const img = try c.arena.alloc(f32, w * h * 3);
    @memset(img, 0.05);
    const point = [2]f64{ 0.3, 0.6 };
    const cases = [_]struct { json: []const u8, geometry: cropping.Geometry }{
        .{ .json = "", .geometry = .{ .size = .{ w, h } } },
        .{ .json = "\"crop\":{\"rotate\":90},", .geometry = .{ .turns = 1, .size = .{ h, w } } },
        .{ .json = "\"crop\":{\"rotate\":270,\"flip\":true},", .geometry = .{ .turns = 3, .flip = true, .size = .{ h, w } } },
        .{ .json = "\"crop\":{\"rect\":[0.1,0.2,0.6,0.7]},", .geometry = .{ .rect = .{ 0.1, 0.2, 0.6, 0.7 }, .size = .{ w, h } } },
        .{ .json = "\"crop\":{\"straighten\":12},", .geometry = .{ .angle = std.math.degreesToRadians(@as(f64, 12)), .size = .{ w, h } } },
    };
    for (cases) |case| {
        const json = try std.fmt.allocPrint(c.arena, "{{{s}\"masks\":[{{\"shape\":\"radial\",\"centre\":[{d},{d}],\"radius\":[0.05,0.075],\"edits\":{{\"exposure\":3}}}}]}}", .{ case.json, point[0], point[1] });
        const r = try c.run(w, h, img, json, null);
        // The middle of the bright spot.
        var sx: f64 = 0;
        var sy: f64 = 0;
        var count: f64 = 0;
        for (0..r.h) |y| for (0..r.w) |x| {
            if (level(r, x, y) > 120) {
                sx += @floatFromInt(x);
                sy += @floatFromInt(y);
                count += 1;
            }
        };
        try expect(count > 0, "no spot with {s}", .{case.json});
        const at = case.geometry.fromPhoto(point);
        const wx = at[0] * @as(f64, @floatFromInt(r.w)) - 0.5;
        const wy = at[1] * @as(f64, @floatFromInt(r.h)) - 0.5;
        try expect(@abs(sx / count - wx) < 1.5 and @abs(sy / count - wy) < 1.5, "{s}: at {d:.1},{d:.1}, handles say {d:.1},{d:.1}", .{ case.json, sx / count, sy / count, wx, wy });
    }
}

// A sharp black and white boundary at x = n/2, in an image n wide.
fn twoHalves(a: std.mem.Allocator, n: usize) ![]f32 {
    const img = try a.alloc(f32, n * n * 3);
    for (0..n) |y| for (0..n) |x| {
        @memset(img[(y * n + x) * 3 ..][0..3], if (x < n / 2) 0.05 else 0.8);
    };
    return img;
}

// How many pixels the boundary's change is spread over, as a share of the width.
fn spread(r: Picture) f64 {
    var count: usize = 0;
    const y = r.h / 2;
    const lo = level(r, 0, y);
    const hi = level(r, r.w - 1, y);
    for (0..r.w) |x| {
        const v = level(r, x, y);
        if (v > lo + 8 and v < hi - 8) count += 1;
    }
    return @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(r.w));
}

fn maskBlur(c: Ctx) !void {
    const small = 256;
    const big = 1024;
    const json = "{\"masks\":[{\"blur\":100}]}";
    const sharp = try c.run(small, small, try twoHalves(c.arena, small), "{}", null);
    try expect(spread(sharp) < 0.02, "the test's picture isn't sharp: {d}", .{spread(sharp)});
    const soft = try c.run(small, small, try twoHalves(c.arena, small), json, null);
    const soft_big = try c.run(big, big, try twoHalves(c.arena, big), json, null);
    try expect(spread(soft) > 0.02, "not blurred: {d}", .{spread(soft)});
    try expect(@abs(spread(soft) - spread(soft_big)) < 0.012, "{d} at 256, {d} at 1024", .{ spread(soft), spread(soft_big) });
    // Only the top half is masked: the bottom stays sharp.
    const part = try c.run(small, small, try twoHalves(c.arena, small), "{\"masks\":[{\"shape\":\"linear\",\"from\":[0.5,0.25],\"to\":[0.5,0.3],\"blur\":100}]}", null);
    var below: usize = 0;
    const y = small - 10;
    for (0..small) |x| {
        const v = level(part, x, y);
        if (v > level(part, 0, y) + 8 and v < level(part, small - 1, y) - 8) below += 1;
    }
    try expect(below <= 5, "below the mask it's blurred too: {d}", .{below});
    var above: usize = 0;
    for (0..small) |x| {
        const v = level(part, x, 10);
        if (v > level(part, 0, 10) + 8 and v < level(part, small - 1, 10) - 8) above += 1;
    }
    try expect(above > 5, "the masked part isn't blurred: {d}", .{above});
}

fn maskBlurNoBleed(c: Ctx) !void {
    // Dark background left, a bright "person" right. A gradient with a hard edge selects the left.
    const n = 256;
    const img = try twoHalves(c.arena, n);
    const base = try c.run(n, n, img, "{}", null);
    const r = try c.run(n, n, img, "{\"masks\":[{\"shape\":\"linear\",\"from\":[0.495,0.5],\"to\":[0.5,0.5],\"blur\":100}]}", null);
    const beside = level(r, n / 2 - 6, n / 2);
    try expect(near(beside, level(base, n / 2 - 6, n / 2), 3), "the bright side bled in: {d}", .{beside});
    try expect(near(level(r, n / 2 + 6, n / 2), level(base, n / 2 + 6, n / 2), 1), "the person changed", .{});
}

fn maskShown(c: Ctx) !void {
    const image = try grey(c.arena, &.{ 0.2, 0.2 });
    const halves = try c.arena.alloc(u16, image.len);
    for (image, halves) |v, *o| o.* = half(v);
    try c.p.setSource(2, 1, halves.ptr);
    const r = c.recipe("{\"masks\":[{\"shape\":\"linear\",\"from\":[0,0.5],\"to\":[0.5,0.5]}]}");
    var t = try Pipeline.target(2, 1, gl.RGBA8, gl.UNSIGNED_BYTE);
    defer t.free();
    var px: [8]u8 = undefined;
    c.p.render(r, .{ .fbo = t.fbo, .width = 2, .height = 1, .show_mask = 0 });
    gl.glBindFramebuffer(gl.FRAMEBUFFER, t.fbo);
    gl.glReadPixels(0, 0, 2, 1, gl.RGBA, gl.UNSIGNED_BYTE, &px);
    try expect(px[0] > @as(u16, px[1]) + 40, "no red over the mask: {any}", .{px[0..3]});
    try expect(near(px[4], px[5], 1) and near(px[5], px[6], 1), "red outside the mask: {any}", .{px[4..7]});
    c.p.render(r, .{ .fbo = t.fbo, .width = 2, .height = 1 });
    gl.glBindFramebuffer(gl.FRAMEBUFFER, t.fbo);
    gl.glReadPixels(0, 0, 2, 1, gl.RGBA, gl.UNSIGNED_BYTE, &px);
    try expect(near(px[0], px[1], 1) and near(px[1], px[2], 1), "red without asking: {any}", .{px[0..3]});
}

fn maskExport(c: Ctx) !void {
    const n = 32;
    const img = try c.arena.alloc(f32, n * n * 3);
    for (0..n * n) |i| {
        const f: f32 = @as(f32, @floatFromInt(i)) / (n * n);
        img[i * 3] = f;
        img[i * 3 + 1] = 0.3;
        img[i * 3 + 2] = 1 - f;
    }
    const json = "{\"crop\":{\"rotate\":90},\"masks\":[{\"shape\":\"radial\",\"edits\":{\"exposure\":1}},{\"shape\":\"linear\",\"hue\":{\"centre\":250,\"width\":60},\"colour\":{\"blues\":{\"sat\":-50}}}]}";
    const preview = try c.run(n, n, img, json, null);
    const exported = try Exporter.renderPixels(c.p, gpa, c.recipe(json), 8, false);
    defer gpa.free(exported.data);
    var worst: u32 = 0;
    for (0..n * n) |i| for (0..3) |k| {
        worst = @max(worst, @abs(@as(i32, preview.px[i * 4 + k]) - exported.data[i * 3 + k]));
    };
    try expect(worst <= 2, "off by {d} levels", .{worst});
}

fn maskStored(c: Ctx) !void {
    const io = c.io;
    const folder = try std.fmt.allocPrintSentinel(c.arena, "/tmp/doka-probe-stored-{d}", .{std.c.getpid()}, 0);
    try std.Io.Dir.cwd().createDirPath(io, folder);
    defer std.Io.Dir.cwd().deleteTree(io, folder) catch {};
    const root = try std.Io.Dir.cwd().openDir(io, folder, .{});
    defer root.close(io);
    // The left half.
    const pixels = [_]u8{ 255, 0 };
    try core.store.saveMask(io, c.arena, root, "half.png", &pixels, 2, 1);
    Pipeline.masks_root = folder;
    defer Pipeline.masks_root = "";
    const image = try grey(c.arena, &.{ 0.1, 0.1, 0.1, 0.1 });
    const base = level(try c.run(4, 1, image, "{}", null), 0, 0);
    const json = "{\"masks\":[{\"shape\":\"subject\",\"file\":\"half.png\",\"edits\":{\"exposure\":1}}]}";
    const r = try c.run(4, 1, image, json, null);
    try expect(level(r, 0, 0) > base + 30 and near(level(r, 3, 0), base, 1), "got {d}, {d} from {d}", .{ level(r, 0, 0), level(r, 3, 0), base });
    const exported = try Exporter.renderPixels(c.p, gpa, c.recipe(json), 8, false);
    defer gpa.free(exported.data);
    try expect(near(exported.data[0], level(r, 0, 0), 2) and near(exported.data[9], level(r, 3, 0), 2), "the export differs", .{});
    // Another pipeline starts with nothing on its GPU, like a restart.
    var fresh = try Pipeline.init(gpa, c.p.es);
    const again = Ctx{ .p = &fresh, .arena = c.arena, .io = io };
    const r2 = try again.run(4, 1, image, json, null);
    try expect(std.mem.eql(u8, r.px, r2.px), "not the same after a restart", .{});
    const missing = try c.run(4, 1, image, "{\"masks\":[{\"shape\":\"subject\",\"file\":\"gone.png\",\"edits\":{\"exposure\":1}}]}", null);
    try expect(near(level(missing, 0, 0), base, 1), "a missing file changed the photo", .{});
    const unfound = try c.run(4, 1, image, "{\"masks\":[{\"shape\":\"subject\",\"edits\":{\"exposure\":1}}]}", null);
    try expect(near(level(unfound, 0, 0), base, 1), "a subject not yet found changed the photo", .{});
}

// Needs the download and testdata/photos; skipped without them.
fn subjectFinds(c: Ctx) !void {
    const home = std.c.getenv("HOME") orelse return;
    const models = try std.fmt.allocPrint(c.arena, "{s}/.config/doka/models", .{home});
    var s: Subject = .{ .gpa = gpa, .io = c.io, .pool = undefined, .models_dir = models };
    if (!s.available()) return std.debug.print("     (skipped: no download)\n", .{});
    const path: [:0]const u8 = "testdata/photos/P8120024.JPG";
    std.Io.Dir.cwd().access(c.io, path, .{}) catch return;
    const start = std.Io.Timestamp.now(c.io, .awake);
    const m = try s.segment(path, &.{.{ 0.5, 0.5, 1 }});
    defer gpa.free(m.pixels);
    const first = start.durationTo(std.Io.Timestamp.now(c.io, .awake)).toMilliseconds();
    const again_start = std.Io.Timestamp.now(c.io, .awake);
    const m2 = try s.segment(path, &.{ .{ 0.5, 0.5, 1 }, .{ 0.02, 0.02, 0 } });
    defer gpa.free(m2.pixels);
    const second = again_start.durationTo(std.Io.Timestamp.now(c.io, .awake)).toMilliseconds();
    var on: usize = 0;
    for (m.pixels) |v| on += @intFromBool(v > 127);
    const share = @as(f64, @floatFromInt(on)) / @as(f64, @floatFromInt(m.pixels.len));
    std.debug.print("     {d}x{d}, {d} ms first, {d} ms after, {d:.1}% selected\n", .{ m.width, m.height, first, second, share * 100 });
    const centre = m.pixels[@as(usize, m.height / 2) * m.width + m.width / 2];
    try expect(centre > 127, "the clicked point isn't in the mask: {d}", .{centre});
    try expect(share < 0.95, "it took the whole photo", .{});
}

var shot_text: ?[]u8 = null;
var shot_mask: ?usize = null;

fn stubScreenshot(shot: App.Shot) void {
    shot_text = shot.text;
    shot_mask = shot.show_mask;
    shot.call.finish(Mcp.textResult(shot.call.gpa, shot.text, false) catch unreachable);
}

fn stubEdited() void {}

// Needs the download and testdata/photos; skipped without them. The real panel, tool and worker
// threads, on a copy in a temp folder: only the window is missing.
fn subjectEndToEnd(c: Ctx) !void {
    const io = c.io;
    const home = std.c.getenv("HOME") orelse return;
    const photo = std.Io.Dir.cwd().readFileAlloc(io, "testdata/photos/P8120024.JPG", gpa, .limited(64 << 20)) catch return;
    defer gpa.free(photo);
    const a = c.arena;
    const folder = try std.fmt.allocPrintSentinel(a, "/tmp/doka-probe-subject-{d}", .{std.c.getpid()}, 0);
    try std.Io.Dir.cwd().createDirPath(io, folder);
    defer std.Io.Dir.cwd().deleteTree(io, folder) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/a.jpg", .{folder}), .data = photo });
    var pool: Pool = .{ .io = io };
    try pool.start();
    defer pool.stop();
    var s: Subject = .{ .gpa = gpa, .io = io, .pool = &pool, .models_dir = try std.fmt.allocPrint(a, "{s}/.config/doka/models", .{home}) };
    if (!s.available()) return std.debug.print("     (skipped: no download)\n", .{});
    var app: App = .{ .gpa = gpa, .io = io, .subject = &s };
    defer app.closeFolder();
    try app.openFolder(folder);
    app.hooks = .{ .edited = stubEdited, .screenshot = stubScreenshot };
    Pipeline.masks_root = folder;
    defer Pipeline.masks_root = "";
    var canvas: Canvas = .{ .gpa = gpa, .photos = undefined, .looks = undefined };
    _ = canvas.create();
    var p: MasksPanel = .{ .gpa = gpa, .app = &app, .canvas = &canvas, .subject = &s, .edited = panelEdited, .layer_changed = panelSync };
    panel_under_test = &p;
    app_under_test = &app;
    p.create();
    panelSync();

    // By hand: + Subject, then a click.
    gtk.g_signal_emit_by_name(p.add_buttons[0], "clicked");
    try expect(canvas.picking and canvas.show_mask == 0, "not picking: {any}", .{canvas.show_mask});
    canvas.on_pick.?.f(canvas.on_pick.?.ctx, .{ 0.5, 0.5 }, true);
    try expect(p.waiting, "not waiting for the answer", .{});
    var turns: usize = 0;
    while (p.waiting and turns < 2000) : (turns += 1) _ = gtk.g_main_context_iteration(null, 0) + sleepMs(5);
    try expect(!p.waiting, "no answer", .{});
    var r = try app.recipe(a);
    try expect(r.masks.len == 1 and r.masks[0].shape == .subject and r.masks[0].file.len > 0 and r.masks[0].points.len == 1, "got {any}", .{r.masks});
    const lin = try core.decode.linear(gpa, "testdata/photos/P8120024.JPG", 256);
    var decoded = lin;
    defer decoded.deinit(gpa);
    try c.p.setSource(@intCast(lin.width), @intCast(lin.height), lin.rgb.ptr);
    const with = try c.draw(c.recipe(try std.fmt.allocPrint(a, "{{\"masks\":[{{\"shape\":\"subject\",\"file\":\"{s}\",\"edits\":{{\"exposure\":2}}}}]}}", .{r.masks[0].file})), null);
    const without = try c.draw(.{}, null);
    try expect(!std.mem.eql(u8, with.px, without.px), "the saved mask does nothing", .{});
    // Another click adds to it, Shift-click marks "not this".
    canvas.on_pick.?.f(canvas.on_pick.?.ctx, .{ 0.02, 0.02 }, false);
    turns = 0;
    while (p.waiting and turns < 2000) : (turns += 1) _ = gtk.g_main_context_iteration(null, 0) + sleepMs(5);
    r = try app.recipe(a);
    try expect(r.masks[0].points.len == 2 and r.masks[0].points[1][2] == 0, "points {any}", .{r.masks[0].points});
    p.setActive(false);
    try expect(!canvas.picking, "still picking in another tab", .{});

    // Claude.
    const arguments = "{\"points\":[[0.5,0.5]],\"name\":\"Portrait\",\"edits\":{\"exposure\":0.5}}";
    const call = try gpa.create(Mcp.Call);
    call.* = .{ .gpa = gpa, .io = io, .name = "mask_subject", .arguments = arguments, .server = undefined };
    shot_text = null;
    tools.run(&app, call);
    turns = 0;
    while (shot_text == null and call.result == null and turns < 2000) : (turns += 1) _ = gtk.g_main_context_iteration(null, 0) + sleepMs(5);
    try expect(call.result != null, "the tool never answered", .{});
    defer gpa.free(call.result.?);
    defer gpa.destroy(call);
    r = try app.recipe(a);
    try expect(r.masks.len == 2 and std.mem.eql(u8, r.masks[1].name, "Portrait") and r.masks[1].edits.exposure == 0.5 and r.masks[1].file.len > 0, "tool: {s}", .{call.result.?});
    try expect(shot_mask == 1, "the view didn't show the new mask", .{});
    // A second call changes that mask, keeps its edits, and adds a point.
    const again = try gpa.create(Mcp.Call);
    defer gpa.destroy(again);
    again.* = .{ .gpa = gpa, .io = io, .name = "mask_subject", .arguments = "{\"mask\":1,\"points\":[[0.4,0.4]],\"exclude\":[[0.9,0.9]]}", .server = undefined };
    tools.run(&app, again);
    turns = 0;
    while (again.result == null and turns < 2000) : (turns += 1) _ = gtk.g_main_context_iteration(null, 0) + sleepMs(5);
    try expect(again.result != null, "the second call never answered", .{});
    defer gpa.free(again.result.?);
    r = try app.recipe(a);
    try expect(r.masks.len == 2 and r.masks[1].points.len == 3 and r.masks[1].edits.exposure == 0.5, "changing it: {s}", .{again.result.?});
    app.flush();
}

extern fn usleep(us: c_uint) c_int;

fn sleepMs(ms: u32) c_int {
    return usleep(ms * 1000);
}

var panel_under_test: *MasksPanel = undefined;
var app_under_test: *App = undefined;

fn panelEdited() void {}

fn panelSync() void {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    panel_under_test.sync(app_under_test.recipe(scratch.allocator()) catch return);
}

// The real panel and app without a window, on a copy of a photo in a temp folder: no display is
// needed to press its buttons.
fn maskPanel(c: Ctx) !void {
    const io = c.io;
    const photo = std.Io.Dir.cwd().readFileAlloc(io, "testdata/photos/P8120024.JPG", gpa, .limited(64 << 20)) catch return;
    defer gpa.free(photo);
    const folder = try std.fmt.allocPrintSentinel(c.arena, "/tmp/doka-probe-layers-{d}", .{std.c.getpid()}, 0);
    try std.Io.Dir.cwd().createDirPath(io, folder);
    defer std.Io.Dir.cwd().deleteTree(io, folder) catch {};
    const name = try std.fmt.allocPrint(c.arena, "{s}/a.jpg", .{folder});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = photo });
    var app: App = .{ .gpa = gpa, .io = io };
    defer app.closeFolder();
    try app.openFolder(folder);
    var canvas: Canvas = .{ .gpa = gpa, .photos = undefined, .looks = undefined };
    _ = canvas.create();
    var p: MasksPanel = .{ .gpa = gpa, .app = &app, .canvas = &canvas, .edited = panelEdited, .layer_changed = panelSync };
    panel_under_test = &p;
    app_under_test = &app;
    p.create();
    panelSync();
    try expect(p.selected == null and canvas.active_mask == null, "starts on a mask", .{});

    gtk.g_signal_emit_by_name(p.add_buttons[2], "clicked");
    gtk.g_signal_emit_by_name(p.add_buttons[1], "clicked");
    const a = c.arena;
    var r = try app.recipe(a);
    try expect(r.masks.len == 2 and r.masks[0].shape == .radial and r.masks[1].shape == .linear, "added {d}", .{r.masks.len});
    try expect(std.mem.eql(u8, r.masks[1].name, "Gradient"), "named {s}", .{r.masks[1].name});
    try expect(p.selected == 1 and canvas.active_mask == 1, "the new one isn't picked", .{});

    p.setEdit("exposure", -1, 5);
    p.setEdit("exposure", -1.5, 5);
    gtk.gtk_toggle_button_set_active(p.invert_button, 1);
    gtk.gtk_toggle_button_set_active(p.hue_buttons[5], 1);
    r = try app.recipe(a);
    const m = r.masks[1];
    try expect(m.edits.exposure == -1.5 and r.edits.exposure == 0, "the slider went to the wrong layer", .{});
    try expect(m.invert and m.hue.centre == 250 and m.hue.width == 45, "limits: {any}", .{m.hue});
    try expect(r.masks[0].edits.exposure == 0 and !r.masks[0].invert, "the other mask changed", .{});

    gtk.gtk_toggle_button_set_active(p.show_button, 1);
    try expect(canvas.show_mask == 1, "not shown", .{});
    p.setActive(false);
    try expect(canvas.show_mask == null and canvas.active_mask == null, "still on in another tab", .{});
    p.setActive(true);

    canvas.on_mask.?.f(canvas.on_mask.?.ctx, 1, .{ .from = .{ 0.2, 0.1 }, .to = .{ 0.8, 0.9 }, .centre = .{ 0, 0 }, .radius = .{ 1, 1 } }, 9);
    r = try app.recipe(a);
    try expect(r.masks[1].from[0] == 0.2 and r.masks[1].to[1] == 0.9 and r.masks[1].edits.exposure == -1.5, "moving it lost something", .{});

    // Undo the move, the hue, the invert, the slider's drag, then the mask itself.
    for (0..5) |_| _ = try app.undo();
    panelSync();
    r = try app.recipe(a);
    try expect(r.masks.len == 1 and p.selected == null and canvas.active_mask == null, "after undo: {d} masks, picked {any}", .{ r.masks.len, p.selected });

    gtk.g_signal_emit_by_name(p.whole_button, "clicked");
    p.selected = 0;
    panelSync();
    p.resetEdits();
    gtk.g_signal_emit_by_name(gtk.gtk_widget_get_last_child(gtk.gtk_widget_get_parent(p.invert_button)).?, "clicked");
    r = try app.recipe(a);
    try expect(r.masks.len == 0 and p.selected == null, "not removed", .{});
    app.flush();
}

fn brokenShader(c: Ctx) !void {
    const io = c.io;
    const dir = try std.fmt.allocPrint(c.arena, "/tmp/doka-probe-shaders-{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var library = try Library.init(gpa, io, dir);
    var looks: Looks = .{ .gpa = gpa, .library = &library };
    defer looks.clear();
    defer c.p.dropShaders();
    try library.saveShader(c.arena, "probe-broken", "this isn't GLSL", "{}", 0);
    const r = c.recipe("{\"shaders\":[{\"name\":\"probe-broken\"}]}");
    looks.prepare(c.p, r);
    try expect(looks.shaderError("probe-broken") != null and looks.broken_changed, "no error kept", .{});
    try expect(looks.shaderError("probe-broken").?.len > 0 and !c.p.hasShader("probe-broken"), "its message is empty, or it's installed", .{});
    // Not tried again: the panel isn't told again, and the message stays the first one's.
    looks.broken_changed = false;
    looks.prepare(c.p, r);
    try expect(!looks.broken_changed, "tried again", .{});
    // A photo with it still draws, without it.
    _ = try c.run(1, 1, try grey(c.arena, &.{0.2}), "{\"shaders\":[{\"name\":\"probe-broken\"}]}", null);

    const good = Library.starters[0];
    try library.saveShader(c.arena, "probe-broken", good.glsl, good.json, 1);
    looks.clear();
    looks.prepare(c.p, r);
    try expect(looks.shaderError("probe-broken") == null and c.p.hasShader("probe-broken"), "fixing it didn't help: {s}", .{Pipeline.last_error});
}

fn maskKeys(c: Ctx) !void {
    const io = c.io;
    const photo = std.Io.Dir.cwd().readFileAlloc(io, "testdata/photos/P8120024.JPG", gpa, .limited(64 << 20)) catch return;
    defer gpa.free(photo);
    const folder = try std.fmt.allocPrintSentinel(c.arena, "/tmp/doka-probe-keys-{d}", .{std.c.getpid()}, 0);
    try std.Io.Dir.cwd().createDirPath(io, folder);
    defer std.Io.Dir.cwd().deleteTree(io, folder) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(c.arena, "{s}/a.jpg", .{folder}), .data = photo });
    var app: App = .{ .gpa = gpa, .io = io };
    defer app.closeFolder();
    try app.openFolder(folder);
    var canvas: Canvas = .{ .gpa = gpa, .photos = undefined, .looks = undefined };
    _ = canvas.create();
    var p: MasksPanel = .{ .gpa = gpa, .app = &app, .canvas = &canvas, .edited = panelEdited, .layer_changed = panelSync };
    panel_under_test = &p;
    app_under_test = &app;
    p.create();
    panelSync();
    const a = c.arena;
    try expect(!p.deleteKey() and !p.escapeKey(), "the keys did something with no mask picked", .{});

    gtk.g_signal_emit_by_name(p.add_buttons[2], "clicked");
    // The red shows only while a limit is being dragged; a second press there puts it back.
    Slider.onBegin(undefined, 50, 0, p.feather);
    try expect(canvas.show_mask == 0, "no red while dragging", .{});
    Slider.onEnd(undefined, 0, 0, p.feather);
    try expect(canvas.show_mask == null, "red after the drag", .{});
    try expect((try app.recipe(a)).masks[0].feather == 100, "feather {d}", .{(try app.recipe(a)).masks[0].feather});
    Slider.onBegin(undefined, 50, 0, p.feather);
    Slider.onEnd(undefined, 0, 0, p.feather);
    try expect((try app.recipe(a)).masks[0].feather == 50, "double-click left {d}", .{(try app.recipe(a)).masks[0].feather});

    // The wheel on a limit: the red shows, and goes when the wheel stops.
    const wheel = gtk.gtk_event_controller_scroll_new(gtk.scroll_vertical);
    try expect(Slider.onScroll(wheel, 0, -1, p.feather) == 1, "the wheel wasn't taken", .{});
    try expect((try app.recipe(a)).masks[0].feather == 51 and canvas.show_mask == 0, "after a notch: {d}, red {any}", .{ (try app.recipe(a)).masks[0].feather, canvas.show_mask });
    const started = gtk.g_get_monotonic_time();
    while (canvas.show_mask != null and gtk.g_get_monotonic_time() - started < 2_000_000) _ = gtk.g_main_context_iteration(null, 0);
    try expect(canvas.show_mask == null, "the red stayed after the wheel stopped", .{});

    // The eye changes the row without making the list again.
    const row = p.rows[0].name;
    gtk.g_signal_emit_by_name(p.rows[0].eye, "clicked");
    try expect(!(try app.recipe(a)).masks[0].enabled and p.rows[0].name == row, "the eye rebuilt the list", .{});

    p.setActive(false);
    try expect(!p.deleteKey(), "Delete worked from another tab", .{});
    p.setActive(true);
    try expect(p.deleteKey() and (try app.recipe(a)).masks.len == 0, "Delete left it", .{});
    _ = try app.undo();
    panelSync();
    try expect((try app.recipe(a)).masks.len == 1, "undo didn't bring it back", .{});

    p.selected = 0;
    panelSync();
    try expect(p.escapeKey() and p.selected == null and canvas.active_mask == null, "Escape stayed on the mask", .{});

    // A subject that never found anything leaves no layer behind.
    gtk.g_signal_emit_by_name(p.add_buttons[0], "clicked");
    try expect(canvas.picking and canvas.show_mask == 1, "not picking", .{});
    try expect(p.escapeKey(), "Escape ignored", .{});
    try expect(!canvas.picking and canvas.show_mask == null and p.selected == null, "still picking", .{});
    try expect((try app.recipe(a)).masks.len == 1, "an empty subject stayed", .{});
    app.flush();
}

var picks: u32 = 0;
var last_pick: [2]f32 = undefined;
var last_keep = false;
var placed: ?Recipe.Mask.Place = null;
var cropped: ?cropping.Rect = null;

fn onTestPick(_: *anyopaque, at: [2]f32, keep: bool) void {
    picks += 1;
    last_pick = at;
    last_keep = keep;
}

fn onTestPlace(_: *anyopaque, _: usize, place: Recipe.Mask.Place, _: u64) void {
    placed = place;
}

fn onTestCrop(rect: cropping.Rect, _: u64) void {
    cropped = rect;
}

fn pointerIs(canvas: *const Canvas, name: ?[]const u8) bool {
    const now = canvas.cursor_name orelse return name == null;
    return name != null and std.mem.eql(u8, std.mem.span(now), name.?);
}

var sheet_under_test: *Sheet = undefined;
var gl_is_es = true;
var picked_photos: []const u32 = &.{};

fn stubSheet(call: *Mcp.Call, indices: []const u32, lead: []const u8) anyerror!void {
    return sheet_under_test.start(call, indices, lead);
}

fn stubSelected(_: std.mem.Allocator) anyerror![]const u32 {
    return picked_photos;
}

fn stubPicksChanged() void {}

fn alwaysCurrent() bool {
    return true;
}

fn contactSheet(c: Ctx) !void {
    const io = c.io;
    const a = c.arena;
    const folder = try std.fmt.allocPrintSentinel(a, "/tmp/doka-probe-sheet-{d}", .{std.c.getpid()}, 0);
    try std.Io.Dir.cwd().createDirPath(io, folder);
    defer std.Io.Dir.cwd().deleteTree(io, folder) catch {};
    for ([_][]const u8{ "P4270251.JPG", "P5070015.jpg", "P7310341.JPG", "P8120024.JPG", "PB290321.JPG" }, 0..) |name, i| {
        const source = std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "testdata/photos/{s}", .{name}), gpa, .limited(64 << 20)) catch return;
        defer gpa.free(source);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/p{d}.jpg", .{ folder, i }), .data = source });
    }
    var pool: Pool = .{ .io = io };
    try pool.start();
    defer pool.stop();
    var app: App = .{ .gpa = gpa, .io = io };
    defer app.closeFolder();
    try app.openFolder(folder);
    const config = try std.fmt.allocPrint(a, "{s}-config", .{folder});
    defer std.Io.Dir.cwd().deleteTree(io, config) catch {};
    var library = try Library.init(gpa, io, config);
    gl_is_es = c.p.es;
    var sheet: Sheet = .{ .gpa = gpa, .app = &app, .pool = &pool, .looks = .{ .gpa = gpa, .library = &library }, .gl_current = alwaysCurrent, .es = struct {
        fn f() bool {
            return gl_is_es;
        }
    }.f };
    sheet_under_test = &sheet;
    app.hooks = .{ .edited = stubEdited, .screenshot = stubScreenshot, .sheet = stubSheet, .selected = stubSelected, .picks_changed = stubPicksChanged };

    const Answer = struct { text: []const u8, jpeg: []const u8 };
    const ask = struct {
        fn f(ctx: Ctx, app_: *App, name: []const u8, arguments: []const u8) !Answer {
            const call = try gpa.create(Mcp.Call);
            defer gpa.destroy(call);
            call.* = .{ .gpa = gpa, .io = ctx.io, .name = name, .arguments = arguments, .server = undefined };
            tools.run(app_, call);
            var turns: usize = 0;
            while (call.result == null and turns < 4000) : (turns += 1) _ = gtk.g_main_context_iteration(null, 0) + sleepMs(2);
            const result = call.result orelse return error.Failed;
            defer gpa.free(result);
            const parsed = try std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, result, .{ .allocate = .alloc_always });
            const content = parsed.object.get("content").?.array.items;
            var jpeg: []const u8 = "";
            if (content.len > 1) {
                const data = content[1].object.get("data").?.string;
                const bytes = try ctx.arena.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(data));
                try std.base64.standard.Decoder.decode(bytes, data);
                jpeg = bytes;
            }
            return .{ .text = content[0].object.get("text").?.string, .jpeg = jpeg };
        }
    }.f;
    // What the sheet's picture has at a cell's middle, brightness 0..255.
    const middle = struct {
        fn f(ctx: Ctx, dir: []const u8, jpeg: []const u8, n: u32, slot: u32) !u8 {
            const path = try std.fmt.allocPrintSentinel(ctx.arena, "{s}/.sheet.jpeg", .{dir}, 0);
            try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = jpeg });
            defer std.Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
            var lin = try core.decode.linear(gpa, path, 0);
            defer lin.deinit(gpa);
            const l = Sheet.layoutFor(n, .landscape);
            try expect(lin.width == l.width and lin.height == l.height, "the sheet is {d}x{d}, not {d}x{d}", .{ lin.width, lin.height, l.width, l.height });
            const x = (slot % l.cols) * (l.cell_w + 4) + l.cell_w / 2;
            const y = (slot / l.cols) * (l.cell_h + 4) + l.cell_h / 2;
            const v: f16 = @bitCast(lin.rgb[(y * lin.width + x) * 3 + 1]);
            return @intFromFloat(@round(encode(@floatCast(v)) * 255));
        }
    }.f;

    // A folder's first three, each numbered, and where to go on from.
    var r = try ask(c, &app, "contact_sheet", "{\"count\":3}");
    try expect(r.jpeg.len > 1000, "no picture: {s}", .{r.text});
    try expect(std.mem.indexOf(u8, r.text, "Next: start 4") != null and std.mem.indexOf(u8, r.text, "\n2  p1.jpg") != null, "the text: {s}", .{r.text});
    const plain = try middle(c, folder, r.jpeg, 3, 1);
    const first_plain = try middle(c, folder, r.jpeg, 3, 0);

    // An edit shows, on that photo only, and the sheet says who made it.
    try expect(app.current == 0, "the first photo isn't open", .{});
    try app.edit("{\"edits\":{\"exposure\":1.5}}", 0);
    r = try ask(c, &app, "contact_sheet", "{\"count\":3}");
    const brighter = try middle(c, folder, r.jpeg, 3, 0);
    const second = try middle(c, folder, r.jpeg, 3, 1);
    try expect(brighter > first_plain + 20 and @abs(@as(i32, second) - plain) <= 3, "the edit doesn't show: {d}, was {d}; beside it {d}, was {d}", .{ brighter, first_plain, second, plain });
    try expect(std.mem.indexOf(u8, r.text, "edited by user") != null and std.mem.indexOf(u8, r.text, "sharp ") != null, "the text: {s}", .{r.text});
    r = try ask(c, &app, "contact_sheet", "{\"only\":\"edited\"}");
    try expect(std.mem.indexOf(u8, r.text, "1 photos") != null and std.mem.indexOf(u8, r.text, "end of the folder") != null, "only edited: {s}", .{r.text});

    // Picks: kept, said on the sheet, usable by name, and no photo was edited for it.
    r = try ask(c, &app, "contact_sheet", "{\"photos\":\"picked\"}");
    try expect(std.mem.indexOf(u8, r.text, "no picks yet") != null, "no picks: {s}", .{r.text});
    r = try ask(c, &app, "pick_photos", "{\"photos\":[2,\"p3.jpg\"]}");
    try expect(std.mem.indexOf(u8, r.text, "2 photos") != null and std.mem.indexOf(u8, r.text, "\n4  p3.jpg") != null, "pick: {s}", .{r.text});
    r = try ask(c, &app, "contact_sheet", "{\"photos\":\"picked\"}");
    try expect(r.jpeg.len > 1000 and std.mem.indexOf(u8, r.text, "p1.jpg") != null and std.mem.indexOf(u8, r.text, "  picked") != null and std.mem.indexOf(u8, r.text, "p2.jpg") == null, "the picks: {s}", .{r.text});
    r = try ask(c, &app, "contact_sheet", "{\"only\":\"picked\",\"count\":1}");
    try expect(std.mem.indexOf(u8, r.text, "Next: start 4") != null, "walking the picks: {s}", .{r.text});
    try expect(!app.folder.?.photos[1].edited and !app.folder.?.photos[3].edited, "picking edited a photo", .{});
    r = try ask(c, &app, "pick_photos", "{\"photos\":[99]}");
    try expect((try app.picks(a)).len == 2, "a bad pick changed the picks: {s}", .{r.text});
    app.flush();
    try app.openFolder(folder);
    try expect((try app.picks(a)).len == 2, "the picks didn't survive reopening", .{});

    // Portrait cells for mostly portrait photos: bigger than they'd be in landscape ones.
    for (0..3) |i| {
        try app.open(i);
        try app.edit("{\"crop\":{\"rotate\":90}}", 0);
    }
    r = try ask(c, &app, "contact_sheet", "{\"count\":3}");
    const portrait = Sheet.layoutFor(3, .portrait);
    const dims = try sheetSize(c, folder, r.jpeg);
    try expect(dims[0] == portrait.width and dims[1] == portrait.height, "portrait sheet {any}, not {d}x{d}", .{ dims, portrait.width, portrait.height });

    // The user's selection still works too; and the numbers open a photo.
    picked_photos = &.{};
    r = try ask(c, &app, "contact_sheet", "{\"photos\":\"selected\"}");
    try expect(std.mem.indexOf(u8, r.text, "hasn't selected") != null, "nothing selected: {s}", .{r.text});
    picked_photos = &.{ 0, 3 };
    r = try ask(c, &app, "contact_sheet", "{\"photos\":\"selected\"}");
    try expect(std.mem.indexOf(u8, r.text, "\n4  p3.jpg") != null and r.jpeg.len > 1000, "the selection: {s}", .{r.text});
    picked_photos = &.{};
    app.flush();
}

fn sheetSize(c: Ctx, dir: []const u8, jpeg: []const u8) ![2]u32 {
    const path = try std.fmt.allocPrintSentinel(c.arena, "{s}/.sheet.jpeg", .{dir}, 0);
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = path, .data = jpeg });
    defer std.Io.Dir.cwd().deleteFile(c.io, path) catch {};
    var lin = try core.decode.linear(gpa, path, 0);
    defer lin.deinit(gpa);
    return .{ @intCast(lin.width), @intCast(lin.height) };
}

fn tempPhoto(c: Ctx, app: *App, tag: []const u8) !?[:0]const u8 {
    const photo = std.Io.Dir.cwd().readFileAlloc(c.io, "testdata/photos/P8120024.JPG", gpa, .limited(64 << 20)) catch return null;
    defer gpa.free(photo);
    const folder = try std.fmt.allocPrintSentinel(c.arena, "/tmp/doka-probe-{s}-{d}", .{ tag, std.c.getpid() }, 0);
    try std.Io.Dir.cwd().createDirPath(c.io, folder);
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = try std.fmt.allocPrint(c.arena, "{s}/a.jpg", .{folder}), .data = photo });
    try app.openFolder(folder);
    return folder;
}

fn curvePanel(c: Ctx) !void {
    var app: App = .{ .gpa = gpa, .io = c.io };
    defer app.closeFolder();
    const folder = try tempPhoto(c, &app, "curve") orelse return;
    defer std.Io.Dir.cwd().deleteTree(c.io, folder) catch {};
    var p: CurvePanel = .{ .gpa = gpa, .app = &app, .edited = stubEdited };
    p.create();
    const a = c.arena;
    p.sync(try app.recipe(a), true);
    try expect(p.count == 2 and p.points[1][0] == 1 and p.points[1][1] == 1, "starts as {any}", .{p.points[0..p.count]});

    // A press in the middle makes a point; near one takes it; the ends only go up and down.
    const middle = p.take(0.5, 0.6, 0.03).?;
    try expect(middle == 1 and p.count == 3, "made {d}, {d} points", .{ middle, p.count });
    try expect(p.take(0.51, 0.61, 0.03).? == 1 and p.count == 3, "a second point right beside the first", .{});
    p.move(1, 5, 0.7);
    try expect(p.points[1][0] < 1 and p.points[1][1] == 0.7, "moved past the end: {any}", .{p.points[1]});
    p.move(0, 0.4, 0.1);
    try expect(p.points[0][0] == 0 and p.points[0][1] == 0.1, "the end left its place: {any}", .{p.points[0]});

    // Full, and a point can't be squeezed against its neighbour.
    const gaps = [_]f32{ 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5 };
    var made: usize = 0;
    for (gaps) |x| {
        if (p.take(x, 0.2, 0.001) != null) made += 1;
    }
    try expect(p.count == Recipe.max_curve_points, "{d} points", .{p.count});
    try expect(p.take(0.03, 0.9, 0.001) == null and p.count == Recipe.max_curve_points, "past full", .{});
    while (p.count > 2) p.drop(1);
    p.drop(0);
    p.drop(1);
    try expect(p.count == 2 and p.points[0][1] == 0 and p.points[1][1] == 1, "not back to straight: {any}", .{p.points[0..p.count]});

    // Through the real handlers on a real widget, 200x200: in tones, x/200 and 1 - y/200.
    gtk.gtk_widget_measure(p.widget, gtk.horizontal, -1, null, null, null, null);
    gtk.gtk_widget_measure(p.widget, gtk.vertical, 200, null, null, null, null);
    gtk.gtk_widget_allocate(p.widget, 200, 240, -1, null);
    try expect(gtk.gtk_widget_get_height(p.area) >= 180, "the curve is {d} high", .{gtk.gtk_widget_get_height(p.area)});
    const h: f64 = @floatFromInt(gtk.gtk_widget_get_height(p.area));
    const steps = (try app.currentSession().?.recipe(a)).curve.len;
    try expect(steps == 0, "curve before the press: {d}", .{steps});
    CurvePanel.onBegin(undefined, 50, h * 0.75, &p);
    CurvePanel.onUpdate(undefined, 0, h * 0.15, &p);
    CurvePanel.onUpdate(undefined, 0, h * 0.25, &p);
    CurvePanel.onEnd(undefined, 0, 0, &p);
    var r = try app.recipe(a);
    try expect(r.curve.len == 3 and @abs(r.curve[1][0] - 0.25) < 0.01 and r.curve[1][1] == 0 and !r.isDefault(), "dragged: {any}", .{r.curve});
    _ = try app.undo();
    try expect((try app.recipe(a)).curve.len == 0, "a press and its drag aren't one undo step", .{});
    p.sync(try app.recipe(a), true);
    try expect(p.count == 2, "undo didn't reach the panel", .{});
    // A double-click on a point takes it away, and a straight curve leaves no trace.
    CurvePanel.onBegin(undefined, 100, h * 0.3, &p);
    CurvePanel.onEnd(undefined, 0, 0, &p);
    try expect((try app.recipe(a)).curve.len == 3, "a click didn't add a point", .{});
    CurvePanel.onPressed(undefined, 1, 100, h * 0.3, &p);
    try expect(p.count == 3, "one press took it away", .{});
    CurvePanel.onPressed(undefined, 2, 100, h * 0.3, &p);
    try expect((try app.recipe(a)).isDefault(), "a straight curve left a trace: {any}", .{(try app.recipe(a)).curve});
    // Reset: a whole curve straight in one go, one undo step, and nothing to reset after it.
    try app.edit("{\"curve\":[[0,0.1],[0.3,0.2],[0.6,0.9],[0.8,0.7],[1,0.9]]}", 0);
    p.sync(try app.recipe(a), true);
    try expect(p.count == 5 and gtk.gtk_widget_get_sensitive(p.reset_button) != 0, "nothing to reset: {d}", .{p.count});
    gtk.g_signal_emit_by_name(p.reset_button, "clicked");
    try expect((try app.recipe(a)).isDefault() and p.count == 2 and gtk.gtk_widget_get_sensitive(p.reset_button) == 0, "Reset left {any}", .{(try app.recipe(a)).curve});
    _ = try app.undo();
    try expect((try app.recipe(a)).curve.len == 5, "Reset wasn't one undo step", .{});
    p.sync(try app.recipe(a), true);
    CurvePanel.onNamePressed(undefined, 1, 0, 0, &p);
    try expect((try app.recipe(a)).curve.len == 5, "one press on the name reset it", .{});
    CurvePanel.onNamePressed(undefined, 2, 0, 0, &p);
    try expect((try app.recipe(a)).isDefault(), "a double-click on the name didn't reset it", .{});
    // A mask's layer has no curve; another photo's points don't stay.
    p.sync(.{ .curve = &.{.{ 0.5, 0.7 }} }, false);
    try expect(p.count == 3, "a curve with only a middle point: {d}", .{p.count});
}

// A real canvas at a known size: 4:3 in 1040x840 puts the photo at 20,45, 1000x750.
fn canvasPresses(c: Ctx) !void {
    _ = try c.run(4, 3, try grey(c.arena, &(.{0.2} ** 12)), "{}", null);
    var canvas: Canvas = .{ .gpa = gpa, .photos = undefined, .looks = undefined };
    const widget = canvas.create();
    canvas.pipeline = c.p.*;
    canvas.rel = try gpa.dupe(u8, "a.jpg");
    defer gpa.free(canvas.rel.?);
    canvas.full_width = 4000;
    canvas.on_pick = .{ .ctx = &canvas, .f = onTestPick };
    canvas.on_mask = .{ .ctx = &canvas, .f = onTestPlace };
    canvas.on_crop = onTestCrop;
    gtk.gtk_widget_measure(widget, gtk.horizontal, -1, null, null, null, null);
    gtk.gtk_widget_measure(widget, gtk.vertical, 1040, null, null, null, null);
    gtk.gtk_widget_allocate(widget, 1040, 840, -1, null);
    try expect(gtk.gtk_widget_get_width(canvas.area) == 1040, "not allocated: {d}", .{gtk.gtk_widget_get_width(canvas.area)});
    const self: *anyopaque = &canvas;
    const press = gtk.gtk_gesture_drag_new();
    const begin = struct {
        fn f(g: *anyopaque, x: f64, y: f64, ctx: *anyopaque) void {
            Canvas.onDragBegin(g, x, y, ctx);
        }
    }.f;

    // Double-click: to 100% and back, and only with two presses.
    Canvas.onMotion(undefined, 520, 420, self);
    try expect(canvas.spotAt(520, 420) == .pan and pointerIs(&canvas, null), "at fit", .{});
    Canvas.onPressed(undefined, 1, 520, 420, self);
    try expect(canvas.goal == 1, "one press zoomed", .{});
    Canvas.onPressed(undefined, 2, 520, 420, self);
    try expect(canvas.goal > 1.5, "double-click didn't zoom: {d}", .{canvas.goal});
    Canvas.onPressed(undefined, 2, 520, 420, self);
    try expect(canvas.goal == 1, "double-click didn't come back: {d}", .{canvas.goal});

    // Zoomed: a hand to grab with, and the photo moves.
    canvas.zoom = 3;
    canvas.goal = 3;
    Canvas.onMotion(undefined, 520, 420, self);
    try expect(pointerIs(&canvas, "grab"), "no grab", .{});
    const was = canvas.centre[0];
    begin(press, 520, 420, self);
    try expect(pointerIs(&canvas, "grabbing"), "no grabbing", .{});
    Canvas.onDragUpdate(undefined, -100, 0, self);
    try expect(canvas.centre[0] > was, "didn't move", .{});
    Canvas.onDragEnd(undefined, 0, 0, self);
    try expect(pointerIs(&canvas, "grab"), "still grabbing", .{});
    canvas.zoom = 1;
    canvas.goal = 1;
    canvas.centre = .{ 0.5, 0.5 };

    // Clicking a subject: a click picks, a drag at fit still picks where it was pressed, a drag
    // zoomed in moves the photo; off the photo nothing.
    canvas.setPicking(true);
    Canvas.onMotion(undefined, 520, 420, self);
    try expect(canvas.spotAt(520, 420) == .pick and canvas.spotAt(5, 5) == .none and pointerIs(&canvas, "crosshair"), "picking's spots", .{});
    begin(press, 520, 420, self);
    try expect(picks == 0, "picked before the release", .{});
    Canvas.onDragEnd(undefined, 0, 0, self);
    try expect(picks == 1 and @abs(last_pick[0] - 0.5) < 0.01 and @abs(last_pick[1] - 0.5) < 0.01 and last_keep, "picked {any}", .{last_pick});
    begin(press, 270, 420, self);
    Canvas.onDragUpdate(undefined, 40, 0, self);
    Canvas.onDragEnd(undefined, 0, 0, self);
    try expect(picks == 2 and @abs(last_pick[0] - 0.25) < 0.01, "a sloppy click picked {any}", .{last_pick});
    canvas.zoom = 3;
    canvas.goal = 3;
    const before_pan = canvas.centre[0];
    begin(press, 520, 420, self);
    Canvas.onDragUpdate(undefined, -60, 0, self);
    Canvas.onDragEnd(undefined, 0, 0, self);
    try expect(picks == 2 and canvas.centre[0] > before_pan, "a drag picked, or didn't move", .{});
    begin(press, 520, 420, self);
    Canvas.onDragUpdate(undefined, 2, 0, self);
    Canvas.onDragEnd(undefined, 0, 0, self);
    try expect(picks == 3, "a click while zoomed didn't pick", .{});
    canvas.zoom = 1;
    canvas.goal = 1;
    canvas.centre = .{ 0.5, 0.5 };
    begin(press, 5, 5, self);
    Canvas.onDragEnd(undefined, 0, 0, self);
    try expect(picks == 3, "picked off the photo", .{});
    Canvas.onPressed(undefined, 2, 520, 420, self);
    try expect(canvas.goal == 1, "double-clicks zoom while picking", .{});
    canvas.setPicking(false);

    // A mask's handles: grabbed, dragged, and the nearest when they're close; no zoom on them.
    canvas.recipe = c.recipe("{\"masks\":[{\"shape\":\"linear\",\"from\":[0.5,0],\"to\":[0.5,0.5]}]}");
    canvas.active_mask = 0;
    Canvas.onMotion(undefined, 520, 420, self);
    try expect(canvas.spotAt(520, 420) == .mask and pointerIs(&canvas, "grab"), "the handle isn't there", .{});
    Canvas.onPressed(undefined, 2, 520, 420, self);
    try expect(canvas.goal == 1, "a double-click on a handle zoomed", .{});
    begin(press, 520, 420, self);
    try expect(pointerIs(&canvas, "grabbing"), "handle: no grabbing", .{});
    Canvas.onDragUpdate(undefined, 0, 75, self);
    Canvas.onDragEnd(undefined, 0, 0, self);
    try expect(placed != null and @abs(placed.?.to[1] - 0.6) < 0.01 and placed.?.from[1] == 0, "moved to {any}", .{placed});
    canvas.recipe = c.recipe("{\"masks\":[{\"shape\":\"linear\",\"from\":[0.5,0.5],\"to\":[0.5,0.52]}]}");
    begin(press, 520, 422, self);
    Canvas.onDragEnd(undefined, 0, 0, self);
    try expect(canvas.mask_handle == .from, "grabbed {t}", .{canvas.mask_handle});
    begin(press, 520, 434, self);
    Canvas.onDragEnd(undefined, 0, 0, self);
    try expect(canvas.mask_handle == .to, "grabbed {t}", .{canvas.mask_handle});
    canvas.active_mask = null;

    // The before/after line.
    canvas.compare = true;
    Canvas.onMotion(undefined, 520, 420, self);
    try expect(canvas.spotAt(520, 420) == .split and pointerIs(&canvas, "ew-resize"), "the line isn't there", .{});
    begin(press, 520, 420, self);
    Canvas.onDragUpdate(undefined, 100, 0, self);
    Canvas.onDragEnd(undefined, 0, 0, self);
    try expect(@abs(canvas.split - 0.6) < 0.001, "split {d}", .{canvas.split});
    canvas.compare = false;

    // The crop: its corners, its frame, and no zoom.
    canvas.recipe = c.recipe("{\"crop\":{\"rect\":[0.25,0.25,0.5,0.5]}}");
    canvas.setCropMode(true);
    Canvas.onMotion(undefined, 520, 420, self);
    try expect(canvas.spotAt(520, 420) == .crop_move and pointerIs(&canvas, "move"), "the frame isn't there", .{});
    try expect(canvas.spotAt(270, 232.5) == .nw and canvas.spotAt(770, 607.5) == .se and canvas.spotAt(30, 60) == .none, "the corners aren't there", .{});
    Canvas.onMotion(undefined, 270, 232.5, self);
    try expect(pointerIs(&canvas, "nwse-resize"), "corner's pointer", .{});
    Canvas.onPressed(undefined, 2, 520, 420, self);
    try expect(canvas.goal == 1, "a double-click zoomed the crop", .{});
    begin(press, 520, 420, self);
    Canvas.onDragUpdate(undefined, 100, 0, self);
    Canvas.onDragEnd(undefined, 0, 0, self);
    try expect(cropped != null and @abs(cropped.?[0] - 0.35) < 0.001, "crop {any}", .{cropped});
}

// Needs testdata/photos; skipped without it, as photo-core's tests are.
fn exportKeepsMetadata(c: Ctx) !void {
    const io = c.io;
    const source: [:0]const u8 = "testdata/photos/P8120024.JPG";
    const before = std.Io.Dir.cwd().readFileAlloc(io, source, gpa, .limited(64 << 20)) catch return;
    defer gpa.free(before);
    var lin = try core.decode.linear(gpa, source, 2048);
    defer lin.deinit(gpa);
    try c.p.setSource(@intCast(lin.width), @intCast(lin.height), lin.rgb.ptr);
    const r = c.recipe("{\"edits\":{\"exposure\":0.3}}");
    for ([_]core.encode.Format{ .jpeg, .png }) |format| {
        const px = try Exporter.renderPixels(c.p, gpa, r, format.bits(), false);
        defer gpa.free(px.data);
        const out = try std.fmt.allocPrintSentinel(c.arena, "/tmp/doka-probe-{d}{s}", .{ std.c.getpid(), format.extension() }, 0);
        defer std.Io.Dir.cwd().deleteFile(io, out) catch {};
        const pixels: core.encode.Pixels = .{ .width = px.w, .height = px.h, .data = if (format == .jpeg) .{ .u8 = px.data } else .{ .u16 = @alignCast(std.mem.bytesAsSlice(u16, @as([]align(2) u8, @alignCast(px.data)))) } };
        try core.encode.save(io, gpa, source, pixels, .{ .format = format }, out);
        const a = try core.decode.info(c.arena, source);
        const b = try core.decode.info(c.arena, out);
        for ([_][2][]const u8{ .{ a.make, b.make }, .{ a.model, b.model }, .{ a.lens, b.lens }, .{ a.exposure, b.exposure }, .{ a.taken, b.taken } }) |pair| {
            try expect(std.mem.eql(u8, pair[0], pair[1]), "{s}: {s} became {s}", .{ @tagName(format), pair[0], pair[1] });
        }
        try expect(a.make.len > 0, "the test photo has no camera in it", .{});
    }
    const after = try std.Io.Dir.cwd().readFileAlloc(io, source, gpa, .limited(64 << 20));
    defer gpa.free(after);
    try expect(std.mem.eql(u8, before, after), "the original changed", .{});
}

const ShaderJson = struct { params: []const struct { name: []const u8, default: f32 = 0 } = &.{} };

fn starters(c: Ctx) !void {
    const list = .{
        .{ "split-tone", @embedFile("starter/split-tone.glsl"), @embedFile("starter/split-tone.json") },
        .{ "bloom", @embedFile("starter/bloom.glsl"), @embedFile("starter/bloom.json") },
        .{ "light-leak", @embedFile("starter/light-leak.glsl"), @embedFile("starter/light-leak.json") },
        .{ "clarity", @embedFile("starter/clarity.glsl"), @embedFile("starter/clarity.json") },
        .{ "dehaze", @embedFile("starter/dehaze.glsl"), @embedFile("starter/dehaze.json") },
    };
    inline for (list) |st| {
        const json = try std.json.parseFromSliceLeaky(ShaderJson, c.arena, st[2], .{ .ignore_unknown_fields = true });
        const params = try c.arena.alloc(Pipeline.Param, json.params.len);
        for (json.params, params) |from, *to| to.* = .{ .name = from.name, .default = from.default };
        const compiled = c.p.compileShader(params, st[1]) catch |err| {
            std.debug.print("    {s}: {t}: {s}\n", .{ st[0], err, Pipeline.last_error });
            return err;
        };
        try c.p.setShader(st[0], compiled);
        defer c.p.setShader(st[0], null) catch {};
        const img = try c.arena.alloc(f32, 64 * 3);
        for (0..64) |i| {
            const f: f32 = @as(f32, @floatFromInt(i)) / 63;
            img[i * 3] = decode(f);
            img[i * 3 + 1] = decode(0.5);
            img[i * 3 + 2] = decode(1 - f);
        }
        const r = try c.run(8, 8, img, "{\"shaders\":[{\"name\":\"" ++ st[0] ++ "\",\"strength\":100}]}", null);
        var sum: u64 = 0;
        var i: usize = 0;
        while (i < r.px.len) : (i += 4) sum += @as(u64, r.px[i]) + r.px[i + 1] + r.px[i + 2];
        try expect(sum > 64 * 3 * 20, "{s} came out black ({d})", .{ st[0], sum });
    }
}

/// Every test, then the count; 0 when all passed.
pub fn run(io: std.Io) !u8 {
    const es = try context();
    std.debug.print("{s}, {s}\n", .{ gl.glGetString(gl.VERSION).?, gl.glGetString(gl.RENDERER).? });
    var p = try Pipeline.init(gpa, es);
    var failed: u32 = 0;
    var total: u32 = 0;
    inline for (tests) |t| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        total += 1;
        if (t[1](.{ .p = &p, .arena = arena.allocator(), .io = io })) |_| {
            const gl_error = gl.glGetError();
            if (gl_error == 0) {
                std.debug.print("ok   {s}\n", .{t[0]});
            } else {
                failed += 1;
                std.debug.print("FAIL {s}: OpenGL error 0x{x}\n", .{ t[0], gl_error });
            }
        } else |err| {
            failed += 1;
            std.debug.print("FAIL {s}: {t}\n", .{ t[0], err });
        }
    }
    std.debug.print("pipeline: {d} of {d} tests passed\n", .{ total - failed, total });
    return if (failed == 0) 0 else 1;
}
