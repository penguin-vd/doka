//! The Looks tab: a grid of looks drawn on the current photo, the look's strength, grain, halation
//! and vignette, the colour mixer (folded away), and the photo's shaders in order.
const std = @import("std");
const core = @import("photo-core");
const gtk = @import("gtk.zig");
const gl = @import("gl.zig");
const App = @import("app.zig");
const Canvas = @import("canvas.zig");
const Looks = @import("looks.zig");
const Pipeline = @import("pipeline.zig");
const Cube = @import("cube.zig");
const Slider = @import("slider.zig");
const Library = @import("library.zig");
const Recipe = core.Recipe;

const Panel = @This();

const thumb_width = 160;
const band_names = [_][:0]const u8{ "reds", "oranges", "yellows", "greens", "blues", "purples" };
const band_labels = [_][*:0]const u8{ "Reds", "Oranges", "Yellows", "Greens", "Blues", "Purples" };

gpa: std.mem.Allocator,
app: *App,
canvas: *Canvas,
library: *Library,
edited: *const fn () void,
widget: *anyopaque = undefined,
grid: *anyopaque = undefined,
strength: *Slider = undefined,
grain: *Slider = undefined,
grain_size: *Slider = undefined,
halation: *Slider = undefined,
vignette: *Slider = undefined,
hue: *Slider = undefined,
sat: *Slider = undefined,
light: *Slider = undefined,
band: usize = 0,
band_buttons: [6]*anyopaque = undefined,
looks: std.ArrayList(LookCell) = .empty,
// A look a preview is waiting to be drawn for.
drawing: ?usize = null,
drawn_for: ?u64 = null,
idle: c_uint = 0,
shader_box: *anyopaque = undefined,
picker: *anyopaque = undefined,
picker_names: std.ArrayList([:0]u8) = .empty,
shader_shape: u64 = 0,
shader_sliders: std.ArrayList(ShaderSlider) = .empty,
open: std.StringHashMapUnmanaged(void) = .empty,
updating: bool = false,
visible: bool = false,
preview: ?Pipeline = null,
preview_looks: *Looks,
source_ready: bool = false,

const LookCell = struct { name: [:0]u8, button: *anyopaque, picture: *anyopaque, panel: *Panel };
const ShaderSlider = struct { slider: *Slider, index: usize, param: ?[:0]u8, default: f64, panel: *Panel };

fn connect(object: *anyopaque, signal: [*:0]const u8, handler: anytype, data: ?*anyopaque) void {
    _ = gtk.g_signal_connect_data(object, signal, @ptrCast(handler), data, null, 0);
}

fn title(text: [*:0]const u8) *anyopaque {
    const l = gtk.gtk_label_new(text);
    gtk.gtk_label_set_xalign(l, 0);
    gtk.gtk_widget_add_css_class(l, "section-title");
    return l;
}

fn plainEdit(p: *Panel, json: []const u8, gesture: u64) void {
    p.app.edit(json, gesture) catch return;
    p.edited();
}

fn fieldSlider(p: *Panel, box: *anyopaque, config: Slider.Config) *Slider {
    var c = config;
    c.ctx = p;
    const s = Slider.create(p.gpa, c);
    gtk.gtk_box_append(box, s.widget);
    return s;
}

fn panelOf(s: *Slider) *Panel {
    return @ptrCast(@alignCast(s.config.ctx));
}

fn patch(comptime fmt: []const u8) *const fn (*Slider, f64, u64) void {
    return struct {
        fn f(s: *Slider, v: f64, g: u64) void {
            var buf: [96]u8 = undefined;
            panelOf(s).plainEdit(std.fmt.bufPrint(&buf, fmt, .{v}) catch return, g);
        }
    }.f;
}

fn mixer(s: *Slider, what: []const u8, v: f64, g: u64) void {
    const p = panelOf(s);
    var buf: [96]u8 = undefined;
    p.plainEdit(std.fmt.bufPrint(&buf, "{{\"colour\":{{\"{s}\":{{\"{s}\":{d}}}}}}}", .{ band_names[p.band], what, v }) catch return, g);
}

