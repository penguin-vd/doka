// WebGL2 plumbing: programs, float textures, framebuffers.

export interface Program {
  program: WebGLProgram;
  uniforms: Map<string, WebGLUniformLocation>;
}

export class ShaderError extends Error {}

let sources: Record<string, string> = {};

/** Loads the pipeline's GLSL from ui/glsl/. */
export async function loadSources(names: string[]) {
  const texts = await Promise.all(names.map(async (n) => {
    const r = await fetch(`glsl/${n}.glsl`);
    if (!r.ok) throw new Error(`glsl/${n}.glsl: ${r.status}`);
    return r.text();
  }));
  sources = Object.fromEntries(names.map((n, i) => [n, texts[i]]));
}

export function source(name: string): string {
  const s = sources[name];
  if (s === undefined) throw new Error(`no shader ${name}`);
  return s;
}

function compile(gl: WebGL2RenderingContext, kind: number, text: string): WebGLShader {
  const s = gl.createShader(kind)!;
  gl.shaderSource(s, text);
  gl.compileShader(s);
  return s;
}

export interface Pending { program: WebGLProgram; vs: WebGLShader; fs: WebGLShader; }

/** Compiles and links without waiting: the driver can work on several at once (`finish` waits). */
export function startProgram(gl: WebGL2RenderingContext, fragment: string): Pending {
  const vs = compile(gl, gl.VERTEX_SHADER, source('vertex'));
  const fs = compile(gl, gl.FRAGMENT_SHADER, `#version 300 es\n${source('common')}\n${fragment}`);
  const p = gl.createProgram()!;
  gl.attachShader(p, vs);
  gl.attachShader(p, fs);
  gl.linkProgram(p);
  return { program: p, vs, fs };
}

/** A program from the shared vertex shader and `fragment` (with common.glsl in front). */
export function program(gl: WebGL2RenderingContext, fragment: string): Program {
  return finish(gl, startProgram(gl, fragment));
}

export function finish(gl: WebGL2RenderingContext, pending: Pending): Program {
  const { program: p, vs, fs } = pending;
  if (!gl.getProgramParameter(p, gl.LINK_STATUS)) {
    const log = gl.getShaderInfoLog(fs) || gl.getShaderInfoLog(vs) || gl.getProgramInfoLog(p) || 'link failed';
    gl.deleteShader(vs);
    gl.deleteShader(fs);
    gl.deleteProgram(p);
    throw new ShaderError(log.trim());
  }
  gl.deleteShader(vs);
  gl.deleteShader(fs);
  const uniforms = new Map<string, WebGLUniformLocation>();
  const n = gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS) as number;
  for (let i = 0; i < n; i++) {
    const info = gl.getActiveUniform(p, i)!;
    const name = info.name.replace(/\[0\]$/, '');
    uniforms.set(name, gl.getUniformLocation(p, info.name)!);
  }
  return { program: p, uniforms };
}

export interface Target {
  texture: WebGLTexture;
  fbo: WebGLFramebuffer;
  width: number;
  height: number;
}

export function texture(gl: WebGL2RenderingContext, width: number, height: number, internal: number, format: number, type: number, data: ArrayBufferView | null, filter: number = gl.LINEAR): WebGLTexture {
  const t = gl.createTexture()!;
  gl.bindTexture(gl.TEXTURE_2D, t);
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
  gl.texImage2D(gl.TEXTURE_2D, 0, internal, width, height, 0, format, type, data);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  return t;
}

/** A half-float RGBA render target. */
export function target(gl: WebGL2RenderingContext, width: number, height: number, internal: number = gl.RGBA16F, type: number = gl.HALF_FLOAT, filter: number = gl.LINEAR): Target {
  const format = gl.RGBA;
  const tex = texture(gl, width, height, internal, format, type, null, filter);
  const fbo = gl.createFramebuffer()!;
  gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
  const status = gl.checkFramebufferStatus(gl.FRAMEBUFFER);
  if (status !== gl.FRAMEBUFFER_COMPLETE) throw new Error(`framebuffer incomplete: ${status}`);
  return { texture: tex, fbo, width, height };
}

export function free(gl: WebGL2RenderingContext, t: Target | null) {
  if (!t) return;
  gl.deleteTexture(t.texture);
  gl.deleteFramebuffer(t.fbo);
}
