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
  // What the buttons show now: only what changed is touched (a slider updates the store per pixel).
  private current = -1;
  private edited: boolean[] = [];
  private selected = new Set<string>();

  constructor(onOpenFolder: () => void, onPick: (rel: string) => void) {
    this.el = h('nav', { class: 'sidebar', 'aria-label': 'Photos in folder' },
      h('button', { type: 'button', class: 'btn btn--small', onclick: onOpenFolder, title: 'Open folder (Ctrl+O)' }, icon('folder'), 'Open folder'),
      h('div', { class: 'sidebar__head' }, this.name, this.count),
      this.list,
    );
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
    this.current = -1;
    this.edited = f.photos.map(() => false);
    this.selected = new Set();
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
      const b = h('button', { type: 'button', class: 'thumb', 'aria-label': p.rel, title: `${p.rel}\nCtrl or Shift-click to pick several for export` },
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
    if (current !== this.current) {
      this.buttons[this.current]?.setAttribute('aria-current', 'false');
      const b = this.buttons[current];
      if (b) {
        b.setAttribute('aria-current', 'true');
        b.scrollIntoView({ block: 'nearest' });
      }
      this.current = current;
    }
    // Edited dots: the open photo is the one that changes, but a new folder state may change any.
    f.photos.forEach((p, i) => {
      if (p.edited === this.edited[i]) return;
      this.edited[i] = p.edited;
      const b = this.buttons[i];
      if (p.edited) b.append(h('span', { class: 'thumb__dot', 'aria-hidden': 'true' }));
      else b.querySelector('.thumb__dot')?.remove();
    });
    const sel = store.selected.size > 1 ? store.selected : new Set<string>();
    if (sel.size !== this.selected.size || [...sel].some((r) => !this.selected.has(r))) {
      this.buttons.forEach((b, i) => b.classList.toggle('thumb--selected', sel.has(f.photos[i].rel)));
      this.selected = new Set(sel);
    }
  }
}
