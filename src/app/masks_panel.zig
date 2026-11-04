//! The layers at the top of Adjust: the whole photo and its masks. Pick one and the same sliders
//! edit it. Its shape, limits and colour mixer show while it's picked; handles on the photo move it.
const std = @import("std");
const core = @import("photo-core");
const gtk = @import("gtk.zig");
const App = @import("app.zig");
const Canvas = @import("canvas.zig");
const Slider = @import("slider.zig");
const Subject = @import("subject.zig");
const Recipe = core.Recipe;
const Mask = Recipe.Mask;

const Panel = @This();

gpa: std.mem.Allocator,
app: *App,
canvas: *Canvas,
subject: ?*Subject = null,
// The photo's edits changed.
edited: *const fn () void,
// Another layer was picked, or the list changed: the sliders follow.
layer_changed: *const fn () void,
// The mask being edited; null is the whole photo.
selected: ?usize = null,
// Only the Adjust tab edits layers.
active: bool = true,
showing: bool = false,
updating: bool = false,
// Clicking a subject: the points so far, newest request first to be answered.
picking: bool = false,
points: std.ArrayList([3]f32) = .empty,
asked: u64 = 0,
waiting: bool = false,
list_shape: u64 = 0,
band: usize = 0,
rows: [Recipe.max_masks]Row = undefined,
// The layers and what the picked mask has: goes above the sliders.
widget: *anyopaque = undefined,
// The picked mask's colour mixer: goes below the sliders.
mixer_widget: *anyopaque = undefined,
whole_button: *anyopaque = undefined,
list: *anyopaque = undefined,
add_buttons: [4]*anyopaque = undefined,
pick_box: *anyopaque = undefined,
pick_button: *anyopaque = undefined,
pick_status: *anyopaque = undefined,
detail: *anyopaque = undefined,
show_button: *anyopaque = undefined,
invert_button: *anyopaque = undefined,
feather: *Slider = undefined,
blur: *Slider = undefined,
lowest: *Slider = undefined,
highest: *Slider = undefined,
hue_buttons: [hue_choices.len]*anyopaque = undefined,
band_buttons: [band_labels.len]*anyopaque = undefined,
hue: *Slider = undefined,
sat: *Slider = undefined,
light: *Slider = undefined,

const add_hint = "Click the subject. Shift-click what doesn't belong.";
const wait_hint = "Finding it\u{2026}";
const missing_hint = "Needs its download: run scripts/subject-model.py, then restart Doka.";

const Row = struct { panel: *Panel, index: usize, name: *anyopaque = undefined };

const band_labels = [_][:0]const u8{ "Reds", "Oranges", "Yellows", "Greens", "Blues", "Purples" };

// The mixer's bands (adjust.glsl), degrees and width.
const hue_choices = [_]struct { label: [:0]const u8, centre: f32, width: f32 }{
    .{ .label = "Any", .centre = 0, .width = 0 },
    .{ .label = "Reds", .centre = 25, .width = 26 },
    .{ .label = "Oranges", .centre = 60, .width = 22 },
    .{ .label = "Yellows", .centre = 100, .width = 26 },
    .{ .label = "Greens", .centre = 145, .width = 38 },
    .{ .label = "Blues", .centre = 250, .width = 45 },
    .{ .label = "Purples", .centre = 315, .width = 35 },
};

fn connect(object: *anyopaque, signal: [*:0]const u8, handler: anytype, data: ?*anyopaque) void {
    _ = gtk.g_signal_connect_data(object, signal, @ptrCast(handler), data, null, 0);
}

fn title(text: [*:0]const u8) *anyopaque {
    const l = gtk.gtk_label_new(text);
    gtk.gtk_label_set_xalign(l, 0);
    gtk.gtk_widget_add_css_class(l, "section-title");
    return l;
}

fn panelOf(s: *Slider) *Panel {
    return @ptrCast(@alignCast(s.config.ctx));
}

fn flowOfThree() *anyopaque {
    const flow = gtk.gtk_flow_box_new();
    gtk.gtk_flow_box_set_homogeneous(flow, 1);
    gtk.gtk_flow_box_set_min_children_per_line(flow, 3);
    gtk.gtk_flow_box_set_max_children_per_line(flow, 3);
    gtk.gtk_flow_box_set_selection_mode(flow, 0);
    return flow;
}

