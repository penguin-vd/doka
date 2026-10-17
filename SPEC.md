# Photo Editor — Build Spec

Oct 16, 2026 · Levi van Daalen
Living version: https://claude.ai/code/artifact/64a027e4-5f24-4c82-9c33-0bab78d71823

## Goal and principles

A small, fast Linux desktop app for everyday photo edits, which Claude Code can also drive live while it's open: you ask in Claude Code, it sees what you see and edits it.

- **Simple:** three tools (Adjust, Looks, Crop) and nothing else in v1.
- **Lightweight and fast:** starts instantly, switches photos instantly, sliders feel live.
- **Non-destructive:** originals are never written to. Edits live in small JSON recipes in the folder's hidden `.photo-editor/` folder.
- **Metadata always kept:** camera, lens, exposure, date and colour profile survive every export. GPS is kept unless the user unticks it.
- **The app owns the state:** Claude talks to the running app directly over MCP, never through shared files, so there is nothing to get out of sync.

## Tech stack

Zig for everything, calling C libraries directly. The UI is a small HTML page shown in the system webview, so the app stays tiny.

| Part | Choice | Why |
| --- | --- | --- |
| App window | [webview](https://github.com/webview/webview) library (MIT) with WebKitGTK 4.1 + GTK 3 | Small and long-established; has a C API Zig calls directly; Zig's build system compiles it (it needs C++11) |
| UI | Plain HTML, CSS and TypeScript (a tiny framework like Preact is optional) | The UI is small; no heavy framework needed |
| Processing | GLSL shaders (WebGL2), for preview and export | Instant sliders, identical export, and looks Claude can write |
| Decode, colour, encode | libvips through `@cImport` | Very fast, multi-threaded, low memory; keeps EXIF, XMP and ICC when saving |
| GPS stripping | Remove the GPS EXIF fields before saving | Only when the user unticks GPS |
| App ↔ Claude link | The app serves MCP itself, over HTTP on 127.0.0.1 | Zig's built-in HTTP server; localhost only; answers from the live state |
| Claude Code access | Add the app's MCP address to Claude Code once | No bridge or extra process; screenshots come back as images, no temp files |

System packages (Debian names): `libvips-dev`, `libgtk-3-dev`, `libwebkit2gtk-4.1-dev`.

Zig is not at 1.0 yet, so pin one Zig version in `build.zig.zon` and stay on it. AI tools sometimes write older Zig syntax; compile errors usually point straight at it.

Preview and export run the same shaders, so they match by construction.

## Image pipeline

All processing is GLSL shaders on the GPU, used for both the live preview and the full-resolution export, so what you see is exactly what you get. Zig and libvips only decode, manage colour, encode and copy metadata.

1. **Decode (libvips):** the camera JPEG is converted to linear float using its embedded ICC profile and uploaded as a float texture.
2. **Base shader:** exposure in true stops, white balance, a filmic tone curve with soft highlight roll-off, and the per-colour mixer (do the mixer in OKLCH so hue shifts look natural).
3. **Look and shaders:** the selected LUT, then any shaders, in order (see Looks and shaders below).
4. **Effect passes:** halation (bright areas blurred and tinted red-orange), grain (luminance-dependent, scaled to resolution) and vignette. Built in; each has its own slider.
5. **Output:** convert to sRGB or Display P3 and dither. For export, the float pixels go back to Zig; libvips resizes, sharpens, encodes, embeds the ICC profile and copies the metadata untouched.

The preview renders a screen-sized copy. Export renders the full image in tiles (for example 2048 × 2048) with the same shaders, so there is no second implementation to keep in sync.

**Tuned for good camera JPEGs:** working in float avoids banding when pushing an 8-bit JPEG. Blown highlights in a JPEG can't be recovered, so the highlight tools aim for a gentle film-like roll-off rather than recovery.

This needs WebGL2 with float render targets in WebKitGTK. Check that on the GPU during step 1 of the build.

**Target machine:** Linux with an NVIDIA RTX 3080, which is plenty for full-resolution float rendering. WebKitGTK on NVIDIA's proprietary driver sometimes shows a blank or flickering window; `WEBKIT_DISABLE_DMABUF_RENDERER=1` usually fixes it.

## Looks and shaders

There are two separate layers that stack: one **look** (a LUT) for the colour base, then any number of **shaders** on top. Neither needs the other.

| | Looks (LUTs) | Shaders |
| --- | --- | --- |
| What it is | A `.cube` file | A folder with `shader.glsl` and `shader.json` |
| Where | `~/.config/<app>/looks/` | `~/.config/<app>/shaders/<name>/` |
| How to add | Drop the file in, done | Write it, or ask Claude |
| Controls | Strength | Strength, plus its own sliders from `shader.json` |
| Per photo | One at a time | Any number, in order |
| Can do | Colour and tone only | Anything: colour, split toning, light leaks, blur, bloom, custom grain |

Order in the pipeline: base adjustments → look → shaders → built-in grain, halation and vignette → output.

```glsl
// shader.glsl: split toning, cool shadows and warm highlights
vec3 effect(vec3 c) {
  float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
  c += vec3(-0.02, 0.0, 0.03) * (1.0 - smoothstep(0.0, 0.4, lum)) * u_shadows;
  c += vec3(0.04, 0.01, -0.03) * smoothstep(0.5, 1.0, lum) * u_highlights;
  return c;
}
```

`u_shadows` and `u_highlights` come from `shader.json`; the app turns each parameter into a uniform and a slider. Shaders that need nearby pixels, like blur or bloom, get the image as a texture.

**Claude's tools for these** (added to the tools in "Claude Code integration"):

| Tool | What it does |
| --- | --- |
| `list_looks` / `list_shaders` | What's installed, with descriptions |
| `get_shader` | A shader's source and parameters |
| `save_shader` | Creates or updates a shader; the app compiles it and returns compile errors, or applies it and returns a screenshot |
| `delete_shader` | Removes a shader |
| `bake_look` | Turns the current colour settings (adjustments + look + colour-only shaders) into a new `.cube` (33³ or 65³), so a look Claude built works as a plain LUT anywhere |

Example: "make it look like Portra 400" → Claude picks a close LUT if there is one, adds a shader for the extra character, checks the screenshot, and can bake the result into a new LUT. A shader that fails to compile never replaces a working one, the last five versions are kept, and files edited by hand reload live.

**Starter looks:** find free film-style `.cube` LUTs online, check that each licence allows personal use, and put them in the looks folder.

## Planned for v2: depth

Shaders can use a depth map, mainly for atmosphere: fog or haze that thickens with distance, and grain or halation that change with depth. Background blur is not a goal.

- **Depth model:** a small monocular model such as Depth Anything V2 (Small), run locally through ONNX Runtime's C API.
- **Only when needed:** a shader declares `"needs": ["depth"]` in `shader.json`; the app computes depth only then, in about a second, and caches it next to the recipe.
- **In the shader:** the depth map arrives as a texture, `u_depth`, with 0 = near and 1 = far.
- **Quality:** fog and grain change gradually, so a soft, lower-resolution depth map is fine; a light blur on the map is enough, no edge refinement needed.
- **Claude:** can write depth shaders too, for example "add some morning fog in the distance."

To prepare in v1: support the `needs` field and an optional extra texture in the shader loader, so depth drops in later without changing existing shaders.

## Architecture

One Zig project: a shared module, `photo-core` (all image work), and one app binary that also hosts the MCP server. One `build.zig` builds it.

```
 ┌──────────────────────────┐
 │ Desktop app UI           │
 │ HTML + WebGL pipeline    │
 └────────────┬─────────────┘
              │ JS bindings
 ┌────────────┴─────────────┐   MCP over HTTP    ┌──────────────────────┐
 │ App window (Zig+webview) │ ◀────────────────▶ │ Claude Code          │
 │ Live state, serves MCP   │   127.0.0.1:7777   │ Asks, looks, edits   │
 └────────────┬─────────────┘                    └──────────────────────┘
              │
 ┌────────────┴───────────────────────────────────────────┐
 │ photo-core (Zig + libvips)                             │
 │ decode · colour management · encode · metadata copy    │
 └────────────┬───────────────────────────────────────────┘
              │ reads photos, writes recipes and exports
 ┌────────────┴───────────────────────────────────────────┐
 │ Photo folder: photos (never changed) + .photo-editor/  │
 └────────────────────────────────────────────────────────┘
```

The running app is the single source of truth: what's on screen, the open photo, the current edits. Claude never reads or writes files to edit; it asks the app. The app still saves recipes in the folder's `.photo-editor/` so edits survive a restart, but that is only for persistence.

## Recipe format

Recipes live in a hidden `.photo-editor/` folder at the root of the folder you open: `trip/photo-04.jpg` → `<root>/.photo-editor/recipes/trip/photo-04.jpg.json`. Photo folders stay clean and edits move with the folder. A setting can switch this to one central location instead. Deleting a recipe resets the photo. Only non-zero values are written.

```json
{
  "version": 1,
  "edits": {
    "exposure": 0.3,
    "temperature": 6,
    "tint": 0,
    "contrast": 8,
    "highlights": -20,
    "shadows": 25,
    "saturation": 5
  },
  "look": { "name": "classic-chrome.cube", "strength": 80 },
  "shaders": [
    { "name": "split-tone", "strength": 60, "params": { "shadows": 0.5, "highlights": 0.7 } }
  ],
  "colour": {
    "greens": { "hue": 8, "sat": -15, "light": 0 },
    "blues": { "hue": 0, "sat": -10, "light": -5 }
  },
  "halation": 15,
  "grain": { "amount": 25, "size": 40 },
  "detail": { "sharpen": 30, "noise": 15 },
  "crop": { "aspect": "4:5", "straighten": -2, "rotate": 0, "flip": false, "rect": [0.1, 0.0, 0.8, 1.0] },
  "updatedBy": "claude",
  "updatedAt": "2026-10-16T13:30:00Z"
}
```

| Field | Range | Notes |
| --- | --- | --- |
| `exposure` | −5 to 5 EV | True stops, applied in linear light |
| `temperature`, `tint`, `contrast`, `highlights`, `shadows`, `saturation` | −100 to 100 | 0 = unchanged |
| `look.name` | A `.cube` file in the looks folder | `none` = no look |
| `look.strength` | 0 to 100 | Blends the LUT in |
| `shaders` | List of { name, strength, params } | Applied in order, after the look |
| `colour.<band>` | hue, sat, light: −100 to 100 | Bands: reds, oranges, yellows, greens, blues, purples |
| `halation` | 0 to 100 | Glow around highlights |
| `grain.amount`, `grain.size` | 0 to 100 | Size is relative to image resolution |
| `detail.sharpen`, `detail.noise` | 0 to 100 | Full quality at export; preview approximates |
| `crop.rect` | 0 to 1, as x, y, width, height | Relative, so it works at any resolution |
| `crop.rotate` | 0, 90, 180, 270 | Quarter turns |
| `updatedBy` | "user" or "claude" | Lets the app show Claude's changes with Keep / Undo |

Undo history is kept in memory for the session and works for edits from either side. After a restart, only the current edits remain.

## App features (v1)

The UI follows the design canvas (see `design/`): folder sidebar, photo in the middle, tool panel on the right. Where the design and this spec differ, this spec wins.

- **Folder browser:** Open folder (native dialog), thumbnail grid, a dot on edited photos. Remember the last folder. ← → switches photos.
- **Adjust:** Exposure, Contrast, Highlights, Shadows, Temperature, Tint, Saturation, Sharpen, Noise reduction. Double-click a slider to reset it.
- **Looks:** a grid of looks (LUT files), each previewed on the current photo, plus Strength, Grain (amount, size) and Halation sliders. A collapsed Colour section holds the per-colour mixer, and a Shaders list below lets you add, reorder and toggle shaders.
- **Crop:** aspect ratios (Original, 1:1, 4:5, 3:2, 16:9), drag handles, Straighten, Rotate 90°, Flip.
- **Before / after:** hold `\` or click the toggle to see the original.
- **Undo / redo:** Ctrl+Z / Ctrl+Shift+Z, per photo.
- **Export:** JPEG, PNG or TIFF; quality; size (original or long edge); Keep metadata on by default; GPS toggle. Batch export for selected photos. Defaults (output folder, naming, quality) to be decided later; pick sensible ones and make them easy to change.
- **Claude changes:** edits from Claude appear live with a Keep / Undo bar and a short note of what changed.
- **Auto-save:** recipes save to disk as you edit, no Save button.

## Claude Code integration

Open the app, open Claude Code, and ask: "make it more film-like." Claude sees the same photo and edits you do, changes it live, and you keep or undo the result.

**How it connects:** while it's open, the app serves MCP at `http://127.0.0.1:7777/mcp`. Add it to Claude Code once: `claude mcp add --transport http photo http://127.0.0.1:7777/mcp`. There is no bridge, socket or second process.

| Tool | What it does |
| --- | --- |
| `get_view` | What you see right now: folder, open photo, active tab, current edits, camera and lens summary, plus a screenshot of the rendered photo, returned as an image |
| `set_edits` | Changes sliders, look, colour, grain, halation or crop live (only the fields given); shows the Keep / Undo bar; returns the new view |
| `open_photo` | Switches to another photo by name, or next / previous |
| `list_photos` | Photos in the open folder, with an edited flag |
| `undo` | Undoes the last change |
| `export` | Exports the current or named photos; metadata always kept |

Plus the look and shader tools listed under "Looks and shaders".

Basic safety: listen on 127.0.0.1 only, and reject requests with a browser `Origin` header so websites can't reach it. If the app isn't open, Claude Code shows the server as disconnected; open the app and run `/mcp` to reconnect.

The server's instructions tell Claude to call `get_view` before editing, make one change at a time, look again after each change, keep camera and lens metadata, and say briefly what it changed.

**Example: "make it more film-like"**

1. `get_view` → Claude sees the photo and that only Exposure +0.3 is set.
2. `set_edits` → a film look at 70%, Highlights −15, Grain 25, a touch of Halation.
3. `get_view` → checks the new screenshot.
4. Replies: "Added the Film look at 70% and softened the highlights." You click Keep, or say "a bit less."

There's no official Zig MCP SDK, but none is needed: each request is a JSON-RPC message POSTed to `/mcp`, and the app can answer with plain JSON. Only `initialize`, `tools/list` and `tools/call` are needed, a few hundred lines with `std.http` and `std.json`.

## Performance targets

Budgets to test against, measured on a 24-megapixel JPEG.

| What | Target | How |
| --- | --- | --- |
| App start to first photo | < 500 ms | Lazy-load the folder; show cached thumbnails first |
| Switch to next photo | < 100 ms | Pre-decode the previous and next photo in the background |
| Slider drag | 60 fps | GPU shader on a preview copy (long edge ≈ screen size), never full-res |
| Thumbnails, 200-photo folder | < 3 s first time, instant after | libvips shrink-on-load; cache in `<root>/.photo-editor/thumbs/` |
| Export one photo | < 2 s | GPU render in tiles, then libvips encode |
| Claude request round trip | < 300 ms with screenshot | Localhost HTTP; screenshot as a 1024 px JPEG |
| Idle memory | < 150 MB | Keep only the current photo at full size |
| Download size | < 5 MB | System webview and libvips; nothing bundled |

## Out of scope for v1

- RAW files: not needed, the photos are good JPEGs (LibRaw could add it later)
- Layers, masks, brushes, healing or local adjustments
- Library features: ratings, tags, albums, search
- Cloud sync, accounts, sharing
- Windows and macOS builds
- Saved presets that apply a whole recipe in one click (v2)

## Build order

Build the core and a basic window first, then the Claude link early. From step 5 on, Claude can be asked for edits while the rest of the UI grows.

1. **Setup:** pin the Zig version, `build.zig` linking libvips and webview, an empty window that opens. Confirm WebGL2 with float render targets works in the window.
2. **Core:** recipe types; decode, colour management, encode and metadata copy with libvips. A test that compares EXIF before and after export.
3. **App window:** open folder, thumbnail grid with cache, switch photos.
4. **Adjust tab:** base shader pipeline from decoded photo to screen; auto-save recipes.
5. **MCP in the app:** HTTP endpoint with `get_view` (including the screenshot) and `set_edits`; try "make it brighter" from Claude Code.
6. **The other tools:** `open_photo`, `list_photos`, `undo`, `export`.
7. **Looks and Crop tabs:** look folders with hot reload, the look and shader tools for Claude, colour mixer, grain, halation, and tiled full-res export on the GPU.
8. **Export dialog,** including batch export and the GPS toggle.
9. **Keep / Undo bar** for Claude's edits.
10. **Polish:** keyboard shortcuts, before/after, performance check against the targets above.

**Done when:** you can open a folder, edit and export photos without the metadata changing, and ask Claude Code "make it more film-like" and watch the open photo change.
