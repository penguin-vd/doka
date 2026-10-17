//! Exports, one photo after another (SPEC.md, Image pipeline, Output): the page renders the photo
//! at full size with the same shaders as the preview and sends its pixels here in strips
//! (POST app://ui/export/<id>?y=&rows=&width=&height=); `done` encodes them with libvips and the
//! original's metadata (photo-core's encode), on a worker thread.
const std = @import("std");
const Io = std.Io;
const core = @import("photo-core");

const App = @import("app.zig");
const Window = @import("window.zig");
const Pool = @import("jobs.zig");
const Settings = @import("settings.zig");
const Mcp = @import("mcp.zig");
const tools = @import("tools.zig");
const Recipe = core.Recipe;

const Exporter = @This();

const log = std.log.scoped(.export_);

// A whole 16-bit photo of 100 megapixels, at most.
const max_pixels = 100_000_000;

app: *App,
batch: ?Batch = null,
next_id: u32 = 1,

/// Claude's extras for one export: a file name, a crop that isn't kept in the recipe.
pub const Extras = struct {
    // Instead of the photo's own name; with several photos, before each one's name.
    name: []const u8 = "",
    // A crop.aspect / crop.focus patch, fitted per photo (tools.fitCropPatch).
    crop: ?std.json.Value = null,
};

pub const Report = union(enum) {
    claude: *Mcp.Call,
    page,
};

pub const Result = struct {
    rel: []const u8,
    path: []const u8 = "",
    @"error": []const u8 = "",
    ms: u64 = 0,
};

const Batch = struct {
    arena: std.heap.ArenaAllocator,
    rels: []const []const u8,
    options: Settings.Export,
    folder: []const u8,
    report: Report,
    index: usize = 0,
    results: std.ArrayList(Result) = .empty,
    job: ?*Job = null,
    started: i96 = 0,
    extras: Extras = .{},
};

const Job = struct {
    id: u32,
    rel: []const u8,
    width: u32 = 0,
    height: u32 = 0,
    // RGB, 8 or 16 bits per channel, rows from the top.
    pixels: []u8 = &.{},
    rows_done: u32 = 0,
    started: i96,
};

pub fn busy(e: *const Exporter) bool {
    return e.batch != null;
}

