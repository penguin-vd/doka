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

const early = new Map<string, Promise<Decoded>>();

/** Starts fetching a photo before the pipeline exists: start-up overlaps the two. */
export function fetchEarly(rel: string, edge: number) {
  const p = fetchPhoto(rel, edge);
  p.catch(() => early.delete(`${rel}@${edge}`));
  early.set(`${rel}@${edge}`, p);
}

function takeEarly(rel: string, edge: number): Promise<Decoded> {
  const key = `${rel}@${edge}`;
  const p = early.get(key);
  early.delete(key);
  return p ?? fetchPhoto(rel, edge);
}

/** The recipe without its adjustments: what "before" shows. The crop stays, so the two line up. */
export function original(r: Recipe): Recipe {
  return { ...defaults(), crop: r.crop };
}

/** The stage's canvas and its WebGL2 context (made first: the GPU check runs on it). */
export function stageCanvas(): { canvas: HTMLCanvasElement; gl: WebGL2RenderingContext | null } {
  const canvas = h('canvas', { class: 'stage__canvas' });
  // preserveDrawingBuffer: `--shot` pictures need the canvas's last frame.
  return { canvas, gl: canvas.getContext('webgl2', { antialias: false, alpha: false, preserveDrawingBuffer: true }) };
}

interface Layout {
  // The canvas's place in the stage, css pixels.
  box: { left: number; top: number; width: number; height: number };
  // The part of the output on the canvas, 0..1.
  view: [number, number, number, number];
  // The whole output at this zoom, css pixels.
  image: { width: number; height: number };
}

