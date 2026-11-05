const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zig's own linker rejects the .sframe sections in GCC 16's crt1.o, so LLD links (as in oubliette).
    // macOS has no GCC crt1.o, and Zig's LLD doesn't link Mach-O.
    const use_lld = b.option(bool, "use_lld", "Link with LLD") orelse (target.result.os.tag != .macos);

    // photo-core: decode, colour, encode and metadata through libvips. No window.
    const core = b.addModule("photo-core", .{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // macOS: vips' pkg-config lists glib's libraries that GTK's already lists, and dyld aborts on a
    // dylib loaded twice. vips' own load commands bring in glib, so the bare library is enough.
    core.linkSystemLibrary("vips", .{ .use_pkg_config = if (target.result.os.tag == .macos) .no else .yes });

    // The editor: GTK 4 and OpenGL over photo-core.
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = if (optimize == .ReleaseFast or optimize == .ReleaseSmall) true else null,
    });
    root.addImport("photo-core", core);
    root.linkSystemLibrary("gtk4", .{});
    // macOS has OpenGL as a framework; elsewhere it's libOpenGL.
    if (target.result.os.tag == .macos) root.linkFramework("OpenGL", .{}) else root.linkSystemLibrary("opengl", .{});

    const exe = b.addExecutable(.{
        .name = "doka",
        .root_module = root,
        .use_llvm = true,
        .use_lld = use_lld,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the editor").dependOn(&run_cmd.step);

    // No window: fails unless the pipeline's tests pass on the GPU.
    const probe_cmd = b.addRunArtifact(exe);
    probe_cmd.addArg("--probe");
    probe_cmd.setCwd(b.path("."));
    probe_cmd.has_side_effects = true;
    b.step("probe", "The pipeline's tests on the GPU, with no window").dependOn(&probe_cmd.step);

    // The test binary has no GTK, so it can take vips' pkg-config flags for glib on macOS.
    const core_tests = if (target.result.os.tag == .macos) b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) else core;
    if (core_tests != core) core_tests.linkSystemLibrary("vips", .{});
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tests_mod.addImport("photo-core", core_tests);
    // Zig runs only the root module's tests, so photo-core's are a second binary.
    const test_step = b.step("test", "Run unit tests");
    for ([_]*std.Build.Module{ tests_mod, core_tests }) |module| {
        const tests = b.addTest(.{
            .root_module = module,
            .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
            .use_llvm = true,
            .use_lld = use_lld,
        });
        const run = b.addRunArtifact(tests);
        run.setCwd(b.path(".")); // testdata/ resolves from the root
        test_step.dependOn(&run.step);
    }
}
