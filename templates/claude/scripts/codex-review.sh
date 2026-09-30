#!/bin/bash
# Wrapper around the Codex CLI (`codex exec`) — the only path by which @codex-reviewer calls Codex.
# History: the `codex` MCP server was dropped from OpenAI support (2026-09); the Claude Code plugin
# `codex@openai-codex` was the path until 2026-09-30 — it is a layer over the same CLI, capped effort
# at `xhigh` and could resume only the last thread of a working tree.
#
# Usage (prompt as a file via --prompt-file; without the flag — on stdin, a heredoc with a quoted marker):
#   bash .claude/scripts/codex-review.sh run --cwd <abs-dir> --model <model> --effort <effort> \
#        --prompt-file <file> [--resume-thread <threadId>] [--wait-ms <ms>]
#   bash .claude/scripts/codex-review.sh run --cwd <abs-dir> --model <model> --effort <effort> <<'CODEX_PROMPT_END'
#   ...prompt text...
#   CODEX_PROMPT_END
#   bash .claude/scripts/codex-review.sh wait <job-id> [--cwd <abs-dir>] [--wait-ms <ms>]
#   bash .claude/scripts/codex-review.sh cancel <job-id>
#   bash .claude/scripts/codex-review.sh check            # CLI/login readiness, JSON
#
# Model and effort come ONLY from the review-tier.sh output (`CODEX_MODEL=`, `CODEX=`): the wrapper
# does not know or supply them; effort is one of low|medium|high|xhigh|max (`ultra` is refused by
# design: it delegates subtasks on its own, so review time becomes unpredictable).
#
# `--prompt-file` is the path for agents in a worktree: Claude Code's built-in worktree-isolation
# guard parses a heredoc fed to `bash` as a script and rejects the call when the prompt contains
# `git …` in backticks. The file must be `<--cwd>/artifacts/codex-prompts/<name>.md` (the directory
# is gitignored); the wrapper only reads it.
#
# What `run` does: copies the prompt into a job directory, starts `codex exec` detached from the
# call (read-only sandbox, approvals off, in the `--cwd` directory), immediately prints `job=<id> …`
# (so that if the Bash call is cut off the job can still be awaited via `wait <id>`), then waits up
# to `--wait-ms` (default 9 minutes — a Claude Bash call is limited to 10 minutes) and prints Codex's
# final message verbatim, with `threadId: <id>` as the last line (round 2 resumes the thread by it).
# If Codex is still thinking — prints `PENDING job=<id>`; the caller repeats `wait <job-id>`.
# `--resume-thread <id>` (round 2): `codex exec resume <id>` with the given model and effort; the
# resume failed in the first wait window (thread not found) — a new thread, and the report prints
# "Round 1 thread not resumed: <reason>" before Codex's answer.
# Any engine failure (CLI not installed, not logged in, the job failed or returned no message) —
# a `### Verdict: UNAVAILABLE` block with the reason, exit code 0: the wrapper agent relays it as is,
# and @reviewer takes over its role.
#
# Job state: `$CODEX_REVIEW_JOBS/<job-id>/` (default `$TMPDIR/codex-review-jobs`): prompt, JSONL
# events, stderr, final message, exit code; directories older than 7 days are removed on `run`.
#
# Environment variable CODEX_BIN — explicit path to `codex` (for tests, overrides the PATH lookup).
#
# Regression test: bash .claude/scripts/codex-review.test.sh

set -u

DEFAULT_WAIT_MS=540000
TMP_BASE="${TMPDIR:-/tmp}"
JOBS_DIR="${CODEX_REVIEW_JOBS:-${TMP_BASE%/}/codex-review-jobs}"
JOBS_DIR="${JOBS_DIR%/}"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

unavailable() {
  printf '### Verdict: UNAVAILABLE\nReason: %s\n' "$1"
  exit 0
}

resolve_codex() {
  if [ -n "${CODEX_BIN:-}" ]; then
    [ -x "$CODEX_BIN" ] && { echo "$CODEX_BIN"; return 0; }
    return 1
  fi
  command -v codex 2>/dev/null
}

