# Masks plan

Editing part of a photo: "darken the sky", "lift only the subject". Steps 1 and 2 are built, and the owner
has used them in the window. Step 3 isn't built.

Each step ends with its tests passing and the owner trying it in the window. Commit only when the
owner says so.

## Decided (2026-11-04)

1. **Who drives masks:** Claude first, with enough UI to see and adjust what it did.
2. **Which photos:** all of them, and portraits especially (most aren't on this drive yet). A sample
   of the library is about a third people outdoors, the rest skies, landscapes, streets and night
   cities. So click-a-subject comes before depth.
3. **Where they live:** layers at the top of Adjust. Pick a layer and the same sliders edit it.
4. **What a mask changes:** the seven sliders and the colour mixer. Sharpening and noise reduction
   would need the pipeline rebuilt, so they stay whole-photo.

5. **How AI masks are stored:** saved, as a small PNG in `.photo-editor/masks/`.
6. **The download:** yes, optional: `scripts/subject-model.py`, 56 MB.

## Step 1: gradient, radial and range masks (built)

No new dependencies. Claude can already be the context-aware part: it sees the photo, finds the
horizon, places a gradient and limits it to blue tones.

- **Recipe:** a `masks` list, each with its shape (whole photo, linear, radial), feather, invert,
  a brightness range, a hue range, and its own edits. Coordinates are 0..1 of the photo as decoded,
  so a mask stays on its pixels through crop and rotation. Only non-defaults are written.
- **Pipeline:** one more pass per mask, after the look and before the shaders. The shared light and
  colour functions are in `adjust.glsl`, so there's still one implementation of the maths.
  Preview, screenshots and export get masks at once, since they share the pipeline.
- **Claude:** `set_edits` takes `masks`, with its coordinates explained in the tool's description.
- **UI:** layers at the top of Adjust, add and remove, the same sliders, and handles on the photo
  drawn on the canvas's overlay. A "show mask" overlay, in red: the one colour besides the photo, while it's on.
- **Tests:** in `selftest.zig`, a mask with no edits changes nothing; a gradient changes one side
  and not the other; brightness and hue limits, and invert, select the right pixels; an exported
  photo matches the preview. In `recipe_test.zig`, masks read, write and clamp.

## Step 2: click a subject (built)

Click a person or object to mask it, or have Claude pick the main subject.

- **Runtime:** ONNX Runtime's C API (Microsoft's release, CPU), declared by hand and loaded only when
  first needed, so the app starts as fast as it does now and works without it.
- **Model:** MobileSAM. Downloaded by a script with pinned checksums, like the starter looks, never
  kept in this repository.
- **Storage:** as decided in 5.
- **Edges:** the coarse mask is refined against the photo's own edges with a guided filter.
- **Claude:** a tool that takes a point or a description of where to look, and returns the mask
  drawn over the photo so it can check.
- **Tests:** the mask pass with a stored mask; a stored mask surviving a restart and an export.

## Step 3: depth

What `SPEC.md` planned for v2. Near and far masks, plus haze and fog by distance.

- **Runtime:** the same as click-a-subject's.
- **Model:** Depth Anything V2 Small, or similar; check its licence. Downloaded by a script, like
  the starter looks, never kept in this repository.
- **Pipeline:** the depth map as a texture: `u_depth` and `needs: ["depth"]` already exist, flat for
  now. Cached beside the recipe.
- **Masks:** a depth range joins the brightness and hue ranges.
- **Tests:** depth maps from a made-up image through the mask pass; the app still runs and says so
  plainly when the runtime or model is missing.

## Out of scope for now

Brushes, per-mask looks or shaders, and syncing masks anywhere outside the recipe.
