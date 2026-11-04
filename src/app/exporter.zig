//! Exports, one photo after another (SPEC.md, Image pipeline, Output): the photo at full size through
//! the same shaders as the preview, then libvips encodes it with the original's metadata on a worker.
const std = @import("std");
const Io = std.Io;
const core = @import("photo-core");
const gl = @import("gl.zig");
const App = @import("app.zig");
const Pipeline = @import("pipeline.zig");
const Looks = @import("looks.zig");
const tools = @import("tools.zig");
const Pool = @import("jobs.zig");
const Settings = @import("settings.zig");
const Mcp = @import("mcp.zig");
const Recipe = core.Recipe;

const Exporter = @This();

const log = std.log.scoped(.export_);

pub const Result = struct { rel: []const u8, path: []const u8 = "", @"error": []const u8 = "", ms: u64 = 0 };

gpa: std.mem.Allocator,
io: Io,
app: *App,
pool: *Pool,
default_folder: []const u8,
// Makes the window's GL context current.
gl_current: *const fn () bool,
pipeline: ?Pipeline = null,
looks: Looks,
batch: ?Batch = null,
on_progress: *const fn (index: usize, total: usize, rel: []const u8) void,
on_done: *const fn (folder: []const u8, results: []const Result, ms: u64) void,

const Batch = struct {
    arena: std.heap.ArenaAllocator,
    rels: []const []const u8,
    options: Settings.Export,
    folder: []const u8,
    name: []const u8,
    crop: ?std.json.Value,
    call: ?*Mcp.Call,
    index: usize = 0,
    results: std.ArrayList(Result) = .empty,
    started: i96,
    job_started: i96 = 0,
};

pub fn busy(e: *const Exporter) bool {
    return e.batch != null;
}

fn time(e: *const Exporter) i96 {
    return Io.Timestamp.now(e.io, .awake).nanoseconds;
}

pub const Extras = struct { name: []const u8 = "", crop: ?std.json.Value = null, call: ?*Mcp.Call = null };

