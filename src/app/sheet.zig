//! A contact sheet for Claude: many photos in one picture, each through the real pipeline with its
//! edits and marked with its position in the folder, the same number get_view shows. A picture of
//! about 1568 px on its long edge, the most Claude sees without it being shrunk first. Photos decode
//! on workers; once all have, the cells take the shape most of them are and they draw on the main loop.
//! Closeups come through here too: one photo at full size, for Claude to judge what a small picture hides.
const std = @import("std");
const Io = std.Io;
const core = @import("photo-core");
const gl = @import("gl.zig");
const App = @import("app.zig");
const Mcp = @import("mcp.zig");
const Pool = @import("jobs.zig");
const memory = @import("memory.zig");
const Pipeline = @import("pipeline.zig");
const Looks = @import("looks.zig");
const tools = @import("tools.zig");
const Recipe = core.Recipe;

const Sheet = @This();

const log = std.log.scoped(.sheet);

pub const max_photos = 30;
const edge = 1568;
const gap = 4;
const background = 32;
const max_decode_edge = 2048;
// Sharpness means little measured on anything smaller.
const min_decode_edge = 1024;
const sharpness_tiles = 8;
// Always measured at this size: on more pixels the same photo scores differently.
const sharpness_edge = 1024;
const closeup_edge = 1200;
const compare_edge = 782;
const digit_scale = 3;
const digit_pad = 4;

gpa: std.mem.Allocator,
app: *App,
pool: *Pool,
looks: Looks,
gl_current: *const fn () bool,
es: *const fn () bool,
pipeline: ?Pipeline = null,

pub const Layout = struct {
    cols: u32,
    rows: u32,
    cell_w: u32,
    cell_h: u32,
    width: u32,
    height: u32,
};

pub const Shape = enum {
    landscape,
    portrait,
    square,

    fn height(shape: Shape, width: u32) u32 {
        return switch (shape) {
            .landscape => width * 3 / 4,
            .portrait => width * 4 / 3,
            .square => width,
        };
    }
};

/// The shape most of these photos are, width over height. Near-square counts for neither side.
pub fn shapeFor(aspects: []const f64) Shape {
    var wide: usize = 0;
    var tall: usize = 0;
    for (aspects) |x| {
        if (x > 1.1) wide += 1 else if (x < 0.9) tall += 1;
    }
    const square = aspects.len - wide - tall;
    if (square > wide and square > tall) return .square;
    return if (tall > wide) .portrait else .landscape;
}

/// The biggest cells of this shape that fit `n` photos on the sheet.
pub fn layoutFor(n: u32, shape: Shape) Layout {
    var best: Layout = .{ .cols = 1, .rows = 1, .cell_w = 1, .cell_h = 1, .width = 1, .height = 1 };
    var cols: u32 = 1;
    while (cols <= @max(n, 1)) : (cols += 1) {
        const rows = (@max(n, 1) + cols - 1) / cols;
        const cell_w = (edge - gap * (cols - 1)) / cols;
        const cell_h = shape.height(cell_w);
        const height = rows * cell_h + gap * (rows - 1);
        if (height <= edge and cell_w > best.cell_w) {
            best = .{ .cols = cols, .rows = rows, .cell_w = cell_w, .cell_h = cell_h, .width = cols * cell_w + gap * (cols - 1), .height = height };
        }
    }
    return best;
}

