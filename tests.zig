// photo-core's tests are their own binary (build.zig): it is a separate module.
test {
    _ = @import("src/app/test.zig");
}
