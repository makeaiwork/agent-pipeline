#!/bin/bash
# Regression test for the codex-review.sh wrapper — no live Codex: a stub (CODEX_COMPANION) is
# substituted for the plugin runner; it writes the arguments it receives to a log and returns
# canned answers. Run: bash .claude/scripts/codex-review.test.sh

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/codex-review.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/codex-review-test.XXXXXX")
STUB="$TMP/stub-companion.mjs"
LOG="$TMP/calls.log"
FAIL=0

cat > "$STUB" <<'EOS'
import fs from "node:fs";
const [cmd, ...rest] = process.argv.slice(2);
const log = process.env.STUB_LOG;
const mode = process.env.STUB_MODE || "ok";
fs.appendFileSync(log, `${cmd} ${rest.join(" ")}\n`);
const opt = (name) => { const i = rest.indexOf(name); return i >= 0 ? rest[i + 1] : null; };
if (cmd === "setup") {
  // as in the plugin: ready=false both when the CLI is missing and when the shared broker is busy
  const available = mode !== "no-cli";
  const ready = available && mode !== "broker-busy";
  console.log(JSON.stringify({ ready, codex: { available }, auth: { loggedIn: ready, detail: mode === "broker-busy" ? "Shared Codex broker is busy." : "" } }));
  process.exit(0);
}
if (cmd === "task-resume-candidate") {
  const available = mode !== "no-candidate";
  console.log(JSON.stringify({ available, candidate: available ? { id: "task-prev", threadId: "thread-A" } : null }));
  process.exit(0);
}
if (cmd === "task") {
  const promptFile = opt("--prompt-file");
  fs.appendFileSync(log, `PROMPT<<${fs.readFileSync(promptFile, "utf8")}>>\n`);
  if (mode === "launch-fail") { console.error("boom: codex exploded"); process.exit(1); }
  if (mode === "resume-fail" && rest.includes("--resume-last")) { console.error("Task task-x is still running."); process.exit(1); }
  if (mode === "node-warning") { console.error("(node:1) ExperimentalWarning: something"); }
  // as in the plugin: --resume-last resumes the candidate's thread (thread-A), --fresh opens a new one (thread-B)
  fs.writeFileSync(log + ".resumed", rest.includes("--resume-last") ? "1" : "0");
  console.log(JSON.stringify({ jobId: "task-stub-1", status: "queued" })); process.exit(0);
}
if (cmd === "status") {
  const status = mode === "pending" ? "running" : mode === "failed" ? "failed" : mode === "cancelled" ? "cancelled" : "completed";
  console.log(JSON.stringify({ job: { id: rest[0], status }, waitTimedOut: mode === "pending" })); process.exit(0);
}
if (cmd === "result") {
  if (mode === "result-fail") { console.error("result: job payload missing"); process.exit(1); }
  const tid = fs.existsSync(log + ".resumed") && fs.readFileSync(log + ".resumed", "utf8") === "1" ? "thread-A" : "thread-B";
  if (rest.includes("--json")) { console.log(JSON.stringify({ job: { id: rest[0], threadId: tid }, storedJob: { threadId: tid } })); process.exit(0); }
  console.log(`### Verdict: APPROVE\n\n### Findings\n\n- none\n\nCodex session ID: ${tid}\nResume in Codex: codex resume ${tid}`); process.exit(0);
}
process.exit(3);
EOS

run_wrapper() { # mode, args...
  local mode="$1"; shift
  : > "$LOG"; rm -f -- "$LOG.resumed"
  printf 'Prompt\nsecond line\n' | CODEX_COMPANION="$STUB" STUB_LOG="$LOG" STUB_MODE="$mode" bash "$SCRIPT" run --cwd "$TMP" "$@" 2>&1
}

check() { # name, output, expected-substring
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "PASS: $1"; else echo "FAIL: $1 — expected '$3', got:"; printf '%s\n' "$2" | sed 's/^/    /'; FAIL=1; fi
}

M="--model gpt-test --effort high"

check "happy path"                               "$(run_wrapper ok $M)"            "### Verdict: APPROVE"
check "threadId as the last line"                "$(run_wrapper ok $M | tail -1)"  "threadId: thread-B"
check "pending → wait command"                   "$(run_wrapper pending $M)"       "PENDING job=task-stub-1"
check "job failed → UNAVAILABLE"                 "$(run_wrapper failed $M)"        "### Verdict: UNAVAILABLE"
check "job cancelled → UNAVAILABLE"              "$(run_wrapper cancelled $M)"     "status 'cancelled'"
check "no codex CLI → UNAVAILABLE"               "$(run_wrapper no-cli $M)"        "codex CLI not found"
check "launch failed → UNAVAILABLE with stderr"  "$(run_wrapper launch-fail $M)"   "codex exploded"
check "result failed on completed → UNAVAILABLE" "$(run_wrapper result-fail $M)"   "result returned no report"
check "a Node warning does not break the launch" "$(run_wrapper node-warning $M)"  "### Verdict: APPROVE"

