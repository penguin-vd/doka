//! Click a subject: MobileSAM through ONNX Runtime, both downloaded by scripts/subject-model.py and
//! loaded only when first asked for, so the app starts as fast without them and works without them.
//! The model's coarse mask is refined against the photo's own edges, saved as a small PNG under
//! `.photo-editor/masks/`, and from there it's a mask like any other.
const builtin = @import("builtin");
const std = @import("std");
const core = @import("photo-core");
const Pool = @import("jobs.zig");
const memory = @import("memory.zig");
const Recipe = core.Recipe;

const Subject = @This();

const log = std.log.scoped(.subject);

pub const library_name = if (builtin.os.tag == .macos) "libonnxruntime.dylib" else "libonnxruntime.so";
pub const encoder_name = "mobile_sam_image_encoder.onnx";
pub const decoder_name = "sam_mask_decoder_multi.onnx";

// The size the model works at, its long edge; and its image embedding's shape.
const model_edge = 1024;
const embedding_len = 256 * 64 * 64;
// The photo size masks are made at: the preview's, whose edges they're refined against.
const mask_edge = 2048;
// The last embedding is kept: more clicks on the same photo take a fraction of the time.

gpa: std.mem.Allocator,
io: std.Io,
pool: *Pool,
models_dir: []const u8,
mutex: std.Io.Mutex = .init,
ort: ?Ort = null,
decoder: ?*anyopaque = null,
cached: ?Encoded = null,

const Encoded = struct {
    path: [:0]u8,
    embedding: []f32,
    // Display-encoded brightness of the photo at mask size: what edges are refined against.
    guide: []f32,
    width: u32,
    height: u32,

    fn deinit(e: *Encoded, gpa: std.mem.Allocator) void {
        gpa.free(e.path);
        gpa.free(e.embedding);
        gpa.free(e.guide);
    }
};

pub const Mask8 = struct { width: u32, height: u32, pixels: []u8 };

/// Are the runtime and the model on this computer? Doesn't load them.
pub fn available(s: *const Subject) bool {
    for ([_][]const u8{ library_name, encoder_name, decoder_name }) |name| {
        var buf: [std.c.PATH_MAX]u8 = undefined;
        const path = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ s.models_dir, name }) catch return false;
        if (std.c.access(path, 4) != 0) return false;
    }
    return true;
}

// ---- ONNX Runtime's C API, by hand ----
//
// OrtApi is a table of function pointers that only ever grows at the end; these are the positions
// (onnxruntime_c_api.h of 1.31.1, scripts/subject-model.py's version).

const api_version = 31;
const Status = ?*anyopaque;
const element_float = 1;
const allocator_arena = 1;
const mem_type_default = 0;
const log_warning = 2;

const Ort = struct {
    table: [*]const ?*const anyopaque,
    env: *anyopaque,
    memory: *anyopaque,
    options: *anyopaque,

    fn f(o: Ort, comptime T: type, comptime index: usize) T {
        return @ptrCast(@alignCast(o.table[index].?));
    }

    fn check(o: Ort, status: Status) !void {
        const st = status orelse return;
        const message = o.f(*const fn (?*anyopaque) callconv(.c) [*:0]const u8, 2)(st);
        log.err("onnx: {s}", .{message});
        o.f(*const fn (?*anyopaque) callconv(.c) void, 93)(st);
        return error.Onnx;
    }

    fn session(o: Ort, path: [*:0]const u8) !*anyopaque {
        var out: ?*anyopaque = null;
        try o.check(o.f(*const fn (*anyopaque, [*:0]const u8, *anyopaque, *?*anyopaque) callconv(.c) Status, 7)(o.env, path, o.options, &out));
        return out.?;
    }

    fn releaseSession(o: Ort, session_: *anyopaque) void {
        o.f(*const fn (*anyopaque) callconv(.c) void, 95)(session_);
    }

    fn tensor(o: Ort, data: []f32, shape: []const i64) !*anyopaque {
        var out: ?*anyopaque = null;
        try o.check(o.f(*const fn (*anyopaque, *anyopaque, usize, [*]const i64, usize, c_int, *?*anyopaque) callconv(.c) Status, 49)(o.memory, data.ptr, data.len * @sizeOf(f32), shape.ptr, shape.len, element_float, &out));
        return out.?;
    }

    fn releaseValue(o: Ort, value: ?*anyopaque) void {
        if (value) |v| o.f(*const fn (*anyopaque) callconv(.c) void, 96)(v);
    }

    fn floats(o: Ort, value: *anyopaque) ![*]f32 {
        var out: ?*anyopaque = null;
        try o.check(o.f(*const fn (*anyopaque, *?*anyopaque) callconv(.c) Status, 51)(value, &out));
        return @ptrCast(@alignCast(out.?));
    }

    fn run(o: Ort, session_: *anyopaque, in_names: []const [*:0]const u8, inputs: []const *anyopaque, out_names: []const [*:0]const u8, outputs: []?*anyopaque) !void {
        try o.check(o.f(*const fn (*anyopaque, ?*anyopaque, [*]const [*:0]const u8, [*]const *anyopaque, usize, [*]const [*:0]const u8, usize, [*]?*anyopaque) callconv(.c) Status, 9)(session_, null, in_names.ptr, inputs.ptr, inputs.len, out_names.ptr, out_names.len, outputs.ptr));
    }
};