/// How sharp a photo's sharpest part is: the strongest fine detail among tiles of it, so a sharp
/// subject before a soft background counts in full. Linear half floats, RGB. Higher is sharper; about
/// 0 to 100 on real photos.
pub fn sharpness(rgb: []const u16, width: usize, height: usize) f32 {
    if (width < 3 or height < 3) return 0;
    const level = struct {
        fn f(pixels: []const u16, w: usize, x: usize, y: usize) f32 {
            const half: f16 = @bitCast(pixels[(y * w + x) * 3 + 1]);
            return @sqrt(@max(@as(f32, half), 0));
        }
    }.f;
    var best: f32 = 0;
    for (0..sharpness_tiles) |ty| for (0..sharpness_tiles) |tx| {
        const x0 = @max(1, tx * width / sharpness_tiles);
        const x1 = @min(width - 1, (tx + 1) * width / sharpness_tiles);
        const y0 = @max(1, ty * height / sharpness_tiles);
        const y1 = @min(height - 1, (ty + 1) * height / sharpness_tiles);
        var sum: f32 = 0;
        var n: f32 = 0;
        for (y0..y1) |y| for (x0..x1) |x| {
            const edge_strength = 4 * level(rgb, width, x, y) - level(rgb, width, x - 1, y) - level(rgb, width, x + 1, y) - level(rgb, width, x, y - 1) - level(rgb, width, x, y + 1);
            sum += edge_strength * edge_strength;
            n += 1;
        };
        if (n > 0) best = @max(best, sum / n);
    };
    return @sqrt(best) * 400;
}

// Five wide, seven high, top row first; bit 4 is the left column.
const digits = [10][7]u5{
    .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
    .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
    .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 },
    .{ 0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110 },
    .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 },
    .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 },
    .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
    .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
    .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
    .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100 },
};

/// White digits on a black box, at x, y of an RGB picture `width` wide.
pub fn drawNumber(rgb: []u8, width: u32, x: u32, y: u32, number: u32) void {
    var buf: [10]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{number}) catch return;
    const advance = 6 * digit_scale;
    const box_w: u32 = @intCast(text.len * advance - digit_scale + 2 * digit_pad);
    const box_h: u32 = 7 * digit_scale + 2 * digit_pad;
    const height: u32 = @intCast(rgb.len / 3 / width);
    for (y..@min(y + box_h, height)) |py| for (x..@min(x + box_w, width)) |px| {
        @memset(rgb[(py * width + px) * 3 ..][0..3], 0);
    };
    for (text, 0..) |char, i| {
        const glyph = digits[char - '0'];
        const left = x + digit_pad + i * advance;
        for (glyph, 0..) |row, gy| for (0..5) |gx| {
            if (row & (@as(u5, 0b10000) >> @intCast(gx)) == 0) continue;
            for (0..digit_scale) |sy| for (0..digit_scale) |sx| {
                const px = left + gx * digit_scale + sx;
                const py = y + digit_pad + gy * digit_scale + sy;
                if (px < width and py < height) @memset(rgb[(py * width + px) * 3 ..][0..3], 255);
            };
        };
    }
}

const Job = struct {
    sheet: *Sheet,
    arena: std.heap.ArenaAllocator,
    call: *Mcp.Call,
    lead: []const u8,
    cells: []*Cell,
    left: usize,
};

const Cell = struct {
    task: Pool.Task = .{ .run = run, .done = done },
    job: *Job,
    position: u32,
    picked: bool,
    rel: []const u8,
    path: [:0]const u8,
    recipe_json: []const u8,
    edge: u32,
    linear: ?core.decode.Linear = null,
    sharp: f32 = 0,
    info_arena: std.heap.ArenaAllocator,
    info: core.decode.Info = .{},

    fn run(task: *Pool.Task) void {
        const c: *Cell = @fieldParentPtr("task", task);
        const gpa = c.job.sheet.gpa;
        c.linear = core.decode.linear(gpa, c.path, c.edge) catch |err| blk: {
            log.warn("{s}: {t}", .{ c.rel, err });
            break :blk null;
        };
        if (c.linear) |l| {
            if (c.edge == sharpness_edge) {
                c.sharp = sharpness(l.rgb, l.width, l.height);
            } else if (core.decode.linear(gpa, c.path, sharpness_edge)) |measured| {
                var m = measured;
                defer m.deinit(gpa);
                c.sharp = sharpness(m.rgb, m.width, m.height);
            } else |_| {}
        }
        c.info = core.decode.info(c.info_arena.allocator(), c.path) catch .{};
    }

    fn done(task: *Pool.Task) void {
        const c: *Cell = @fieldParentPtr("task", task);
        const job = c.job;
        job.left -= 1;
        if (job.left == 0) job.sheet.finish(job);
    }
};

