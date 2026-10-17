// The page's building blocks: an element helper and the few components every panel uses, so a
// slider or a button looks the same everywhere. Styles are classes in style.css.

type Child = Node | string | null | undefined | false;
type Props = Record<string, unknown>;

/** h('button', { class: 'btn', onclick }, 'Export') */
export function h<K extends keyof HTMLElementTagNameMap>(tag: K, props: Props = {}, ...children: Child[]): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (value === undefined || value === null || value === false) continue;
    if (key.startsWith('on') && typeof value === 'function') el.addEventListener(key.slice(2), value as EventListener);
    else if (key === 'style' && typeof value === 'object') Object.assign(el.style, value);
    else if (key in el && key !== 'list' && key !== 'type') (el as unknown as Record<string, unknown>)[key] = value;
    else el.setAttribute(key, value === true ? '' : String(value));
  }
  append(el, children);
  return el;
}

export function append(el: Element, children: Child[]) {
  for (const c of children) if (c !== null && c !== undefined && c !== false) el.append(c);
}

export function clear(el: Element, ...children: Child[]) {
  el.replaceChildren();
  append(el, children);
}

// Icons: 24×24 strokes, drawn in currentColor.
const paths: Record<string, string> = {
  prev: 'm15 5-7 7 7 7',
  next: 'm9 5 7 7-7 7',
  undo: 'M9 14 4 9l5-5M4 9h11a5 5 0 0 1 0 10h-4',
  redo: 'm15 14 5-5-5-5M20 9H9a5 5 0 0 0 0 10h4',
  compare: 'M12 3v18M5 5h14v14H5z',
  export: 'M12 3v12m-5-5 5 5 5-5M5 21h14',
  folder: 'M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z',
  rotate: 'M3 12a9 9 0 1 0 3-6.7L3 8M3 3v5h5',
  flip: 'M12 3v18M8 7 3 12l5 5M16 7l5 5-5 5',
  check: 'm5 12 5 5 9-10',
  close: 'M6 6l12 12M18 6 6 18',
  up: 'm6 15 6-6 6 6',
  down: 'm6 9 6 6 6-6',
  plus: 'M12 5v14M5 12h14',
  trash: 'M4 7h16M9 7V4h6v3m-8 0 1 13h8l1-13',
  eye: 'M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12zm10 3a3 3 0 1 0 0-6 3 3 0 0 0 0 6z',
  eyeOff: 'M3 3l18 18M10.6 5.1A10 10 0 0 1 12 5c6 0 10 7 10 7a17 17 0 0 1-3 3.6M6.6 6.6C3.8 8.4 2 12 2 12s4 7 10 7a9 9 0 0 0 4.4-1.1',
  sparkle: 'M12 3l2 5 5 2-5 2-2 5-2-5-5-2 5-2z',
};

export function icon(name: keyof typeof paths, size = 18): SVGSVGElement {
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  for (const [k, v] of Object.entries({ width: size, height: size, viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', 'stroke-width': 1.8, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true' })) svg.setAttribute(k, String(v));
  const path = document.createElementNS(ns, 'path');
  path.setAttribute('d', paths[name]);
  svg.append(path);
  return svg;
}

export function iconButton(name: keyof typeof paths, label: string, onclick: () => void): HTMLButtonElement {
  return h('button', { type: 'button', class: 'icon-btn', 'aria-label': label, title: label, onclick }, icon(name));
}

export function section(title: string, ...children: Child[]): HTMLElement {
  return h('section', { class: 'section' }, h('h2', { class: 'section__title' }, title), ...children);
}

/** A collapsed section: <details> with the section's title. */
export function fold(title: string, open: boolean, ...children: Child[]): HTMLDetailsElement {
  return h('details', { class: 'fold', open },
    h('summary', {}, h('h2', { class: 'section__title' }, title)),
    h('div', { class: 'fold__body' }, ...children));
}

let gestureCounter = 0;
/** A new id per drag or click, so the edits of one gesture undo together. */
export function newGesture(): number {
  gestureCounter += 1;
  return Date.now() * 100 + (gestureCounter % 100);
}

export interface SliderOptions {
  label: string;
  min: number;
  max: number;
  step?: number;
  value: number;
  reset?: number;
  format?: (v: number) => string;
  onchange: (value: number, gesture: number) => void;
}

export interface Slider { el: HTMLElement; set(value: number): void; }

/** A labelled range with its value; double-click resets it. */
export function slider(o: SliderOptions): Slider {
  const reset = o.reset ?? 0;
  const format = o.format ?? signed;
  const id = `s${Math.random().toString(36).slice(2)}`;
  const value = h('span', { class: 'slider__value' });
  const input = h('input', { type: 'range', id, min: o.min, max: o.max, step: o.step ?? 1 });
  let gesture = newGesture();
  const show = (v: number) => {
    value.textContent = format(v);
    value.classList.toggle('slider__value--set', v !== reset);
  };
  const set = (v: number) => {
    input.value = String(v);
    show(v);
  };
  input.addEventListener('pointerdown', () => { gesture = newGesture(); });
  input.addEventListener('keydown', () => { gesture = newGesture(); });
  input.addEventListener('input', () => {
    const v = Number(input.value);
    show(v);
    o.onchange(v, gesture);
  });
  input.addEventListener('dblclick', () => {
    set(reset);
    o.onchange(reset, newGesture());
  });
  set(o.value);
  const el = h('div', { class: 'slider' },
    h('div', { class: 'slider__head' }, h('label', { class: 'slider__label', for: id }, o.label), value),
    input);
  return { el, set };
}

export function signed(v: number): string {
  const r = Math.round(v * 100) / 100;
  return r > 0 ? `+${r}` : String(r);
}

/** Buttons where one is pressed: aspect ratios, formats. */
export function chips<T extends string>(options: readonly { value: T; label: string }[], value: T, onpick: (v: T) => void, kind = 'chip'): { el: HTMLElement; set(v: T): void } {
  const buttons = options.map((o) => h('button', { type: 'button', class: kind === 'chip' ? 'chip' : '', onclick: () => onpick(o.value) }, o.label));
  const set = (v: T) => buttons.forEach((b, i) => b.setAttribute('aria-pressed', String(options[i].value === v)));
  set(value);
  return { el: h('div', { class: kind === 'chip' ? 'chips' : 'segmented', role: 'group' }, ...buttons), set };
}

export function toast(message: string, ms = 2500) {
  const el = h('div', { class: 'toast', role: 'status' }, message);
  document.body.append(el);
  setTimeout(() => el.remove(), ms);
}
