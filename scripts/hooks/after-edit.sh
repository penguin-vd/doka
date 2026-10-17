#!/bin/sh
# Claude Code's PostToolUse hook (.claude/settings.json): a .zig file Claude edits is formatted.
# Exit 2 hands the findings back to Claude.
cd "$(dirname "$0")/../.."
file=$(jq -r '.tool_input.file_path // empty')
case "$file" in
    *.zig) zig fmt "$file" >/dev/null 2>&1 || { zig fmt --check "$file" >&2; exit 2; } ;;
esac
exit 0
