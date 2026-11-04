//! The pipeline's tests, on the GPU, with no window: small made-up images go through the real
//! shaders; what comes back is checked to the 8-bit level. `zig build probe-native`.
const std = @import("std");
const core = @import("photo-core");
const gl = @import("gl.zig");
const gtk = @import("gtk.zig");
const Pipeline = @import("pipeline.zig");
const Cube = @import("cube.zig");
const Exporter = @import("exporter.zig");
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
