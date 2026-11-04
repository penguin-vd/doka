// Halation, step two: a wide Gaussian along one axis. The radius is a share of the photo's long
// edge, so the glow is the same size in the preview and the export.
uniform sampler2D u_image;
uniform vec2 u_step; // one tap, in uv

void main() {
  vec3 sum = vec3(0.0);
  float wsum = 0.0;
  for (int i = -12; i <= 12; i++) {
    float w = exp(-0.5 * float(i * i) / 25.0);
    sum += texture(u_image, v_uv + float(i) * u_step).rgb * w;
    wsum += w;
  }
  o_color = vec4(sum / wsum, 1.0);
}
