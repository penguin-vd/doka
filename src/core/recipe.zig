//! A photo's edits: what the app shows, what Claude changes, what `.photo-editor/recipes/` keeps.
//! Field names are the JSON's (SPEC.md, Recipe format); only values that differ from the default
//! are written. Every field's default is "unchanged".
const std = @import("std");

const Recipe = @This();

pub const current_version = 1;

version: u32 = current_version,
edits: Edits = .{},
look: Look = .{},
shaders: []const ShaderUse = &.{},
colour: Colour = .{},
halation: f32 = 0,
grain: Grain = .{},
detail: Detail = .{},
vignette: f32 = 0,
crop: Crop = .{},
updatedBy: By = .user,
updatedAt: []const u8 = "",

pub const By = enum { user, claude };

pub const Edits = struct {
    exposure: f32 = 0,
    temperature: f32 = 0,
    tint: f32 = 0,
    contrast: f32 = 0,
    highlights: f32 = 0,
    shadows: f32 = 0,
    saturation: f32 = 0,
};

pub const no_look = "none";

pub const Look = struct {
    name: []const u8 = no_look,
    strength: f32 = 100,
};

pub const ShaderUse = struct {
    name: []const u8,
    strength: f32 = 100,
    enabled: bool = true,
    params: std.json.ArrayHashMap(f32) = .{},
};

pub const Band = struct {
    hue: f32 = 0,
    sat: f32 = 0,
    light: f32 = 0,
};

pub const Colour = struct {
    reds: Band = .{},
    oranges: Band = .{},
    yellows: Band = .{},
    greens: Band = .{},
    blues: Band = .{},
    purples: Band = .{},
};

pub const Grain = struct {
    amount: f32 = 0,
    size: f32 = 50,
};

pub const Detail = struct {
    sharpen: f32 = 0,
    noise: f32 = 0,
};

pub const aspects = [_][]const u8{ "original", "free", "1:1", "4:5", "3:2", "16:9" };

pub const Crop = struct {
    aspect: []const u8 = "original",
    straighten: f32 = 0,
    rotate: u16 = 0,
    flip: bool = false,
    // x, y, width, height, relative to the photo after rotation.
    rect: [4]f32 = .{ 0, 0, 1, 1 },
};

pub const max_exposure = 5;
pub const max_straighten = 45;
const min_crop = 0.02;

/// A recipe from its JSON, out-of-range values clamped. Strings live in `arena`.
pub fn parse(arena: std.mem.Allocator, json: []const u8) !Recipe {
    var r = try std.json.parseFromSliceLeaky(Recipe, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    if (r.version > current_version) return error.NewerRecipeVersion;
    r.clamp();
    return r;
}

/// `patch` merged into `base`: objects field by field, anything else replaced, null back to the
/// default. How `set_edits` and the page change a recipe without sending all of it.
pub fn apply(arena: std.mem.Allocator, base: Recipe, patch: std.json.Value) !Recipe {
    const full = try std.json.Stringify.valueAlloc(arena, base, .{});
    var merged = try std.json.parseFromSliceLeaky(std.json.Value, arena, full, .{});
    try mergeInto(arena, &merged, patch);
    var r = try std.json.parseFromValueLeaky(Recipe, arena, merged, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    r.clamp();
    return r;
}

fn mergeInto(arena: std.mem.Allocator, target: *std.json.Value, patch: std.json.Value) !void {
    if (patch != .object or target.* != .object) {
        target.* = patch;
        return;
    }
    var it = patch.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .null) {
            _ = target.object.orderedRemove(entry.key_ptr.*);
        } else if (target.object.getPtr(entry.key_ptr.*)) |existing| {
            try mergeInto(arena, existing, entry.value_ptr.*);
        } else {
            try target.object.put(arena, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
}

/// The recipe as the file keeps it: version and who changed it when, then only what isn't default.
pub fn write(r: Recipe, w: *std.Io.Writer) !void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };
    try writeObject(&s, r, &.{ "version", "updatedBy", "updatedAt" });
}

pub fn writeAlloc(r: Recipe, gpa: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try r.write(&out.writer);
    return out.toOwnedSlice();
}

/// True when nothing in it changes the photo.
pub fn isDefault(r: Recipe) bool {
    inline for (@typeInfo(Recipe).@"struct".fields) |f| {
        if (comptime isBookkeeping(f.name)) continue;
        if (!eql(@field(r, f.name), f.defaultValue().?)) return false;
    }
    return true;
}

fn isBookkeeping(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "version") or std.mem.eql(u8, name, "updatedBy") or std.mem.eql(u8, name, "updatedAt");
}