const pad = 32;
// Deepest zoom: four screen pixels per photo pixel.
const maxPixelZoom = 4;

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
  // Zoom: 1 fits the stage; the centre of what's shown, in output 0..1.
  zoom = 1;
  private centre: [number, number] = [0.5, 0.5];
  // The full-size photo is on the GPU (zoomed past the preview's pixels).
  private full: string | null = null;
  private fullLoading: string | null = null;
  // Before/after: the divider's place across the canvas, 0..1.
  split = 0.5;
  private divider: HTMLElement;

  constructor(stage: HTMLElement, canvas: HTMLCanvasElement, gl: WebGL2RenderingContext) {
    this.stage = stage;
    this.canvas = canvas;
    this.overlay = h('div', { class: 'crop hidden' });
    this.divider = h('div', { class: 'compare hidden' },
      h('span', { class: 'compare__label compare__label--before' }, 'Before'),
      h('span', { class: 'compare__label compare__label--after' }, 'After'),
      h('div', { class: 'compare__handle', 'aria-hidden': 'true' }));
    stage.append(this.canvas, this.overlay, this.divider);
    this.pipeline = new Pipeline(gl);
    new ResizeObserver(() => this.schedule()).observe(stage);
    this.interact();
  }

  /** Called after each drawn frame. */
  onDraw(fn: () => void) { this.listeners.push(fn); }

  private pending: Promise<void> | null = null;

  /** Puts the photo on the GPU; resolves when it's there (at once if it already is). */
  load(rel: string, edge: number): Promise<void> {
    if (this.loaded === rel) return Promise.resolve();
    if (this.loading === rel && this.pending) return this.pending;
    this.loading = rel;
    this.pending = takeEarly(rel, edge).then((photo) => {
      // Another photo was asked for meanwhile.
      if (this.loading !== rel) return;
      this.pipeline.setSource(photo.width, photo.height, photo.rgb);
      this.loaded = rel;
      this.loading = null;
      this.full = null;
      this.zoom = 1;
      this.centre = [0.5, 0.5];
      this.schedule();
    });
    return this.pending;
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

  private zoomable(): boolean { return store.tab !== 'crop'; }

  // The output's size in full-size pixels: what 100% means.
  private fullSize(recipe: Recipe): [number, number] {
    const info = store.photo!.info;
    const turned = (recipe.crop.rotate / 90) % 2 === 1;
    const r = store.tab === 'crop' ? [0, 0, 1, 1] : recipe.crop.rect;
    return [(turned ? info.height : info.width) * r[2], (turned ? info.width : info.height) * r[3]];
  }

  private layout(recipe: Recipe, zoom: number, centre: [number, number]): Layout {
    const [ow, oh] = this.pipeline.outputSize(recipe, store.tab === 'crop');
    const room = { w: Math.max(1, this.stage.clientWidth - 2 * pad), h: Math.max(1, this.stage.clientHeight - 2 * pad) };
    const scale = Math.min(room.w / ow, room.h / oh) * zoom;
    const image = { width: ow * scale, height: oh * scale };
    const width = Math.max(1, Math.floor(Math.min(room.w, image.width)));
    const height = Math.max(1, Math.floor(Math.min(room.h, image.height)));
    const vw = Math.min(1, width / image.width);
    const vh = Math.min(1, height / image.height);
    const x = Math.min(Math.max(centre[0] - vw / 2, 0), 1 - vw);
    const y = Math.min(Math.max(centre[1] - vh / 2, 0), 1 - vh);
    return {
      box: { left: (this.stage.clientWidth - width) / 2, top: (this.stage.clientHeight - height) / 2, width, height },
      view: [x, y, vw, vh],
      image,
    };
  }

  /** The zoom at which one photo pixel is one screen pixel. */
  private actualSize(recipe: Recipe): number {
    const fit = this.layout(recipe, 1, [0.5, 0.5]);
    return this.fullSize(recipe)[0] / (fit.image.width * (window.devicePixelRatio || 1));
  }

  /** "Fit", or how big a photo pixel is on the screen. */
  zoomLabel(): string {
    if (this.zoom <= 1.001 || !store.photo) return 'Fit';
    return `${Math.round((this.zoom / this.actualSize(store.recipe)) * 100)}%`;
  }

  private setZoom(zoom: number, at: { x: number; y: number } | null) {
    if (!store.photo || !this.zoomable()) return;
    const recipe = store.recipe;
    const max = Math.max(2, this.actualSize(recipe) * maxPixelZoom);
    const z = Math.min(Math.max(zoom, 1), max);
    const before = this.layout(recipe, this.zoom, this.centre);
    // The point under the cursor stays under it.
    const u = at ? Math.min(Math.max((at.x - before.box.left) / before.box.width, 0), 1) : 0.5;
    const v = at ? Math.min(Math.max((at.y - before.box.top) / before.box.height, 0), 1) : 0.5;
    const px = before.view[0] + u * before.view[2];
    const py = before.view[1] + v * before.view[3];
    const after = this.layout(recipe, z, [px, py]);
    const u2 = (at ? at.x - after.box.left : after.box.width / 2) / after.box.width;
    const v2 = (at ? at.y - after.box.top : after.box.height / 2) / after.box.height;
    this.centre = [px - u2 * after.view[2] + after.view[2] / 2, py - v2 * after.view[3] + after.view[3] / 2];
    this.zoom = z;
    this.schedule();
  }

  private interact() {
    this.stage.addEventListener('wheel', (e) => {
      if (!this.zoomable() || !store.photo) return;
      e.preventDefault();
      const r = this.stage.getBoundingClientRect();
      const lines = e.deltaMode === 1 ? 40 : 1;
      this.setZoom(this.zoom * Math.exp(-e.deltaY * lines * 0.0015), { x: e.clientX - r.left, y: e.clientY - r.top });
    }, { passive: false });
    this.canvas.addEventListener('dblclick', (e) => {
      const r = this.stage.getBoundingClientRect();
      this.setZoom(this.zoom > 1.01 ? 1 : this.actualSize(store.recipe), { x: e.clientX - r.left, y: e.clientY - r.top });
    });
    this.canvas.addEventListener('pointerdown', (down) => {
      if (this.zoom <= 1.001 || !this.zoomable()) return;
      this.canvas.setPointerCapture(down.pointerId);
      this.canvas.classList.add('stage__canvas--grabbing');
      const start = [...this.centre];
      const l = this.layout(store.recipe, this.zoom, this.centre);
      const move = (e: PointerEvent) => {
        this.centre = [start[0] - (e.clientX - down.clientX) / l.image.width, start[1] - (e.clientY - down.clientY) / l.image.height];
        this.schedule();
      };
      const up = () => {
        this.canvas.classList.remove('stage__canvas--grabbing');
        this.canvas.removeEventListener('pointermove', move);
        this.canvas.removeEventListener('pointerup', up);
      };
      this.canvas.addEventListener('pointermove', move);
      this.canvas.addEventListener('pointerup', up);
    });
    this.divider.addEventListener('pointerdown', (down) => {
      down.preventDefault();
      this.divider.setPointerCapture(down.pointerId);
      const move = (e: PointerEvent) => {
        const r = this.canvas.getBoundingClientRect();
        this.split = Math.min(Math.max((e.clientX - r.left) / r.width, 0), 1);
        this.schedule();
      };
      const up = () => {
        this.divider.removeEventListener('pointermove', move);
        this.divider.removeEventListener('pointerup', up);
      };
      this.divider.addEventListener('pointermove', move);
      this.divider.addEventListener('pointerup', up);
    });
  }

  // Zoomed past the preview's own pixels: the full-size photo takes its place, once.
  private wantFull(l: Layout, canvasWidth: number, ow: number) {
    const rel = store.photo!.rel;
    if (this.full === rel || this.fullLoading === rel) return;
    if (canvasWidth <= l.view[2] * ow * 1.05) return;
    this.fullLoading = rel;
    fetchPhoto(rel, 0).then((photo) => {
      this.fullLoading = null;
      if (this.loaded !== rel || store.photo?.rel !== rel) return;
      this.pipeline.setSource(photo.width, photo.height, photo.rgb);
      this.full = rel;
      this.schedule();
    }).catch(() => { this.fullLoading = null; });
  }

  private draw() {
    // Until the new photo is on the GPU the old frame stays: never the old photo with the new crop.
    if (!this.pipeline.ready || !store.photo || this.loaded !== store.photo.rel) return;
    this.canvas.classList.remove('hidden');
    if (!this.zoomable()) this.zoom = 1;
    const recipe = store.before ? original(store.recipe) : store.recipe;
    const uncropped = store.tab === 'crop';
    const l = this.layout(recipe, this.zoom, this.centre);
    this.centre = [l.view[0] + l.view[2] / 2, l.view[1] + l.view[3] / 2];
    const dpr = window.devicePixelRatio || 1;
    const w = Math.max(1, Math.round(l.box.width * dpr));
    const hgt = Math.max(1, Math.round(l.box.height * dpr));
    if (this.canvas.width !== w || this.canvas.height !== hgt) {
      this.canvas.width = w;
      this.canvas.height = hgt;
    }
    this.canvas.style.width = `${l.box.width}px`;
    this.canvas.style.height = `${l.box.height}px`;
    const out = { target: null, width: w, height: hgt, dither: 1 / 255, uncropped, view: l.view };
    this.pipeline.render(recipe, out);
    // Before/after: the original drawn over the left of the divider.
    const comparing = store.compare && !store.before && !uncropped;
    if (comparing) this.pipeline.render(original(recipe), { ...out, scissor: [0, 0, Math.round(this.split * w), hgt] });
    this.divider.classList.toggle('hidden', !comparing);
    if (comparing) {
      Object.assign(this.divider.style, { left: `${l.box.left + this.split * l.box.width}px`, top: `${l.box.top}px`, height: `${l.box.height}px` });
    }
    this.canvas.classList.toggle('stage__canvas--zoomed', this.zoom > 1.001);
    this.box = l.box;
    if (this.zoom > 1.001) this.wantFull(l, w, this.pipeline.outputSize(recipe, uncropped)[0]);
    for (const fn of this.listeners) fn();
  }
}
