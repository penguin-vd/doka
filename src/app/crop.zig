//! The crop's arithmetic, with no window: fitting an aspect, moving and resizing. Rectangles are
//! x, y, w, h in 0..1 of the rotated photo.
const std = @import("std");

pub const Rect = [4]f64;
const min_size = 0.02;

/// The biggest rectangle of `ratio` centred where `rect` is, inside the photo.
pub fn fitAspect(rect: Rect, ratio: f64, photo: [2]f64) Rect {
    const cx = rect[0] + rect[2] / 2;
    const cy = rect[1] + rect[3] / 2;
    // In 0..1 units, width over height is the ratio times the photo's height over width.
    const k = ratio * (photo[1] / photo[0]);
    var w = @min(1, k);
    var h = w / k;
    if (h > 1) {
        h = 1;
        w = k;
    }
    return .{ std.math.clamp(cx - w / 2, 0, 1 - w), std.math.clamp(cy - h / 2, 0, 1 - h), w, h };
}

pub const Spot = union(enum) { frame, corner: Corner };

/// What a press at this place on the widget takes hold of: a corner, the frame, or nothing. `box` is
/// the photo on the widget (x, y, width, height).
pub fn spotAt(r: Rect, box: [4]f64, x: f64, y: f64, grab: f64) ?Spot {
    const left = box[0] + r[0] * box[2];
    const top = box[1] + r[1] * box[3];
    const right = left + r[2] * box[2];
    const bottom = top + r[3] * box[3];
    const near = struct {
        fn f(a: f64, b: f64, limit: f64) bool {
            return @abs(a - b) < limit;
        }
    }.f;
    if (near(y, top, grab)) {
        if (near(x, left, grab)) return .{ .corner = .nw };
        if (near(x, right, grab)) return .{ .corner = .ne };
    }
    if (near(y, bottom, grab)) {
        if (near(x, left, grab)) return .{ .corner = .sw };
        if (near(x, right, grab)) return .{ .corner = .se };
    }
    return if (x > left and x < right and y > top and y < bottom) .frame else null;
}

pub fn moved(r: Rect, dx: f64, dy: f64) Rect {
    return .{ std.math.clamp(r[0] + dx, 0, 1 - r[2]), std.math.clamp(r[1] + dy, 0, 1 - r[3]), r[2], r[3] };
}

pub const Corner = enum { nw, ne, sw, se };

/// The rectangle with one corner dragged; the opposite corner stays, the ratio holds.
pub fn resized(r: Rect, corner: Corner, dx: f64, dy: f64, ratio: ?f64, photo: [2]f64) Rect {
    const west = corner == .nw or corner == .sw;
    const north = corner == .nw or corner == .ne;
    const fx = if (west) r[0] + r[2] else r[0];
    const fy = if (north) r[1] + r[3] else r[1];
    var nw = @max(min_size, if (west) r[2] - dx else r[2] + dx);
    var nh = @max(min_size, if (north) r[3] - dy else r[3] + dy);
    const room_w = if (west) fx else 1 - fx;
    const room_h = if (north) fy else 1 - fy;
    nw = @min(nw, room_w);
    nh = @min(nh, room_h);
    if (ratio) |q| {
        const k = q * (photo[1] / photo[0]);
        // Follow whichever side moved more, then fit the room.
        if (nw / k > nh) nh = nw / k else nw = nh * k;
        if (nw > room_w) {
            nw = room_w;
            nh = nw / k;
        }
        if (nh > room_h) {
            nh = room_h;
            nw = nh * k;
        }
    }
    return .{ if (west) fx - nw else fx, if (north) fy - nh else fy, nw, nh };
}

