// The Adjust tab: light, colour and detail sliders.

import { h, section, slider, signed, type Slider } from './dom.js';
import { store, type Recipe } from './state.js';

interface Def {
  path: [keyof Recipe, string];
  label: string;
  min: number;
  max: number;
  step?: number;
  format?: (v: number) => string;
}

const ev = (v: number) => `${signed(Math.round(v * 100) / 100)} EV`;

const sections: { title: string; sliders: Def[] }[] = [
  { title: 'Light', sliders: [
    { path: ['edits', 'exposure'], label: 'Exposure', min: -5, max: 5, step: 0.05, format: ev },
    { path: ['edits', 'contrast'], label: 'Contrast', min: -100, max: 100 },
    { path: ['edits', 'highlights'], label: 'Highlights', min: -100, max: 100 },
    { path: ['edits', 'shadows'], label: 'Shadows', min: -100, max: 100 },
  ] },
  { title: 'Colour', sliders: [
    { path: ['edits', 'temperature'], label: 'Temperature', min: -100, max: 100 },
    { path: ['edits', 'tint'], label: 'Tint', min: -100, max: 100 },
    { path: ['edits', 'saturation'], label: 'Saturation', min: -100, max: 100 },
  ] },
  { title: 'Detail', sliders: [
    { path: ['detail', 'sharpen'], label: 'Sharpen', min: 0, max: 100, format: String },
    { path: ['detail', 'noise'], label: 'Noise reduction', min: 0, max: 100, format: String },
  ] },
];

function read(r: Recipe, [group, key]: Def['path']): number {
  return (r[group] as unknown as Record<string, number>)[key];
}

export class AdjustPanel {
  readonly el: HTMLElement;
  private sliders: { def: Def; s: Slider }[] = [];

  constructor() {
    const parts = sections.map((sec) => section(sec.title, ...sec.sliders.map((def) => {
      const s = slider({
        label: def.label, min: def.min, max: def.max, step: def.step, value: 0, format: def.format,
        onchange: (v, gesture) => store.edit({ [def.path[0]]: { [def.path[1]]: v } }, gesture),
      });
      this.sliders.push({ def, s });
      return s.el;
    })));
    const reset = h('button', { type: 'button', class: 'btn btn--small btn--outline', style: { alignSelf: 'flex-start' }, onclick: () => this.reset() }, 'Reset sliders');
    this.el = h('div', { class: 'panel__body' }, ...parts, reset);
  }

  update() {
    const r = store.recipe;
    for (const { def, s } of this.sliders) s.set(read(r, def.path));
  }

  private reset() {
    const patch: Record<string, Record<string, null>> = {};
    for (const { def } of this.sliders) (patch[def.path[0]] ??= {})[def.path[1]] = null;
    store.edit(patch);
  }
}