fn describe(a: std.mem.Allocator, c: *const Cell, r: Recipe) ![]const u8 {
    var w: Io.Writer.Allocating = .init(a);
    try w.writer.print("{d}  {s}", .{ c.position, c.rel });
    if (c.linear == null) {
        try w.writer.writeAll("  (couldn't be read)");
        return w.written();
    }
    const i = c.info;
    try w.writer.print("  {s}  {s} s f/{s} ISO {s} {s} mm  sharp {d:.0}", .{ i.taken, i.exposure, i.aperture, i.iso, i.focal_length, c.sharp });
    if (c.picked) try w.writer.writeAll("  picked");
    if (!r.isDefault()) {
        try w.writer.print("  edited by {t}", .{r.updatedBy});
        if (!std.mem.eql(u8, r.look.name, Recipe.no_look)) try w.writer.print(", {s}", .{r.look.name});
    }
    return w.written();
}

// Width over height of a photo as the recipe's crop and turn leave it.
fn outputAspect(l: *const core.decode.Linear, r: Recipe) f64 {
    const w: f64 = @floatFromInt(l.width);
    const h: f64 = @floatFromInt(l.height);
    const turned = (r.crop.rotate / 90) % 2 == 1;
    const across = (if (turned) h else w) * r.crop.rect[2];
    const down = (if (turned) w else h) * r.crop.rect[3];
    return across / @max(down, 1);
}

/// Answers `call` with `lead`, a line per photo and the picture.
pub fn start(s: *Sheet, call: *Mcp.Call, indices: []const u32, lead: []const u8) !void {
    const app = s.app;
    const f = &(app.folder orelse return error.NoFolder);
    const count = @min(indices.len, max_photos);
    if (count == 0) return error.NoPhotos;
    const job = try s.gpa.create(Job);
    errdefer s.gpa.destroy(job);
    job.* = .{ .sheet = s, .arena = .init(s.gpa), .call = call, .lead = "", .cells = &.{}, .left = count };
    errdefer job.arena.deinit();
    const a = job.arena.allocator();
    job.lead = try a.dupe(u8, lead);
    job.cells = try a.alloc(*Cell, count);
    // Big enough for whichever shape the cells turn out, and to measure sharpness on.
    const biggest = @max(layoutFor(@intCast(count), .landscape).cell_w, layoutFor(@intCast(count), .portrait).cell_h);
    const decode_edge = std.math.clamp(biggest * 3 / 2, min_decode_edge, max_decode_edge);
    for (indices[0..count], job.cells) |index, *cell| {
        const session = try app.session(index);
        const photo = f.photos[index];
        cell.* = try s.gpa.create(Cell);
        cell.*.* = .{
            .job = job,
            .position = index + 1,
            .picked = photo.picked,
            .rel = try a.dupe(u8, photo.rel),
            .path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ f.path, photo.rel }, 0),
            .recipe_json = try a.dupe(u8, session.json),
            .edge = decode_edge,
            .info_arena = .init(s.gpa),
        };
    }
    // Nothing above can leave a task behind: they all start or none does.
    for (job.cells) |cell| s.pool.submit(&cell.task, .urgent);
}

fn ready(s: *Sheet) !*Pipeline {
    if (!s.gl_current()) return error.NoOpenGL;
    if (s.pipeline == null) s.pipeline = try Pipeline.init(s.gpa, s.es());
    return &s.pipeline.?;
}

/// The looks folder or a shader changed.
pub fn libraryChanged(s: *Sheet) void {
    s.looks.clear();
    if (s.pipeline != null and s.gl_current()) s.pipeline.?.dropShaders();
}

