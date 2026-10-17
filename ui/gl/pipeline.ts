// The image pipeline (SPEC.md, Image pipeline): one implementation for the preview, the look
// thumbnails, Claude's screenshots and the full-size export.
//
//   photo (linear, half float)
//   → detail      noise reduction, sharpening        (only when set)
//   → develop     the Adjust sliders, colour mixer, the look's LUT
//   → shaders     each enabled shader, in order
//   → halation    bright parts, blurred              (only when set)
//   → finish      crop/straighten/rotate/flip, halation, vignette, grain, colour space, dither

import { program, target, free, ShaderError, source, type Program, type Target } from './gl.js';
import type { Cube } from './cube.js';
import { bands, type Recipe } from '../state.js';

export const pipelineSources = ['vertex', 'common', 'detail', 'develop', 'effect', 'bright', 'blur', 'finish'];

export interface ShaderParam { name: string; label?: string; default: number; min: number; max: number; }

export interface ShaderDef {
  name: string;
  description: string;
  params: ShaderParam[];
  needs: string[];
}

interface Compiled { def: ShaderDef; prog: Program; colourOnly: boolean; }

export interface Output {
  // null: the canvas.
  target: Target | null;
  width: number;
  height: number;
  p3?: boolean;
  // One step of the output's bit depth (1/255 for 8 bits); 0 for none.
  dither?: number;
  // The whole photo, for the Crop tab (it draws the crop over it).
  uncropped?: boolean;
}

// Halation's blur: sigma as a share of the photo's long edge.
const GLOW_SIGMA = 0.011;
const BLUR_TAPS_PER_SIGMA = 5;

export class Pipeline {
  readonly gl: WebGL2RenderingContext;
  private progs: Record<'detail' | 'develop' | 'bright' | 'blur' | 'finish', Program>;
  private src: WebGLTexture | null = null;
  width = 0;
  height = 0;
  private a: Target | null = null;
  private b: Target | null = null;
  private c: Target | null = null;
  private glowA: Target | null = null;
  private glowB: Target | null = null;
  private lut: WebGLTexture;
  private lutInfo = { size: 2, min: [0, 0, 0], max: [1, 1, 1] };
  private flat: WebGLTexture;
  private shaders = new Map<string, Compiled>();

