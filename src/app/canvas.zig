//! The photo in the middle: a GL area, the pipeline, zoom and move. It draws only when something
//! changed. Past the preview's own pixels the full-size photo takes over, a few rows per frame.
const std = @import("std");
const core = @import("photo-core");
const gtk = @import("gtk.zig");
const gl = @import("gl.zig");
const Pipeline = @import("pipeline.zig");
const Looks = @import("looks.zig");
const Photos = @import("photos.zig");
const cropping = @import("crop.zig");
const Recipe = core.Recipe;

const Canvas = @This();

const log = std.log.scoped(.canvas);

pub const preview_edge = 2048;
const pad = 20;
// How fast the zoom catches up with the wheel, ms.
const glide_ms = 55.0;
// About 8 MB of a full-size photo per frame, well under a frame's time.
const rows_per_frame = 256;

gpa: std.mem.Allocator,
photos: *Photos,
looks: *Looks,
area: *anyopaque = undefined,
pipeline: ?Pipeline = null,
failed: bool = false,
// The photo in the pipeline, and its recipe. Until a new photo's here the old frame stays: never
// the old photo with the new crop.
rel: ?[]u8 = null,
recipe: Recipe = .{},
recipe_arena: std.heap.ArenaAllocator = undefined,
// Waiting to go to the GPU, the next time there's a GL context.
pending: ?struct { rel: []u8, json: []u8 } = null,
full_width: f64 = 0,
full: enum { no, asked, uploading, here } = .no,
full_texture: c_uint = 0,
full_row: c_int = 0,
zoom: f64 = 1,
goal: f64 = 1,
centre: [2]f64 = .{ 0.5, 0.5 },
cursor: [2]f64 = .{ 0, 0 },
drag_centre: [2]f64 = .{ 0.5, 0.5 },
ticking: c_uint = 0,
last_tick: i64 = 0,
overlay: *anyopaque = undefined,
widget: *anyopaque = undefined,
// The Crop tab: the whole photo, with the crop drawn over it.
crop_mode: bool = false,
// Holding \: the whole original.
before: bool = false,
// The line to drag across the photo.
compare: bool = false,
split: f64 = 0.5,
drag: Spot = .none,
dragging: bool = false,
// The pointer's look on the photo, so it's only told when it changes.
cursor_name: ?[*:0]const u8 = null,
drag_rect: cropping.Rect = .{ 0, 0, 1, 1 },
// A crop changed by dragging: patch json, gesture is the window's.
on_crop: ?*const fn (rect: cropping.Rect, gesture: u64) void = null,
crop_gesture: u64 = 0,
aspect_ratio: ?f64 = null,
// The mask being edited, its handles on the photo; and the one painted red.
active_mask: ?usize = null,
show_mask: ?usize = null,
// A mask moved by its handles: patch json, gesture is the window's.
on_mask: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, index: usize, place: Recipe.Mask.Place, gesture: u64) void } = null,
// Clicks on the photo pick a subject's points: 0..1 of the photo as decoded; `keep` false with Shift.
picking: bool = false,
on_pick: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, at: [2]f32, keep: bool) void } = null,
pick_keep: bool = true,
mask_handle: Handle = .from,
mask_start: Recipe.Mask.Place = undefined,
mask_gesture: u64 = 0,
drag_at: [2]f64 = .{ 0, 0 },
// Told after each drawn frame, and when a new photo is on the GPU.
on_drawn: ?*const fn () void = null,
on_installed: ?*const fn () void = null,
on_failed: ?*const fn () void = null,
zoom_label: ?*anyopaque = null,

const Layout = struct { box: [4]f64, view: [4]f64, image: [2]f64 };

const Handle = enum { from, to, middle, centre, across, down };

// What a press at some place on the photo takes hold of.
pub const Spot = enum { pan, split, crop_move, nw, ne, sw, se, none, mask, pick };

