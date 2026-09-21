#!/bin/bash
# active-session.sh — is there a SECOND active Claude Code session in this project.
#
# Run from the main checkout:
#   bash .claude/scripts/active-session.sh [--minutes N] [--dir <transcripts directory>] [--self <session-id>]
#
# By default the transcripts directory is ~/.claude/projects/<pwd with everything but [A-Za-z0-9] → '-'>,
# the "own" transcript is $CLAUDE_CODE_SESSION_ID (Claude Code sets it in every session's env),
# the window is 10 minutes (an integer). The old check "mtime of the second-freshest transcript is
# younger than 10 minutes" fired on a session the owner had just interrupted; here not only mtime is
# examined but also the LAST meaningful transcript record (`assistant`/`user`; service records
# last-prompt/atis-latch/ai-title/system are skipped). Subagent transcripts
# `<session>/subagents/*.jsonl` are checked too: while a task-runner works, the parent file is not
# updated for 20–30 minutes — without this a foreign /do-all would be invisible. A fresh subagent file
# only widens the window: its verdict is decided by the PARENT transcript `<session>.jsonl`
# (assistant tool_use = Agent in flight → ACTIVE; end_turn/interrupted → IDLE) — the subagent itself
# ends with a record without stop_reason in 7% of cases, so it alone cannot decide.
#
#   assistant, stop_reason end_turn / stop_sequence  → IDLE   (waits for a human; API limit/error)
#   user: text starts with "[Request interrupted by user" → IDLE (the owner interrupted the turn)
#   user: string "<command-name>…" / "<local-command-stdout>…" → IDLE (slash command: /mcp, /compact …)
#   assistant tool_use / max_tokens / no stop_reason    → ACTIVE (a turn is running or hangs on a permission)
#   user with tool_result / a fresh prompt              → ACTIVE (the session is working)
#
# Output: one `ACTIVE <file> — <why>` line per active session, then the total
# `RESULT=ACTIVE` (exit 10) or `RESULT=IDLE` (exit 0). `SKIPPED=…` — own and idle files,
# `WARN=…` — if the own transcript could not be determined from env (then the freshest top-level
# file is excluded — at call time it is almost certainly the own one). Writes nothing. Requires python3.

set -u

MINUTES=10
DIR=""
SELF="${CLAUDE_CODE_SESSION_ID:-}"
need_value() { [ $# -ge 2 ] || { echo "active-session.sh: $1 has no value" >&2; exit 64; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --minutes) need_value "$@"; MINUTES="$2"; shift 2 ;;
    --dir)     need_value "$@"; DIR="$2"; shift 2 ;;
    --self)    need_value "$@"; SELF="$2"; shift 2 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "active-session.sh: unknown argument $1" >&2; exit 64 ;;
  esac
done
case "$MINUTES" in
  ''|0|*[!0-9]*) echo "active-session.sh: --minutes must be an integer > 0, got '$MINUTES'" >&2; exit 64 ;;
esac

if [ -z "$DIR" ]; then
  slug=$(pwd | sed 's/[^A-Za-z0-9]/-/g')
  DIR="$HOME/.claude/projects/$slug"
fi
if [ ! -d "$DIR" ]; then
  echo "SKIPPED=transcripts directory not found: $DIR"
  echo "RESULT=IDLE"
  exit 0
fi
command -v python3 >/dev/null 2>&1 || { echo "active-session.sh: python3 is required" >&2; exit 65; }

