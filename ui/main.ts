// The page: lays out the editor, loads what the app says is open, and keeps it in step.

import { h, clear, icon } from './dom.js';
import { call, on, report } from './rpc.js';
import { store, type AppState, type Photo, type Tab } from './state.js';
import { loadSources } from './gl/gl.js';
import { pipelineSources } from './gl/pipeline.js';
import { checkGpu, gpuOk } from './gpu.js';
import { selfTest } from './selftest.js';
import { Viewer } from './viewer.js';
import { Sidebar } from './sidebar.js';
import { Header } from './header.js';
import { AdjustPanel } from './adjust.js';
import { ClaudeBar, listenToClaude } from './claude.js';
import { Library } from './library.js';
import { LooksPanel } from './looks.js';
import { CropPanel } from './crop.js';
import { ExportDialog } from './exportdialog.js';
import { renderExport, type ExportJob } from './exporter.js';
import { writeCube } from './gl/cube.js';

// The preview's long edge: about the screen's, so the stage never shows upscaled pixels.
const previewEdge = Math.min(4096, Math.max(1600, Math.round(Math.max(screen.width, screen.height) * (window.devicePixelRatio || 1))));

async function boot() {
  const gpu = checkGpu();
  await loadSources(pipelineSources);
  const { probe } = await call<{ probe: boolean }>('gpu', gpu);
  if (probe) {
    await call('selftest', gpuOk(gpu) ? selfTest() : []);
    return;
  }

  const stage = h('div', { class: 'stage__view' });
  const empty = h('div', { class: 'stage__empty' },
    h('p', {}, 'Open a folder to start.'),
    h('button', { type: 'button', class: 'btn', onclick: () => openFolder() }, icon('folder'), 'Open folder'));
  const badge = h('span', { class: 'stage__badge hidden' }, 'Original');
  stage.append(empty, badge);
  if (!gpuOk(gpu)) {
    clear(empty, h('p', {}, `This needs WebGL2 with float render targets: ${gpu.error || 'missing'}.`));
  }
  const viewer = new Viewer(stage);
  const library = new Library();
  await library.refresh();
  const exportDialog = new ExportDialog();

  const exif = h('span', { class: 'footer__exif mono' });
  const footer = h('div', { class: 'footer' },
    h('span', { class: 'badge-ok' }, icon('check', 14), 'Metadata kept'),
    exif,
    h('span', { class: 'muted', style: { fontSize: '12px' } }, '← → to switch photos'));

  const sidebar = new Sidebar(() => openFolder(), (rel) => openPhoto(rel));
  const header = new Header({
    prev: () => step(-1),
    next: () => step(1),
    undo: () => store.step('undo').catch(report),
    redo: () => store.step('redo').catch(report),
    toggleBefore: () => { store.before = !store.before; store.notify(); },
    exportPhoto: () => exportDialog.open().catch(report),
  });

  const adjust = new AdjustPanel();
  const panels: Record<Tab, { el: HTMLElement; update(): void }> = {
    adjust,
    looks: new LooksPanel(library, viewer),
    crop: new CropPanel(viewer),
  };
  const tabNames: [Tab, string][] = [['adjust', 'Adjust'], ['looks', 'Looks'], ['crop', 'Crop']];
  const tabs = tabNames.map(([t, label]) => h('button', { type: 'button', class: 'tab', role: 'tab', onclick: () => { store.tab = t; store.notify(); } }, label));
  const body = h('div', { style: { display: 'contents' } });
  const recipeText = h('pre', {});
  const panel = h('aside', { class: 'panel' },
    h('div', { class: 'tabs', role: 'tablist', 'aria-label': 'Tools' }, ...tabs),
    body,
    h('details', { class: 'recipe' }, h('summary', {}, 'Edit recipe (what Claude Code sees)'), recipeText));

  const claudeBar = new ClaudeBar();
  document.body.append(header.el, h('div', { class: 'layout' }, sidebar.el, h('main', { class: 'stage' }, claudeBar.el, stage, footer), panel));
  listenToClaude(viewer, header, library, previewEdge);
  library.subscribe(() => { if (store.photo) library.prepare(viewer.pipeline, store.recipe).then(() => viewer.schedule()).catch(report); });

  // The app asks; the page answers (src/app/app.zig, ask).
  on('compileShader', async ({ id, name, source, def }: { id: number; name: string; source: string; def: { description: string; params: never[]; needs: string[] } }) => {
    const error = library.check(viewer.pipeline, { name, description: def.description ?? '', params: def.params ?? [], needs: def.needs ?? [] }, source);
    await call('answer', { id, error });
  });
  on('bakeLook', async ({ id, size, title }: { id: number; size: number; title: string }) => {
    let cube = '';
    try {
      await library.prepare(viewer.pipeline, store.recipe);
      cube = writeCube(title, size, viewer.pipeline.bakeLattice(store.recipe, size));
    } catch (e) { report(e); }
    await call('answer', { id, cube });
  });
  on('export', (job: ExportJob) => {
    renderExport(job, library, (done) => window.doka.event('exportProgress', { index: job.index, total: job.total, rel: job.rel, done })).catch(report);
  });

  let shownTab: Tab | null = null;
  store.subscribe(() => {
    const p = store.photo;
    empty.classList.toggle('hidden', !!p);
    badge.classList.toggle('hidden', !store.before);
    if (store.tab !== shownTab) {
      shownTab = store.tab;
      clear(body, panels[store.tab].el);
      tabs.forEach((t, i) => t.setAttribute('aria-selected', String(tabNames[i][0] === store.tab)));
      call('tab', { tab: store.tab }).catch(report);
    }
    panels[store.tab].update();
    if (p) {
      const i = p.info;
      exif.textContent = [i.make && i.model ? `${i.model}` : '', i.lens, i.exposure && `${i.exposure} s`, i.aperture && `f/${i.aperture.replace(/^f\//, '')}`, i.iso && `ISO ${i.iso}`].filter(Boolean).join(' · ');
      recipeText.textContent = JSON.stringify(withoutDefaults(p.recipe), null, 2);
      viewer.load(p.rel, previewEdge).catch(report);
      library.prepare(viewer.pipeline, p.recipe).then((changed) => { if (changed) viewer.schedule(); }).catch(report);
    } else {
      exif.textContent = '';
      viewer.unload();
    }
    viewer.schedule();
  });

  on('photo', (p: Photo | null) => store.setPhoto(p));
  on('state', (s: AppState) => applyState(s));

  document.addEventListener('keydown', (e) => {
    const typing = (e.target as Element).closest('input[type=text], textarea, select');
    if (typing) return;
    if (e.key === 'ArrowLeft' && !(e.target as Element).closest('input')) { e.preventDefault(); step(-1); }
    else if (e.key === 'ArrowRight' && !(e.target as Element).closest('input')) { e.preventDefault(); step(1); }
    else if (e.key === '\\' && !e.repeat) { store.before = true; store.notify(); }
    else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'e') { e.preventDefault(); exportDialog.open().catch(report); }
    else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'z') {
      e.preventDefault();
      store.step(e.shiftKey ? 'redo' : 'undo').catch(report);
    }
  });
  document.addEventListener('keyup', (e) => {
    if (e.key === '\\') { store.before = false; store.notify(); }
  });

  // For `doka --shot out.png --eval '…'`: drive the page without a window on the screen.
  (window as unknown as { test: unknown }).test = {
    store, viewer, openPhoto, step,
    edit: (patch: unknown) => store.edit(patch),
    tab: (t: Tab) => { store.tab = t; store.notify(); },
    library, exportDialog,
    before: (on: boolean) => { store.before = on; store.notify(); },
    wait: (ms: number) => new Promise((r) => setTimeout(r, ms)),
  };

  const state = await call<AppState>('state', { edge: previewEdge });
  if (state.shotTab === 'adjust' || state.shotTab === 'looks' || state.shotTab === 'crop') store.tab = state.shotTab;
  applyState(state);

  // Tell the app the first frame is up (`--shot` waits for it).
  if (store.photo) {
    let told = false;
    viewer.onDraw(() => { if (!told) { told = true; call('ready'); } });
  } else {
    requestAnimationFrame(() => call('ready'));
  }
}

