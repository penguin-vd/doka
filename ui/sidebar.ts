// The folder on the left: Open folder, then every photo's thumbnail, grouped by subfolder.
// A dot marks an edited photo.

import { h, clear, icon } from './dom.js';
import { store } from './state.js';
import { photoUrl } from './viewer.js';

export class Sidebar {
  readonly el: HTMLElement;
  private name = h('span', { class: 'sidebar__name' });
  private count = h('span', { class: 'sidebar__count' });
  private list = h('div', { class: 'sidebar__list' });
  private buttons: HTMLButtonElement[] = [];
  private shownFolder: string | null = null;

  constructor(onOpenFolder: () => void, onPick: (rel: string) => void) {
    this.el = h('nav', { class: 'sidebar', 'aria-label': 'Photos in folder' },
      h('button', { type: 'button', class: 'btn btn--small', onclick: onOpenFolder, title: 'Open folder (Ctrl+O)' }, icon('folder'), 'Open folder'),
      h('div', { class: 'sidebar__head' }, this.name, this.count),
      this.list,
      h('p', { class: 'sidebar__note' }, 'Dot = edited. Originals are never changed. Ctrl or Shift-click to pick several for export.'));
    this.list.addEventListener('click', (e) => {
      const b = (e.target as Element).closest('button.thumb') as HTMLButtonElement | null;
      if (!b || !b.dataset.rel) return;
      const rel = b.dataset.rel;
      if (e.ctrlKey || e.metaKey) {
        if (store.selected.size === 0 && store.photo) store.selected.add(store.photo.rel);
        if (store.selected.has(rel)) store.selected.delete(rel); else store.selected.add(rel);
        store.notify();
      } else if (e.shiftKey && store.photo && store.folder) {
        const rels = store.folder.photos.map((p) => p.rel);
        const [a, z] = [rels.indexOf(store.photo.rel), rels.indexOf(rel)].sort((x, y) => x - y);
        store.selected = new Set(rels.slice(a, z + 1));
        store.notify();
      } else {
        store.selected.clear();
        onPick(rel);
      }
    });
    store.subscribe(() => this.update());
  }

  private rebuild() {
    const f = store.folder;
    this.buttons = [];
    if (!f) {
      this.name.textContent = 'No folder';
      this.count.textContent = '';
      clear(this.list);
      return;
    }
    this.name.textContent = f.name;
    this.name.title = f.path;
    this.count.textContent = `${f.photos.length} photos`;
    const groups = new Map<string, HTMLElement>();
    const frag = document.createDocumentFragment();
    for (const p of f.photos) {
      const slash = p.rel.lastIndexOf('/');
      const dir = slash < 0 ? '' : p.rel.slice(0, slash);
      let grid = groups.get(dir);
      if (!grid) {
        grid = h('div', { class: 'thumbs' });
        groups.set(dir, grid);
        if (dir) frag.append(h('h3', { class: 'group-title' }, dir));
        frag.append(grid);
      }
      const b = h('button', { type: 'button', class: 'thumb', 'aria-label': p.rel, title: p.rel },
        h('img', { src: photoUrl('thumb', p.rel), loading: 'lazy', decoding: 'async', alt: '' }));
      b.dataset.rel = p.rel;
      grid.append(b);
      this.buttons.push(b);
    }
    clear(this.list, frag);
  }

  private update() {
    const f = store.folder;
    if ((f?.path ?? null) !== this.shownFolder) {
      this.shownFolder = f?.path ?? null;
      this.rebuild();
    }
    if (!f) return;
    const current = store.photo?.index ?? -1;
    this.buttons.forEach((b, i) => {
      const on = i === current;
      if ((b.getAttribute('aria-current') === 'true') !== on) {
        b.setAttribute('aria-current', String(on));
        if (on) b.scrollIntoView({ block: 'nearest' });
      }
      b.classList.toggle('thumb--selected', store.selected.size > 1 && store.selected.has(f.photos[i].rel));
      const edited = f.photos[i].edited;
      const dot = b.querySelector('.thumb__dot');
      if (edited && !dot) b.append(h('span', { class: 'thumb__dot', 'aria-hidden': 'true' }));
      if (!edited && dot) dot.remove();
    });
  }
}
