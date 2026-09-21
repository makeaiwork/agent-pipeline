#!/bin/bash
# PostToolUse(Edit|Write) hook: auto-formats the edited file.
# The formatter and the extension mask come from the PROJECT block; no formatter — the hook does nothing.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
if [ -z "$FILE_PATH" ] || [ "$FILE_PATH" = "null" ]; then
  exit 0
fi

# === PROJECT-SPECIFIC (agent-pipeline init) ===
# FORMAT_CMD is run as `$FORMAT_CMD "$FILE_PATH"`; an empty string — no formatting.
# Examples: "npx prettier --write" (js/ts/css/json/md), "ruff format" (py), "gofmt -w" (go), "cargo fmt --" (rs).
FORMAT_CMD="{{FORMAT_CMD}}"
FORMAT_EXT_RE='\.(js|ts|jsx|tsx|css|scss|json|md|html|vue|svelte)$'
FORMAT_BIN_CHECK="node_modules/.bin/prettier"   # a file whose presence confirms the formatter is installed; empty — do not check
# === /PROJECT-SPECIFIC ===

[ -n "$FORMAT_CMD" ] || exit 0
case "$FORMAT_CMD" in *'{{'*) exit 0 ;; esac   # placeholder not substituted — skip silently
if [ -n "$FORMAT_BIN_CHECK" ] && [ ! -f "$FORMAT_BIN_CHECK" ]; then
  exit 0
fi
if echo "$FILE_PATH" | grep -qE "$FORMAT_EXT_RE"; then
  $FORMAT_CMD "$FILE_PATH" 2>/dev/null || true
fi
exit 0