job_dir() { # job-id → JOB_DIR; only ids this wrapper issues (no path tricks)
  case "$1" in cr-[0-9]*) ;; *) echo "invalid job-id: '$1'" >&2; exit 2 ;; esac
  case "$1" in *[!A-Za-z0-9-]*) echo "invalid job-id: '$1'" >&2; exit 2 ;; esac
  JOB_DIR="$JOBS_DIR/$1"
}

# Runs detached from the caller: one `codex exec` for the job, then writes its exit code to `rc`.
run_job() { # job-dir
  local job="$1" codex_pid rc
  # shellcheck source=/dev/null
  . "$job/job.env"
  cd "$JOB_CWD" 2>"$job/stderr.txt" || { echo 1 > "$job/rc"; return; }
  set -- exec
  [ -n "$JOB_RESUME" ] && set -- "$@" resume "$JOB_RESUME"
  set -- "$@" --skip-git-repo-check -m "$JOB_MODEL" -c "model_reasoning_effort=\"$JOB_EFFORT\"" \
    -c 'sandbox_mode="read-only"' -c 'approval_policy="never"' --json -o "$job/last.md" -
  "$JOB_CODEX" "$@" < "$job/prompt.md" > "$job/events.jsonl" 2> "$job/stderr.txt" &
  codex_pid=$!
  echo "$codex_pid" > "$job/codex.pid"
  wait "$codex_pid"; rc=$?
  echo "$rc" > "$job/rc.tmp" && mv -- "$job/rc.tmp" "$job/rc"
}

# Start a job: jobId → JOB_ID, error → LAUNCH_ERR; return code — launch success.
launch_job() { # prompt-file resume-thread-or-empty
  local job
  JOB_ID="cr-$(date +%Y%m%d%H%M%S)-$$-${RANDOM}"
  job="$JOBS_DIR/$JOB_ID"
  mkdir -p -- "$job" || { LAUNCH_ERR="could not create the job directory $job"; return 1; }
  cp -- "$1" "$job/prompt.md" || { LAUNCH_ERR="could not copy the prompt into $job"; return 1; }
  {
    printf 'JOB_CWD=%q\n' "$CWD"
    printf 'JOB_MODEL=%q\n' "$MODEL"
    printf 'JOB_EFFORT=%q\n' "$EFFORT"
    printf 'JOB_RESUME=%q\n' "$2"
    printf 'JOB_CODEX=%q\n' "$CODEX"
  } > "$job/job.env"
  # own session: the job outlives a Bash call that is cut off at the tool's time limit
  if command -v perl >/dev/null 2>&1; then
    nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' bash "$SELF" _job "$job" </dev/null >/dev/null 2>&1 &
  else
    nohup bash "$SELF" _job "$job" </dev/null >/dev/null 2>&1 &
  fi
  echo $! > "$job/runner.pid"
  printf 'job=%s started; if this call is cut off, wait for it: bash .claude/scripts/codex-review.sh wait %s --cwd %q\n' "$JOB_ID" "$JOB_ID" "$CWD"
}

# The reason a finished job failed: the last turn error, else the last error event, else stderr.
failure_reason() { # job-dir
  local job="$1" reason
  reason=$(jq -r 'select(.type == "turn.failed") | .error.message // empty' "$job/events.jsonl" 2>/dev/null | tail -1)
  [ -n "$reason" ] || reason=$(jq -r 'select(.type == "error") | .message // empty' "$job/events.jsonl" 2>/dev/null | tail -1)
  [ -n "$reason" ] || reason=$(tail -c 1500 "$job/stderr.txt" 2>/dev/null | tr '\n' ' ')
  printf '%s' "$reason" | head -c 1500
}

