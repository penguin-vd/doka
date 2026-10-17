const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zig's own linker rejects the .sframe sections in GCC 16's crt1.o, so LLD links (as in oubliette).
    const use_lld = b.option(bool, "use_lld", "Link with LLD") orelse true;

    // photo-core: decode, colour, encode and metadata through libvips. No window, no webview.
    const core = b.addModule("photo-core", .{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core.linkSystemLibrary("vips", .{});

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // The download stays small (SPEC.md: < 5 MB); ReleaseSafe keeps its stack traces.
        .strip = if (optimize == .ReleaseFast or optimize == .ReleaseSmall) true else null,
    });
    root.addImport("photo-core", core);
    addWebview(b, root);
    addUi(b, root);

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

    // The window opened briefly: fails unless WebGL2 renders to and reads back float targets on the GPU.
    const probe_cmd = b.addRunArtifact(exe);
    probe_cmd.addArg("--probe");
    probe_cmd.has_side_effects = true;
    b.step("probe", "Open the window, check WebGL2 float render targets, quit").dependOn(&probe_cmd.step);

    const tests_mod = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tests_mod.addImport("photo-core", core);
    addUi(b, tests_mod);
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

// webview is one C++11 source over WebKitGTK 4.1 and GTK 3, compiled into the app's own module: as a
// static library Zig would pack the system .so files into its archive and LLD rejects them.
fn addWebview(b: *std.Build, module: *std.Build.Module) void {
    const dep = b.dependency("webview", .{});
    module.link_libcpp = true;
    module.addCSourceFile(.{ .file = dep.path("core/src/webview.cc"), .flags = &.{ "-std=c++11", "-DWEBVIEW_STATIC" } });
    module.addIncludePath(dep.path("core/include"));
    // webview's own includes, and the WebKit calls it doesn't wrap (src/app/c.zig).
    module.linkSystemLibrary("gtk+-3.0", .{});
    module.linkSystemLibrary("webkit2gtk-4.1", .{});
}

// The page's files, embedded: every file under ui/, listed as `@import("ui_files")` for
// src/app/ui.zig. TypeScript is turned into JavaScript by Node's own type stripping
// (scripts/strip-types.mjs), so there are no npm packages; the page loads `x.js` for `x.ts`.
fn addUi(b: *std.Build, module: *std.Build.Module) void {
    var dir = b.build_root.handle.openDir(b.graph.io, "ui", .{ .iterate = true }) catch @panic("no ui/");
    defer dir.close(b.graph.io);
    var walker = dir.walk(b.allocator) catch @panic("OOM");
    var paths: std.ArrayList([]const u8) = .empty;
    while (walker.next(b.graph.io) catch @panic("walk ui/")) |entry| {
        if (entry.kind == .file) paths.append(b.allocator, b.dupe(entry.path)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);

    const table = b.addWriteFiles();
    const files = b.createModule(.{ .root_source_file = table.getDirectory().path(b, "ui_files.zig") });
    var list: std.Io.Writer.Allocating = .init(b.allocator);
    list.writer.writeAll("pub const files = .{\n") catch @panic("OOM");
    for (paths.items) |path| {
        const served = if (std.mem.endsWith(u8, path, ".ts")) b.fmt("{s}.js", .{path[0 .. path.len - 3]}) else path;
        const source = b.path(b.pathJoin(&.{ "ui", path }));
        if (std.mem.endsWith(u8, path, ".ts")) {
            const strip = b.addSystemCommand(&.{ "node", "--no-warnings" });
            strip.addFileArg(b.path("scripts/strip-types.mjs"));
            strip.addFileArg(source);
            files.addAnonymousImport(served, .{ .root_source_file = strip.addOutputFileArg(std.fs.path.basename(served)) });
        } else {
            files.addAnonymousImport(served, .{ .root_source_file = source });
        }
        list.writer.print("    .{{ \"{s}\", @embedFile(\"{s}\") }},\n", .{ served, served }) catch @panic("OOM");
    }
    list.writer.writeAll("};\n") catch @panic("OOM");
    _ = table.add("ui_files.zig", list.written());
    module.addImport("ui_files", files);
}