# busy broker: ready=false, but the CLI is present → the job is launched anyway
out=$(run_wrapper broker-busy $M)
if printf '%s' "$out" | grep -qF "### Verdict: APPROVE" && grep -q '^task ' "$LOG"; then echo "PASS: a busy broker does not yield a false UNAVAILABLE"; else echo "FAIL: busy broker:"; printf '%s\n' "$out" | sed 's/^/    /'; FAIL=1; fi

# runner arguments: read-only (no --write), model/effort from the arguments, the prompt passed in full
run_wrapper ok --model gpt-x --effort xhigh >/dev/null
if grep -q '^task .*--background .*--fresh .*--model gpt-x .*--effort xhigh .*--prompt-file' "$LOG" && ! grep -q -- '--write' "$LOG" \
   && grep -q 'PROMPT<<Prompt' "$LOG" && grep -q '^second line' "$LOG"; then
  echo "PASS: task arguments (read-only, model/effort from the arguments, prompt from stdin)"
else echo "FAIL: task arguments:"; sed 's/^/    /' "$LOG"; FAIL=1; fi

# round 2: the thread matches the last one → --resume-last, no --fresh, no note
out=$(run_wrapper ok $M --resume-thread thread-A)
if grep -q '^task .*--resume-last' "$LOG" && ! grep -q -- '--fresh' "$LOG" && ! printf '%s' "$out" | grep -q 'not resumed' && printf '%s' "$out" | grep -qF "### Verdict: APPROVE"; then
  echo "PASS: resume-thread matched → thread resumed"
else echo "FAIL: resume-thread matched:"; printf '%s\n' "$out" | sed 's/^/    /'; sed 's/^/    /' "$LOG"; FAIL=1; fi

# round 2: the thread does not match → a new thread and the note as the first line
out=$(run_wrapper ok $M --resume-thread thread-Z)
if grep -q '^task .*--fresh' "$LOG" && ! grep -q -- '--resume-last' "$LOG" && [ "$(printf '%s\n' "$out" | head -1 | cut -c1-30)" = "Round 1 thread not resumed: th" ]; then
  echo "PASS: resume-thread did not match → new thread with the note"
else echo "FAIL: resume-thread did not match:"; printf '%s\n' "$out" | sed 's/^/    /'; FAIL=1; fi

# round 2: no candidate → a new thread with the note
out=$(run_wrapper no-candidate $M --resume-thread thread-A)
check "resume-thread with no candidate → new thread" "$out" "Round 1 thread not resumed"

# round 2: --resume-last failed (another job is running) → a new thread with the note, not UNAVAILABLE
out=$(run_wrapper resume-fail $M --resume-thread thread-A)
if printf '%s' "$out" | grep -q 'not resumed' && printf '%s' "$out" | grep -qF "### Verdict: APPROVE" && grep -q '^task .*--fresh' "$LOG"; then
  echo "PASS: resume-last failed → fallback to a new thread"
else echo "FAIL: resume-last failed:"; printf '%s\n' "$out" | sed 's/^/    /'; FAIL=1; fi

# wait: waiting again by job-id
: > "$LOG"
out=$(CODEX_COMPANION="$STUB" STUB_LOG="$LOG" STUB_MODE=ok bash "$SCRIPT" wait task-stub-1 --cwd "$TMP" 2>&1)
if printf '%s' "$out" | grep -qF "### Verdict: APPROVE" && grep -q '^status task-stub-1 .*--wait' "$LOG"; then echo "PASS: wait <job-id>"; else echo "FAIL: wait <job-id>:"; printf '%s\n' "$out" | sed 's/^/    /'; FAIL=1; fi

# argument validation: no --model, invalid effort, a flag without a value — exit code 2 before launch
if run_wrapper ok --effort high >/dev/null; then echo "FAIL: a call without --model must be rejected"; FAIL=1; else echo "PASS: --model is required"; fi
if run_wrapper ok --model gpt-x --effort max >/dev/null; then echo "FAIL: effort=max must be rejected"; FAIL=1; else echo "PASS: effort only from the plugin's set"; fi
out=$(run_wrapper ok --model gpt-x --effort); rc=$?
if [ $rc -eq 2 ] && printf '%s' "$out" | grep -qF "value required"; then echo "PASS: flag without a value"; else echo "FAIL: flag without a value (rc=$rc): $out"; FAIL=1; fi

# plugin not found → UNAVAILABLE, exit code 0
out=$(printf 'x\n' | CODEX_COMPANION="$TMP/nope.mjs" bash "$SCRIPT" run --cwd "$TMP" $M 2>&1); rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qF "### Verdict: UNAVAILABLE"; then echo "PASS: plugin not found → UNAVAILABLE"; else echo "FAIL: plugin not found (rc=$rc):"; printf '%s\n' "$out" | sed 's/^/    /'; FAIL=1; fi

rm -r -- "$TMP"
[ $FAIL -eq 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
