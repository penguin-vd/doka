// The export dialog (design/export.dc.html): format, quality, size, colour space, metadata and
// GPS, the folder. Exports the selected photos, or the open one. What you choose is remembered.

import { h, clear, icon, iconButton, chips, slider } from './dom.js';
import { call, on, report } from './rpc.js';
import { store } from './state.js';

interface ExportSettings {
  format: 'jpeg' | 'png';
  quality: number;
  long_edge: number;
  keep_metadata: boolean;
  keep_gps: boolean;
  space: 'srgb' | 'p3';
  folder: string;
  suffix: string;
}

interface Settings { export: ExportSettings; defaultFolder: string; }
interface Result { rel: string; path: string; error: string; ms: number; }

const sizes = [0, 3000, 2048, 1080];

export class ExportDialog {
  private scrim: HTMLElement | null = null;
  private progress: { bar: HTMLElement; text: HTMLElement } | null = null;
  private running = false;

  constructor() {
    on('export', (job: { index: number; total: number; rel: string }) => this.step(job.index, job.total, job.rel, 0));
    on('exportProgress', (p: { index: number; total: number; rel: string; done: number }) => this.step(p.index, p.total, p.rel, p.done));
    on('exportDone', (d: { folder: string; results: Result[]; ms: number }) => this.finished(d));
  }

  /** The selected photos, or the open one. */
  private photos(): string[] {
    if (store.selected.size > 1) return store.folder!.photos.map((p) => p.rel).filter((r) => store.selected.has(r));
    return store.photo ? [store.photo.rel] : [];
  }

