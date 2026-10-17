// The photo in the middle: the pipeline drawing the open photo into a canvas that fits the stage.

import { Pipeline } from './gl/pipeline.js';
import { defaults, store, type Recipe } from './state.js';
import { h } from './dom.js';

export const header = 16;

/** A photo's URL under app://ui/, each path part encoded. */
export function photoUrl(kind: 'photo' | 'thumb', rel: string, edge?: number): string {
  const path = rel.split('/').map(encodeURIComponent).join('/');
  return edge === undefined ? `${kind}/${path}` : `${kind}/${path}?edge=${edge}`;
}

export interface Decoded { width: number; height: number; fullWidth: number; fullHeight: number; rgb: Uint16Array; }

/** The photo as linear half floats, decoded by the app (images.zig). */
export async function fetchPhoto(rel: string, edge: number): Promise<Decoded> {
  const r = await fetch(photoUrl('photo', rel, edge));
  if (!r.ok) throw new Error(`photo ${rel}: ${r.status}`);
  const buf = await r.arrayBuffer();
  const head = new DataView(buf, 0, header);
  return {
    width: head.getUint32(0, true),
    height: head.getUint32(4, true),
    fullWidth: head.getUint32(8, true),
    fullHeight: head.getUint32(12, true),
    rgb: new Uint16Array(buf, header),
  };
}

/** The recipe without its adjustments: what "before" shows. The crop stays, so the two line up. */
export function original(r: Recipe): Recipe {
  return { ...defaults(), crop: r.crop };
}

export class Viewer {
  readonly canvas: HTMLCanvasElement;
  readonly pipeline: Pipeline;
  readonly stage: HTMLElement;
  readonly overlay: HTMLElement;
  loaded: string | null = null;
  private loading: string | null = null;
  private frame = 0;
  private listeners: (() => void)[] = [];
  /** The canvas's place in the stage, for overlays. */
  box = { left: 0, top: 0, width: 0, height: 0 };

  constructor(stage: HTMLElement) {
    this.stage = stage;
    this.canvas = h('canvas', { class: 'stage__canvas' });
    this.overlay = h('div', { class: 'crop hidden' });
    stage.append(this.canvas, this.overlay);
    const gl = this.canvas.getContext('webgl2', { antialias: false, alpha: false, preserveDrawingBuffer: true });
    if (!gl) throw new Error('no WebGL2');
    this.pipeline = new Pipeline(gl);
    new ResizeObserver(() => this.schedule()).observe(stage);
  }

  /** Called after each drawn frame. */
  onDraw(fn: () => void) { this.listeners.push(fn); }

  async load(rel: string, edge: number): Promise<boolean> {
    if (this.loaded === rel || this.loading === rel) return false;
    this.loading = rel;
    const photo = await fetchPhoto(rel, edge);
    // Another photo was asked for meanwhile.
    if (this.loading !== rel) return false;
    this.pipeline.setSource(photo.width, photo.height, photo.rgb);
    this.loaded = rel;
    this.loading = null;
    this.schedule();
    return true;
  }

  unload() {
    this.loaded = null;
    this.loading = null;
    this.canvas.classList.add('hidden');
  }

  schedule() {
    if (this.frame) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = 0;
      this.draw();
    });
  }

  private draw() {
    if (!this.pipeline.ready || !this.loaded || !store.photo) return;
    this.canvas.classList.remove('hidden');
    const recipe = store.before ? original(store.recipe) : store.recipe;
    const uncropped = store.tab === 'crop';
    const [ow, oh] = this.pipeline.outputSize(recipe, uncropped);
    const pad = 32;
    const room = { w: Math.max(1, this.stage.clientWidth - 2 * pad), h: Math.max(1, this.stage.clientHeight - 2 * pad) };
    const scale = Math.min(room.w / ow, room.h / oh);
    const cssW = Math.max(1, Math.floor(ow * scale));
    const cssH = Math.max(1, Math.floor(oh * scale));
    const dpr = window.devicePixelRatio || 1;
    // Never more pixels than the preview has: the stage is the limit, not a reason to upscale.
    const w = Math.max(1, Math.min(ow, Math.round(cssW * dpr)));
    const hgt = Math.max(1, Math.round((w * oh) / ow));
    if (this.canvas.width !== w || this.canvas.height !== hgt) {
      this.canvas.width = w;
      this.canvas.height = hgt;
    }
    this.canvas.style.width = `${cssW}px`;
    this.canvas.style.height = `${cssH}px`;
    this.pipeline.render(recipe, { target: null, width: w, height: hgt, dither: 1 / 255, uncropped });
    this.box = {
      left: (this.stage.clientWidth - cssW) / 2,
      top: (this.stage.clientHeight - cssH) / 2,
      width: cssW,
      height: cssH,
    };
    for (const fn of this.listeners) fn();
  }
}
