// The Crop tab: aspect ratios, straighten, rotate and flip, and the crop drawn over the whole
// photo (the viewer shows it uncropped while this tab is open) with handles to drag.

import { h, section, slider, chips, icon, newGesture, type Slider } from './dom.js';
import { store, type Recipe } from './state.js';
import type { Viewer } from './viewer.js';

type Rect = [number, number, number, number];

export const aspects = [
  { value: 'original', label: 'Original' },
  { value: 'free', label: 'Free' },
  { value: '1:1', label: '1:1' },
  { value: '4:5', label: '4:5' },
  { value: '3:2', label: '3:2' },
  { value: '16:9', label: '16:9' },
] as const;

const minSize = 0.02;

/** The crop's width over its height in pixels, or null when free. */
function ratioOf(r: Recipe, photo: [number, number]): number | null {
  const a = r.crop.aspect;
  if (a === 'free') return null;
  if (a === 'original') return photo[0] / photo[1];
  const [x, y] = a.split(':').map(Number);
  return x / y;
}

/** The biggest rectangle of `ratio` centred where `rect` is, inside the photo. */
export function fitAspect(rect: Rect, ratio: number, photo: [number, number]): Rect {
  const cx = rect[0] + rect[2] / 2;
  const cy = rect[1] + rect[3] / 2;
  // In normalised units, width / height must be ratio × (photo height / photo width).
  const k = ratio * (photo[1] / photo[0]);
  let w = Math.min(1, k);
  let hgt = w / k;
  if (hgt > 1) { hgt = 1; w = k; }
  const x = Math.min(Math.max(cx - w / 2, 0), 1 - w);
  const y = Math.min(Math.max(cy - hgt / 2, 0), 1 - hgt);
  return [x, y, w, hgt];
}

export class CropPanel {
  readonly el: HTMLElement;
  private straighten: Slider;
  private aspect: { el: HTMLElement; set(v: string): void };
  private rect: HTMLElement;
  private handles: HTMLElement[];
  // The photo outside the crop, dimmed: above, below, left, right.
  private shades = [0, 1, 2, 3].map(() => h('div', { class: 'crop__shade' }));

  private viewer: Viewer;

  constructor(viewer: Viewer) {
    this.viewer = viewer;
    this.aspect = chips(aspects, 'original', (a) => this.setAspect(a));
    this.straighten = slider({
      label: 'Straighten', min: -45, max: 45, step: 0.1, value: 0,
      format: (v) => `${v > 0 ? '+' : ''}${v.toFixed(1)}°`,
      onchange: (v, g) => store.edit({ crop: { straighten: v } }, g),
    });
    const rotate = () => {
      const c = store.recipe.crop;
      // Clockwise as shown: the flip comes after the turn, so a flipped photo turns the other way.
      // The crop turns with the photo.
      const [x, y, w, hgt] = c.rect;
      store.edit({ crop: { rotate: (c.rotate + (c.flip ? 270 : 90)) % 360, rect: [1 - y - hgt, x, hgt, w] } });
    };
    const flip = () => {
      const c = store.recipe.crop;
      const [x, y, w, hgt] = c.rect;
      store.edit({ crop: { flip: !c.flip, rect: [1 - x - w, y, w, hgt] } });
    };
    this.el = h('div', { class: 'panel__body' },
      section('Aspect ratio', this.aspect.el),
      this.straighten.el,
      h('div', { style: { display: 'flex', gap: '8px' } },
        h('button', { type: 'button', class: 'btn', style: { flex: '1' }, onclick: rotate }, icon('rotate'), 'Rotate 90°'),
        h('button', { type: 'button', class: 'btn', style: { flex: '1' }, onclick: flip }, icon('flip'), 'Flip')),
      h('button', { type: 'button', class: 'btn btn--small btn--outline', style: { alignSelf: 'flex-start' }, onclick: () => store.edit({ crop: null }) }, 'Reset crop'),
      h('p', { class: 'hint' }, 'Drag the frame to move it, its corners to resize.'));

    this.rect = h('div', { class: 'crop__rect' });
    this.handles = ['nw', 'ne', 'sw', 'se'].map((corner) => {
      const el = h('div', { class: 'crop__handle', 'data-corner': corner });
      this.drag(el, corner);
      return el;
    });
    this.drag(this.rect, 'move');
    viewer.overlay.append(...this.shades, this.rect, ...this.handles);
    viewer.onDraw(() => this.place());
  }

  private photoSize(): [number, number] {
    const [w, hgt] = this.viewer.pipeline.outputSize(store.recipe, true);
    return [w, hgt];
  }

