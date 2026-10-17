# Changelog

One section per release, the one being worked on at the top. Every commit changes it: a line under
Changed for what someone would notice, a line under Decided for a choice whose reason isn't obvious.

## v0.1 (in progress)

### Changed

- An empty editor window opens (`zig build run`); `zig build probe` checks WebGL2 float render
  targets on the GPU and fails without them.

### Decided

- C APIs (libvips, webview, WebKitGTK, GLib) are declared by hand in Zig, only what we call:
  Zig 0.16's translate-c can't read GLib's headers (`_Pragma` in macros, `g_string_free`).
- The page is served from memory at `app://ui/` (a WebKit URI scheme), not `set_html`: photos and
  float pixels will travel the same way, which webview's JSON-only `bind` can't carry.
- TypeScript is turned into JavaScript by Node's own type stripping (`scripts/strip-types.mjs`):
  no npm packages, no type check.
- Styling is one `ui/style.css`: the design's colours, type and sizes as tokens on `:root`, and a
  few component classes (`.bar`, `.btn`, `.status`). No Tailwind: it needs a build or a CDN.
