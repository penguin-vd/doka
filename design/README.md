# Design

Live canvas: https://claude.ai/artifact/FYDdyBbwBPCpK2RYcn4Mbn

These files are the canvas's source, for reference only. They use the canvas's own component format, so they won't open as plain web pages. Read them for layout, colours, spacing and type.

- `editor.dc.html`: the main editor. A folder sidebar with thumbnails, the photo in the middle, and the tool panel on the right.
- `claude-editing.dc.html`: Claude editing the open photo, with the Keep / Undo bar and before/after.
- `export.dc.html`: the export dialog with the metadata and GPS options.

The look in short: a dark, neutral grey UI so photo colours read true. IBM Plex Sans for UI text and IBM Plex Mono for numbers. One amber accent (`#E8B04B`), 44 px touch targets, and real buttons and inputs.

**The design is older than the spec.** It still shows a "Filters" tab and a recipe panel, and Claude's activity panel describes a CLI. Follow `SPEC.md`:

- The tabs are Adjust, Looks and Crop.
- Looks has a Shaders list and a collapsed Colour mixer.
- Claude connects over MCP.
