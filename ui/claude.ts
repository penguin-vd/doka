// Claude's side of the page: its change waiting for Keep or Undo, its screenshots, and the
// "connected" pill.

import { h, icon } from './dom.js';
import { call, on, report } from './rpc.js';
import { store } from './state.js';
import { snapshotJpeg } from './snapshot.js';
import type { Viewer } from './viewer.js';
import type { Header } from './header.js';
import type { Library } from './library.js';

// The pill stays this long after Claude's last call: MCP over HTTP has no "disconnected".
const connectedFor = 10 * 60 * 1000;

export class ClaudeBar {
  readonly el: HTMLElement;
  private text = h('span', { class: 'claude-bar__text' });

  constructor() {
    this.el = h('div', { class: 'claude-bar hidden', role: 'status' },
      icon('sparkle'),
      this.text,
      h('button', { type: 'button', class: 'btn btn--outline', onclick: () => store.step('undoClaude').catch(report) }, 'Undo'),
      h('button', { type: 'button', class: 'btn btn--accent', onclick: () => store.step('keep').catch(report) }, 'Keep'));
    store.subscribe(() => this.update());
  }

  private update() {
    const c = store.photo?.claude;
    this.el.classList.toggle('hidden', !c);
    if (c) this.text.textContent = c.note ? `Claude changed this photo: ${c.note}` : 'Claude changed this photo.';
  }
}

export function listenToClaude(viewer: Viewer, header: Header, library: Library, previewEdge: number) {
  let timer = 0;
  on('claude', () => {
    header.setClaudeConnected(true);
    clearTimeout(timer);
    timer = window.setTimeout(() => header.setClaudeConnected(false), connectedFor);
  });
  on('screenshot', async ({ id, edge }: { id: number; edge: number }) => {
    let data = '';
    try {
      const p = store.photo;
      if (p) {
        await viewer.load(p.rel, previewEdge);
        await library.settled();
        await library.prepare(viewer.pipeline, store.recipe);
        data = snapshotJpeg(viewer.pipeline, store.recipe, edge);
      }
    } catch (e) {
      report(e);
    }
    await call('screenshot', { id, data });
  });
}