fn onHue(s: *Slider, v: f64, g: u64) void {
    mixer(s, "hue", v, g);
}
fn onSat(s: *Slider, v: f64, g: u64) void {
    mixer(s, "sat", v, g);
}
fn onLight(s: *Slider, v: f64, g: u64) void {
    mixer(s, "light", v, g);
}

pub fn create(p: *Panel) *anyopaque {
    const box = gtk.gtk_box_new(gtk.vertical, 8);
    gtk.gtk_widget_add_css_class(box, "panel-body");
    gtk.gtk_box_append(box, title("Look"));
    p.grid = gtk.gtk_flow_box_new();
    gtk.gtk_flow_box_set_homogeneous(p.grid, 1);
    gtk.gtk_flow_box_set_min_children_per_line(p.grid, 3);
    gtk.gtk_flow_box_set_max_children_per_line(p.grid, 3);
    gtk.gtk_flow_box_set_selection_mode(p.grid, 0);
    gtk.gtk_box_append(box, p.grid);
    p.strength = p.fieldSlider(box, .{ .label = "Strength", .min = 0, .max = 100, .reset = 100, .unit = .percent, .on_change = patch("{{\"look\":{{\"strength\":{d}}}}}") });
    gtk.gtk_box_append(box, title("Film"));
    p.grain = p.fieldSlider(box, .{ .label = "Grain", .min = 0, .max = 100, .unit = .plain, .on_change = patch("{{\"grain\":{{\"amount\":{d}}}}}") });
    p.grain_size = p.fieldSlider(box, .{ .label = "Grain size", .min = 0, .max = 100, .reset = 50, .unit = .plain, .on_change = patch("{{\"grain\":{{\"size\":{d}}}}}") });
    p.halation = p.fieldSlider(box, .{ .label = "Halation", .min = 0, .max = 100, .unit = .plain, .on_change = patch("{{\"halation\":{d}}}") });
    p.vignette = p.fieldSlider(box, .{ .label = "Vignette", .min = 0, .max = 100, .unit = .plain, .on_change = patch("{{\"vignette\":{d}}}") });

    const colour = gtk.gtk_box_new(gtk.vertical, 8);
    const bands = gtk.gtk_flow_box_new();
    gtk.gtk_flow_box_set_homogeneous(bands, 1);
    gtk.gtk_flow_box_set_min_children_per_line(bands, 3);
    gtk.gtk_flow_box_set_max_children_per_line(bands, 3);
    gtk.gtk_flow_box_set_selection_mode(bands, 0);
    for (&p.band_buttons, band_labels, 0..) |*b, label, i| {
        b.* = gtk.gtk_toggle_button_new_with_label(label);
        if (i > 0) gtk.gtk_toggle_button_set_group(b.*, p.band_buttons[0]);
        gtk.gtk_flow_box_append(bands, b.*);
    }
    // Before listening: the sliders this moves don't exist yet.
    gtk.gtk_toggle_button_set_active(p.band_buttons[0], 1);
    for (p.band_buttons) |b| connect(b, "toggled", &onBand, p);
    gtk.gtk_box_append(colour, bands);
    p.hue = p.fieldSlider(colour, .{ .label = "Hue", .min = -100, .max = 100, .on_change = onHue });
    p.sat = p.fieldSlider(colour, .{ .label = "Saturation", .min = -100, .max = 100, .on_change = onSat });
    p.light = p.fieldSlider(colour, .{ .label = "Lightness", .min = -100, .max = 100, .on_change = onLight });
    const reset = gtk.gtk_button_new_with_label("Reset colours");
    gtk.gtk_widget_add_css_class(reset, "quiet");
    gtk.gtk_widget_set_halign(reset, gtk.align_start);
    connect(reset, "clicked", &onResetColours, p);
    gtk.gtk_box_append(colour, reset);
    const fold = gtk.gtk_expander_new("Colour");
    gtk.gtk_widget_add_css_class(fold, "section-title");
    gtk.gtk_expander_set_child(fold, colour);
    gtk.gtk_box_append(box, fold);

    gtk.gtk_box_append(box, title("Shaders"));
    p.shader_box = gtk.gtk_box_new(gtk.vertical, 6);
    gtk.gtk_box_append(box, p.shader_box);
    const none = [_]?[*:0]const u8{ "Add a shader…", null };
    p.picker = gtk.gtk_drop_down_new_from_strings(&none);
    connect(p.picker, "notify::selected", &onPicked, p);
    gtk.gtk_box_append(box, p.picker);

    const scrolled = gtk.gtk_scrolled_window_new();
    gtk.gtk_scrolled_window_set_policy(scrolled, 2, 1);
    gtk.gtk_scrolled_window_set_child(scrolled, box);
    gtk.gtk_widget_set_vexpand(scrolled, 1);
    p.widget = scrolled;
    p.reloadLooks();
    return scrolled;
}

