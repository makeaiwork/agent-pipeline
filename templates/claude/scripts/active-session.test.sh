#!/bin/bash
# Regression test of active-session.sh on transcript fixtures in a temporary directory.
# Run from the repository root:  bash .claude/scripts/active-session.test.sh
# exit 0 — the matrix is green, exit 1 — there are mismatches.

SCRIPT="$(cd "$(dirname "$0")" && pwd)/active-session.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/active-session-test.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "TMP is empty" >&2; exit 1; }
cleanup() { [ -d "$TMP" ] && find "$TMP" -depth -delete 2>/dev/null; }
trap cleanup EXIT

PASS=0; FAIL=0
META='{"type":"last-prompt","lastPrompt":"x"}
{"type":"atis-latch","value":1}'

# fixture <name> <kind> — writes $TMP/d/<name>.jsonl; kind: end_turn | interrupted | tool_use | tool_result | prompt | meta_only | garbage
fixture() {
  local f="$TMP/d/$1.jsonl"
  mkdir -p "$TMP/d"
  {
    echo '{"type":"user","message":{"role":"user","content":"start"}}'
    case "$2" in
      end_turn)    echo '{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}'; echo "$META" ;;
      interrupted) echo '{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}'
                   echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}'; echo "$META" ;;
      tool_use)    echo '{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}'; echo "$META" ;;
      tool_result) echo '{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}'
                   echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]}}' ;;
      prompt)      echo '{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}'
                   echo '{"type":"user","message":{"role":"user","content":"do some more"}}' ;;
      meta_only)   echo "$META" ;;
      garbage)     echo '{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[]}}'; echo '{"broken json' ;;
      stop_seq)    echo '{"type":"assistant","message":{"role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"You have hit your session limit"}]}}' ;;
      slash_cmd)   echo '{"type":"user","message":{"role":"user","content":"<command-name>/mcp</command-name>\n<command-message>mcp</command-message>"}}'
                   echo '{"type":"system","subtype":"local_command","content":"x"}' ;;
      slash_out)   echo '{"type":"user","message":{"role":"user","content":"<local-command-stdout>Compacted</local-command-stdout>"}}' ;;
      tr_interrupt) echo '{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Read","input":{}}]}}'
                   echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"… \"Request interrupted\" (the owner interrupted) …"}]}}' ;;
      interrupted_prompt) echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}' ;;
      utf8_split)  # before a whole tool_use record — a long run of 2-byte characters, so that the 4 MB tail starts inside a character
                   python3 -c "import sys; sys.stdout.write('{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"' + '\u00e9'*2200000 + '\"}}\n')"
                   echo '{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}' ;;
      null_text)   echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]}}'
                   echo '{"type":"assistant","message":{"role":"assistant","stop_reason":null,"content":[{"type":"text","text":"### Verdict: APPROVE"}]}}' ;;
      big_end)     # a last end_turn record of ~1 MB (fits into the 4 MB tail)
                   python3 -c "import sys; sys.stdout.write('{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"' + 'a'*1000000 + '\"}]}}\n')" ;;
    esac
  } > "$f"
}
reset() { [ -d "$TMP/d" ] && find "$TMP/d" -depth -delete 2>/dev/null; mkdir -p "$TMP/d"; }