# Waits for the job up to WAIT_MS. Prints the result (+ threadId as the last line) or PENDING.
# Argument 3 = "resume": on failure it does not exit but returns 3 with the reason in FAIL_REASON —
# the caller will start a new thread.
wait_and_print() { # job-id wait-ms [resume]
  local job_id="$1" wait_ms="$2" on_fail="${3:-}" job deadline runner rc thread_id reason
  job_dir "$job_id"; job="$JOB_DIR"
  [ -d "$job" ] || unavailable "no Codex job $job_id in $JOBS_DIR"
  deadline=$(( $(date +%s) + wait_ms / 1000 ))
  while [ ! -f "$job/rc" ]; do
    runner=$(cat "$job/runner.pid" 2>/dev/null)
    if [ -n "$runner" ] && ! kill -0 "$runner" 2>/dev/null && [ ! -f "$job/rc" ]; then
      unavailable "Codex job $job_id stopped without an exit code (killed?): $(failure_reason "$job")"
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      printf 'PENDING job=%s status=running — Codex is still working; repeat: bash .claude/scripts/codex-review.sh wait %s --cwd %q\n' \
        "$job_id" "$job_id" "$CWD"
      exit 0
    fi
    sleep 1
  done
  rc=$(cat "$job/rc")
  thread_id=$(jq -r 'select(.type == "thread.started") | .thread_id // empty' "$job/events.jsonl" 2>/dev/null | head -1)
  if [ "$rc" = "0" ] && [ -s "$job/last.md" ]; then
    if [ "$on_fail" = "resume" ] && [ "$thread_id" != "$RESUME_THREAD" ]; then
      printf 'Round 1 thread not resumed: Codex answered in thread %s instead of %s\n' "${thread_id:-?}" "$RESUME_THREAD"
    fi
    cat -- "$job/last.md"
    printf '\n'
    if [ -n "$thread_id" ]; then
      printf '\nCodex session ID: %s\nResume in Codex: codex resume %s\nthreadId: %s\n' "$thread_id" "$thread_id" "$thread_id"
    fi
    return 0
  fi
  if [ "$rc" = "0" ]; then reason="Codex finished without a final message"; else reason="rc=$rc: $(failure_reason "$job")"; fi
  if [ "$on_fail" = "resume" ]; then
    FAIL_REASON="the resume failed ($reason)"
    return 3
  fi
  [ -n "$thread_id" ] || reason="$reason (no thread opened — not logged in? codex login)"
  unavailable "Codex job $job_id failed, $reason"
}

parse_common() {
  CWD=""; MODEL=""; EFFORT=""; RESUME_THREAD=""; PROMPT_SRC=""; WAIT_MS="$DEFAULT_WAIT_MS"
  while [ $# -gt 0 ]; do
    case "$1" in
      --cwd|--model|--effort|--resume-thread|--prompt-file|--wait-ms)
        [ -n "${2:-}" ] || { echo "$1: value required" >&2; exit 2; }
        case "$1" in
          --cwd) CWD="$2" ;;
          --model) MODEL="$2" ;;
          --effort) EFFORT="$2" ;;
          --resume-thread) RESUME_THREAD="$2" ;;
          --prompt-file) PROMPT_SRC="$2" ;;
          --wait-ms) WAIT_MS="$2" ;;
        esac
        shift 2 ;;
      *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
  done
  case "$WAIT_MS" in *[!0-9]*) echo "--wait-ms must be a whole number (got: '$WAIT_MS')" >&2; exit 2 ;; esac
  [ -n "$CWD" ] || CWD="$(pwd)"
  [ -d "$CWD" ] || unavailable "--cwd directory does not exist: $CWD"
}

CMD="${1:-}"; shift || true

if [ "$CMD" = "_job" ]; then run_job "$1"; exit 0; fi

CODEX=$(resolve_codex) || unavailable "codex CLI not found in PATH; install: npm i -g @openai/codex, then codex login"
command -v jq >/dev/null 2>&1 || unavailable "jq not found in PATH"

