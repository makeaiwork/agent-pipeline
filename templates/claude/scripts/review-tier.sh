#!/bin/bash
# review-tier.sh — review tier of a task from its diff (agent-pipeline).
#
# Run from any directory inside the task's worktree (or the main checkout in manual mode):
#   bash .claude/scripts/review-tier.sh [--task-id <ID>] [--base <ref>]
#   bash .claude/scripts/review-tier.sh --task "<full task line>"     # alternative
#
# `--task-id T-1` — the script itself takes the `**T-1.` line from todo.md in the repository root and
# looks for the `[review: Rn]` marker in it (legacy alias: `[ревью: Rn]`); this is the main form: a full
# task line in a Bash argument breaks on single quotes and can trip the safety-check hook (the task
# text may contain names of protected files and dangerous commands).
#
# Reads tracked changes against <base> (`git diff --numstat`, HEAD by default) and untracked files
# (`git ls-files --others --exclude-standard`), changes nothing. Prints exactly this:
#
#   TIER=R0|R1|R2|R3
#   CODEX=none|<effort>          # Codex effort in BOTH rounds (by tier, see the PROJECT block); R0 — not called
#   CODEX_MODEL=none|<model>     # Codex model — the single source for agents, never hardcoded in prompts
#   ROUND1=none|single|double    # round 1: single — one @codex-reviewer; double — @reviewer ‖ @codex-reviewer (+ consolidator)
#   ROUND2=none|light|escalate|double   # round 2 (only on confirmed S1/S2): light — one Codex verify;
#                                       # escalate — Codex verify ‖ full @reviewer; double — both in verify mode
#   CONSOLIDATOR=yes|no          # with ROUND1=double: yes — @review-consolidator merges both reports; no — the runner merges them itself
#   PROFILE=standard|strict|light
#   BACKEND=both|claude|codex    # who reviews: claude — CODEX=none, @reviewer takes the Codex slots; codex — no Claude reader
#   REASON=<why this tier>
#   WARN=<only if the [review: Rn] marker lowered the tier while critical paths are touched>
#   FILES=<n> LINES=<n> CRITICAL=<comma-separated paths or none>
#
# Rules — in order, first match wins:
#   1. `[review: R0|R1|R2|R3]` marker in the task line → that tier (WARN on critical paths and tier < R3);
#   2. diff is empty → R1 (@codex-reviewer evaluates the research output);
#   3. all paths ∈ {todo.md, claude-progress.md, blockers.md} → R0;
#   4. at least one path is critical (see CRITICAL_GLOBS) → R3;
#   5. docs-only (all paths *.md or docs/**): ≤ DOCS_R0_MAX_LINES lines → R0, otherwise R1;
#   6. code: ≤ CODE_R1_MAX_FILES files AND ≤ CODE_R1_MAX_LINES lines → R1, otherwise R2.
#
# The only place where the critical paths list and the thresholds live: agents refer here, never duplicate.

set -u

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
BASE=HEAD
TASK=""
TASK_ID=""
need_value() { [ $# -ge 2 ] || { echo "review-tier.sh: $1 has no value" >&2; exit 64; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --task)    need_value "$@"; TASK="$2"; shift 2 ;;
    --task-id) need_value "$@"; TASK_ID="$2"; shift 2 ;;
    --base)    need_value "$@"; BASE="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$SELF"; exit 0 ;;
    *) echo "review-tier.sh: unknown argument $1" >&2; exit 64 ;;
  esac
done

# === PROJECT-SPECIFIC (agent-pipeline init) — the only place the skill edits on deployment ===
# Tier thresholds. Revisit them from .claude/state/runs.log (fields tier/rounds/found) after ~20 tasks.
DOCS_R0_MAX_LINES=20     # docs-only diff up to this size — R0 (no review)
CODE_R1_MAX_FILES=2      # code ≤ N files AND ≤ M lines — R1
CODE_R1_MAX_LINES=60
BINARY_LINES=1000        # a binary file counts as "large"

# Codex: model and effort by tier. Agents take them ONLY from this script's output (CODEX_MODEL=, CODEX=).
# The current model catalog is ~/.codex/models_cache.json. Changing the model is one constant here.
CODEX_MODEL="gpt-5.6-sol"
CODEX_EFFORT_R12="high"  # R1/R2, both rounds
CODEX_EFFORT_R3="xhigh"  # R3, both rounds