# expect <name> <IDLE|ACTIVE> [extra args…]
expect() {
  local name="$1" want="$2"; shift 2
  local out rc got
  out=$(bash "$SCRIPT" --dir "$TMP/d" "$@" 2>&1); rc=$?
  got=$(printf '%s\n' "$out" | sed -n 's/^RESULT=//p')
  if [ "$got" = "$want" ] && { { [ "$want" = "ACTIVE" ] && [ $rc -eq 10 ]; } || { [ "$want" = "IDLE" ] && [ $rc -eq 0 ]; }; }; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL: $name — expected $want, got '$got' (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

# 1. empty directory → IDLE
reset; expect "empty dir" IDLE
# 2. no directory → IDLE
expect "missing dir" IDLE --dir "$TMP/nope"
# 3. finished session (end_turn + service records after it) → IDLE
reset; fixture a end_turn; expect "end_turn" IDLE
# 4. interrupted by the owner → IDLE
reset; fixture a interrupted; expect "interrupted" IDLE
# 5. hangs on tool_use → ACTIVE
reset; fixture a tool_use; expect "tool_use" ACTIVE
# 6. tool_result (the assistant is working) → ACTIVE
reset; fixture a tool_result; expect "tool_result" ACTIVE
# 7. a fresh human prompt → ACTIVE
reset; fixture a prompt; expect "fresh prompt" ACTIVE
# 8. old transcript (mtime 30 min) with tool_use → IDLE (outside the window)
reset; fixture a tool_use; touch -t "$(date -v-30M +%Y%m%d%H%M.%S 2>/dev/null || date -d '30 min ago' +%Y%m%d%H%M.%S)" "$TMP/d/a.jsonl"; expect "old tool_use" IDLE
# 9. the own transcript is excluded by --self
reset; fixture me tool_use; expect "self excluded" IDLE --self me
# 10. own + a foreign active one → ACTIVE
reset; fixture me tool_use; fixture other tool_result; expect "self + other active" ACTIVE --self me
# 11. the own one is excluded by CLAUDE_CODE_SESSION_ID
reset; fixture me tool_use; out=$(CLAUDE_CODE_SESSION_ID=me bash "$SCRIPT" --dir "$TMP/d"); if printf '%s\n' "$out" | grep -q '^RESULT=IDLE$'; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: env self"; printf '%s\n' "$out"; fi
# 12. service records only → ACTIVE (conservative)
reset; fixture a meta_only; expect "meta only" ACTIVE
# 13. a truncated last line does not break parsing: the last whole one is end_turn → IDLE
reset; fixture a garbage; expect "garbage tail" IDLE
# 14. several: one idle, one active → ACTIVE
reset; fixture a end_turn; fixture b tool_use; expect "mixed" ACTIVE
# 15. narrow window: a 3-minute-old transcript with --minutes 2 → IDLE, with --minutes 5 → ACTIVE
reset; fixture a tool_use; touch -t "$(date -v-3M +%Y%m%d%H%M.%S 2>/dev/null || date -d '3 min ago' +%Y%m%d%H%M.%S)" "$TMP/d/a.jsonl"
expect "window 2 min" IDLE --minutes 2
expect "window 5 min" ACTIVE --minutes 5
# 16. argument without a value → error; non-integer --minutes → error
if bash "$SCRIPT" --dir >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: --dir without a value must fail"; else PASS=$((PASS+1)); fi
if bash "$SCRIPT" --dir "$TMP/d" --minutes 0.5 >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: --minutes 0.5 must fail"; else PASS=$((PASS+1)); fi
if bash "$SCRIPT" --dir "$TMP/d" --minutes 0 >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: --minutes 0 must fail"; else PASS=$((PASS+1)); fi

# 17. API limit/error (stop_sequence) → IDLE
reset; fixture a stop_seq; expect "stop_sequence" IDLE
# 18. slash command as the last record (/mcp, /compact) → IDLE
reset; fixture a slash_cmd; expect "slash command" IDLE
reset; fixture a slash_out; expect "local command stdout" IDLE
# 19. "Request interrupted" inside a tool_result — that is a WORKING session → ACTIVE
reset; fixture a tr_interrupt; expect "interrupted text inside tool_result" ACTIVE
# 20. an interruption in the form without "for tool use" → IDLE
reset; fixture a interrupted_prompt; expect "interrupted plain" IDLE
# 21. subagent: the parent is old (25 min), the subagent is fresh with tool_use → ACTIVE
reset; fixture parent tool_use; touch -t "$(date -v-25M +%Y%m%d%H%M.%S 2>/dev/null || date -d '25 min ago' +%Y%m%d%H%M.%S)" "$TMP/d/parent.jsonl"
mkdir -p "$TMP/d/parent/subagents"; fixture "parent/subagents/agent-1" tool_use; expect "subagent active, parent stale" ACTIVE
# 22. the own session's subagent is excluded together with it
expect "own subagent excluded" IDLE --self parent
# 23. subagent finished (end_turn), no parent → by the file itself → IDLE
reset; mkdir -p "$TMP/d/p2/subagents"; fixture "p2/subagents/agent-2" end_turn; expect "subagent done, no parent" IDLE
# 23a. the subagent ends with a record without stop_reason (7% of real ones), parent end_turn → IDLE (by the parent)
reset; fixture p3 end_turn; mkdir -p "$TMP/d/p3/subagents"; fixture "p3/subagents/agent-3" null_text; expect "subagent null stop, parent idle" IDLE
# 23b. the same subagent, but the parent is in flight (tool_use, old mtime) → ACTIVE (by the parent)
reset; fixture p4 tool_use; touch -t "$(date -v-25M +%Y%m%d%H%M.%S 2>/dev/null || date -d '25 min ago' +%Y%m%d%H%M.%S)" "$TMP/d/p4.jsonl"
mkdir -p "$TMP/d/p4/subagents"; fixture "p4/subagents/agent-4" null_text; expect "subagent null stop, parent active" ACTIVE
# 23c. the parent is interrupted by the owner, the subagent is fresh with tool_use → IDLE (by the parent)
reset; fixture p5 interrupted; mkdir -p "$TMP/d/p5/subagents"; fixture "p5/subagents/agent-5" tool_use; expect "subagent fresh, parent interrupted" IDLE
# 24. the tail cuts a UTF-8 character before a whole tool_use record → still ACTIVE
reset; fixture a utf8_split; expect "utf8 split tail" ACTIVE
# 25. a big final end_turn record (~1 MB) → IDLE
reset; fixture a big_end; expect "big end_turn record" IDLE
# 26. without CLAUDE_CODE_SESSION_ID and --self: the only fresh (own) one → IDLE + WARN; plus a foreign active one → ACTIVE
reset; fixture me tool_use
out=$(env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPT" --dir "$TMP/d"); rc=$?
if printf '%s\n' "$out" | grep -q '^RESULT=IDLE$' && printf '%s\n' "$out" | grep -q '^WARN='; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: no SELF fallback"; printf '%s\n' "$out"; fi
sleep 1; fixture me tool_use; fixture other tool_result   # other is the freshest, so it becomes the "own" one; me stays and is active
out=$(env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPT" --dir "$TMP/d"); rc=$?
if [ $rc -eq 10 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: no SELF + second active"; printf '%s\n' "$out"; fi

echo "active-session: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
