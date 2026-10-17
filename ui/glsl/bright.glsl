// Halation, step one: the bright parts in linear light, at a quarter of the size.
uniform sampler2D u_image; // display-encoded
uniform vec2 u_texel;      // of u_image

void main() {
  vec3 sum = vec3(0.0);
  for (int y = 0; y < 2; y++) for (int x = 0; x < 2; x++) {
    vec3 c = srgbDecode(texture(u_image, v_uv + (vec2(x, y) - 0.5) * u_texel * 2.0).rgb);
    sum += c * smoothstep(0.55, 1.0, luma(c));
  }
  o_color = vec4(sum / 4.0, 1.0);
}