const ApiBase = extern struct {
    get_api: *const fn (u32) callconv(.c) ?[*]const ?*const anyopaque,
    get_version: *const fn () callconv(.c) [*:0]const u8,
};

fn modelPath(s: *const Subject, a: std.mem.Allocator, name: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ s.models_dir, name }, 0);
}

fn runtime(s: *Subject) !Ort {
    if (s.ort) |o| return o;
    if (!s.available()) return error.ModelMissing;
    const path = try s.modelPath(s.gpa, library_name);
    defer s.gpa.free(path);
    const lib = std.c.dlopen(path, .{ .NOW = true }) orelse {
        if (std.c.dlerror()) |e| log.err("{s}", .{e});
        return error.ModelMissing;
    };
    const get_base: *const fn () callconv(.c) *const ApiBase = @ptrCast(@alignCast(std.c.dlsym(lib, "OrtGetApiBase") orelse return error.ModelMissing));
    const table = get_base().get_api(api_version) orelse return error.ModelMissing;
    var o: Ort = .{ .table = table, .env = undefined, .memory = undefined, .options = undefined };
    var out: ?*anyopaque = null;
    try o.check(o.f(*const fn (c_int, [*:0]const u8, *?*anyopaque) callconv(.c) Status, 3)(log_warning, "doka", &out));
    o.env = out.?;
    try o.check(o.f(*const fn (c_int, c_int, *?*anyopaque) callconv(.c) Status, 69)(allocator_arena, mem_type_default, &out));
    o.memory = out.?;
    try o.check(o.f(*const fn (*?*anyopaque) callconv(.c) Status, 10)(&out));
    o.options = out.?;
    s.ort = o;
    return o;
}

// ---- The photo into the model ----

fn encoded(s: *Subject, path: [:0]const u8) !*Encoded {
    if (s.cached) |*c| if (std.mem.eql(u8, c.path, path)) return c;
    const o = try s.runtime();
    var lin = try core.decode.linear(s.gpa, path, mask_edge);
    defer lin.deinit(s.gpa);
    const w: usize = lin.width;
    const h: usize = lin.height;
    const guide = try s.gpa.alloc(f32, w * h);
    errdefer s.gpa.free(guide);
    const long: f64 = @floatFromInt(@max(w, h));
    const mw: usize = @intFromFloat(@round(@as(f64, @floatFromInt(w)) * model_edge / long));
    const mh: usize = @intFromFloat(@round(@as(f64, @floatFromInt(h)) * model_edge / long));
    const input = try s.gpa.alloc(f32, mw * mh * 3);
    defer s.gpa.free(input);
    // Encode once, then average down to the model's size.
    const display = try s.gpa.alloc(f32, w * h * 3);
    defer s.gpa.free(display);
    for (0..w * h) |i| {
        for (0..3) |k| {
            const half: f16 = @bitCast(lin.rgb[i * 3 + k]);
            display[i * 3 + k] = encode(@floatCast(half));
        }
        guide[i] = encode(0.2126 * decodeHalf(lin.rgb[i * 3]) + 0.7152 * decodeHalf(lin.rgb[i * 3 + 1]) + 0.0722 * decodeHalf(lin.rgb[i * 3 + 2]));
    }
    shrink(display, w, h, input, mw, mh);
    for (input) |*v| v.* *= 255;

    const encoder = try s.modelPath(s.gpa, encoder_name);
    defer s.gpa.free(encoder);
    // Only for a new photo, and it's the big one: not kept in memory between them.
    const session = try o.session(encoder);
    defer o.releaseSession(session);
    const image = try o.tensor(input, &.{ @intCast(mh), @intCast(mw), 3 });
    defer o.releaseValue(image);
    var outputs = [_]?*anyopaque{null};
    try o.run(session, &.{"input_image"}, &.{image}, &.{"image_embeddings"}, &outputs);
    defer o.releaseValue(outputs[0]);
    const embedding = try s.gpa.dupe(f32, (try o.floats(outputs[0].?))[0..embedding_len]);
    errdefer s.gpa.free(embedding);
    const owned = try s.gpa.dupeZ(u8, path);
    if (s.cached) |*c| c.deinit(s.gpa);
    s.cached = .{ .path = owned, .embedding = embedding, .guide = guide, .width = @intCast(w), .height = @intCast(h) };
    return &s.cached.?;
}