fn onBand(_: *anyopaque, ctx: ?*anyopaque) callconv(.c) void {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    for (p.band_buttons, 0..) |b, i| if (gtk.gtk_toggle_button_get_active(b) != 0) {
        p.band = i;
    };
    p.update();
}

fn onResetColours(_: *anyopaque, ctx: ?*anyopaque) callconv(.c) void {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    p.plainEdit("{\"colour\":null}", 0);
    p.update();
}

fn onLookClicked(_: *anyopaque, ctx: ?*anyopaque) callconv(.c) void {
    const cell: *LookCell = @ptrCast(@alignCast(ctx));
    const p = cell.panel;
    var scratch: std.heap.ArenaAllocator = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const r = p.app.recipe(a) catch return;
    const strength: f32 = if (std.mem.eql(u8, r.look.name, Recipe.no_look)) 100 else r.look.strength;
    p.plainEdit(std.fmt.allocPrint(a, "{{\"look\":{{\"name\":{f},\"strength\":{d}}}}}", .{ std.json.fmt(@as([]const u8, cell.name), .{}), strength }) catch return, 0);
    p.update();
}

/// The looks folder changed, or the panel's just been made.
pub fn reloadLooks(p: *Panel) void {
    gtk.gtk_flow_box_remove_all(p.grid);
    for (p.looks.items) |c| p.gpa.free(c.name);
    p.looks.clearRetainingCapacity();
    p.drawn_for = null;
    var scratch: std.heap.ArenaAllocator = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const names = p.library.lookNames(a) catch return;
    p.looks.ensureTotalCapacity(p.gpa, names.len + 1) catch return;
    p.addLook(Recipe.no_look, "None");
    for (names) |n| {
        const t = a.dupeZ(u8, p.library.lookTitle(a, n)) catch continue;
        p.addLook(n, t);
    }
}

fn addLook(p: *Panel, name: []const u8, label_text: [:0]const u8) void {
    const cell = p.looks.addOneAssumeCapacity();
    const button = gtk.gtk_button_new_with_label("");
    gtk.gtk_widget_add_css_class(button, "look");
    const inner = gtk.gtk_box_new(gtk.vertical, 3);
    const picture = gtk.gtk_picture_new();
    gtk.gtk_widget_set_size_request(picture, 70, 47);
    gtk.gtk_picture_set_content_fit(picture, gtk.fit_contain);
    const label = gtk.gtk_label_new(label_text);
    gtk.gtk_label_set_wrap(label, 1);
    gtk.gtk_widget_add_css_class(label, "look-name");
    gtk.gtk_box_append(inner, picture);
    gtk.gtk_box_append(inner, label);
    gtk.gtk_button_set_child(button, inner);
    cell.* = .{ .name = p.gpa.dupeZ(u8, name) catch unreachable, .button = button, .picture = picture, .panel = p };
    connect(button, "clicked", &onLookClicked, cell);
    gtk.gtk_flow_box_append(p.grid, button);
}

/// The tab opened or closed.
pub fn setVisible(p: *Panel, v: bool) void {
    p.visible = v;
    if (v) {
        p.update();
        p.maybeDrawPreviews();
    }
}

