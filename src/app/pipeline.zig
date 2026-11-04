//! The image pipeline (SPEC.md, Image pipeline) on OpenGL, with no window code: one implementation
//! for the preview, the look thumbnails, Claude's screenshots and the full-size export.
//!
//!   photo (linear, half float)
//!   → detail      noise reduction, sharpening        (only when set)
//!   → develop     the Adjust sliders, colour mixer, tone curve, the look's LUT
//!   → masks       each mask's own sliders and mixer, where it selects
//!   → shaders     each enabled shader, in order
//!   → halation    bright parts, blurred              (only when set)
//!   → finish      crop/straighten/rotate/flip, halation, vignette, grain, colour space, dither
const std = @import("std");
const core = @import("photo-core");
const gl = @import("gl.zig");
const Cube = @import("cube.zig");
const Recipe = core.Recipe;

const Pipeline = @This();

const common = @embedFile("glsl/common.glsl");
const vertex_source = @embedFile("glsl/vertex.glsl");
const effect_source = @embedFile("glsl/effect.glsl");
const adjust_source = @embedFile("glsl/adjust.glsl");

const band_count = 6;
// Halation's blur: sigma as a share of the photo's long edge.
const glow_sigma = 0.011;
const blur_taps_per_sigma = 5;
// A mask's blur at 100: its radius as a share of the long edge.
const mask_blur_reach = 0.025;

pub const Target = struct {
    texture: c_uint,
    fbo: c_uint,
    width: c_int,
    height: c_int,

    pub fn free(t: *Target) void {
        gl.glDeleteTextures(1, &t.texture);
        gl.glDeleteFramebuffers(1, &t.fbo);
    }
};

/// A render target; half floats unless asked otherwise.
pub fn target(width: c_int, height: c_int, internal: c_int, kind: c_uint) !Target {
    var t: Target = .{ .texture = 0, .fbo = 0, .width = width, .height = height };
    gl.glGenTextures(1, &t.texture);
    gl.glBindTexture(gl.TEXTURE_2D, t.texture);
    gl.glTexImage2D(gl.TEXTURE_2D, 0, internal, width, height, 0, gl.RGBA, kind, null);
    linearClamped(gl.TEXTURE_2D);
    gl.glGenFramebuffers(1, &t.fbo);
    gl.glBindFramebuffer(gl.FRAMEBUFFER, t.fbo);
    gl.glFramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t.texture, 0);
    if (gl.glCheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE) return error.FramebufferIncomplete;
    return t;
}

pub const Param = struct { name: []const u8, default: f32 = 0 };

pub const Compiled = struct {
    program: c_uint,
    params: []const Param,
    // A shader that looks at other pixels can't be baked into a LUT.
    colour_only: bool,
};

pub const Output = struct {
    // The framebuffer to draw into; `flip_y` for a window's, whose y runs up.
    fbo: c_uint,
    flip_y: bool = false,
    // Where in it, pixels from the bottom-left.
    x: c_int = 0,
    y: c_int = 0,
    width: c_int,
    height: c_int,
    p3: bool = false,
    // One step of the output's bit depth (1/255 for 8 bits); 0 for none.
    dither: f32 = 0,
    // The whole photo, for the Crop tab (it draws the crop over it).
    uncropped: bool = false,
    // The part of the output to draw, x, y, w, h in 0..1: zoom and pan.
    view: [4]f32 = .{ 0, 0, 1, 1 },
    // Only this rectangle is drawn: before/after.
    scissor: ?[4]c_int = null,
    // This mask drawn in red over the photo, to see where it is. Never in an export.
    show_mask: ?usize = null,
};

gpa: std.mem.Allocator,
es: bool,
curve: c_uint = 0,
detail: c_uint = 0,
develop: c_uint = 0,
mask: c_uint = 0,
bright: c_uint = 0,
blur: c_uint = 0,
finish: c_uint = 0,
vao: c_uint = 0,
lut: c_uint = 0,
lut_size: c_int = 2,
lut_min: [3]f32 = .{ 0, 0, 0 },
lut_max: [3]f32 = .{ 1, 1, 1 },
flat: c_uint = 0,
src: c_uint = 0,
width: c_int = 0,
height: c_int = 0,
a: ?Target = null,
b: ?Target = null,
c: ?Target = null,
glow_a: ?Target = null,
glow_b: ?Target = null,
shaders: std.StringHashMapUnmanaged(Compiled) = .empty,
// Subjects' saved masks on the GPU, by file name.
stored: std.StringHashMapUnmanaged(c_uint) = .empty,
// The result of everything before the last pass, and a hash of the recipe that made it: moving
// and zooming change only the last pass.
developed: ?*Target = null,
developed_key: u64 = 0,

