// TypeScript to JavaScript for the webview, by Node's own type stripping: no packages, no type check.
// Only erasable syntax works (no enum, namespace or parameter properties). build.zig runs it.
//   node scripts/strip-types.mjs in.ts out.js
import { readFileSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';

const [input, output] = process.argv.slice(2);
writeFileSync(output, stripTypeScriptTypes(readFileSync(input, 'utf8')));
