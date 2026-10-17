// The bar along the top: where you are, previous / next, undo / redo, before / after, Export.

import { h, icon, iconButton } from './dom.js';
import { store } from './state.js';

export interface HeaderActions {
  prev(): void;
  next(): void;
  undo(): void;
  redo(): void;
  toggleBefore(): void;
  exportPhoto(): void;
}

export class Header {
  readonly el: HTMLElement;
  private folder = h('span', { class: 'crumbs__folder' });
  private photo = h('span', { class: 'crumbs__photo' });
  private position = h('span', { class: 'position mono' });
  private undoBtn: HTMLButtonElement;
  private redoBtn: HTMLButtonElement;
  private beforeBtn: HTMLButtonElement;
  private exportBtn: HTMLButtonElement;
  private claude = h('span', { class: 'pill hidden' }, h('span', { class: 'pill__dot', 'aria-hidden': 'true' }), 'Claude Code connected');

  constructor(a: HeaderActions) {
    this.undoBtn = iconButton('undo', 'Undo (Ctrl+Z)', a.undo);
    this.redoBtn = iconButton('redo', 'Redo (Ctrl+Shift+Z)', a.redo);
    this.beforeBtn = h('button', { type: 'button', class: 'btn btn--outline', onclick: a.toggleBefore, title: 'Hold \\ to see the original' }, icon('compare'), 'Before / after');
    this.exportBtn = h('button', { type: 'button', class: 'btn btn--accent', onclick: a.exportPhoto }, icon('export'), 'Export');
    this.el = h('header', { class: 'bar' },
      h('div', { class: 'crumbs' },
        h('span', { class: 'crumbs__app' }, 'Doka'),
        h('span', { class: 'crumbs__sep', 'aria-hidden': 'true' }, '/'), this.folder,
        h('span', { class: 'crumbs__sep', 'aria-hidden': 'true' }, '/'), this.photo),
      this.claude,
      h('div', { class: 'bar__group' },
        iconButton('prev', 'Previous photo (←)', a.prev), this.position, iconButton('next', 'Next photo (→)', a.next),
        h('span', { class: 'bar__rule', 'aria-hidden': 'true' }),
        this.undoBtn, this.redoBtn, this.beforeBtn, this.exportBtn));
    store.subscribe(() => this.update());
  }

  setClaudeConnected(on: boolean) { this.claude.classList.toggle('hidden', !on); }

  private update() {
    const f = store.folder;
    const p = store.photo;
    this.folder.textContent = f ? f.name : 'No folder open';
    this.photo.textContent = p ? p.rel.split('/').pop()! : '';
    this.position.textContent = f && p ? `${p.index + 1} / ${f.photos.length}` : '';
    this.undoBtn.disabled = !p?.canUndo;
    this.redoBtn.disabled = !p?.canRedo;
    this.beforeBtn.disabled = !p;
    this.exportBtn.disabled = !p;
    this.beforeBtn.setAttribute('aria-pressed', String(store.before));
    this.beforeBtn.lastChild!.textContent = store.before ? 'Showing original' : 'Before / after';
  }
}
