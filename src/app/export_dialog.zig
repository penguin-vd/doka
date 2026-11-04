//! The export dialog: format, quality, size, colour space, metadata and GPS, the folder. Exports the
//! selected photos, or the open one. What you choose is remembered.
const std = @import("std");
const core = @import("photo-core");
const gtk = @import("gtk.zig");
const App = @import("app.zig");
const Exporter = @import("exporter.zig");
const Slider = @import("slider.zig");
const Settings = @import("settings.zig");

const Dialog = @This();

const sizes = [_]u32{ 0, 3000, 2048, 1080 };

gpa: std.mem.Allocator,
app: *App,
exporter: *Exporter,
parent: *anyopaque,
default_folder: []const u8,
settings_arena: *std.heap.ArenaAllocator,
window: ?*anyopaque = null,
rels: std.ArrayList([]u8) = .empty,
options: Settings.Export = .{},
jpeg: *anyopaque = undefined,
png: *anyopaque = undefined,
srgb: *anyopaque = undefined,
p3: *anyopaque = undefined,
quality: *Slider = undefined,
size: *anyopaque = undefined,
keep: *anyopaque = undefined,
gps: *anyopaque = undefined,
warning: *anyopaque = undefined,
folder: *anyopaque = undefined,
suffix: *anyopaque = undefined,
summary: *anyopaque = undefined,
bar: *anyopaque = undefined,
progress: *anyopaque = undefined,
go: *anyopaque = undefined,
cancel: *anyopaque = undefined,
running: bool = false,

fn connect(object: *anyopaque, signal: [*:0]const u8, handler: anytype, data: ?*anyopaque) void {
    _ = gtk.g_signal_connect_data(object, signal, @ptrCast(handler), data, null, 0);
}

fn field(box: *anyopaque, label: [*:0]const u8, child: *anyopaque) void {
    const l = gtk.gtk_label_new(label);
    gtk.gtk_label_set_xalign(l, 0);
    gtk.gtk_widget_add_css_class(l, "faint");
    gtk.gtk_box_append(box, l);
    gtk.gtk_box_append(box, child);
}

fn pair(d: *Dialog, a: [*:0]const u8, b: [*:0]const u8, first: **anyopaque, second: **anyopaque, a_on: bool) *anyopaque {
    const row = gtk.gtk_box_new(gtk.horizontal, 0);
    gtk.gtk_widget_add_css_class(row, "linked");
    first.* = gtk.gtk_toggle_button_new_with_label(a);
    second.* = gtk.gtk_toggle_button_new_with_label(b);
    gtk.gtk_toggle_button_set_group(second.*, first.*);
    gtk.gtk_widget_set_hexpand(first.*, 1);
    gtk.gtk_widget_set_hexpand(second.*, 1);
    gtk.gtk_toggle_button_set_active(if (a_on) first.* else second.*, 1);
    connect(first.*, "toggled", &onChanged, d);
    gtk.gtk_box_append(row, first.*);
    gtk.gtk_box_append(row, second.*);
    return row;
}

fn onQuality(s: *Slider, v: f64, _: u64) void {
    const d: *Dialog = @ptrCast(@alignCast(s.config.ctx));
    d.options.quality = @intFromFloat(v);
    d.refresh();
}

