// What the page shows, as the app last said it: the folder, the photo and its recipe. Panels read
// it and subscribe; edits go to the app (`edit`) and come back as the new state.

import { call } from './rpc.js';

export interface Band { hue: number; sat: number; light: number; }
export const bands = ['reds', 'oranges', 'yellows', 'greens', 'blues', 'purples'] as const;
export type BandName = typeof bands[number];

export interface ShaderUse { name: string; strength: number; enabled: boolean; params: Record<string, number>; }

export interface Recipe {
  version: number;
  edits: { exposure: number; temperature: number; tint: number; contrast: number; highlights: number; shadows: number; saturation: number; };
  look: { name: string; strength: number; };
  shaders: ShaderUse[];
  colour: Record<BandName, Band>;
  halation: number;
  grain: { amount: number; size: number; };
  detail: { sharpen: number; noise: number; };
  vignette: number;
  crop: { aspect: string; straighten: number; rotate: number; flip: boolean; rect: [number, number, number, number]; };
  updatedBy: 'user' | 'claude';
  updatedAt: string;
}

// The same defaults as src/core/recipe.zig: every one means "unchanged".
export function defaults(): Recipe {
  const colour = {} as Record<BandName, Band>;
  for (const b of bands) colour[b] = { hue: 0, sat: 0, light: 0 };
  return {
    version: 1,
    edits: { exposure: 0, temperature: 0, tint: 0, contrast: 0, highlights: 0, shadows: 0, saturation: 0 },
    look: { name: 'none', strength: 100 },
    shaders: [],
    colour,
    halation: 0,
    grain: { amount: 0, size: 50 },
    detail: { sharpen: 0, noise: 0 },
    vignette: 0,
    crop: { aspect: 'original', straighten: 0, rotate: 0, flip: false, rect: [0, 0, 1, 1] },
    updatedBy: 'user',
    updatedAt: '',
  };
}

/** `patch` merged into `base`, as the app merges it: objects by field, the rest replaced. */
export function merge<T>(base: T, patch: unknown): T {
  if (patch === null || typeof patch !== 'object' || Array.isArray(patch) || base === null || typeof base !== 'object' || Array.isArray(base)) return patch as T;
  const out = { ...(base as Record<string, unknown>) };
  for (const [k, v] of Object.entries(patch as Record<string, unknown>)) {
    // null puts a field back to its default.
    if (v === null) delete out[k];
    else out[k] = merge(out[k], v);
  }
  return out as T;
}

/** A recipe as the app writes it (only what changed), filled in with the defaults. */
export function complete(r: unknown): Recipe {
  const full = merge(defaults(), r);
  // A field put back to its default by `merge` is gone; the defaults fill it again.
  for (const [k, v] of Object.entries(defaults())) {
    const f = full as unknown as Record<string, unknown>;
    if (f[k] === undefined) f[k] = v;
    else if (v && typeof v === 'object' && !Array.isArray(v)) f[k] = merge(v, f[k]);
  }
  full.shaders = (full.shaders ?? []).map((s) => ({ strength: 100, enabled: true, params: {}, ...s }));
  return full;
}

export interface Info { make: string; model: string; lens: string; exposure: string; aperture: string; iso: string; focal_length: string; taken: string; width: number; height: number; }

export interface Photo {
  rel: string;
  index: number;
  edited: boolean;
  info: Info;
  recipe: Recipe;
  canUndo: boolean;
  canRedo: boolean;
  claude: { note: string } | null;
}

export interface FolderState { name: string; path: string; photos: { rel: string; edited: boolean }[]; }

export interface AppState { folder: FolderState | null; photo: Photo | null; shotTab: string; previewEdge: number; }

export type Tab = 'adjust' | 'looks' | 'crop';

type Listener = () => void;

class Store {
  folder: FolderState | null = null;
  photo: Photo | null = null;
  tab: Tab = 'adjust';
  // Holding \\: the whole original.
  before = false;
  // Before/after with a divider (the header's button).
  compare = false;
  // Photos picked with Ctrl or Shift for a batch export.
  selected = new Set<string>();
  private listeners = new Set<Listener>();
  // Edits sent but not yet answered; while dragging the page keeps its own copy.
  private pending = 0;

  subscribe(fn: Listener) { this.listeners.add(fn); }
  notify() { for (const fn of this.listeners) fn(); }

  setPhoto(p: Photo | null) {
    if (p) p.recipe = complete(p.recipe);
    this.photo = p;
    if (p && this.folder) {
      const entry = this.folder.photos[p.index];
      if (entry) entry.edited = p.edited;
    }
    this.notify();
  }

  get recipe(): Recipe { return this.photo ? this.photo.recipe : defaults(); }

  /** Changes the photo's recipe now, and tells the app. */
  async edit(patch: unknown, gesture = 0) {
    if (!this.photo) return;
    this.photo.recipe = complete(merge(this.photo.recipe, patch));
    this.notify();
    this.pending += 1;
    try {
      const p = await call<Photo>('edit', { patch, gesture });
      this.pending -= 1;
      // A later edit is on its way; its answer will bring the state.
      if (this.pending === 0 && p && this.photo && p.rel === this.photo.rel) this.setPhoto(p);
    } catch (e) {
      this.pending -= 1;
      throw e;
    }
  }

  async step(method: 'undo' | 'redo' | 'keep' | 'undoClaude') {
    if (!this.photo) return;
    this.setPhoto(await call<Photo>(method));
  }
}

export const store = new Store();
