//! The photos on the left: two to a row, separated by subfolder and by the day taken. A list view
//! makes widgets only for the rows in view, so a folder of thousands scrolls like one of ten.
const std = @import("std");
const gtk = @import("gtk.zig");
const App = @import("app.zig");
const Photos = @import("photos.zig");

const Sidebar = @This();

gpa: std.mem.Allocator,
app: *App,
photos: *Photos,
on_pick: *const fn (index: usize) void,
widget: *anyopaque = undefined,
view: *anyopaque = undefined,
rows: std.ArrayList(Row) = .empty,
// Which row each photo is on, for scrolling to it.
row_of: std.ArrayList(u32) = .empty,
// The rows in view: what a new thumbnail or a new current photo has to touch.
live: std.ArrayList(*RowUi) = .empty,
current: ?usize = null,
// Photos selected with Ctrl or Shift for a batch export.
selected: std.AutoHashMapUnmanaged(u32, void) = .empty,
count_label: *anyopaque = undefined,
name_label: *anyopaque = undefined,
day_menu: *anyopaque = undefined,
status_buttons: [4]*anyopaque = undefined,
sticky: *anyopaque = undefined,
adjustment: *anyopaque = undefined,
// The days in the menu, in its order after "All days".
days: std.ArrayList([]const u8) = .empty,
updating: bool = false,
on_filter: ?*const fn () void = null,

heading_seen: f64 = 0,

const width = 212;

const Row = union(enum) {
    folder: []const u8,
    day: struct { label: [32:0]u8, count: u32 },
    photos: [2]?u32,
};

const Cell = struct {
    frame: *anyopaque,
    picture: *anyopaque,
    dot: *anyopaque,
    pick_mark: *anyopaque,
    index: ?u32 = null,
    sidebar: *Sidebar,
};

const RowUi = struct {
    box: *anyopaque,
    title: *anyopaque,
    count: *anyopaque,
    heading: *anyopaque,
    cells_box: *anyopaque,
    cells: [2]Cell,
};

/// "Fri 7 Aug", with the year when the folder spans several, from "2026-08-07".
pub fn dayLabel(day: []const u8, with_year: bool, out: *[32:0]u8) void {
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    var w: std.Io.Writer = .fixed(out[0..31]);
    defer out[w.end] = 0;
    if (day.len < 10) {
        w.writeAll("No date") catch {};
        return;
    }
    const y = std.fmt.parseInt(i32, day[0..4], 10) catch 0;
    const m = std.fmt.parseInt(u32, day[5..7], 10) catch 1;
    const d = std.fmt.parseInt(u32, day[8..10], 10) catch 1;
    // Sakamoto's day of the week.
    const t = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    const yy = if (m < 3) y - 1 else y;
    const dow = @mod(yy + @divFloor(yy, 4) - @divFloor(yy, 100) + @divFloor(yy, 400) + t[@min(m, 12) - 1] + @as(i32, @intCast(d)), 7);
    if (with_year) {
        w.print("{s} {d} {s} {d}", .{ weekdays[@intCast(dow)], d, months[@min(m, 12) - 1], y }) catch {};
    } else {
        w.print("{s} {d} {s}", .{ weekdays[@intCast(dow)], d, months[@min(m, 12) - 1] }) catch {};
    }
}

test "a day reads as a person would say it" {
    var out: [32:0]u8 = undefined;
    dayLabel("2026-08-07", false, &out);
    try std.testing.expectEqualStrings("Fri 7 Aug", std.mem.sliceTo(&out, 0));
    dayLabel("2024-01-01", true, &out);
    try std.testing.expectEqualStrings("Mon 1 Jan 2024", std.mem.sliceTo(&out, 0));
    dayLabel("", false, &out);
    try std.testing.expectEqualStrings("No date", std.mem.sliceTo(&out, 0));
}

