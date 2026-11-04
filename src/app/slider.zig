//! A labelled slider that fills from where "nothing" is: the middle of one that goes both ways.
//! Double-click puts it back, on the track or the name. A press starts a new undo step; grabbing the
//! thumb doesn't move it. Clicked or tabbed to, up and down nudge it (Shift: ten steps). The wheel over
//! its track moves it (Ctrl: one step at a time), unless the panel is still scrolling past.
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
    // While a drag is changing it, and when that ends.
    on_hold: ?*const fn (s: *Slider, held: bool) void = null,
    ctx: ?*anyopaque = null,
};

const thumb = 5.5;
const height = 16;
// A press this near the thumb grabs it.
const grab_slack = 3;
// GTK's own defaults for a double-click.
const double_click_us = 400_000;
const double_click_px = 5;
// Key presses this close together are one undo step.
const nudge_joins_us = 600_000;
// A wheel still scrolling the panel keeps doing that when a slider comes under the pointer.
const panel_keeps_wheel_us = 500_000;
// How long the wheel or a key counts as holding a slider that shows something while held.
const hold_ms = 500;
// The tokens in the window's CSS.
const track = [3]f64{ 0.29, 0.29, 0.29 };
const on = [3]f64{ 0.957, 0.957, 0.957 };
const off_thumb = [3]f64{ 0.569, 0.569, 0.569 };

var gesture_counter: u64 = 0;
var panel_moved_at: i64 = 0;

pub fn nextGesture() u64 {
    gesture_counter += 1;
    return gesture_counter;
}

config: Config,
value: f64,
gesture: u64 = 0,
// The place along the track a drag counts from; while not dragging, a drag does nothing.
drag_from: f64 = 0,
dragging: bool = false,
held: bool = false,
last_press: i64 = 0,
last_press_x: f64 = 0,
last_nudge: i64 = 0,
// Part of a step from a touchpad's small scrolls, in notches of the wheel.
wheel_left: f64 = 0,
hold_timer: c_uint = 0,
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
    connect(drag, "drag-end", &onEnd, s);
    gtk.gtk_widget_add_controller(s.area, drag);
    gtk.gtk_widget_set_focusable(s.area, 1);
    const keys = gtk.gtk_event_controller_key_new();
    connect(keys, "key-pressed", &onKey, s);
    gtk.gtk_widget_add_controller(s.area, keys);
    const focus = gtk.gtk_event_controller_focus_new();
    connect(focus, "enter", &onFocusChange, s);
    connect(focus, "leave", &onFocusChange, s);
    gtk.gtk_widget_add_controller(s.area, focus);
    const wheel = gtk.gtk_event_controller_scroll_new(gtk.scroll_vertical);
    connect(wheel, "scroll", &onScroll, s);
    gtk.gtk_widget_add_controller(s.area, wheel);
    const click = gtk.gtk_gesture_click_new();
    connect(click, "pressed", &onNamePressed, s);
    gtk.gtk_widget_add_controller(head, click);
    gtk.gtk_box_append(box, s.area);
    s.widget = box;
    s.show();
    return s;
}

fn connect(object: *anyopaque, signal: [*:0]const u8, handler: anytype, data: ?*anyopaque) void {
    _ = gtk.g_signal_connect_data(object, signal, @ptrCast(handler), data, null, 0);
}

/// Sliders inside this scrolled window let the wheel go on scrolling it.
pub fn watchPanel(scrolled: *anyopaque) void {
    connect(gtk.gtk_scrolled_window_get_vadjustment(scrolled), "value-changed", &onPanelMoved, null);
}

fn onPanelMoved(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    panel_moved_at = gtk.g_get_monotonic_time();
}

/// From the recipe: no edit comes of it.
pub fn set(s: *Slider, value: f64) void {
    if (value == s.value) return;
    s.value = value;
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
    // The one the arrow keys move.
    if (gtk.gtk_widget_has_focus(s.area) != 0) {
        gtk.cairo_set_source_rgb(cr, on[0], on[1], on[2]);
        gtk.cairo_set_line_width(cr, 1);
        gtk.cairo_arc(cr, s.position(s.value, w), y + 0.5, thumb + 2, 0, 2 * std.math.pi);
        gtk.cairo_stroke(cr);
    }
}

