const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zig's own linker rejects the .sframe sections in GCC 16's crt1.o, so LLD links (as in oubliette).
    const use_lld = b.option(bool, "use_lld", "Link with LLD") orelse true;

    // photo-core: decode, colour, encode and metadata through libvips. No window.
    const core = b.addModule("photo-core", .{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core.linkSystemLibrary("vips", .{});

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
    root.linkSystemLibrary("opengl", .{});

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

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tests_mod.addImport("photo-core", core);
    // Zig runs only the root module's tests, so photo-core's are a second binary.
    const test_step = b.step("test", "Run unit tests");
    for ([_]*std.Build.Module{ tests_mod, core }) |module| {
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
