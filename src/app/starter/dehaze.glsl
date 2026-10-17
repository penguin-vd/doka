// Dehaze: haze is the light every pixel nearby shares, so the darkest channel around a pixel
// says how much there is (the dark channel prior). Take it out, then bring back the contrast.
vec3 effect(vec3 c) {
  float r = 0.008 * max(u_resolution.x, u_resolution.y);
  float dark = 1.0;
  for (int i = 0; i < 16; i++) {
    float a = float(i) * 2.39996;
    vec2 o = vec2(cos(a), sin(a)) * sqrt((float(i) + 0.5) / 16.0) * r * u_texel;
    vec3 s = srgbDecode(texture(u_image, v_uv + o).rgb);
    dark = min(dark, min(s.r, min(s.g, s.b)));
  }
  // The haze's own colour: a pale, slightly blue grey.
  vec3 air = vec3(0.86, 0.9, 0.95);
  float t = max(1.0 - u_amount * 0.95 * dark / air.b, 0.3);
  vec3 lin = (srgbDecode(c) - air) / t + air;
  return srgbEncode(clamp(lin, 0.0, 1.0));
}
