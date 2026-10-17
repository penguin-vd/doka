// What the app needs from WebGL2 before anything is built on it: float render targets on the GPU.
// The report goes to the app (src/app/gpu.zig), which logs it and fails `zig build probe` without them.

export interface GpuReport {
  webgl2: boolean;
  renderer: string;
  float_render: boolean;
  float_readback: boolean;
  half_float_render: boolean;
  float_linear: boolean;
  max_texture_size: number;
  error: string;
}

// Outside 0..1 on purpose: an 8-bit or clamped target would lose them.
const probe = [2.5, -0.75, 0.001, 16.0];

export function checkGpu(): GpuReport {
  const r: GpuReport = {
    webgl2: false, renderer: '', float_render: false, float_readback: false,
    half_float_render: false, float_linear: false, max_texture_size: 0, error: '',
  };
  const gl = document.createElement('canvas').getContext('webgl2');
  if (!gl) { r.error = 'no WebGL2 context'; return r; }
  r.webgl2 = true;
  const info = gl.getExtension('WEBGL_debug_renderer_info');
  r.renderer = String(gl.getParameter(info ? info.UNMASKED_RENDERER_WEBGL : gl.RENDERER));
  r.max_texture_size = gl.getParameter(gl.MAX_TEXTURE_SIZE);
  r.float_linear = gl.getExtension('OES_texture_float_linear') !== null;
  if (!gl.getExtension('EXT_color_buffer_float')) { r.error = 'no EXT_color_buffer_float'; return r; }
  r.half_float_render = targetComplete(gl, gl.RGBA16F, gl.HALF_FLOAT);
  r.float_render = targetComplete(gl, gl.RGBA32F, gl.FLOAT);
  if (r.float_render) r.float_readback = drawsUnclamped(gl);
  return r;
}

function makeTarget(gl: WebGL2RenderingContext, format: number, type: number): WebGLFramebuffer | null {
  const tex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texImage2D(gl.TEXTURE_2D, 0, format, 4, 4, 0, gl.RGBA, type, null);
  const fb = gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
  return fb;
}

function targetComplete(gl: WebGL2RenderingContext, format: number, type: number): boolean {
  makeTarget(gl, format, type);
  return gl.checkFramebufferStatus(gl.FRAMEBUFFER) === gl.FRAMEBUFFER_COMPLETE;
}

// A shader writes the probe values into an RGBA32F target; they must come back as written.
function drawsUnclamped(gl: WebGL2RenderingContext): boolean {
  makeTarget(gl, gl.RGBA32F, gl.FLOAT);
  const vs = '#version 300 es\nvoid main(){vec2 p=vec2(gl_VertexID&1,gl_VertexID>>1)*4.0-1.0;gl_Position=vec4(p,0,1);}';
  const fs = `#version 300 es\nprecision highp float;out vec4 o;void main(){o=vec4(${probe.map((v) => v.toFixed(4)).join(',')});}`;
  const prog = gl.createProgram()!;
  for (const [kind, src] of [[gl.VERTEX_SHADER, vs], [gl.FRAGMENT_SHADER, fs]] as const) {
    const s = gl.createShader(kind)!;
    gl.shaderSource(s, src);
    gl.compileShader(s);
    gl.attachShader(prog, s);
  }
  gl.linkProgram(prog);
  gl.useProgram(prog);
  gl.viewport(0, 0, 4, 4);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  const out = new Float32Array(4);
  gl.readPixels(1, 1, 1, 1, gl.RGBA, gl.FLOAT, out);
  return probe.every((v, i) => Math.abs(out[i] - v) < 1e-4);
}

export function gpuOk(r: GpuReport): boolean {
  return r.webgl2 && r.float_render && r.float_readback;
}