pub fn create(c: *Canvas) *anyopaque {
    c.recipe_arena = .init(c.gpa);
    const area = gtk.gtk_gl_area_new();
    c.area = area;
    gtk.gtk_widget_set_hexpand(area, 1);
    gtk.gtk_widget_set_vexpand(area, 1);
    connect(area, "realize", &onRealize, c);
    connect(area, "render", &onRender, c);
    const scroll = gtk.gtk_event_controller_scroll_new(gtk.scroll_both);
    connect(scroll, "scroll", &onScroll, c);
    gtk.gtk_widget_add_controller(area, scroll);
    const motion = gtk.gtk_event_controller_motion_new();
    connect(motion, "motion", &onMotion, c);
    gtk.gtk_widget_add_controller(area, motion);
    const drag = gtk.gtk_gesture_drag_new();
    connect(drag, "drag-begin", &onDragBegin, c);
    connect(drag, "drag-update", &onDragUpdate, c);
    connect(drag, "drag-end", &onDragEnd, c);
    gtk.gtk_widget_add_controller(area, drag);
    const click = gtk.gtk_gesture_click_new();
    connect(click, "pressed", &onPressed, c);
    gtk.gtk_widget_add_controller(area, click);
    // Clicking the photo takes the keys back from a slider.
    gtk.gtk_widget_set_focusable(area, 1);
    const overlay = gtk.gtk_overlay_new();
    gtk.gtk_overlay_set_child(overlay, area);
    c.overlay = gtk.gtk_drawing_area_new();
    gtk.gtk_widget_set_can_target(c.overlay, 0);
    gtk.gtk_drawing_area_set_draw_func(c.overlay, drawOverlay, c, null);
    gtk.gtk_overlay_add_overlay(overlay, c.overlay);
    gtk.gtk_widget_set_hexpand(overlay, 1);
    gtk.gtk_widget_set_vexpand(overlay, 1);
    c.widget = overlay;
    return overlay;
}

/// Something about how the photo is shown changed.
pub fn redraw(c: *Canvas) void {
    gtk.gtk_gl_area_queue_render(c.area);
    gtk.gtk_widget_queue_draw(c.overlay);
}

pub fn setPicking(c: *Canvas, on: bool) void {
    c.picking = on;
    c.updateCursor();
}

pub fn setCropMode(c: *Canvas, on: bool) void {
    c.crop_mode = on;
    if (on) {
        c.zoom = 1;
        c.goal = 1;
    }
    c.updateCursor();
    c.redraw();
}

fn shownRecipe(c: *const Canvas) Recipe {
    if (!c.before) return c.recipe;
    return .{ .crop = c.recipe.crop };
}

/// With the window's GL context current; false when there isn't one yet.
pub fn makeCurrent(c: *Canvas) bool {
    if (c.pipeline == null) return false;
    gtk.gtk_gl_area_make_current(c.area);
    return gtk.gtk_gl_area_get_error(c.area) == null;
}

fn zoomable(c: *const Canvas) bool {
    return !c.crop_mode;
}

fn connect(object: *anyopaque, signal: [*:0]const u8, handler: anytype, data: ?*anyopaque) void {
    _ = gtk.g_signal_connect_data(object, signal, @ptrCast(handler), data, null, 0);
}

/// A decoded photo is ready: it goes on screen at the next draw, with these edits.
pub fn show(c: *Canvas, rel: []const u8, recipe_json: []const u8) void {
    c.dropPending();
    const r = c.gpa.dupe(u8, rel) catch return;
    const j = c.gpa.dupe(u8, recipe_json) catch {
        c.gpa.free(r);
        return;
    };
    c.pending = .{ .rel = r, .json = j };
    gtk.gtk_gl_area_queue_render(c.area);
}

fn dropPending(c: *Canvas) void {
    if (c.pending) |p| {
        c.gpa.free(p.rel);
        c.gpa.free(p.json);
        c.pending = null;
    }
}

/// Shader files changed: they compile again when next used. With the GL context current.
pub fn reloadShaders(c: *Canvas) void {
    c.pipeline.?.dropShaders();
}

/// The look in the pipeline isn't the recipe's any more (the look previews, a file on disk).
pub fn lookChanged(c: *Canvas) void {
    c.looks.forget();
    c.redraw();
}

/// The photo on screen's edits changed.
pub fn edited(c: *Canvas, recipe_json: []const u8) void {
    c.setRecipe(recipe_json);
    gtk.gtk_gl_area_queue_render(c.area);
}

pub fn showing(c: *const Canvas, rel: []const u8) bool {
    return if (c.rel) |r| std.mem.eql(u8, r, rel) else false;
}

fn setRecipe(c: *Canvas, json: []const u8) void {
    _ = c.recipe_arena.reset(.retain_capacity);
    c.recipe = Recipe.parse(c.recipe_arena.allocator(), json) catch |err| blk: {
        log.err("recipe: {t}", .{err});
        break :blk .{};
    };
}

fn photoSize(c: *const Canvas, r: Recipe) [2]f64 {
    const size = c.pipeline.?.outputSize(r, c.crop_mode);
    return .{ @floatFromInt(size[0]), @floatFromInt(size[1]) };
}