fn slider(p: *Panel, box: *anyopaque, config: Slider.Config) *Slider {
    var c = config;
    c.ctx = p;
    const s = Slider.create(p.gpa, c);
    gtk.gtk_box_append(box, s.widget);
    return s;
}

pub fn create(p: *Panel) void {
    p.canvas.on_mask = .{ .ctx = p, .f = onPlaced };
    p.canvas.on_pick = .{ .ctx = p, .f = onPicked };
    for (&p.rows, 0..) |*row, i| row.* = .{ .panel = p, .index = i };
    const box = gtk.gtk_box_new(gtk.vertical, 8);
    gtk.gtk_box_append(box, title("Layers"));
    const layers = gtk.gtk_box_new(gtk.vertical, 2);
    p.whole_button = layerButton("Whole photo");
    gtk.gtk_widget_set_tooltip_text(p.whole_button, "The sliders edit the whole photo");
    connect(p.whole_button, "clicked", &onWhole, p);
    gtk.gtk_box_append(layers, p.whole_button);
    p.list = gtk.gtk_box_new(gtk.vertical, 2);
    gtk.gtk_box_append(layers, p.list);
    gtk.gtk_box_append(box, layers);

    const adders = gtk.gtk_flow_box_new();
    gtk.gtk_flow_box_set_homogeneous(adders, 1);
    gtk.gtk_flow_box_set_min_children_per_line(adders, 2);
    gtk.gtk_flow_box_set_max_children_per_line(adders, 2);
    gtk.gtk_flow_box_set_selection_mode(adders, 0);
    for (&p.add_buttons, [_][*:0]const u8{ "+ Subject", "+ Gradient", "+ Circle", "+ Range" }, [_][*:0]const u8{
        "Click a person or thing to mask it",
        "A mask that fades across the photo",
        "A mask inside a circle",
        "A mask by brightness or colour alone",
    }) |*b, label, tip| {
        b.* = gtk.gtk_button_new_with_label(label);
        gtk.gtk_widget_add_css_class(b.*, "quiet");
        gtk.gtk_widget_set_tooltip_text(b.*, tip);
        gtk.gtk_flow_box_append(adders, b.*);
    }
    connect(p.add_buttons[0], "clicked", &onAddSubject, p);
    connect(p.add_buttons[1], "clicked", &onAddLinear, p);
    connect(p.add_buttons[2], "clicked", &onAddRadial, p);
    connect(p.add_buttons[3], "clicked", &onAddRange, p);
    gtk.gtk_box_append(box, adders);

    p.detail = gtk.gtk_box_new(gtk.vertical, 8);
    gtk.gtk_widget_add_css_class(p.detail, "mask-detail");
    gtk.gtk_box_append(p.detail, title("Mask"));
    const switches = gtk.gtk_box_new(gtk.horizontal, 4);
    p.show_button = gtk.gtk_toggle_button_new_with_label("Show mask");
    gtk.gtk_widget_set_tooltip_text(p.show_button, "Paint this mask red on the photo, to see where it is. Never exported.");
    p.invert_button = gtk.gtk_toggle_button_new_with_label("Invert");
    gtk.gtk_widget_set_tooltip_text(p.invert_button, "Everything but what's selected");
    const remove = gtk.gtk_button_new_with_label("Remove");
    for ([_]*anyopaque{ p.show_button, p.invert_button, remove }) |b| {
        gtk.gtk_widget_add_css_class(b, "quiet");
        gtk.gtk_widget_set_hexpand(b, 1);
        gtk.gtk_box_append(switches, b);
    }
    connect(p.show_button, "toggled", &onShow, p);
    connect(p.invert_button, "toggled", &onInvert, p);
    connect(remove, "clicked", &onRemove, p);
    gtk.gtk_box_append(p.detail, switches);
    p.pick_box = gtk.gtk_box_new(gtk.vertical, 4);
    p.pick_button = gtk.gtk_toggle_button_new_with_label("Click on the photo");
    gtk.gtk_widget_add_css_class(p.pick_button, "quiet");
    connect(p.pick_button, "toggled", &onPickToggled, p);
    gtk.gtk_box_append(p.pick_box, p.pick_button);
    p.pick_status = gtk.gtk_label_new(add_hint);
    gtk.gtk_label_set_xalign(p.pick_status, 0);
    gtk.gtk_label_set_wrap(p.pick_status, 1);
    gtk.gtk_widget_add_css_class(p.pick_status, "faint");
    gtk.gtk_box_append(p.pick_box, p.pick_status);
    gtk.gtk_box_append(p.detail, p.pick_box);
    p.feather = p.slider(p.detail, .{ .label = "Feather", .min = 0, .max = 100, .reset = 50, .unit = .plain, .on_change = onFeather });
    p.blur = p.slider(p.detail, .{ .label = "Blur", .min = 0, .max = 100, .unit = .plain, .on_change = onBlur });
    p.lowest = p.slider(p.detail, .{ .label = "Darkest tone", .min = 0, .max = 100, .unit = .plain, .on_change = onLowest });
    p.highest = p.slider(p.detail, .{ .label = "Brightest tone", .min = 0, .max = 100, .reset = 100, .unit = .plain, .on_change = onHighest });
    const limit = gtk.gtk_label_new("Only this colour");
    gtk.gtk_label_set_xalign(limit, 0);
    gtk.gtk_widget_add_css_class(limit, "slider-label");
    gtk.gtk_box_append(p.detail, limit);
    const hues = flowOfThree();
    for (&p.hue_buttons, hue_choices, 0..) |*b, choice, i| {
        b.* = gtk.gtk_toggle_button_new_with_label(choice.label);
        if (i > 0) gtk.gtk_toggle_button_set_group(b.*, p.hue_buttons[0]);
        gtk.gtk_flow_box_append(hues, b.*);
    }
    gtk.gtk_toggle_button_set_active(p.hue_buttons[0], 1);
    for (p.hue_buttons) |b| connect(b, "toggled", &onHueLimit, p);
    gtk.gtk_box_append(p.detail, hues);
    gtk.gtk_box_append(box, p.detail);
    p.widget = box;

    const colour = gtk.gtk_box_new(gtk.vertical, 8);
    const bands = flowOfThree();
    for (&p.band_buttons, band_labels, 0..) |*b, label, i| {
        b.* = gtk.gtk_toggle_button_new_with_label(label);
        if (i > 0) gtk.gtk_toggle_button_set_group(b.*, p.band_buttons[0]);
        gtk.gtk_flow_box_append(bands, b.*);
    }
    gtk.gtk_toggle_button_set_active(p.band_buttons[0], 1);
    for (p.band_buttons) |b| connect(b, "toggled", &onBand, p);
    gtk.gtk_box_append(colour, bands);
    p.hue = p.slider(colour, .{ .label = "Hue", .min = -100, .max = 100, .on_change = onMixHue });
    p.sat = p.slider(colour, .{ .label = "Saturation", .min = -100, .max = 100, .on_change = onMixSat });
    p.light = p.slider(colour, .{ .label = "Lightness", .min = -100, .max = 100, .on_change = onMixLight });
    p.mixer_widget = gtk.gtk_expander_new("Colour mixer");
    gtk.gtk_widget_add_css_class(p.mixer_widget, "section-title");
    gtk.gtk_expander_set_child(p.mixer_widget, colour);
}

