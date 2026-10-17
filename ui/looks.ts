// The Looks tab: a grid of looks drawn on the current photo, the look's strength, grain,
// halation and vignette, the colour mixer (folded away), and the photo's shaders in order.

import { h, clear, section, fold, slider, chips, iconButton, type Slider } from './dom.js';
import { store, bands, type Recipe, type ShaderUse } from './state.js';
import { target, free } from './gl/gl.js';
import { report } from './rpc.js';
import type { Library } from './library.js';
import type { Viewer } from './viewer.js';

const thumbWidth = 160;
const pct = (v: number) => `${Math.round(v)}%`;
const plain = (v: number) => String(Math.round(v));

export class LooksPanel {
  readonly el: HTMLElement;
  private grid = h('div', { class: 'looks' });
  private strength: Slider;
  private effects: { s: Slider; read: (r: Recipe) => number }[] = [];
  private mixer: { s: Slider; read: (r: Recipe) => number }[] = [];
  private shaderList = h('div', { class: 'rows' });
  private picker = h('select', { class: 'select', 'aria-label': 'Add a shader' });
  private hint = h('p', { class: 'hint' });
  private thumbsFor = '';
  private open = new Set<string>();
  // The rows are rebuilt only when the list's shape changes, never mid-drag.
  private shape = '';
  private shaderSliders: { s: Slider; read: (r: Recipe) => number }[] = [];

  private library: Library;
  private viewer: Viewer;

  constructor(library: Library, viewer: Viewer) {
    this.library = library;
    this.viewer = viewer;
    this.strength = slider({
      label: 'Strength', min: 0, max: 100, value: 100, reset: 100, format: pct,
      onchange: (v, g) => store.edit({ look: { strength: v } }, g),
    });
    const effect = (label: string, read: (r: Recipe) => number, patch: (v: number) => unknown, reset = 0) => {
      const s = slider({ label, min: 0, max: 100, value: reset, reset, format: plain, onchange: (v, g) => store.edit(patch(v), g) });
      this.effects.push({ s, read });
      return s.el;
    };
    // One band at a time: pick a colour, then its hue, saturation and lightness.
    let band: typeof bands[number] = 'reds';
    const bandChips = chips(bands.map((b) => ({ value: b, label: b[0].toUpperCase() + b.slice(1) })), band, (b) => {
      band = b;
      bandChips.set(b);
      for (const m of this.mixer) m.s.set(m.read(store.recipe));
    });
    const mixerRows = (['hue', 'sat', 'light'] as const).map((what) => {
      const s = slider({
        label: { hue: 'Hue', sat: 'Saturation', light: 'Lightness' }[what], min: -100, max: 100, value: 0,
        onchange: (v, g) => store.edit({ colour: { [band]: { [what]: v } } }, g),
      });
      this.mixer.push({ s, read: (r) => r.colour[band][what] });
      return s.el;
    });
    this.picker.addEventListener('change', () => {
      const name = this.picker.value;
      this.picker.value = '';
      if (!name) return;
      const def = this.library.shaders.find((s) => s.name === name);
      const params: Record<string, number> = {};
      for (const p of def?.params ?? []) params[p.name] = p.default;
      this.setShaders([...store.recipe.shaders, { name, strength: 100, enabled: true, params }]);
    });

    this.el = h('div', { class: 'panel__body' },
      section('Look', this.grid, this.strength.el, this.hint),
      section('Film',
        effect('Grain', (r) => r.grain.amount, (v) => ({ grain: { amount: v } })),
        effect('Grain size', (r) => r.grain.size, (v) => ({ grain: { size: v } }), 50),
        effect('Halation', (r) => r.halation, (v) => ({ halation: v })),
        effect('Vignette', (r) => r.vignette, (v) => ({ vignette: v }))),
      fold('Colour', false, bandChips.el, ...mixerRows,
        h('button', { type: 'button', class: 'btn btn--small btn--outline', style: { alignSelf: 'flex-start' }, onclick: () => store.edit({ colour: null }) }, 'Reset colours')),
      section('Shaders', this.shaderList, this.picker));
    library.subscribe(() => { this.thumbsFor = ''; this.update(); });
    viewer.onDraw(() => this.maybeThumbs());
  }

