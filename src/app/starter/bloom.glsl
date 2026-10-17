// A soft glow around the bright parts, as from a diffusion filter. Sizes are shares of the
// photo's long edge, so the preview and the export match.
vec3 effect(vec3 c) {
  float r = u_radius * 0.03 * max(u_resolution.x, u_resolution.y);
  vec3 glow = vec3(0.0);
  for (int i = 0; i < 32; i++) {
    // A golden-angle spiral: even coverage with few taps.
    float a = float(i) * 2.39996;
    vec2 o = vec2(cos(a), sin(a)) * sqrt((float(i) + 0.5) / 32.0) * r * u_texel;
    vec3 s = srgbDecode(texture(u_image, v_uv + o).rgb);
    glow += s * smoothstep(u_threshold, 1.0, luma(s));
  }
  return srgbEncode(srgbDecode(c) + glow / 32.0 * u_amount * 2.0);
}