/// After each frame: the previews follow the photo and its crop.
pub fn maybeDrawPreviews(p: *Panel) void {
    if (!p.visible or p.drawing != null) return;
    const rel = p.canvas.rel orelse return;
    var key: std.hash.Wyhash = .init(0);
    key.update(rel);
    key.update(std.mem.asBytes(&p.canvas.recipe.crop.rect));
    key.update(std.mem.asBytes(&p.canvas.recipe.crop.rotate));
    key.update(std.mem.asBytes(&p.looks.items.len));
    const k = key.final();
    if (p.drawn_for == k) return;
    p.drawn_for = k;
    p.source_ready = false;
    p.drawing = 0;
    p.resume_();
}

/// A look finished parsing: on with the previews, if they were waiting for it.
pub fn resume_(p: *Panel) void {
    if (p.drawing != null and p.idle == 0) p.idle = gtk.g_idle_add(onIdleDraw, p);
}

// One look per pass of the main loop, so the window keeps moving. A look that isn't parsed yet ends
// this run; its parser brings us back.
fn onIdleDraw(ctx: ?*anyopaque) callconv(.c) c_int {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    const i = p.drawing orelse {
        p.idle = 0;
        return gtk.source_remove;
    };
    // The photo moved on: start over from the next frame.
    if (i >= p.looks.items.len or !p.visible) {
        p.drawing = null;
        p.idle = 0;
        if (!p.visible) p.drawn_for = null;
        return gtk.source_remove;
    }
    const cell = &p.looks.items[i];
    const cube: ?*const Cube = if (std.mem.eql(u8, cell.name, Recipe.no_look)) null else switch (p.preview_looks.find(cell.name)) {
        .loading => {
            p.idle = 0;
            return gtk.source_remove;
        },
        .missing => {
            p.drawing = i + 1;
            return gtk.continue_;
        },
        .ready => |c| c,
    };
    p.drawPreview(cell, cube) catch {};
    p.drawing = i + 1;
    return gtk.continue_;
}

// In a pipeline of its own: the photo on screen keeps its look, whatever's being previewed.
fn drawPreview(p: *Panel, cell: *LookCell, cube: ?*const Cube) !void {
    if (!p.canvas.makeCurrent()) return error.NoOpenGL;
    if (p.preview == null) p.preview = try Pipeline.init(p.gpa, p.canvas.pipeline.?.es);
    const pipe = &p.preview.?;
    if (!p.source_ready) {
        const entry = p.canvas.photos.lookup(p.canvas.rel orelse return error.NoPhoto, Canvas.preview_edge) orelse return error.NoPhoto;
        try pipe.setSource(@intCast(entry.linear.width), @intCast(entry.linear.height), entry.linear.rgb.ptr);
        p.source_ready = true;
    }
    var r = p.canvas.recipe;
    r.look = .{ .name = cell.name, .strength = 100 };
    r.shaders = &.{};
    r.grain.amount = 0;
    pipe.setLook(cube);
    const size = pipe.outputSize(r, false);
    const w: c_int = thumb_width;
    const h: c_int = @max(1, @divFloor(thumb_width * size[1], size[0]));
    var t = try Pipeline.target(w, h, gl.RGBA8, gl.UNSIGNED_BYTE);
    defer t.free();
    pipe.render(r, .{ .fbo = t.fbo, .width = w, .height = h });
    gl.glBindFramebuffer(gl.FRAMEBUFFER, t.fbo);
    const px = try p.gpa.alloc(u8, @intCast(w * h * 4));
    defer p.gpa.free(px);
    gl.glReadPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, px.ptr);
    const bytes = gtk.g_bytes_new(px.ptr, px.len);
    defer gtk.g_bytes_unref(bytes);
    const texture = gtk.gdk_memory_texture_new(w, h, gtk.memory_rgba8, bytes, @intCast(w * 4));
    defer gtk.g_object_unref(texture);
    gtk.gtk_picture_set_paintable(cell.picture, texture);
}