fn layout(c: *const Canvas, zoom: f64, centre: [2]f64) Layout {
    const w: f64 = @floatFromInt(gtk.gtk_widget_get_width(c.area));
    const h: f64 = @floatFromInt(gtk.gtk_widget_get_height(c.area));
    const photo = c.photoSize(c.recipe);
    const room = [2]f64{ @max(1, w - 2 * pad), @max(1, h - 2 * pad) };
    const scale = @min(room[0] / photo[0], room[1] / photo[1]) * zoom;
    const image = [2]f64{ photo[0] * scale, photo[1] * scale };
    const bw = @max(1, @floor(@min(room[0], image[0])));
    const bh = @max(1, @floor(@min(room[1], image[1])));
    const vw = @min(1, bw / image[0]);
    const vh = @min(1, bh / image[1]);
    const x = std.math.clamp(centre[0] - vw / 2, 0, 1 - vw);
    const y = std.math.clamp(centre[1] - vh / 2, 0, 1 - vh);
    return .{ .box = .{ (w - bw) / 2, (h - bh) / 2, bw, bh }, .view = .{ x, y, vw, vh }, .image = image };
}

fn ready(c: *const Canvas) bool {
    return c.pipeline != null and c.rel != null;
}

fn maxZoom(c: *const Canvas) f64 {
    const fit = c.layout(1, .{ 0.5, 0.5 });
    const share: f64 = if (c.crop_mode) 1 else c.recipe.crop.rect[2];
    return @max(2, c.full_width * share / fit.image[0] * 4);
}

// The point under the cursor stays under it.
fn setZoom(c: *Canvas, zoom: f64) void {
    const z = std.math.clamp(zoom, 1, c.maxZoom());
    const before = c.layout(c.zoom, c.centre);
    const u = std.math.clamp((c.cursor[0] - before.box[0]) / before.box[2], 0, 1);
    const v = std.math.clamp((c.cursor[1] - before.box[1]) / before.box[3], 0, 1);
    const px = before.view[0] + u * before.view[2];
    const py = before.view[1] + v * before.view[3];
    const after = c.layout(z, .{ px, py });
    const au = (c.cursor[0] - after.box[0]) / after.box[2];
    const av = (c.cursor[1] - after.box[1]) / after.box[3];
    c.centre = .{ px - au * after.view[2] + after.view[2] / 2, py - av * after.view[3] + after.view[3] / 2 };
    c.zoom = z;
}

fn startTicking(c: *Canvas) void {
    if (c.ticking != 0) return;
    c.last_tick = gtk.g_get_monotonic_time();
    c.ticking = gtk.gtk_widget_add_tick_callback(c.area, onTick, c, null);
}

// Runs once per frame while something moves on its own, then stops: an idle window draws nothing.
fn onTick(_: *anyopaque, _: *anyopaque, ctx: ?*anyopaque) callconv(.c) c_int {
    const c: *Canvas = @ptrCast(@alignCast(ctx));
    const now = gtk.g_get_monotonic_time();
    const dt_ms = @as(f64, @floatFromInt(now - c.last_tick)) / 1000;
    c.last_tick = now;
    var busy = false;
    if (c.ready() and c.zoom != c.goal) {
        const k = 1 - @exp(-dt_ms / glide_ms);
        var next = c.zoom * std.math.pow(f64, c.goal / c.zoom, k);
        if (@abs(@log(c.goal / next)) < 0.002) next = c.goal;
        c.setZoom(next);
        if (next == c.goal) c.goal = c.zoom;
        busy = true;
        gtk.gtk_gl_area_queue_render(c.area);
    } else if (c.ready()) {
        c.wantFull();
    }
    if (c.full == .uploading) {
        busy = true;
        gtk.gtk_gl_area_queue_render(c.area);
    }
    if (busy) return gtk.continue_;
    c.ticking = 0;
    c.updateCursor();
    return gtk.remove;
}

// Zoomed past the preview's own pixels: the full-size photo takes its place, once.
fn wantFull(c: *Canvas) void {
    if (c.full != .no or c.zoom <= 1.001) return;
    const l = c.layout(c.zoom, c.centre);
    const scale: f64 = @floatFromInt(gtk.gtk_widget_get_scale_factor(c.area));
    if (l.box[2] * scale <= l.view[2] * c.photoSize(c.recipe)[0] * 1.05) return;
    c.full = .asked;
    c.photos.request(c.rel.?, 0, .urgent);
}

/// The full-size photo finished decoding.
pub fn fullDecoded(c: *Canvas, rel: []const u8, ok: bool) void {
    if (!c.showing(rel) or c.full != .asked) return;
    if (!ok) {
        c.full = .no;
        return;
    }
    c.full = .uploading;
    c.full_row = 0;
    c.startTicking();
}

fn onRealize(area: *anyopaque, ctx: ?*anyopaque) callconv(.c) void {
    const c: *Canvas = @ptrCast(@alignCast(ctx));
    gtk.gtk_gl_area_make_current(area);
    if (gtk.gtk_gl_area_get_error(area)) |e| {
        // GTK writes this one on the area itself.
        log.err("no OpenGL: {s}", .{e.message});
        c.failed = true;
        return;
    }
    const es = gtk.gdk_gl_context_get_use_es(gtk.gtk_gl_area_get_context(area).?) != 0;
    c.pipeline = Pipeline.init(c.gpa, es) catch |err| {
        log.err("pipeline: {t}: {s}", .{ err, Pipeline.last_error });
        c.fail();
        return;
    };
}