/// Starts exporting `rels`; `report` hears when all are written.
pub fn start(e: *Exporter, rels: []const []const u8, options: Settings.Export, report: Report, extras: Extras) !void {
    if (e.batch != null) return error.ExportBusy;
    if (rels.len == 0) return error.NothingToExport;
    var arena: std.heap.ArenaAllocator = .init(e.app.gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const folder = if (options.folder.len > 0) try a.dupe(u8, options.folder) else try Settings.defaultExportFolder(a, e.app.env);
    try Io.Dir.cwd().createDirPath(e.app.io, folder);
    var copy = options;
    copy.folder = folder;
    copy.suffix = try a.dupe(u8, options.suffix);
    const owned = try a.alloc([]const u8, rels.len);
    for (rels, owned) |r, *o| o.* = try a.dupe(u8, r);
    var kept: Extras = .{ .name = try a.dupe(u8, extras.name) };
    if (extras.crop) |c| kept.crop = try std.json.parseFromSliceLeaky(std.json.Value, a, try std.json.Stringify.valueAlloc(a, c, .{}), .{});
    e.batch = .{ .arena = arena, .rels = owned, .options = copy, .folder = folder, .report = report, .started = Io.Timestamp.now(e.app.io, .awake).nanoseconds, .extras = kept };
    e.next();
}

fn next(e: *Exporter) void {
    const b = &(e.batch orelse return);
    if (b.index >= b.rels.len) return e.finish();
    const a = b.arena.allocator();
    const rel = b.rels[b.index];
    const f = &(e.app.folder orelse return e.fail("the folder was closed"));
    const i = f.index(rel) orelse return e.fail("no such photo");
    const s = e.app.session(i) catch return e.fail("its recipe didn't load");
    const job = a.create(Job) catch return e.fail("out of memory");
    job.* = .{ .id = e.next_id, .rel = rel, .started = Io.Timestamp.now(e.app.io, .awake).nanoseconds };
    e.next_id +%= 1;
    b.job = job;
    var recipe_json: []const u8 = s.json;
    if (b.extras.crop) |crop| {
        // This export's own crop; the photo's recipe stays as it is.
        const r = s.recipe(a) catch return e.fail("its recipe didn't load");
        var patch = crop.object.clone(a) catch return e.fail("out of memory");
        tools.fitCropPatch(e.app, a, i, r.crop, &patch) catch return e.fail("that crop doesn't fit");
        var wrapper: std.json.ObjectMap = .empty;
        wrapper.put(a, "crop", .{ .object = patch }) catch return e.fail("out of memory");
        const cropped = Recipe.apply(a, r, .{ .object = wrapper }) catch return e.fail("that crop doesn't fit");
        recipe_json = cropped.writeAlloc(a) catch return e.fail("out of memory");
    }
    var out: Io.Writer.Allocating = .init(a);
    out.writer.print("{{\"id\":{d},\"rel\":{f},\"bits\":{d},\"p3\":{},\"index\":{d},\"total\":{d},\"recipe\":{s}}}", .{
        job.id, std.json.fmt(rel, .{}), b.options.format.bits(), b.options.space == .p3, b.index, b.rels.len, recipe_json,
    }) catch return e.fail("out of memory");
    e.app.emit("export", out.written());
}

// This photo failed; on to the next.
fn fail(e: *Exporter, why: []const u8) void {
    const b = &(e.batch orelse return);
    const a = b.arena.allocator();
    const rel = if (b.index < b.rels.len) b.rels[b.index] else "";
    log.err("export {s}: {s}", .{ rel, why });
    b.results.append(a, .{ .rel = rel, .@"error" = a.dupe(u8, why) catch "" }) catch {};
    e.freeJob();
    b.index += 1;
    e.next();
}

fn freeJob(e: *Exporter) void {
    const b = &(e.batch orelse return);
    if (b.job) |job| {
        if (job.pixels.len > 0) e.app.gpa.free(job.pixels);
        job.pixels = &.{};
    }
    b.job = null;
    // A full-size photo's pixels (up to hundreds of MB) go back to the system now.
    _ = @import("images.zig").malloc_trim(0);
}

fn finish(e: *Exporter) void {
    var b = e.batch.?;
    e.batch = null;
    defer b.arena.deinit();
    const a = b.arena.allocator();
    const total_ms: u64 = @intCast(@divFloor(Io.Timestamp.now(e.app.io, .awake).nanoseconds - b.started, std.time.ns_per_ms));
    var out: Io.Writer.Allocating = .init(a);
    out.writer.print("{f}", .{std.json.fmt(.{ .folder = b.folder, .results = b.results.items, .ms = total_ms }, .{})}) catch {};
    switch (b.report) {
        .page => e.app.emit("exportDone", out.written()),
        .claude => |call| {
            var text: Io.Writer.Allocating = .init(a);
            for (b.results.items) |r| {
                if (r.@"error".len > 0) text.writer.print("{s}: failed, {s}\n", .{ r.rel, r.@"error" }) catch {} else text.writer.print("{s} → {s} ({d} ms)\n", .{ r.rel, r.path, r.ms }) catch {};
            }
            text.writer.writeAll("Metadata (camera, lens, exposure, date, colour profile) kept.") catch {};
            const failed = for (b.results.items) |r| {
                if (r.@"error".len > 0) break true;
            } else false;
            call.finish(Mcp.textResult(e.app.gpa, text.written(), failed) catch return);
            // The page shows exports too, whoever started them.
            e.app.emit("exportDone", out.written());
        },
    }
}

/// Serves `export/<id>…`; false when the path isn't one.
pub fn handle(e: *Exporter, request: *Window.Request, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "export/")) return false;
    // On an error the page gives up on the photo with `fail`.
    e.serve(request, path["export/".len..]) catch |err| {
        log.err("export request {s}: {t}", .{ path, err });
        Window.fail(request, 500, @errorName(err));
    };
    return true;
}

