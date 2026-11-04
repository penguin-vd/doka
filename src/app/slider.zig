//! A labelled slider that fills from where "nothing" is: the middle of one that goes both ways.
//! Double-click puts it back; a press starts a new undo step.
const std = @import("std");
const gtk = @import("gtk.zig");

const Slider = @This();

pub const Config = struct {
    label: [:0]const u8,
    min: f64,
    max: f64,
    step: f64 = 1,
    reset: f64 = 0,
    unit: enum { plain, signed, ev, percent, degrees, decimal } = .signed,
    on_change: *const fn (s: *Slider, value: f64, gesture: u64) void,
    ctx: ?*anyopaque = null,
};

const thumb = 5.5;
const height = 16;
// The tokens in the window's CSS.
const track = [3]f64{ 0.29, 0.29, 0.29 };
const on = [3]f64{ 0.957, 0.957, 0.957 };
const off_thumb = [3]f64{ 0.569, 0.569, 0.569 };

var gesture_counter: u64 = 0;

pub fn nextGesture() u64 {
    gesture_counter += 1;
    return gesture_counter;
}

config: Config,
value: f64,
gesture: u64 = 0,
widget: *anyopaque = undefined,
area: *anyopaque = undefined,
value_label: *anyopaque = undefined,
name_label: *anyopaque = undefined,

pub fn create(gpa: std.mem.Allocator, config: Config) *Slider {
    const s = gpa.create(Slider) catch @panic("out of memory");
    s.* = .{ .config = config, .value = config.reset };
    const box = gtk.gtk_box_new(gtk.vertical, 0);
    const head = gtk.gtk_box_new(gtk.horizontal, 8);
    s.name_label = gtk.gtk_label_new(config.label);
    gtk.gtk_label_set_xalign(s.name_label, 0);
    gtk.gtk_widget_set_hexpand(s.name_label, 1);
    gtk.gtk_widget_add_css_class(s.name_label, "slider-label");
    s.value_label = gtk.gtk_label_new(null);
    gtk.gtk_widget_add_css_class(s.value_label, "slider-value");
    gtk.gtk_box_append(head, s.name_label);
    gtk.gtk_box_append(head, s.value_label);
    gtk.gtk_box_append(box, head);
    s.area = gtk.gtk_drawing_area_new();
    gtk.gtk_drawing_area_set_content_height(s.area, height);
    gtk.gtk_drawing_area_set_draw_func(s.area, draw, s, null);
    const drag = gtk.gtk_gesture_drag_new();
    connect(drag, "drag-begin", &onBegin, s);
    connect(drag, "drag-update", &onUpdate, s);
    gtk.gtk_widget_add_controller(s.area, drag);
    const click = gtk.gtk_gesture_click_new();
    connect(click, "pressed", &onPressed, s);
    gtk.gtk_widget_add_controller(s.area, click);
    gtk.gtk_box_append(box, s.area);
    s.widget = box;
    s.show();
    return s;
}

fn connect(object: *anyopaque, signal: [*:0]const u8, handler: anytype, data: ?*anyopaque) void {
    _ = gtk.g_signal_connect_data(object, signal, @ptrCast(handler), data, null, 0);
}

/// From the recipe: no edit comes of it.
pub fn set(s: *Slider, value: f64) void {
    if (value == s.value) return;
    s.value = value;
    s.gesture = 0;
    s.show();
}

fn show(s: *Slider) void {
    var buf: [32]u8 = undefined;
    const v = s.value;
    const plus: []const u8 = if (v > 0) "+" else "";
    const text = switch (s.config.unit) {
        .plain => std.fmt.bufPrintZ(&buf, "{d:.0}", .{v}),
        .signed => std.fmt.bufPrintZ(&buf, "{s}{d:.0}", .{ plus, v }),
        .ev => if (v == 0) std.fmt.bufPrintZ(&buf, "0 EV", .{}) else std.fmt.bufPrintZ(&buf, "{s}{d:.2} EV", .{ plus, v }),
        .percent => std.fmt.bufPrintZ(&buf, "{d:.0}%", .{v}),
        .degrees => std.fmt.bufPrintZ(&buf, "{s}{d:.1}°", .{ plus, v }),
        .decimal => std.fmt.bufPrintZ(&buf, "{d:.2}", .{v}),
    };
    gtk.gtk_label_set_text(s.value_label, text catch "");
    const changed = v != s.config.reset;
    if (changed) {
        gtk.gtk_widget_add_css_class(s.value_label, "set");
        gtk.gtk_widget_add_css_class(s.name_label, "set");
    } else {
        gtk.gtk_widget_remove_css_class(s.value_label, "set");
        gtk.gtk_widget_remove_css_class(s.name_label, "set");
    }
    gtk.gtk_widget_queue_draw(s.area);
}

