# Photo editor: hand-off

Everything Claude Code needs to start building.

| File | What it is |
| --- | --- |
| `PROMPT.md` | The prompt to paste into Claude Code to start |
| `SPEC.md` | The full build spec (source of truth) |
| `CLAUDE.md` | Project rules for Claude Code; keep it in the repo root |
| `design/` | UI design source and notes |
| `reference-photos/` | Three example photos, compressed, without EXIF |

## Start

1. Make a new project folder next to `oubliette`, for example `~/code/photo-editor`, and unzip this into it.
2. Open Claude Code in that folder.
3. Paste the prompt from `PROMPT.md`.
4. Once step 5 of the build is done, connect Claude Code to the running app:
   `claude mcp add --transport http photo http://127.0.0.1:7777/mcp`
