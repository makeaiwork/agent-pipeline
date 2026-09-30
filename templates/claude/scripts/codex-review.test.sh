#!/bin/bash
# Regression test for the codex-review.sh wrapper — no live Codex: a stub (CODEX_BIN) is substituted
# for the `codex` CLI; it writes the arguments it receives to a log and returns canned JSONL events.
# Run: bash .claude/scripts/codex-review.test.sh

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/codex-review.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/codex-review-test.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
STUB="$TMP/codex"
LOG="$TMP/calls.log"
export CODEX_REVIEW_JOBS="$TMP/jobs"
FAIL=0

cat > "$STUB" <<'EOS'
#!/bin/bash
mode="${STUB_MODE:-ok}"
case "$1" in
  --version) [ "$mode" = "no-version" ] && exit 1; echo "codex-cli 9.9.9"; exit 0 ;;
  login) [ "$mode" = "no-login" ] && { echo "Not logged in"; exit 1; }; echo "Logged in using ChatGPT"; exit 0 ;;
esac
echo "ARGS $*" >> "$STUB_LOG"
echo "PWD $(pwd -P)" >> "$STUB_LOG"
resume=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    resume) resume="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'PROMPT<<%s>>\n' "$(cat)" >> "$STUB_LOG"
case "$mode" in
  hang) exec sleep 30 ;;
  slow) sleep 3 ;;
  no-login) echo "Error: not logged in" >&2; exit 1 ;;
  resume-fail) [ -n "$resume" ] && { echo "Error: thread/resume failed: no rollout found for thread id $resume" >&2; exit 1; } ;;
esac
tid="${resume:-thread-B}"
echo "{\"type\":\"thread.started\",\"thread_id\":\"$tid\"}"
case "$mode" in
  turn-failed) echo '{"type":"turn.failed","error":{"message":"The model is not supported when using Codex with a ChatGPT account."}}'; exit 1 ;;
  empty) echo '{"type":"turn.completed"}'; exit 0 ;;
esac
printf '### Verdict: APPROVE\n\n### Findings\n\n- none\n' > "$out"
echo '{"type":"turn.completed"}'
EOS
chmod +x "$STUB"

run_wrapper() { # mode, args...
  local mode="$1"; shift
  : > "$LOG"
  printf 'Prompt\nsecond line\n' | CODEX_BIN="$STUB" STUB_LOG="$LOG" STUB_MODE="$mode" bash "$SCRIPT" run --cwd "$TMP" "$@" 2>&1
}
wrapper() { # mode, args... — any subcommand, no stdin
  local mode="$1"; shift
  CODEX_BIN="$STUB" STUB_LOG="$LOG" STUB_MODE="$mode" bash "$SCRIPT" "$@" </dev/null 2>&1
}

check() { # name, output, expected-substring
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "PASS: $1"; else echo "FAIL: $1 — expected '$3', got:"; printf '%s\n' "$2" | sed 's/^/    /'; FAIL=1; fi
}

M="--model gpt-test --effort high"

check "happy path"                               "$(run_wrapper ok $M)"            "### Verdict: APPROVE"
check "threadId as the last line"                "$(run_wrapper ok $M | tail -1)"  "threadId: thread-B"
check "job id printed first"                     "$(run_wrapper ok $M | head -1)"  "job=cr-"
check "turn failed → UNAVAILABLE with the reason" "$(run_wrapper turn-failed $M)"  "not supported when using Codex"
check "no login → UNAVAILABLE with a hint"       "$(run_wrapper no-login $M)"      "not logged in"
check "no final message → UNAVAILABLE"           "$(run_wrapper empty $M)"         "without a final message"

# exec arguments: read-only sandbox, approvals off, model/effort from the arguments, JSON events,
# no resume, no bypass flags; runs in --cwd; the prompt passed in full
run_wrapper ok --model gpt-x --effort xhigh >/dev/null
if grep -qF 'ARGS exec --skip-git-repo-check -m gpt-x -c model_reasoning_effort="xhigh" -c sandbox_mode="read-only" -c approval_policy="never" --json -o ' "$LOG" \
   && ! grep -q 'resume\|dangerously\|--write' "$LOG" && grep -qxF "PWD $TMP" "$LOG" \
   && grep -q 'PROMPT<<Prompt' "$LOG" && grep -q '^second line>>' "$LOG"; then
  echo "PASS: exec arguments (read-only, approvals off, model/effort from the arguments, cwd, prompt from stdin)"
