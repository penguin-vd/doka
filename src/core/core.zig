//! photo-core: everything that touches pixels outside the GPU. Decode, colour, encode, metadata,
//! and the recipes that hold a photo's edits.
pub const vips = @import("vips.zig");
pub const decode = @import("decode.zig");
pub const encode = @import("encode.zig");
pub const exif = @import("exif.zig");
pub const Recipe = @import("recipe.zig");
pub const store = @import("store.zig");

test {
    _ = @import("test.zig");
    _ = @import("recipe_test.zig");
}