pub fn create(s: *Sidebar) *anyopaque {
    const factory = gtk.gtk_signal_list_item_factory_new();
    connect(factory, "setup", &onSetup, s);
    connect(factory, "bind", &onBind, s);
    connect(factory, "unbind", &onUnbind, s);
    s.view = gtk.gtk_list_view_new(null, factory);
    gtk.gtk_widget_add_css_class(s.view, "photo-list");
    const scrolled = gtk.gtk_scrolled_window_new();
    // External: the list is as wide as the sidebar, however big its thumbnails would like to be.
    gtk.gtk_scrolled_window_set_policy(scrolled, gtk.policy_external, 1);
    gtk.gtk_scrolled_window_set_child(scrolled, s.view);
    gtk.gtk_widget_set_size_request(scrolled, width, -1);
    gtk.gtk_widget_set_vexpand(scrolled, 1);
    gtk.gtk_widget_add_css_class(scrolled, "sidebar");
    s.adjustment = gtk.gtk_scrolled_window_get_vadjustment(scrolled);
    connect(s.adjustment, "value-changed", &onScrolled, s);
    const stack = gtk.gtk_overlay_new();
    gtk.gtk_overlay_set_child(stack, scrolled);
    s.sticky = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(s.sticky, 0);
    gtk.gtk_widget_add_css_class(s.sticky, "sticky-day");
    gtk.gtk_widget_set_valign(s.sticky, gtk.align_start);
    gtk.gtk_widget_set_can_target(s.sticky, 0);
    gtk.gtk_widget_set_visible(s.sticky, 0);
    gtk.gtk_overlay_add_overlay(stack, s.sticky);

    const column = gtk.gtk_box_new(gtk.vertical, 6);
    gtk.gtk_widget_add_css_class(column, "sidebar");
    gtk.gtk_widget_set_size_request(column, width, -1);
    // Its thumbnails want to expand; that mustn't make the sidebar expand: the photo gets the room.
    gtk.gtk_widget_set_hexpand(column, 0);
    const head = gtk.gtk_box_new(gtk.vertical, 0);
    gtk.gtk_widget_add_css_class(head, "sidebar-head");
    s.name_label = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(s.name_label, 0);
    s.count_label = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(s.count_label, 0);
    gtk.gtk_widget_add_css_class(s.count_label, "faint");
    gtk.gtk_box_append(head, s.name_label);
    gtk.gtk_box_append(head, s.count_label);
    gtk.gtk_box_append(column, head);
    const filters = gtk.gtk_box_new(gtk.vertical, 4);
    gtk.gtk_widget_add_css_class(filters, "filters");
    const buttons = gtk.gtk_box_new(gtk.horizontal, 0);
    gtk.gtk_widget_add_css_class(buttons, "linked");
    for (&s.status_buttons, [_][*:0]const u8{ "All", "Edited", "Not edited", "Picked" }, 0..) |*b, label, i| {
        b.* = gtk.gtk_toggle_button_new_with_label(label);
        gtk.gtk_widget_set_hexpand(b.*, 1);
        if (i > 0) gtk.gtk_toggle_button_set_group(b.*, s.status_buttons[0]);
        // On a row of its own: the sidebar is narrow.
        if (i < 3) gtk.gtk_box_append(buttons, b.*);
    }
    gtk.gtk_widget_set_tooltip_text(s.status_buttons[3], "The photos you or Claude picked; P picks the open one");
    gtk.gtk_toggle_button_set_active(s.status_buttons[0], 1);
    for (s.status_buttons) |b| connect(b, "toggled", &onStatus, s);
    gtk.gtk_box_append(filters, buttons);
    gtk.gtk_box_append(filters, s.status_buttons[3]);
    const none = [_]?[*:0]const u8{ "All days", null };
    s.day_menu = gtk.gtk_drop_down_new_from_strings(&none);
    connect(s.day_menu, "notify::selected", &onDay, s);
    gtk.gtk_box_append(filters, s.day_menu);
    gtk.gtk_box_append(column, filters);
    gtk.gtk_box_append(column, stack);
    gtk.gtk_widget_set_vexpand(stack, 1);
    s.widget = column;
    return column;
}

fn onStatus(_: *anyopaque, ctx: ?*anyopaque) callconv(.c) void {
    const s: *Sidebar = @ptrCast(@alignCast(ctx));
    if (s.updating) return;
    const list = [_]App.Status{ .all, .edited, .unedited, .picked };
    for (s.status_buttons, list) |b, status| if (gtk.gtk_toggle_button_get_active(b) != 0) {
        if (s.app.status == status) return;
        s.app.status = status;
    };
    s.refilter();
}

fn onDay(_: *anyopaque, _: *anyopaque, ctx: ?*anyopaque) callconv(.c) void {
    const s: *Sidebar = @ptrCast(@alignCast(ctx));
    if (s.updating) return;
    const i = gtk.gtk_drop_down_get_selected(s.day_menu);
    s.app.day = if (i >= 1 and i - 1 < s.days.items.len) s.days.items[i - 1] else "";
    s.refilter();
}