fn decodeHalf(v: u16) f32 {
    const half: f16 = @bitCast(v);
    return @max(0, @as(f32, @floatCast(half)));
}

fn encode(l: f32) f32 {
    if (l <= 0.0031308) return 12.92 * @max(0, l);
    return @min(1, 1.055 * std.math.pow(f32, l, 1.0 / 2.4) - 0.055);
}

// Averages w×h RGB into mw×mh RGB.
fn shrink(from: []const f32, w: usize, h: usize, to: []f32, mw: usize, mh: usize) void {
    for (0..mh) |y| {
        const y0 = y * h / mh;
        const y1 = @max(y0 + 1, (y + 1) * h / mh);
        for (0..mw) |x| {
            const x0 = x * w / mw;
            const x1 = @max(x0 + 1, (x + 1) * w / mw);
            var sum = [3]f32{ 0, 0, 0 };
            for (y0..y1) |sy| for (x0..x1) |sx| for (0..3) |k| {
                sum[k] += from[(sy * w + sx) * 3 + k];
            };
            const n: f32 = @floatFromInt((y1 - y0) * (x1 - x0));
            for (0..3) |k| to[(y * mw + x) * 3 + k] = sum[k] / n;
        }
    }
}

/// The subject at these points of the photo at `path`: x, y in 0..1 as decoded, and 1 for "this" or
/// 0 for "not this". Thread-safe, slow the first time per photo. `pixels` are for `gpa` to free.
pub fn segment(s: *Subject, path: [:0]const u8, points: []const [3]f32) !Mask8 {
    if (points.len == 0) return error.BadArguments;
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    defer memory.trim();
    const o = try s.runtime();
    const e = try s.encoded(path);
    if (s.decoder == null) {
        const name = try s.modelPath(s.gpa, decoder_name);
        defer s.gpa.free(name);
        s.decoder = try o.session(name);
    }
    const w: usize = e.width;
    const h: usize = e.height;
    const long: f32 = @floatFromInt(@max(w, h));
    const model_scale = @as(f32, model_edge) / long;
    // SAM's interface: pixels of the 1024 frame, with a last "no point" when there's no box.
    const coords = try s.gpa.alloc(f32, (points.len + 1) * 2);
    defer s.gpa.free(coords);
    const labels = try s.gpa.alloc(f32, points.len + 1);
    defer s.gpa.free(labels);
    for (points, 0..) |p, i| {
        coords[i * 2] = p[0] * @as(f32, @floatFromInt(w)) * model_scale;
        coords[i * 2 + 1] = p[1] * @as(f32, @floatFromInt(h)) * model_scale;
        labels[i] = if (p[2] > 0.5) 1 else 0;
    }
    coords[points.len * 2] = 0;
    coords[points.len * 2 + 1] = 0;
    labels[points.len] = -1;
    const no_mask = try s.gpa.alloc(f32, 256 * 256);
    defer s.gpa.free(no_mask);
    @memset(no_mask, 0);
    var has_mask = [1]f32{0};
    var size = [2]f32{ @floatFromInt(h), @floatFromInt(w) };
    const n: i64 = @intCast(points.len + 1);
    var inputs: [6]*anyopaque = undefined;
    var made: usize = 0;
    defer for (inputs[0..made]) |v| o.releaseValue(v);
    const tensors = [_]struct { data: []f32, shape: []const i64 }{
        .{ .data = e.embedding, .shape = &.{ 1, 256, 64, 64 } },
        .{ .data = coords, .shape = &.{ 1, n, 2 } },
        .{ .data = labels, .shape = &.{ 1, n } },
        .{ .data = no_mask, .shape = &.{ 1, 1, 256, 256 } },
        .{ .data = &has_mask, .shape = &.{1} },
        .{ .data = &size, .shape = &.{2} },
    };
    for (tensors) |t| {
        inputs[made] = try o.tensor(t.data, t.shape);
        made += 1;
    }
    var outputs = [_]?*anyopaque{ null, null };
    defer for (outputs) |v| o.releaseValue(v);
    try o.run(s.decoder.?, &.{ "image_embeddings", "point_coords", "point_labels", "mask_input", "has_mask_input", "orig_im_size" }, &inputs, &.{ "masks", "iou_predictions" }, &outputs);
    const masks = try o.floats(outputs[0].?);
    const scores = try o.floats(outputs[1].?);
    // One point is ambiguous, so the model answers three ways and rates them; several points are
    // what its first answer is for.
    var best: usize = 0;
    if (points.len == 1) {
        best = 1;
        for ([_]usize{ 2, 3 }) |i| {
            if (scores[i] > scores[best]) best = i;
        }
    }
    const logits = masks[best * w * h ..][0 .. w * h];
    const coarse = try s.gpa.alloc(f32, w * h);
    defer s.gpa.free(coarse);
    for (logits, coarse) |l, *c| c.* = 1 / (1 + @exp(-l));
    const pixels = try s.gpa.alloc(u8, w * h);
    errdefer s.gpa.free(pixels);
    const fine = try s.gpa.alloc(f32, w * h);
    defer s.gpa.free(fine);
    try refine(s.gpa, e.guide, coarse, w, h, @max(4, @max(w, h) / 256), 2e-3, fine);
    for (fine, pixels) |v, *out| out.* = @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
    return .{ .width = e.width, .height = e.height, .pixels = pixels };
}