  update() {
    const r = store.recipe;
    this.strength.set(r.look.strength);
    this.strength.el.classList.toggle('hidden', r.look.name === 'none');
    for (const e of this.effects) e.s.set(e.read(r));
    for (const m of this.mixer) m.s.set(m.read(r));
    this.renderGrid(r);
    this.renderShaders(r);
  }

  private renderGrid(r: Recipe) {
    const names = ['none', ...this.library.looks.map((l) => l.name)];
    if (this.grid.childElementCount !== names.length || this.grid.dataset.names !== names.join('\n')) {
      this.grid.dataset.names = names.join('\n');
      clear(this.grid, ...names.map((name) => {
        const title = name === 'none' ? 'None' : this.library.looks.find((l) => l.name === name)?.title ?? name;
        const b = h('button', { type: 'button', class: 'look', title, onclick: () => store.edit({ look: { name, strength: store.recipe.look.name === 'none' ? 100 : store.recipe.look.strength } }) },
          h('canvas', { width: thumbWidth, height: Math.round(thumbWidth * 2 / 3) }), h('span', {}, title));
        b.dataset.look = name;
        return b;
      }));
      this.thumbsFor = '';
    }
    for (const b of this.grid.children) (b as HTMLElement).setAttribute('aria-pressed', String((b as HTMLElement).dataset.look === r.look.name));
    this.hint.textContent = this.library.looks.length === 0 ? 'No looks yet: put .cube files in the looks folder.' : '';
  }

  // The look previews are drawn once per photo (and look list), after the photo is on the GPU.
  private maybeThumbs() {
    if (store.tab !== 'looks' || !store.photo || this.viewer.loaded !== store.photo.rel) return;
    const key = `${store.photo.rel}\n${this.grid.dataset.names}\n${JSON.stringify(store.recipe.crop)}`;
    if (key === this.thumbsFor) return;
    this.thumbsFor = key;
    this.drawThumbs().catch(report);
  }

  private async drawThumbs() {
    const p = this.viewer.pipeline;
    const gl = p.gl;
    const base = store.recipe;
    const [ow, oh] = p.outputSize(base);
    const w = thumbWidth;
    const hgt = Math.max(1, Math.round((w * oh) / ow));
    const t = target(gl, w, hgt, gl.RGBA8, gl.UNSIGNED_BYTE);
    const px = new Uint8ClampedArray(w * hgt * 4);
    try {
      for (const b of Array.from(this.grid.children) as HTMLElement[]) {
        const name = b.dataset.look!;
        // The photo with this look, nothing else changed but the crop.
        const r: Recipe = { ...base, look: { name, strength: 100 }, shaders: [], grain: { ...base.grain, amount: 0 } };
        p.setLook(name === 'none' ? null : await this.library.cube(name));
        p.render(r, { target: t, width: w, height: hgt });
        gl.bindFramebuffer(gl.FRAMEBUFFER, t.fbo);
        gl.readPixels(0, 0, w, hgt, gl.RGBA, gl.UNSIGNED_BYTE, px);
        const canvas = b.querySelector('canvas')!;
        canvas.width = w;
        canvas.height = hgt;
        canvas.getContext('2d')!.putImageData(new ImageData(px, w, hgt), 0, 0);
      }
    } finally {
      free(gl, t);
      // The preview's own look goes back.
      this.library.forget(p);
      await this.library.prepare(p, store.recipe);
      this.viewer.schedule();
    }
  }

  private setShaders(list: ShaderUse[], gesture = 0) {
    store.edit({ shaders: list }, gesture);
  }

