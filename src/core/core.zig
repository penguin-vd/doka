//! photo-core: everything that touches pixels outside the GPU. Decode, colour, encode, metadata.
pub const vips = @import("vips.zig");

test {
    _ = @import("test.zig");
}