/// A mask of `p` that follows the edges of `guide`: a guided filter (He, Sun, Tang), so a coarse
/// mask's outline settles on the photo's own edges, down to hair. Both w×h, 0..1.
pub fn refine(gpa: std.mem.Allocator, guide: []const f32, p: []const f32, w: usize, h: usize, radius: usize, eps: f32, out: []f32) !void {
    const n = w * h;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const scratch = try a.alloc(f32, n);
    const mean_i = try a.alloc(f32, n);
    const mean_p = try a.alloc(f32, n);
    const corr_i = try a.alloc(f32, n);
    const corr_ip = try a.alloc(f32, n);
    const product = try a.alloc(f32, n);
    box(guide, w, h, radius, scratch, mean_i);
    box(p, w, h, radius, scratch, mean_p);
    for (guide, product) |g, *v| v.* = g * g;
    box(product, w, h, radius, scratch, corr_i);
    for (guide, p, product) |g, m, *v| v.* = g * m;
    box(product, w, h, radius, scratch, corr_ip);
    const coef_a = try a.alloc(f32, n);
    const coef_b = try a.alloc(f32, n);
    for (0..n) |i| {
        const variance = corr_i[i] - mean_i[i] * mean_i[i];
        const covariance = corr_ip[i] - mean_i[i] * mean_p[i];
        coef_a[i] = covariance / (variance + eps);
        coef_b[i] = mean_p[i] - coef_a[i] * mean_i[i];
    }
    box(coef_a, w, h, radius, scratch, mean_i);
    box(coef_b, w, h, radius, scratch, mean_p);
    for (0..n) |i| out[i] = std.math.clamp(mean_i[i] * guide[i] + mean_p[i], 0, 1);
}

// A box blur in time that doesn't depend on the radius: across, then down.
fn box(from: []const f32, w: usize, h: usize, radius: usize, scratch: []f32, to: []f32) void {
    for (0..h) |y| boxLine(from[y * w ..], 1, w, radius, scratch[y * w ..], 1);
    for (0..w) |x| boxLine(scratch[x..], w, h, radius, to[x..], w);
}

fn boxLine(from: []const f32, stride: usize, count: usize, radius: usize, to: []f32, out_stride: usize) void {
    var sum: f64 = 0;
    var inside: f64 = 0;
    var right: usize = 0;
    for (0..count) |i| {
        const end = @min(count, i + radius + 1);
        while (right < end) : (right += 1) {
            sum += from[right * stride];
            inside += 1;
        }
        if (i > radius) {
            sum -= from[(i - radius - 1) * stride];
            inside -= 1;
        }
        to[i * out_stride] = @floatCast(sum / inside);
    }
}