fn serve(e: *Exporter, request: *Window.Request, rest: []const u8) !void {
    const b = &(e.batch orelse return error.NoExport);
    const job = b.job orelse return error.NoExport;
    var parts = std.mem.splitScalar(u8, rest, '/');
    const id = std.fmt.parseInt(u32, parts.next() orelse "", 10) catch return error.BadRequest;
    if (id != job.id) return error.StaleExport;
    const action = parts.next() orelse "strip";
    const gpa = e.app.gpa;

    if (std.mem.eql(u8, action, "strip")) {
        const q = struct {
            fn int(r: *Window.Request, k: []const u8) !u32 {
                return std.fmt.parseInt(u32, Window.query(r, k) orelse return error.BadRequest, 10);
            }
        };
        const width = try q.int(request, "width");
        const height = try q.int(request, "height");
        const y = try q.int(request, "y");
        const rows = try q.int(request, "rows");
        const bytes_per: usize = if (b.options.format.bits() == 8) 3 else 6;
        if (job.pixels.len == 0) {
            if (@as(u64, width) * height > max_pixels or width == 0 or height == 0) return error.TooLarge;
            job.width = width;
            job.height = height;
            job.pixels = try gpa.alloc(u8, @as(usize, width) * height * bytes_per);
        }
        if (width != job.width or height != job.height or y + rows > height) return error.BadRequest;
        const row_bytes = @as(usize, width) * bytes_per;
        const body = try Window.body(request, gpa, row_bytes * rows);
        defer gpa.free(body);
        if (body.len != row_bytes * rows) return error.BadRequest;
        @memcpy(job.pixels[y * row_bytes ..][0..body.len], body);
        job.rows_done += rows;
        Window.respond(request, "{}", "application/json");
        return;
    }
    if (std.mem.eql(u8, action, "fail")) {
        const why = Window.body(request, gpa, 4096) catch try gpa.dupe(u8, "the page couldn't render it");
        defer gpa.free(why);
        Window.respond(request, "{}", "application/json");
        e.fail(why);
        return;
    }
    if (std.mem.eql(u8, action, "done")) {
        if (job.rows_done < job.height) return error.MissingRows;
        const task = try gpa.create(Encode);
        task.* = .{
            .exporter = e,
            .request = request,
            .io = e.app.io,
            .gpa = gpa,
            .source = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ e.app.folder.?.path, job.rel }, 0),
            .out = try outputPath(gpa, e.app.io, b.folder, try stemFor(b.arena.allocator(), job.rel, b.extras.name, b.rels.len), b.options.suffix, b.options.format.extension()),
            .options = .{
                .format = b.options.format,
                .quality = b.options.quality,
                .long_edge = b.options.long_edge,
                .keep_metadata = b.options.keep_metadata,
                .keep_gps = b.options.keep_gps,
                .space = b.options.space,
            },
            .pixels = .{ .width = job.width, .height = job.height, .data = if (b.options.format.bits() == 8)
                .{ .u8 = job.pixels }
            else
                .{ .u16 = @alignCast(std.mem.bytesAsSlice(u16, job.pixels)) } },
        };
        Window.hold(request);
        e.app.pool.submit(&task.task, .urgent);
        return;
    }
    return error.BadRequest;
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
    request: *Window.Request,
    io: Io,
    gpa: std.mem.Allocator,
    source: [:0]u8,
    out: [:0]u8,
    options: core.encode.Options,
    pixels: core.encode.Pixels,
    err: ?anyerror = null,

    fn run(task: *Pool.Task) void {
        const t: *Encode = @fieldParentPtr("task", task);
        core.encode.save(t.io, t.gpa, t.source, t.pixels, t.options, t.out) catch |err| {
            t.err = err;
        };
    }

    fn done(task: *Pool.Task) void {
        const t: *Encode = @fieldParentPtr("task", task);
        const e = t.exporter;
        defer {
            t.gpa.free(t.source);
            t.gpa.free(t.out);
            t.gpa.destroy(t);
        }
        if (t.err) |err| {
            Window.fail(t.request, 500, @errorName(err));
            Window.release(t.request);
            return e.fail(@errorName(err));
        }
        Window.respond(t.request, "{}", "application/json");
        Window.release(t.request);
        const b = &(e.batch orelse return);
        const a = b.arena.allocator();
        const job = b.job.?;
        const ms: u64 = @intCast(@divFloor(Io.Timestamp.now(t.io, .awake).nanoseconds - job.started, std.time.ns_per_ms));
        log.info("{s} → {s} in {d} ms", .{ job.rel, t.out, ms });
        b.results.append(a, .{ .rel = job.rel, .path = a.dupe(u8, t.out) catch "", .ms = ms }) catch {};
        e.freeJob();
        b.index += 1;
        e.next();
    }
};