# Review strictness profile (init interview, the "strictness" question): standard | strict | light.
#   standard — round 1: R1/R2 one Codex, R3 @reviewer ‖ Codex + consolidator; round 2 is light everywhere (one Codex verify).
#   strict   — round 1: R2 and R3 double + consolidator; round 2: R1/R2 escalate to double, R3 double verify.
#   light    — R1 no review; R2 one Codex; R3 @reviewer ‖ Codex without a consolidator (CONSOLIDATOR=no, the runner merges); round 2 light.
REVIEW_PROFILE="standard"
# Who reviews: both — Codex primary + a Claude reader on double; claude — Codex is not called, @reviewer
# takes its place everywhere (double → single, no consolidator); codex — no Claude reader (double → single).
REVIEW_BACKEND="both"

# Critical paths → always R3. Bash `case` globs. A mistake here costs money, rights, access, data or prod.
# Always keep: migrations/schema, auth, payments, deploy/CI, `.claude/*` (pipeline code, even .md).
CRITICAL_GLOBS=(
  '.claude/*'                         # pipeline code
  '.worktreeinclude'
  # {{CRITICAL_GLOBS}}                # ← init substitutes the project's paths: auth, payments, schema/migrations, deploy, CI
)
# Bookkeeping files: only they are in the diff → R0; they do not count toward the thresholds.
STATE_FILES=('todo.md' 'claude-progress.md' 'blockers.md')
# === /PROJECT-SPECIFIC ===