fn layerButton(text: [*:0]const u8) *anyopaque {
    const b = gtk.gtk_button_new();
    const l = gtk.gtk_label_new(text);
    gtk.gtk_label_set_xalign(l, 0);
    gtk.gtk_label_set_ellipsize(l, gtk.ellipsize_end);
    gtk.gtk_button_set_child(b, l);
    gtk.gtk_widget_add_css_class(b, "layer");
    gtk.gtk_widget_set_hexpand(b, 1);
    return b;
}

fn setOn(widget: *anyopaque, on: bool) void {
    if (on) gtk.gtk_widget_add_css_class(widget, "on") else gtk.gtk_widget_remove_css_class(widget, "on");
}

// ---- Following the recipe ----

/// The picked mask in `r`, or null for the whole photo.
pub fn layer(p: *const Panel, r: Recipe) ?Mask {
    const i = p.selected orelse return null;
    return if (i < r.masks.len) r.masks[i] else null;
}

/// A new photo: back to the whole of it.
pub fn reset(p: *Panel) void {
    p.selected = null;
    p.showing = false;
    p.stopPicking();
}

fn stopPicking(p: *Panel) void {
    p.picking = false;
    p.waiting = false;
    // A late answer for what's no longer asked is dropped.
    p.asked += 1;
    p.points.clearRetainingCapacity();
    p.canvas.setPicking(false);
}

