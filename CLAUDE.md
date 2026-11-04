# CLAUDE.md

A small, fast Linux photo editor in Zig, with a GTK 4 UI, a GLSL processing pipeline and a built-in MCP server so Claude Code can edit the open photo live. `SPEC.md` is the source of truth; read it before changing anything structural.

## Hard rules

- **Never modify original photos.** All edits are recipes in `<root>/.photo-editor/`. Exports go to a separate file.
- **Never strip metadata.** Camera, lens, exposure, date and ICC profile must survive every export. GPS is removed only when the user explicitly unticks it.
- Tests that export write to ~/Pictures/Doka by default: delete what a test run left there.
- **The real photo library is read-only during development.** The owner's photos are in `/mnt/games/Pictures` (dated subfolders of Olympus E-P7 JPEGs; confirmed 2026-10-17). Tests and experiments copy photos into a temp folder first; never write into the library, not even `.photo-editor/`, unless the owner runs the app on it.
- **Keep it simple.** No new tools, tabs, dependencies or frameworks beyond the spec without asking.

## Run

```sh
zig build run          # the editor (zig-out/bin/doka: GTK 4 and OpenGL)
zig build test         # unit tests (the app's, and photo-core's as a second binary)
zig build probe        # no window: the pipeline's tests on the GPU, and an export's metadata (src/app/selftest.zig)
zig build -Doptimize=ReleaseSafe   # the build to actually use: a plain `zig build` is a slower debug one
./zig-out/bin/doka photo.jpg --check out.ppm   # no window: the photo through the pipeline, as a picture
                       # never open a visible window: the owner tests the window on their own screen
scripts/setup.sh       # once per clone: git's pre-commit (format, changelog, test, probe)
scripts/starter-looks.py   # twelve film looks into ~/.config/doka/looks (downloads 420 MB once)
scripts/subject-model.py   # click-a-subject's ONNX Runtime and model into ~/.config/doka/models (56 MB once)
```

Layout: `src/main.zig` is the window; `src/app/` the rest of the editor (`app.zig` the state with no window,
`pipeline.zig` image passes over `glsl/`, `canvas.zig` the photo, `sidebar.zig`, `slider.zig`, `looks_panel.zig`,
`masks_panel.zig`, `subject.zig` (click a subject), `export_dialog.zig`, `exporter.zig`, `tools.zig` and `mcp.zig` Claude's side, `gtk.zig` and `gl.zig` the C APIs by hand).
`src/core/` is `photo-core` (libvips, no window: `decode`, `encode` + `exif`, `Recipe`,
`store`; its tests need `testdata/photos/` and skip without it).
C APIs are declared by hand in Zig (`src/app/gtk.zig`, `src/app/gl.zig`, the `c` struct in `src/core/vips.zig`), only
what we call: Zig 0.16's translate-c can't read GLib's headers. Add a declaration when you need a call.

Pipeline: `src/app/pipeline.zig` runs `src/app/glsl/` for the preview, thumbnails, screenshots and export
alike; new image maths goes there, with a test in `src/app/selftest.zig`. GTK gives OpenGL ES 3.2 here;
keep to what's in both ES 3.0 and desktop 4.1 (a Mac's limit), and the shader version line follows the context.

UI: the look is one CSS string in `src/main.zig`: neutral greys only (R = G = B), white for "on" and
"changed"; the photo is the only colour on screen. No new frameworks.

## Zig setup

- Follow `../oubliette` for everything Zig: the pinned Zig version, `build.zig` / `build.zig.zon` structure, project layout, formatting, testing and any CI or tooling. Read it first; copy its conventions; never modify it.
- AI tools often write older Zig syntax. When the compiler disagrees with you, trust the compiler and the pinned version's std library source.
- C libraries come in through the build system: libvips, GTK 4, OpenGL.

## System dependencies (Debian names)

`libvips-dev`, `libgtk-4-dev`, `libopengl-dev`

## Machine notes

- Target: Linux, NVIDIA RTX 3080 with the proprietary driver.
- GTK 4 here runs on OpenGL ES and refuses a desktop OpenGL context: don't set a required version on the GL area.
- The desktop is Hyprland: screenshot the app window with `grim -g "$(hyprctl clients -j | jq -r '.[] | select(.title=="Doka") | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"')" out.png`.
- The pipeline needs float render targets (`EXT_color_buffer_float` on OpenGL ES): `zig build probe` checks it.

## Working style

- Follow the build order in `SPEC.md`, one step at a time. After each step: build, run the tests, and give a short summary of what works and what doesn't. Commit only when the owner says so.
- Test with real JPEGs (copies from the photo library on `/mnt/games`). The EXIF round-trip test is mandatory from step 2 on.
- `reference-photos/` shows the kind of photos this is for. Those copies lost their EXIF in transfer, so don't use them for metadata tests.
- Preview and export share the same shaders. Never add a second implementation of the image maths.
- MCP: localhost only (127.0.0.1:7777), reject requests that carry a browser `Origin` header.

## Git

- Conventional prefixes: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`. One line, no
  body, no trailers, never `Co-Authored-By`.
- Every commit updates `docs/changelog.md` (the pre-commit checks it).
