// A warm leak of light from one edge, as from a camera back that let light in.
vec3 effect(vec3 c) {
  float aspect = u_resolution.x / u_resolution.y;
  vec2 from = vec2(mix(-0.15, 1.15, u_position), 0.35);
  float d = distance(v_uv * vec2(aspect, 1.0), from * vec2(aspect, 1.0));
  float leak = exp(-d * d / (0.02 + 0.5 * u_size));
  vec3 tint = mix(vec3(1.0, 0.45, 0.12), vec3(1.0, 0.18, 0.32), u_hue);
  vec3 lin = srgbDecode(c);
  // Screen: it lightens, never darkens.
  lin = 1.0 - (1.0 - lin) * (1.0 - tint * leak * u_amount);
  return srgbEncode(lin);
}