fn fail(c: *Canvas) void {
    c.failed = true;
    if (c.on_failed) |f| f();
}

// The waiting photo goes to the GPU.
fn installPending(c: *Canvas) void {
    const p = c.pending orelse return;
    c.pending = null;
    defer c.gpa.free(p.json);
    const entry = c.photos.lookup(p.rel, preview_edge) orelse {
        c.gpa.free(p.rel);
        return;
    };
    const lin = &entry.linear;
    c.pipeline.?.setSource(@intCast(lin.width), @intCast(lin.height), lin.rgb.ptr) catch |err| log.err("photo: {t}", .{err});
    if (c.rel) |r| c.gpa.free(r);
    c.rel = p.rel;
    c.full_width = @floatFromInt(lin.full_width);
    c.setRecipe(p.json);
    c.looks.prepareSoon(&c.pipeline.?, c.recipe);
    if (c.on_installed) |f| f();
    c.zoom = 1;
    c.goal = 1;
    c.centre = .{ 0.5, 0.5 };
    if (c.full_texture != 0) gl.glDeleteTextures(1, &c.full_texture);
    c.full_texture = 0;
    c.full = .no;
}

fn uploadFull(c: *Canvas) void {
    const entry = c.photos.lookup(c.rel.?, 0) orelse {
        c.full = .no;
        return;
    };
    const lin = &entry.linear;
    const width: c_int = @intCast(lin.width);
    const height: c_int = @intCast(lin.height);
    if (c.full_texture == 0) c.full_texture = Pipeline.newSource(width, height);
    const rows = @min(rows_per_frame, height - c.full_row);
    Pipeline.uploadRows(c.full_texture, width, c.full_row, rows, lin.rgb.ptr);
    c.full_row += rows;
    if (c.full_row >= height) {
        c.pipeline.?.installSource(c.full_texture, width, height) catch |err| log.err("full size: {t}", .{err});
        c.full_texture = 0;
        c.full = .here;
    }
}

fn onRender(area: *anyopaque, _: *anyopaque, ctx: ?*anyopaque) callconv(.c) c_int {
    const c: *Canvas = @ptrCast(@alignCast(ctx));
    if (c.pipeline == null) return 1;
    // GTK draws into its own framebuffer, not number 0.
    var to: c_int = 0;
    gl.glGetIntegerv(gl.DRAW_FRAMEBUFFER_BINDING, &to);
    c.installPending();
    const scale = gtk.gtk_widget_get_scale_factor(area);
    const whole_w = gtk.gtk_widget_get_width(area) * scale;
    const whole_h = gtk.gtk_widget_get_height(area) * scale;
    gl.glBindFramebuffer(gl.FRAMEBUFFER, @intCast(to));
    gl.glDisable(gl.SCISSOR_TEST);
    gl.glViewport(0, 0, whole_w, whole_h);
    gl.glClearColor(0.102, 0.102, 0.102, 1);
    gl.glClear(gl.COLOR_BUFFER_BIT);
    if (c.rel == null) return 1;
    if (c.full == .uploading) c.uploadFull();
    c.looks.prepareSoon(&c.pipeline.?, c.recipe);

    const l = c.layout(c.zoom, c.centre);
    c.centre = .{ l.view[0] + l.view[2] / 2, l.view[1] + l.view[3] / 2 };
    const f: f64 = @floatFromInt(scale);
    const bw: c_int = @intFromFloat(l.box[2] * f);
    const bh: c_int = @intFromFloat(l.box[3] * f);
    var out: Pipeline.Output = .{
        .fbo = @intCast(to),
        .flip_y = true,
        .x = @intFromFloat(l.box[0] * f),
        .y = whole_h - bh - @as(c_int, @intFromFloat(l.box[1] * f)),
        .width = bw,
        .height = bh,
        .dither = 1.0 / 255.0,
        .uncropped = c.crop_mode,
        .view = .{ @floatCast(l.view[0]), @floatCast(l.view[1]), @floatCast(l.view[2]), @floatCast(l.view[3]) },
        .show_mask = if (c.before) null else c.show_mask,
    };
    c.pipeline.?.render(c.shownRecipe(), out);
    // Before/after: the original over the left of the line.
    if (c.compare and !c.before and !c.crop_mode) {
        out.scissor = .{ out.x, out.y, @intFromFloat(c.split * @as(f64, @floatFromInt(bw))), bh };
        c.pipeline.?.render(.{ .crop = c.recipe.crop }, out);
    }
    gtk.gtk_widget_queue_draw(c.overlay);
    if (c.on_drawn) |d| d();
    return 1;
}

