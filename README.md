# Doka

A small, fast photo editor for Linux that Claude Code can drive live: you ask in Claude Code, it
sees the photo you see and edits it. Three tools (Adjust, Looks, Crop), non-destructive recipes,
and exports that keep every bit of the camera's metadata. `SPEC.md` is the full spec.

## Build and run

Needs Zig 0.16.0 and the system's `libvips`, `gtk4` and OpenGL.

```sh
zig build -Doptimize=ReleaseSafe     # zig-out/bin/doka
./zig-out/bin/doka [folder]          # opens the folder, or the last one
scripts/starter-looks.py             # twelve film looks into ~/.config/doka/looks (once)
scripts/subject-model.py             # optional: click a subject to mask it (56 MB, once)
scripts/setup.sh                     # for development: the git pre-commit (tests and the GPU probe)
```

## Claude Code

While the app is open it serves MCP at `http://127.0.0.1:7777/mcp`. Once:

```sh
claude mcp add --transport http photo http://127.0.0.1:7777/mcp
```

Then ask in Claude Code, for example "make it more film-like". Claude's changes apply live and
Ctrl+Z undoes them. It can also open other photos, export, and write shaders (`save_shader`) or bake
its colour work into a new look (`bake_look`). If the app wasn't open, open it and run `/mcp`.

## Where things are

- Edits: `<folder>/.photo-editor/recipes/<photo>.json`, written as you edit. Delete one to reset
  the photo. Photos themselves are never written.
- Thumbnails: `<folder>/.photo-editor/thumbs/`.
- Looks (`.cube` LUTs) and shaders: `~/.config/doka/looks/` and `~/.config/doka/shaders/<name>/`
  (`shader.glsl` and `shader.json`); edits there show up at once.
- Exports: `~/Pictures/Doka/` unless you choose another folder; never over an earlier export.
- Settings: `~/.config/doka/settings.json`.

## Keys

| Key | |
| --- | --- |
| ← → | Previous / next photo |
| hold `\` | See the original |
| double-click the photo | 100% there, and back |
| ↑ ↓, with Shift ten steps | Nudge the slider you clicked |
| wheel over a slider's track, with Ctrl one step | Move it |
| Escape | Stop clicking a subject, back to the whole photo |
| Delete | Remove the picked mask |
| Ctrl+Z, Ctrl+Shift+Z or Ctrl+Y | Undo, redo |
| Ctrl+E | Export |
| Ctrl+O | Open folder |
| Ctrl/Shift-click a thumbnail | Pick several for export |
| double-click a slider or its name, or the Curve title | Reset it |

## Credits

Click-a-subject uses ONNX Runtime (MIT, Microsoft) and MobileSAM (Apache-2.0), downloaded by
`scripts/subject-model.py`, not kept in this repository.

The starter looks are converted from the RawTherapee Film Simulation Collection (CC BY-SA 4.0;
Pat David, Pavlov Dmitry, Michael Ezra). They're downloaded by `scripts/starter-looks.py`, not
kept in this repository; a `CREDITS.txt` goes beside them.