  private renderShaders(r: Recipe) {
    const shape = JSON.stringify([r.shaders.map((u) => [u.name, u.enabled]), [...this.open], this.library.shaders.map((s) => [s.name, s.version, s.error ?? ''])]);
    if (shape === this.shape) {
      for (const x of this.shaderSliders) x.s.set(x.read(r));
      return;
    }
    this.shape = shape;
    this.shaderSliders = [];
    const rows: HTMLElement[] = [];
    r.shaders.forEach((use, i) => {
      const def = this.library.shaders.find((s) => s.name === use.name);
      const move = (by: number) => {
        const list = [...r.shaders];
        const [x] = list.splice(i, 1);
        list.splice(i + by, 0, x);
        this.setShaders(list);
      };
      // Always from the latest recipe: a drag sends many changes before this row is redrawn.
      const change = (patch: (u: ShaderUse) => Partial<ShaderUse>, gesture = 0) =>
        this.setShaders(store.recipe.shaders.map((u, j) => (j === i ? { ...u, ...patch(u) } : u)), gesture);
      const name = h('button', { type: 'button', class: `row__name btn--plain${use.enabled ? '' : ' row__name--off'}`, style: { background: 'none', border: 0, textAlign: 'left', padding: 0 }, title: def?.description || use.name, onclick: () => {
        if (this.open.has(use.name)) this.open.delete(use.name); else this.open.add(use.name);
        this.renderShaders(store.recipe);
      } }, use.name, def ? '' : ' (missing)');
      rows.push(h('div', { class: 'row' },
        name,
        iconButton(use.enabled ? 'eye' : 'eyeOff', use.enabled ? 'Turn off' : 'Turn on', () => change((u) => ({ enabled: !u.enabled }))),
        i > 0 ? iconButton('up', 'Earlier', () => move(-1)) : null,
        i < r.shaders.length - 1 ? iconButton('down', 'Later', () => move(1)) : null,
        iconButton('trash', 'Remove from this photo', () => this.setShaders(r.shaders.filter((_, j) => j !== i)))));
      if (def?.error) rows.push(h('p', { class: 'warn mono', style: { whiteSpace: 'pre-wrap', fontSize: '11px' } }, `Doesn't compile; the last working version is used.\n${def.error}`));
      if (this.open.has(use.name)) {
        const strength = slider({ label: 'Strength', min: 0, max: 100, value: use.strength, reset: 100, format: pct, onchange: (v, g) => change(() => ({ strength: v }), g) });
        this.shaderSliders.push({ s: strength, read: (rr) => rr.shaders[i]?.strength ?? 100 });
        const params = (def?.params ?? []).map((p) => {
          const step = (p.max - p.min) / 100;
          const s = slider({
            label: p.label || p.name, min: p.min, max: p.max, step, value: use.params[p.name] ?? p.default, reset: p.default,
            format: (v) => v.toFixed(2),
            onchange: (v, g) => change((u) => ({ params: { ...u.params, [p.name]: v } }), g),
          });
          this.shaderSliders.push({ s, read: (rr) => rr.shaders[i]?.params[p.name] ?? p.default });
          return s.el;
        });
        rows.push(h('div', { class: 'row-detail' }, def?.description ? h('p', { class: 'hint' }, def.description) : null, strength.el, ...params));
      }
    });
    if (r.shaders.length === 0) rows.push(h('p', { class: 'hint' }, 'No shaders on this photo.'));
    clear(this.shaderList, ...rows);
    const available = this.library.shaders.filter((s) => !r.shaders.some((u) => u.name === s.name));
    clear(this.picker,
      h('option', { value: '' }, available.length ? 'Add a shader…' : this.library.shaders.length ? 'All shaders are on' : 'No shaders yet (ask Claude for one)'),
      ...available.map((s) => h('option', { value: s.name }, s.name)));
    this.picker.disabled = available.length === 0;
  }
}