case "$CMD" in
  check)
    version=$("$CODEX" --version 2>&1); version_rc=$?
    login=$("$CODEX" login status 2>&1); login_rc=$?
    version=$(printf '%s' "$version" | head -1)
    login=$(printf '%s' "$login" | head -3 | tr '\n' ' ')
    jq -n --arg v "$version" --argjson vok "$([ $version_rc -eq 0 ] && echo true || echo false)" \
          --arg l "$login" --argjson lok "$([ $login_rc -eq 0 ] && echo true || echo false)" \
      '{ready: ($vok and $lok), codex: {available: $vok, detail: $v}, auth: {loggedIn: $lok, detail: $l}}' ;;
  run)
    parse_common "$@"
    [ -n "$MODEL" ] || { echo "--model is required (CODEX_MODEL= from review-tier.sh)" >&2; exit 2; }
    case "$EFFORT" in low|medium|high|xhigh|max) ;; *) echo "--effort must be one of low|medium|high|xhigh|max (got: '${EFFORT}')" >&2; exit 2 ;; esac
    if [ -n "$PROMPT_SRC" ]; then
      # only the gitignored prompt dir of this tree: a stray path would land in the task commit
      case "$PROMPT_SRC" in
        */../*|*/./*) echo "--prompt-file: path with '..' or '.': $PROMPT_SRC" >&2; exit 2 ;;
        "${CWD%/}"/artifacts/codex-prompts/*.md) ;;
        *) echo "--prompt-file: only ${CWD%/}/artifacts/codex-prompts/<name>.md (got: $PROMPT_SRC)" >&2; exit 2 ;;
      esac
      [ -f "$PROMPT_SRC" ] || { echo "--prompt-file: file not found: $PROMPT_SRC" >&2; exit 2; }
    fi
    mkdir -p -- "$JOBS_DIR" || unavailable "could not create $JOBS_DIR"
    find "$JOBS_DIR" -mindepth 1 -maxdepth 1 -type d -name 'cr-*' -mtime +7 -exec rm -rf -- {} + 2>/dev/null
    PROMPT_FILE=$(mktemp "$JOBS_DIR/prompt.XXXXXX") || unavailable "could not create a temp prompt file"
    trap 'rm -f -- "$PROMPT_FILE"' EXIT   # the file is needed until the last launch (fallback after resume)
    if [ -n "$PROMPT_SRC" ]; then
      cat -- "$PROMPT_SRC" > "$PROMPT_FILE" || unavailable "could not read --prompt-file: $PROMPT_SRC"
    else
      cat > "$PROMPT_FILE"
    fi
    [ -s "$PROMPT_FILE" ] || unavailable "empty prompt (${PROMPT_SRC:-stdin})"
    if [ -n "$RESUME_THREAD" ]; then
      if launch_job "$PROMPT_FILE" "$RESUME_THREAD"; then
        # a resume error (thread not found) fails fast — catch it in the first wait window and fall back to a new thread
        wait_and_print "$JOB_ID" "$WAIT_MS" resume && exit 0
        NOT_RESUMED="$FAIL_REASON"
      else
        NOT_RESUMED="launch failed: ${LAUNCH_ERR}"
      fi
      printf 'Round 1 thread not resumed: %s\n' "$NOT_RESUMED"
    fi
    launch_job "$PROMPT_FILE" "" || unavailable "Codex job launch failed: ${LAUNCH_ERR}"
    wait_and_print "$JOB_ID" "$WAIT_MS" ;;
  wait)
    JOB_ID="${1:-}"; shift || true
    [ -n "$JOB_ID" ] || { echo "wait: job-id required" >&2; exit 2; }
    parse_common "$@"
    wait_and_print "$JOB_ID" "$WAIT_MS" ;;
  cancel)
    JOB_ID="${1:-}"
    [ -n "$JOB_ID" ] || { echo "cancel: job-id required" >&2; exit 2; }
    job_dir "$JOB_ID"; job="$JOB_DIR"
    [ -d "$job" ] || { echo "no Codex job $JOB_ID in $JOBS_DIR" >&2; exit 1; }
    [ -f "$job/rc" ] && { echo "job $JOB_ID already finished (rc=$(cat "$job/rc"))"; exit 0; }
    kill "$(cat "$job/codex.pid" 2>/dev/null)" 2>/dev/null || kill "$(cat "$job/runner.pid" 2>/dev/null)" 2>/dev/null
    echo "job $JOB_ID cancelled" ;;
  *)
    sed -n '7,15p' "$0" >&2; exit 2 ;;
esac
