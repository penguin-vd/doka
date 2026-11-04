// Noise reduction, then sharpening, in linear light at the render's own pixels. On the preview
// the pixels are bigger than the photo's, so it only approximates the export (SPEC.md).
uniform sampler2D u_src;
uniform vec2 u_texel;
uniform float u_noise;   // 0..1
uniform float u_sharpen; // 0..1

void main() {
  vec3 c = texture(u_src, v_uv).rgb;
  float lc = log2(max(luma(c), 1e-5));
  // A small bilateral filter: neighbours that differ much in brightness count for little.
  vec3 sum = c;
  float wsum = 1.0;
  float range = 0.05 + 0.6 * u_noise;
  for (int y = -2; y <= 2; y++) for (int x = -2; x <= 2; x++) {
    if (x == 0 && y == 0) continue;
    vec3 s = texture(u_src, v_uv + vec2(x, y) * u_texel).rgb;
    float d = (log2(max(luma(s), 1e-5)) - lc) / range;
    float w = exp(-0.5 * d * d - float(x * x + y * y) / 4.5);
    sum += s * w;
    wsum += w;
  }
  c = mix(c, sum / wsum, u_noise);

  // Unsharp mask on brightness only, so edges don't grow coloured fringes.
  vec3 blur = vec3(0.0);
  for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
    float w = (x == 0 ? 2.0 : 1.0) * (y == 0 ? 2.0 : 1.0);
    blur += texture(u_src, v_uv + vec2(x, y) * u_texel).rgb * w;
  }
  blur /= 16.0;
  float l = luma(c);
  float detail = l - luma(blur);
  float sharpened = max(l + detail * u_sharpen * 2.0, 0.0);
  c *= l > 1e-5 ? sharpened / l : 1.0;
  o_color = vec4(c, 1.0);
}