/// Opens on these photos; does nothing while one's open.
pub fn open(d: *Dialog, rels: []const []const u8) void {
    if (d.window != null or rels.len == 0) return;
    for (d.rels.items) |r| d.gpa.free(r);
    d.rels.clearRetainingCapacity();
    for (rels) |r| d.rels.append(d.gpa, d.gpa.dupe(u8, r) catch return) catch return;
    d.options = d.app.settings.@"export";
    const w = gtk.gtk_window_new();
    d.window = w;
    gtk.gtk_window_set_transient_for(w, d.parent);
    gtk.gtk_window_set_modal(w, 1);
    gtk.gtk_window_set_default_size(w, 480, -1);
    var title_buf: [64]u8 = undefined;
    gtk.gtk_window_set_title(w, if (rels.len > 1) std.fmt.bufPrintZ(&title_buf, "Export {d} photos", .{rels.len}) catch "Export" else "Export photo");
    connect(w, "close-request", &onCloseRequest, d);
    const box = gtk.gtk_box_new(gtk.vertical, 8);
    gtk.gtk_widget_add_css_class(box, "dialog");
    gtk.gtk_window_set_child(w, box);

    field(box, "Format", d.pair("JPEG", "PNG 16-bit", &d.jpeg, &d.png, d.options.format == .jpeg));
    d.quality = Slider.create(d.gpa, .{ .label = "Quality", .min = 50, .max = 100, .reset = 90, .unit = .plain, .on_change = onQuality, .ctx = d });
    d.quality.set(@floatFromInt(d.options.quality));
    gtk.gtk_box_append(box, d.quality.widget);
    const size_names = [_]?[*:0]const u8{ "Original size", "Long edge 3000 px", "Long edge 2048 px", "Long edge 1080 px", null };
    d.size = gtk.gtk_drop_down_new_from_strings(&size_names);
    for (sizes, 0..) |s, i| if (s == d.options.long_edge) gtk.gtk_drop_down_set_selected(d.size, @intCast(i));
    connect(d.size, "notify::selected", &onChangedNotify, d);
    field(box, "Size", d.size);
    field(box, "Colour space", d.pair("sRGB", "Display P3", &d.srgb, &d.p3, d.options.space == .srgb));

    d.keep = gtk.gtk_check_button_new_with_label("Keep metadata: camera, lens, exposure, date, colour profile");
    gtk.gtk_check_button_set_active(d.keep, @intFromBool(d.options.keep_metadata));
    connect(d.keep, "toggled", &onChanged, d);
    gtk.gtk_box_append(box, d.keep);
    d.gps = gtk.gtk_check_button_new_with_label("Include GPS location (untick to strip it before sharing online)");
    gtk.gtk_check_button_set_active(d.gps, @intFromBool(d.options.keep_gps));
    connect(d.gps, "toggled", &onChanged, d);
    gtk.gtk_box_append(box, d.gps);
    d.warning = gtk.gtk_label_new("Camera, lens and date will be removed from the exported file.");
    gtk.gtk_label_set_xalign(d.warning, 0);
    gtk.gtk_widget_add_css_class(d.warning, "warning-text");
    gtk.gtk_box_append(box, d.warning);

    d.folder = gtk.gtk_entry_new();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    gtk.gtk_editable_set_text(d.folder, std.fmt.bufPrintZ(&buf, "{s}", .{if (d.options.folder.len > 0) d.options.folder else d.default_folder}) catch "");
    field(box, "Folder", d.folder);
    d.suffix = gtk.gtk_entry_new();
    gtk.gtk_editable_set_text(d.suffix, std.fmt.bufPrintZ(&buf, "{s}", .{d.options.suffix}) catch "");
    connect(d.suffix, "changed", &onChanged, d);
    field(box, "Added to the name", d.suffix);

    d.summary = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(d.summary, 0);
    gtk.gtk_label_set_wrap(d.summary, 1);
    gtk.gtk_widget_add_css_class(d.summary, "faint");
    gtk.gtk_box_append(box, d.summary);
    d.bar = gtk.gtk_progress_bar_new();
    gtk.gtk_widget_set_visible(d.bar, 0);
    gtk.gtk_box_append(box, d.bar);
    d.progress = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(d.progress, 0);
    gtk.gtk_label_set_wrap(d.progress, 1);
    gtk.gtk_box_append(box, d.progress);

    const foot = gtk.gtk_box_new(gtk.horizontal, 8);
    gtk.gtk_widget_set_halign(foot, 2);
    d.cancel = gtk.gtk_button_new_with_label("Cancel");
    connect(d.cancel, "clicked", &onCancel, d);
    d.go = gtk.gtk_button_new_with_label(if (rels.len > 1) "Export all" else "Export");
    gtk.gtk_widget_add_css_class(d.go, "accent");
    connect(d.go, "clicked", &onGo, d);
    gtk.gtk_box_append(foot, d.cancel);
    gtk.gtk_box_append(foot, d.go);
    gtk.gtk_box_append(box, foot);
    d.refresh();
    // Escape closes it; Enter exports.
    const keys = gtk.gtk_event_controller_key_new();
    connect(keys, "key-pressed", &onKey, d);
    gtk.gtk_widget_add_controller(w, keys);
    gtk.gtk_window_set_focus(w, d.go);
    gtk.gtk_window_present(w);
}

fn onKey(_: *anyopaque, key: c_uint, _: c_uint, _: c_uint, ctx: ?*anyopaque) callconv(.c) c_int {
    if (key != gtk.key_escape) return 0;
    onCancel(undefined, ctx);
    return 1;
}

fn onChanged(_: *anyopaque, ctx: ?*anyopaque) callconv(.c) void {
    const d: *Dialog = @ptrCast(@alignCast(ctx));
    d.read();
    d.refresh();
}

fn onChangedNotify(_: *anyopaque, _: *anyopaque, ctx: ?*anyopaque) callconv(.c) void {
    onChanged(undefined, ctx);
}

fn read(d: *Dialog) void {
    d.options.format = if (gtk.gtk_toggle_button_get_active(d.jpeg) != 0) .jpeg else .png;
    d.options.space = if (gtk.gtk_toggle_button_get_active(d.srgb) != 0) .srgb else .p3;
    const i = gtk.gtk_drop_down_get_selected(d.size);
    d.options.long_edge = if (i < sizes.len) sizes[i] else 0;
    d.options.keep_metadata = gtk.gtk_check_button_get_active(d.keep) != 0;
    d.options.keep_gps = gtk.gtk_check_button_get_active(d.gps) != 0;
}

