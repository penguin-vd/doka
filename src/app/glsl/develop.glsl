// The base adjustments, then the look. In: linear light (Rec.709 primaries) from the photo.
// Out: display-encoded sRGB values, which is what looks (.cube) and shaders work on.
// Every slider at 0 leaves the photo as it was.
uniform sampler2D u_src;
uniform float u_exposure;    // stops
uniform float u_temperature; // -1..1, the rest too
uniform float u_tint;
uniform float u_contrast;
uniform float u_highlights;
uniform float u_shadows;
uniform float u_saturation;
uniform vec3 u_bands[6];     // hue, saturation, lightness per colour band, -1..1

uniform sampler3D u_lut;
uniform float u_lut_size;
uniform vec3 u_lut_min;
uniform vec3 u_lut_max;
uniform float u_lut_strength; // 0 = no look

const float MID_GREY = 0.18;

vec3 whiteBalance(vec3 c) {
  // Warmer is more red, less blue; tint is magenta against green. Brightness stays put.
  vec3 gain = vec3(exp2(0.35 * u_temperature), exp2(-0.25 * u_tint), exp2(-0.35 * u_temperature));
  return c * gain / dot(gain, LUMA);
}

vec3 scaleLuma(vec3 c, float from, float to) {
  return from > 1e-6 ? c * (to / from) : c;
}

// Exposure, white balance, contrast, highlights and shadows: brightness moves, hue doesn't.
vec3 light(vec3 c) {
  c *= exp2(u_exposure);
  c = whiteBalance(c);
  float l = luma(c);
  // Contrast pivots on mid grey, in stops.
  float k = exp2(u_contrast * 0.8);
  float lc = l > 0.0 ? MID_GREY * pow(l / MID_GREY, k) : l;
  // Shadows lift the dark end, highlights move the bright end, each by up to 1.5 stops.
  float stops = log2(max(lc, 1e-6) / MID_GREY);
  float ws = 1.0 - smoothstep(-5.0, 0.0, stops);
  float wh = smoothstep(-0.5, log2(1.0 / MID_GREY), stops);
  float lt = lc * exp2(1.5 * (u_shadows * ws + u_highlights * wh));
  return scaleLuma(c, l, lt);
}

// A film-like shoulder: values above `knee` bend so the brightest the edits can make (`top`)
// lands on white instead of clipping. With nothing pushed past white, top is 1: no change.
vec3 rollOff(vec3 c, float top) {
  const float knee = 0.25;
  if (top <= 1.0) return c;
  float m = (top - knee) / (1.0 - knee);
  vec3 u = max(c - knee, 0.0) / (1.0 - knee);
  vec3 g = u * (1.0 + u / (m * m)) / (1.0 + u);
  return mix(c, knee + (1.0 - knee) * g, step(knee, c));
}

float cbrt(float x) { return sign(x) * pow(abs(x), 1.0 / 3.0); }

vec3 toOklab(vec3 c) {
  vec3 lms = mat3(0.4122214708, 0.2119034982, 0.0883024619,
                  0.5363325363, 0.6806995451, 0.2817188376,
                  0.0514459929, 0.1073969566, 0.6299787005) * c;
  lms = vec3(cbrt(lms.x), cbrt(lms.y), cbrt(lms.z));
  return mat3(0.2104542553, 1.9779984951, 0.0259040371,
              0.7936177850, -2.4285922050, 0.7827717662,
              -0.0040720468, 0.4505937099, -0.8086757660) * lms;
}

vec3 fromOklab(vec3 lab) {
  vec3 lms = mat3(1.0, 1.0, 1.0,
                  0.3963377774, -0.1055613458, -0.0894841775,
                  0.2158037573, -0.0638541728, -1.2914855480) * lab;
  lms = lms * lms * lms;
  return mat3(4.0767416621, -1.2684380046, -0.0041960863,
              -3.3077115913, 2.6097574011, -0.7034186147,
              0.2309699292, -0.3413193965, 1.7076147010) * lms;
}

// The colour bands' centres and widths on OKLCH's hue circle, in degrees.
const float BAND_HUE[6] = float[6](25.0, 60.0, 100.0, 145.0, 250.0, 315.0);
const float BAND_WIDTH[6] = float[6](26.0, 22.0, 26.0, 38.0, 45.0, 35.0);

// Saturation and the per-colour mixer in OKLCH, so a hue shift keeps its brightness.
vec3 colour(vec3 c) {
  vec3 lab = toOklab(c);
  float chroma = length(lab.yz);
  float hue = degrees(atan(lab.z, lab.y));
  float shift = 0.0, sat = 0.0, lit = 0.0;
  for (int i = 0; i < 6; i++) {
    float d = mod(hue - BAND_HUE[i] + 540.0, 360.0) - 180.0;
    float w = exp(-0.5 * (d * d) / (BAND_WIDTH[i] * BAND_WIDTH[i]));
    shift += w * u_bands[i].x;
    sat += w * u_bands[i].y;
    lit += w * u_bands[i].z;
  }
  // Greys have no colour to belong to a band: they stay put.
  float colourful = smoothstep(0.0, 0.06, chroma);
  hue += 30.0 * shift * colourful;
  chroma *= max(0.0, 1.0 + sat) * max(0.0, 1.0 + u_saturation);
  lab.x *= 1.0 + 0.3 * lit * colourful;
  lab.yz = chroma * vec2(cos(radians(hue)), sin(radians(hue)));
  return fromOklab(lab);
}

vec3 look(vec3 c) {
  if (u_lut_strength <= 0.0) return c;
  vec3 x = clamp((c - u_lut_min) / (u_lut_max - u_lut_min), 0.0, 1.0);
  // Sample the lattice points' centres.
  vec3 coord = x * ((u_lut_size - 1.0) / u_lut_size) + 0.5 / u_lut_size;
  return mix(c, texture(u_lut, coord).rgb, u_lut_strength);
}

void main() {
  vec3 c = light(texture(u_src, v_uv).rgb);
  vec3 white = light(vec3(1.0));
  c = rollOff(c, max(white.r, max(white.g, white.b)));
  c = colour(c);
  c = srgbEncode(clamp(c, 0.0, 1.0));
  o_color = vec4(look(c), 1.0);
}