// Nearest on the slider's steps, and exactly its reset value when that's the nearest: a step's
// rounding never leaves it just beside "nothing".
pub fn onSteps(c: Config, raw: f64) f64 {
    const v = std.math.clamp(@round(raw / c.step) * c.step, c.min, c.max);
    return if (@abs(v - c.reset) < c.step / 2) c.reset else v;
}

// A value from a place along the track, on the slider's steps.
pub fn snapped(c: Config, x: f64, w: f64) f64 {
    const share = std.math.clamp((x - thumb) / @max(1, w - 2 * thumb), 0, 1);
    return onSteps(c, c.min + share * (c.max - c.min));
}

/// How far one notch of the wheel moves it: a hundredth of its range on its steps, or one step.
pub fn notch(c: Config, fine: bool) f64 {
    return if (fine) c.step else @max(c.step, @round((c.max - c.min) / 100 / c.step) * c.step);
}

pub fn isSecondClick(since_us: i64, moved_px: f64) bool {
    return since_us < double_click_us and @abs(moved_px) < double_click_px;
}

/// Where a drag from this press counts from: the thumb itself when it's on the thumb, so it doesn't
/// jump by how far off centre it was grabbed.
pub fn dragOrigin(x: f64, thumb_x: f64) ?f64 {
    return if (@abs(x - thumb_x) <= thumb + grab_slack) thumb_x else null;
}

fn change(s: *Slider, value: f64) void {
    if (value == s.value) return;
    s.value = value;
    s.show();
    if (s.dragging and !s.held) {
        s.held = true;
        if (s.config.on_hold) |f| f(s, true);
    }
    s.config.on_change(s, value, s.gesture);
}

fn width(s: *const Slider) f64 {
    return @floatFromInt(gtk.gtk_widget_get_width(s.area));
}

pub fn onBegin(_: *anyopaque, x: f64, _: f64, ctx: ?*anyopaque) callconv(.c) void {
    const s: *Slider = @ptrCast(@alignCast(ctx));
    _ = gtk.gtk_widget_grab_focus(s.area);
    const now = gtk.g_get_monotonic_time();
    if (isSecondClick(now - s.last_press, x - s.last_press_x)) {
        // With the first click's gesture: a click on the track and back undo as one step. The rest
        // of this press is no drag: a hand's tremble mustn't move it away again.
        s.last_press = 0;
        s.dragging = false;
        s.change(s.config.reset);
        return;
    }
    s.last_press = now;
    s.last_press_x = x;
    s.gesture = nextGesture();
    s.dragging = true;
    if (dragOrigin(x, s.position(s.value, s.width()))) |from| {
        s.drag_from = from;
    } else {
        s.drag_from = x;
        s.change(snapped(s.config, x, s.width()));
    }
}

fn onUpdate(_: *anyopaque, dx: f64, _: f64, ctx: ?*anyopaque) callconv(.c) void {
    const s: *Slider = @ptrCast(@alignCast(ctx));
    if (s.dragging) s.change(snapped(s.config, s.drag_from + dx, s.width()));
}

pub fn onEnd(_: *anyopaque, _: f64, _: f64, ctx: ?*anyopaque) callconv(.c) void {
    const s: *Slider = @ptrCast(@alignCast(ctx));
    s.dragging = false;
    if (s.held) {
        s.held = false;
        if (s.config.on_hold) |f| f(s, false);
    }
}

fn onNamePressed(_: *anyopaque, presses: c_int, _: f64, _: f64, ctx: ?*anyopaque) callconv(.c) void {
    const s: *Slider = @ptrCast(@alignCast(ctx));
    if (presses != 2) return;
    s.gesture = nextGesture();
    s.change(s.config.reset);
}

fn onKey(_: *anyopaque, key: c_uint, _: c_uint, state: c_uint, ctx: ?*anyopaque) callconv(.c) c_int {
    const s: *Slider = @ptrCast(@alignCast(ctx));
    const direction: f64 = switch (key) {
        gtk.key_up => 1,
        gtk.key_down => -1,
        else => return 0,
    };
    const now = gtk.g_get_monotonic_time();
    if (now - s.last_nudge > nudge_joins_us) s.gesture = nextGesture();
    s.last_nudge = now;
    const steps: f64 = if (state & gtk.shift_mask != 0) 10 else 1;
    s.holdBriefly();
    s.change(onSteps(s.config, s.value + direction * steps * s.config.step));
    return 1;
}