/// The sliders and the shader list follow the recipe.
pub fn update(p: *Panel) void {
    var scratch: std.heap.ArenaAllocator = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const r = p.app.recipe(a) catch Recipe{};
    p.strength.set(r.look.strength);
    p.grain.set(r.grain.amount);
    p.grain_size.set(r.grain.size);
    p.halation.set(r.halation);
    p.vignette.set(r.vignette);
    const band: Recipe.Band = switch (p.band) {
        0 => r.colour.reds,
        1 => r.colour.oranges,
        2 => r.colour.yellows,
        3 => r.colour.greens,
        4 => r.colour.blues,
        else => r.colour.purples,
    };
    p.hue.set(band.hue);
    p.sat.set(band.sat);
    p.light.set(band.light);
    for (p.looks.items) |c| {
        if (std.mem.eql(u8, c.name, r.look.name)) gtk.gtk_widget_add_css_class(c.button, "on") else gtk.gtk_widget_remove_css_class(c.button, "on");
    }
    p.renderShaders(a, r);
}

// ---- Shaders ----

fn setShaders(p: *Panel, list: []const Recipe.ShaderUse, gesture: u64) void {
    var scratch: std.heap.ArenaAllocator = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const text = std.fmt.allocPrint(a, "{{\"shaders\":{f}}}", .{std.json.fmt(list, .{})}) catch return;
    p.plainEdit(text, gesture);
    p.update();
}

fn renderShaders(p: *Panel, a: std.mem.Allocator, r: Recipe) void {
    const installed = p.library.shaderNames(a) catch &.{};
    var hash: std.hash.Wyhash = .init(0);
    for (r.shaders) |u| {
        hash.update(u.name);
        hash.update(std.mem.asBytes(&u.enabled));
    }
    for (installed) |n| hash.update(n);
    var it = p.open.keyIterator();
    while (it.next()) |k| hash.update(k.*);
    const shape = hash.final() | 1;
    if (shape == p.shader_shape) {
        for (p.shader_sliders.items) |x| {
            if (x.index >= r.shaders.len) continue;
            const use = r.shaders[x.index];
            x.slider.set(if (x.param) |name| use.params.map.get(name) orelse x.default else use.strength);
        }
        return;
    }
    p.shader_shape = shape;
    // Rows are made anew only when the list's shape changes, never mid-drag.
    while (gtk.gtk_widget_get_first_child(p.shader_box)) |child| gtk.gtk_box_remove(p.shader_box, child);
    p.shader_sliders.clearRetainingCapacity();
    for (r.shaders, 0..) |use, i| p.addRow(a, r, use, i);
    if (r.shaders.len == 0) {
        const none = gtk.gtk_label_new("No shaders on this photo.");
        gtk.gtk_label_set_xalign(none, 0);
        gtk.gtk_widget_add_css_class(none, "faint");
        gtk.gtk_box_append(p.shader_box, none);
    }
    p.fillPicker(a, r, installed);
}

const RowAction = struct { panel: *Panel, index: usize, kind: enum { toggle, up, down, remove, open } };

fn rowButton(p: *Panel, row: *anyopaque, icon: [*:0]const u8, tip: [*:0]const u8, index: usize, kind: @FieldType(RowAction, "kind")) void {
    const action = p.gpa.create(RowAction) catch return;
    action.* = .{ .panel = p, .index = index, .kind = kind };
    const b = gtk.gtk_button_new_from_icon_name(icon);
    gtk.gtk_widget_set_tooltip_text(b, tip);
    gtk.gtk_widget_add_css_class(b, "flat");
    connect(b, "clicked", &onRowAction, action);
    gtk.gtk_box_append(row, b);
}

