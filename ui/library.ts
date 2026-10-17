// Looks and shaders as the app lists them (src/app/library.zig), loaded into pipelines: a look's
// .cube parsed once, a shader compiled per pipeline. A shader edited on disk that no longer
// compiles keeps its last working version, with its error shown.

import { call, on, report } from './rpc.js';
import { parseCube, type Cube } from './gl/cube.js';
import { ShaderError, type Pipeline, type ShaderDef } from './gl/pipeline.js';
import type { Recipe } from './state.js';

export interface LookInfo { name: string; title: string; version: number; }
export interface ShaderInfo extends ShaderDef { source: string; version: number; error?: string; }

type Listener = () => void;

export class Library {
  looks: LookInfo[] = [];
  shaders: ShaderInfo[] = [];
  private cubes = new Map<string, { version: number; cube: Promise<Cube> }>();
  // What each pipeline has: its look and every shader's version.
  private state = new WeakMap<Pipeline, { look: string; lookVersion: number; shaders: Map<string, number> }>();
  private listeners = new Set<Listener>();
  private loading: Promise<void> = Promise.resolve();

  constructor() {
    on('library', () => { this.refresh().catch(report); });
  }

  subscribe(fn: Listener) { this.listeners.add(fn); }

  /** Reloads the lists; resolves when done. */
  refresh(): Promise<void> {
    this.loading = this.loading.then(async () => {
      const lib = await call<{ looks: LookInfo[]; shaders: ShaderInfo[] }>('library');
      const errors = new Map(this.shaders.map((s) => [s.name, s]));
      this.looks = lib.looks;
      this.shaders = lib.shaders.map((s) => {
        const old = errors.get(s.name);
        return old && old.version === s.version ? { ...s, error: old.error } : s;
      });
      for (const fn of this.listeners) fn();
    });
    return this.loading;
  }

  /** Waits for a refresh under way. */
  settled(): Promise<void> { return this.loading; }

  cube(name: string): Promise<Cube> {
    const info = this.looks.find((l) => l.name === name);
    const version = info?.version ?? 0;
    const have = this.cubes.get(name);
    if (have && have.version === version) return have.cube;
    const cube = fetch(`looks/${encodeURIComponent(name)}`)
      .then((r) => { if (!r.ok) throw new Error(`look ${name}: ${r.status}`); return r.text(); })
      .then(parseCube);
    cube.catch(() => this.cubes.delete(name));
    this.cubes.set(name, { version, cube });
    return cube;
  }

  /** Loads the recipe's look and shaders into `p`; true when anything changed. */
  async prepare(p: Pipeline, recipe: Recipe): Promise<boolean> {
    await this.loading;
    let st = this.state.get(p);
    if (!st) { st = { look: 'none', lookVersion: 0, shaders: new Map() }; this.state.set(p, st); }
    let changed = false;

    const want = recipe.look.name;
    const info = this.looks.find((l) => l.name === want);
    if (want === 'none' || !info) {
      if (st.look !== 'none') { p.setLook(null); st.look = 'none'; changed = true; }
    } else if (st.look !== want || st.lookVersion !== info.version) {
      try {
        p.setLook(await this.cube(want));
        st.look = want;
        st.lookVersion = info.version;
        changed = true;
      } catch (e) { report(e); }
    }

    for (const use of recipe.shaders) {
      const s = this.shaders.find((x) => x.name === use.name);
      if (!s || st.shaders.get(s.name) === s.version) continue;
      st.shaders.set(s.name, s.version);
      try {
        p.setShader(s.name, p.compileShader(s, s.source));
        s.error = undefined;
        changed = true;
      } catch (e) {
        // The last version that compiled stays in the pipeline.
        s.error = e instanceof ShaderError ? e.message : String(e);
        for (const fn of this.listeners) fn();
      }
    }
    return changed;
  }

  /** Forgets what `p` has loaded, after something set its look directly (the look previews). */
  forget(p: Pipeline) { this.state.delete(p); }

  /** Compiles a shader without installing it: save_shader's check. */
  check(p: Pipeline, def: ShaderDef, source: string): string {
    try {
      const compiled = p.compileShader(def, source);
      p.gl.deleteProgram(compiled.prog.program);
      return '';
    } catch (e) {
      return e instanceof ShaderError ? e.message : String(e);
    }
  }
}