fn draw(s: *Sheet, rgb: []u8, lay: Layout, slot: usize, l: *const core.decode.Linear, r: Recipe) !void {
    const p = try s.ready();
    try p.setSource(@intCast(l.width), @intCast(l.height), l.rgb.ptr);
    s.looks.prepare(p, r);
    const size = p.outputSize(r, false);
    const fit = @min(@as(f64, @floatFromInt(lay.cell_w)) / @as(f64, @floatFromInt(size[0])), @as(f64, @floatFromInt(lay.cell_h)) / @as(f64, @floatFromInt(size[1])));
    const w: u32 = std.math.clamp(@as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(size[0])) * fit))), 1, lay.cell_w);
    const h: u32 = std.math.clamp(@as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(size[1])) * fit))), 1, lay.cell_h);
    var t = try Pipeline.target(@intCast(w), @intCast(h), gl.RGBA8, gl.UNSIGNED_BYTE);
    defer t.free();
    p.render(r, .{ .fbo = t.fbo, .width = @intCast(w), .height = @intCast(h), .dither = 1.0 / 255.0 });
    gl.glBindFramebuffer(gl.FRAMEBUFFER, t.fbo);
    const px = try s.gpa.alloc(u8, @as(usize, w) * h * 4);
    defer s.gpa.free(px);
    gl.glReadPixels(0, 0, @intCast(w), @intCast(h), gl.RGBA, gl.UNSIGNED_BYTE, px.ptr);
    const col: u32 = @intCast(slot % lay.cols);
    const row: u32 = @intCast(slot / lay.cols);
    const left = col * (lay.cell_w + gap) + (lay.cell_w - w) / 2;
    const top = row * (lay.cell_h + gap) + (lay.cell_h - h) / 2;
    for (0..h) |y| for (0..w) |x| {
        const from = (y * w + x) * 4;
        const to = ((top + y) * lay.width + left + x) * 3;
        rgb[to..][0..3].* = px[from..][0..3].*;
    };
}

fn finish(s: *Sheet, job: *Job) void {
    defer {
        for (job.cells) |cell| {
            if (cell.linear) |*l| l.deinit(s.gpa);
            cell.info_arena.deinit();
            s.gpa.destroy(cell);
        }
        job.arena.deinit();
        s.gpa.destroy(job);
    }
    const result = s.compose(job) catch |err| {
        log.warn("sheet: {t}", .{err});
        job.call.finish(Mcp.textResult(s.gpa, "The contact sheet failed.", true) catch return);
        return;
    };
    tools.finishScreenshot(s.app, .{ .call = job.call, .text = result.text }, result.base64, "");
}

fn compose(s: *Sheet, job: *Job) !struct { text: []u8, base64: []const u8 } {
    const a = job.arena.allocator();
    const recipes = try a.alloc(Recipe, job.cells.len);
    var aspects: std.ArrayList(f64) = .empty;
    for (job.cells, recipes) |cell, *r| {
        r.* = Recipe.parse(a, cell.recipe_json) catch Recipe{};
        if (cell.linear) |*l| try aspects.append(a, outputAspect(l, r.*));
    }
    const lay = layoutFor(@intCast(job.cells.len), shapeFor(aspects.items));
    const rgb = try a.alloc(u8, @as(usize, lay.width) * lay.height * 3);
    @memset(rgb, background);
    var w: Io.Writer.Allocating = .init(s.gpa);
    errdefer w.deinit();
    try w.writer.print("{s}\n", .{job.lead});
    for (job.cells, recipes, 0..) |cell, r, slot| {
        try w.writer.print("{s}\n", .{try describe(a, cell, r)});
        if (cell.linear) |*l| s.draw(rgb, lay, slot, l, r) catch |err| log.warn("{s}: {t}", .{ cell.rel, err });
        const x: u32 = @as(u32, @intCast(slot % lay.cols)) * (lay.cell_w + gap);
        const y: u32 = @as(u32, @intCast(slot / lay.cols)) * (lay.cell_h + gap);
        drawNumber(rgb, lay.width, x, y, cell.position);
    }
    const jpeg = try core.encode.jpegBytes(rgb, lay.width, lay.height, 85);
    defer core.vips.freeMemory(jpeg);
    const base64 = try a.alloc(u8, std.base64.standard.Encoder.calcSize(jpeg.len));
    _ = std.base64.standard.Encoder.encode(base64, jpeg);
    return .{ .text = try w.toOwnedSlice(), .base64 = base64 };
}