/// The open folder: where subjects' saved masks are read from.
pub var masks_root: []const u8 = "";
// Each is a few MB on the GPU; they load again in a moment when one's needed.
const max_stored = 16;

/// The compiler's message after `error.ShaderCompile` or `error.ShaderLink`.
pub var last_error: []const u8 = "";
var error_buf: [4096]u8 = undefined;

fn versionLine(es: bool) []const u8 {
    return if (es) "#version 300 es\n" else "#version 410 core\n";
}

fn compile(kind: c_uint, parts: []const []const u8) !c_uint {
    const s = gl.glCreateShader(kind);
    errdefer gl.glDeleteShader(s);
    var buf: [1 << 18]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    for (parts) |p| try w.writeAll(p);
    try w.writeByte(0);
    const text: [*:0]const u8 = @ptrCast(w.buffered().ptr);
    gl.glShaderSource(s, 1, &text, null);
    gl.glCompileShader(s);
    var ok: c_int = 0;
    gl.glGetShaderiv(s, gl.COMPILE_STATUS, &ok);
    if (ok == 0) {
        var n: c_int = 0;
        gl.glGetShaderInfoLog(s, error_buf.len, &n, &error_buf);
        last_error = error_buf[0..@intCast(n)];
        return error.ShaderCompile;
    }
    return s;
}

fn program(es: bool, fragment: []const []const u8) !c_uint {
    // The vertex shader's own version line goes; the rest is the same in every OpenGL.
    const vertex_body = vertex_source[std.mem.indexOfScalar(u8, vertex_source, '\n').? + 1 ..];
    const vs = try compile(gl.VERTEX_SHADER, &.{ versionLine(es), vertex_body });
    defer gl.glDeleteShader(vs);
    var parts: [8][]const u8 = undefined;
    parts[0] = versionLine(es);
    parts[1] = common;
    @memcpy(parts[2..][0..fragment.len], fragment);
    const fs = try compile(gl.FRAGMENT_SHADER, parts[0 .. 2 + fragment.len]);
    defer gl.glDeleteShader(fs);
    const p = gl.glCreateProgram();
    errdefer gl.glDeleteProgram(p);
    gl.glAttachShader(p, vs);
    gl.glAttachShader(p, fs);
    gl.glLinkProgram(p);
    var ok: c_int = 0;
    gl.glGetProgramiv(p, gl.LINK_STATUS, &ok);
    if (ok == 0) {
        var n: c_int = 0;
        gl.glGetProgramInfoLog(p, error_buf.len, &n, &error_buf);
        last_error = error_buf[0..@intCast(n)];
        return error.ShaderLink;
    }
    return p;
}