  constructor(gl: WebGL2RenderingContext) {
    this.gl = gl;
    if (!gl.getExtension('EXT_color_buffer_float')) throw new Error('no EXT_color_buffer_float');
    this.progs = {
      detail: program(gl, source('detail')),
      develop: program(gl, source('develop')),
      bright: program(gl, source('bright')),
      blur: program(gl, source('blur')),
      finish: program(gl, source('finish')),
    };
    this.lut = gl.createTexture()!;
    this.setLook(null);
    this.flat = gl.createTexture()!;
    gl.bindTexture(gl.TEXTURE_2D, this.flat);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([128, 128, 128, 255]));
  }

  /** The photo: linear RGB half floats, rows from the top. */
  setSource(width: number, height: number, rgb: Uint16Array) {
    const gl = this.gl;
    if (this.src) gl.deleteTexture(this.src);
    this.src = gl.createTexture()!;
    gl.bindTexture(gl.TEXTURE_2D, this.src);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 2);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB16F, width, height, 0, gl.RGB, gl.HALF_FLOAT, rgb);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    if (width !== this.width || height !== this.height) {
      for (const t of [this.a, this.b, this.c, this.glowA, this.glowB]) free(gl, t);
      this.a = target(gl, width, height);
      this.b = target(gl, width, height);
      this.c = target(gl, width, height);
      const gw = Math.max(1, Math.ceil(width / 4));
      const gh = Math.max(1, Math.ceil(height / 4));
      this.glowA = target(gl, gw, gh);
      this.glowB = target(gl, gw, gh);
      this.width = width;
      this.height = height;
    }
  }

  get ready(): boolean { return this.src !== null; }

  /** The look's LUT, or none. */
  setLook(cube: Cube | null) {
    const gl = this.gl;
    const size = cube ? cube.size : 2;
    const data = cube ? cube.data : new Float32Array([0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0, 0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1]);
    gl.bindTexture(gl.TEXTURE_3D, this.lut);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 4);
    gl.texImage3D(gl.TEXTURE_3D, 0, gl.RGB16F, size, size, size, 0, gl.RGB, gl.FLOAT, data);
    gl.texParameteri(gl.TEXTURE_3D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_3D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    for (const w of [gl.TEXTURE_WRAP_S, gl.TEXTURE_WRAP_T, gl.TEXTURE_WRAP_R]) gl.texParameteri(gl.TEXTURE_3D, w, gl.CLAMP_TO_EDGE);
    this.lutInfo = { size, min: cube ? cube.min : [0, 0, 0], max: cube ? cube.max : [1, 1, 1] };
  }

  /** Compiles a shader; throws ShaderError with the compiler's message. Doesn't install it. */
  compileShader(def: ShaderDef, glsl: string): Compiled {
    const params = def.params.map((p) => `uniform float u_${p.name};`).join('\n');
    const text = source('effect').replace('//@params', params).replace('//@source', glsl);
    const prog = program(this.gl, text);
    // A shader that looks at other pixels can't be baked into a LUT.
    const colourOnly = !/\b(u_image|u_texel|u_depth|v_uv|u_resolution)\b/.test(glsl);
    return { def, prog, colourOnly };
  }

  setShader(name: string, compiled: Compiled | null) {
    const old = this.shaders.get(name);
    if (old) this.gl.deleteProgram(old.prog.program);
    if (compiled) this.shaders.set(name, compiled); else this.shaders.delete(name);
  }

  hasShader(name: string): boolean { return this.shaders.has(name); }

  /** Size of the cropped, rotated output in source pixels. */
  outputSize(recipe: Recipe, uncropped = false): [number, number] {
    const turned = (recipe.crop.rotate / 90) % 2 === 1;
    const w = turned ? this.height : this.width;
    const h = turned ? this.width : this.height;
    const r = uncropped ? [0, 0, 1, 1] : recipe.crop.rect;
    return [Math.max(1, Math.round(w * r[2])), Math.max(1, Math.round(h * r[3]))];
  }

  render(recipe: Recipe, out: Output) {
    const gl = this.gl;
    if (!this.src) return;
    gl.disable(gl.BLEND);
    gl.disable(gl.DEPTH_TEST);
    let cur = this.src;
    const texel = [1 / this.width, 1 / this.height];

    if (recipe.detail.noise > 0 || recipe.detail.sharpen > 0) {
      this.pass(this.progs.detail, this.a!, { u_src: cur }, { u_texel: texel, u_noise: recipe.detail.noise / 100, u_sharpen: recipe.detail.sharpen / 100 });
      cur = this.a!.texture;
    }

    const e = recipe.edits;
    const bandValues: number[] = [];
    for (const name of bands) {
      const b = recipe.colour[name];
      bandValues.push(b.hue / 100, b.sat / 100, b.light / 100);
    }
    const hasLook = recipe.look.name !== 'none' && recipe.look.strength > 0 && this.lutInfo.size > 2;
    this.pass(this.progs.develop, this.b!, { u_src: cur }, {
      u_exposure: e.exposure,
      u_temperature: e.temperature / 100,
      u_tint: e.tint / 100,
      u_contrast: e.contrast / 100,
      u_highlights: e.highlights / 100,
      u_shadows: e.shadows / 100,
      u_saturation: e.saturation / 100,
      u_bands: bandValues,
      u_lut_size: this.lutInfo.size,
      u_lut_min: this.lutInfo.min,
      u_lut_max: this.lutInfo.max,
      u_lut_strength: hasLook ? recipe.look.strength / 100 : 0,
    });
    let curTarget = this.b!;

    for (const use of recipe.shaders) {
      const s = this.shaders.get(use.name);
      if (!s || !use.enabled || use.strength <= 0) continue;
      const next = curTarget === this.b ? this.c! : this.b!;
      const values: Record<string, number | number[]> = { u_strength: use.strength / 100, u_texel: texel, u_resolution: [this.width, this.height] };
      for (const p of s.def.params) values[`u_${p.name}`] = use.params[p.name] ?? p.default;
      this.pass(s.prog, next, { u_image: curTarget.texture, u_depth: this.flat }, values);
      curTarget = next;
    }

    const halation = recipe.halation / 100;
    if (halation > 0) {
      const gw = this.glowA!.width, gh = this.glowA!.height;
      this.pass(this.progs.bright, this.glowA!, { u_image: curTarget.texture }, { u_texel: texel });
      const longEdge = Math.max(gw, gh);
      const step = (GLOW_SIGMA * longEdge) / BLUR_TAPS_PER_SIGMA;
      this.pass(this.progs.blur, this.glowB!, { u_image: this.glowA!.texture }, { u_step: [step / gw, 0] });
      this.pass(this.progs.blur, this.glowA!, { u_image: this.glowB!.texture }, { u_step: [0, step / gh] });
    }

    // A preview smaller than the photo samples a mipmap, not every few pixels.
    gl.bindTexture(gl.TEXTURE_2D, curTarget.texture);
    gl.generateMipmap(gl.TEXTURE_2D);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);

    const turns = Math.round(recipe.crop.rotate / 90) % 4;
    const odd = turns % 2 === 1;
    const rect = out.uncropped ? [0, 0, 1, 1] : recipe.crop.rect;
    this.pass(this.progs.finish, out.target, { u_image: curTarget.texture, u_glow: this.glowA!.texture }, {
      u_halation: halation,
      u_rect: rect,
      u_turns: turns,
      u_flip: recipe.crop.flip ? 1 : 0,
      u_angle: (recipe.crop.straighten * Math.PI) / 180,
      u_size: odd ? [this.height, this.width] : [this.width, this.height],
      u_vignette: recipe.vignette / 100,
      u_grain: recipe.grain.amount / 100,
      u_grain_size: recipe.grain.size / 100,
      u_out: [out.width, out.height],
      u_p3: out.p3 ? 1 : 0,
      u_dither: out.dither ?? 0,
    }, out.width, out.height, out.target === null);

    gl.bindTexture(gl.TEXTURE_2D, curTarget.texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  }

  /** The colour part of the pipeline (develop, look, colour-only shaders) on a lattice: bake_look. */
  bakeLattice(recipe: Recipe, size: number): Float32Array {
    const gl = this.gl;
    const w = size * size, h = size;
    const input = new Float32Array(w * h * 3);
    const decode = (v: number) => (v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4));
    for (let b = 0; b < size; b++) for (let g = 0; g < size; g++) for (let r = 0; r < size; r++) {
      const i = (b * w + g * size + r) * 3;
      input[i] = decode(r / (size - 1));
      input[i + 1] = decode(g / (size - 1));
      input[i + 2] = decode(b / (size - 1));
    }
    const src = gl.createTexture()!;
    gl.bindTexture(gl.TEXTURE_2D, src);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 4);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB32F, w, h, 0, gl.RGB, gl.FLOAT, input);
    for (const [k, v] of [[gl.TEXTURE_MIN_FILTER, gl.NEAREST], [gl.TEXTURE_MAG_FILTER, gl.NEAREST]]) gl.texParameteri(gl.TEXTURE_2D, k, v);
    const t1 = target(gl, w, h, gl.RGBA32F, gl.FLOAT, gl.NEAREST);
    const t2 = target(gl, w, h, gl.RGBA32F, gl.FLOAT, gl.NEAREST);
    const e = recipe.edits;
    const bandValues: number[] = [];
    for (const name of bands) bandValues.push(recipe.colour[name].hue / 100, recipe.colour[name].sat / 100, recipe.colour[name].light / 100);
    const hasLook = recipe.look.name !== 'none' && recipe.look.strength > 0 && this.lutInfo.size > 2;
    this.pass(this.progs.develop, t1, { u_src: src }, {
      u_exposure: e.exposure, u_temperature: e.temperature / 100, u_tint: e.tint / 100, u_contrast: e.contrast / 100,
      u_highlights: e.highlights / 100, u_shadows: e.shadows / 100, u_saturation: e.saturation / 100, u_bands: bandValues,
      u_lut_size: this.lutInfo.size, u_lut_min: this.lutInfo.min, u_lut_max: this.lutInfo.max,
      u_lut_strength: hasLook ? recipe.look.strength / 100 : 0,
    });
    let cur = t1;
    for (const use of recipe.shaders) {
      const s = this.shaders.get(use.name);
      if (!s || !s.colourOnly || !use.enabled || use.strength <= 0) continue;
      const next = cur === t1 ? t2 : t1;
      const values: Record<string, number | number[]> = { u_strength: use.strength / 100, u_texel: [1 / w, 1 / h], u_resolution: [w, h] };
      for (const p of s.def.params) values[`u_${p.name}`] = use.params[p.name] ?? p.default;
      this.pass(s.prog, next, { u_image: cur.texture, u_depth: this.flat }, values);
      cur = next;
    }
    gl.bindFramebuffer(gl.FRAMEBUFFER, cur.fbo);
    const rgba = new Float32Array(w * h * 4);
    gl.readPixels(0, 0, w, h, gl.RGBA, gl.FLOAT, rgba);
    gl.deleteTexture(src);
    free(gl, t1);
    free(gl, t2);
    const rgb = new Float32Array(w * h * 3);
    for (let i = 0; i < w * h; i++) for (let k = 0; k < 3; k++) rgb[i * 3 + k] = Math.min(1, Math.max(0, rgba[i * 4 + k]));
    return rgb;
  }

  shaderIsColourOnly(name: string): boolean { return this.shaders.get(name)?.colourOnly ?? false; }

  private pass(p: Program, to: Target | null, textures: Record<string, WebGLTexture>, values: Record<string, number | number[]>, width?: number, height?: number, flipY = false) {
    const gl = this.gl;
    gl.useProgram(p.program);
    gl.bindFramebuffer(gl.FRAMEBUFFER, to ? to.fbo : null);
    gl.viewport(0, 0, width ?? to!.width, height ?? to!.height);
    let unit = 0;
    // The LUT always sits on its own unit: sampler3D and sampler2D can't share one.
    const lutLoc = p.uniforms.get('u_lut');
    if (lutLoc) {
      gl.activeTexture(gl.TEXTURE0 + 7);
      gl.bindTexture(gl.TEXTURE_3D, this.lut);
      gl.uniform1i(lutLoc, 7);
    }
    for (const [name, tex] of Object.entries(textures)) {
      const loc = p.uniforms.get(name);
      if (!loc) continue;
      gl.activeTexture(gl.TEXTURE0 + unit);
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.uniform1i(loc, unit);
      unit += 1;
    }
    const flip = p.uniforms.get('u_flip_y');
    if (flip) gl.uniform1i(flip, flipY ? 1 : 0);
    for (const [name, v] of Object.entries(values)) {
      const loc = p.uniforms.get(name);
      if (!loc) continue;
      if (typeof v === 'number') {
        if (name === 'u_turns' || name === 'u_flip' || name === 'u_p3') gl.uniform1i(loc, v);
        else gl.uniform1f(loc, v);
      } else if (name === 'u_bands') gl.uniform3fv(loc, v);
      else if (v.length === 2) gl.uniform2fv(loc, v);
      else if (v.length === 3) gl.uniform3fv(loc, v);
      else if (v.length === 4) gl.uniform4fv(loc, v);
    }
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    gl.activeTexture(gl.TEXTURE0);
  }
}

export { ShaderError };