  async open() {
    if (this.scrim || !store.photo) return;
    const settings = await call<Settings>('settings');
    const o = { ...settings.export };
    const rels = this.photos();
    const close = () => { if (!this.running) { this.scrim?.remove(); this.scrim = null; } };

    const name = h('input', { class: 'input', type: 'text', readOnly: true });
    const suffix = h('input', { class: 'input', type: 'text', value: o.suffix, 'aria-label': 'Added to the name' });
    const folder = h('input', { class: 'input', type: 'text', value: o.folder || settings.defaultFolder, 'aria-label': 'Export folder' });
    const quality = slider({ label: 'Quality', min: 50, max: 100, value: o.quality, reset: 90, format: String, onchange: (v) => { o.quality = v; } });
    const format = chips([{ value: 'jpeg', label: 'JPEG' }, { value: 'png', label: 'PNG 16-bit' }] as const, o.format, (v) => { o.format = v; refresh(); }, 'segmented');
    const space = chips([{ value: 'srgb', label: 'sRGB' }, { value: 'p3', label: 'Display P3' }] as const, o.space, (v) => { o.space = v; refresh(); }, 'segmented');
    const size = h('select', { class: 'select', id: 'exp-size', onchange: () => { o.long_edge = Number(size.value); refresh(); } },
      ...sizes.map((s) => h('option', { value: String(s), selected: s === o.long_edge }, s === 0 ? 'Original size' : `Long edge ${s} px`)));
    const keep = h('input', { type: 'checkbox', checked: o.keep_metadata, onchange: () => { o.keep_metadata = keep.checked; refresh(); } });
    const gps = h('input', { type: 'checkbox', checked: o.keep_gps, onchange: () => { o.keep_gps = gps.checked; refresh(); } });
    const kept = h('div', { style: { display: 'flex', flexDirection: 'column', gap: '10px', paddingLeft: '28px' } },
      h('ul', { class: 'kept' }, ...['Camera & lens', 'Exposure settings', 'Date taken', 'Colour profile'].map((t) => h('li', {}, icon('check', 14), t))),
      h('label', { class: 'check' }, gps, h('span', {}, 'Include GPS location')),
      h('p', { class: 'hint' }, 'Untick to strip the location before sharing online.'));
    const stripped = h('p', { class: 'warn', style: { paddingLeft: '28px' } }, 'Camera, lens and date will be removed from the exported file.');
    const summary = h('span', { class: 'mono muted' });
    const go = h('button', { type: 'button', class: 'btn btn--accent' }, rels.length > 1 ? `Export ${rels.length} photos` : 'Export');
    const bar = h('div', { style: { width: '0%' } });
    const progressText = h('span', { class: 'hint' });
    const progress = h('div', { class: 'field hidden', style: { padding: '0 20px 16px' } }, h('div', { class: 'progress' }, bar), progressText);
    this.progress = { bar, text: progressText };

    const refresh = () => {
      const stem = rels[0].split('/').pop()!.replace(/\.[^.]*$/, '');
      name.value = `${stem}${suffix.value}${o.format === 'jpeg' ? '.jpg' : '.png'}${rels.length > 1 ? ` (+${rels.length - 1} more)` : ''}`;
      quality.el.classList.toggle('hidden', o.format !== 'jpeg');
      kept.classList.toggle('hidden', !o.keep_metadata);
      stripped.classList.toggle('hidden', o.keep_metadata);
      // The open photo's size after its crop and turns, then the long edge.
      const info = store.photo!.info;
      const c = store.recipe.crop;
      const turned = (c.rotate / 90) % 2 === 1;
      const w = (turned ? info.height : info.width) * c.rect[2];
      const hh = (turned ? info.width : info.height) * c.rect[3];
      const scale = o.long_edge ? Math.min(1, o.long_edge / Math.max(w, hh)) : 1;
      summary.textContent = `${Math.round(w * scale)} × ${Math.round(hh * scale)} · ${o.format === 'jpeg' ? `JPEG ${o.quality}` : 'PNG 16-bit'} · ${o.space === 'p3' ? 'P3' : 'sRGB'}`;
    };
    suffix.addEventListener('input', refresh);
    quality.el.addEventListener('input', refresh);

    go.addEventListener('click', async () => {
      o.suffix = suffix.value;
      o.folder = folder.value.trim() === settings.defaultFolder ? '' : folder.value.trim();
      this.running = true;
      go.disabled = true;
      progress.classList.remove('hidden');
      try {
        await call('export', { rels, options: o, remember: true });
      } catch (e) {
        this.running = false;
        go.disabled = false;
        progressText.textContent = `Export failed: ${e}`;
        report(e);
      }
    });

    const dialog = h('div', { class: 'dialog', role: 'dialog', 'aria-labelledby': 'export-title' },
      h('div', { class: 'dialog__head' }, h('h1', { class: 'dialog__title', id: 'export-title' }, rels.length > 1 ? `Export ${rels.length} photos` : 'Export photo'), iconButton('close', 'Close', close)),
      h('div', { class: 'dialog__body' },
        h('div', { class: 'field' }, h('span', { class: 'field__label' }, 'File name'), name),
        h('div', { class: 'field' }, h('span', { class: 'field__label' }, 'Format'), format.el),
        quality.el,
        h('div', { class: 'field' }, h('label', { for: 'exp-size' }, 'Size'), size),
        h('div', { class: 'field' }, h('span', { class: 'field__label' }, 'Colour space'), space.el),
        h('fieldset', { class: 'fieldset' }, h('legend', {}, 'Metadata'),
          h('label', { class: 'check' }, keep, h('span', { style: { fontWeight: '500' } }, 'Keep metadata')), kept, stripped),
        h('div', { class: 'field' }, h('span', { class: 'field__label' }, 'Folder and name ending'),
          h('div', { style: { display: 'flex', gap: '8px' } }, h('div', { style: { flex: '3', display: 'grid' } }, folder), h('div', { style: { flex: '1', display: 'grid' } }, suffix)))),
      progress,
      h('div', { class: 'dialog__foot' }, summary,
        h('div', { style: { display: 'flex', gap: '8px' } }, h('button', { type: 'button', class: 'btn btn--outline', onclick: close }, 'Cancel'), go)));
    this.scrim = h('div', { class: 'scrim', onclick: (e: Event) => { if (e.target === this.scrim) close(); } }, dialog);
    this.scrim.addEventListener('keydown', (e) => { if ((e as KeyboardEvent).key === 'Escape') close(); });
    document.body.append(this.scrim);
    refresh();
    go.focus();
  }

  private step(index: number, total: number, rel: string, done: number) {
    if (!this.progress) return;
    const share = (index + done) / total;
    this.progress.bar.style.width = `${Math.round(share * 100)}%`;
    this.progress.text.textContent = `Exporting ${rel.split('/').pop()} (${index + 1} of ${total})…`;
  }

  private finished(d: { folder: string; results: Result[]; ms: number }) {
    this.running = false;
    const failed = d.results.filter((r) => r.error);
    if (!this.scrim || !this.progress) return;
    this.progress.bar.style.width = '100%';
    this.progress.text.textContent = failed.length
      ? `${failed.length} failed: ${failed.map((r) => `${r.rel} (${r.error})`).join(', ')}`
      : `Saved ${d.results.length === 1 ? d.results[0].path : `${d.results.length} photos to ${d.folder}`} in ${(d.ms / 1000).toFixed(1)} s.`;
    const foot = this.scrim.querySelector('.dialog__foot > div')!;
    clear(foot, h('button', { type: 'button', class: 'btn btn--accent', onclick: () => { this.scrim?.remove(); this.scrim = null; } }, 'Done'));
  }
}
