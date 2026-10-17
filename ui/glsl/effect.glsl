// Wraps a shader from ~/.config/doka/shaders/<name>/shader.glsl, which defines
//   vec3 effect(vec3 c)
// on display-encoded sRGB colour (0..1). It can also read the image around it: u_image at v_uv,
// one pixel is u_texel; u_resolution is the render's size. Each parameter in shader.json is a
// `uniform float u_<name>`, declared here. Shaders that declare "needs": ["depth"] get u_depth
// (0 near, 1 far); until the depth model arrives it is flat.
uniform sampler2D u_image;
uniform sampler2D u_depth;
uniform vec2 u_texel;
uniform vec2 u_resolution;
uniform float u_strength;
//@params

#line 1
//@source

void main() {
  vec3 c = texture(u_image, v_uv).rgb;
  o_color = vec4(mix(c, effect(c), u_strength), 1.0);
}