fn writeObject(s: *std.json.Stringify, v: anytype, comptime always: []const []const u8) !void {
    const T = @TypeOf(v);
    try s.beginObject();
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const value = @field(v, f.name);
        const keep = comptime blk: {
            for (always) |a| if (std.mem.eql(u8, a, f.name)) break :blk true;
            break :blk f.defaultValue() == null;
        };
        if (keep or !eql(value, f.defaultValue().?)) {
            try s.objectField(f.name);
            try writeValue(s, value);
        }
    }
    try s.endObject();
}

fn writeValue(s: *std.json.Stringify, value: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => if (@hasDecl(T, "jsonStringify")) try s.write(value) else try writeObject(s, value, &.{}),
        .pointer => |p| if (p.child == u8) try s.write(value) else {
            try s.beginArray();
            for (value) |item| try writeValue(s, item);
            try s.endArray();
        },
        // f32's shortest form: 0.3, not 0.30000001192092896.
        .float => try s.print("{d}", .{value}),
        else => try s.write(value),
    }
}

fn eql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .@"struct" => |st| {
            if (@hasField(T, "map")) return a.map.count() == 0 and b.map.count() == 0;
            inline for (st.fields) |f| if (!eql(@field(a, f.name), @field(b, f.name))) return false;
            return true;
        },
        .pointer => |p| return if (p.child == u8) std.mem.eql(u8, a, b) else a.len == 0 and b.len == 0,
        .array => {
            for (a, b) |x, y| if (!eql(x, y)) return false;
            return true;
        },
        else => return a == b,
    }
}

fn clampField(v: *f32, lo: f32, hi: f32) void {
    v.* = if (std.math.isNan(v.*)) 0 else std.math.clamp(v.*, lo, hi);
}

pub fn clamp(r: *Recipe) void {
    clampField(&r.edits.exposure, -max_exposure, max_exposure);
    inline for (.{ "temperature", "tint", "contrast", "highlights", "shadows", "saturation" }) |name| clampField(&@field(r.edits, name), -100, 100);
    clampField(&r.look.strength, 0, 100);
    if (r.look.name.len == 0) r.look.name = no_look;
    for (@constCast(r.shaders)) |*sh| clampField(&sh.strength, 0, 100);
    inline for (@typeInfo(Colour).@"struct".fields) |f| {
        const band = &@field(r.colour, f.name);
        inline for (.{ "hue", "sat", "light" }) |name| clampField(&@field(band, name), -100, 100);
    }
    inline for (.{ &r.halation, &r.grain.amount, &r.grain.size, &r.detail.sharpen, &r.detail.noise, &r.vignette }) |v| clampField(v, 0, 100);

    const known = for (aspects) |a| {
        if (std.mem.eql(u8, a, r.crop.aspect)) break true;
    } else false;
    if (!known) r.crop.aspect = "original";
    clampField(&r.crop.straighten, -max_straighten, max_straighten);
    r.crop.rotate = @intCast((@as(u32, r.crop.rotate) + 45) / 90 * 90 % 360);
    const rect = &r.crop.rect;
    clampField(&rect[0], 0, 1 - min_crop);
    clampField(&rect[1], 0, 1 - min_crop);
    clampField(&rect[2], min_crop, 1 - rect[0]);
    clampField(&rect[3], min_crop, 1 - rect[1]);
}

/// "2026-10-16T13:30:00Z" for `updatedAt`, from seconds since the epoch.
pub fn timestamp(buf: *[20]u8, epoch_seconds: u64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = epoch_seconds };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// An aspect ratio's width over height in pixels of a photo `size` (rotated) big; null for free.
pub fn aspectRatio(aspect: []const u8, size: [2]f64) ?f64 {
    if (std.mem.eql(u8, aspect, "free")) return null;
    if (std.mem.eql(u8, aspect, "original")) return size[0] / size[1];
    const colon = std.mem.indexOfScalar(u8, aspect, ':') orelse return null;
    const w = std.fmt.parseFloat(f64, aspect[0..colon]) catch return null;
    const h = std.fmt.parseFloat(f64, aspect[colon + 1 ..]) catch return null;
    return if (w > 0 and h > 0) w / h else null;
}

/// The biggest crop of `ratio` (null: the size `current` has) centred on `focus` (0..1 of the
/// rotated photo) as far as the photo allows: how an aspect and a point become a crop.rect.
pub fn fitCrop(current: [4]f32, ratio: ?f64, focus: [2]f64, size: [2]f64) [4]f32 {
    var w: f64 = current[2];
    var h: f64 = current[3];
    if (ratio) |r| {
        // In 0..1 units the width over height is the ratio times the photo's height over width.
        const k = r * size[1] / size[0];
        w = @min(1, k);
        h = w / k;
        if (h > 1) {
            h = 1;
            w = k;
        }
    }
    const x = std.math.clamp(focus[0] - w / 2, 0, 1 - w);
    const y = std.math.clamp(focus[1] - h / 2, 0, 1 - h);
    return .{ @floatCast(x), @floatCast(y), @floatCast(w), @floatCast(h) };
}
