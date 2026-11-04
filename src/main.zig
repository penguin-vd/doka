//! The editor: GTK 4 and OpenGL over the recipes and shaders. Claude reaches it over MCP.
//!   doka [folder]             the editor, on that folder (or the last one)
//!   doka photo.jpg --check out.ppm    no window: draws the photo once and saves the picture
//!   doka --probe              no window: the pipeline's tests on the GPU
const std = @import("std");
const core = @import("photo-core");
const Pool = @import("app/jobs.zig");
const Settings = @import("app/settings.zig");
const Library = @import("app/library.zig");
const gtk = @import("app/gtk.zig");
const gl = @import("app/gl.zig");
const Pipeline = @import("app/pipeline.zig");
const selftest = @import("app/selftest.zig");
const App = @import("app/app.zig");
const Photos = @import("app/photos.zig");
const Looks = @import("app/looks.zig");
const Canvas = @import("app/canvas.zig");
const Sidebar = @import("app/sidebar.zig");
const Slider = @import("app/slider.zig");
const LooksPanel = @import("app/looks_panel.zig");
const Exporter = @import("app/exporter.zig");
const ExportDialog = @import("app/export_dialog.zig");
const tools = @import("app/tools.zig");
const cropping = @import("app/crop.zig");
const Mcp = @import("app/mcp.zig");
const Recipe = core.Recipe;

const log = std.log.scoped(.window);
const gpa = std.heap.c_allocator;

const panel_width = 264;

// Recipes reach the disk this long after the last change: a drag saves once, at the end.
const save_delay_ms = 400;

var app: App = undefined;
var photos: Photos = undefined;
var looks: Looks = undefined;
var preview_looks: Looks = undefined;
var canvas: Canvas = undefined;
var sidebar: Sidebar = undefined;
var looks_panel: LooksPanel = undefined;
var exporter: Exporter = undefined;
var export_dialog: ExportDialog = undefined;
var compare_button: *anyopaque = undefined;
var export_button: *anyopaque = undefined;
var claude_label: *anyopaque = undefined;
var claude_timer: c_uint = 0;
var exif_label: *anyopaque = undefined;
var zoom_label: *anyopaque = undefined;
var tab_stack: *anyopaque = undefined;
var tab_buttons: [3]*anyopaque = undefined;
const Tab = enum { adjust, looks, crop };
var active_tab: Tab = .adjust;
// Claude's views waiting for the photo to reach the GPU.
var shots: std.ArrayList(App.Shot) = .empty;
var shown_indices: std.ArrayList(u32) = .empty;
var pool: Pool = undefined;
var library: Library = undefined;
var start_folder: ?[:0]const u8 = null;
var folder_label: *anyopaque = undefined;
var photo_label: *anyopaque = undefined;
var position_label: *anyopaque = undefined;
var undo_button: *anyopaque = undefined;
var redo_button: *anyopaque = undefined;
var window: *anyopaque = undefined;
var save_timer: c_uint = 0;
// The photo being decoded for the screen; one at a time, the newest asked for next. Holding an
// arrow key passes over the rest instead of queueing them.
var decoding: ?[]u8 = null;

