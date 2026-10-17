const std = @import("std");
const testing = std.testing;

const gpu = @import("gpu.zig");
const ui = @import("ui.zig");

test "a GPU report with float targets on the RTX passes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try gpu.parse(arena.allocator(),
        \\[{"webgl2":true,"renderer":"NVIDIA GeForce RTX 3080/PCIe/SSE2","float_render":true,
        \\"float_readback":true,"half_float_render":true,"float_linear":true,"max_texture_size":32768,"extra":1}]
    );
    try testing.expect(r.ok());
    try testing.expectEqual(32768, r.max_texture_size);
}

test "a GPU report fails without float targets or on a software renderer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(!(try gpu.parse(a, "[{\"webgl2\":true,\"renderer\":\"NVIDIA\",\"float_render\":false}]")).ok());
    try testing.expect(!(try gpu.parse(a,
        \\[{"webgl2":true,"renderer":"llvmpipe (LLVM 20.1, 256 bits)","float_render":true,"float_readback":true}]
    )).ok());
    try testing.expectError(error.BadReport, gpu.parse(a, "[]"));
}

test "app:// URIs find the page's files" {
    try testing.expectEqualStrings("text/html", ui.find(ui.start).?.mime);
    try testing.expectEqualStrings("main.js", ui.find("app://ui/main.js?v=2").?.path);
    try testing.expect(ui.find("app://ui/../secret") == null);
    try testing.expect(ui.find("https://ui/index.html") == null);
}
