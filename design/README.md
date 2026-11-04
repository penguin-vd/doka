# Design

Live canvas: https://claude.ai/artifact/FYDdyBbwBPCpK2RYcn4Mbn

These files are the canvas's source, for reference only. They use the canvas's own component format, so they won't open as plain web pages. Read them for layout, colours, spacing and type.

- `editor.dc.html`: the main editor. A folder sidebar with thumbnails, the photo in the middle, and the tool panel on the right.
- `claude-editing.dc.html`: Claude editing the open photo, with before/after, and a Keep / Undo bar the app no longer has.
- `export.dc.html`: the export dialog with the metadata and GPS options.

**The app's look has since moved on; the CSS in `src/main.zig` is the source of truth.** The photo is the only colour on screen: true neutral greys, white for "on" and "changed", IBM Plex Sans throughout, and controls sized for a mouse. These files still show the earlier amber look and 44 px touch targets.

**The design is older than the spec.** It still shows a "Filters" tab and a recipe panel, and Claude's activity panel describes a CLI. Follow `SPEC.md`:

- The tabs are Adjust, Looks and Crop.
- Looks has a Shaders list and a collapsed Colour mixer.
- Claude connects over MCP.
