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
- Looks and Crop tabs: a grid of looks drawn on the photo, strength, grain, halation, vignette, a
  colour mixer (one band at a time), the photo's shaders (add, order, turn off, tune); crop with
  aspect ratios, handles, straighten, rotate and flip.
- Export on the GPU at full size with the preview's shaders: JPEG or 16-bit PNG, sRGB or Display P3,
  a long edge, metadata and GPS choices, the selected photos at once (Ctrl/Shift-click); never over
  an earlier export. Claude's `export` does the same.
- Looks are .cube files in ~/.config/doka/looks, shaders folders in ~/.config/doka/shaders, both
  watched for edits; `scripts/starter-looks.py` installs twelve film stocks. Claude has
  list_looks, list_shaders, get_shader, save_shader (compiled before it's saved, last five kept),
  delete_shader and bake_look.
- Faster: the first photo is up ~350 ms after start (the photo decodes while the shaders compile),
  thumbnails use every core (200 in ~1.1 s, instant once cached), memory is handed back after
  decodes and exports, release builds are stripped (1.3 MB). Ctrl+O, Ctrl+E and Ctrl+Y.
- Scroll to zoom (around the cursor), drag to move, double-click for 100%; past the preview's
  pixels the full-size photo loads. Before / after is a line to drag across the photo; holding
  `\` still shows the whole original.
- Switching photos no longer shows the old photo with the new one's crop, and no longer waits
  behind thumbnails; long folders scroll smoothly (only changed thumbnails are touched, ones off
  screen aren't painted, the newest thumbnails are made first).
- The footer's "Metadata kept" and the sidebar's hint are gone (the hint is in the thumbnails' tooltip).
- For Claude: set_edits and undo take the `photo` they mean (refused if another is open); a crop
  by `aspect` and `focus`; export to a `folder` under a `name`, with a crop for that export only;
  list_photos `edited_only`; get_view measures clipping, mean and a histogram; the Keep / Undo bar
  says how many changes Claude made and the last one.
- Straighten turns clockwise for + (as Lightroom), the other way round from before.
- Starter shaders bloom, light-leak, clarity and dehaze; each lands in the shaders folder once.
- `doka --shot out.png [--eval js]` draws the app off the screen and saves a picture: how Claude
  looks at it without taking over the desktop. `zig build probe` runs the pipeline's tests on the GPU.
- The sidebar separates photos by the day they were taken, with a heading that stays in view, and
  filters them: all, edited or not edited, and by day. ← → follow the filters; the photo you have
  open stays in the list so it can't vanish while you edit it.
- Claude's edits just apply: no Keep / Undo bar; Ctrl+Z undoes them step by step.
- A new look: the photo is the only colour on screen. Neutral greys, white for "on" and "changed",
  sliders that fill from zero, whole photos in the thumbnails, compact controls.
- Smoother: a slider tick no longer rereads the photo's metadata from disk, no redraw when nothing
  on the canvas changed, the wheel zoom and the photo list glide, holding ← → skips photos instead of queueing them, and the full-size photo waits
  until the zoom settles.
- Zooming in no longer freezes when the full-size photo arrives: it goes to the GPU a little per
  frame. Frames keep coming while the mouse or keyboard is in use, so a scroll or zoom starts at once.
- Moving or zooming a photo redraws only the last step, not all the edits over all its pixels.
- The editor is now native: GTK 4 and OpenGL, far smoother than the WebKit window it replaces, with
  everything it had: filters and day groups, Adjust, Looks, Crop, Compare, export, and all of Claude's
  tools. The WebKit window, the page in `ui/` and the Node build step are gone.

- Masks: part of the photo with edits of its own, as layers at the top of Adjust. Pick a layer and
  the same sliders edit it, with its own colour mixer. Gradients, circles and brightness or colour
  ranges, up to eight, with handles on the photo and a red "show mask" view. Claude places them with
  `set_edits` and checks them with `get_view`'s `show_mask`. Preview, screenshots and export all
  have them; the look thumbnails too. The Adjust tab scrolls when a mask's controls need the room.

- Masks can blur: a Blur slider per mask, like a lens, so a background goes soft behind a person
  without taking their colour.
- Click a subject: "+ Subject" in Adjust, click a person or thing and the mask follows its outline,
  down to hair; more clicks add to it, Shift-clicks take away. Claude does the same with
  `mask_subject`. Optional: `scripts/subject-model.py` downloads ONNX Runtime and MobileSAM once
  (56 MB, 74 MB unpacked); without it everything else works and the button says what to run.
- What the native window had lost is back: double-click a slider resets it for sure (the name too,
  and one undo step), double-click the photo for 100% and back, the pointer shows what a press will
  grab, "Original" while holding `\\`, the way in when no folder is open, Escape and Enter in the
  export dialog, tooltips on thumbnails and shaders, and a shader that doesn't compile says so in its
  row (and is tried once, not on every frame). Grabbing a slider's thumb no longer moves it.
- ← → always switch photos, also just after clicking a look or a button. A clicked slider nudges
  with ↑ ↓, Shift for ten steps.
- The wheel over a slider's track moves it, Ctrl for one step at a time; a run of it undoes as one
  step. A wheel already scrolling the panel keeps scrolling it, and the sliders' names scroll it.
- Smoother masks: Escape leaves click-a-subject or the mask, Delete removes it; zoomed in, dragging
  while clicking a subject moves the photo; the red shows while dragging Feather or a tone limit; the
  limits fold away so the Light sliders stay near the top; a mask's eye no longer rebuilds the list;
  grabbing takes the nearest handle; new masks don't repeat a name; a failed subject click says so.

### Decided

- Subject masks are saved as small PNGs in `.photo-editor/masks/`, named from what made them, so they
  look the same every time and open instantly. Undo needs the old ones, so removing a mask keeps its
  file. MobileSAM over bigger models: 1.2 s the first click on a photo and 0.2 s after, on the CPU,
  with no GPU runtime to install. The model's image part is unloaded after each photo, to keep idle
  memory low. The coarse mask is refined against the photo with a guided filter.
- Masks' brightness and colour limits read the original photo, not the edited one: changing a look
  or the exposure doesn't move what a mask selects. They read a tiny average of nearby pixels,
  because single pixels' noise speckled the mask's edge.
- A mask's edits run after the look, in `src/app/glsl/adjust.glsl`, the same code as the whole
  photo's sliders. Sharpening and noise reduction stay whole-photo: per mask they'd need the pipeline
  rebuilt and would slow every slider drag.
- After gradients, click-a-subject comes before depth: portraits are a big part of what this is for.
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
- The export renders the whole photo at once (a 20 MP photo is ~1 GB of GPU memory, fine on the
  RTX 3080) and reads it back in strips, rather than rendering tiles: halation's blur and
  straighten need pixels from beyond a tile's edge, and whole-photo rendering has no seams.
- Export pixels reach the app by POSTs to app://ui/export/…, the same channel as photos going
  the other way; webview's bind only carries JSON.
- A tag the camera left out of EXIF (ColorSpace on a RawTherapee JPEG) is added by moving the
  Exif IFD to the end of the block; the maker note and everything else stay where they were.
- Starter looks come from the RawTherapee Film Simulation Collection (CC BY-SA 4.0): converted by a
  script into the user's folder rather than kept in the repository, with a credits file beside them.
- Crop aspect ratios are literal (4:5 is portrait on any photo); Original is the photo's own.
- The preview is a fixed 2048 px on its long edge, chosen by the app rather than the page, so the
  app can decode the photo before the page asks for it.
- libvips' operation cache is off: it kept decoded photos alive; nothing here asks twice.
- Zoom and before/after happen in the finish pass (a window onto the output, a scissor for the
  original), so grain, vignette and halation stay true to the whole photo at any zoom.
- Clarity and dehaze are starter shaders, not sliders: no new core maths, and Claude can tune them.
- Styling is one `ui/style.css`: the design's colours, type and sizes as tokens on `:root`, and a
  few component classes (`.bar`, `.btn`, `.status`). No Tailwind: it needs a build or a CDN.
- The day comes from EXIF, read on a worker from each file's first 64 KB, not from the file's date,
  which changes on copying. The list stays in file order: a day that comes back gets a second heading.
- All neutral greys, because any tint beside the photo shifts how its colours read; supersedes the
  design's amber accent and 44 px targets (this is used with a mouse). The recipe box in the panel
  went with it: Claude reads the recipe from get_view.
- GTK 4 instead of WebKit: WebKit stays near 60 frames per second on this NVIDIA driver. GTK over Raylib or
  SDL: an editor is mostly lists, sliders, dialogs and text, and it draws nothing when idle.
- The shaders stayed as they were; the version line follows what GTK offers (OpenGL ES here, desktop on a Mac).