// ---- A closer look ----

pub const Window = struct { width: u32, height: u32, view: [4]f32, percent: u32 };

/// The part of a photo `size` big to show, on at most `most` pixels, never bigger than its own pixels.
/// Moved back onto the photo if it would run off it. `at` null: all of it.
pub fn windowFor(size: [2]u32, at: ?[2]f32, share: f32, most: u32) Window {
    const w: f64 = @floatFromInt(size[0]);
    const h: f64 = @floatFromInt(size[1]);
    const long = @max(w, h);
    const side = std.math.clamp(@as(f64, share), 0.01, 1) * long;
    const across = if (at != null) @min(side, w) else w;
    const down = if (at != null) @min(side, h) else h;
    const scale = @min(1, @as(f64, @floatFromInt(most)) / @max(across, down));
    const point = at orelse [2]f32{ 0.5, 0.5 };
    const x = std.math.clamp(@as(f64, point[0]) * w - across / 2, 0, w - across);
    const y = std.math.clamp(@as(f64, point[1]) * h - down / 2, 0, h - down);
    return .{
        .width = @intFromFloat(@max(1, @round(across * scale))),
        .height = @intFromFloat(@max(1, @round(down * scale))),
        .view = .{ @floatCast(x / w), @floatCast(y / h), @floatCast(across / w), @floatCast(down / h) },
        .percent = @intFromFloat(@round(scale * 100)),
    };
}

const Closeup = struct {
    task: Pool.Task = .{ .run = runCloseup, .done = doneCloseup },
    sheet: *Sheet,
    request: App.Closeup,
    path: [:0]u8,
    recipe_json: []u8,
    linear: ?core.decode.Linear = null,
};

/// Answers with the photo in detail, or before and after, under `request.text`.
pub fn closeup(s: *Sheet, request: App.Closeup) !void {
    const f = &(s.app.folder orelse return error.NoFolder);
    const session = try s.app.session(request.index);
    const c = try s.gpa.create(Closeup);
    errdefer s.gpa.destroy(c);
    const path = try std.fmt.allocPrintSentinel(s.gpa, "{s}/{s}", .{ f.path, f.photos[request.index].rel }, 0);
    errdefer s.gpa.free(path);
    c.* = .{ .sheet = s, .request = request, .path = path, .recipe_json = try s.gpa.dupe(u8, session.json) };
    s.pool.submit(&c.task, .urgent);
}

fn runCloseup(task: *Pool.Task) void {
    const c: *Closeup = @fieldParentPtr("task", task);
    // In detail, the photo's own pixels; side by side, a preview's are plenty.
    c.linear = core.decode.linear(c.sheet.gpa, c.path, if (c.request.at != null) 0 else max_decode_edge) catch |err| blk: {
        log.warn("{s}: {t}", .{ c.path, err });
        break :blk null;
    };
}

fn doneCloseup(task: *Pool.Task) void {
    const c: *Closeup = @fieldParentPtr("task", task);
    const s = c.sheet;
    defer {
        if (c.linear) |*l| l.deinit(s.gpa);
        s.gpa.free(c.path);
        s.gpa.free(c.recipe_json);
        s.gpa.destroy(c);
        memory.trim();
    }
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const base64 = s.composeCloseup(arena.allocator(), c) catch |err| blk: {
        log.warn("closeup: {t}", .{err});
        break :blk "";
    };
    tools.finishScreenshot(s.app, .{ .call = c.request.call, .text = c.request.text }, base64, "");
}