// Wheel up is more. Consecutive notches are one undo step, like the keys.
pub fn onScroll(controller: *anyopaque, _: f64, dy: f64, ctx: ?*anyopaque) callconv(.c) c_int {
    const s: *Slider = @ptrCast(@alignCast(ctx));
    const now = gtk.g_get_monotonic_time();
    if (now - panel_moved_at < panel_keeps_wheel_us) return 0;
    if (now - s.last_nudge > nudge_joins_us) {
        s.gesture = nextGesture();
        s.wheel_left = 0;
    }
    s.last_nudge = now;
    const size = notch(s.config, gtk.gtk_event_controller_get_current_event_state(controller) & gtk.control_mask != 0);
    const wanted = s.value - (dy + s.wheel_left) * size;
    const next = onSteps(s.config, wanted);
    // What a small scroll didn't reach waits for the next one; past the end nothing waits.
    s.wheel_left = if (next == s.config.min or next == s.config.max) 0 else (next - wanted) / size;
    s.holdBriefly();
    s.change(next);
    return 1;
}

fn holdBriefly(s: *Slider) void {
    const f = s.config.on_hold orelse return;
    if (s.dragging) return;
    if (!s.held) {
        s.held = true;
        f(s, true);
    }
    if (s.hold_timer != 0) _ = gtk.g_source_remove(s.hold_timer);
    s.hold_timer = gtk.g_timeout_add(hold_ms, onHoldOver, s);
}

fn onHoldOver(ctx: ?*anyopaque) callconv(.c) c_int {
    const s: *Slider = @ptrCast(@alignCast(ctx));
    s.hold_timer = 0;
    if (s.held and !s.dragging) {
        s.held = false;
        if (s.config.on_hold) |f| f(s, false);
    }
    return gtk.source_remove;
}

fn onFocusChange(_: *anyopaque, ctx: ?*anyopaque) callconv(.c) void {
    const s: *Slider = @ptrCast(@alignCast(ctx));
    gtk.gtk_widget_queue_draw(s.area);
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

test "a step's rounding lands exactly on the reset value, and stays inside the range" {
    const nothing = struct {
        fn f(_: *Slider, _: f64, _: u64) void {}
    }.f;
    const straighten: Config = .{ .label = "x", .min = -45, .max = 45, .step = 0.1, .on_change = nothing };
    try std.testing.expectEqual(0, onSteps(straighten, 1e-9));
    try std.testing.expectEqual(0, onSteps(straighten, 0.04));
    try std.testing.expectEqual(45, onSteps(straighten, 46));
    // A reset between the steps, as a shader's default can be.
    const param: Config = .{ .label = "x", .min = 0, .max = 1, .step = 0.01, .reset = 0.333, .on_change = nothing };
    try std.testing.expectEqual(0.333, onSteps(param, 0.33));
}

test "a notch of the wheel is a hundredth of the range, on the steps; fine is one step" {
    const nothing = struct {
        fn f(_: *Slider, _: f64, _: u64) void {}
    }.f;
    const contrast: Config = .{ .label = "x", .min = -100, .max = 100, .on_change = nothing };
    try std.testing.expectEqual(2, notch(contrast, false));
    try std.testing.expectEqual(1, notch(contrast, true));
    const sharpen: Config = .{ .label = "x", .min = 0, .max = 100, .on_change = nothing };
    try std.testing.expectEqual(1, notch(sharpen, false));
    const exposure: Config = .{ .label = "x", .min = -5, .max = 5, .step = 0.05, .on_change = nothing };
    try std.testing.expectApproxEqAbs(0.1, notch(exposure, false), 1e-9);
    const quality: Config = .{ .label = "x", .min = 50, .max = 100, .on_change = nothing };
    try std.testing.expectEqual(1, notch(quality, false));
}

test "a double-click is two presses soon after each other, in nearly one place" {
    try std.testing.expect(isSecondClick(200_000, 2));
    try std.testing.expect(isSecondClick(200_000, -4));
    try std.testing.expect(!isSecondClick(500_000, 0));
    try std.testing.expect(!isSecondClick(200_000, 20));
}

test "the thumb grabbed off centre stays where it is; the track jumps" {
    try std.testing.expectEqual(100, dragOrigin(104, 100).?);
    try std.testing.expectEqual(100, dragOrigin(92, 100).?);
    try std.testing.expectEqual(null, dragOrigin(120, 100));
}
