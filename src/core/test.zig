const std = @import("std");
const testing = std.testing;

const vips = @import("vips.zig");

test "libvips links and starts" {
    try vips.init("doka-test");
    const v = vips.version();
    // 8.15 is the oldest with the metadata and ICC handling the export relies on.
    try testing.expect(v.major == 8 and v.minor >= 15);
}