fn composeCloseup(s: *Sheet, a: std.mem.Allocator, c: *const Closeup) ![]const u8 {
    const l = &(c.linear orelse return error.NoPhoto);
    const p = try s.ready();
    // A full-size photo's render targets are big: not kept for the next time.
    defer if (c.request.at != null) p.release();
    try p.setSource(@intCast(l.width), @intCast(l.height), l.rgb.ptr);
    const r = try Recipe.parse(a, c.recipe_json);
    const size = p.outputSize(r, false);
    const compare = c.request.compare;
    const window = windowFor(.{ @intCast(size[0]), @intCast(size[1]) }, c.request.at, c.request.size, if (compare) compare_edge else closeup_edge);
    const panels: u32 = if (compare) 2 else 1;
    const width = panels * window.width + (panels - 1) * gap;
    const rgb = try a.alloc(u8, @as(usize, width) * window.height * 3);
    @memset(rgb, background);
    if (compare) {
        const original: Recipe = .{ .crop = r.crop };
        s.looks.prepare(p, original);
        try drawPanel(s, p, original, window, null, rgb, width, 0);
    }
    s.looks.prepare(p, r);
    try drawPanel(s, p, r, window, c.request.show_mask, rgb, width, (panels - 1) * (window.width + gap));
    const jpeg = try core.encode.jpegBytes(rgb, width, window.height, 88);
    defer core.vips.freeMemory(jpeg);
    const base64 = try a.alloc(u8, std.base64.standard.Encoder.calcSize(jpeg.len));
    _ = std.base64.standard.Encoder.encode(base64, jpeg);
    return base64;
}

fn drawPanel(s: *Sheet, p: *Pipeline, r: Recipe, window: Window, show_mask: ?usize, rgb: []u8, width: u32, left: u32) !void {
    var t = try Pipeline.target(@intCast(window.width), @intCast(window.height), gl.RGBA8, gl.UNSIGNED_BYTE);
    defer t.free();
    p.render(r, .{ .fbo = t.fbo, .width = @intCast(window.width), .height = @intCast(window.height), .dither = 1.0 / 255.0, .view = window.view, .show_mask = show_mask });
    gl.glBindFramebuffer(gl.FRAMEBUFFER, t.fbo);
    const px = try s.gpa.alloc(u8, @as(usize, window.width) * window.height * 4);
    defer s.gpa.free(px);
    gl.glReadPixels(0, 0, @intCast(window.width), @intCast(window.height), gl.RGBA, gl.UNSIGNED_BYTE, px.ptr);
    for (0..window.height) |y| for (0..window.width) |x| {
        rgb[(y * width + left + x) * 3 ..][0..3].* = px[(y * window.width + x) * 4 ..][0..3].*;
    };
}

const testing = std.testing;

test "a closer look shows that part at 100%, stays on the photo, and shrinks only what doesn't fit" {
    const photo = [2]u32{ 3888, 5184 };
    // A face: a tenth of the long edge, its own pixels.
    const face = windowFor(photo, .{ 0.5, 0.4 }, 0.1, closeup_edge);
    try testing.expectEqual(518, face.width);
    try testing.expectEqual(518, face.height);
    try testing.expectEqual(100, face.percent);
    try testing.expectApproxEqAbs(@as(f32, 0.5 - 518.4 / 3888.0 / 2.0), face.view[0], 0.001);
    // Half the photo doesn't fit in 1200 pixels: it's smaller, not cut off.
    const half = windowFor(photo, .{ 0.5, 0.5 }, 0.5, closeup_edge);
    try testing.expectEqual(1200, half.height);
    try testing.expect(half.percent < 50);
    // In a corner, the window moves back onto the photo.
    const corner = windowFor(photo, .{ 0.99, 0.01 }, 0.2, closeup_edge);
    try testing.expectEqual(0, corner.view[1]);
    try testing.expect(corner.view[0] + corner.view[2] <= 1.0001);
    // Too big a window is all the photo, in its shape.
    const all = windowFor(photo, .{ 0.5, 0.5 }, 1, closeup_edge);
    try testing.expectApproxEqAbs(@as(f32, 1), all.view[2], 0.001);
    try testing.expectEqual(900, all.width);
    // No place given: all of it, whatever the share.
    try testing.expectEqual(1200, windowFor(photo, null, 0.1, closeup_edge).height);
}