pub fn setActive(p: *Panel, active: bool) void {
    p.active = active;
    if (!active) p.stopPicking();
    p.pushToCanvas();
}

fn pushToCanvas(p: *Panel) void {
    const on = if (p.active) p.selected else null;
    p.canvas.active_mask = on;
    p.canvas.show_mask = if (p.showing) on else null;
    p.canvas.redraw();
}

/// Everything here follows the recipe: undo, Claude, another photo.
pub fn sync(p: *Panel, r: Recipe) void {
    p.updating = true;
    defer p.updating = false;
    if (p.selected) |i| if (i >= r.masks.len) {
        p.selected = null;
    };
    if (p.layer(r) == null or p.layer(r).?.shape != .subject) if (p.picking) p.stopPicking();
    p.syncList(r);
    setOn(p.whole_button, p.selected == null);
    for (0..r.masks.len) |i| setOn(gtk.gtk_widget_get_parent(p.rows[i].name), p.selected == i);
    for (p.add_buttons) |b| gtk.gtk_widget_set_sensitive(b, @intFromBool(r.masks.len < Recipe.max_masks));
    if (!p.subjectReady()) {
        gtk.gtk_widget_set_sensitive(p.add_buttons[0], 0);
        gtk.gtk_widget_set_tooltip_text(p.add_buttons[0], missing_hint);
    }
    const m = p.layer(r);
    gtk.gtk_widget_set_visible(p.detail, @intFromBool(m != null));
    gtk.gtk_widget_set_visible(p.mixer_widget, @intFromBool(m != null));
    if (m) |mask| {
        gtk.gtk_toggle_button_set_active(p.show_button, @intFromBool(p.showing));
        gtk.gtk_toggle_button_set_active(p.invert_button, @intFromBool(mask.invert));
        gtk.gtk_widget_set_visible(p.feather.widget, @intFromBool(mask.shape == .radial));
        gtk.gtk_widget_set_visible(p.pick_box, @intFromBool(mask.shape == .subject));
        gtk.gtk_toggle_button_set_active(p.pick_button, @intFromBool(p.picking));
        gtk.gtk_widget_set_sensitive(p.pick_button, @intFromBool(p.subjectReady()));
        gtk.gtk_label_set_text(p.pick_status, if (!p.subjectReady()) missing_hint else if (p.waiting) wait_hint else add_hint);
        p.feather.set(mask.feather);
        p.blur.set(mask.blur);
        p.lowest.set(mask.brightness.min);
        p.highest.set(mask.brightness.max);
        for (p.hue_buttons, hue_choices) |b, choice| {
            const here = choice.width == mask.hue.width and (choice.width == 0 or choice.centre == mask.hue.centre);
            gtk.gtk_toggle_button_set_active(b, @intFromBool(here));
        }
        const band = p.currentBand(mask);
        p.hue.set(band.hue);
        p.sat.set(band.sat);
        p.light.set(band.light);
    } else p.showing = false;
    p.pushToCanvas();
}

fn subjectReady(p: *const Panel) bool {
    const s = p.subject orelse return false;
    return s.available();
}

fn currentBand(p: *const Panel, m: Mask) Recipe.Band {
    return bandOf(&@constCast(&m).colour, p.band).*;
}

fn bandOf(c: *Recipe.Colour, i: usize) *Recipe.Band {
    return switch (i) {
        0 => &c.reds,
        1 => &c.oranges,
        2 => &c.yellows,
        3 => &c.greens,
        4 => &c.blues,
        else => &c.purples,
    };
}

