#version 300 es
// One triangle over the target. v_uv runs 0..1 with y down the image; u_flip_y is for the
// canvas, whose y runs up (a framebuffer read with readPixels already starts at the top).
uniform bool u_flip_y;
out vec2 v_uv;

void main() {
  vec2 p = vec2(gl_VertexID & 1, gl_VertexID >> 1) * 4.0 - 1.0;
  v_uv = p * 0.5 + 0.5;
  if (u_flip_y) v_uv.y = 1.0 - v_uv.y;
  gl_Position = vec4(p, 0.0, 1.0);
}