test "a sheet fits on 1568 pixels, with the biggest cells that fit" {
    for (1..max_photos + 1) |n| for ([_]Shape{ .landscape, .portrait, .square }) |shape| {
        const l = layoutFor(@intCast(n), shape);
        try testing.expect(l.cols * l.rows >= n);
        try testing.expect(l.width <= edge and l.height <= edge);
    };
    try testing.expectEqual(1, layoutFor(1, .landscape).cols);
    const twenty = layoutFor(20, .landscape);
    try testing.expectEqual(4, twenty.cols);
    try testing.expect(twenty.cell_w > 380);
    try testing.expect(layoutFor(30, .landscape).cell_w >= 300);
    // Portrait photos in portrait cells are bigger than in landscape cells, where they'd be
    // only as high as those.
    try testing.expect(layoutFor(20, .portrait).cell_h > layoutFor(20, .landscape).cell_h);
}

test "the cells take the shape most photos are" {
    try testing.expectEqual(.landscape, shapeFor(&.{}));
    try testing.expectEqual(.portrait, shapeFor(&.{ 0.75, 0.75, 1.33 }));
    try testing.expectEqual(.landscape, shapeFor(&.{ 1.33, 1.33, 0.75 }));
    try testing.expectEqual(.landscape, shapeFor(&.{ 1.33, 0.75 }));
    try testing.expectEqual(.square, shapeFor(&.{ 1, 1, 0.75 }));
}

test "sharpness: detail scores above the same picture blurred, a flat picture none, whatever else is soft" {
    const w = 64;
    const h = 64;
    var sharp: [w * h * 3]u16 = undefined;
    var soft: [w * h * 3]u16 = undefined;
    var flat: [w * h * 3]u16 = undefined;
    var part: [w * h * 3]u16 = undefined;
    for (0..h) |y| for (0..w) |x| {
        const hard: f16 = if ((x / 2 + y / 2) % 2 == 0) 0.6 else 0.1;
        const gentle: f16 = 0.3 + 0.2 * @as(f16, @floatFromInt(x)) / w;
        for (0..3) |k| {
            sharp[(y * w + x) * 3 + k] = @bitCast(hard);
            soft[(y * w + x) * 3 + k] = @bitCast(gentle);
            flat[(y * w + x) * 3 + k] = @bitCast(@as(f16, 0.4));
            // A sharp subject in one corner, the rest soft.
            part[(y * w + x) * 3 + k] = @bitCast(if (x < 8 and y < 8) hard else gentle);
        }
    };
    const s = sharpness(&sharp, w, h);
    try testing.expectEqual(0, sharpness(&flat, w, h));
    try testing.expect(s > 10 * sharpness(&soft, w, h));
    try testing.expect(sharpness(&part, w, h) > 0.5 * s);
    try testing.expectEqual(0, sharpness(&flat, 2, 2));
}

test "a number is white on a black box, and stays inside the picture" {
    const width = 60;
    var rgb: [width * 40 * 3]u8 = @splat(100);
    drawNumber(&rgb, width, 0, 0, 7);
    // The top bar of the 7: its first pixel after the box's padding.
    try testing.expectEqual(255, rgb[(digit_pad * width + digit_pad) * 3]);
    // The box's corner, and outside the box.
    try testing.expectEqual(0, rgb[0]);
    try testing.expectEqual(100, rgb[(35 * width + 50) * 3]);
    // A number too long for the picture doesn't write past it.
    drawNumber(&rgb, width, 40, 30, 123456);
}
