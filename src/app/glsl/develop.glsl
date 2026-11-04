// The base adjustments, then the look. In: linear light (Rec.709 primaries) from the photo.
// Out: display-encoded sRGB values, which is what looks (.cube) and shaders work on.
// Every slider at 0 leaves the photo as it was.
uniform sampler2D u_src;
uniform sampler3D u_lut;
uniform float u_lut_size;
uniform vec3 u_lut_min;
uniform vec3 u_lut_max;
uniform float u_lut_strength; // 0 = no look

vec3 look(vec3 c) {
  if (u_lut_strength <= 0.0) return c;
  vec3 x = clamp((c - u_lut_min) / (u_lut_max - u_lut_min), 0.0, 1.0);
  // Sample the lattice points' centres.
  vec3 coord = x * ((u_lut_size - 1.0) / u_lut_size) + 0.5 / u_lut_size;
  return mix(c, texture(u_lut, coord).rgb, u_lut_strength);
}

void main() {
  vec3 c = srgbEncode(adjust(texture(u_src, v_uv).rgb));
  o_color = vec4(look(c), 1.0);
}