is_critical() {
  local p="$1" g
  for g in "${CRITICAL_GLOBS[@]}"; do
    # shellcheck disable=SC2254
    case "$p" in $g) return 0 ;; esac
  done
  return 1
}
is_state() {
  local p="$1" s
  for s in "${STATE_FILES[@]}"; do [ "$p" = "$s" ] && return 0; done
  return 1
}
is_doc() {
  local p="$1"
  case "$p" in *.md|docs/*) return 0 ;; esac
  return 1
}

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "review-tier.sh: not a git repository" >&2; exit 65; }
cd "$(git rev-parse --show-toplevel)" || exit 65
git rev-parse --verify -q "$BASE^{commit}" >/dev/null 2>&1 || { echo "review-tier.sh: base '$BASE' is not a commit" >&2; exit 65; }

# Task line by ID — from todo.md in the repository root
if [ -n "$TASK_ID" ]; then
  if [ -f todo.md ]; then
    # only the task's own line (`- [ ] **ID.`), not mentions of `**ID.` in other tasks' descriptions
    id_re=$(printf '%s' "$TASK_ID" | sed 's/[][\.*^$?+(){}|/]/\\&/g')
    TASK=$(grep -E -- "^[[:space:]]*- \[[ x]\] \*\*${id_re}\." todo.md | head -1)
  fi
  [ -n "$TASK" ] || echo "review-tier.sh: task line ${TASK_ID} not found in todo.md — marker not applied" >&2
fi

# ---- Path set: tracked changes against BASE + untracked (without ignored ones).
# bash 3.2 (macOS): no associative arrays — two parallel indexed ones.
PATHS=()
PLINES=()
while IFS=$'\t' read -r add del path; do
  [ -z "${path:-}" ] && continue
  PATHS+=("$path")
  if [ "$add" = "-" ] || [ "$del" = "-" ]; then
    PLINES+=("$BINARY_LINES")
  else
    PLINES+=("$((add + del))")
  fi
done < <(git -c core.quotePath=false diff "$BASE" --numstat --no-renames -- . 2>/dev/null)

while IFS= read -r path; do
  [ -z "$path" ] && continue
  [ -f "$path" ] || continue
  PATHS+=("$path")
  if [ ! -s "$path" ] || grep -qI . "$path" 2>/dev/null; then
    # grep -c '' also counts a last line without a trailing newline (wc -l loses it)
    n=$(grep -c '' "$path" 2>/dev/null)   # grep -c returns 1 on zero lines (empty file) — the exit code is not an error sign
    PLINES+=("${n:-0}")
  else
    PLINES+=("$BINARY_LINES")
  fi
done < <(git -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null)

FILES=${#PATHS[@]}
TOTAL=0
CRITICAL=()
ALL_STATE=1
ALL_DOCS=1
i=0
while [ "$i" -lt "$FILES" ]; do
  p="${PATHS[$i]}"
  TOTAL=$((TOTAL + PLINES[$i]))
  is_critical "$p" && CRITICAL+=("$p")
  is_state "$p" || ALL_STATE=0
  is_doc "$p" || ALL_DOCS=0
  i=$((i + 1))
done
CRIT_STR="none"
[ ${#CRITICAL[@]} -gt 0 ] && CRIT_STR=$(IFS=,; echo "${CRITICAL[*]}")

# ---- Override marker in the task line (both spellings accepted, see the header)
OVERRIDE=""
if [ -n "$TASK" ]; then
  OVERRIDE=$(printf '%s' "$TASK" | grep -oE '\[(review|ревью): *R[0-3]\]' | head -1 | grep -oE 'R[0-3]' || true)
fi

TIER=""
REASON=""
WARN=""
if [ -n "$OVERRIDE" ]; then
  TIER=$OVERRIDE
  REASON="marker [review: $OVERRIDE] in task line; auto would be: $( bash "$SELF" --base "$BASE" | sed -n 's/^TIER=//p' )"
  if [ "$CRIT_STR" != "none" ] && [ "$TIER" != "R3" ]; then
    WARN="marker lowered tier below R3 while critical paths touched: $CRIT_STR"
  fi
elif [ "$FILES" -eq 0 ]; then
  TIER=R1; REASON="empty diff: reviewer evaluates research output"
elif [ "$ALL_STATE" -eq 1 ]; then
  TIER=R0; REASON="state files only ($FILES files)"
elif [ "$CRIT_STR" != "none" ]; then
  TIER=R3; REASON="critical paths: $CRIT_STR"
elif [ "$ALL_DOCS" -eq 1 ]; then
  if [ "$TOTAL" -le "$DOCS_R0_MAX_LINES" ]; then
    TIER=R0; REASON="docs-only, $FILES files, $TOTAL lines (<= $DOCS_R0_MAX_LINES)"
  else
    TIER=R1; REASON="docs-only, $FILES files, $TOTAL lines (> $DOCS_R0_MAX_LINES)"
  fi
elif [ "$FILES" -le "$CODE_R1_MAX_FILES" ] && [ "$TOTAL" -le "$CODE_R1_MAX_LINES" ]; then
  TIER=R1; REASON="code: $FILES files, $TOTAL lines (<= $CODE_R1_MAX_FILES files and <= $CODE_R1_MAX_LINES lines); critical: none"
else
  TIER=R2; REASON="code: $FILES files, $TOTAL lines; critical: none"
fi

# ---- Review composition by tier and profile
case "$TIER" in
  R0) CODEX=none; ROUND1=none; ROUND2=none ;;
  R1) CODEX=$CODEX_EFFORT_R12; ROUND1=single; ROUND2=light ;;
  R2) CODEX=$CODEX_EFFORT_R12; ROUND1=single; ROUND2=light ;;
  R3) CODEX=$CODEX_EFFORT_R3;  ROUND1=double; ROUND2=light ;;
esac
case "$REVIEW_PROFILE" in
  strict)
    case "$TIER" in
      R1) ROUND2=escalate ;;
      R2) ROUND1=double; ROUND2=double ;;
      R3) ROUND2=double ;;
    esac ;;
  light)
    case "$TIER" in
      R1) CODEX=none; ROUND1=none; ROUND2=none ;;
    esac ;;
  standard|*) ;;
esac
CONSOLIDATOR=no
[ "$ROUND1" = "double" ] && [ "$REVIEW_PROFILE" != "light" ] && CONSOLIDATOR=yes
case "$REVIEW_BACKEND" in
  claude) [ "$ROUND1" != "none" ] && CODEX=none
          [ "$ROUND1" = "double" ] && ROUND1=single
          case "$ROUND2" in escalate|double) ROUND2=light ;; esac
          CONSOLIDATOR=no ;;
  codex)  [ "$ROUND1" = "double" ] && ROUND1=single
          case "$ROUND2" in escalate|double) ROUND2=light ;; esac
          CONSOLIDATOR=no ;;
  both|*) ;;
esac
MODEL_OUT=$CODEX_MODEL
[ "$CODEX" = "none" ] && MODEL_OUT=none

echo "TIER=$TIER"
echo "CODEX=$CODEX"
echo "CODEX_MODEL=$MODEL_OUT"
echo "ROUND1=$ROUND1"
echo "ROUND2=$ROUND2"
echo "CONSOLIDATOR=$CONSOLIDATOR"
echo "PROFILE=$REVIEW_PROFILE"
echo "BACKEND=$REVIEW_BACKEND"
echo "REASON=$REASON"
[ -n "$WARN" ] && echo "WARN=$WARN"
echo "FILES=$FILES LINES=$TOTAL CRITICAL=$CRIT_STR"
exit 0
