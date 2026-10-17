# Roadmap

v1 (SPEC.md's build order) is built. What came out of the first sessions, and what's open.

## Done after the first sessions

- Zoom with the scroll wheel, drag to move, double-click for 100% (full-size photo).
- Before / after as a line to drag across the photo.
- Switching photos: no stale crop, no waiting behind thumbnails; long folders scroll smoothly.
- Claude's tools: `photo` on set_edits/undo (refused if another photo is open), straighten's direction
  fixed and documented (+ clockwise), crop by `aspect` + `focus`, export `folder`, `name` and an
  export-only crop, the Keep / Undo bar shows the last change and a count, list_photos
  `edited_only` with who changed it last, get_view measures clipping and a histogram.
- Starter shaders: bloom, light-leak, clarity (local contrast), dehaze, besides split-tone.

## Open: needs a decision (outside v1's scope in SPEC.md)

- **Masks** (only the sky, only the subject). SPEC.md puts masks and local adjustments out of v1.
  A first step could be a sky mask from colour and position, or the v2 depth map.
- **Dehaze / clarity as built-in sliders** rather than starter shaders.

## Notes

- Kodachrome 64 turns pale skies lavender: that's the LUT (from the RawTherapee collection),
  not the pipeline.
- Idle memory is ~180 MB for the app plus WebKit's own processes; SPEC.md's 150 MB isn't reachable
  with a WebKit window and the NVIDIA driver loaded.
