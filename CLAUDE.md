# CLAUDE.md

A small, fast Linux photo editor in Zig, with a webview UI, a GLSL processing pipeline and a built-in MCP server so Claude Code can edit the open photo live. `SPEC.md` is the source of truth; read it before changing anything structural.

## Hard rules

- **Never modify original photos.** All edits are recipes in `<root>/.photo-editor/`. Exports go to a separate file.
- **Never strip metadata.** Camera, lens, exposure, date and ICC profile must survive every export. GPS is removed only when the user explicitly unticks it.
- **The real photo library is read-only during development.** The owner's photos are in `/mnt/games/Pictures` (dated subfolders of Olympus E-P7 JPEGs; confirmed 2026-10-17). Tests and experiments copy photos into a temp folder first; never write into the library, not even `.photo-editor/`, unless the owner runs the app on it.
- **Keep it simple.** No new tools, tabs, dependencies or frameworks beyond the spec without asking.

## Run

```sh
zig build run          # the editor
zig build test         # unit tests (the app's, and photo-core's as a second binary)
zig build probe        # opens the window hidden, checks WebGL2 float render targets, quits; fails without them
scripts/setup.sh       # once per clone: git's pre-commit (format, changelog, test, probe)
```

Layout: `src/core/` is `photo-core` (libvips, no window); `src/app/` the window, its C bindings
(`c.zig`) and the page's files (`ui.zig`); `ui/` the page (HTML, `style.css`, TypeScript).
C APIs are declared by hand in Zig (`src/app/c.zig`, the `c` struct in `src/core/vips.zig`), only
what we call: Zig 0.16's translate-c can't read GLib's headers. Add a declaration when you need a call.

UI: colours, type and sizes are tokens on `:root` in `ui/style.css`; components are classes there
(`.bar`, `.btn`, ...). Use them; no inline colours, no new frameworks. TypeScript is only type-stripped
(Node, no packages): erasable syntax only, no `enum` or `namespace`.

## Zig setup

- Follow `../oubliette` for everything Zig: the pinned Zig version, `build.zig` / `build.zig.zon` structure, project layout, formatting, testing and any CI or tooling. Read it first; copy its conventions; never modify it.
- AI tools often write older Zig syntax. When the compiler disagrees with you, trust the compiler and the pinned version's std library source.
- C libraries come in through `@cImport` and the build system: libvips, webview (compiled from source; needs C++11), WebKitGTK 4.1 + GTK 3.

## System dependencies (Debian names)

`libvips-dev`, `libgtk-3-dev`, `libwebkit2gtk-4.1-dev`

## Machine notes

- Target: Linux, NVIDIA RTX 3080 with the proprietary driver.
- Without `WEBKIT_DISABLE_DMABUF_RENDERER=1` the window dies at once on Hyprland (Wayland) with Gdk "Error 71"; `Window.init` sets it.
- The desktop is Hyprland: screenshot the app window with `grim -g "$(hyprctl clients -j | jq -r '.[] | select(.title=="Doka") | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"')" out.png`.
- WebKit reports the WebGL renderer as "Apple GPU" (anti-fingerprinting); the real driver shows in `/proc/<WebKitWebProcess>/maps` (`libnvidia-glcore`).
- The pipeline needs WebGL2 with float render targets (`EXT_color_buffer_float`). Verify this in build step 1 before building on it.

## Working style

- Follow the build order in `SPEC.md`, one step at a time. After each step: build, run the tests, commit, and give a short summary of what works and what doesn't.
- Test with real JPEGs (copies from the photo library on `/mnt/games`). The EXIF round-trip test is mandatory from step 2 on.
- `reference-photos/` shows the kind of photos this is for. Those copies lost their EXIF in transfer, so don't use them for metadata tests.
- Preview and export share the same shaders. Never add a second implementation of the image maths.
- MCP: localhost only (127.0.0.1:7777), reject requests that carry a browser `Origin` header.

## Git

- Conventional prefixes: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`. One line, no
  body, no trailers, never `Co-Authored-By`.
- Every commit updates `docs/changelog.md` (the pre-commit checks it).
