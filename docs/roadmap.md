# Roadmap

v1 (SPEC.md's build order) is built. Below: what was done after the first sessions, then every
optional idea so far, roughly by how much it would help. Sizes: S a few hours, M a day or two,
L more. Nothing here is decided; pick from it.

## Done after the first sessions

- Zoom with the scroll wheel, drag to move, double-click for 100% (the full-size photo loads).
- Before / after as a line to drag across the photo.
- Switching photos: no stale crop, no waiting behind thumbnails; long folders scroll smoothly.
- Claude's tools: `photo` on set_edits/undo (refused if another photo is open), straighten's
  direction fixed and documented (+ clockwise), crop by `aspect` + `focus`, export `folder`, `name`
  and an export-only crop, the Keep / Undo bar shows the last change and a count, list_photos
  `edited_only` with who changed it last, get_view measures clipping and a histogram.
- Starter shaders: bloom, light-leak, clarity (local contrast), dehaze, besides split-tone.

## Immich

The photos are also in Immich. Endpoints below are from Immich's OpenAPI spec (`main`, 3.3.0-rc,
`open-api/immich-openapi-specs.json`); check them against the server's own version first
(`GET /api/server/version`). Auth is an API key in the `x-api-key` header, kept in settings.json
(or the desktop's keyring).

1. **Export to Immich** (M, the most useful). An export can also go to Immich: upload it
   (`POST /assets`, multipart `assetData` with `fileCreatedAt`/`fileModifiedAt`), put it in an album
   (`PUT /albums/{id}/assets`), and stack it on the original (`POST /stacks` with
   `[edited, original]`: the first becomes the stack's cover, so the edit shows and the original
   stays one click away). Finding the original's asset: if Immich reads `/mnt/games/Pictures` as an
   external library, by `originalPath` (`POST /search/metadata`); otherwise by `originalFileName` and
   the date taken, or by checksum (Immich's is the original file's SHA-1). The export dialog gets
   "Also to Immich" with an album picker; Claude's `export` gets `immich: true` / `album`.
   Metadata is already kept by the export, so Immich's map, dates and camera info just work.
2. **Edited in Doka, visible in Immich** (S, with 1): a tag or description on the stacked export
   saying it came from Doka, with the recipe's summary.
3. **Open from Immich** (L): browse albums or search in the sidebar, download originals
   (`GET /assets/{id}/original`) into a local cache folder and edit there. Bigger change: today a
   "folder" is a folder on disk. Only worth it if photos aren't on this computer anyway.
4. **Immich's own edits** (S, probably not): Immich 3.3 has `PUT /assets/{id}/edits`, but only
   crop, rotate and mirror. Syncing Doka's crop there would show the crop in Immich without an
   export; colours wouldn't come along, so 1 is the better way.

## Editing

- **Masks** (L; SPEC.md puts masks out of v1). In steps:
  - a sky mask from colour, brightness and position, with a feathered edge (M): "darken only the sky";
  - masks from the v2 depth map: near / far (M once depth exists);
  - subject masks need a segmentation model through ONNX Runtime, like depth (L).
  Each mask would be a recipe entry `{mask, edits}` running the develop pass a second time.
- **Depth** (L, SPEC.md v2): Depth Anything V2 Small through ONNX Runtime's C API; `needs: ["depth"]`
  and `u_depth` are already wired (flat for now). Fog, haze, grain by distance.
- **Presets** (S–M, SPEC.md v2): save a recipe's look-and-colour part, apply it in one click.
- **Copy and paste edits** between photos, and to all selected ones (S).
- **Dehaze and clarity as sliders** in Adjust instead of starter shaders (S each; the shaders work).
- **Crop aspect follows orientation** (S): 3:2 becomes 2:3 on a portrait photo, with a swap button.
- **A histogram in the UI** (S): the numbers exist already (get_view).

## Files and formats

- **TIFF export with all EXIF** (M): libvips' TIFF writer drops fields; would need our EXIF
  written into the TIFF's own IFDs. PNG 16-bit covers lossless meanwhile.
- **One central place for recipes** instead of `.photo-editor/` beside the photos (S; SPEC.md
  mentions it as a setting).
- **RAW** through LibRaw (L; SPEC.md: out of v1, the photos are good JPEGs).

## Claude

- **Edit several photos in one call** (S): set_edits with `photos: [...]`, for a series.
- **An activity list** in the panel (S; the design had one): Claude's calls, newest last.
- **More looks and shaders** written by Claude on request; bake_look already makes LUTs of them.

## Speed and size

- **Idle memory** (M): ~180 MB for the app plus WebKit's own processes; SPEC.md's 150 MB isn't
  reachable with a WebKit window and the NVIDIA driver. Could drop the neighbour cache after a
  minute idle (-38 MB) and the full-size photo when zoomed out.
- **First thumbnails from EXIF** (S): the camera's embedded thumbnail shows at once, the real one
  replaces it.

## Packaging

- A `.desktop` file and icon, an install step (`zig build install --prefix ~/.local`) (S).
- An AUR package (S, if others want it).

## Not tested by Claude

Only through a real window: the open-folder dialog (GTK portal on Hyprland), dragging sliders and
crop handles with the mouse, wheel zoom with a real mouse.

## Notes

- Kodachrome 64 turns pale skies lavender: that's the LUT (from the RawTherapee collection),
  not the pipeline.
