//! What the page found out about WebGL2 at start-up (ui/main.ts, checkGpu). The pipeline renders in
//! float, so it needs float render targets on the real GPU, not a software renderer.
const std = @import("std");

pub const Report = struct {
    webgl2: bool = false,
    renderer: []const u8 = "",
    // EXT_color_buffer_float, and an RGBA32F framebuffer that is complete.
    float_render: bool = false,
    // Values outside 0..1 drawn into RGBA32F read back unclamped.
    float_readback: bool = false,
    half_float_render: bool = false,
    // OES_texture_float_linear: float textures can be sampled with filtering.
    float_linear: bool = false,
    max_texture_size: u32 = 0,
    @"error": []const u8 = "",

    pub fn ok(r: Report) bool {
        return r.webgl2 and r.float_render and r.float_readback and !r.software();
    }

    pub fn software(r: Report) bool {
        const names = [_][]const u8{ "llvmpipe", "softpipe", "SwiftShader", "Software" };
        for (names) |n| if (std.mem.indexOf(u8, r.renderer, n) != null) return true;
        return false;
    }
};

/// The argument list webview hands a bound function: `[{...report...}]`.
pub fn parse(arena: std.mem.Allocator, request: []const u8) !Report {
    const args = try std.json.parseFromSliceLeaky([]Report, arena, request, .{ .ignore_unknown_fields = true });
    if (args.len != 1) return error.BadReport;
    return args[0];
}

/// One of the pipeline's tests run on the GPU (ui/selftest.ts).
pub const TestResult = struct {
    name: []const u8,
    ok: bool,
    detail: []const u8 = "",
};