// The look (docs): the photo is the only colour on screen. Every grey is neutral (R = G = B), so
// nothing beside the photo tints how its colours read; "on" and "changed" are shown with white.
const css =
    \\@define-color accent_bg_color #f4f4f4;
    \\@define-color accent_fg_color #161616;
    \\@define-color accent_color #f4f4f4;
    \\window, .chrome { background: #242424; color: #ececec; font-family: "IBM Plex Sans", system-ui, sans-serif; font-size: 13px; }
    \\*:focus-visible { outline-color: #f4f4f4; }
    \\.stage { background: #1a1a1a; }
    \\.bar { padding: 4px 8px 4px 12px; min-height: 28px; border-bottom: 1px solid #363636; background: #242424; }
    \\.rule { min-width: 1px; margin: 5px 6px; background: #363636; }
    \\.footer { padding: 4px 12px; font-size: 12px; color: #b8b8b8; border-top: 1px solid #363636; background: #242424; }
    \\.sidebar { background: #242424; border-right: 1px solid #363636; }
    \\.sidebar-head { padding: 8px 12px 0; }
    \\.filters { padding: 0 12px 8px; border-bottom: 1px solid #363636; }
    \\.panel { background: #242424; border-left: 1px solid #363636; }
    \\.panel-body { padding: 0 14px 14px; }
    \\.tabs { padding: 0 14px; border-bottom: 1px solid #363636; }
    \\.photo-list, .photo-list > row { background: transparent; padding: 0; }
    \\.group-title { padding: 10px 12px 6px; font-size: 12px; font-weight: 500; color: #b8b8b8; }
    \\.sticky-day { padding: 8px 12px 6px; font-size: 12px; font-weight: 500; color: #b8b8b8; background: #242424; }
    \\.thumbs { padding: 0 12px 4px; }
    \\.thumb { background: #1c1c1c; }
    \\.thumb.empty { background: transparent; }
    \\.thumb.current { outline: 2px solid #f4f4f4; outline-offset: -2px; }
    \\.thumb.selected { outline: 1px dashed #f4f4f4; outline-offset: -1px; }
    \\.thumb-dot { min-width: 7px; min-height: 7px; margin: 4px; border-radius: 50%; background: #f4f4f4; box-shadow: 0 0 0 1px #161616; }
    \\.faint { color: #919191; font-weight: 400; font-size: 12px; }
    \\.section-title { font-weight: 500; margin-top: 8px; padding-top: 12px; border-top: 1px solid #363636; }
    \\.section-title:first-child { margin-top: 0; border-top: 0; }
    \\expander.section-title > title { font-weight: 500; }
    \\.slider-label { color: #b8b8b8; }
    \\.slider-label.set { color: #ececec; }
    \\.slider-value { color: #919191; font-size: 12px; font-feature-settings: "tnum"; }
    \\.slider-value.set { color: #f4f4f4; }
    \\button { font-weight: 400; min-height: 24px; min-width: 0; padding: 1px 8px; background: #333333; background-image: none; color: #ececec; border: 0; border-radius: 3px; box-shadow: none; text-shadow: none; }
    \\button:hover { background: #3d3d3d; }
    \\button:active, button:checked { background: #4c4c4c; color: #f4f4f4; }
    \\button:disabled { opacity: 0.35; background: #333333; }
    \\button.icon { background: transparent; color: #b8b8b8; min-width: 26px; padding: 1px; }
    \\button.icon:hover { background: #333333; color: #ececec; }
    \\button.flat { background: transparent; }
    \\button.flat:hover { background: #333333; }
    \\button.quiet { background: transparent; color: #b8b8b8; }
    \\button.quiet:hover { background: #333333; color: #ececec; }
    \\button.quiet:checked { background: #3d3d3d; color: #f4f4f4; }
    \\button.accent { background: #f4f4f4; color: #161616; font-weight: 500; }
    \\button.accent:hover { background: #ffffff; }
    \\button.accent:disabled { background: #f4f4f4; }
    \\.linked > button { border-radius: 0; font-size: 12px; background: #1c1c1c; color: #b8b8b8; margin-right: 1px; }
    \\.linked > button:first-child { border-radius: 3px 0 0 3px; }
    \\.linked > button:last-child { border-radius: 0 3px 3px 0; margin-right: 0; }
    \\.linked > button:hover { color: #ececec; background: #1c1c1c; }
    \\.linked > button:checked { background: #3d3d3d; color: #f4f4f4; }
    \\button.tab, button.tab:hover, button.tab:checked { background: transparent; border-radius: 0; min-height: 34px; padding: 0; color: #919191; border-bottom: 2px solid transparent; }
    \\button.tab:hover { color: #ececec; }
    \\button.tab:checked { color: #ececec; border-bottom-color: #f4f4f4; }
    \\dropdown > button { background: #1c1c1c; font-size: 12px; }
    \\dropdown > button:hover { background: #1c1c1c; }
    \\popover > contents { background: #2a2a2a; border-radius: 3px; box-shadow: 0 2px 8px rgba(0, 0, 0, 0.5); }
    \\popover listview > row:selected, popover listview > row:hover { background: #3d3d3d; }
    \\entry { background: #1c1c1c; color: #ececec; border: 1px solid #363636; border-radius: 3px; min-height: 26px; box-shadow: none; }
    \\entry:focus-within { border-color: #f4f4f4; outline: 0; }
    \\checkbutton check { background: #1c1c1c; border: 1px solid #4c4c4c; border-radius: 3px; box-shadow: none; }
    \\checkbutton check:checked { background: #f4f4f4; color: #161616; border-color: #f4f4f4; }
    \\progressbar > trough { background: #1c1c1c; min-height: 2px; border-radius: 0; }
    \\progressbar > trough > progress { background: #f4f4f4; min-height: 2px; border-radius: 0; }
    \\scrollbar { background: transparent; border: 0; }
    \\scrollbar slider { min-width: 4px; min-height: 24px; margin: 2px; background: #4c4c4c; border: 0; border-radius: 3px; }
    \\scrollbar slider:hover { background: #636363; }
    \\flowboxchild { padding: 2px; min-width: 0; background: transparent; outline: 0; }
    \\flowboxchild:hover, flowboxchild:focus { background: transparent; }
    \\.look { padding: 0; background: transparent; color: #b8b8b8; }
    \\.look:hover, .look:active { color: #ececec; background: transparent; }
    \\.look.on { color: #f4f4f4; outline: 2px solid #f4f4f4; outline-offset: -2px; background: transparent; }
    \\.look-name { font-size: 11px; }
    \\.shader-detail { padding: 2px 0 8px 10px; border-left: 1px solid #4c4c4c; }
    \\.dialog { padding: 16px; }
    \\.warning-text { color: #e3a878; font-size: 12px; }
;

// ---- Sliders ----

const Field = struct { group: []const u8, field: []const u8, label: [:0]const u8, min: f64, max: f64, step: f64 = 1, unit: @FieldType(Slider.Config, "unit") = .signed, slider: *Slider = undefined };

var fields = [_]Field{
    .{ .group = "edits", .field = "exposure", .label = "Exposure", .min = -5, .max = 5, .step = 0.05, .unit = .ev },
    .{ .group = "edits", .field = "contrast", .label = "Contrast", .min = -100, .max = 100 },
    .{ .group = "edits", .field = "highlights", .label = "Highlights", .min = -100, .max = 100 },
    .{ .group = "edits", .field = "shadows", .label = "Shadows", .min = -100, .max = 100 },
    .{ .group = "edits", .field = "temperature", .label = "Temperature", .min = -100, .max = 100 },
    .{ .group = "edits", .field = "tint", .label = "Tint", .min = -100, .max = 100 },
    .{ .group = "edits", .field = "saturation", .label = "Saturation", .min = -100, .max = 100 },
    .{ .group = "detail", .field = "sharpen", .label = "Sharpen", .min = 0, .max = 100, .unit = .plain },
    .{ .group = "detail", .field = "noise", .label = "Noise reduction", .min = 0, .max = 100, .unit = .plain },
};
const section_before = [_]struct { index: usize, title: [:0]const u8 }{
    .{ .index = 0, .title = "Light" },
    .{ .index = 4, .title = "Colour" },
    .{ .index = 7, .title = "Detail" },
};

fn readField(r: Recipe, group: []const u8, field: []const u8) f32 {
    if (std.mem.eql(u8, group, "edits")) {
        inline for (@typeInfo(Recipe.Edits).@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, field)) return @field(r.edits, f.name);
        }
    } else {
        inline for (@typeInfo(Recipe.Detail).@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, field)) return @field(r.detail, f.name);
        }
    }
    return 0;
}

fn onFieldChanged(s: *Slider, v: f64, gesture: u64) void {
    const f: *Field = @ptrCast(@alignCast(s.config.ctx));
    var buf: [128]u8 = undefined;
    const patch = std.fmt.bufPrint(&buf, "{{\"{s}\":{{\"{s}\":{d}}}}}", .{ f.group, f.field, v }) catch return;
    app.edit(patch, gesture) catch |err| return log.err("edit: {t}", .{err});
    edited();
}

// Every control follows the recipe: a new photo, undo, Claude.
fn syncControls() void {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const r = app.recipe(scratch.allocator()) catch Recipe{};
    for (&fields) |*f| f.slider.set(readField(r, f.group, f.field));
    syncCrop(r);
    if (active_tab == .looks) looks_panel.update();
}

// ---- Crop ----

const aspect_values = [_][:0]const u8{ "original", "free", "1:1", "4:5", "3:2", "16:9" };
const aspect_labels = [_][:0]const u8{ "Original", "Free", "1:1", "4:5", "3:2", "16:9" };
var aspect_buttons: [aspect_values.len]*anyopaque = undefined;
var straighten: *Slider = undefined;
var updating_crop = false;

fn ratioOf(aspect: []const u8, photo: [2]f64) ?f64 {
    return Recipe.aspectRatio(aspect, photo);
}

fn photoSize(rotate: u16) [2]f64 {
    const pipe = &(canvas.pipeline orelse return .{ 1, 1 });
    const w: f64 = @floatFromInt(pipe.width);
    const h: f64 = @floatFromInt(pipe.height);
    return if ((rotate / 90) % 2 == 1) .{ h, w } else .{ w, h };
}

fn syncCrop(r: Recipe) void {
    updating_crop = true;
    defer updating_crop = false;
    straighten.set(r.crop.straighten);
    for (aspect_buttons, aspect_values) |b, v| {
        if (std.mem.eql(u8, v, r.crop.aspect)) gtk.gtk_toggle_button_set_active(b, 1);
    }
    canvas.aspect_ratio = ratioOf(r.crop.aspect, photoSize(r.crop.rotate));
}

fn onStraighten(_: *Slider, v: f64, gesture: u64) void {
    var buf: [64]u8 = undefined;
    app.edit(std.fmt.bufPrint(&buf, "{{\"crop\":{{\"straighten\":{d}}}}}", .{v}) catch return, gesture) catch return;
    edited();
}

fn onCropDragged(rect: cropping.Rect, gesture: u64) void {
    var buf: [128]u8 = undefined;
    app.edit(std.fmt.bufPrint(&buf, "{{\"crop\":{{\"rect\":[{d},{d},{d},{d}]}}}}", .{ rect[0], rect[1], rect[2], rect[3] }) catch return, gesture) catch return;
    edited();
}

fn onAspect(_: *anyopaque, ctx: ?*anyopaque) callconv(.c) void {
    if (updating_crop) return;
    const button = ctx.?;
    if (gtk.gtk_toggle_button_get_active(button) == 0) return;
    const index = for (aspect_buttons, 0..) |b, i| {
        if (b == button) break i;
    } else return;
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const r = app.recipe(a) catch return;
    const aspect = aspect_values[index];
    const photo = photoSize(r.crop.rotate);
    const c = r.crop.rect;
    const cur: cropping.Rect = .{ c[0], c[1], c[2], c[3] };
    const rect = if (ratioOf(aspect, photo)) |q| cropping.fitAspect(cur, q, photo) else cur;
    app.edit(std.fmt.allocPrint(a, "{{\"crop\":{{\"aspect\":\"{s}\",\"rect\":[{d},{d},{d},{d}]}}}}", .{ aspect, rect[0], rect[1], rect[2], rect[3] }) catch return, 0) catch return;
    edited();
    canvas.aspect_ratio = ratioOf(aspect, photo);
}

fn onRotate(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const c = (app.recipe(a) catch return).crop;
    // Clockwise as shown: the flip comes after the turn, so a flipped photo turns the other way.
    const rotate = (c.rotate + @as(u16, if (c.flip) 270 else 90)) % 360;
    const r = c.rect;
    app.edit(std.fmt.allocPrint(a, "{{\"crop\":{{\"rotate\":{d},\"rect\":[{d},{d},{d},{d}]}}}}", .{ rotate, 1 - r[1] - r[3], r[0], r[3], r[2] }) catch return, 0) catch return;
    edited();
}

fn onFlip(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const c = (app.recipe(a) catch return).crop;
    const r = c.rect;
    app.edit(std.fmt.allocPrint(a, "{{\"crop\":{{\"flip\":{},\"rect\":[{d},{d},{d},{d}]}}}}", .{ !c.flip, 1 - r[0] - r[2], r[1], r[2], r[3] }) catch return, 0) catch return;
    edited();
}

fn onResetCrop(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    app.edit("{\"crop\":null}", 0) catch return;
    syncControls();
    edited();
}

fn buildCropPanel() *anyopaque {
    const box = gtk.gtk_box_new(gtk.vertical, 8);
    gtk.gtk_widget_add_css_class(box, "panel-body");
    gtk.gtk_box_append(box, sectionTitle("Aspect ratio"));
    const flow = gtk.gtk_flow_box_new();
    gtk.gtk_flow_box_set_homogeneous(flow, 1);
    gtk.gtk_flow_box_set_min_children_per_line(flow, 3);
    gtk.gtk_flow_box_set_max_children_per_line(flow, 3);
    gtk.gtk_flow_box_set_selection_mode(flow, 0);
    for (&aspect_buttons, aspect_labels, 0..) |*b, label, i| {
        b.* = gtk.gtk_toggle_button_new_with_label(label);
        if (i > 0) gtk.gtk_toggle_button_set_group(b.*, aspect_buttons[0]);
        gtk.gtk_flow_box_append(flow, b.*);
    }
    for (aspect_buttons) |b| connect(b, "toggled", &onAspect, b);
    gtk.gtk_box_append(box, flow);
    straighten = Slider.create(gpa, .{ .label = "Straighten", .min = -45, .max = 45, .step = 0.1, .unit = .degrees, .on_change = onStraighten });
    gtk.gtk_box_append(box, straighten.widget);
    const row = gtk.gtk_box_new(gtk.horizontal, 4);
    const rotate = gtk.gtk_button_new_with_label("Rotate 90°");
    const flip = gtk.gtk_button_new_with_label("Flip");
    gtk.gtk_widget_set_hexpand(rotate, 1);
    gtk.gtk_widget_set_hexpand(flip, 1);
    connect(rotate, "clicked", &onRotate, null);
    connect(flip, "clicked", &onFlip, null);
    gtk.gtk_box_append(row, rotate);
    gtk.gtk_box_append(row, flip);
    gtk.gtk_box_append(box, row);
    const reset = gtk.gtk_button_new_with_label("Reset crop");
    gtk.gtk_widget_add_css_class(reset, "quiet");
    gtk.gtk_widget_set_halign(reset, gtk.align_start);
    connect(reset, "clicked", &onResetCrop, null);
    gtk.gtk_box_append(box, reset);
    const hint = gtk.gtk_label_new("Drag the frame to move it, its corners to resize.");
    gtk.gtk_label_set_xalign(hint, 0);
    gtk.gtk_label_set_wrap(hint, 1);
    gtk.gtk_widget_add_css_class(hint, "faint");
    gtk.gtk_box_append(box, hint);
    return box;
}

// ---- What happens ----

fn scheduleSave() void {
    if (save_timer != 0) _ = gtk.g_source_remove(save_timer);
    save_timer = gtk.g_timeout_add(save_delay_ms, onSaveTimer, null);
}

fn onSaveTimer(_: ?*anyopaque) callconv(.c) c_int {
    save_timer = 0;
    app.flush();
    return gtk.source_remove;
}

// The open photo's edits changed.
fn edited() void {
    scheduleSave();
    if (app.currentSession()) |s| if (canvas.showing(app.currentRel().?)) canvas.edited(s.json);
    sidebar.repaint();
    if (active_tab == .crop or active_tab == .looks) {
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        if (active_tab == .crop) if (app.recipe(scratch.allocator())) |r| syncCrop(r) else |_| {};
    }
    syncHeader();
}

fn syncHeader() void {
    var buf: [256]u8 = undefined;
    const f = if (app.folder) |*x| x else null;
    gtk.gtk_label_set_text(folder_label, if (f) |x| std.fmt.bufPrintZ(&buf, "{s}", .{x.name()}) catch "" else "No folder open");
    var buf2: [256]u8 = undefined;
    gtk.gtk_label_set_text(photo_label, if (app.currentRel()) |r| std.fmt.bufPrintZ(&buf2, "{s}", .{std.fs.path.basename(r)}) catch "" else "");
    var buf3: [64]u8 = undefined;
    var position: usize = if (app.current) |c| c + 1 else 0;
    var total: usize = if (f) |x| x.photos.len else 0;
    if (app.filtered()) {
        app.shown(gpa, &shown_indices) catch {};
        total = shown_indices.items.len;
        for (shown_indices.items, 1..) |n, at| {
            if (n == app.current) position = at;
        }
    }
    gtk.gtk_label_set_text(position_label, if (f != null and app.current != null) std.fmt.bufPrintZ(&buf3, "{d} / {d}", .{ position, total }) catch "" else "");
    gtk.gtk_widget_set_sensitive(export_button, @intFromBool(app.current != null));
    gtk.gtk_widget_set_sensitive(compare_button, @intFromBool(app.current != null));
    const s = app.currentSession();
    gtk.gtk_widget_set_sensitive(undo_button, @intFromBool(s != null and s.?.canUndo()));
    gtk.gtk_widget_set_sensitive(redo_button, @intFromBool(s != null and s.?.canRedo()));
}

// The open photo changed: everything but the canvas follows at once, the canvas when it's decoded.
fn photoChanged() void {
    syncControls();
    syncHeader();
    syncExif();
    if (app.filtered()) sidebar.refilterQuiet();
    sidebar.setCurrent(app.current);
    askForCurrent();
}

fn askForCurrent() void {
    const rel = app.currentRel() orelse return;
    if (decoding != null) return;
    if (canvas.showing(rel)) return;
    decoding = gpa.dupe(u8, rel) catch return;
    photos.request(rel, Canvas.preview_edge, .urgent);
}

fn onDecoded(rel: []const u8, edge: u32, ok: bool) void {
    if (edge == 0) return canvas.fullDecoded(rel, ok);
    const mine = decoding != null and std.mem.eql(u8, decoding.?, rel);
    if (!mine) return;
    gpa.free(decoding.?);
    decoding = null;
    const current = app.currentRel() orelse return;
    if (!std.mem.eql(u8, current, rel)) return askForCurrent();
    if (!ok) return;
    if (app.currentSession()) |s| canvas.show(rel, s.json);
    decodeNeighbours();
}

// So ← and → don't wait.
fn decodeNeighbours() void {
    const f = &(app.folder orelse return);
    const i = app.current orelse return;
    if (i + 1 < f.photos.len) photos.request(f.photos[i + 1].rel, Canvas.preview_edge, .background);
    if (i > 0) photos.request(f.photos[i - 1].rel, Canvas.preview_edge, .background);
}

fn onThumb(rel: []const u8, texture: *anyopaque) void {
    sidebar.thumbArrived(rel, texture);
}

fn pick(index: usize) void {
    app.open(index) catch |err| return log.err("open: {t}", .{err});
    photoChanged();
}

fn stepPhoto(by: isize) void {
    const current = app.current orelse return;
    app.shown(gpa, &shown_indices) catch return;
    const items = shown_indices.items;
    const at = std.mem.indexOfScalar(u32, items, @intCast(current)) orelse return;
    const next = @as(isize, @intCast(at)) + by;
    if (next < 0 or next >= items.len) return;
    pick(items[@intCast(next)]);
}

fn undoStep() void {
    if (app.undo() catch false) {
        syncControls();
        edited();
    }
}

fn redoStep() void {
    if (app.redo() catch false) {
        syncControls();
        edited();
    }
}

fn openFolder(path: [:0]const u8) void {
    app.openFolder(path) catch |err| return log.err("can't open {s}: {t}", .{ path, err });
    const f = &app.folder.?;
    photos.setRoot(f.path) catch return;
    if (decoding) |d| gpa.free(d);
    decoding = null;
    sidebar.rebuild();
    photoChanged();
    DayScan.start() catch |err| log.warn("no dates for the photos: {t}", .{err});
}

/// The day each photo was taken, off the main loop: the first 64 KB of each file hold its EXIF.
const DayScan = struct {
    task: Pool.Task = .{ .run = run, .done = done },
    generation: u32,
    arena: std.heap.ArenaAllocator,
    paths: [][:0]const u8,
    days: [][10]u8,
    head: []u8,

    fn start() !void {
        const f = &(app.folder orelse return);
        const scan = try gpa.create(DayScan);
        scan.* = .{ .generation = app.generation, .arena = .init(gpa), .paths = &.{}, .days = &.{}, .head = &.{} };
        errdefer scan.free();
        const a = scan.arena.allocator();
        scan.paths = try a.alloc([:0]const u8, f.photos.len);
        for (f.photos, scan.paths) |p, *path| path.* = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ f.path, p.rel }, 0);
        scan.days = try a.alloc([10]u8, f.photos.len);
        scan.head = try a.alloc(u8, 64 << 10);
        pool.submit(&scan.task, .background);
    }

    fn free(scan: *DayScan) void {
        scan.arena.deinit();
        gpa.destroy(scan);
    }

    fn run(task: *Pool.Task) void {
        const scan: *DayScan = @alignCast(@fieldParentPtr("task", task));
        for (scan.paths, scan.days) |path, *day| {
            day.* = @splat(0);
            const fd = std.c.open(path, .{ .ACCMODE = .RDONLY });
            if (fd < 0) continue;
            defer _ = std.c.close(fd);
            const got = std.c.read(fd, scan.head.ptr, scan.head.len);
            if (got <= 0) continue;
            if (core.exif.dayTaken(scan.head[0..@intCast(got)])) |d| day.* = d;
        }
    }

    fn done(task: *Pool.Task) void {
        const scan: *DayScan = @alignCast(@fieldParentPtr("task", task));
        defer scan.free();
        if (scan.generation != app.generation) return;
        app.setDays(scan.days) catch return;
        sidebar.rebuild();
    }
};

// ---- The window ----

fn connect(object: *anyopaque, signal: [*:0]const u8, handler: anytype, data: ?*anyopaque) void {
    _ = gtk.g_signal_connect_data(object, signal, @ptrCast(handler), data, null, 0);
}

fn onOpenClicked(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    chooseFolder();
}

fn chooseFolder() void {
    const dialog = gtk.gtk_file_dialog_new();
    gtk.gtk_file_dialog_select_folder(dialog, window, null, onFolderChosen, null);
}

fn onFolderChosen(dialog: *anyopaque, result: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    defer gtk.g_object_unref(dialog);
    const file = gtk.gtk_file_dialog_select_folder_finish(dialog, result, null) orelse return;
    defer gtk.g_object_unref(file);
    const path = gtk.g_file_get_path(file) orelse return;
    defer gtk.g_free(path);
    openFolder(std.mem.span(path));
}

fn onPrev(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    stepPhoto(-1);
}
fn onNext(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    stepPhoto(1);
}
fn onUndo(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    undoStep();
}
fn onRedo(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    redoStep();
}
fn onResetSliders(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    app.edit("{\"edits\":null,\"detail\":null}", 0) catch return;
    syncControls();
    edited();
}

fn onKey(_: *anyopaque, key: c_uint, _: c_uint, state: c_uint, _: ?*anyopaque) callconv(.c) c_int {
    const ctrl = state & gtk.control_mask != 0;
    const shift = state & gtk.shift_mask != 0;
    if (ctrl) switch (key) {
        'z', 'Z' => {
            if (shift) redoStep() else undoStep();
            return 1;
        },
        'y' => {
            redoStep();
            return 1;
        },
        'o' => {
            chooseFolder();
            return 1;
        },
        'e' => {
            openExport();
            return 1;
        },
        else => return 0,
    };
    switch (key) {
        gtk.key_left => stepPhoto(-1),
        gtk.key_right => stepPhoto(1),
        '\\' => {
            canvas.before = true;
            canvas.redraw();
        },
        else => return 0,
    }
    return 1;
}

fn onKeyUp(_: *anyopaque, key: c_uint, _: c_uint, _: c_uint, _: ?*anyopaque) callconv(.c) void {
    if (key == '\\') {
        canvas.before = false;
        canvas.redraw();
    }
}

fn iconButton(icon: [*:0]const u8, tip: [*:0]const u8, handler: anytype) *anyopaque {
    const b = gtk.gtk_button_new_from_icon_name(icon);
    gtk.gtk_widget_set_tooltip_text(b, tip);
    gtk.gtk_widget_add_css_class(b, "icon");
    connect(b, "clicked", handler, null);
    return b;
}

fn rule() *anyopaque {
    const r = gtk.gtk_box_new(gtk.vertical, 0);
    gtk.gtk_widget_add_css_class(r, "rule");
    return r;
}

fn buildBar() *anyopaque {
    const bar = gtk.gtk_box_new(gtk.horizontal, 4);
    gtk.gtk_widget_add_css_class(bar, "bar");
    folder_label = gtk.gtk_label_new(null);
    gtk.gtk_widget_add_css_class(folder_label, "faint");
    gtk.gtk_box_append(bar, folder_label);
    photo_label = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(photo_label, 0);
    gtk.gtk_widget_set_hexpand(photo_label, 1);
    gtk.gtk_box_append(bar, photo_label);
    claude_label = gtk.gtk_label_new("Claude connected");
    gtk.gtk_widget_add_css_class(claude_label, "faint");
    gtk.gtk_widget_set_visible(claude_label, 0);
    gtk.gtk_box_append(bar, claude_label);
    gtk.gtk_box_append(bar, iconButton("folder-open-symbolic", "Open folder (Ctrl+O)", &onOpenClicked));
    gtk.gtk_box_append(bar, iconButton("go-previous-symbolic", "Previous photo (←)", &onPrev));
    position_label = gtk.gtk_label_new(null);
    gtk.gtk_box_append(bar, position_label);
    gtk.gtk_box_append(bar, iconButton("go-next-symbolic", "Next photo (→)", &onNext));
    gtk.gtk_box_append(bar, rule());
    undo_button = iconButton("edit-undo-symbolic", "Undo (Ctrl+Z)", &onUndo);
    redo_button = iconButton("edit-redo-symbolic", "Redo (Ctrl+Shift+Z)", &onRedo);
    gtk.gtk_box_append(bar, undo_button);
    gtk.gtk_box_append(bar, redo_button);
    compare_button = gtk.gtk_toggle_button_new_with_label("Compare");
    gtk.gtk_widget_add_css_class(compare_button, "quiet");
    gtk.gtk_widget_set_tooltip_text(compare_button, "Drag the line across the photo; hold \\ to see the whole original");
    connect(compare_button, "toggled", &onCompare, null);
    gtk.gtk_box_append(bar, compare_button);
    export_button = gtk.gtk_button_new_with_label("Export");
    gtk.gtk_widget_add_css_class(export_button, "accent");
    gtk.gtk_widget_set_tooltip_text(export_button, "Export (Ctrl+E)");
    connect(export_button, "clicked", &onExportClicked, null);
    gtk.gtk_box_append(bar, export_button);
    return bar;
}

fn sectionTitle(text: [*:0]const u8) *anyopaque {
    const l = gtk.gtk_label_new(text);
    gtk.gtk_label_set_xalign(l, 0);
    gtk.gtk_widget_add_css_class(l, "section-title");
    return l;
}

fn buildAdjust() *anyopaque {
    const panel = gtk.gtk_box_new(gtk.vertical, 8);
    gtk.gtk_widget_add_css_class(panel, "panel-body");
    for (&fields, 0..) |*f, i| {
        for (section_before) |section| if (section.index == i) gtk.gtk_box_append(panel, sectionTitle(section.title));
        f.slider = Slider.create(gpa, .{ .label = f.label, .min = f.min, .max = f.max, .step = f.step, .unit = f.unit, .on_change = onFieldChanged, .ctx = f });
        gtk.gtk_box_append(panel, f.slider.widget);
    }
    const reset = gtk.gtk_button_new_with_label("Reset sliders");
    gtk.gtk_widget_add_css_class(reset, "quiet");
    gtk.gtk_widget_set_halign(reset, gtk.align_start);
    connect(reset, "clicked", &onResetSliders, null);
    gtk.gtk_box_append(panel, reset);
    return panel;
}

fn onTab(button: *anyopaque, ctx: ?*anyopaque) callconv(.c) void {
    if (gtk.gtk_toggle_button_get_active(button) == 0) return;
    const tab: Tab = @enumFromInt(@intFromPtr(ctx) - 1);
    active_tab = tab;
    app.tab = @tagName(tab);
    gtk.gtk_stack_set_visible_child_name(tab_stack, @tagName(tab));
    canvas.setCropMode(tab == .crop);
    looks_panel.setVisible(tab == .looks);
    syncControls();
}

fn buildPanel() *anyopaque {
    const panel = gtk.gtk_box_new(gtk.vertical, 0);
    gtk.gtk_widget_add_css_class(panel, "panel");
    gtk.gtk_widget_set_size_request(panel, panel_width, -1);
    // A child that wants to expand mustn't make the whole panel expand: the photo gets the room.
    gtk.gtk_widget_set_hexpand(panel, 0);
    const tabs = gtk.gtk_box_new(gtk.horizontal, 14);
    gtk.gtk_widget_add_css_class(tabs, "tabs");
    for (&tab_buttons, [_][*:0]const u8{ "Adjust", "Looks", "Crop" }, 0..) |*b, label, i| {
        b.* = gtk.gtk_toggle_button_new_with_label(label);
        gtk.gtk_widget_add_css_class(b.*, "tab");
        if (i > 0) gtk.gtk_toggle_button_set_group(b.*, tab_buttons[0]);
        gtk.gtk_box_append(tabs, b.*);
    }
    gtk.gtk_toggle_button_set_active(tab_buttons[0], 1);
    for (tab_buttons, 0..) |b, i| connect(b, "toggled", &onTab, @ptrFromInt(i + 1));
    gtk.gtk_box_append(panel, tabs);
    tab_stack = gtk.gtk_stack_new();
    gtk.gtk_widget_set_vexpand(tab_stack, 1);
    _ = gtk.gtk_stack_add_named(tab_stack, buildAdjust(), "adjust");
    _ = gtk.gtk_stack_add_named(tab_stack, looks_panel.create(), "looks");
    _ = gtk.gtk_stack_add_named(tab_stack, buildCropPanel(), "crop");
    gtk.gtk_box_append(panel, tab_stack);
    return panel;
}

fn syncExif() void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const f = &(app.folder orelse return gtk.gtk_label_set_text(exif_label, ""));
    const rel = app.currentRel() orelse return gtk.gtk_label_set_text(exif_label, "");
    const path = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ f.path, rel }, 0) catch return;
    const i = core.decode.info(a, path) catch core.decode.Info{};
    const aperture = if (std.mem.startsWith(u8, i.aperture, "f/")) i.aperture[2..] else i.aperture;
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    w.print("{s}", .{i.model}) catch return;
    if (i.lens.len > 0) w.print("     {s}", .{i.lens}) catch return;
    if (i.exposure.len > 0) w.print("     {s} s", .{i.exposure}) catch return;
    if (aperture.len > 0) w.print("     f/{s}", .{aperture}) catch return;
    if (i.iso.len > 0) w.print("     ISO {s}", .{i.iso}) catch return;
    w.writeByte(0) catch return;
    gtk.gtk_label_set_text(exif_label, @ptrCast(out.written().ptr));
}

fn onDrawn() void {
    var buf: [32]u8 = undefined;
    gtk.gtk_label_set_text(zoom_label, canvas.zoomText(&buf));
    looks_panel.maybeDrawPreviews();
}

fn onCompare(button: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    canvas.compare = gtk.gtk_toggle_button_get_active(button) != 0;
    canvas.redraw();
}

fn onExportClicked(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    openExport();
}

fn openExport() void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const picked = sidebar.selection(arena.allocator()) catch return;
    if (picked.len > 1) return export_dialog.open(picked);
    const rel = app.currentRel() orelse return;
    export_dialog.open(&.{rel});
}

fn onExportProgress(index: usize, total: usize, rel: []const u8) void {
    export_dialog.progress_(index, total, rel);
}

fn onExportDone(folder: []const u8, results: []const Exporter.Result, ms: u64) void {
    export_dialog.finished(folder, results, ms);
}

// ---- Claude ----

fn onMcpCall(_: *anyopaque, call: *Mcp.Call) void {
    tools.run(&app, call);
}

// Shown for this long after Claude's last call: MCP over HTTP has no "disconnected".
const connected_for_ms = 10 * 60 * 1000;

fn onMcpActivity(_: *anyopaque) void {
    gtk.gtk_widget_set_visible(claude_label, 1);
    if (claude_timer != 0) _ = gtk.g_source_remove(claude_timer);
    claude_timer = gtk.g_timeout_add(connected_for_ms, onClaudeQuiet, null);
}

fn onClaudeQuiet(_: ?*anyopaque) callconv(.c) c_int {
    claude_timer = 0;
    gtk.gtk_widget_set_visible(claude_label, 0);
    return gtk.source_remove;
}

fn hookEdited() void {
    syncControls();
    edited();
}

fn hookPhotoChanged() void {
    photoChanged();
}

fn hookLibraryChanged() void {
    if (canvas.makeCurrent()) canvas.reloadShaders();
    looks.clear();
    preview_looks.clear();
    canvas.lookChanged();
    looks_panel.reloadLooks();
    looks_panel.shader_shape = 0;
    if (active_tab == .looks) looks_panel.update();
}

fn onLookParsed() void {
    canvas.redraw();
}

fn onPreviewLookParsed() void {
    looks_panel.resume_();
}

fn onLibraryChange(_: *anyopaque) void {
    hookLibraryChanged();
}

fn hookCompile(a: std.mem.Allocator, params: []const Library.Param, source: []const u8) []const u8 {
    if (!canvas.makeCurrent()) return "there's no OpenGL context yet";
    const list = a.alloc(Pipeline.Param, params.len) catch return "out of memory";
    for (params, list) |from, *to| to.* = .{ .name = from.name, .default = @floatCast(from.default) };
    const compiled = canvas.pipeline.?.compileShader(list, source) catch return a.dupe(u8, Pipeline.last_error) catch "didn't compile";
    canvas.pipeline.?.dropCompiled(compiled);
    return "";
}

fn hookBake(a: std.mem.Allocator, title: []const u8, size: u32) ![]const u8 {
    if (!canvas.makeCurrent()) return error.NoOpenGL;
    const r = try app.recipe(a);
    looks.prepare(&canvas.pipeline.?, r);
    const lattice = try canvas.pipeline.?.bakeLattice(gpa, r, size);
    defer gpa.free(lattice);
    return @import("app/cube.zig").write(a, title, size, lattice);
}

fn hookScreenshot(shot: App.Shot) void {
    const rel = app.currentRel() orelse return tools.finishScreenshot(&app, shot, "", "");
    if (canvas.showing(rel) and canvas.pending == null) return takeShot(shot);
    shots.append(gpa, shot) catch tools.finishScreenshot(&app, shot, "", "");
}

// Views waiting for this photo.
fn onInstalled() void {
    const waiting = shots.toOwnedSlice(gpa) catch return;
    defer gpa.free(waiting);
    for (waiting) |shot| takeShot(shot);
}

const screenshot_tones_bins = 16;

// The rendered photo as a JPEG and its tones: the pipeline into a small target, not a grab of the
// screen. The numbers mean Claude needn't judge exposure from a small JPEG.
fn takeShot(shot: App.Shot) void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    renderShot(a, shot) catch |err| {
        log.warn("screenshot: {t}", .{err});
        tools.finishScreenshot(&app, shot, "", "");
    };
}

fn renderShot(a: std.mem.Allocator, shot: App.Shot) !void {
    if (!canvas.makeCurrent()) return error.NoOpenGL;
    const pipe = &canvas.pipeline.?;
    const r = try app.recipe(a);
    looks.prepare(pipe, r);
    const size = pipe.outputSize(r, false);
    const longest: f64 = @floatFromInt(@max(size[0], size[1]));
    const scale = @min(1, @as(f64, tools.screenshot_edge) / longest);
    const w: c_int = @max(1, @as(c_int, @intFromFloat(@round(@as(f64, @floatFromInt(size[0])) * scale))));
    const h: c_int = @max(1, @as(c_int, @intFromFloat(@round(@as(f64, @floatFromInt(size[1])) * scale))));
    var t = try Pipeline.target(w, h, gl.RGBA8, gl.UNSIGNED_BYTE);
    defer t.free();
    pipe.render(r, .{ .fbo = t.fbo, .width = w, .height = h, .dither = 1.0 / 255.0 });
    gl.glBindFramebuffer(gl.FRAMEBUFFER, t.fbo);
    const count: usize = @intCast(w * h);
    const px = try a.alloc(u8, count * 4);
    gl.glReadPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, px.ptr);
    const rgb = try a.alloc(u8, count * 3);
    var hi: usize = 0;
    var rr: usize = 0;
    var gg: usize = 0;
    var bb: usize = 0;
    var lo: usize = 0;
    var sum: f64 = 0;
    var bins = [_]usize{0} ** screenshot_tones_bins;
    for (0..count) |i| {
        const R = px[i * 4];
        const G = px[i * 4 + 1];
        const B = px[i * 4 + 2];
        rgb[i * 3] = R;
        rgb[i * 3 + 1] = G;
        rgb[i * 3 + 2] = B;
        if (R == 255) rr += 1;
        if (G == 255) gg += 1;
        if (B == 255) bb += 1;
        if (R == 255 or G == 255 or B == 255) hi += 1;
        if (R <= 2 and G <= 2 and B <= 2) lo += 1;
        const l = 0.2126 * @as(f64, @floatFromInt(R)) + 0.7152 * @as(f64, @floatFromInt(G)) + 0.0722 * @as(f64, @floatFromInt(B));
        sum += l;
        bins[@min(15, @as(usize, @intFromFloat(l / 16)))] += 1;
    }
    const n: f64 = @floatFromInt(count);
    const pct = struct {
        fn f(x: usize, total: f64) f64 {
            return @round(@as(f64, @floatFromInt(x)) / total * 1000) / 10;
        }
    }.f;
    var histogram: [screenshot_tones_bins]f64 = undefined;
    for (bins, &histogram) |b, *o| o.* = pct(b, n);
    const tones = try std.json.Stringify.valueAlloc(a, .{
        .clipped_highlights = pct(hi, n),
        .clipped_red = pct(rr, n),
        .clipped_green = pct(gg, n),
        .clipped_blue = pct(bb, n),
        .crushed_shadows = pct(lo, n),
        .mean = @round(sum / n),
        .histogram = histogram,
    }, .{});
    const jpeg = try core.encode.jpegBytes(rgb, @intCast(w), @intCast(h), 85);
    defer core.vips.freeMemory(jpeg);
    const base64 = try a.alloc(u8, std.base64.standard.Encoder.calcSize(jpeg.len));
    _ = std.base64.standard.Encoder.encode(base64, jpeg);
    tools.finishScreenshot(&app, shot, base64, tones);
}

fn hookExport(call: *Mcp.Call, args: std.json.Value) anyerror!void {
    const f = &(app.folder orelse return error.NoFolder);
    var options = app.settings.@"export";
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var rels: std.ArrayList([]const u8) = .empty;
    var extras: Exporter.Extras = .{ .call = call };
    if (args == .object) {
        if (args.object.get("names")) |names| if (names == .array) for (names.array.items) |n| {
            if (n != .string) continue;
            try rels.append(a, f.photos[try tools.find(f, n.string)].rel);
        };
        if (args.object.get("format")) |v| if (v == .string) {
            options.format = std.meta.stringToEnum(core.encode.Format, v.string) orelse return error.BadFormat;
        };
        if (args.object.get("quality")) |v| if (v == .integer) {
            options.quality = @intCast(std.math.clamp(v.integer, 50, 100));
        };
        if (args.object.get("long_edge")) |v| if (v == .integer) {
            options.long_edge = @intCast(std.math.clamp(v.integer, 0, 100_000));
        };
        if (args.object.get("gps")) |v| if (v == .bool) {
            options.keep_gps = v.bool;
        };
        if (args.object.get("folder")) |v| if (v == .string) {
            if (!std.fs.path.isAbsolute(v.string)) return error.FolderNotAbsolute;
            options.folder = v.string;
        };
        if (args.object.get("name")) |v| if (v == .string) {
            extras.name = v.string;
            // A name of its own needs no "-edit".
            options.suffix = "";
        };
        if (args.object.get("aspect") != null or args.object.get("focus") != null) {
            var crop: std.json.ObjectMap = .empty;
            if (args.object.get("aspect")) |v| try crop.put(a, "aspect", v);
            if (args.object.get("focus")) |v| try crop.put(a, "focus", v);
            extras.crop = .{ .object = crop };
        }
    }
    if (rels.items.len == 0) try rels.append(a, f.photos[app.current orelse return error.NoPhoto].rel);
    // Exports always keep the camera, lens and date (SPEC.md).
    options.keep_metadata = true;
    try exporter.start(rels.items, options, extras);
}

fn exportGlCurrent() bool {
    return canvas.makeCurrent();
}

fn onActivate(application: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (gtk.gtk_settings_get_default()) |settings| gtk.g_object_set(settings, "gtk-interface-color-scheme", @as(c_int, 2), @as(?*anyopaque, null));
    const provider = gtk.gtk_css_provider_new();
    gtk.gtk_css_provider_load_from_string(provider, css);
    gtk.gtk_style_context_add_provider_for_display(gtk.gdk_display_get_default().?, provider, gtk.css_priority_application);

    window = gtk.gtk_application_window_new(application);
    gtk.gtk_window_set_title(window, "Doka");
    gtk.gtk_window_set_default_size(window, 1440, 900);
    const key = gtk.gtk_event_controller_key_new();
    connect(key, "key-pressed", &onKey, null);
    connect(key, "key-released", &onKeyUp, null);
    gtk.gtk_widget_add_controller(window, key);

    const column = gtk.gtk_box_new(gtk.vertical, 0);
    gtk.gtk_window_set_child(window, column);
    gtk.gtk_box_append(column, buildBar());
    const row = gtk.gtk_box_new(gtk.horizontal, 0);
    gtk.gtk_widget_set_vexpand(row, 1);
    gtk.gtk_box_append(column, row);
    gtk.gtk_box_append(row, sidebar.create());
    const stage = gtk.gtk_box_new(gtk.vertical, 0);
    gtk.gtk_widget_add_css_class(stage, "stage");
    gtk.gtk_widget_set_hexpand(stage, 1);
    gtk.gtk_box_append(stage, canvas.create());
    const footer = gtk.gtk_box_new(gtk.horizontal, 12);
    gtk.gtk_widget_add_css_class(footer, "footer");
    exif_label = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(exif_label, 0);
    gtk.gtk_widget_set_hexpand(exif_label, 1);
    zoom_label = gtk.gtk_label_new("Fit");
    gtk.gtk_widget_set_tooltip_text(zoom_label, "Scroll to zoom, drag to move");
    gtk.gtk_box_append(footer, exif_label);
    gtk.gtk_box_append(footer, zoom_label);
    gtk.gtk_box_append(stage, footer);
    gtk.gtk_box_append(row, stage);
    gtk.gtk_box_append(row, buildPanel());
    canvas.on_drawn = onDrawn;
    canvas.on_installed = onInstalled;
    canvas.on_crop = onCropDragged;
    sidebar.on_filter = syncHeader;
    export_dialog.parent = window;
    syncHeader();
    gtk.gtk_window_present(window);

    if (start_folder) |path| openFolder(path) else if (app.settings.last_folder.len > 0) {
        const path = gpa.dupeZ(u8, app.settings.last_folder) catch return;
        defer gpa.free(path);
        openFolder(path);
    }
}

fn onShutdown(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    app.flush();
}

// One picture of the photo in a file, with no window.
fn check(path: [:0]const u8, out_path: [:0]const u8) !void {
    const es = try selftest.context();
    var p = try Pipeline.init(gpa, es);
    var lin = try core.decode.linear(gpa, path, Canvas.preview_edge);
    defer lin.deinit(gpa);
    const w: c_int = @intCast(lin.width);
    const h: c_int = @intCast(lin.height);
    try p.setSource(w, h, lin.rgb.ptr);
    var t = try Pipeline.target(w, h, gl.RGBA8, gl.UNSIGNED_BYTE);
    defer t.free();
    p.render(.{}, .{ .fbo = t.fbo, .width = w, .height = h, .dither = 1.0 / 255.0 });
    gl.glBindFramebuffer(gl.FRAMEBUFFER, t.fbo);
    const px = try gpa.alloc(u8, @intCast(w * h * 4));
    defer gpa.free(px);
    gl.glReadPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, px.ptr);
    const file = std.c.fopen(out_path, "wb") orelse return error.CantWrite;
    defer _ = std.c.fclose(file);
    var head: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&head, "P6\n{d} {d}\n255\n", .{ w, h });
    _ = std.c.fwrite(line.ptr, 1, line.len, file);
    var i: usize = 0;
    while (i < px.len) : (i += 4) _ = std.c.fwrite(px[i..].ptr, 1, 3, file);
    std.debug.print("{d}x{d} saved to {s}\n", .{ w, h, out_path });
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    var it = try init.minimal.args.iterateAllocator(arena);
    _ = it.next();
    var check_out: ?[:0]const u8 = null;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            check_out = it.next() orelse return 2;
        } else if (std.mem.eql(u8, arg, "--probe")) {
            try core.vips.init("doka");
            defer core.vips.shutdown();
            return selftest.run(init.io) catch |err| {
                std.debug.print("probe: {t}\n", .{err});
                return 1;
            };
        } else start_folder = arg;
    }
    try core.vips.init("doka");
    defer core.vips.shutdown();
    if (check_out) |out| {
        check(start_folder orelse return 2, out) catch |err| {
            std.debug.print("check failed: {t}\n", .{err});
            return 1;
        };
        return 0;
    }

    pool = .{ .io = init.io };
    try pool.start();
    defer pool.stop();
    const config_dir = try Settings.configDir(arena, init.environ_map);
    var settings_arena: std.heap.ArenaAllocator = .init(gpa);
    const settings = Settings.load(init.io, settings_arena.allocator(), config_dir);
    library = try Library.init(gpa, init.io, config_dir);
    library.on_change = .{ .ctx = &library, .f = onLibraryChange };
    library.watch();
    app = .{ .gpa = gpa, .io = init.io, .config_dir = config_dir, .settings = settings, .settings_arena = &settings_arena, .library = &library };
    app.hooks = .{
        .edited = hookEdited,
        .photo_changed = hookPhotoChanged,
        .library_changed = hookLibraryChanged,
        .screenshot = hookScreenshot,
        .export_for_claude = hookExport,
        .compile_shader = hookCompile,
        .bake = hookBake,
    };
    defer app.deinit();
    const default_folder = try Settings.defaultExportFolder(arena, init.environ_map);
    exporter = .{ .gpa = gpa, .io = init.io, .app = &app, .pool = &pool, .default_folder = default_folder, .gl_current = exportGlCurrent, .looks = .{ .gpa = gpa, .library = &library }, .on_progress = onExportProgress, .on_done = onExportDone };
    export_dialog = .{ .gpa = gpa, .app = &app, .exporter = &exporter, .parent = undefined, .default_folder = default_folder, .settings_arena = &settings_arena };
    var mcp: Mcp = .{ .gpa = gpa, .io = init.io, .handler = .{ .ctx = &app, .call = onMcpCall, .activity = onMcpActivity, .tools = tools.definitions, .instructions = tools.instructions } };
    mcp.start() catch |err| log.warn("MCP server not started ({t}): is the app already open?", .{err});
    photos = .{ .gpa = gpa, .io = init.io, .pool = &pool, .on_decoded = onDecoded, .on_thumb = onThumb };
    looks = .{ .gpa = gpa, .library = &library, .pool = &pool, .on_ready = onLookParsed };
    preview_looks = .{ .gpa = gpa, .library = &library, .pool = &pool, .on_ready = onPreviewLookParsed };
    canvas = .{ .gpa = gpa, .photos = &photos, .looks = &looks };
    sidebar = .{ .gpa = gpa, .app = &app, .photos = &photos, .on_pick = pick };
    looks_panel = .{ .gpa = gpa, .app = &app, .canvas = &canvas, .library = &library, .edited = edited, .preview_looks = &preview_looks };

    const application = gtk.gtk_application_new("app.doka.Doka", gtk.non_unique);
    defer gtk.g_object_unref(application);
    connect(application, "activate", &onActivate, null);
    connect(application, "shutdown", &onShutdown, null);
    const code = gtk.g_application_run(application, 0, null);
    return if (canvas.failed) 1 else @intCast(code);
}