  private setAspect(a: string) {
    const r = store.recipe;
    const next: Recipe = { ...r, crop: { ...r.crop, aspect: a } };
    const ratio = ratioOf(next, this.photoSize());
    const rect = ratio === null ? r.crop.rect : fitAspect(r.crop.rect, ratio, this.photoSize());
    store.edit({ crop: { aspect: a, rect } });
  }

  update() {
    const c = store.recipe.crop;
    this.straighten.set(c.straighten);
    this.aspect.set(c.aspect);
    this.place();
  }

  // The crop frame over the canvas.
  private place() {
    const on = store.tab === 'crop' && !!store.photo && this.viewer.loaded === store.photo.rel;
    this.viewer.overlay.classList.toggle('hidden', !on);
    if (!on) return;
    const b = this.viewer.box;
    const [x, y, w, hgt] = store.recipe.crop.rect;
    const px = (v: number) => `${v}px`;
    const L = b.left + x * b.width, T = b.top + y * b.height, W = w * b.width, H = hgt * b.height;
    Object.assign(this.rect.style, { left: px(L), top: px(T), width: px(W), height: px(H) });
    const boxes: [number, number, number, number][] = [
      [b.left, b.top, b.width, T - b.top],
      [b.left, T + H, b.width, b.top + b.height - T - H],
      [b.left, T, L - b.left, H],
      [L + W, T, b.left + b.width - L - W, H],
    ];
    this.shades.forEach((el, i) => {
      const [l, t, wd, ht] = boxes[i];
      Object.assign(el.style, { left: px(l), top: px(t), width: px(Math.max(0, wd)), height: px(Math.max(0, ht)) });
    });
    const corners: Record<string, [number, number]> = { nw: [x, y], ne: [x + w, y], sw: [x, y + hgt], se: [x + w, y + hgt] };
    for (const el of this.handles) {
      const [cx, cy] = corners[el.dataset.corner!];
      Object.assign(el.style, { left: `${b.left + cx * b.width}px`, top: `${b.top + cy * b.height}px` });
    }
  }

  private drag(el: HTMLElement, kind: string) {
    el.addEventListener('pointerdown', (down) => {
      down.preventDefault();
      el.setPointerCapture(down.pointerId);
      const start: Rect = [...store.recipe.crop.rect] as Rect;
      const gesture = newGesture();
      const b = this.viewer.box;
      const photo = this.photoSize();
      const ratio = ratioOf(store.recipe, photo);
      const move = (e: PointerEvent) => {
        const dx = (e.clientX - down.clientX) / b.width;
        const dy = (e.clientY - down.clientY) / b.height;
        store.edit({ crop: { rect: kind === 'move' ? moved(start, dx, dy) : resized(start, kind, dx, dy, ratio, photo) } }, gesture);
      };
      const up = () => {
        el.removeEventListener('pointermove', move);
        el.removeEventListener('pointerup', up);
        el.removeEventListener('pointercancel', up);
      };
      el.addEventListener('pointermove', move);
      el.addEventListener('pointerup', up);
      el.addEventListener('pointercancel', up);
    });
  }
}

function moved([x, y, w, hgt]: Rect, dx: number, dy: number): Rect {
  return [Math.min(Math.max(x + dx, 0), 1 - w), Math.min(Math.max(y + dy, 0), 1 - hgt), w, hgt];
}

/** The rectangle with one corner dragged; the opposite corner stays, the ratio holds. */
export function resized([x, y, w, hgt]: Rect, corner: string, dx: number, dy: number, ratio: number | null, photo: [number, number]): Rect {
  const west = corner.includes('w');
  const north = corner.includes('n');
  // The fixed corner.
  const fx = west ? x + w : x;
  const fy = north ? y + hgt : y;
  let nw = Math.max(minSize, west ? w - dx : w + dx);
  let nh = Math.max(minSize, north ? hgt - dy : hgt + dy);
  // Room up to the photo's edge from the fixed corner.
  const roomW = west ? fx : 1 - fx;
  const roomH = north ? fy : 1 - fy;
  nw = Math.min(nw, roomW);
  nh = Math.min(nh, roomH);
  if (ratio !== null) {
    const k = ratio * (photo[1] / photo[0]);
    // Follow whichever side moved more, then fit the room.
    if (nw / k > nh) nh = nw / k; else nw = nh * k;
    if (nw > roomW) { nw = roomW; nh = nw / k; }
    if (nh > roomH) { nh = roomH; nw = nh * k; }
  }
  return [west ? fx - nw : fx, north ? fy - nh : fy, nw, nh];
}