else echo "FAIL: exec arguments:"; sed 's/^/    /' "$LOG"; FAIL=1; fi

# pending → PENDING with the wait command; `wait <id>` in a later call collects the result
out=$(run_wrapper slow $M --wait-ms 1000)
job=$(printf '%s\n' "$out" | sed -n 's/^PENDING job=\([^ ]*\).*/\1/p')
if [ -n "$job" ]; then
  echo "PASS: pending → PENDING job=<id>"
  check "wait <job-id> collects the result" "$(wrapper slow wait "$job" --cwd "$TMP")" "threadId: thread-B"
else echo "FAIL: pending:"; printf '%s\n' "$out" | sed 's/^/    /'; FAIL=1; fi

# cancel: a hanging job is stopped, a later wait reports it as failed
out=$(run_wrapper hang $M --wait-ms 1000)
job=$(printf '%s\n' "$out" | sed -n 's/^PENDING job=\([^ ]*\).*/\1/p')
check "cancel <job-id>" "$(wrapper hang cancel "$job")" "cancelled"
check "wait after cancel → UNAVAILABLE" "$(wrapper hang wait "$job" --wait-ms 5000)" "### Verdict: UNAVAILABLE"

# --prompt-file: prompt from the file (with `git diff` in backticks), stdin is not read, the caller's file stays
PD="$TMP/artifacts/codex-prompts"; mkdir -p "$PD"
PF="$PD/T-1-review.md"
printf 'Prompt from a file: `git diff HEAD -- README.md`\n' > "$PF"
run_pf() { # mode, prompt-file, args... — stdin carries a decoy that must not reach the prompt
  local mode="$1" pf="$2"; shift 2
  : > "$LOG"
  printf 'stdin-must-not-leak\n' | CODEX_BIN="$STUB" STUB_LOG="$LOG" STUB_MODE="$mode" bash "$SCRIPT" run --cwd "$TMP" $M --prompt-file "$pf" "$@" 2>&1
}
out=$(run_pf ok "$PF")
if printf '%s' "$out" | grep -qF "### Verdict: APPROVE" && grep -qF 'PROMPT<<Prompt from a file: `git diff HEAD -- README.md`' "$LOG" \
   && ! grep -q 'stdin-must-not-leak' "$LOG" && [ -f "$PF" ]; then
  echo "PASS: --prompt-file (prompt from the file, stdin not read, file not deleted)"
else echo "FAIL: --prompt-file:"; printf '%s\n' "$out" | sed 's/^/    /'; sed 's/^/    /' "$LOG"; FAIL=1; fi

# --prompt-file + --resume-thread (the working call of mode: verify) → the thread is resumed with the prompt from the file
out=$(run_pf ok "$PF" --resume-thread thread-A)
if grep -q '^ARGS exec resume thread-A ' "$LOG" && grep -qF 'PROMPT<<Prompt from a file' "$LOG" && printf '%s' "$out" | grep -qF "threadId: thread-A"; then
  echo "PASS: --prompt-file + --resume-thread"
else echo "FAIL: --prompt-file + --resume-thread:"; printf '%s\n' "$out" | sed 's/^/    /'; sed 's/^/    /' "$LOG"; FAIL=1; fi

# --prompt-file outside <cwd>/artifacts/codex-prompts, with '..', missing, not .md → exit 2 before launch
printf 'x\n' > "$TMP/outside.md"
for bad in "$TMP/outside.md" "$PD/../../outside.md" "$PD/nope.md" "$PD/T-1-review.txt"; do
  out=$(run_pf ok "$bad"); rc=$?
  if [ $rc -eq 2 ] && ! grep -q '^ARGS ' "$LOG"; then echo "PASS: --prompt-file rejected: ${bad#$TMP/}"; else echo "FAIL: --prompt-file ${bad#$TMP/} (rc=$rc): $out"; FAIL=1; fi