// The rows are made again only when there's a different list, not on each slider's move.
fn syncList(p: *Panel, r: Recipe) void {
    var h = std.hash.Wyhash.init(0);
    for (r.masks) |m| {
        h.update(m.name);
        h.update(&.{ @intFromBool(m.enabled), 0xff });
    }
    const shape = h.final() +% r.masks.len;
    if (shape == p.list_shape) return;
    p.list_shape = shape;
    while (gtk.gtk_widget_get_first_child(p.list)) |child| gtk.gtk_box_remove(p.list, child);
    for (r.masks, 0..) |m, i| {
        var buf: [64]u8 = undefined;
        const name = std.fmt.bufPrintZ(&buf, "{s}", .{if (m.name.len > 0) m.name else shapeName(m.shape)}) catch "Mask";
        const row = gtk.gtk_box_new(gtk.horizontal, 0);
        gtk.gtk_widget_add_css_class(row, "layer-row");
        const pick = layerButton(name);
        if (!m.enabled) gtk.gtk_widget_set_opacity(pick, 0.5);
        connect(pick, "clicked", &onPick, &p.rows[i]);
        p.rows[i].name = pick;
        const eye = gtk.gtk_button_new_from_icon_name(if (m.enabled) "view-reveal-symbolic" else "view-conceal-symbolic");
        gtk.gtk_widget_add_css_class(eye, "icon");
        gtk.gtk_widget_set_tooltip_text(eye, if (m.enabled) "Switch this mask off" else "Switch this mask on");
        connect(eye, "clicked", &onEye, &p.rows[i]);
        gtk.gtk_box_append(row, pick);
        gtk.gtk_box_append(row, eye);
        gtk.gtk_box_append(p.list, row);
    }
}

fn shapeName(shape: Mask.Shape) []const u8 {
    return switch (shape) {
        .whole => "Range",
        .linear => "Gradient",
        .radial => "Circle",
        .subject => "Subject",
    };
}

// ---- Changing the recipe ----

const Editing = struct { masks: []Mask, mask: *Mask };

// The list to change, with the picked mask.
fn editing(p: *Panel, a: std.mem.Allocator) ?Editing {
    const r = p.app.recipe(a) catch return null;
    const i = p.selected orelse return null;
    if (i >= r.masks.len) return null;
    const masks = a.dupe(Mask, r.masks) catch return null;
    return .{ .masks = masks, .mask = &masks[i] };
}

fn commit(p: *Panel, a: std.mem.Allocator, masks: []const Mask, gesture: u64) void {
    const json = std.json.Stringify.valueAlloc(a, .{ .masks = masks }, .{}) catch return;
    p.app.edit(json, gesture) catch return;
    p.edited();
}

fn resync(p: *Panel) void {
    p.layer_changed();
}

const Scratch = std.heap.ArenaAllocator;

/// A slider of the Light and Colour sections moved, with this mask picked.
pub fn setEdit(p: *Panel, field: []const u8, v: f64, gesture: u64) void {
    var scratch: Scratch = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const e = p.editing(a) orelse return;
    inline for (@typeInfo(Recipe.Edits).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, field)) @field(e.mask.edits, f.name) = @floatCast(v);
    }
    p.commit(a, e.masks, gesture);
}

/// "Reset sliders" with this mask picked: its edits; it stays where it is.
pub fn resetEdits(p: *Panel) void {
    var scratch: Scratch = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const e = p.editing(a) orelse return;
    e.mask.edits = .{};
    e.mask.colour = .{};
    e.mask.blur = 0;
    p.commit(a, e.masks, 0);
    p.resync();
}

fn onPlaced(ctx: *anyopaque, index: usize, place: Mask.Place, gesture: u64) void {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    var scratch: Scratch = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const r = p.app.recipe(a) catch return;
    if (index >= r.masks.len) return;
    const masks = a.dupe(Mask, r.masks) catch return;
    const m = &masks[index];
    m.from = place.from;
    m.to = place.to;
    m.centre = place.centre;
    m.radius = place.radius;
    p.commit(a, masks, gesture);
}