pub fn onMotion(_: *anyopaque, x: f64, y: f64, ctx: ?*anyopaque) callconv(.c) void {
    const c: *Canvas = @ptrCast(@alignCast(ctx));
    c.cursor = .{ x, y };
    c.updateCursor();
}

fn updateCursor(c: *Canvas) void {
    const name: ?[*:0]const u8 = switch (if (c.dragging) c.drag else c.spotAt(c.cursor[0], c.cursor[1])) {
        .pan => if (c.zoom <= 1.001) null else if (c.dragging) "grabbing" else "grab",
        .mask => if (c.dragging) "grabbing" else "grab",
        .split => "ew-resize",
        .crop_move => "move",
        .nw, .se => "nwse-resize",
        .ne, .sw => "nesw-resize",
        .pick => "crosshair",
        .none => null,
    };
    if (name == c.cursor_name) return;
    c.cursor_name = name;
    gtk.gtk_widget_set_cursor_from_name(c.area, name);
}

// Double-click: from the whole photo to 100% at that place, and back.
pub fn onPressed(_: *anyopaque, presses: c_int, x: f64, y: f64, ctx: ?*anyopaque) callconv(.c) void {
    const c: *Canvas = @ptrCast(@alignCast(ctx));
    if (presses != 2 or !c.ready() or !c.zoomable() or c.spotAt(x, y) != .pan) return;
    c.cursor = .{ x, y };
    c.goal = if (c.goal > 1.01) 1 else std.math.clamp(c.actualSize(), 2, c.maxZoom());
    c.startTicking();
}

// The zoom at which a photo pixel is a pixel on the screen.
fn actualSize(c: *const Canvas) f64 {
    const fit = c.layout(1, .{ 0.5, 0.5 });
    const scale: f64 = @floatFromInt(gtk.gtk_widget_get_scale_factor(c.area));
    return c.full_width * c.recipe.crop.rect[2] / (fit.image[0] * scale);
}

fn onScroll(_: *anyopaque, _: f64, dy: f64, ctx: ?*anyopaque) callconv(.c) c_int {
    const c: *Canvas = @ptrCast(@alignCast(ctx));
    if (!c.ready() or !c.zoomable()) return 0;
    c.goal = std.math.clamp(c.goal * @exp(-dy * 120 * 0.0015), 1, c.maxZoom());
    c.startTicking();
    return 1;
}

// Grab distance for the crop's corners and the before/after line, pixels.
const grab = 14.0;

pub fn spotAt(c: *const Canvas, x: f64, y: f64) Spot {
    if (!c.ready()) return .none;
    const l = c.layout(c.zoom, c.centre);
    if (c.crop_mode) {
        const r = c.recipe.crop.rect;
        const spot = cropping.spotAt(.{ r[0], r[1], r[2], r[3] }, l.box, x, y, grab) orelse return .none;
        return switch (spot) {
            .frame => .crop_move,
            .corner => |corner| switch (corner) {
                .nw => .nw,
                .ne => .ne,
                .sw => .sw,
                .se => .se,
            },
        };
    }
    const on_photo = x >= l.box[0] and y >= l.box[1] and x <= l.box[0] + l.box[2] and y <= l.box[1] + l.box[3];
    if (c.picking) return if (on_photo) .pick else .none;
    if (c.compare and !c.before and @abs(x - (l.box[0] + c.split * l.box[2])) < grab and y > l.box[1] and y < l.box[1] + l.box[3]) return .split;
    if (c.maskHandleAt(l, x, y) != null) return .mask;
    return .pan;
}

pub fn onDragBegin(gesture: *anyopaque, x: f64, y: f64, ctx: ?*anyopaque) callconv(.c) void {
    const c: *Canvas = @ptrCast(@alignCast(ctx));
    _ = gtk.gtk_widget_grab_focus(c.area);
    c.cursor = .{ x, y };
    c.drag = c.spotAt(x, y);
    c.drag_centre = c.centre;
    c.dragging = true;
    defer c.updateCursor();
    switch (c.drag) {
        .none, .pan => {},
        .pick => {
            c.drag_at = .{ x, y };
            c.pick_keep = gtk.gtk_event_controller_get_current_event_state(gesture) & gtk.shift_mask == 0;
        },
        .split => c.drag_centre = .{ x, y },
        .mask => {
            const m = c.activeMask().?;
            c.mask_handle = c.maskHandleAt(c.layout(c.zoom, c.centre), x, y).?;
            c.mask_start = m.place();
            c.drag_at = .{ x, y };
            c.mask_gesture = @import("slider.zig").nextGesture();
        },
        .crop_move, .nw, .ne, .sw, .se => {
            const r = c.recipe.crop.rect;
            c.drag_rect = .{ r[0], r[1], r[2], r[3] };
            c.crop_gesture = @import("slider.zig").nextGesture();
        },
    }
}

