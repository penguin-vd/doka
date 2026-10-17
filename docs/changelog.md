# Changelog

One section per release, the one being worked on at the top. Every commit changes it: a line under
Changed for what someone would notice, a line under Decided for a choice whose reason isn't obvious.

## v0.1 (in progress)

### Changed

- An empty editor window opens (`zig build run`); `zig build probe` checks WebGL2 float render
  targets on the GPU and fails without them.
- photo-core: camera JPEGs decode to linear half floats (embedded ICC profile, upright, shrink-on-load
  for previews); exports keep every EXIF field, maker notes included, with GPS removed only on request;
  recipes read, merge, clamp and save under `.photo-editor/`.

### Decided

- C APIs (libvips, webview, WebKitGTK, GLib) are declared by hand in Zig, only what we call:
  Zig 0.16's translate-c can't read GLib's headers (`_Pragma` in macros, `g_string_free`).
- The page is served from memory at `app://ui/` (a WebKit URI scheme), not `set_html`: photos and
  float pixels will travel the same way, which webview's JSON-only `bind` can't carry.
- TypeScript is turned into JavaScript by Node's own type stripping (`scripts/strip-types.mjs`):
  no npm packages, no type check.
- EXIF goes into an export byte for byte, patched in place (`src/core/exif.zig`), not through
  libvips: libvips rewrites it with libexif, which cut the E-P7's 17 KB maker note to 144 bytes.
  Patched: orientation 1, pixel size, colour space, the camera's thumbnail dropped, GPS on request.
- Export formats are JPEG and 16-bit PNG, not TIFF: libvips' TIFF writer drops EXIF fields, and
  splicing EXIF into a TIFF's own IFDs isn't worth it while PNG covers lossless 16-bit.
- The recipe adds `vignette` (0–100, the built-in pass has a slider), `shaders[].enabled` (the
  Looks tab toggles shaders) and the `free` crop aspect.
- Styling is one `ui/style.css`: the design's colours, type and sizes as tokens on `:root`, and a
  few component classes (`.bar`, `.btn`, `.status`). No Tailwind: it needs a build or a CDN.