/// The picks changed: the marks and the count, and what the filter shows.
pub fn picksChanged(s: *Sidebar) void {
    s.showPickCount();
    if (s.app.status == .picked) s.buildAndShow();
    s.repaint();
}

fn showPickCount(s: *Sidebar) void {
    var count: usize = 0;
    if (s.app.folder) |*f| for (f.photos) |p| {
        count += @intFromBool(p.picked);
    };
    var buf: [32]u8 = undefined;
    gtk.gtk_button_set_label(s.status_buttons[3], if (count > 0) std.fmt.bufPrintZ(&buf, "Picked ({d})", .{count}) catch "Picked" else "Picked");
}

/// The open photo changed under a filter: the one left may drop out.
pub fn refilterQuiet(s: *Sidebar) void {
    s.buildAndShow();
}

fn refilter(s: *Sidebar) void {
    s.buildAndShow();
    if (s.on_filter) |f| f();
}

// The menu of days, with how many photos each has.
fn fillDays(s: *Sidebar) void {
    const f = &(s.app.folder orelse return);
    s.days.clearRetainingCapacity();
    for (f.photos) |p| {
        if (p.day.len == 0) continue;
        for (s.days.items) |d| {
            if (std.mem.eql(u8, d, p.day)) break;
        } else s.days.append(s.gpa, p.day) catch return;
    }
    std.mem.sort([]const u8, s.days.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const years = s.days.items.len > 0 and !std.mem.eql(u8, s.days.items[0][0..4], s.days.items[s.days.items.len - 1][0..4]);
    const strings = a.alloc(?[*:0]const u8, s.days.items.len + 2) catch return;
    strings[0] = "All days";
    strings[strings.len - 1] = null;
    var selected: c_uint = 0;
    for (s.days.items, strings[1 .. strings.len - 1], 1..) |d, *out, i| {
        var count: u32 = 0;
        for (f.photos) |p| {
            if (std.mem.eql(u8, p.day, d)) count += 1;
        }
        var label: [32:0]u8 = undefined;
        dayLabel(d, years, &label);
        out.* = std.fmt.allocPrintSentinel(a, "{s} ({d})", .{ std.mem.sliceTo(&label, 0), count }, 0) catch return;
        if (std.mem.eql(u8, d, s.app.day)) selected = @intCast(i);
    }
    s.updating = true;
    defer s.updating = false;
    const model = gtk.gtk_string_list_new(strings.ptr);
    gtk.gtk_drop_down_set_model(s.day_menu, model);
    gtk.g_object_unref(model);
    gtk.gtk_drop_down_set_selected(s.day_menu, selected);
    gtk.gtk_widget_set_visible(s.day_menu, @intFromBool(s.days.items.len > 1));
}

// The heading of the group at the top of the list stays in view. Rows of a kind are one height.
fn onScrolled(_: *anyopaque, ctx: ?*anyopaque) callconv(.c) void {
    const s: *Sidebar = @ptrCast(@alignCast(ctx));
    s.updateSticky();
}

fn updateSticky(s: *Sidebar) void {
    const top = gtk.gtk_adjustment_get_value(s.adjustment);
    var heading_h: f64 = 30;
    var photos_h: f64 = 75;
    for (s.live.items) |ui| photos_h = @max(1, @as(f64, @floatFromInt(gtk.gtk_widget_get_height(ui.box))));
    if (s.heading_seen > 0) heading_h = s.heading_seen;
    var y: f64 = 0;
    var label: ?[*:0]const u8 = null;
    for (s.rows.items) |*row| {
        const h = if (row.* == .photos) photos_h else heading_h;
        if (row.* == .day) {
            if (y > top) break;
            label = &row.day.label;
        }
        if (y > top) break;
        y += h;
    }
    if (label != null and top > heading_h / 2) {
        gtk.gtk_label_set_text(s.sticky, label.?);
        gtk.gtk_widget_set_visible(s.sticky, 1);
    } else gtk.gtk_widget_set_visible(s.sticky, 0);
}

fn connect(object: *anyopaque, signal: [*:0]const u8, handler: anytype, data: ?*anyopaque) void {
    _ = gtk.g_signal_connect_data(object, signal, @ptrCast(handler), data, null, 0);
}

/// Lays out the folder again: a new folder, or its dates arrived.
pub fn rebuild(s: *Sidebar) void {
    s.selected.clearRetainingCapacity();
    s.updating = true;
    gtk.gtk_toggle_button_set_active(s.status_buttons[@intFromEnum(s.app.status)], 1);
    s.updating = false;
    s.fillDays();
    s.showPickCount();
    var buf: [256]u8 = undefined;
    gtk.gtk_label_set_text(s.name_label, if (s.app.folder) |*f| std.fmt.bufPrintZ(&buf, "{s}", .{f.name()}) catch "" else "No folder");
    s.buildAndShow();
}

fn buildAndShow(s: *Sidebar) void {
    s.buildRows() catch return;
    if (s.app.folder) |*f| {
        var buf: [64]u8 = undefined;
        var shown: usize = 0;
        for (f.photos, 0..) |p, i| {
            if (i == s.app.current or s.app.matches(p)) shown += 1;
        }
        gtk.gtk_label_set_text(s.count_label, (if (s.app.filtered()) std.fmt.bufPrintZ(&buf, "{d} of {d}", .{ shown, f.photos.len }) else std.fmt.bufPrintZ(&buf, "{d} photos", .{f.photos.len})) catch "");
    }
    const strings = s.gpa.alloc(?[*:0]const u8, s.rows.items.len + 1) catch return;
    defer s.gpa.free(strings);
    @memset(strings[0 .. strings.len - 1], "");
    strings[strings.len - 1] = null;
    const model = gtk.gtk_no_selection_new(gtk.gtk_string_list_new(strings.ptr));
    gtk.gtk_list_view_set_model(s.view, model);
    gtk.g_object_unref(model);
    s.setCurrent(s.app.current);
}

fn buildRows(s: *Sidebar) !void {
    s.rows.clearRetainingCapacity();
    s.row_of.clearRetainingCapacity();
    const f = &(s.app.folder orelse return);
    try s.row_of.resize(s.gpa, f.photos.len);
    @memset(s.row_of.items, 0);
    var dated = false;
    var first_year: []const u8 = "";
    var years = false;
    for (f.photos) |p| if (p.day.len >= 4) {
        if (dated and !std.mem.eql(u8, first_year, p.day[0..4])) years = true;
        if (!dated) first_year = p.day[0..4];
        dated = true;
    };
    var dir: ?[]const u8 = null;
    var day: ?[]const u8 = null;
    var day_row: ?usize = null;
    var open: ?usize = null;
    for (f.photos, 0..) |p, i| {
        if (i != s.app.current and !s.app.matches(p)) continue;
        const d = std.fs.path.dirname(p.rel) orelse "";
        const new_dir = dir == null or !std.mem.eql(u8, dir.?, d);
        const new_day = day == null or !std.mem.eql(u8, day.?, p.day);
        if (new_dir and d.len > 0) try s.rows.append(s.gpa, .{ .folder = d });
        if (new_dir or new_day) {
            open = null;
            if (dated) {
                var label: [32:0]u8 = undefined;
                dayLabel(p.day, years, &label);
                day_row = s.rows.items.len;
                try s.rows.append(s.gpa, .{ .day = .{ .label = label, .count = 0 } });
            }
        }
        dir = d;
        day = p.day;
        if (day_row) |r| s.rows.items[r].day.count += 1;
        if (open) |r| {
            s.rows.items[r].photos[1] = @intCast(i);
            s.row_of.items[i] = @intCast(r);
            open = null;
        } else {
            s.row_of.items[i] = @intCast(s.rows.items.len);
            open = s.rows.items.len;
            try s.rows.append(s.gpa, .{ .photos = .{ @intCast(i), null } });
        }
    }
}

fn onSetup(_: *anyopaque, item: *anyopaque, ctx: ?*anyopaque) callconv(.c) void {
    const s: *Sidebar = @ptrCast(@alignCast(ctx));
    gtk.gtk_list_item_set_activatable(item, 0);
    gtk.gtk_list_item_set_selectable(item, 0);
    gtk.gtk_list_item_set_focusable(item, 0);
    const ui = s.gpa.create(RowUi) catch return;
    const box = gtk.gtk_box_new(gtk.vertical, 0);
    const heading = gtk.gtk_box_new(gtk.horizontal, 8);
    gtk.gtk_widget_add_css_class(heading, "group-title");
    const title = gtk.gtk_label_new(null);
    gtk.gtk_label_set_xalign(title, 0);
    gtk.gtk_widget_set_hexpand(title, 1);
    const count = gtk.gtk_label_new(null);
    gtk.gtk_widget_add_css_class(count, "faint");
    gtk.gtk_box_append(heading, title);
    gtk.gtk_box_append(heading, count);
    gtk.gtk_box_append(box, heading);
    const cells_box = gtk.gtk_box_new(gtk.horizontal, 4);
    gtk.gtk_widget_add_css_class(cells_box, "thumbs");
    gtk.gtk_box_append(box, cells_box);
    ui.* = .{ .box = box, .title = title, .count = count, .heading = heading, .cells_box = cells_box, .cells = undefined };
    for (&ui.cells) |*cell| {
        const frame = gtk.gtk_overlay_new();
        gtk.gtk_widget_add_css_class(frame, "thumb");
        gtk.gtk_widget_set_size_request(frame, (width - 28) / 2, (width - 28) / 3);
        gtk.gtk_widget_set_hexpand(frame, 1);
        const picture = gtk.gtk_picture_new();
        gtk.gtk_picture_set_content_fit(picture, gtk.fit_contain);
        gtk.gtk_overlay_set_child(frame, picture);
        const dot = gtk.gtk_box_new(gtk.horizontal, 0);
        gtk.gtk_widget_set_opacity(dot, 0);
        gtk.gtk_widget_add_css_class(dot, "thumb-dot");
        gtk.gtk_widget_set_halign(dot, 2);
        gtk.gtk_widget_set_valign(dot, gtk.align_start);
        gtk.gtk_overlay_add_overlay(frame, dot);
        const pick_mark = gtk.gtk_box_new(gtk.horizontal, 0);
        gtk.gtk_widget_set_opacity(pick_mark, 0);
        gtk.gtk_widget_add_css_class(pick_mark, "thumb-pick");
        gtk.gtk_widget_set_halign(pick_mark, gtk.align_start);
        gtk.gtk_widget_set_valign(pick_mark, gtk.align_start);
        gtk.gtk_overlay_add_overlay(frame, pick_mark);
        cell.* = .{ .frame = frame, .picture = picture, .dot = dot, .pick_mark = pick_mark, .sidebar = s };
        const click = gtk.gtk_gesture_click_new();
        connect(click, "released", &onClick, cell);
        gtk.gtk_widget_add_controller(frame, click);
        gtk.gtk_box_append(cells_box, frame);
    }
    gtk.g_object_set_data(box, "ui", ui);
    gtk.gtk_list_item_set_child(item, box);
}

fn uiOf(item: *anyopaque) ?*RowUi {
    const child = gtk.gtk_list_item_get_child(item) orelse return null;
    return @ptrCast(@alignCast(gtk.g_object_get_data(child, "ui")));
}

fn onBind(_: *anyopaque, item: *anyopaque, ctx: ?*anyopaque) callconv(.c) void {
    const s: *Sidebar = @ptrCast(@alignCast(ctx));
    const ui = uiOf(item) orelse return;
    const position = gtk.gtk_list_item_get_position(item);
    if (position >= s.rows.items.len) return;
    const f = &(s.app.folder orelse return);
    switch (s.rows.items[position]) {
        .folder => |name| {
            var buf: [256]u8 = undefined;
            const z = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch return;
            gtk.gtk_label_set_text(ui.title, z);
            gtk.gtk_label_set_text(ui.count, "");
            gtk.gtk_widget_set_visible(ui.heading, 1);
            gtk.gtk_widget_set_visible(ui.cells_box, 0);
        },
        .day => |*d| {
            var buf: [16]u8 = undefined;
            s.heading_seen = @floatFromInt(@max(gtk.gtk_widget_get_height(ui.box), 0));
            gtk.gtk_label_set_text(ui.title, &d.label);
            gtk.gtk_label_set_text(ui.count, std.fmt.bufPrintZ(&buf, "{d}", .{d.count}) catch "");
            gtk.gtk_widget_set_visible(ui.heading, 1);
            gtk.gtk_widget_set_visible(ui.cells_box, 0);
        },
        .photos => |indices| {
            gtk.gtk_widget_set_visible(ui.heading, 0);
            gtk.gtk_widget_set_visible(ui.cells_box, 1);
            for (&ui.cells, indices) |*cell, index| {
                cell.index = index;
                if (index) |i| {
                    var tip: [std.fs.max_path_bytes + 64]u8 = undefined;
                    gtk.gtk_widget_set_tooltip_text(cell.frame, std.fmt.bufPrintZ(&tip, "{s}\nCtrl or Shift-click to pick several for export", .{f.photos[i].rel}) catch null);
                    gtk.gtk_widget_remove_css_class(cell.frame, "empty");
                    gtk.gtk_picture_set_paintable(cell.picture, s.photos.thumb(f.photos[i].rel));
                    s.paintCell(cell);
                } else {
                    gtk.gtk_widget_set_tooltip_text(cell.frame, null);
                    gtk.gtk_picture_set_paintable(cell.picture, null);
                    gtk.gtk_widget_set_opacity(cell.dot, 0);
                    gtk.gtk_widget_add_css_class(cell.frame, "empty");
                    gtk.gtk_widget_remove_css_class(cell.frame, "current");
                    gtk.gtk_widget_remove_css_class(cell.frame, "selected");
                }
            }
            s.live.append(s.gpa, ui) catch {};
        },
    }
}

fn onUnbind(_: *anyopaque, item: *anyopaque, ctx: ?*anyopaque) callconv(.c) void {
    const s: *Sidebar = @ptrCast(@alignCast(ctx));
    const ui = uiOf(item) orelse return;
    for (s.live.items, 0..) |x, i| if (x == ui) {
        _ = s.live.swapRemove(i);
        break;
    };
    for (&ui.cells) |*cell| {
        cell.index = null;
        gtk.gtk_picture_set_paintable(cell.picture, null);
    }
}

fn paintCell(s: *Sidebar, cell: *Cell) void {
    const i = cell.index orelse return;
    const f = &(s.app.folder orelse return);
    // Opacity, not visibility: this runs while the list lays itself out.
    gtk.gtk_widget_set_opacity(cell.dot, if (f.photos[i].edited) 1 else 0);
    gtk.gtk_widget_set_opacity(cell.pick_mark, if (f.photos[i].picked) 1 else 0);
    if (s.current == @as(usize, i)) gtk.gtk_widget_add_css_class(cell.frame, "current") else gtk.gtk_widget_remove_css_class(cell.frame, "current");
    if (s.selected.count() > 1 and s.selected.contains(i)) gtk.gtk_widget_add_css_class(cell.frame, "selected") else gtk.gtk_widget_remove_css_class(cell.frame, "selected");
}

/// A thumbnail arrived: into its cell, if it's in view.
pub fn thumbArrived(s: *Sidebar, rel: []const u8, texture: *anyopaque) void {
    const f = &(s.app.folder orelse return);
    for (s.live.items) |ui| for (&ui.cells) |*cell| {
        const i = cell.index orelse continue;
        if (std.mem.eql(u8, f.photos[i].rel, rel)) gtk.gtk_picture_set_paintable(cell.picture, texture);
    };
}

/// Shows which photo is open, and brings it into view.
pub fn setCurrent(s: *Sidebar, index: ?usize) void {
    s.current = index;
    s.repaint();
    if (index) |i| if (i < s.row_of.items.len) gtk.gtk_list_view_scroll_to(s.view, s.row_of.items[i], 0, null);
}

/// The dots and the outline, for the rows in view.
pub fn repaint(s: *Sidebar) void {
    for (s.live.items) |ui| for (&ui.cells) |*cell| s.paintCell(cell);
}

fn onClick(controller: *anyopaque, _: c_int, _: f64, _: f64, ctx: ?*anyopaque) callconv(.c) void {
    const cell: *Cell = @ptrCast(@alignCast(ctx));
    const s = cell.sidebar;
    const i = cell.index orelse return;
    const state = gtk.gtk_event_controller_get_current_event_state(controller);
    if (state & gtk.control_mask != 0) {
        if (s.selected.count() == 0) if (s.current) |c| s.selected.put(s.gpa, @intCast(c), {}) catch {};
        if (!s.selected.remove(i)) s.selected.put(s.gpa, i, {}) catch {};
        return s.repaint();
    }
    if (state & gtk.shift_mask != 0) {
        if (s.current) |c| {
            s.selected.clearRetainingCapacity();
            const a = @min(c, i);
            const b = @max(c, i);
            const f = &(s.app.folder orelse return);
            for (a..b + 1) |n| if (n == c or s.app.matches(f.photos[n])) s.selected.put(s.gpa, @intCast(n), {}) catch {};
            return s.repaint();
        }
    }
    s.selected.clearRetainingCapacity();
    s.on_pick(i);
}

/// The photos selected for an export, in order, or none.
pub fn selection(s: *const Sidebar, a: std.mem.Allocator) ![]const []const u8 {
    if (s.selected.count() < 2) return &.{};
    const f = &(s.app.folder orelse return &.{});
    var out: std.ArrayList([]const u8) = .empty;
    for (f.photos, 0..) |p, i| if (s.selected.contains(@intCast(i))) try out.append(a, p.rel);
    return out.items;
}