/// How the last pass (finish.glsl) puts the photo on the output.
pub const Geometry = struct {
    rect: [4]f64 = .{ 0, 0, 1, 1 },
    turns: u2 = 0,
    flip: bool = false,
    // Radians.
    angle: f64 = 0,
    // The rotated photo's size.
    size: [2]f64,

    fn fit(g: Geometry) f64 {
        const s = @abs(@sin(g.angle));
        const c = @cos(g.angle);
        return @min(g.size[0] / (g.size[0] * c + g.size[1] * s), g.size[1] / (g.size[0] * s + g.size[1] * c));
    }

    /// A point of the output (0..1) in the photo as decoded: finish.glsl's source().
    pub fn toPhoto(g: Geometry, out: [2]f64) [2]f64 {
        const px = g.rect[0] + out[0] * g.rect[2];
        const py = g.rect[1] + out[1] * g.rect[3];
        const k = g.fit();
        const qx = (px - 0.5) * g.size[0] * k;
        const qy = (py - 0.5) * g.size[1] * k;
        const s = @sin(g.angle);
        const c = @cos(g.angle);
        var x = (c * qx + s * qy) / g.size[0] + 0.5;
        const y = (-s * qx + c * qy) / g.size[1] + 0.5;
        if (g.flip) x = 1 - x;
        return switch (g.turns) {
            0 => .{ x, y },
            1 => .{ y, 1 - x },
            2 => .{ 1 - x, 1 - y },
            3 => .{ 1 - y, x },
        };
    }

    /// A point of the photo as decoded on the output (0..1); outside when it's cropped away.
    pub fn fromPhoto(g: Geometry, photo: [2]f64) [2]f64 {
        const u = photo[0];
        const v = photo[1];
        var x: f64, const y: f64 = switch (g.turns) {
            0 => .{ u, v },
            1 => .{ 1 - v, u },
            2 => .{ 1 - u, 1 - v },
            3 => .{ v, 1 - u },
        };
        if (g.flip) x = 1 - x;
        const tx = (x - 0.5) * g.size[0];
        const ty = (y - 0.5) * g.size[1];
        const s = @sin(g.angle);
        const c = @cos(g.angle);
        const k = g.fit();
        const px = (c * tx - s * ty) / k / g.size[0] + 0.5;
        const py = (s * tx + c * ty) / k / g.size[1] + 0.5;
        return .{ (px - g.rect[0]) / g.rect[2], (py - g.rect[1]) / g.rect[3] };
    }
};

const testing = std.testing;

test "a point of the photo maps to the output and back, however it's cropped and turned" {
    for ([_]u2{ 0, 1, 2, 3 }) |turns| for ([_]bool{ false, true }) |flip| {
        const g: Geometry = .{ .rect = .{ 0.1, 0.2, 0.6, 0.5 }, .turns = turns, .flip = flip, .angle = 0.2, .size = .{ 3000, 2000 } };
        const back = g.toPhoto(g.fromPhoto(.{ 0.3, 0.7 }));
        try testing.expectApproxEqAbs(0.3, back[0], 1e-9);
        try testing.expectApproxEqAbs(0.7, back[1], 1e-9);
    };
}

test "with nothing done to it, the output is the photo" {
    const g: Geometry = .{ .size = .{ 3, 2 } };
    try testing.expectEqual([2]f64{ 0.25, 0.75 }, g.toPhoto(.{ 0.25, 0.75 }));
    try testing.expectEqual([2]f64{ 0.25, 0.75 }, g.fromPhoto(.{ 0.25, 0.75 }));
}

test "an aspect fits inside the photo, around where the crop was" {
    const r = fitAspect(.{ 0, 0, 1, 1 }, 1, .{ 3, 2 });
    try testing.expectApproxEqAbs(2.0 / 3.0, r[2], 1e-9);
    try testing.expectApproxEqAbs(1, r[3], 1e-9);
    try testing.expectApproxEqAbs(1.0 / 6.0, r[0], 1e-9);
}

test "a moved crop stays on the photo" {
    const r = moved(.{ 0.5, 0.5, 0.4, 0.4 }, 1, -1);
    try testing.expectApproxEqAbs(0.6, r[0], 1e-9);
    try testing.expectEqual(0, r[1]);
}

test "resizing keeps the opposite corner, and the ratio when there is one" {
    const free = resized(.{ 0.2, 0.2, 0.4, 0.4 }, .se, 0.1, -0.1, null, .{ 3, 2 });
    try testing.expectEqual(0.2, free[0]);
    try testing.expectApproxEqAbs(0.5, free[2], 1e-9);
    try testing.expectApproxEqAbs(0.3, free[3], 1e-9);
    const held = resized(.{ 0.2, 0.2, 0.4, 0.4 }, .nw, -0.1, 0, 1.5, .{ 3, 2 });
    try testing.expectApproxEqAbs(0.6, held[0] + held[2], 1e-9);
    try testing.expectApproxEqAbs(held[2], held[3], 1e-9);
}

test "a press takes hold of the crop's corner, its frame, or nothing" {
    const r: Rect = .{ 0.25, 0.25, 0.5, 0.5 };
    const box = [4]f64{ 10, 10, 400, 200 };
    try std.testing.expectEqual(Corner.nw, spotAt(r, box, 112, 58, 14).?.corner);
    try std.testing.expectEqual(Corner.se, spotAt(r, box, 308, 162, 14).?.corner);
    try std.testing.expect(spotAt(r, box, 200, 100, 14).? == .frame);
    try std.testing.expectEqual(null, spotAt(r, box, 20, 20, 14));
}