/// Starts exporting; `on_done` hears when all are written.
pub fn start(e: *Exporter, rels: []const []const u8, options: Settings.Export, extras: Extras) !void {
    if (e.batch != null) return error.ExportBusy;
    if (rels.len == 0) return error.NothingToExport;
    var arena: std.heap.ArenaAllocator = .init(e.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const folder = try a.dupe(u8, if (options.folder.len > 0) options.folder else e.default_folder);
    try Io.Dir.cwd().createDirPath(e.io, folder);
    var copy = options;
    copy.folder = folder;
    copy.suffix = try a.dupe(u8, options.suffix);
    const owned = try a.alloc([]const u8, rels.len);
    for (rels, owned) |r, *o| o.* = try a.dupe(u8, r);
    var crop: ?std.json.Value = null;
    if (extras.crop) |c| crop = try std.json.parseFromSliceLeaky(std.json.Value, a, try std.json.Stringify.valueAlloc(a, c, .{}), .{});
    e.batch = .{ .arena = arena, .rels = owned, .options = copy, .folder = folder, .name = try a.dupe(u8, extras.name), .crop = crop, .call = extras.call, .started = e.time() };
    e.next();
}

// The recipe to export a photo with: its own, or with this export's own crop.
fn recipeFor(e: *Exporter, a: std.mem.Allocator, rel: []const u8) !Recipe {
    const b = &e.batch.?;
    const f = &(e.app.folder orelse return error.NoFolder);
    const i = f.index(rel) orelse return error.NoSuchPhoto;
    const s = try e.app.session(i);
    const r = try s.recipe(a);
    const crop = b.crop orelse return r;
    var patch = try crop.object.clone(a);
    try tools.fitCropPatch(e.app, a, i, r.crop, &patch);
    var wrapper: std.json.ObjectMap = .empty;
    try wrapper.put(a, "crop", .{ .object = patch });
    return Recipe.apply(a, r, .{ .object = wrapper });
}

fn next(e: *Exporter) void {
    const b = &(e.batch orelse return);
    if (b.index >= b.rels.len) return e.finish();
    const rel = b.rels[b.index];
    const f = &(e.app.folder orelse return e.fail("the folder was closed"));
    b.job_started = e.time();
    e.on_progress(b.index, b.rels.len, rel);
    const task = e.gpa.create(Decode) catch return e.fail("out of memory");
    task.* = .{ .exporter = e, .path = std.fmt.allocPrintSentinel(e.gpa, "{s}/{s}", .{ f.path, rel }, 0) catch return e.fail("out of memory") };
    e.pool.submit(&task.task, .urgent);
}

const Decode = struct {
    task: Pool.Task = .{ .run = run, .done = done },
    exporter: *Exporter,
    path: [:0]u8,
    linear: ?core.decode.Linear = null,

    fn run(task: *Pool.Task) void {
        const t: *Decode = @fieldParentPtr("task", task);
        t.linear = core.decode.linear(t.exporter.gpa, t.path, 0) catch null;
    }

    fn done(task: *Pool.Task) void {
        const t: *Decode = @fieldParentPtr("task", task);
        const e = t.exporter;
        defer e.gpa.destroy(t);
        defer e.gpa.free(t.path);
        var lin = t.linear orelse return e.fail("it didn't decode");
        defer lin.deinit(e.gpa);
        e.render(&lin) catch |err| e.fail(@errorName(err));
    }
};

/// The photo through the pipeline at its full output size: RGB rows from the top, 8 or 16 bits.
pub fn renderPixels(p: *Pipeline, gpa: std.mem.Allocator, r: Recipe, bits: u8, p3: bool) !struct { w: u32, h: u32, data: []u8 } {
    const size = p.outputSize(r, false);
    const w: usize = @intCast(size[0]);
    const h: usize = @intCast(size[1]);
    const deep = bits == 16;
    var t = if (deep) try Pipeline.target(size[0], size[1], gl.RGBA32F, gl.FLOAT) else try Pipeline.target(size[0], size[1], gl.RGBA8, gl.UNSIGNED_BYTE);
    defer t.free();
    p.render(r, .{ .fbo = t.fbo, .width = size[0], .height = size[1], .p3 = p3, .dither = if (deep) 1.0 / 65535.0 else 1.0 / 255.0 });
    gl.glBindFramebuffer(gl.FRAMEBUFFER, t.fbo);
    const out = try gpa.alloc(u8, w * h * @as(usize, if (deep) 6 else 3));
    errdefer gpa.free(out);
    if (deep) {
        const rgba = try gpa.alloc(f32, w * h * 4);
        defer gpa.free(rgba);
        gl.glReadPixels(0, 0, size[0], size[1], gl.RGBA, gl.FLOAT, rgba.ptr);
        const to: []align(1) u16 = std.mem.bytesAsSlice(u16, out);
        for (0..w * h) |i| for (0..3) |k| {
            to[i * 3 + k] = @intFromFloat(@round(std.math.clamp(rgba[i * 4 + k], 0, 1) * 65535));
        };
    } else {
        const rgba = try gpa.alloc(u8, w * h * 4);
        defer gpa.free(rgba);
        gl.glReadPixels(0, 0, size[0], size[1], gl.RGBA, gl.UNSIGNED_BYTE, rgba.ptr);
        for (0..w * h) |i| {
            out[i * 3] = rgba[i * 4];
            out[i * 3 + 1] = rgba[i * 4 + 1];
            out[i * 3 + 2] = rgba[i * 4 + 2];
        }
    }
    return .{ .w = @intCast(w), .h = @intCast(h), .data = out };
}

fn render(e: *Exporter, lin: *const core.decode.Linear) !void {
    const b = &(e.batch orelse return);
    const a = b.arena.allocator();
    const rel = b.rels[b.index];
    if (!e.gl_current()) return error.NoOpenGL;
    if (e.pipeline == null) e.pipeline = try Pipeline.init(e.gpa, glIsEs());
    const p = &e.pipeline.?;
    const r = try e.recipeFor(a, rel);
    try p.setSource(@intCast(lin.width), @intCast(lin.height), lin.rgb.ptr);
    e.looks.prepare(p, r);
    const bits = b.options.format.bits();
    const px = try renderPixels(p, e.gpa, r, bits, b.options.space == .p3);
    errdefer e.gpa.free(px.data);
    const f = &e.app.folder.?;
    const task = try e.gpa.create(Encode);
    task.* = .{
        .exporter = e,
        .source = try std.fmt.allocPrintSentinel(e.gpa, "{s}/{s}", .{ f.path, rel }, 0),
        .out = try outputPath(e.gpa, e.io, b.folder, try stemFor(a, rel, b.name, b.rels.len), b.options.suffix, b.options.format.extension()),
        .options = .{ .format = b.options.format, .quality = b.options.quality, .long_edge = b.options.long_edge, .keep_metadata = b.options.keep_metadata, .keep_gps = b.options.keep_gps, .space = b.options.space },
        .data = px.data,
        .pixels = .{ .width = px.w, .height = px.h, .data = if (bits == 8) .{ .u8 = px.data } else .{ .u16 = @alignCast(std.mem.bytesAsSlice(u16, @as([]align(2) u8, @alignCast(px.data)))) } },
    };
    e.pool.submit(&task.task, .urgent);
}

fn glIsEs() bool {
    const version = std.mem.span(gl.glGetString(gl.VERSION).?);
    return std.mem.startsWith(u8, version, "OpenGL ES");
}

/// The exported file's name: the photo's, or the one asked for (before each photo's own when several).
pub fn stemFor(a: std.mem.Allocator, rel: []const u8, name: []const u8, count: usize) ![]const u8 {
    const own = withoutExtension(std.fs.path.basename(rel));
    if (name.len == 0) return own;
    const asked = withoutExtension(std.fs.path.basename(name));
    if (count == 1) return asked;
    return std.fmt.allocPrint(a, "{s}-{s}", .{ asked, own });
}

fn withoutExtension(name: []const u8) []const u8 {
    return name[0 .. std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len];
}

/// `<folder>/<name><suffix><ext>`, with -2, -3… when that's taken: an export never overwrites.
pub fn outputPath(gpa: std.mem.Allocator, io: Io, folder: []const u8, stem: []const u8, suffix: []const u8, ext: []const u8) ![:0]u8 {
    var n: u32 = 1;
    while (n < 10_000) : (n += 1) {
        const path = if (n == 1)
            try std.fmt.allocPrintSentinel(gpa, "{s}/{s}{s}{s}", .{ folder, stem, suffix, ext }, 0)
        else
            try std.fmt.allocPrintSentinel(gpa, "{s}/{s}{s}-{d}{s}", .{ folder, stem, suffix, n, ext }, 0);
        Io.Dir.cwd().access(io, path, .{}) catch return path;
        gpa.free(path);
    }
    return error.TooManyExports;
}

const Encode = struct {
    task: Pool.Task = .{ .run = run, .done = done },
    exporter: *Exporter,
    source: [:0]u8,
    out: [:0]u8,
    options: core.encode.Options,
    data: []u8,
    pixels: core.encode.Pixels,
    err: ?anyerror = null,

    fn run(task: *Pool.Task) void {
        const t: *Encode = @fieldParentPtr("task", task);
        core.encode.save(t.exporter.io, t.exporter.gpa, t.source, t.pixels, t.options, t.out) catch |err| {
            t.err = err;
        };
    }

    fn done(task: *Pool.Task) void {
        const t: *Encode = @fieldParentPtr("task", task);
        const e = t.exporter;
        defer {
            e.gpa.free(t.data);
            e.gpa.free(t.source);
            e.gpa.free(t.out);
            e.gpa.destroy(t);
        }
        if (t.err) |err| return e.fail(@errorName(err));
        const b = &(e.batch orelse return);
        const a = b.arena.allocator();
        const rel = b.rels[b.index];
        const ms: u64 = @intCast(@divFloor(e.time() - b.job_started, std.time.ns_per_ms));
        log.info("{s} → {s} in {d} ms", .{ rel, t.out, ms });
        b.results.append(a, .{ .rel = rel, .path = a.dupe(u8, t.out) catch "", .ms = ms }) catch {};
        b.index += 1;
        e.next();
    }
};

// This photo failed; on to the next.
fn fail(e: *Exporter, why: []const u8) void {
    const b = &(e.batch orelse return);
    const a = b.arena.allocator();
    const rel = if (b.index < b.rels.len) b.rels[b.index] else "";
    log.err("export {s}: {s}", .{ rel, why });
    b.results.append(a, .{ .rel = rel, .@"error" = a.dupe(u8, why) catch "" }) catch {};
    b.index += 1;
    e.next();
}

fn finish(e: *Exporter) void {
    var b = e.batch.?;
    e.batch = null;
    defer b.arena.deinit();
    const a = b.arena.allocator();
    const ms: u64 = @intCast(@divFloor(e.time() - b.started, std.time.ns_per_ms));
    e.on_done(b.folder, b.results.items, ms);
    const call = b.call orelse return;
    var text: Io.Writer.Allocating = .init(a);
    var failed = false;
    for (b.results.items) |r| {
        if (r.@"error".len > 0) {
            failed = true;
            text.writer.print("{s}: failed, {s}\n", .{ r.rel, r.@"error" }) catch {};
        } else text.writer.print("{s} → {s} ({d} ms)\n", .{ r.rel, r.path, r.ms }) catch {};
    }
    text.writer.writeAll("Metadata (camera, lens, exposure, date, colour profile) kept.") catch {};
    call.finish(Mcp.textResult(e.gpa, text.written(), failed) catch return);
}
