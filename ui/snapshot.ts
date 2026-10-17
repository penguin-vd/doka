// The rendered photo as a JPEG, for Claude (get_view's screenshot): the pipeline drawing into a
// small framebuffer, not a grab of the screen.

import { target, free } from './gl/gl.js';
import type { Pipeline } from './gl/pipeline.js';
import type { Recipe } from './state.js';

export function snapshotJpeg(p: Pipeline, recipe: Recipe, edge: number): string {
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
  return canvas.toDataURL('image/jpeg', 0.85).split(',')[1];
}