fn add(p: *Panel, shape: Mask.Shape) void {
    var scratch: Scratch = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const r = p.app.recipe(a) catch return;
    if (r.masks.len >= Recipe.max_masks) return;
    var same: usize = 1;
    for (r.masks) |m| {
        if (m.shape == shape) same += 1;
    }
    var mask: Mask = .{ .shape = shape };
    mask.name = if (same == 1) shapeName(shape) else std.fmt.allocPrint(a, "{s} {d}", .{ shapeName(shape), same }) catch shapeName(shape);
    // A true circle, whatever the photo's shape.
    if (p.canvas.pipeline) |*pipe| if (pipe.width > 0 and pipe.height > 0) {
        const w: f32 = @floatFromInt(pipe.width);
        const h: f32 = @floatFromInt(pipe.height);
        const edge = 0.25 * @min(w, h);
        mask.radius = .{ edge / w, edge / h };
    };
    const masks = a.alloc(Mask, r.masks.len + 1) catch return;
    @memcpy(masks[0..r.masks.len], r.masks);
    masks[r.masks.len] = mask;
    p.selected = r.masks.len;
    p.commit(a, masks, 0);
    p.resync();
}

fn onAddSubject(_: *anyopaque, ctx: *Panel) callconv(.c) void {
    ctx.showing = true;
    ctx.picking = true;
    ctx.points.clearRetainingCapacity();
    ctx.canvas.setPicking(true);
    ctx.add(.subject);
}

// Asks for the mask at the points so far: the newest question's answer is the one that counts.
fn onPicked(ctx: *anyopaque, at: [2]f32, keep: bool) void {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    const subject = p.subject orelse return;
    var scratch: Scratch = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const e = p.editing(a) orelse return;
    if (e.mask.shape != .subject) return;
    const f = &(p.app.folder orelse return);
    const rel = p.app.currentRel() orelse return;
    if (p.points.items.len == 0) p.points.appendSlice(p.gpa, e.mask.points) catch return;
    if (p.points.items.len >= Recipe.max_mask_points) return;
    p.points.append(p.gpa, .{ at[0], at[1], if (keep) 1 else 0 }) catch return;
    const path = std.fmt.allocPrint(a, "{s}/{s}", .{ f.path, rel }) catch return;
    p.asked += 1;
    p.waiting = true;
    subject.ask(.{ .path = path, .root = f.path, .rel = rel, .points = p.points.items, .ctx = p, .tag = p.asked, .done = onFound }) catch |err| {
        std.log.err("subject: {t}", .{err});
        p.waiting = false;
    };
    p.resync();
}

fn onFound(ctx: *anyopaque, tag: u64, rel: []const u8, points: []const [3]f32, file: ?[]const u8, failure: ?anyerror) void {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    if (tag != p.asked) return;
    p.waiting = false;
    defer p.resync();
    const name = file orelse {
        std.log.err("subject: {t}", .{failure.?});
        return;
    };
    const current = p.app.currentRel() orelse return;
    if (!std.mem.eql(u8, current, rel)) return;
    var scratch: Scratch = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const e = p.editing(a) orelse return;
    if (e.mask.shape != .subject) return;
    e.mask.file = name;
    e.mask.points = points;
    p.commit(a, e.masks, 0);
    p.points.clearRetainingCapacity();
}

fn onPickToggled(button: *anyopaque, p: *Panel) callconv(.c) void {
    if (p.updating) return;
    p.picking = gtk.gtk_toggle_button_get_active(button) != 0;
    p.canvas.setPicking(p.picking);
    p.showing = p.picking;
    p.resync();
}

fn onAddLinear(_: *anyopaque, ctx: *Panel) callconv(.c) void {
    ctx.add(.linear);
}
fn onAddRadial(_: *anyopaque, ctx: *Panel) callconv(.c) void {
    ctx.add(.radial);
}
fn onAddRange(_: *anyopaque, ctx: *Panel) callconv(.c) void {
    ctx.add(.whole);
}

fn onWhole(_: *anyopaque, p: *Panel) callconv(.c) void {
    p.stopPicking();
    p.selected = null;
    p.resync();
}

fn onPick(_: *anyopaque, row: *Row) callconv(.c) void {
    if (row.panel.selected != row.index) row.panel.stopPicking();
    row.panel.selected = row.index;
    row.panel.resync();
}