function applyState(s: AppState) {
  store.folder = s.folder;
  store.setPhoto(s.photo);
}

async function openFolder() {
  const s = await call<AppState | null>('openFolder');
  if (s) applyState(s);
}

async function openPhoto(rel: string) {
  if (store.photo?.rel === rel) return;
  store.before = false;
  store.setPhoto(await call<Photo>('open', { rel }));
}

function step(by: number) {
  const f = store.folder;
  if (!f || f.photos.length === 0) return;
  const i = store.photo ? store.photo.index : -1;
  const next = Math.min(f.photos.length - 1, Math.max(0, i + by));
  if (next !== i) openPhoto(f.photos[next].rel).catch(report);
}

/** The recipe as the file keeps it: only what changed. */
function withoutDefaults(r: object): object {
  const { updatedBy, updatedAt, version, ...rest } = r as Record<string, unknown>;
  const strip = (v: unknown, d: unknown): unknown => {
    if (v && typeof v === 'object' && !Array.isArray(v) && d && typeof d === 'object') {
      const out: Record<string, unknown> = {};
      for (const [k, x] of Object.entries(v)) {
        const s = strip(x, (d as Record<string, unknown>)[k]);
        if (s !== undefined) out[k] = s;
      }
      return Object.keys(out).length ? out : undefined;
    }
    if (Array.isArray(v)) return v.length ? v : undefined;
    return JSON.stringify(v) === JSON.stringify(d) ? undefined : v;
  };
  return { version, ...(strip(rest, defaultsFlat()) as object ?? {}), updatedBy, updatedAt };
}

function defaultsFlat() {
  const { updatedBy, updatedAt, version, ...rest } = store.photo ? (JSON.parse(JSON.stringify(emptyRecipe)) as Record<string, unknown>) : {};
  void updatedBy; void updatedAt; void version;
  return rest;
}

import { defaults } from './state.js';
const emptyRecipe = defaults();

boot().catch(report);
