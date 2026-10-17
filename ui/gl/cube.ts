// .cube LUT files (Adobe/Resolve 3D LUT format): a lattice of output colours, red fastest.

export interface Cube {
  title: string;
  size: number;
  min: [number, number, number];
  max: [number, number, number];
  data: Float32Array; // size³ × RGB
}

export function parseCube(text: string): Cube {
  let title = '';
  let size = 0;
  let min: [number, number, number] = [0, 0, 0];
  let max: [number, number, number] = [1, 1, 1];
  const values: number[] = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line === '' || line.startsWith('#')) continue;
    const parts = line.split(/\s+/);
    const key = parts[0].toUpperCase();
    if (key === 'TITLE') title = line.slice(5).trim().replace(/^"|"$/g, '');
    else if (key === 'LUT_3D_SIZE') size = Number(parts[1]);
    else if (key === 'DOMAIN_MIN') min = [Number(parts[1]), Number(parts[2]), Number(parts[3])];
    else if (key === 'DOMAIN_MAX') max = [Number(parts[1]), Number(parts[2]), Number(parts[3])];
    else if (key === 'LUT_1D_SIZE') throw new Error('1D LUTs are not supported');
    else if (/^[-+.\d]/.test(key)) values.push(Number(parts[0]), Number(parts[1]), Number(parts[2]));
  }
  if (size < 2 || size > 256) throw new Error(`bad LUT_3D_SIZE ${size}`);
  if (values.length !== size * size * size * 3) throw new Error(`expected ${size ** 3} entries, found ${values.length / 3}`);
  if (values.some((v) => !Number.isFinite(v))) throw new Error('a value is not a number');
  return { title, size, min, max, data: new Float32Array(values) };
}

/** A .cube's text: what bake_look writes. */
export function writeCube(title: string, size: number, rgb: Float32Array): string {
  const lines = [`TITLE "${title.replace(/"/g, '')}"`, `LUT_3D_SIZE ${size}`, 'DOMAIN_MIN 0 0 0', 'DOMAIN_MAX 1 1 1'];
  for (let i = 0; i < size * size * size; i++) {
    lines.push(`${rgb[i * 3].toFixed(6)} ${rgb[i * 3 + 1].toFixed(6)} ${rgb[i * 3 + 2].toFixed(6)}`);
  }
  return lines.join('\n') + '\n';
}
