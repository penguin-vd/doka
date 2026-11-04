// One mask: the adjustments again, only where the mask says. After the look, so it works on what
// the photo looks like by then. Coordinates are the photo's as decoded, so a mask stays on its
// pixels through crop and rotation. The limits read the original photo, so they select the same
// pixels whatever the other edits do.
uniform sampler2D u_image;  // display-encoded: everything before this mask
uniform sampler2D u_photo;  // linear: the photo as decoded
uniform sampler2D u_stored; // a subject's saved mask
uniform int u_shape;        // 0 whole photo, 1 linear, 2 radial, 3 a saved mask, 4 nothing yet
uniform vec2 u_from;        // linear: the full effect here,
uniform vec2 u_to;          // fading to nothing here
uniform vec2 u_centre;      // radial
uniform vec2 u_radius;      // as shares of the photo's width and height
uniform float u_feather;    // 0..1 of the radius, fading inwards from its edge
uniform bool u_invert;
uniform vec2 u_brightness;  // 0..1, lowest and highest
uniform float u_hue;        // OKLCH degrees
uniform float u_hue_width;  // degrees to each side; 0 = any colour
uniform vec2 u_size;        // the photo's size, for true distances
uniform bool u_show;        // red where the mask is, to see it
uniform float u_blur;       // the disc's radius, as a share of the long edge; 0 = none
uniform float u_blur_lod;   // the mipmap level whose pixels fill the gaps between the disc's taps

const float LIMIT_SOFTNESS = 0.06;
// Limits read a small average, as a share of the long edge: a single pixel's noise would speckle
// the mask's edge, and the same share means the same mask at preview and export sizes.
const float LIMIT_REACH = 0.0012;
const vec3 SHOW = vec3(1.0, 0.12, 0.12);

float shapeAt(vec2 uv) {
  if (u_shape == 1) {
    vec2 along = (u_to - u_from) * u_size;
    float len2 = dot(along, along);
    if (len2 < 1e-6) return 1.0;
    return 1.0 - smoothstep(0.0, 1.0, dot((uv - u_from) * u_size, along) / len2);
  }
  if (u_shape == 2) {
    float d = length((uv - u_centre) / u_radius);
    return 1.0 - smoothstep(1.0 - max(u_feather, 0.001), 1.0, d);
  }
  if (u_shape == 3) return texture(u_stored, uv).r;
  if (u_shape == 4) return 0.0;
  return 1.0;
}

float limits() {
  vec2 reach = LIMIT_REACH * max(u_size.x, u_size.y) / u_size;
  vec3 p = texture(u_photo, v_uv).rgb * 0.2;
  p += texture(u_photo, v_uv + reach * vec2(-1.0, -0.4)).rgb * 0.2;
  p += texture(u_photo, v_uv + reach * vec2(0.4, -1.0)).rgb * 0.2;
  p += texture(u_photo, v_uv + reach * vec2(1.0, 0.4)).rgb * 0.2;
  p += texture(u_photo, v_uv + reach * vec2(-0.4, 1.0)).rgb * 0.2;
  float m = 1.0;
  float y = srgbEncode(vec3(luma(p))).r;
  if (u_brightness.x > 0.0) m *= smoothstep(u_brightness.x - LIMIT_SOFTNESS, u_brightness.x + LIMIT_SOFTNESS, y);
  if (u_brightness.y < 1.0) m *= 1.0 - smoothstep(u_brightness.y - LIMIT_SOFTNESS, u_brightness.y + LIMIT_SOFTNESS, y);
  if (u_hue_width > 0.0) {
    vec3 lab = toOklab(p);
    float d = abs(mod(degrees(atan(lab.z, lab.y)) - u_hue + 540.0, 360.0) - 180.0);
    // Greys have no colour to match.
    m *= (1.0 - smoothstep(u_hue_width * 0.75, u_hue_width * 1.25, d)) * smoothstep(0.01, 0.04, length(lab.yz));
  }
  return m;
}

const int BLUR_TAPS = 64;

// A lens's blur: a disc of taps on a golden-angle spiral, added up in linear light so bright spots
// stay bright. Only what's in the mask counts, so a person's colour doesn't bleed into the
// background around them. The size is a share of the long edge: the same at any render size.
vec3 blurred(vec3 c) {
  vec3 sum = vec3(0.0);
  float wsum = 0.0;
  vec2 reach = u_blur * max(u_size.x, u_size.y) / u_size;
  for (int i = 0; i < BLUR_TAPS; i++) {
    float a = float(i) * 2.39996323;
    vec2 uv = v_uv + reach * sqrt((float(i) + 0.5) / float(BLUR_TAPS)) * vec2(cos(a), sin(a));
    float w = shapeAt(uv);
    if (u_invert) w = 1.0 - w;
    sum += srgbDecode(textureLod(u_image, uv, u_blur_lod).rgb) * w;
    wsum += w;
  }
  return wsum > 0.001 ? srgbEncode(sum / wsum) : c;
}

void main() {
  vec3 c = texture(u_image, v_uv).rgb;
  float m = shapeAt(v_uv) * limits();
  if (u_invert) m = 1.0 - m;
  vec3 from = u_blur > 0.0 ? blurred(c) : c;
  vec3 out_c = mix(c, srgbEncode(adjust(srgbDecode(from))), m);
  if (u_show) out_c = mix(out_c, SHOW, 0.65 * m);
  o_color = vec4(out_c, 1.0);
}
