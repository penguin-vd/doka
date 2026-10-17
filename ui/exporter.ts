// Exports drawn on the GPU (SPEC.md, Image pipeline): the photo at full size through the same
// shaders as the preview, in a pipeline of its own, its pixels sent to the app in strips; the app
// encodes them with the original's metadata (src/app/exporter.zig).

import { Pipeline } from './gl/pipeline.js';
import { target, free } from './gl/gl.js';
import { complete, type Recipe } from './state.js';
import { fetchPhoto } from './viewer.js';
import { report } from './rpc.js';
import type { Library } from './library.js';

export interface ExportJob { id: number; rel: string; bits: 8 | 16; p3: boolean; index: number; total: number; recipe: unknown; }

// A strip of rows at a time: memory stays small whatever the photo's size.
const stripBytes = 32 << 20;

export async function renderExport(job: ExportJob, library: Library, progress: (done: number) => void) {
  const url = (action: string) => `export/${job.id}${action}`;
  let gl: WebGL2RenderingContext | null = null;
  try {
    const recipe: Recipe = complete(job.recipe);
    const photo = await fetchPhoto(job.rel, 0);
    gl = document.createElement('canvas').getContext('webgl2', { antialias: false, alpha: false });
    if (!gl) throw new Error('no WebGL2 for the export');
    const p = new Pipeline(gl);
    await library.prepare(p, recipe);
    p.setSource(photo.width, photo.height, photo.rgb);
    const [w, h] = p.outputSize(recipe);
    const deep = job.bits === 16;
    // 16 bits need more than half floats' 11 bits of precision.
    const t = deep ? target(gl, w, h, gl.RGBA32F, gl.FLOAT) : target(gl, w, h, gl.RGBA8, gl.UNSIGNED_BYTE);
    p.render(recipe, { target: t, width: w, height: h, p3: job.p3, dither: deep ? 1 / 65535 : 1 / 255 });
    gl.bindFramebuffer(gl.FRAMEBUFFER, t.fbo);

    const rows = Math.max(1, Math.floor(stripBytes / (w * (deep ? 16 : 4))));
    const rgba = deep ? new Float32Array(w * rows * 4) : new Uint8Array(w * rows * 4);
    for (let y = 0; y < h; y += rows) {
      const n = Math.min(rows, h - y);
      gl.readPixels(0, y, w, n, gl.RGBA, deep ? gl.FLOAT : gl.UNSIGNED_BYTE, rgba);
      const count = w * n;
      let body: ArrayBufferView;
      if (deep) {
        const out = new Uint16Array(count * 3);
        const src = rgba as Float32Array;
        for (let i = 0; i < count; i++) for (let k = 0; k < 3; k++) {
          const v = src[i * 4 + k];
          out[i * 3 + k] = v <= 0 ? 0 : v >= 1 ? 65535 : Math.round(v * 65535);
        }
        body = out;
      } else {
        const out = new Uint8Array(count * 3);
        const src = rgba as Uint8Array;
        for (let i = 0; i < count; i++) {
          out[i * 3] = src[i * 4];
          out[i * 3 + 1] = src[i * 4 + 1];
          out[i * 3 + 2] = src[i * 4 + 2];
        }
        body = out;
      }
      const r = await fetch(url(`?width=${w}&height=${h}&y=${y}&rows=${n}`), { method: 'POST', body });
      if (!r.ok) throw new Error(`sending rows ${y}–${y + n}: ${r.status}`);
      progress((y + n) / h);
    }
    free(gl, t);
    const r = await fetch(url('/done'), { method: 'POST' });
    if (!r.ok) throw new Error(`encoding failed: ${r.status}`);
  } catch (e) {
    report(e);
    await fetch(url('/fail'), { method: 'POST', body: String((e as Error).message ?? e) }).catch(() => {});
  } finally {
    // Its textures are big: give the GPU memory back now.
    gl?.getExtension('WEBGL_lose_context')?.loseContext();
  }
}
