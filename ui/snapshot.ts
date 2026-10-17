// The rendered photo as a JPEG, for Claude (get_view's screenshot): the pipeline drawing into a
// small framebuffer, not a grab of the screen.

import { target, free } from './gl/gl.js';
import type { Pipeline } from './gl/pipeline.js';
import type { Recipe } from './state.js';

export interface Tones {
  // Shares of the pixels, in %: a channel at 255, all channels at 0..2.
  clipped_highlights: number;
  clipped_red: number;
  clipped_green: number;
  clipped_blue: number;
  crushed_shadows: number;
  // Mean brightness 0..255, and the brightness histogram in 16 bins (% each), darkest first.
  mean: number;
  histogram: number[];
}

/** Numbers about the rendered photo, so Claude needn't judge exposure from a small JPEG. */
export function tones(px: Uint8ClampedArray): Tones {
  const n = px.length / 4;
  let hi = 0, r = 0, g = 0, b = 0, lo = 0, sum = 0;
  const bins = new Array(16).fill(0);
  for (let i = 0; i < px.length; i += 4) {
    const R = px[i], G = px[i + 1], B = px[i + 2];
    if (R >= 255) r++;
    if (G >= 255) g++;
    if (B >= 255) b++;
    if (R >= 255 || G >= 255 || B >= 255) hi++;
    if (R <= 2 && G <= 2 && B <= 2) lo++;
    const l = 0.2126 * R + 0.7152 * G + 0.0722 * B;
    sum += l;
    bins[Math.min(15, Math.floor(l / 16))]++;
  }
  const pct = (x: number) => Math.round((x / n) * 1000) / 10;
  return {
    clipped_highlights: pct(hi), clipped_red: pct(r), clipped_green: pct(g), clipped_blue: pct(b),
    crushed_shadows: pct(lo), mean: Math.round(sum / n), histogram: bins.map(pct),
  };
}

export function snapshotJpeg(p: Pipeline, recipe: Recipe, edge: number): { data: string; tones: Tones } {
  const gl = p.gl;
  const [ow, oh] = p.outputSize(recipe);
  const scale = Math.min(1, edge / Math.max(ow, oh));
  const w = Math.max(1, Math.round(ow * scale));
  const h = Math.max(1, Math.round(oh * scale));
  const t = target(gl, w, h, gl.RGBA8, gl.UNSIGNED_BYTE);
  p.render(recipe, { target: t, width: w, height: h, dither: 1 / 255 });
  const px = new Uint8ClampedArray(w * h * 4);
  gl.bindFramebuffer(gl.FRAMEBUFFER, t.fbo);
  gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, px);
  free(gl, t);
  const canvas = document.createElement('canvas');
  canvas.width = w;
  canvas.height = h;
  canvas.getContext('2d')!.putImageData(new ImageData(px, w, h), 0, 0);
  return { data: canvas.toDataURL('image/jpeg', 0.85).split(',')[1], tones: tones(px) };
}