pub fn onDragEnd(_: *anyopaque, _: f64, _: f64, ctx: ?*anyopaque) callconv(.c) void {
    const c: *Canvas = @ptrCast(@alignCast(ctx));
    c.dragging = false;
    defer c.updateCursor();
    // A press that became a move of the photo isn't a click on it.
    if (c.drag != .pick) return;
    c.drag = .none;
    if (!c.ready()) return;
    const on_pick = c.on_pick orelse return;
    const at = c.onPhoto(c.layout(c.zoom, c.centre), c.drag_at[0], c.drag_at[1]);
    on_pick.f(on_pick.ctx, .{ @floatCast(std.math.clamp(at[0], 0, 1)), @floatCast(std.math.clamp(at[1], 0, 1)) }, c.pick_keep);
}

// ---- A mask's handles ----

fn geometry(c: *const Canvas) cropping.Geometry {
    const r = c.recipe;
    const size = c.pipeline.?.outputSize(.{ .crop = .{ .rotate = r.crop.rotate } }, true);
    const rect = r.crop.rect;
    return .{
        .rect = if (c.crop_mode) .{ 0, 0, 1, 1 } else .{ rect[0], rect[1], rect[2], rect[3] },
        .turns = @intCast(@mod(r.crop.rotate / 90, 4)),
        .flip = r.crop.flip,
        .angle = std.math.degreesToRadians(@as(f64, r.crop.straighten)),
        .size = .{ @floatFromInt(size[0]), @floatFromInt(size[1]) },
    };
}

// A point of the photo as decoded, on the widget.
fn onScreen(c: *const Canvas, l: Layout, p: [2]f64) [2]f64 {
    const o = c.geometry().fromPhoto(p);
    return .{
        l.box[0] + (o[0] - l.view[0]) / l.view[2] * l.box[2],
        l.box[1] + (o[1] - l.view[1]) / l.view[3] * l.box[3],
    };
}

// A point of the widget, on the photo as decoded.
fn onPhoto(c: *const Canvas, l: Layout, x: f64, y: f64) [2]f64 {
    return c.geometry().toPhoto(.{
        l.view[0] + (x - l.box[0]) / l.box[2] * l.view[2],
        l.view[1] + (y - l.box[1]) / l.box[3] * l.view[3],
    });
}

fn activeMask(c: *const Canvas) ?Recipe.Mask {
    if (c.crop_mode or c.before) return null;
    const i = c.active_mask orelse return null;
    return if (i < c.recipe.masks.len) c.recipe.masks[i] else null;
}

fn point64(p: [2]f32) [2]f64 {
    return .{ p[0], p[1] };
}

fn handlePoint(m: Recipe.Mask.Place, h: Handle) [2]f64 {
    const from = point64(m.from);
    const to = point64(m.to);
    const centre = point64(m.centre);
    const radius = point64(m.radius);
    return switch (h) {
        .from => from,
        .to => to,
        .middle => .{ (from[0] + to[0]) / 2, (from[1] + to[1]) / 2 },
        .centre => centre,
        .across => .{ centre[0] + radius[0], centre[1] },
        .down => .{ centre[0], centre[1] + radius[1] },
    };
}

fn handlesOf(shape: Recipe.Mask.Shape) []const Handle {
    return switch (shape) {
        .whole, .subject => &.{},
        .linear => &.{ .middle, .from, .to },
        .radial => &.{ .centre, .across, .down },
    };
}

// The nearest handle within reach: however close together they've been dragged.
fn maskHandleAt(c: *const Canvas, l: Layout, x: f64, y: f64) ?Handle {
    const m = c.activeMask() orelse return null;
    const place = m.place();
    var best: ?Handle = null;
    var best_distance: f64 = std.math.inf(f64);
    for (handlesOf(m.shape)) |h| {
        const at_screen = c.onScreen(l, handlePoint(place, h));
        const dx = x - at_screen[0];
        const dy = y - at_screen[1];
        if (@abs(dx) >= grab or @abs(dy) >= grab or dx * dx + dy * dy >= best_distance) continue;
        best = h;
        best_distance = dx * dx + dy * dy;
    }
    return best;
}

fn dragMask(c: *Canvas, dx: f64, dy: f64) void {
    const i = c.active_mask orelse return;
    const on_mask = c.on_mask orelse return;
    const l = c.layout(c.zoom, c.centre);
    const start = c.onPhoto(l, c.drag_at[0], c.drag_at[1]);
    const now = c.onPhoto(l, c.drag_at[0] + dx, c.drag_at[1] + dy);
    const move = [2]f32{ @floatCast(now[0] - start[0]), @floatCast(now[1] - start[1]) };
    const s = c.mask_start;
    var p = s;
    const moved = struct {
        fn f(a: [2]f32, by: [2]f32) [2]f32 {
            return .{ a[0] + by[0], a[1] + by[1] };
        }
    }.f;
    switch (c.mask_handle) {
        .from => p.from = moved(s.from, move),
        .to => p.to = moved(s.to, move),
        .middle => {
            p.from = moved(s.from, move);
            p.to = moved(s.to, move);
        },
        .centre => p.centre = moved(s.centre, move),
        .across => p.radius[0] = @abs(s.radius[0] + move[0]),
        .down => p.radius[1] = @abs(s.radius[1] + move[1]),
    }
    on_mask.f(on_mask.ctx, i, p, c.mask_gesture);
}