fn addRow(p: *Panel, a: std.mem.Allocator, r: Recipe, use: Recipe.ShaderUse, i: usize) void {
    const row = gtk.gtk_box_new(gtk.horizontal, 2);
    const shader = p.library.readShader(a, use.name) catch null;
    const name_z = std.fmt.allocPrintSentinel(a, "{s}{s}", .{ use.name, if (shader == null) " (missing)" else "" }, 0) catch return;
    const name = gtk.gtk_button_new_with_label(name_z);
    gtk.gtk_widget_add_css_class(name, "flat");
    if (!use.enabled) gtk.gtk_widget_add_css_class(name, "faint");
    gtk.gtk_widget_set_hexpand(name, 1);
    const action = p.gpa.create(RowAction) catch return;
    action.* = .{ .panel = p, .index = i, .kind = .open };
    connect(name, "clicked", &onRowAction, action);
    gtk.gtk_box_append(row, name);
    p.rowButton(row, if (use.enabled) "view-reveal-symbolic" else "view-conceal-symbolic", if (use.enabled) "Turn off" else "Turn on", i, .toggle);
    if (i > 0) p.rowButton(row, "go-up-symbolic", "Earlier", i, .up);
    if (i + 1 < r.shaders.len) p.rowButton(row, "go-down-symbolic", "Later", i, .down);
    p.rowButton(row, "user-trash-symbolic", "Remove from this photo", i, .remove);
    gtk.gtk_box_append(p.shader_box, row);
    if (!p.open.contains(use.name)) return;
    const detail = gtk.gtk_box_new(gtk.vertical, 6);
    gtk.gtk_widget_add_css_class(detail, "shader-detail");
    if (shader) |sh| if (sh.json.description.len > 0) {
        const about = gtk.gtk_label_new((a.dupeZ(u8, sh.json.description) catch return).ptr);
        gtk.gtk_label_set_wrap(about, 1);
        gtk.gtk_label_set_xalign(about, 0);
        gtk.gtk_widget_add_css_class(about, "faint");
        gtk.gtk_box_append(detail, about);
    };
    p.addShaderSlider(detail, .{ .label = "Strength", .min = 0, .max = 100, .reset = 100, .unit = .percent, .on_change = onShaderSlider }, i, null, 100, use.strength);
    if (shader) |sh| for (sh.json.params) |param| {
        const label = p.gpa.dupeZ(u8, if (param.label.len > 0) param.label else param.name) catch continue;
        const key = p.gpa.dupeZ(u8, param.name) catch continue;
        const value = use.params.map.get(param.name) orelse @as(f32, @floatCast(param.default));
        p.addShaderSlider(detail, .{ .label = label, .min = param.min, .max = param.max, .step = (param.max - param.min) / 100, .reset = param.default, .unit = .decimal, .on_change = onShaderSlider }, i, key, param.default, value);
    };
    gtk.gtk_box_append(p.shader_box, detail);
}

fn addShaderSlider(p: *Panel, box: *anyopaque, config: Slider.Config, index: usize, param: ?[:0]u8, default: f64, value: f64) void {
    const item = p.gpa.create(ShaderSlider) catch return;
    var c = config;
    c.ctx = item;
    const s = Slider.create(p.gpa, c);
    s.set(value);
    item.* = .{ .slider = s, .index = index, .param = param, .default = default, .panel = p };
    p.shader_sliders.append(p.gpa, item.*) catch {};
    gtk.gtk_box_append(box, s.widget);
}

fn onShaderSlider(s: *Slider, v: f64, g: u64) void {
    const item: *ShaderSlider = @ptrCast(@alignCast(s.config.ctx));
    const p = item.panel;
    var scratch: std.heap.ArenaAllocator = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const r = p.app.recipe(a) catch return;
    if (item.index >= r.shaders.len) return;
    const list = a.dupe(Recipe.ShaderUse, r.shaders) catch return;
    if (item.param) |name| {
        var map = list[item.index].params;
        map.map.put(a, name, @floatCast(v)) catch return;
        list[item.index].params = map;
    } else list[item.index].strength = @floatCast(v);
    p.setShaders(list, g);
}

// Runs after the click: a row can't take itself away while it's being clicked.
fn onRowAction(_: *anyopaque, ctx: ?*anyopaque) callconv(.c) void {
    _ = gtk.g_idle_add(applyRowAction, ctx);
}