fn onEye(_: *anyopaque, row: *Row) callconv(.c) void {
    const p = row.panel;
    var scratch: Scratch = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const r = p.app.recipe(a) catch return;
    if (row.index >= r.masks.len) return;
    const masks = a.dupe(Mask, r.masks) catch return;
    masks[row.index].enabled = !masks[row.index].enabled;
    p.commit(a, masks, 0);
    p.resync();
}

fn onRemove(_: *anyopaque, p: *Panel) callconv(.c) void {
    var scratch: Scratch = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const r = p.app.recipe(a) catch return;
    const i = p.selected orelse return;
    if (i >= r.masks.len) return;
    const masks = a.alloc(Mask, r.masks.len - 1) catch return;
    @memcpy(masks[0..i], r.masks[0..i]);
    @memcpy(masks[i..], r.masks[i + 1 ..]);
    p.stopPicking();
    p.selected = null;
    p.showing = false;
    p.commit(a, masks, 0);
    p.resync();
}

fn onShow(button: *anyopaque, p: *Panel) callconv(.c) void {
    if (p.updating) return;
    p.showing = gtk.gtk_toggle_button_get_active(button) != 0;
    p.pushToCanvas();
}

fn onInvert(button: *anyopaque, p: *Panel) callconv(.c) void {
    if (p.updating) return;
    var scratch: Scratch = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const e = p.editing(a) orelse return;
    e.mask.invert = gtk.gtk_toggle_button_get_active(button) != 0;
    p.commit(a, e.masks, 0);
}

fn onFeather(s: *Slider, v: f64, g: u64) void {
    const p = panelOf(s);
    var scratch: Scratch = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const e = p.editing(a) orelse return;
    e.mask.feather = @floatCast(v);
    p.commit(a, e.masks, g);
}

fn onBlur(s: *Slider, v: f64, g: u64) void {
    const p = panelOf(s);
    var scratch: Scratch = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const e = p.editing(a) orelse return;
    e.mask.blur = @floatCast(v);
    p.commit(a, e.masks, g);
}

fn onLowest(s: *Slider, v: f64, g: u64) void {
    const p = panelOf(s);
    var scratch: Scratch = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const e = p.editing(a) orelse return;
    e.mask.brightness.min = @floatCast(@min(v, e.mask.brightness.max));
    p.commit(a, e.masks, g);
    // Stopped at the other end: the same drag goes on.
    const held = s.gesture;
    s.set(e.mask.brightness.min);
    s.gesture = held;
}

fn onHighest(s: *Slider, v: f64, g: u64) void {
    const p = panelOf(s);
    var scratch: Scratch = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const e = p.editing(a) orelse return;
    e.mask.brightness.max = @floatCast(@max(v, e.mask.brightness.min));
    p.commit(a, e.masks, g);
    const held = s.gesture;
    s.set(e.mask.brightness.max);
    s.gesture = held;
}

fn onHueLimit(button: *anyopaque, p: *Panel) callconv(.c) void {
    if (p.updating or gtk.gtk_toggle_button_get_active(button) == 0) return;
    const index = for (p.hue_buttons, 0..) |b, i| {
        if (b == button) break i;
    } else return;
    var scratch: Scratch = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const e = p.editing(a) orelse return;
    e.mask.hue = .{ .centre = hue_choices[index].centre, .width = hue_choices[index].width };
    p.commit(a, e.masks, 0);
}

fn onBand(button: *anyopaque, p: *Panel) callconv(.c) void {
    if (gtk.gtk_toggle_button_get_active(button) == 0) return;
    for (p.band_buttons, 0..) |b, i| if (b == button) {
        p.band = i;
    };
    if (p.updating) return;
    p.resync();
}

fn mix(s: *Slider, comptime what: []const u8, v: f64, g: u64) void {
    const p = panelOf(s);
    var scratch: Scratch = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const e = p.editing(a) orelse return;
    @field(bandOf(&e.mask.colour, p.band), what) = @floatCast(v);
    p.commit(a, e.masks, g);
}

fn onMixHue(s: *Slider, v: f64, g: u64) void {
    mix(s, "hue", v, g);
}
fn onMixSat(s: *Slider, v: f64, g: u64) void {
    mix(s, "sat", v, g);
}
fn onMixLight(s: *Slider, v: f64, g: u64) void {
    mix(s, "light", v, g);
}
