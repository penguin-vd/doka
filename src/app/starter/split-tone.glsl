// Split toning: cool shadows and warm highlights (SPEC.md's example).
vec3 effect(vec3 c) {
  float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
  c += vec3(-0.02, 0.0, 0.03) * (1.0 - smoothstep(0.0, 0.4, lum)) * u_shadows;
  c += vec3(0.04, 0.01, -0.03) * smoothstep(0.5, 1.0, lum) * u_highlights;
  return c;
}