WARN=""
if [ -z "$SELF" ]; then
  # Fallback: the freshest top-level transcript is the own one (its last record is this call).
  newest=$(ls -t "$DIR"/*.jsonl 2>/dev/null | head -1)
  if [ -n "$newest" ]; then
    SELF=$(basename "$newest" .jsonl)
    WARN="CLAUDE_CODE_SESSION_ID is not set — the freshest transcript $SELF is treated as own (heuristic)"
  fi
fi

# classify <file> → prints `ACTIVE <why>` or `IDLE <why>`
classify() {
  # 4 MB tail: enough for any last record; decoding with 'replace' — tail -c can cut a UTF-8
  # character in half, and the first (truncated) line is dropped as non-JSON anyway.
  tail -c 4194304 "$1" | python3 -c '
import sys, json
data = sys.stdin.buffer.read().decode("utf-8", "replace")
last = None
for raw in reversed(data.split("\n")):
    raw = raw.strip()
    if not raw:
        continue
    try:
        d = json.loads(raw)
    except Exception:
        continue
    if not isinstance(d, dict) or d.get("type") not in ("assistant", "user"):
        continue
    last = d
    break
if last is None:
    print("ACTIVE no assistant/user record in tail")
    sys.exit(0)
m = last.get("message") or {}
if last.get("type") == "assistant":
    sr = m.get("stop_reason")
    if sr in ("end_turn", "stop_sequence"):
        print("IDLE %s" % sr)
    else:
        print("ACTIVE assistant stop_reason=%s" % sr)
    sys.exit(0)
c = m.get("content")
if isinstance(c, str):
    s = c.lstrip()
    if s.startswith("<command-name>") or s.startswith("<local-command-stdout>") or s.startswith("<local-command-caveat>"):
        print("IDLE local command")
    else:
        print("ACTIVE user prompt")
    sys.exit(0)
kinds = set()
interrupted = False
if isinstance(c, list):
    for b in c:
        if not isinstance(b, dict):
            continue
        kinds.add(b.get("type"))
        if b.get("type") == "text" and (b.get("text") or "").lstrip().startswith("[Request interrupted by user"):
            interrupted = True
if "tool_result" in kinds:
    print("ACTIVE user tool_result")
elif interrupted:
    print("IDLE interrupted")
else:
    print("ACTIVE user prompt")
'
}

ACTIVE=0
CHECKED=0
SKIPPED=""
SEEN=" "
# Fresh transcripts: top level first, then subagents. A subagent's session = the name of the
# parent directory; each session is evaluated once.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  rel=${f#"$DIR"/}
  case "$rel" in
    */subagents/*) sid=${rel%%/*} ;;
    *)             sid=$(basename "$f" .jsonl) ;;
  esac
  if [ -n "$SELF" ] && [ "$sid" = "$SELF" ]; then
    SKIPPED="$SKIPPED self:$rel"
    continue
  fi
  case "$SEEN" in *" $sid "*) continue ;; esac   # the session was already evaluated by another file
  SEEN="$SEEN$sid "
  CHECKED=$((CHECKED + 1))
  case "$rel" in
    */subagents/*)
      # By the parent, regardless of its mtime. Consequence: a subagent started in the background that
      # outlives the parent's end_turn counts as IDLE — in this project the runner's subagents are
      # synchronous only. No parent (an anomaly) — by the file itself.
      if [ -f "$DIR/$sid.jsonl" ]; then
        verdict=$(classify "$DIR/$sid.jsonl")
        verdict="$verdict (by parent $sid.jsonl)"
      else
        verdict=$(classify "$f")
      fi ;;
    *) verdict=$(classify "$f") ;;
  esac
  case "$verdict" in
    ACTIVE*) ACTIVE=$((ACTIVE + 1)); echo "ACTIVE $f — ${verdict#ACTIVE }" ;;
    IDLE*)   SKIPPED="$SKIPPED idle:$rel(${verdict#IDLE })" ;;
    *)       ACTIVE=$((ACTIVE + 1)); echo "ACTIVE $f — classifier gave no answer (treated as active)" ;;
  esac
done < <( { find "$DIR" -maxdepth 1 -name '*.jsonl' -mmin "-$MINUTES"; \
            find "$DIR" -mindepth 3 -maxdepth 3 -path '*/subagents/*.jsonl' -mmin "-$MINUTES"; } 2>/dev/null )

[ -n "$WARN" ] && echo "WARN=$WARN"
[ -n "$SKIPPED" ] && echo "SKIPPED=${SKIPPED# }"
echo "CHECKED=$CHECKED"
if [ "$ACTIVE" -gt 0 ]; then
  echo "RESULT=ACTIVE"
  exit 10
fi
echo "RESULT=IDLE"
exit 0