fn applyRowAction(ctx: ?*anyopaque) callconv(.c) c_int {
    const action: *RowAction = @ptrCast(@alignCast(ctx));
    const p = action.panel;
    var scratch: std.heap.ArenaAllocator = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const r = p.app.recipe(a) catch return gtk.source_remove;
    const i = action.index;
    if (i >= r.shaders.len) return gtk.source_remove;
    const list = a.dupe(Recipe.ShaderUse, r.shaders) catch return gtk.source_remove;
    switch (action.kind) {
        .open => {
            if (p.open.fetchRemove(list[i].name)) |k| p.gpa.free(k.key) else p.open.put(p.gpa, p.gpa.dupe(u8, list[i].name) catch return gtk.source_remove, {}) catch {};
            p.update();
        },
        .toggle => {
            list[i].enabled = !list[i].enabled;
            p.setShaders(list, 0);
        },
        .up => {
            std.mem.swap(Recipe.ShaderUse, &list[i], &list[i - 1]);
            p.setShaders(list, 0);
        },
        .down => {
            std.mem.swap(Recipe.ShaderUse, &list[i], &list[i + 1]);
            p.setShaders(list, 0);
        },
        .remove => {
            var out: std.ArrayList(Recipe.ShaderUse) = .empty;
            for (list, 0..) |u, j| if (j != i) out.append(a, u) catch return gtk.source_remove;
            p.setShaders(out.items, 0);
        },
    }
    return gtk.source_remove;
}

fn fillPicker(p: *Panel, a: std.mem.Allocator, r: Recipe, installed: []const []const u8) void {
    for (p.picker_names.items) |n| p.gpa.free(n);
    p.picker_names.clearRetainingCapacity();
    outer: for (installed) |n| {
        for (r.shaders) |u| if (std.mem.eql(u8, u.name, n)) continue :outer;
        p.picker_names.append(p.gpa, p.gpa.dupeZ(u8, n) catch continue) catch {};
    }
    const strings = a.alloc(?[*:0]const u8, p.picker_names.items.len + 2) catch return;
    strings[0] = if (p.picker_names.items.len > 0) "Add a shader…" else if (installed.len > 0) "All shaders are on" else "No shaders yet (ask Claude for one)";
    for (p.picker_names.items, strings[1 .. strings.len - 1]) |n, *o| o.* = n.ptr;
    strings[strings.len - 1] = null;
    p.updating = true;
    defer p.updating = false;
    const model = gtk.gtk_string_list_new(strings.ptr);
    gtk.gtk_drop_down_set_model(p.picker, model);
    gtk.g_object_unref(model);
    gtk.gtk_drop_down_set_selected(p.picker, 0);
    gtk.gtk_widget_set_sensitive(p.picker, @intFromBool(p.picker_names.items.len > 0));
}

fn onPicked(_: *anyopaque, _: *anyopaque, ctx: ?*anyopaque) callconv(.c) void {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    if (p.updating) return;
    const i = gtk.gtk_drop_down_get_selected(p.picker);
    if (i == 0 or i - 1 >= p.picker_names.items.len) return;
    _ = gtk.g_idle_add(addPicked, p);
}

fn addPicked(ctx: ?*anyopaque) callconv(.c) c_int {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    const i = gtk.gtk_drop_down_get_selected(p.picker);
    if (i == 0 or i - 1 >= p.picker_names.items.len) return gtk.source_remove;
    var scratch: std.heap.ArenaAllocator = .init(p.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const r = p.app.recipe(a) catch return gtk.source_remove;
    const name = p.picker_names.items[i - 1];
    var out: std.ArrayList(Recipe.ShaderUse) = .empty;
    out.appendSlice(a, r.shaders) catch return gtk.source_remove;
    var use: Recipe.ShaderUse = .{ .name = a.dupe(u8, name) catch return gtk.source_remove };
    if (p.library.readShader(a, name)) |sh| {
        for (sh.json.params) |param| use.params.map.put(a, param.name, @floatCast(param.default)) catch {};
    } else |_| {}
    out.append(a, use) catch return gtk.source_remove;
    p.setShaders(out.items, 0);
    return gtk.source_remove;
}
