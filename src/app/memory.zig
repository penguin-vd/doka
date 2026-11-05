//! Hands freed heap pages back to the OS after a big decode. glibc only: macOS's allocator has no
//! malloc_trim, and its pages come back on their own.
const builtin = @import("builtin");

pub fn trim() void {
    if (builtin.os.tag != .linux) return;
    _ = malloc_trim(0);
}

extern fn malloc_trim(pad: usize) c_int;