// ---- Work off the main loop ----

pub const Request = struct {
    // The photo, and the folder it's in.
    path: []const u8,
    root: []const u8,
    rel: []const u8,
    points: []const [3]f32,
    ctx: *anyopaque,
    // The asker's own number, handed back.
    tag: u64 = 0,
    // On the main loop. `file` is the saved mask's name in `.photo-editor/masks/`; null on failure,
    // with `failure` saying why. `points` and `rel` are the request's.
    done: *const fn (ctx: *anyopaque, tag: u64, rel: []const u8, points: []const [3]f32, file: ?[]const u8, failure: ?anyerror) void,
};

const Job = struct {
    task: Pool.Task = .{ .run = run, .done = done },
    subject: *Subject,
    arena: std.heap.ArenaAllocator,
    request: Request,
    path: [:0]const u8,
    file: [24:0]u8 = undefined,
    failure: ?anyerror = null,

    fn run(task: *Pool.Task) void {
        const job: *Job = @alignCast(@fieldParentPtr("task", task));
        job.work() catch |err| {
            job.failure = err;
        };
    }

    fn work(job: *Job) !void {
        const s = job.subject;
        const mask = try s.segment(job.path, job.request.points);
        defer s.gpa.free(mask.pixels);
        const a = job.arena.allocator();
        // The same request makes the same file, so its name comes from what made it.
        var h = std.hash.Wyhash.init(0);
        h.update(job.request.rel);
        h.update(std.mem.sliceAsBytes(job.request.points));
        const name = try std.fmt.bufPrintZ(&job.file, "{x:0>16}.png", .{h.final()});
        const root = try std.Io.Dir.cwd().openDir(s.io, job.request.root, .{});
        defer root.close(s.io);
        try core.store.saveMask(s.io, a, root, name, mask.pixels, mask.width, mask.height);
    }

    fn done(task: *Pool.Task) void {
        const job: *Job = @alignCast(@fieldParentPtr("task", task));
        defer {
            var arena = job.arena;
            arena.deinit();
        }
        const r = job.request;
        r.done(r.ctx, r.tag, r.rel, r.points, if (job.failure == null) std.mem.sliceTo(&job.file, 0) else null, job.failure);
    }
};

/// Finds a subject off the main loop; `request.done` answers. Everything in the request is copied.
pub fn ask(s: *Subject, request: Request) !void {
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const job = try a.create(Job);
    var r = request;
    r.root = try a.dupe(u8, request.root);
    r.rel = try a.dupe(u8, request.rel);
    r.points = try a.dupe([3]f32, request.points);
    const path = try a.dupeZ(u8, request.path);
    r.path = path;
    job.* = .{ .subject = s, .arena = arena, .request = r, .path = path };
    s.pool.submit(&job.task, .urgent);
}

const testing = std.testing;

test "refining a blurry mask settles it on the photo's edge" {
    const w = 64;
    const h = 8;
    var guide: [w * h]f32 = undefined;
    var coarse: [w * h]f32 = undefined;
    for (0..h) |y| for (0..w) |x| {
        // The photo's edge is at 32; the mask's blurry outline is a ramp over 16 pixels around it.
        guide[y * w + x] = if (x < 32) 0.2 else 0.8;
        coarse[y * w + x] = std.math.clamp((@as(f32, @floatFromInt(x)) - 24) / 16, 0, 1);
    };
    var fine: [w * h]f32 = undefined;
    try refine(testing.allocator, &guide, &coarse, w, h, 4, 1e-4, &fine);
    const step = fine[4 * w + 32] - fine[4 * w + 31];
    const was = coarse[4 * w + 32] - coarse[4 * w + 31];
    try testing.expect(step > was * 4);
    try testing.expect(fine[4 * w + 2] < 0.05 and fine[4 * w + 60] > 0.95);
}

test "a box blur averages what's inside it, and fewer at the edges" {
    const from = [_]f32{ 3, 0, 0, 3 };
    var scratch: [4]f32 = undefined;
    var to: [4]f32 = undefined;
    box(&from, 4, 1, 1, &scratch, &to);
    try testing.expectApproxEqAbs(1.5, to[0], 1e-6);
    try testing.expectApproxEqAbs(1, to[1], 1e-6);
    try testing.expectApproxEqAbs(1, to[2], 1e-6);
    try testing.expectApproxEqAbs(1.5, to[3], 1e-6);
}
