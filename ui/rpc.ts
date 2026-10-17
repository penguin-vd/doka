// Talking to the app (src/app/app.zig): `call` asks it something, `on` hears what changed
// outside the page (Claude's edits, files on disk).

declare global {
  interface Window {
    rpc(method: string, params?: unknown): Promise<unknown>;
    doka: { event(name: string, payload: unknown): void };
  }
}

export async function call<T>(method: string, params?: unknown): Promise<T> {
  return (await window.rpc(method, params ?? null)) as T;
}

type Listener = (payload: any) => void;
const listeners = new Map<string, Set<Listener>>();

export function on(name: string, fn: Listener) {
  if (!listeners.has(name)) listeners.set(name, new Set());
  listeners.get(name)!.add(fn);
}

window.doka = {
  event(name, payload) {
    for (const fn of listeners.get(name) ?? []) {
      try { fn(payload); } catch (e) { report(e); }
    }
  },
};

export function log(message: string, level: 'info' | 'error' = 'info') {
  window.rpc('log', { level, message }).catch(() => {});
}

export function report(e: unknown) {
  const err = e as Error;
  log(err && err.stack ? `${err.message}\n${err.stack}` : String(e), 'error');
}

window.addEventListener('error', (e) => log(`${e.message} at ${e.filename}:${e.lineno}`, 'error'));
window.addEventListener('unhandledrejection', (e) => report(e.reason));