// A line light on any photo: white over a dark edge.
fn strokeLine(cr: *gtk.Cairo, points: []const [2]f64) void {
    for ([_][2]f64{ .{ 3, 0.45 }, .{ 1, 0.95 } }, [_]f64{ 0, 0.957 }) |style, grey| {
        gtk.cairo_set_line_width(cr, style[0]);
        gtk.cairo_set_source_rgba(cr, grey, grey, grey, style[1]);
        for (points, 0..) |p, i| {
            if (i == 0) gtk.cairo_move_to(cr, p[0], p[1]) else gtk.cairo_line_to(cr, p[0], p[1]);
        }
        gtk.cairo_stroke(cr);
    }
}

fn drawHandle(cr: *gtk.Cairo, at_screen: [2]f64) void {
    gtk.cairo_set_source_rgba(cr, 0, 0, 0, 0.5);
    gtk.cairo_arc(cr, at_screen[0], at_screen[1], 6.5, 0, 2 * std.math.pi);
    gtk.cairo_fill(cr);
    gtk.cairo_set_source_rgb(cr, 0.957, 0.957, 0.957);
    gtk.cairo_arc(cr, at_screen[0], at_screen[1], 5, 0, 2 * std.math.pi);
    gtk.cairo_fill(cr);
}

fn drawMask(c: *const Canvas, cr: *gtk.Cairo, l: Layout, m: Recipe.Mask) void {
    if (m.shape == .whole) return;
    if (m.shape == .subject) {
        // The points that found it: light is "this", dark is "not this".
        for (m.points) |p| {
            const at = c.onScreen(l, .{ p[0], p[1] });
            drawHandle(cr, at);
            if (p[2] < 0.5) {
                gtk.cairo_set_source_rgb(cr, 0.1, 0.1, 0.1);
                gtk.cairo_arc(cr, at[0], at[1], 3.5, 0, 2 * std.math.pi);
                gtk.cairo_fill(cr);
            }
        }
        return;
    }
    gtk.cairo_save(cr);
    defer gtk.cairo_restore(cr);
    gtk.cairo_rectangle(cr, l.box[0], l.box[1], l.box[2], l.box[3]);
    gtk.cairo_clip(cr);
    const place = m.place();
    if (m.shape == .linear) {
        // Across the gradient at each end: full effect above the first line, none past the second.
        const w: f64 = @floatFromInt(c.pipeline.?.width);
        const h: f64 = @floatFromInt(c.pipeline.?.height);
        const from = point64(m.from);
        const to = point64(m.to);
        const dx = (to[0] - from[0]) * w;
        const dy = (to[1] - from[1]) * h;
        const len = @max(1e-6, @sqrt(dx * dx + dy * dy));
        // Two photos' worth of line: the clip ends it.
        const reach = 2 * @max(w, h);
        const ax = -dy / len * reach / w;
        const ay = dx / len * reach / h;
        for ([_][2]f64{ from, to }) |p| {
            strokeLine(cr, &.{ c.onScreen(l, .{ p[0] - ax, p[1] - ay }), c.onScreen(l, .{ p[0] + ax, p[1] + ay }) });
        }
    } else {
        var outline: [65][2]f64 = undefined;
        for (&outline, 0..) |*o, i| {
            const t = @as(f64, @floatFromInt(i)) / 64 * 2 * std.math.pi;
            o.* = c.onScreen(l, .{ m.centre[0] + m.radius[0] * @cos(t), m.centre[1] + m.radius[1] * @sin(t) });
        }
        strokeLine(cr, &outline);
    }
    for (handlesOf(m.shape)) |h| drawHandle(cr, c.onScreen(l, handlePoint(place, h)));
}

fn dragCrop(c: *Canvas, dx: f64, dy: f64) void {
    const l = c.layout(c.zoom, c.centre);
    const nx = dx / l.box[2];
    const ny = dy / l.box[3];
    const photo = c.photoSize(c.recipe);
    const r: cropping.Rect = switch (c.drag) {
        .crop_move => cropping.moved(c.drag_rect, nx, ny),
        .nw => cropping.resized(c.drag_rect, .nw, nx, ny, c.aspect_ratio, photo),
        .ne => cropping.resized(c.drag_rect, .ne, nx, ny, c.aspect_ratio, photo),
        .sw => cropping.resized(c.drag_rect, .sw, nx, ny, c.aspect_ratio, photo),
        .se => cropping.resized(c.drag_rect, .se, nx, ny, c.aspect_ratio, photo),
        else => return,
    };
    if (c.on_crop) |f| f(r, c.crop_gesture);
}

