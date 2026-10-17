// The last pass, at the output's size: crop, straighten, rotate and flip; halation, vignette and
// grain; then the output colour space and dither. Preview and export both end here.
uniform sampler2D u_image; // display-encoded, the photo upright as decoded
uniform sampler2D u_glow;  // halation's blurred highlights, linear
uniform float u_halation;  // 0..1
uniform vec4 u_rect;       // crop x, y, w, h in the rotated photo, 0..1
uniform int u_turns;       // quarter turns clockwise
uniform bool u_flip;
uniform float u_angle;     // straighten, radians: + turns the photo clockwise (as Lightroom)
uniform vec2 u_size;       // the rotated photo's size, pixels at any scale
uniform float u_vignette;  // 0..1
uniform float u_grain;     // 0..1
uniform float u_grain_size;
uniform vec2 u_out;        // the whole output's size, pixels (bigger than the target when zoomed in)
uniform vec4 u_view;       // the part of the output drawn: x, y, w, h in 0..1 (zoom and pan)
uniform bool u_p3;         // Display P3 out, else sRGB
uniform float u_dither;    // one step of the output's bit depth; 0 for float

// Output uv to the uv of the photo as decoded.
vec2 source(vec2 uv) {
  vec2 p = u_rect.xy + uv * u_rect.zw;
  // Straighten turns around the middle and zooms in just enough that no corner shows past the edge.
  vec2 q = (p - 0.5) * u_size;
  float s = abs(sin(u_angle)), c = cos(u_angle);
  float fit = min(u_size.x / (u_size.x * c + u_size.y * s), u_size.y / (u_size.x * s + u_size.y * c));
  // The sample point turns the other way to the photo (y runs down).
  q = mat2(c, -sin(u_angle), sin(u_angle), c) * (q * fit);
  p = q / u_size + 0.5;
  if (u_flip) p.x = 1.0 - p.x;
  if (u_turns == 1) return vec2(p.y, 1.0 - p.x);
  if (u_turns == 2) return vec2(1.0 - p.x, 1.0 - p.y);
  if (u_turns == 3) return vec2(1.0 - p.y, p.x);
  return p;
}

// Smooth value noise.
float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float a = hash12(i), b = hash12(i + vec2(1, 0)), c = hash12(i + vec2(0, 1)), d = hash12(i + vec2(1, 1));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void main() {
  // Where in the whole output this pixel is: everything below is relative to that, so zooming
  // shows the same grain and vignette, only bigger.
  vec2 ov = u_view.xy + v_uv * u_view.zw;
  vec2 uv = source(ov);
  vec3 lin = srgbDecode(texture(u_image, uv).rgb);
  if (u_halation > 0.0) lin += texture(u_glow, uv).rgb * vec3(1.0, 0.32, 0.12) * u_halation * 1.6;

  if (u_vignette > 0.0) {
    vec2 d = (ov - 0.5) * vec2(u_out.x / u_out.y, 1.0);
    float r = length(d) / length(vec2(u_out.x / u_out.y, 1.0) * 0.5);
    lin *= 1.0 - u_vignette * 0.85 * smoothstep(0.3, 1.1, r);
  }

  vec3 c = srgbEncode(lin);
  if (u_grain > 0.0) {
    // Grains across the long edge: fewer is coarser. Where the render has fewer pixels than
    // grains (a small preview) the grain is averaged away, as it would be on film.
    float longEdge = max(u_out.x, u_out.y);
    float cells = mix(2200.0, 500.0, u_grain_size);
    vec2 g = ov * u_out / longEdge * cells;
    float n = noise(g) + noise(g * 1.7 + 19.1) - 1.0;
    float l = luma(c);
    float amount = u_grain * 0.16 * pow(clamp(4.0 * l * (1.0 - l), 0.0, 1.0), 0.6) * sqrt(min(1.0, longEdge / cells));
    c += n * amount;
  }

  if (u_p3) c = srgbEncode(mat3(0.8225, 0.0332, 0.0171, 0.1774, 0.9669, 0.0724, 0.0, 0.0, 0.9108) * srgbDecode(c));
  // Triangular dither: no banding when 8 bits leave the float pipeline.
  c += (hash12(gl_FragCoord.xy) + hash12(gl_FragCoord.yx + 71.3) - 1.0) * u_dither;
  o_color = vec4(clamp(c, 0.0, 1.0), 1.0);
}
