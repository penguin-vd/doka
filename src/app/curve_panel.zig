//! The tone curve in Adjust, for the whole photo: click to add a point, drag to move it, double-click
//! a point to take it away (an end goes back to black or white). Reset, or a double-click on its name
//! as on a slider's, makes it straight again. What it edits is the recipe's `curve`.
const std = @import("std");
const core = @import("photo-core");
const gtk = @import("gtk.zig");
const App = @import("app.zig");
const Slider = @import("slider.zig");
const Recipe = core.Recipe;

const Panel = @This();

const height = 200;
// How near a press has to be to take hold of a point, pixels.
const grab_px = 10;
// Two points this close would make a cliff, as a share of the width.
const min_gap = 0.02;

gpa: std.mem.Allocator,
app: *App,
edited: *const fn () void,
widget: *anyopaque = undefined,
area: *anyopaque = undefined,
reset_button: *anyopaque = undefined,
// The curve with both its ends, always.
points: [Recipe.max_curve_points][2]f32 = undefined,
count: usize = 2,
held: ?usize = null,
start: [2]f32 = .{ 0, 0 },
gesture: u64 = 0,

fn connect(object: *anyopaque, signal: [*:0]const u8, handler: anytype, data: ?*anyopaque) void {
    _ = gtk.g_signal_connect_data(object, signal, @ptrCast(handler), data, null, 0);
}

pub fn create(p: *Panel) void {
    p.load(&.{});
    const box = gtk.gtk_box_new(gtk.vertical, 8);
    const heading = gtk.gtk_label_new("Curve");
    gtk.gtk_label_set_xalign(heading, 0);
    gtk.gtk_widget_add_css_class(heading, "section-title");
    gtk.gtk_widget_set_hexpand(heading, 1);
    const head = gtk.gtk_box_new(gtk.horizontal, 8);
    gtk.gtk_box_append(head, heading);
    const name_click = gtk.gtk_gesture_click_new();
    connect(name_click, "pressed", &onNamePressed, p);
    gtk.gtk_widget_add_controller(heading, name_click);
    p.reset_button = gtk.gtk_button_new_with_label("Reset");
    gtk.gtk_widget_add_css_class(p.reset_button, "quiet");
    gtk.gtk_widget_set_tooltip_text(p.reset_button, "Make the curve straight again");
    gtk.gtk_widget_set_sensitive(p.reset_button, 0);
    connect(p.reset_button, "clicked", &onReset, p);
    gtk.gtk_box_append(head, p.reset_button);
    gtk.gtk_box_append(box, head);
    p.area = gtk.gtk_drawing_area_new();
    gtk.gtk_drawing_area_set_content_height(p.area, height);
    gtk.gtk_drawing_area_set_draw_func(p.area, draw, p, null);
    gtk.gtk_widget_set_tooltip_text(p.area, "Click to add a point and drag it; double-click a point to take it away");
    const drag = gtk.gtk_gesture_drag_new();
    connect(drag, "drag-begin", &onBegin, p);
    connect(drag, "drag-update", &onUpdate, p);
    connect(drag, "drag-end", &onEnd, p);
    gtk.gtk_widget_add_controller(p.area, drag);
    const click = gtk.gtk_gesture_click_new();
    connect(click, "pressed", &onPressed, p);
    gtk.gtk_widget_add_controller(p.area, click);
    gtk.gtk_box_append(box, p.area);
    p.widget = box;
}

/// Follows the recipe: another photo, undo, Claude. `whole`: the whole photo is the layer picked.
pub fn sync(p: *Panel, r: Recipe, whole: bool) void {
    gtk.gtk_widget_set_visible(p.widget, @intFromBool(whole));
    p.held = null;
    p.load(r.curve);
    p.showChanged();
    gtk.gtk_widget_queue_draw(p.area);
}

fn isStraight(p: *const Panel) bool {
    return p.count == 2 and p.points[0][1] == 0 and p.points[1][1] == 1;
}

