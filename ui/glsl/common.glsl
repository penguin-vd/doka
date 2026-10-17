// Prepended to every fragment shader (ui/gl/pipeline.ts), the user's shaders included.
precision highp float;
precision highp sampler3D;

in vec2 v_uv;
out vec4 o_color;

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

float luma(vec3 c) { return dot(c, LUMA); }

vec3 srgbEncode(vec3 c) {
  vec3 x = max(c, 0.0);
  return mix(12.92 * x, 1.055 * pow(x, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, x));
}

vec3 srgbDecode(vec3 c) {
  vec3 x = max(c, 0.0);
  return mix(x / 12.92, pow((x + 0.055) / 1.055, vec3(2.4)), step(0.04045, x));
}

float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}