fn linearClamped(kind: c_uint) void {
    gl.glTexParameteri(kind, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.glTexParameteri(kind, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.glTexParameteri(kind, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.glTexParameteri(kind, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
}

/// With a GL context current; `es` when it's OpenGL ES (GTK picks).
pub fn init(gpa: std.mem.Allocator, es: bool) !Pipeline {
    var p: Pipeline = .{ .gpa = gpa, .es = es };
    gl.glGenTextures(1, &p.curve);
    gl.glBindTexture(gl.TEXTURE_2D, p.curve);
    linearClamped(gl.TEXTURE_2D);
    p.detail = try program(es, &.{@embedFile("glsl/detail.glsl")});
    p.develop = try program(es, &.{ adjust_source, @embedFile("glsl/develop.glsl") });
    p.mask = try program(es, &.{ adjust_source, @embedFile("glsl/mask.glsl") });
    p.bright = try program(es, &.{@embedFile("glsl/bright.glsl")});
    p.blur = try program(es, &.{@embedFile("glsl/blur.glsl")});
    p.finish = try program(es, &.{@embedFile("glsl/finish.glsl")});
    // Core OpenGL draws nothing without a vertex array, even with no vertices in it.
    gl.glGenVertexArrays(1, &p.vao);
    gl.glGenTextures(1, &p.lut);
    p.setLook(null);
    gl.glGenTextures(1, &p.flat);
    gl.glBindTexture(gl.TEXTURE_2D, p.flat);
    const grey = [_]u8{ 128, 128, 128, 255 };
    gl.glPixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.glTexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, &grey);
    linearClamped(gl.TEXTURE_2D);
    return p;
}

// ---- The photo ----

/// A texture for a photo, to fill with `uploadRows`; the old photo stays until `installSource`.
pub fn newSource(width: c_int, height: c_int) c_uint {
    var t: c_uint = 0;
    gl.glGenTextures(1, &t);
    gl.glBindTexture(gl.TEXTURE_2D, t);
    gl.glTexImage2D(gl.TEXTURE_2D, 0, gl.RGB16F, width, height, 0, gl.RGB, gl.HALF_FLOAT, null);
    linearClamped(gl.TEXTURE_2D);
    return t;
}

/// Rows of linear half floats, RGB, from the top of the photo.
pub fn uploadRows(t: c_uint, width: c_int, y: c_int, rows: c_int, rgb: [*]const u16) void {
    gl.glBindTexture(gl.TEXTURE_2D, t);
    gl.glPixelStorei(gl.UNPACK_ALIGNMENT, 2);
    gl.glTexSubImage2D(gl.TEXTURE_2D, 0, 0, y, width, rows, gl.RGB, gl.HALF_FLOAT, rgb + @as(usize, @intCast(y * width * 3)));
}

pub fn installSource(p: *Pipeline, t: c_uint, width: c_int, height: c_int) !void {
    if (p.src != 0) gl.glDeleteTextures(1, &p.src);
    p.src = t;
    p.developed = null;
    if (width == p.width and height == p.height) return;
    for ([_]*?Target{ &p.a, &p.b, &p.c, &p.glow_a, &p.glow_b }) |slot| if (slot.*) |*old| {
        old.free();
        slot.* = null;
    };
    p.a = try target(width, height, gl.RGBA16F, gl.HALF_FLOAT);
    p.b = try target(width, height, gl.RGBA16F, gl.HALF_FLOAT);
    p.c = try target(width, height, gl.RGBA16F, gl.HALF_FLOAT);
    const gw = @max(1, @divFloor(width + 3, 4));
    const gh = @max(1, @divFloor(height + 3, 4));
    p.glow_a = try target(gw, gh, gl.RGBA16F, gl.HALF_FLOAT);
    p.glow_b = try target(gw, gh, gl.RGBA16F, gl.HALF_FLOAT);
    p.width = width;
    p.height = height;
}

/// Gives back the photo and its render targets: for a pipeline that was holding a full-size one.
pub fn release(p: *Pipeline) void {
    if (p.src != 0) gl.glDeleteTextures(1, &p.src);
    p.src = 0;
    for ([_]*?Target{ &p.a, &p.b, &p.c, &p.glow_a, &p.glow_b }) |slot| if (slot.*) |*old| {
        old.free();
        slot.* = null;
    };
    p.width = 0;
    p.height = 0;
    p.developed = null;
}

/// The whole photo at once.
pub fn setSource(p: *Pipeline, width: c_int, height: c_int, rgb: [*]const u16) !void {
    const t = newSource(width, height);
    uploadRows(t, width, 0, height, rgb);
    try p.installSource(t, width, height);
}

// ---- Looks and shaders ----

/// The look's LUT, or none.
pub fn setLook(p: *Pipeline, cube: ?*const Cube) void {
    const nothing = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0, 0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1 };
    const size: c_int = if (cube) |x| @intCast(x.size) else 2;
    const data: [*]const f32 = if (cube) |x| x.data.ptr else &nothing;
    gl.glBindTexture(gl.TEXTURE_3D, p.lut);
    gl.glPixelStorei(gl.UNPACK_ALIGNMENT, 4);
    gl.glTexImage3D(gl.TEXTURE_3D, 0, gl.RGB16F, size, size, size, 0, gl.RGB, gl.FLOAT, data);
    linearClamped(gl.TEXTURE_3D);
    gl.glTexParameteri(gl.TEXTURE_3D, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE);
    p.lut_size = size;
    p.lut_min = if (cube) |x| x.min else .{ 0, 0, 0 };
    p.lut_max = if (cube) |x| x.max else .{ 1, 1, 1 };
    p.developed = null;
}

/// Compiles a shader without installing it. On failure, `last_error` has the compiler's message.
pub fn compileShader(p: *Pipeline, params: []const Param, glsl: []const u8) !Compiled {
    var decls: std.Io.Writer.Allocating = .init(p.gpa);
    defer decls.deinit();
    for (params) |param| try decls.writer.print("uniform float u_{s};\n", .{param.name});
    const params_at = std.mem.indexOf(u8, effect_source, "//@params").?;
    const source_at = std.mem.indexOf(u8, effect_source, "//@source").?;
    const prog = try program(p.es, &.{
        effect_source[0..params_at],
        decls.written(),
        effect_source[params_at + "//@params".len .. source_at],
        glsl,
        effect_source[source_at + "//@source".len ..],
    });
    errdefer gl.glDeleteProgram(prog);
    const copied = try p.gpa.alloc(Param, params.len);
    for (params, copied) |from, *to| to.* = .{ .name = try p.gpa.dupe(u8, from.name), .default = from.default };
    var colour_only = true;
    for ([_][]const u8{ "u_image", "u_texel", "u_depth", "v_uv", "u_resolution" }) |word| {
        if (std.mem.indexOf(u8, glsl, word) != null) colour_only = false;
    }
    return .{ .program = prog, .params = copied, .colour_only = colour_only };
}

fn freeCompiled(p: *Pipeline, s: Compiled) void {
    gl.glDeleteProgram(s.program);
    for (s.params) |param| p.gpa.free(param.name);
    p.gpa.free(s.params);
}

/// A compiled shader that won't be installed: save_shader's check.
pub fn dropCompiled(p: *Pipeline, s: Compiled) void {
    p.freeCompiled(s);
}

/// Forgets every shader; each compiles again when a recipe next asks for it.
pub fn dropShaders(p: *Pipeline) void {
    var it = p.shaders.iterator();
    while (it.next()) |e| {
        p.freeCompiled(e.value_ptr.*);
        p.gpa.free(e.key_ptr.*);
    }
    p.shaders.clearRetainingCapacity();
    p.developed = null;
}

/// Installs a shader under its name (null removes it), replacing the old one.
pub fn setShader(p: *Pipeline, name: []const u8, compiled: ?Compiled) !void {
    p.developed = null;
    if (p.shaders.fetchRemove(name)) |old| {
        p.freeCompiled(old.value);
        p.gpa.free(old.key);
    }
    if (compiled) |s| try p.shaders.put(p.gpa, try p.gpa.dupe(u8, name), s);
}

pub fn hasShader(p: *const Pipeline, name: []const u8) bool {
    return p.shaders.contains(name);
}

// ---- Drawing ----

/// Size of the cropped, rotated output in source pixels.
pub fn outputSize(p: *const Pipeline, r: Recipe, uncropped: bool) [2]c_int {
    const turned = @mod(r.crop.rotate / 90, 2) == 1;
    const w: f32 = @floatFromInt(if (turned) p.height else p.width);
    const h: f32 = @floatFromInt(if (turned) p.width else p.height);
    const rw: f32 = if (uncropped) 1 else r.crop.rect[2];
    const rh: f32 = if (uncropped) 1 else r.crop.rect[3];
    return .{ @max(1, @as(c_int, @intFromFloat(@round(w * rw)))), @max(1, @as(c_int, @intFromFloat(@round(h * rh)))) };
}

fn at(prog: c_uint, name: [*:0]const u8) c_int {
    return gl.glGetUniformLocation(prog, name);
}

fn texture(prog: c_uint, name: [*:0]const u8, unit: c_uint, tex: c_uint) void {
    gl.glActiveTexture(gl.TEXTURE0 + unit);
    gl.glBindTexture(gl.TEXTURE_2D, tex);
    gl.glUniform1i(at(prog, name), @intCast(unit));
}

// The program on a target: fills all of it.
fn begin(prog: c_uint, fbo: c_uint, x: c_int, y: c_int, width: c_int, height: c_int, flip_y: bool) void {
    gl.glUseProgram(prog);
    gl.glBindFramebuffer(gl.FRAMEBUFFER, fbo);
    gl.glViewport(x, y, width, height);
    gl.glUniform1i(at(prog, "u_flip_y"), @intFromBool(flip_y));
}

fn drawPass() void {
    gl.glDrawArrays(gl.TRIANGLES, 0, 3);
    gl.glActiveTexture(gl.TEXTURE0);
}

fn runDevelop(p: *Pipeline, from: c_uint, to: *const Target, r: Recipe) void {
    const d = p.develop;
    begin(d, to.fbo, 0, 0, to.width, to.height, false);
    texture(d, "u_src", 0, from);
    p.setDevelopValues(r);
    drawPass();
}

// The uniforms of adjust.glsl.
fn setAdjustValues(prog: c_uint, e: Recipe.Edits, colour: Recipe.Colour) void {
    gl.glUniform1f(at(prog, "u_exposure"), e.exposure);
    gl.glUniform1f(at(prog, "u_temperature"), e.temperature / 100);
    gl.glUniform1f(at(prog, "u_tint"), e.tint / 100);
    gl.glUniform1f(at(prog, "u_contrast"), e.contrast / 100);
    gl.glUniform1f(at(prog, "u_highlights"), e.highlights / 100);
    gl.glUniform1f(at(prog, "u_shadows"), e.shadows / 100);
    gl.glUniform1f(at(prog, "u_whites"), e.whites / 100);
    gl.glUniform1f(at(prog, "u_blacks"), e.blacks / 100);
    gl.glUniform1f(at(prog, "u_vibrance"), e.vibrance / 100);
    gl.glUniform1f(at(prog, "u_saturation"), e.saturation / 100);
    var bands: [band_count * 3]f32 = undefined;
    inline for (.{ "reds", "oranges", "yellows", "greens", "blues", "purples" }, 0..) |name, i| {
        const b = @field(colour, name);
        bands[i * 3] = b.hue / 100;
        bands[i * 3 + 1] = b.sat / 100;
        bands[i * 3 + 2] = b.light / 100;
    }
    gl.glUniform3fv(at(prog, "u_bands"), band_count, &bands);
}

// A subject's mask, read from its file the first time. Null when there's none (yet, or any more).
fn storedMask(p: *Pipeline, name: []const u8) ?c_uint {
    if (name.len == 0) return null;
    if (p.stored.get(name)) |t| return t;
    const picture = core.store.loadMask(p.gpa, masks_root, name) catch return null;
    defer p.gpa.free(picture.pixels);
    if (p.stored.count() >= max_stored) p.dropStored();
    const key = p.gpa.dupe(u8, name) catch return null;
    p.stored.put(p.gpa, key, 0) catch {
        p.gpa.free(key);
        return null;
    };
    var t: c_uint = 0;
    gl.glGenTextures(1, &t);
    gl.glBindTexture(gl.TEXTURE_2D, t);
    gl.glPixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.glTexImage2D(gl.TEXTURE_2D, 0, gl.R8, @intCast(picture.width), @intCast(picture.height), 0, gl.RED, gl.UNSIGNED_BYTE, picture.pixels.ptr);
    linearClamped(gl.TEXTURE_2D);
    p.stored.getPtr(key).?.* = t;
    return t;
}

fn dropStored(p: *Pipeline) void {
    var it = p.stored.iterator();
    while (it.next()) |e| {
        gl.glDeleteTextures(1, e.value_ptr);
        p.gpa.free(e.key_ptr.*);
    }
    p.stored.clearRetainingCapacity();
}

fn runMask(p: *Pipeline, m: Recipe.Mask, show: bool, from: c_uint, to: *const Target) void {
    // Loading binds a texture of its own: before the pass's.
    const stored = if (m.shape == .subject) p.storedMask(m.file) else null;
    const blur = if (m.enabled) m.blur / 100 * mask_blur_reach else 0;
    if (blur > 0) {
        gl.glBindTexture(gl.TEXTURE_2D, from);
        gl.glGenerateMipmap(gl.TEXTURE_2D);
        gl.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    }
    defer if (blur > 0) {
        gl.glBindTexture(gl.TEXTURE_2D, from);
        gl.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    };
    const prog = p.mask;
    begin(prog, to.fbo, 0, 0, to.width, to.height, false);
    texture(prog, "u_image", 0, from);
    texture(prog, "u_photo", 1, p.src);
    if (m.enabled) setAdjustValues(prog, m.edits, m.colour) else setAdjustValues(prog, .{}, .{});
    texture(prog, "u_stored", 2, stored orelse p.flat);
    gl.glUniform1i(at(prog, "u_shape"), if (m.shape == .subject and stored == null) 4 else @intFromEnum(m.shape));
    gl.glUniform2f(at(prog, "u_from"), m.from[0], m.from[1]);
    gl.glUniform2f(at(prog, "u_to"), m.to[0], m.to[1]);
    gl.glUniform2f(at(prog, "u_centre"), m.centre[0], m.centre[1]);
    gl.glUniform2f(at(prog, "u_radius"), m.radius[0], m.radius[1]);
    gl.glUniform1f(at(prog, "u_feather"), m.feather / 100);
    gl.glUniform1i(at(prog, "u_invert"), @intFromBool(m.invert));
    gl.glUniform2f(at(prog, "u_brightness"), m.brightness.min / 100, m.brightness.max / 100);
    gl.glUniform1f(at(prog, "u_hue"), m.hue.centre);
    gl.glUniform1f(at(prog, "u_hue_width"), m.hue.width);
    gl.glUniform2f(at(prog, "u_size"), @floatFromInt(p.width), @floatFromInt(p.height));
    gl.glUniform1i(at(prog, "u_show"), @intFromBool(show));
    gl.glUniform1f(at(prog, "u_blur"), blur);
    // 64 taps over the disc are about 8 across: each covers that share of its width.
    const across = blur * 2 * @as(f32, @floatFromInt(@max(p.width, p.height))) / 8;
    gl.glUniform1f(at(prog, "u_blur_lod"), std.math.log2(@max(1, across)));
    drawPass();
}

fn setDevelopValues(p: *Pipeline, r: Recipe) void {
    const d = p.develop;
    gl.glActiveTexture(gl.TEXTURE0 + 7);
    gl.glBindTexture(gl.TEXTURE_3D, p.lut);
    gl.glUniform1i(at(d, "u_lut"), 7);
    setAdjustValues(d, r.edits, r.colour);
    gl.glActiveTexture(gl.TEXTURE0 + 6);
    gl.glBindTexture(gl.TEXTURE_2D, p.curve);
    gl.glUniform1i(at(d, "u_curve"), 6);
    gl.glUniform1i(at(d, "u_curve_on"), @intFromBool(r.curve.len > 0));
    if (r.curve.len > 0) {
        var table: [Recipe.curve_samples]f32 = undefined;
        Recipe.curveTable(r.curve, &table);
        gl.glPixelStorei(gl.UNPACK_ALIGNMENT, 4);
        gl.glTexImage2D(gl.TEXTURE_2D, 0, gl.R16F, table.len, 1, 0, gl.RED, gl.FLOAT, &table);
    }
    const has_look = !std.mem.eql(u8, r.look.name, Recipe.no_look) and r.look.strength > 0 and p.lut_size > 2;
    gl.glUniform1f(at(d, "u_lut_size"), @floatFromInt(p.lut_size));
    gl.glUniform3f(at(d, "u_lut_min"), p.lut_min[0], p.lut_min[1], p.lut_min[2]);
    gl.glUniform3f(at(d, "u_lut_max"), p.lut_max[0], p.lut_max[1], p.lut_max[2]);
    gl.glUniform1f(at(d, "u_lut_strength"), if (has_look) r.look.strength / 100 else 0);
}

fn runShader(p: *Pipeline, s: Compiled, use: Recipe.ShaderUse, from: c_uint, to: *const Target, width: c_int, height: c_int) void {
    const prog = s.program;
    begin(prog, to.fbo, 0, 0, to.width, to.height, false);
    texture(prog, "u_image", 0, from);
    texture(prog, "u_depth", 1, p.flat);
    gl.glUniform1f(at(prog, "u_strength"), use.strength / 100);
    gl.glUniform2f(at(prog, "u_texel"), 1.0 / @as(f32, @floatFromInt(width)), 1.0 / @as(f32, @floatFromInt(height)));
    gl.glUniform2f(at(prog, "u_resolution"), @floatFromInt(width), @floatFromInt(height));
    for (s.params) |param| {
        var buf: [96]u8 = undefined;
        const name = std.fmt.bufPrintZ(&buf, "u_{s}", .{param.name}) catch continue;
        gl.glUniform1f(at(prog, name), use.params.map.get(param.name) orelse param.default);
    }
    drawPass();
}

// What the recipe changes before the last pass, as a number: crop, grain and vignette are the last
// pass's, the date doesn't change a pixel. 0 when it doesn't fit: nothing is reused then.
fn developKey(r: Recipe) u64 {
    var copy = r;
    copy.crop = .{};
    copy.grain = .{};
    copy.vignette = 0;
    copy.updatedAt = "";
    copy.updatedBy = .user;
    var buf: [1 << 15]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    std.json.Stringify.value(copy, .{}, &w) catch return 0;
    return std.hash.Wyhash.hash(0, w.buffered()) | 1;
}

pub fn render(p: *Pipeline, r: Recipe, out: Output) void {
    if (p.src == 0) return;
    gl.glDisable(gl.BLEND);
    gl.glDisable(gl.DEPTH_TEST);
    gl.glDisable(gl.SCISSOR_TEST);
    gl.glBindVertexArray(p.vao);
    const halation = r.halation / 100;
    var key = developKey(r);
    if (key != 0) if (out.show_mask) |i| {
        key = (key +% (i + 1) *% 0x9E3779B97F4A7C15) | 1;
    };
    const developed: *Target = if (p.developed != null and key != 0 and key == p.developed_key) p.developed.? else p.runChain(r, key, halation, out.show_mask);
    gl.glBindTexture(gl.TEXTURE_2D, developed.texture);
    // A preview smaller than the photo samples a mipmap, not every few pixels.
    gl.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);

    const turns: c_int = @intCast(@mod(r.crop.rotate / 90, 4));
    const odd = @mod(turns, 2) == 1;
    const rect = if (out.uncropped) [4]f32{ 0, 0, 1, 1 } else r.crop.rect;
    if (out.scissor) |c| {
        gl.glEnable(gl.SCISSOR_TEST);
        gl.glScissor(c[0], c[1], c[2], c[3]);
    }
    const f = p.finish;
    begin(f, out.fbo, out.x, out.y, out.width, out.height, out.flip_y);
    texture(f, "u_image", 0, developed.texture);
    texture(f, "u_glow", 1, p.glow_a.?.texture);
    gl.glUniform1f(at(f, "u_halation"), halation);
    gl.glUniform4f(at(f, "u_rect"), rect[0], rect[1], rect[2], rect[3]);
    gl.glUniform1i(at(f, "u_turns"), turns);
    gl.glUniform1i(at(f, "u_flip"), @intFromBool(r.crop.flip));
    gl.glUniform1f(at(f, "u_angle"), std.math.degreesToRadians(r.crop.straighten));
    const pw: f32 = @floatFromInt(p.width);
    const ph: f32 = @floatFromInt(p.height);
    gl.glUniform2f(at(f, "u_size"), if (odd) ph else pw, if (odd) pw else ph);
    gl.glUniform1f(at(f, "u_vignette"), r.vignette / 100);
    gl.glUniform1f(at(f, "u_grain"), r.grain.amount / 100);
    gl.glUniform1f(at(f, "u_grain_size"), r.grain.size / 100);
    gl.glUniform2f(at(f, "u_out"), @as(f32, @floatFromInt(out.width)) / out.view[2], @as(f32, @floatFromInt(out.height)) / out.view[3]);
    gl.glUniform4f(at(f, "u_view"), out.view[0], out.view[1], out.view[2], out.view[3]);
    gl.glUniform1i(at(f, "u_p3"), @intFromBool(out.p3));
    gl.glUniform1f(at(f, "u_dither"), out.dither);
    drawPass();
    gl.glDisable(gl.SCISSOR_TEST);
    gl.glBindTexture(gl.TEXTURE_2D, developed.texture);
    gl.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
}

// Everything before the last pass.
fn runChain(p: *Pipeline, r: Recipe, key: u64, halation: f32, show_mask: ?usize) *Target {
    var cur = p.src;
    const texel = [2]f32{ 1.0 / @as(f32, @floatFromInt(p.width)), 1.0 / @as(f32, @floatFromInt(p.height)) };
    if (r.detail.noise > 0 or r.detail.sharpen > 0) {
        const d = p.detail;
        begin(d, p.a.?.fbo, 0, 0, p.width, p.height, false);
        texture(d, "u_src", 0, cur);
        gl.glUniform2f(at(d, "u_texel"), texel[0], texel[1]);
        gl.glUniform1f(at(d, "u_noise"), r.detail.noise / 100);
        gl.glUniform1f(at(d, "u_sharpen"), r.detail.sharpen / 100);
        drawPass();
        cur = p.a.?.texture;
    }
    p.runDevelop(cur, &p.b.?, r);
    var current: *Target = &p.b.?;
    for (r.masks, 0..) |m, i| {
        const show = show_mask == i;
        if (!show and (!m.enabled or !m.hasEdits())) continue;
        const next: *Target = if (current == &p.b.?) &p.c.? else &p.b.?;
        p.runMask(m, show, current.texture, next);
        current = next;
    }
    for (r.shaders) |use| {
        const s = p.shaders.get(use.name) orelse continue;
        if (!use.enabled or use.strength <= 0) continue;
        const next: *Target = if (current == &p.b.?) &p.c.? else &p.b.?;
        p.runShader(s, use, current.texture, next, p.width, p.height);
        current = next;
    }
    if (halation > 0) {
        const ga = &p.glow_a.?;
        const gb = &p.glow_b.?;
        begin(p.bright, ga.fbo, 0, 0, ga.width, ga.height, false);
        texture(p.bright, "u_image", 0, current.texture);
        gl.glUniform2f(at(p.bright, "u_texel"), texel[0], texel[1]);
        drawPass();
        const gw: f32 = @floatFromInt(ga.width);
        const gh: f32 = @floatFromInt(ga.height);
        const step = glow_sigma * @max(gw, gh) / blur_taps_per_sigma;
        begin(p.blur, gb.fbo, 0, 0, gb.width, gb.height, false);
        texture(p.blur, "u_image", 0, ga.texture);
        gl.glUniform2f(at(p.blur, "u_step"), step / gw, 0);
        drawPass();
        begin(p.blur, ga.fbo, 0, 0, ga.width, ga.height, false);
        texture(p.blur, "u_image", 0, gb.texture);
        gl.glUniform2f(at(p.blur, "u_step"), 0, step / gh);
        drawPass();
    }
    gl.glBindTexture(gl.TEXTURE_2D, current.texture);
    gl.glGenerateMipmap(gl.TEXTURE_2D);
    p.developed = current;
    p.developed_key = key;
    return current;
}

/// The colour part of the pipeline (develop, look, colour-only shaders) on a lattice: bake_look.
/// size³ × RGB, for `gpa` to free.
pub fn bakeLattice(p: *Pipeline, gpa: std.mem.Allocator, r: Recipe, size: u32) ![]f32 {
    const n: usize = size;
    const w: c_int = @intCast(n * n);
    const h: c_int = @intCast(n);
    const decode = struct {
        fn f(v: f32) f32 {
            return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
        }
    }.f;
    const scale: f32 = @floatFromInt(n - 1);
    const input = try gpa.alloc(f32, n * n * n * 3);
    defer gpa.free(input);
    for (0..n) |b| for (0..n) |g| for (0..n) |red| {
        const i = (b * n * n + g * n + red) * 3;
        input[i] = decode(@as(f32, @floatFromInt(red)) / scale);
        input[i + 1] = decode(@as(f32, @floatFromInt(g)) / scale);
        input[i + 2] = decode(@as(f32, @floatFromInt(b)) / scale);
    };
    var src: c_uint = 0;
    gl.glGenTextures(1, &src);
    defer gl.glDeleteTextures(1, &src);
    gl.glBindTexture(gl.TEXTURE_2D, src);
    gl.glPixelStorei(gl.UNPACK_ALIGNMENT, 4);
    gl.glTexImage2D(gl.TEXTURE_2D, 0, gl.RGB32F, w, h, 0, gl.RGB, gl.FLOAT, input.ptr);
    gl.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    var t1 = try target(w, h, gl.RGBA32F, gl.FLOAT);
    defer t1.free();
    var t2 = try target(w, h, gl.RGBA32F, gl.FLOAT);
    defer t2.free();
    for ([_]c_uint{ t1.texture, t2.texture }) |t| {
        gl.glBindTexture(gl.TEXTURE_2D, t);
        gl.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    }
    gl.glDisable(gl.BLEND);
    gl.glDisable(gl.DEPTH_TEST);
    gl.glDisable(gl.SCISSOR_TEST);
    gl.glBindVertexArray(p.vao);
    p.runDevelop(src, &t1, r);
    var cur = &t1;
    for (r.shaders) |use| {
        const s = p.shaders.get(use.name) orelse continue;
        if (!s.colour_only or !use.enabled or use.strength <= 0) continue;
        const next = if (cur == &t1) &t2 else &t1;
        p.runShader(s, use, cur.texture, next, w, h);
        cur = next;
    }
    gl.glBindFramebuffer(gl.FRAMEBUFFER, cur.fbo);
    const rgba = try gpa.alloc(f32, n * n * n * 4);
    defer gpa.free(rgba);
    gl.glReadPixels(0, 0, w, h, gl.RGBA, gl.FLOAT, rgba.ptr);
    const rgb = try gpa.alloc(f32, n * n * n * 3);
    for (0..n * n * n) |i| for (0..3) |k| {
        rgb[i * 3 + k] = std.math.clamp(rgba[i * 4 + k], 0, 1);
    };
    return rgb;
}