done

# --prompt-file empty or unreadable → UNAVAILABLE, exit 0
: > "$PD/empty.md"
check "--prompt-file empty → UNAVAILABLE"        "$(run_pf ok "$PD/empty.md")"     "empty prompt ($PD/empty.md)"
printf 'x\n' > "$PD/locked.md"; chmod 000 "$PD/locked.md"
if [ -r "$PD/locked.md" ]; then echo "SKIP: unreadable file (running as root)"
else check "--prompt-file unreadable → UNAVAILABLE" "$(run_pf ok "$PD/locked.md")" "could not read --prompt-file"; fi
chmod 600 "$PD/locked.md"

# round 2: resume by id — the same thread, one launch, no note
out=$(run_wrapper ok $M --resume-thread thread-A)
if [ "$(grep -c '^ARGS ' "$LOG")" = "1" ] && grep -q '^ARGS exec resume thread-A ' "$LOG" && ! printf '%s' "$out" | grep -q 'not resumed' \
   && [ "$(printf '%s\n' "$out" | tail -1)" = "threadId: thread-A" ]; then
  echo "PASS: resume-thread → thread resumed by id"
else echo "FAIL: resume-thread:"; printf '%s\n' "$out" | sed 's/^/    /'; sed 's/^/    /' "$LOG"; FAIL=1; fi

# round 2: the resume failed (thread not found) → a new thread with the note, not UNAVAILABLE
out=$(run_wrapper resume-fail $M --resume-thread thread-A)
if printf '%s' "$out" | grep -q '^Round 1 thread not resumed: .*no rollout found' && printf '%s' "$out" | grep -qF "### Verdict: APPROVE" \
   && [ "$(grep -c '^ARGS ' "$LOG")" = "2" ] && [ "$(printf '%s\n' "$out" | tail -1)" = "threadId: thread-B" ]; then
  echo "PASS: resume failed → fallback to a new thread"
else echo "FAIL: resume failed:"; printf '%s\n' "$out" | sed 's/^/    /'; FAIL=1; fi

# check: ready with CLI and login; not logged in → ready=false
check "check: ready"                             "$(wrapper ok check | jq -r .ready)"        "true"
check "check: not logged in → ready=false"       "$(wrapper no-login check | jq -r .ready)"  "false"

# argument validation: no --model, effort outside the set, a flag without a value, a foreign job id — exit code 2 before launch
if run_wrapper ok --effort high >/dev/null; then echo "FAIL: a call without --model must be rejected"; FAIL=1; else echo "PASS: --model is required"; fi
if run_wrapper ok --model gpt-x --effort ultra >/dev/null; then echo "FAIL: effort=ultra must be rejected"; FAIL=1; else echo "PASS: effort=ultra rejected"; fi
check "effort=max accepted"                      "$(run_wrapper ok --model gpt-x --effort max)" "### Verdict: APPROVE"
out=$(run_wrapper ok --model gpt-x --effort); rc=$?
if [ $rc -eq 2 ] && printf '%s' "$out" | grep -qF "value required"; then echo "PASS: flag without a value"; else echo "FAIL: flag without a value (rc=$rc): $out"; FAIL=1; fi
out=$(wrapper ok wait ../../etc); rc=$?
if [ $rc -eq 2 ]; then echo "PASS: wait rejects a foreign job id"; else echo "FAIL: wait with a foreign job id (rc=$rc): $out"; FAIL=1; fi
check "wait for an unknown job → UNAVAILABLE"    "$(wrapper ok wait cr-1-2-3)"               "no Codex job cr-1-2-3"

# CLI not found → UNAVAILABLE, exit code 0
out=$(printf 'x\n' | CODEX_BIN="$TMP/nope" bash "$SCRIPT" run --cwd "$TMP" $M 2>&1); rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qF "### Verdict: UNAVAILABLE"; then echo "PASS: CLI not found → UNAVAILABLE"; else echo "FAIL: CLI not found (rc=$rc):"; printf '%s\n' "$out" | sed 's/^/    /'; FAIL=1; fi

rm -rf -- "$TMP"
[ $FAIL -eq 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