pub fn onDragUpdate(_: *anyopaque, dx: f64, dy: f64, ctx: ?*anyopaque) callconv(.c) void {
    const c: *Canvas = @ptrCast(@alignCast(ctx));
    if (!c.ready()) return;
    if (c.drag == .none) return;
    if (c.drag == .pick) {
        // Zoomed in, a click still picks and a drag still moves the photo.
        if (c.zoom <= 1.001 or dx * dx + dy * dy < 16) return;
        c.drag = .pan;
        c.updateCursor();
    }
    if (c.drag == .mask) return c.dragMask(dx, dy);
    if (c.drag == .split) {
        const l = c.layout(c.zoom, c.centre);
        c.split = std.math.clamp((c.drag_centre[0] + dx - l.box[0]) / l.box[2], 0, 1);
        return c.redraw();
    }
    if (c.crop_mode) return c.dragCrop(dx, dy);
    if (c.zoom <= 1.001) return;
    const l = c.layout(c.zoom, c.centre);
    c.centre = .{ c.drag_centre[0] - dx / l.image[0], c.drag_centre[1] - dy / l.image[1] };
    gtk.gtk_gl_area_queue_render(c.area);
}

// What's drawn over the photo: the crop's frame, the before/after line, a mask's handles.
fn drawOverlay(_: *anyopaque, cr: *gtk.Cairo, _: c_int, _: c_int, ctx: ?*anyopaque) callconv(.c) void {
    const c: *Canvas = @ptrCast(@alignCast(ctx));
    if (!c.ready()) return;
    const l = c.layout(c.zoom, c.centre);
    const bx = l.box[0];
    const by = l.box[1];
    const bw = l.box[2];
    const bh = l.box[3];
    if (c.crop_mode) {
        const r = c.recipe.crop.rect;
        const L = bx + r[0] * bw;
        const T = by + r[1] * bh;
        const W = r[2] * bw;
        const H = r[3] * bh;
        gtk.cairo_set_source_rgba(cr, 0, 0, 0, 0.6);
        gtk.cairo_rectangle(cr, bx, by, bw, T - by);
        gtk.cairo_rectangle(cr, bx, T + H, bw, by + bh - T - H);
        gtk.cairo_rectangle(cr, bx, T, L - bx, H);
        gtk.cairo_rectangle(cr, L + W, T, bx + bw - L - W, H);
        gtk.cairo_fill(cr);
        gtk.cairo_set_line_width(cr, 1);
        gtk.cairo_set_source_rgba(cr, 1, 1, 1, 0.35);
        for ([_]f64{ 1.0 / 3.0, 2.0 / 3.0 }) |t| {
            gtk.cairo_move_to(cr, L + t * W, T);
            gtk.cairo_line_to(cr, L + t * W, T + H);
            gtk.cairo_move_to(cr, L, T + t * H);
            gtk.cairo_line_to(cr, L + W, T + t * H);
        }
        gtk.cairo_stroke(cr);
        gtk.cairo_set_source_rgba(cr, 1, 1, 1, 0.9);
        gtk.cairo_rectangle(cr, L, T, W, H);
        gtk.cairo_stroke(cr);
        gtk.cairo_set_source_rgb(cr, 0.957, 0.957, 0.957);
        for ([_][2]f64{ .{ L, T }, .{ L + W, T }, .{ L, T + H }, .{ L + W, T + H } }) |p| {
            gtk.cairo_rectangle(cr, p[0] - 5, p[1] - 5, 10, 10);
            gtk.cairo_fill(cr);
        }
    } else if (c.compare and !c.before) {
        const x = bx + c.split * bw;
        gtk.cairo_set_source_rgb(cr, 0.957, 0.957, 0.957);
        gtk.cairo_rectangle(cr, x - 0.5, by, 1, bh);
        gtk.cairo_fill(cr);
        gtk.cairo_arc(cr, x, by + bh / 2, 10, 0, 2 * std.math.pi);
        gtk.cairo_fill(cr);
    }
    if (c.activeMask()) |m| c.drawMask(cr, l, m);
}

/// "Fit", or how big a photo pixel is on the screen.
pub fn zoomText(c: *const Canvas, buf: []u8) [:0]const u8 {
    if (c.zoom <= 1.001 or !c.ready()) return "Fit";
    return std.fmt.bufPrintZ(buf, "{d:.0}%", .{c.zoom / c.actualSize() * 100}) catch "Fit";
}
