//! libvips, started once per process. Its C API is declared here by hand, only what we call:
//! Zig 0.16's translate-c can't read GLib's headers.

pub const Version = struct { major: c_int, minor: c_int };

pub fn init(argv0: [*:0]const u8) error{VipsInit}!void {
    if (c.vips_init(argv0) != 0) return error.VipsInit;
}

// libvips can't start again after this, so only at exit.
pub fn shutdown() void {
    c.vips_shutdown();
}

pub fn version() Version {
    return .{ .major = c.vips_version(0), .minor = c.vips_version(1) };
}

const c = struct {
    extern fn vips_init(argv0: [*:0]const u8) c_int;
    extern fn vips_shutdown() void;
    extern fn vips_version(flag: c_int) c_int;
};