fn origin(c: Config) f64 {
    return if (c.min < 0 and c.max > 0) 0 else c.min;
}

fn position(s: *const Slider, v: f64, w: f64) f64 {
    const share = (v - s.config.min) / (s.config.max - s.config.min);
    return thumb + share * (w - 2 * thumb);
}

fn draw(_: *anyopaque, cr: *gtk.Cairo, w_i: c_int, h_i: c_int, ctx: ?*anyopaque) callconv(.c) void {
    const s: *Slider = @ptrCast(@alignCast(ctx));
    const w: f64 = @floatFromInt(w_i);
    const y = @floor(@as(f64, @floatFromInt(h_i)) / 2);
    gtk.cairo_set_source_rgb(cr, track[0], track[1], track[2]);
    gtk.cairo_rectangle(cr, 0, y, w, 1);
    gtk.cairo_fill(cr);
    const c = s.config;
    const o = origin(c);
    if (o != c.min) {
        gtk.cairo_rectangle(cr, @floor(s.position(o, w)), y - 3, 1, 7);
        gtk.cairo_fill(cr);
    }
    const a = s.position(@min(o, s.value), w);
    const b = s.position(@max(o, s.value), w);
    gtk.cairo_set_source_rgb(cr, on[0], on[1], on[2]);
    gtk.cairo_rectangle(cr, a, y, b - a, 1);
    gtk.cairo_fill(cr);
    const colour = if (s.value != c.reset) on else off_thumb;
    gtk.cairo_set_source_rgb(cr, colour[0], colour[1], colour[2]);
    gtk.cairo_arc(cr, s.position(s.value, w), y + 0.5, thumb, 0, 2 * std.math.pi);
    gtk.cairo_fill(cr);
}

// A value from a place along the track, on the slider's steps.
pub fn snapped(c: Config, x: f64, w: f64) f64 {
    const share = std.math.clamp((x - thumb) / @max(1, w - 2 * thumb), 0, 1);
    const raw = c.min + share * (c.max - c.min);
    return std.math.clamp(c.min + @round((raw - c.min) / c.step) * c.step, c.min, c.max);
}

fn change(s: *Slider, value: f64) void {
    if (value == s.value) return;
    s.value = value;
    s.show();
    s.config.on_change(s, value, s.gesture);
}

var drag_start: f64 = 0;

fn onBegin(_: *anyopaque, x: f64, _: f64, ctx: ?*anyopaque) callconv(.c) void {
    const s: *Slider = @ptrCast(@alignCast(ctx));
    drag_start = x;
    if (s.gesture == 0) s.gesture = nextGesture();
    s.change(snapped(s.config, x, @floatFromInt(gtk.gtk_widget_get_width(s.area))));
}

fn onUpdate(_: *anyopaque, dx: f64, _: f64, ctx: ?*anyopaque) callconv(.c) void {
    const s: *Slider = @ptrCast(@alignCast(ctx));
    s.change(snapped(s.config, drag_start + dx, @floatFromInt(gtk.gtk_widget_get_width(s.area))));
}

fn onPressed(_: *anyopaque, presses: c_int, _: f64, _: f64, ctx: ?*anyopaque) callconv(.c) void {
    const s: *Slider = @ptrCast(@alignCast(ctx));
    s.gesture = nextGesture();
    if (presses == 2) s.change(s.config.reset);
}

test "a place along the track becomes a value on the slider's steps" {
    const nothing = struct {
        fn f(_: *Slider, _: f64, _: u64) void {}
    }.f;
    const c: Config = .{ .label = "x", .min = -100, .max = 100, .on_change = nothing };
    try std.testing.expectEqual(-100, snapped(c, 0, 211));
    try std.testing.expectEqual(0, snapped(c, 105.5, 211));
    try std.testing.expectEqual(100, snapped(c, 500, 211));
    const ev: Config = .{ .label = "x", .min = -5, .max = 5, .step = 0.05, .on_change = nothing };
    try std.testing.expectApproxEqAbs(0.5, snapped(ev, 116, 211), 0.051);
}
