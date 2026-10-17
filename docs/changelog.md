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
- The editor: open a folder (subfolders included), a thumbnail grid cached in `.photo-editor/thumbs/`,
  ← → between photos (neighbours decoded ahead), the Adjust tab on the GPU pipeline (exposure in
  stops, white balance, contrast, highlights, shadows, a film-like highlight roll-off, OKLCH
  saturation, sharpen, noise reduction), undo/redo per photo, recipes saved as you edit.
- Claude Code edits the open photo over MCP (`claude mcp add --transport http photo
  http://127.0.0.1:7777/mcp`): get_view (with a screenshot drawn by the pipeline), set_edits,
  open_photo, list_photos, undo. Claude's changes show with a note and Keep / Undo; the header says
  when Claude Code is connected.
- `doka --shot out.png [--eval js]` draws the app off the screen and saves a picture: how Claude
  looks at it without taking over the desktop. `zig build probe` runs the pipeline's tests on the GPU.

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
- The highlight roll-off is identity until an edit pushes white past 1, then bends exactly enough
  that the brightest value lands on white: "0 = unchanged" holds, and pushed highlights never clip hard.
- Sharpen and noise reduction are shader passes, not libvips at export: one implementation of the
  image maths (CLAUDE.md). On the preview they act on its bigger pixels, which the spec allows.
- Halation's blur and the grain's size are shares of the photo's long edge, so the preview and the
  export look the same.
- The page is ES modules served from app://ui/ (registered secure and CORS-enabled); everything the
  app serves (photos, thumbnails) lives under that one origin.
- The MCP server runs on its own threads and only reads requests; every tool runs on the main loop,
  so the app's state has one owner and no locks. Each change returns the new view with its screenshot.
- Undo on Claude's bar undoes all of Claude's pending changes as one step; redo brings them back.
- set_edits refuses unknown fields at any depth, so a typo is an error rather than a silent no-op.
- `doka --offscreen --shots DIR` runs the app with MCP off the screen and pictures each tool call:
  how Claude tests the integration without a window on the desktop.
- Styling is one `ui/style.css`: the design's colours, type and sizes as tokens on `:root`, and a
  few component classes (`.bar`, `.btn`, `.status`). No Tailwind: it needs a build or a CDN.
