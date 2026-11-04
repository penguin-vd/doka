# Masks plan

Editing part of a photo: "darken the sky", "lift only the subject". Nothing here is built yet. The
three steps are agreed in outline; the open questions below come first.

Each step ends with its tests passing and the owner trying it in the window. Commit only when the
owner says so.

## Open questions

Answer these before step 1; the first two shape everything else.

1. **Who drives masks most?** Asking Claude, so the UI stays small; or working by hand, so it needs
   a full panel and handles on the photo. Leaning: Claude first, with enough UI to see and adjust
   what it did.
2. **Which photos are they for?** A few real examples from the library. Grey skies over water call
   for something else than neon streets or food, and may decide whether subject masks come earlier.
3. **Where do they live in the app?** A section in Adjust keeps "three tools"; a fourth tab has more
   room. Leaning: a section, unless masks turn out to need many controls.
4. **What can a mask change?** Leaning: the light and colour sliders only. Per-mask looks,
   sharpening or noise reduction would change how the pipeline is built.
5. **How are AI masks stored?** Gradients are a few numbers in the recipe. A subject mask is an
   image: a file in `.photo-editor/`, or made again each time. Decide before step 3 at the latest;
   the recipe format should leave room from step 1.
6. **Is the download acceptable?** Steps 2 and 3 add ONNX Runtime and models, likely 100 MB or more.
   Optional, and loaded only when used, but the app is meant to be small.

## Step 1: gradient, radial and range masks

No new dependencies. Claude can already be the context-aware part: it sees the photo, finds the
horizon, places a gradient and limits it to blue tones.

- **Recipe:** a `masks` list, each with its shape (whole photo, linear, radial), feather, invert,
  a brightness range, a hue range, and its own edits. Coordinates are 0..1 of the photo as decoded,
  so a mask stays on its pixels through crop and rotation. Only non-defaults are written.
- **Pipeline:** one more pass per mask, after the look and before the shaders. Move the shared light
  and colour functions out of `develop.glsl`, so there's still one implementation of the maths.
  Preview, screenshots and export get masks at once, since they share the pipeline.
- **Claude:** `set_edits` takes `masks`, with its coordinates explained in the tool's description.
- **UI:** a list of masks, add and remove, their sliders, and handles on the photo drawn on the
  canvas's overlay. A "show mask" overlay, in red: the one colour besides the photo, while it's on.
- **Tests:** in `selftest.zig`, a mask with no edits changes nothing; a gradient changes one side
  and not the other; brightness and hue limits, and invert, select the right pixels; an exported
  photo matches the preview. In `recipe_test.zig`, masks read, write and clamp.

## Step 2: depth

What `SPEC.md` planned for v2. Near and far masks, plus haze and fog by distance.

- **Runtime:** ONNX Runtime's C API, declared by hand and loaded only when first needed, so the app
  starts as fast as it does now and works without it. On Arch: `onnxruntime-cpu`; check whether the
  GPU builds are worth their size.
- **Model:** Depth Anything V2 Small, or similar; check its licence. Downloaded by a script, like
  the starter looks, never kept in this repository.
- **Pipeline:** the depth map as a texture: `u_depth` and `needs: ["depth"]` already exist, flat for
  now. Cached beside the recipe.
- **Masks:** a depth range joins the brightness and hue ranges.
- **Tests:** depth maps from a made-up image through the mask pass; the app still runs and says so
  plainly when the runtime or model is missing.

## Step 3: click a subject

Click a person or object to mask it, or have Claude pick the main subject.

- **Model:** a small Segment Anything style model through the same runtime; choose by size, speed
  and licence when we get there.
- **Storage:** as decided in question 5.
- **Edges:** a coarse mask needs refining against the photo's own edges to look right on hair and
  leaves. Expect this to be the hard part.
- **Claude:** a tool that takes a point or a description of where to look, and returns the mask
  drawn over the photo so it can check.
- **Tests:** the mask pass with a stored mask; a stored mask surviving a restart and an export.

## Out of scope for now

Brushes, per-mask looks or shaders, and syncing masks anywhere outside the recipe.