fn refresh(d: *Dialog) void {
    const jpeg = d.options.format == .jpeg;
    gtk.gtk_widget_set_visible(d.quality.widget, @intFromBool(jpeg));
    gtk.gtk_widget_set_visible(d.gps, @intFromBool(d.options.keep_metadata));
    gtk.gtk_widget_set_visible(d.warning, @intFromBool(!d.options.keep_metadata));
    const first = d.rels.items[0];
    const base = std.fs.path.basename(first);
    const stem = base[0 .. std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len];
    var buf: [512]u8 = undefined;
    const more = d.rels.items.len - 1;
    var more_buf: [32]u8 = undefined;
    const tail = if (more > 0) std.fmt.bufPrint(&more_buf, " (+{d} more)", .{more}) catch "" else "";
    gtk.gtk_label_set_text(d.summary, std.fmt.bufPrintZ(&buf, "{s}{s}{s}{s}, {s}", .{ stem, std.mem.span(gtk.gtk_editable_get_text(d.suffix)), d.options.format.extension(), tail, if (d.options.space == .p3) "Display P3" else "sRGB" }) catch "");
}

fn onCancel(_: *anyopaque, ctx: ?*anyopaque) callconv(.c) void {
    const d: *Dialog = @ptrCast(@alignCast(ctx));
    if (d.running) return;
    if (d.window) |w| gtk.gtk_window_destroy(w);
    d.window = null;
}

fn onCloseRequest(_: *anyopaque, ctx: ?*anyopaque) callconv(.c) c_int {
    const d: *Dialog = @ptrCast(@alignCast(ctx));
    if (d.running) return 1;
    d.window = null;
    return 0;
}

fn onGo(_: *anyopaque, ctx: ?*anyopaque) callconv(.c) void {
    const d: *Dialog = @ptrCast(@alignCast(ctx));
    d.read();
    const keep = d.settings_arena.allocator();
    const folder = std.mem.span(gtk.gtk_editable_get_text(d.folder));
    d.options.folder = if (std.mem.eql(u8, folder, d.default_folder)) "" else keep.dupe(u8, folder) catch "";
    d.options.suffix = keep.dupe(u8, std.mem.span(gtk.gtk_editable_get_text(d.suffix))) catch "-edit";
    d.app.settings.@"export" = d.options;
    d.app.saveSettings();
    const rels: []const []const u8 = @ptrCast(d.rels.items);
    d.exporter.start(rels, d.options, .{}) catch |err| {
        var buf: [128]u8 = undefined;
        gtk.gtk_label_set_text(d.progress, std.fmt.bufPrintZ(&buf, "Export failed: {t}", .{err}) catch "Export failed");
        return;
    };
    d.running = true;
    gtk.gtk_widget_set_sensitive(d.go, 0);
    gtk.gtk_widget_set_sensitive(d.cancel, 0);
    gtk.gtk_widget_set_visible(d.bar, 1);
}

pub fn progress_(d: *Dialog, index: usize, total: usize, rel: []const u8) void {
    if (d.window == null) return;
    gtk.gtk_progress_bar_set_fraction(d.bar, @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(total)));
    var buf: [512]u8 = undefined;
    gtk.gtk_label_set_text(d.progress, std.fmt.bufPrintZ(&buf, "Exporting {s} ({d} of {d})…", .{ std.fs.path.basename(rel), index + 1, total }) catch "");
}

pub fn finished(d: *Dialog, folder: []const u8, results: []const Exporter.Result, ms: u64) void {
    d.running = false;
    if (d.window == null) return;
    gtk.gtk_progress_bar_set_fraction(d.bar, 1);
    var failed: usize = 0;
    for (results) |r| {
        if (r.@"error".len > 0) failed += 1;
    }
    var buf: [1024]u8 = undefined;
    const seconds = @as(f64, @floatFromInt(ms)) / 1000;
    const text = if (failed > 0)
        std.fmt.bufPrintZ(&buf, "{d} failed, first: {s} ({s})", .{ failed, results[0].rel, results[0].@"error" })
    else if (results.len == 1)
        std.fmt.bufPrintZ(&buf, "Saved {s} in {d:.1} s.", .{ results[0].path, seconds })
    else
        std.fmt.bufPrintZ(&buf, "Saved {d} photos to {s} in {d:.1} s.", .{ results.len, folder, seconds });
    gtk.gtk_label_set_text(d.progress, text catch "Done.");
    gtk.gtk_button_set_label(d.cancel, "Done");
    gtk.gtk_widget_set_sensitive(d.cancel, 1);
    // Enter closes it now.
    gtk.gtk_window_set_focus(d.window.?, d.cancel);
}
