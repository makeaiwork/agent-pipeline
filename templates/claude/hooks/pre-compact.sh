#!/bin/bash
# PreCompact hook (matcher auto|manual): saves a snapshot of the run state to a file,
# which session-start-compact.sh prints into the context after compaction.
#
# Why a file rather than "instructions for the summary": PreCompact CANNOT slip custom
# instructions to the compactor — its stdout goes only to the debug log, and exit 2
# merely blocks compaction (docs/hooks: "PreCompact | Yes | Blocks compaction").
# The only event input whose stdout actually reaches the context is SessionStart.
# So here we write the state to disk, and the SessionStart(compact) hook reads it.
#
# The snapshot does NOT retell file contents: only pointers — what lives where.

set -uo pipefail

INPUT=$(cat)
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "unknown"' 2>/dev/null)
SESSION=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_DIR" || exit 0

STATE_DIR="$PROJECT_DIR/.claude/state"
mkdir -p "$STATE_DIR"
OUT="$STATE_DIR/compact-context.md"

{
  echo "# Snapshot before compaction"
  echo
  echo "- when: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "- trigger: $TRIGGER"
  echo "- session: ${SESSION:-unknown}"
  echo

  echo "## Working tree (git status --short)"
  echo
  echo '```'
  git status --short 2>/dev/null | head -40
  echo '```'
  echo

  echo "## Recent commits"
  echo
  echo '```'
  git log --oneline -3 2>/dev/null
  echo '```'
  echo

  echo "## First open task in todo.md"
  echo
  grep -n -m 1 '^\s*- \[ \]' todo.md 2>/dev/null | cut -c1-400
  echo

  # Review reports of the current task: they are the round's "memory" that survives compaction.
  if [ -n "$SESSION" ]; then
    # macOS: /private/tmp; Linux: /tmp
    SCRATCH=$(find /private/tmp /tmp -maxdepth 4 -type d -path "*/$SESSION/scratchpad" 2>/dev/null | head -1)
    if [ -n "$SCRATCH" ]; then
      echo "## Task artifacts in scratchpad"
      echo
      echo "- directory: \`$SCRATCH\`"
      ls -1t "$SCRATCH" 2>/dev/null | head -12 | sed 's/^/- /'
      echo
    fi
  fi

  echo "## What to restore after compaction"
  echo
  echo "- the ID and phase of the current task — from \`todo.md\` and the \`review-*.md\` files above (the task worktree — \`git worktree list\`);"
  echo "- review verdicts — read them from \`review-*.md\`, do not reconstruct them from memory;"
  echo "- open decisions for the owner — from the header of \`claude-progress.md\` and from \`blockers.md\`."
} >"$OUT" 2>/dev/null

exit 0