fn showChanged(p: *Panel) void {
    gtk.gtk_widget_set_sensitive(p.reset_button, @intFromBool(!p.isStraight()));
}

/// Straight again, in one undo step.
pub fn reset(p: *Panel) void {
    if (p.isStraight() or p.app.currentSession() == null) return;
    p.held = null;
    p.load(&.{});
    p.commit(Slider.nextGesture());
    gtk.gtk_widget_queue_draw(p.area);
}

fn onReset(_: *anyopaque, p: *Panel) callconv(.c) void {
    p.reset();
}

pub fn onNamePressed(_: *anyopaque, presses: c_int, _: f64, _: f64, ctx: ?*anyopaque) callconv(.c) void {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    if (presses == 2) p.reset();
}

fn load(p: *Panel, curve: []const [2]f32) void {
    var n: usize = 0;
    if (curve.len == 0 or curve[0][0] > 0) {
        p.points[0] = .{ 0, 0 };
        n = 1;
    }
    for (curve) |point| {
        if (n == p.points.len) break;
        p.points[n] = point;
        n += 1;
    }
    if (p.points[n - 1][0] < 1) {
        // No room left: the last point becomes the end.
        if (n == p.points.len) n -= 1;
        p.points[n] = .{ 1, 1 };
        n += 1;
    }
    p.count = n;
}

fn commit(p: *Panel, gesture: u64) void {
    var scratch: std.heap.ArenaAllocator = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    p.showChanged();
    const json = (if (p.isStraight())
        a.dupe(u8, "{\"curve\":null}")
    else
        std.json.Stringify.valueAlloc(a, .{ .curve = p.points[0..p.count] }, .{})) catch return;
    p.app.edit(json, gesture) catch return;
    p.edited();
}

// ---- What a press does, in tones: x black to white, y dark to light ----

/// Takes hold of the point near here, or makes one. Null when the curve is full.
pub fn take(p: *Panel, x: f32, y: f32, reach: f32) ?usize {
    var best: ?usize = null;
    var nearest = reach;
    for (p.points[0..p.count], 0..) |point, i| {
        const d = std.math.hypot(point[0] - x, point[1] - y);
        if (d < nearest) {
            nearest = d;
            best = i;
        }
    }
    if (best) |i| return i;
    if (p.count == p.points.len) return null;
    const at = for (p.points[1..p.count], 1..) |point, i| {
        if (x < point[0]) break i;
    } else p.count - 1;
    const room = @min(x - p.points[at - 1][0], p.points[at][0] - x);
    if (room < min_gap) return null;
    std.mem.copyBackwards([2]f32, p.points[at + 1 .. p.count + 1], p.points[at..p.count]);
    p.points[at] = .{ x, std.math.clamp(y, 0, 1) };
    p.count += 1;
    return at;
}

/// Moves a point, staying between its neighbours. The ends only go up and down.
pub fn move(p: *Panel, i: usize, x: f32, y: f32) void {
    p.points[i][1] = std.math.clamp(y, 0, 1);
    if (i == 0 or i == p.count - 1) return;
    p.points[i][0] = std.math.clamp(x, p.points[i - 1][0] + min_gap, p.points[i + 1][0] - min_gap);
}

/// Takes a point away; an end goes back to black or white.
pub fn drop(p: *Panel, i: usize) void {
    if (i == 0) {
        p.points[0][1] = 0;
    } else if (i == p.count - 1) {
        p.points[i][1] = 1;
    } else {
        std.mem.copyForwards([2]f32, p.points[i .. p.count - 1], p.points[i + 1 .. p.count]);
        p.count -= 1;
    }
}

// ---- The widget ----

fn tones(p: *const Panel, x: f64, y: f64) [2]f32 {
    const w: f64 = @floatFromInt(@max(1, gtk.gtk_widget_get_width(p.area)));
    const h: f64 = @floatFromInt(@max(1, gtk.gtk_widget_get_height(p.area)));
    return .{ @floatCast(std.math.clamp(x / w, 0, 1)), @floatCast(std.math.clamp(1 - y / h, 0, 1)) };
}

