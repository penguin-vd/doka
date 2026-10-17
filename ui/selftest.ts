// The pipeline's tests, run on the GPU by `zig build probe` (and so by every commit).
// Small made-up images go through the real shaders; what comes back is checked to the 8-bit level.

import { Pipeline, ShaderError } from './gl/pipeline.js';
import { target, free } from './gl/gl.js';
import { complete, type Recipe } from './state.js';

export interface Result { name: string; ok: boolean; detail: string; }

function toHalf(v: number): number {
  const f = new Float32Array([v]);
  const x = new Uint32Array(f.buffer)[0];
  const sign = (x >>> 16) & 0x8000;
  let exp = ((x >>> 23) & 0xff) - 127 + 15;
  let mant = x & 0x7fffff;
  if (exp <= 0) {
    if (exp < -10) return sign;
    mant = (mant | 0x800000) >> (1 - exp);
    return sign | ((mant + 0x1000) >> 13);
  }
  if (exp >= 31) return sign | 0x7c00;
  const h = sign | (exp << 10) | ((mant + 0x1000) >> 13);
  return h;
}

const decode = (c: number) => (c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
const encode = (l: number) => (l <= 0.0031308 ? 12.92 * l : 1.055 * Math.pow(l, 1 / 2.4) - 0.055);

/** Renders `linear` (w×h RGB) with the recipe, returns the 8-bit RGBA output and its size. */
function run(p: Pipeline, w: number, h: number, linear: number[], patch: unknown, view?: [number, number, number, number]): { px: Uint8Array; w: number; h: number } {
  const gl = p.gl;
  p.setSource(w, h, new Uint16Array(linear.map(toHalf)));
  const recipe: Recipe = complete(patch);
  let [ow, oh] = p.outputSize(recipe);
  if (view) { ow = Math.round(ow * view[2]); oh = Math.round(oh * view[3]); }
  const t = target(gl, ow, oh, gl.RGBA8, gl.UNSIGNED_BYTE);
  p.render(recipe, { target: t, width: ow, height: oh, view });
  const px = new Uint8Array(ow * oh * 4);
  gl.bindFramebuffer(gl.FRAMEBUFFER, t.fbo);
  gl.readPixels(0, 0, ow, oh, gl.RGBA, gl.UNSIGNED_BYTE, px);
  free(gl, t);
  return { px, w: ow, h: oh };
}

function grey(values: number[]): number[] {
  return values.flatMap((v) => [v, v, v]);
}

export function selfTest(): Result[] {
  const results: Result[] = [];
  const check = (name: string, f: () => string | true) => {
    try {
      const r = f();
      results.push({ name, ok: r === true, detail: r === true ? '' : r });
    } catch (e) {
      results.push({ name, ok: false, detail: String((e as Error).message ?? e) });
    }
  };
  const canvas = document.createElement('canvas');
  const gl = canvas.getContext('webgl2')!;
  const p = new Pipeline(gl);

  // Every 8-bit sRGB value, per channel: all sliders at 0 must give it back.
  const ramp: number[] = [];
  for (let i = 0; i < 256; i++) ramp.push(decode(i / 255), decode(((i * 7) % 256) / 255), decode((255 - i) / 255));
  check('all sliders at 0 change nothing', () => {
    const { px } = run(p, 256, 1, ramp, {});
    let worst = 0;
    for (let i = 0; i < 256; i++) {
      worst = Math.max(worst, Math.abs(px[i * 4] - i), Math.abs(px[i * 4 + 1] - (i * 7) % 256), Math.abs(px[i * 4 + 2] - (255 - i)));
    }
    return worst <= 1 || `off by ${worst} levels`;
  });

  check('exposure +1 doubles the light below the shoulder', () => {
    const { px } = run(p, 1, 1, grey([0.05]), { edits: { exposure: 1 } });
    const want = Math.round(encode(0.1) * 255);
    return Math.abs(px[0] - want) <= 1 || `got ${px[0]}, want ${want}`;
  });

  check('pushed highlights roll off to white without clipping early', () => {
    const { px } = run(p, 4, 1, grey([0.25, 0.5, 0.75, 1]), { edits: { exposure: 2 } });
    const v = [px[0], px[4], px[8], px[12]];
    return (v[0] < v[1] && v[1] < v[2] && v[2] < v[3] && v[3] >= 254) || `got ${v}`;
  });

  check('highlights −100 darkens white, shadows +100 lifts black', () => {
    const hi = run(p, 1, 1, grey([1]), { edits: { highlights: -100 } }).px[0];
    const sh = run(p, 1, 1, grey([0.005]), { edits: { shadows: 100 } }).px[0];
    const base = Math.round(encode(0.005) * 255);
    return (hi < 230 && sh > base + 10) || `white ${hi}, shadow ${sh} (from ${base})`;
  });

  check('saturation −100 is grey', () => {
    const { px } = run(p, 1, 1, [0.6, 0.1, 0.05], { edits: { saturation: -100 } });
    return Math.max(px[0], px[1], px[2]) - Math.min(px[0], px[1], px[2]) <= 2 || `got ${px.slice(0, 3)}`;
  });

  check('temperature warms: more red, less blue', () => {
    const { px } = run(p, 1, 1, grey([0.2]), { edits: { temperature: 50 } });
    return (px[0] > px[1] && px[1] > px[2]) || `got ${px.slice(0, 3)}`;
  });

  // Six distinct pixels, 3 wide, 2 high: the geometry tests follow them.
  const colours = [[1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 0], [0, 1, 1], [1, 0, 1]];
  const six = colours.flat().map((c) => c * 0.8);
  const at = (r: { px: Uint8Array; w: number }, x: number, y: number) => {
    const i = (y * r.w + x) * 4;
    return colours.findIndex((c) => c.every((v, k) => Math.abs(r.px[i + k] - (v ? 231 : 0)) <= 2));
  };
  check('rotate 90° turns clockwise', () => {
    const r = run(p, 3, 2, six, { crop: { rotate: 90 } });
    if (r.w !== 2 || r.h !== 3) return `size ${r.w}×${r.h}`;
    // Clockwise: the bottom-left pixel comes to the top-left.
    const got = [at(r, 0, 0), at(r, 1, 0), at(r, 0, 2), at(r, 1, 2)];
    return got.join() === '3,0,5,2' || `got ${got}`;
  });
  check('flip mirrors left to right', () => {
    const r = run(p, 3, 2, six, { crop: { flip: true } });
    const got = [at(r, 0, 0), at(r, 2, 0), at(r, 0, 1)];
    return got.join() === '2,0,5' || `got ${got}`;
  });
  check('crop keeps the rectangle asked for', () => {
    const r = run(p, 3, 2, six, { crop: { rect: [2 / 3, 0, 1 / 3, 1] } });
    if (r.w !== 1 || r.h !== 2) return `size ${r.w}×${r.h}`;
    return [at(r, 0, 0), at(r, 0, 1)].join() === '2,5' || `got ${[at(r, 0, 0), at(r, 0, 1)]}`;
  });

  check('a zoomed view shows that part of the photo', () => {
    const r = run(p, 3, 2, six, {}, [2 / 3, 0, 1 / 3, 1]);
    return [at(r, 0, 0), at(r, 0, 1)].join() === '2,5' || `got ${[at(r, 0, 0), at(r, 0, 1)]}`;
  });

  check('an identity look changes nothing', () => {
    const n = 17;
    const data = new Float32Array(n * n * n * 3);
    for (let b = 0; b < n; b++) for (let g = 0; g < n; g++) for (let r = 0; r < n; r++) {
      const i = (b * n * n + g * n + r) * 3;
      data[i] = r / (n - 1); data[i + 1] = g / (n - 1); data[i + 2] = b / (n - 1);
    }
    p.setLook({ title: 'identity', size: n, min: [0, 0, 0], max: [1, 1, 1], data });
    const { px } = run(p, 256, 1, ramp, { look: { name: 'identity.cube', strength: 100 } });
    p.setLook(null);
    let worst = 0;
    for (let i = 0; i < 256; i++) worst = Math.max(worst, Math.abs(px[i * 4] - i), Math.abs(px[i * 4 + 2] - (255 - i)));
    return worst <= 1 || `off by ${worst} levels`;
  });

  check('a shader runs, and a broken one is refused with its error', () => {
    const def = { name: 'invert', description: '', params: [{ name: 'amount', default: 1, min: 0, max: 1 }], needs: [] };
    p.setShader('invert', p.compileShader(def, 'vec3 effect(vec3 c) { return mix(c, 1.0 - c, u_amount); }'));
    const { px } = run(p, 1, 1, grey([0]), { shaders: [{ name: 'invert', strength: 100, params: {} }] });
    p.setShader('invert', null);
    if (px[0] < 250) return `inverted black gave ${px[0]}`;
    try {
      p.compileShader(def, 'vec3 effect(vec3 c) { return nope; }');
      return 'a broken shader compiled';
    } catch (e) {
      return (e instanceof ShaderError && /nope/.test(e.message)) || `wrong error: ${e}`;
    }
  });

  check('a baked look reproduces the colour settings', () => {
    p.setSource(1, 1, new Uint16Array([0, 0, 0]));
    const lattice = p.bakeLattice(complete({ edits: { saturation: -100 } }), 9);
    // Pure red's lattice point, made grey.
    const i = 8 * 3;
    return Math.abs(lattice[i] - lattice[i + 1]) < 0.01 || `red became ${lattice.slice(i, i + 3)}`;
  });

  return results;
}
