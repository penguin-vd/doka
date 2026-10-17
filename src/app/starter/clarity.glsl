// Clarity: local contrast. Texture and edges stand out (or soften, below 0) while the overall
// tones stay; highlights and shadows are spared so they don't clip.
vec3 effect(vec3 c) {
  float r = 0.012 * max(u_resolution.x, u_resolution.y);
  float around = 0.0;
  for (int i = 0; i < 32; i++) {
    float a = float(i) * 2.39996;
    vec2 o = vec2(cos(a), sin(a)) * sqrt((float(i) + 0.5) / 32.0) * r * u_texel;
    around += luma(texture(u_image, v_uv + o).rgb);
  }
  float l = luma(c);
  float detail = l - around / 32.0;
  float mid = 1.0 - pow(abs(2.0 * l - 1.0), 2.0);
  return c + detail * u_amount * 1.5 * mid;
}