fn reachInTones(p: *const Panel) f32 {
    return grab_px / @as(f32, @floatFromInt(@max(1, gtk.gtk_widget_get_width(p.area))));
}

pub fn onBegin(_: *anyopaque, x: f64, y: f64, ctx: ?*anyopaque) callconv(.c) void {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    if (p.app.currentSession() == null) return;
    const at = p.tones(x, y);
    const before = p.count;
    p.gesture = Slider.nextGesture();
    p.held = p.take(at[0], at[1], p.reachInTones());
    const i = p.held orelse return;
    p.start = p.points[i];
    if (p.count != before) p.commit(p.gesture);
    gtk.gtk_widget_queue_draw(p.area);
}

pub fn onUpdate(_: *anyopaque, dx: f64, dy: f64, ctx: ?*anyopaque) callconv(.c) void {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    const i = p.held orelse return;
    const w: f64 = @floatFromInt(@max(1, gtk.gtk_widget_get_width(p.area)));
    const h: f64 = @floatFromInt(@max(1, gtk.gtk_widget_get_height(p.area)));
    p.move(i, p.start[0] + @as(f32, @floatCast(dx / w)), p.start[1] - @as(f32, @floatCast(dy / h)));
    p.commit(p.gesture);
    gtk.gtk_widget_queue_draw(p.area);
}

pub fn onEnd(_: *anyopaque, _: f64, _: f64, ctx: ?*anyopaque) callconv(.c) void {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    p.held = null;
}

pub fn onPressed(_: *anyopaque, presses: c_int, x: f64, y: f64, ctx: ?*anyopaque) callconv(.c) void {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    if (presses != 2 or p.app.currentSession() == null) return;
    const at = p.tones(x, y);
    const i = p.take(at[0], at[1], p.reachInTones()) orelse return;
    p.drop(i);
    p.held = null;
    p.commit(Slider.nextGesture());
    gtk.gtk_widget_queue_draw(p.area);
}

fn draw(_: *anyopaque, cr: *gtk.Cairo, width: c_int, h_px: c_int, ctx: ?*anyopaque) callconv(.c) void {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(h_px);
    gtk.cairo_set_source_rgb(cr, 0.13, 0.13, 0.13);
    gtk.cairo_rectangle(cr, 0, 0, w, h);
    gtk.cairo_fill(cr);
    gtk.cairo_set_line_width(cr, 1);
    gtk.cairo_set_source_rgb(cr, 0.24, 0.24, 0.24);
    for ([_]f64{ 0.25, 0.5, 0.75 }) |t| {
        gtk.cairo_move_to(cr, @round(t * w) + 0.5, 0);
        gtk.cairo_line_to(cr, @round(t * w) + 0.5, h);
        gtk.cairo_move_to(cr, 0, @round(t * h) + 0.5);
        gtk.cairo_line_to(cr, w, @round(t * h) + 0.5);
    }
    gtk.cairo_move_to(cr, 0, h);
    gtk.cairo_line_to(cr, w, 0);
    gtk.cairo_stroke(cr);

    var table: [Recipe.curve_samples]f32 = undefined;
    Recipe.curveTable(p.points[0..p.count], &table);
    gtk.cairo_set_line_width(cr, 1.5);
    gtk.cairo_set_source_rgb(cr, 0.957, 0.957, 0.957);
    for (table, 0..) |v, i| {
        const x = @as(f64, @floatFromInt(i)) / (table.len - 1) * w;
        const y = (1 - @as(f64, v)) * h;
        if (i == 0) gtk.cairo_move_to(cr, x, y) else gtk.cairo_line_to(cr, x, y);
    }
    gtk.cairo_stroke(cr);
    for (p.points[0..p.count]) |point| {
        gtk.cairo_arc(cr, point[0] * w, (1 - point[1]) * h, 4, 0, 2 * std.math.pi);
        gtk.cairo_fill(cr);
    }
}
