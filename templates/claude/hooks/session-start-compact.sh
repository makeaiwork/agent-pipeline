#!/bin/bash
# SessionStart hook, matcher compact. Prints the repository state after compaction,
# so that the state files need not be re-read in full. Read-only, changes nothing.

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_DIR" || exit 0

SNAPSHOT="$PROJECT_DIR/.claude/state/compact-context.md"

echo "=== State after compaction (session-start-compact.sh) ==="
echo

if [ -f "$SNAPSHOT" ]; then
  echo "## Snapshot taken before compaction"
  echo
  head -60 "$SNAPSHOT"
  echo
fi

echo "## Tree now"
echo
git status --short 2>/dev/null | head -40
echo

echo "## Recent commits"
echo
git log --oneline -3 2>/dev/null
echo

echo "## First open task in todo.md"
echo
grep -n -m 1 '^\s*- \[ \]' todo.md 2>/dev/null | cut -c1-400
echo

echo "## Header of claude-progress.md"
echo
head -30 claude-progress.md 2>/dev/null

exit 0
