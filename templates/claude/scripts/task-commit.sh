#!/bin/bash
# task-commit.sh — does the task already have a work commit (duplicate check before start).
#
# Run from any directory inside the repository (the task's worktree or the main checkout):
#   bash .claude/scripts/task-commit.sh --task-id <ID> [--base <ref>]
#
# Searches the history from <base> (HEAD by default) for a commit whose subject looks like
# `type(scope): <ID> …` — the ID comes RIGHT after `type(scope): ` (the @committer format guarantees it). A
# mention of the ID mid-subject or in the commit body is not a work commit. The token boundary is
# `[^0-9A-Za-z-]`: a hyphen is not a boundary, otherwise a parent ID matches child commits (`M-A3` ⊂ `M-A3-1`).
#
# A candidate is confirmed by its contents: a work commit is one that has at least one path outside the
# state files (todo.md, claude-progress.md, blockers.md), or whose diff moves the task line in todo.md
# to `[x]`. Otherwise it is a bookkeeping commit — the next candidate is examined.
#
# Prints exactly:
#   RESULT=DONE <hash>          # the task's work commit is found
#   RESULT=STATE <hash>         # no work commit, but there is a state commit `chore(todo): <ID> done in <hash>`
#   RESULT=NONE                 # neither one
#   RESULT=SKIP reason=<…>      # the ID contains characters outside [0-9A-Za-z-] — a history search is
#                               # impossible, decide by the todo.md line
#   TODO=open|closed|missing    # state of the `**<ID>.` line in the repository root's todo.md
# Changes nothing.

set -u

BASE=HEAD
TASK_ID=""
need_value() { [ $# -ge 2 ] || { echo "task-commit.sh: $1 has no value" >&2; exit 64; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --task-id) need_value "$@"; TASK_ID="$2"; shift 2 ;;
    --base)    need_value "$@"; BASE="$2"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "task-commit.sh: unknown argument $1" >&2; exit 64 ;;
  esac
done
[ -n "$TASK_ID" ] || { echo "task-commit.sh: --task-id is required" >&2; exit 64; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "task-commit.sh: not a git repository" >&2; exit 65; }
cd "$(git rev-parse --show-toplevel)" || exit 65
git rev-parse --verify -q "$BASE^{commit}" >/dev/null 2>&1 || { echo "task-commit.sh: base '$BASE' is not a commit" >&2; exit 65; }

# State of the line in todo.md
TODO=missing
if [ -f todo.md ]; then
  # only the task's own line (`- [ ] **ID.` / `- [x] **ID.`), not mentions of
  # `**ID.` inside other tasks' descriptions; the ID has not passed the whitelist yet — escape it for ERE
  id_re=$(printf '%s' "$TASK_ID" | sed 's/[][\.*^$?+(){}|/]/\\&/g')
  line=$(grep -E -- "^[[:space:]]*- \[[ x]\] \*\*${id_re}\." todo.md | head -1)
  if [ -n "$line" ]; then
    case "$line" in
      *'- [x]'*) TODO=closed ;;
      *)         TODO=open ;;
    esac
  fi
fi

case "$TASK_ID" in
  *[!0-9A-Za-z-]*)
    echo "RESULT=SKIP reason=ID contains characters outside [0-9A-Za-z-]"
    echo "TODO=$TODO"
    exit 0 ;;
esac

# === PROJECT-SPECIFIC (agent-pipeline init) — the same bookkeeping files as STATE_FILES in review-tier.sh ===
STATE_RE='^(todo\.md|claude-progress\.md|blockers\.md)$'
# === /PROJECT-SPECIFIC ===

is_work_commit() {
  local h="$1"
  # at least one path outside the state files
  if git show --format= --name-only "$h" | grep -qvE "$STATE_RE"; then
    return 0
  fi
  # or the task line in todo.md moves to [x]
  if git show "$h" -- todo.md | grep -qE "^\+.*\[x\] \*\*${TASK_ID}\."; then
    return 0
  fi
  return 1
}

FOUND=""
while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  h=${cand%% *}
  if is_work_commit "$h"; then FOUND=$h; break; fi
done < <(git log "$BASE" --format='%h %s' --grep="$TASK_ID" \
  | grep -E "^[0-9a-f]+ [a-z]+(\([^)]*\))?: ${TASK_ID}([^0-9A-Za-z-]|\$)" \
  | grep -vE "^[0-9a-f]+ chore\(todo\): ${TASK_ID} done in ")

if [ -n "$FOUND" ]; then
  echo "RESULT=DONE $FOUND"
  echo "TODO=$TODO"
  exit 0
fi

STATE=$(git log "$BASE" --format=%s --grep="chore(todo): ${TASK_ID} done in" -1 \
  | sed -nE "s/^chore\(todo\): ${TASK_ID} done in ([0-9a-f]+).*/\1/p")
if [ -n "$STATE" ]; then
  echo "RESULT=STATE $STATE"
else
  echo "RESULT=NONE"
fi
echo "TODO=$TODO"
exit 0
