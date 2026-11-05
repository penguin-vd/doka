// photo-core's tests are their own binary (build.zig): it is a separate module.
test {
    _ = @import("src/app/test.zig");
    _ = @import("src/app/cube.zig");
    _ = @import("src/app/app.zig");
    _ = @import("src/app/sidebar.zig");
    _ = @import("src/app/slider.zig");
    _ = @import("src/app/crop.zig");
    _ = @import("src/app/masks_panel.zig");
    _ = @import("src/app/sheet.zig");
    _ = @import("src/app/subject.zig");
    _ = @import("src/app/subject_fetch.zig");
}
