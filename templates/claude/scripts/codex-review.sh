#!/bin/bash
# Wrapper around the Codex plugin for Claude Code (`codex@openai-codex`) — the only path by which
# @codex-reviewer calls Codex (the `codex` MCP server was dropped from OpenAI support, 2026-09).
#
# Usage (prompt on stdin, a heredoc with a unique quoted marker):
#   bash .claude/scripts/codex-review.sh run --cwd <abs-dir> --model <model> --effort <effort> \
#        [--resume-thread <threadId>] [--wait-ms <ms>] <<'CODEX_PROMPT_END'
#   ...prompt text...
#   CODEX_PROMPT_END
#   bash .claude/scripts/codex-review.sh wait <job-id> --cwd <abs-dir> [--wait-ms <ms>]
#   bash .claude/scripts/codex-review.sh check            # plugin/CLI/login readiness, JSON
#
# Model and effort come ONLY from the review-tier.sh output (`CODEX_MODEL=`, `CODEX=`): the wrapper
# does not know or supply them; effort is from the plugin's set none|minimal|low|medium|high|xhigh
# (the plugin does not accept `max`/`ultra`).
#
# What `run` does: writes the prompt to a temp file, starts `codex-companion.mjs task --background`
# read-only (no `--write`) in the `--cwd` directory, immediately prints `job=<id> …` (so that if the
# Bash call is cut off the job can still be awaited via `wait <id>`), then waits up to `--wait-ms`
# (default 9 minutes — a Claude Bash call is limited to 10 minutes) and prints Codex's final message
# verbatim, with `threadId: <id>` as the last line (round 2 resumes the same thread by it).
# If Codex is still thinking — prints `PENDING job=<id>`; the caller repeats `wait <job-id>`.
# `--resume-thread <id>` (round 2): the plugin can resume only the LAST task thread in this
# working tree, so the wrapper compares its id with the given one before launch and with the actual
# `threadId` after: match — the thread is resumed (model and effort are passed anyway); no match, or
# the resume failed in the first wait window (a foreign job is running, thread not found) — a new
# thread, and the report prints "Round 1 thread not resumed: <reason>" before Codex's answer.
# Any engine failure (plugin not found, CLI not installed, the job failed or returned no result) —
# a `### Verdict: UNAVAILABLE` block with the reason, exit code 0: the wrapper agent relays it as is,
# and @reviewer takes over its role.
#
# Job state is shared with the plugin's `/codex:status` and `/codex:cancel` (`CLAUDE_PLUGIN_DATA`), but
# it is keyed by the working-tree root: those commands see a job from a pipeline worktree only with
# `--cwd <worktree>` (from the main checkout they do not see it).
#
# Environment variable CODEX_COMPANION — explicit path to codex-companion.mjs (for tests, overrides the lookup).
#
# Regression test: bash .claude/scripts/codex-review.test.sh

set -u

PLUGIN_KEY="codex@openai-codex"
DEFAULT_WAIT_MS=540000
POLL_MS=3000
HOME_DIR="${HOME:-/tmp}"
PLUGIN_DATA_DIR="${CLAUDE_PLUGIN_DATA:-$HOME_DIR/.claude/plugins/data/codex-openai-codex}"

unavailable() {
  printf '### Verdict: UNAVAILABLE\nReason: %s\n' "$1"
  exit 0
}

resolve_companion() {
  if [ -n "${CODEX_COMPANION:-}" ]; then
    [ -f "$CODEX_COMPANION" ] && { echo "$CODEX_COMPANION"; return 0; }
    return 1
  fi
  local registry="$HOME_DIR/.claude/plugins/installed_plugins.json" install_path=""
  if [ -f "$registry" ] && command -v jq >/dev/null 2>&1; then
    install_path=$(jq -r --arg k "$PLUGIN_KEY" '(.plugins // .)[$k] // [] | map(select(.installPath != null)) | (max_by(.installedAt) // {}) | .installPath // ""' "$registry" 2>/dev/null)
    if [ -n "$install_path" ] && [ -f "$install_path/scripts/codex-companion.mjs" ]; then
      echo "$install_path/scripts/codex-companion.mjs"; return 0
    fi
  fi
  # fallback path — the newest version in the plugin cache
  local candidate
  candidate=$(ls -d "$HOME_DIR"/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)
  if [ -n "$candidate" ] && [ -f "$candidate" ]; then
    echo "$candidate"; return 0
  fi
  return 1
}

companion() {
  CLAUDE_PLUGIN_DATA="$PLUGIN_DATA_DIR" node "$COMPANION" "$@"
}

new_tmp() { mktemp "${TMPDIR:-/tmp}/codex-review.XXXXXX"; }

# Waits for the job up to WAIT_MS. Prints the result (+ threadId as the last line) or PENDING.
# Argument 4 = "resume": on status failed/cancelled it does not exit but returns 3 with the reason in
# FAIL_REASON — the caller will start a new thread.
wait_and_print() {
  local job_id="$1" cwd="$2" wait_ms="$3" on_fail="${4:-}" snapshot status timed_out result rc err_file result_err thread_id
  snapshot=$(companion status "$job_id" --cwd "$cwd" --wait --timeout-ms "$wait_ms" --poll-interval-ms "$POLL_MS" --json 2>/dev/null) \
    || unavailable "codex-companion status failed for job $job_id"
  status=$(printf '%s' "$snapshot" | jq -r '.job.status // "unknown"' 2>/dev/null)
  timed_out=$(printf '%s' "$snapshot" | jq -r '.waitTimedOut // false' 2>/dev/null)
  if [ "$timed_out" = "true" ] || [ "$status" = "queued" ] || [ "$status" = "running" ]; then
    printf 'PENDING job=%s status=%s — Codex is still working; repeat: bash .claude/scripts/codex-review.sh wait %s --cwd %q\n' \
      "$job_id" "$status" "$job_id" "$cwd"
    exit 0
  fi
  err_file=$(new_tmp) || unavailable "could not create a temp file"
  result=$(companion result "$job_id" --cwd "$cwd" 2>"$err_file"); rc=$?
  result_err=$(head -c 1500 "$err_file"); rm -- "$err_file"
  case "$status" in
    completed)
      [ $rc -eq 0 ] && [ -n "$result" ] || unavailable "Codex job $job_id completed, but result returned no report (rc=$rc): $(printf '%s' "$result" | head -c 1500) ${result_err}"
      thread_id=$(companion result "$job_id" --cwd "$cwd" --json 2>/dev/null | jq -r '.storedJob.threadId // .job.threadId // empty' 2>/dev/null)
      # race: between the candidate check and the worker start, a foreign thread may have become the last one
      if [ "$on_fail" = "resume" ] && [ "$thread_id" != "$RESUME_THREAD" ]; then
        printf 'Round 1 thread not resumed: resumed thread %s instead of %s (race with another Codex job in this tree)\n' "${thread_id:-?}" "$RESUME_THREAD"
      fi
      printf '%s\n' "$result"
      [ -n "$thread_id" ] && printf 'threadId: %s\n' "$thread_id"
      return 0 ;;
    *)
      if [ "$on_fail" = "resume" ]; then
        FAIL_REASON="the resume failed with status '$status': $(printf '%s' "$result" | head -c 500) ${result_err}"
        return 3
      fi
      unavailable "Codex job $job_id finished with status '$status': $(printf '%s' "$result" | head -c 1500) ${result_err}" ;;
  esac
}

parse_common() {
  CWD=""; MODEL=""; EFFORT=""; RESUME_THREAD=""; WAIT_MS="$DEFAULT_WAIT_MS"
  while [ $# -gt 0 ]; do
    case "$1" in
      --cwd|--model|--effort|--resume-thread|--wait-ms)
        [ -n "${2:-}" ] || { echo "$1: value required" >&2; exit 2; }
        case "$1" in
          --cwd) CWD="$2" ;;
          --model) MODEL="$2" ;;
          --effort) EFFORT="$2" ;;
          --resume-thread) RESUME_THREAD="$2" ;;
          --wait-ms) WAIT_MS="$2" ;;
        esac
        shift 2 ;;
      *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
  done
  [ -n "$CWD" ] || CWD="$(pwd)"
  [ -d "$CWD" ] || unavailable "--cwd directory does not exist: $CWD"
}

# Launch a job: jobId → JOB_ID, error → LAUNCH_ERR; return code — launch success.
launch_task() { # prompt_file --fresh|--resume-last
  local prompt_file="$1"; shift
  local err_file launch rc
  err_file=$(new_tmp) || { LAUNCH_ERR="could not create a temp file"; return 1; }
  launch=$(companion task --cwd "$CWD" --background "$@" --model "$MODEL" --effort "$EFFORT" --prompt-file "$prompt_file" --json 2>"$err_file"); rc=$?
  LAUNCH_ERR="$(printf '%s' "$launch" | head -c 1500) $(head -c 1500 "$err_file")"
  rm -- "$err_file"
  JOB_ID=$(printf '%s' "$launch" | jq -r '.jobId // empty' 2>/dev/null)
  [ $rc -eq 0 ] && [ -n "$JOB_ID" ] || return 1
  printf 'job=%s started; if this call is cut off, wait for it: bash .claude/scripts/codex-review.sh wait %s --cwd %q\n' "$JOB_ID" "$JOB_ID" "$CWD"
}

CMD="${1:-}"; shift || true
COMPANION=$(resolve_companion) || unavailable "plugin $PLUGIN_KEY not found (~/.claude/plugins/installed_plugins.json); install: claude plugin marketplace add openai/codex-plugin-cc && claude plugin install $PLUGIN_KEY"
command -v node >/dev/null 2>&1 || unavailable "node not found in PATH"
command -v jq >/dev/null 2>&1 || unavailable "jq not found in PATH"

case "$CMD" in
  check)
    companion setup --json ;;
  run)
    parse_common "$@"
    [ -n "$MODEL" ] || { echo "--model is required (CODEX_MODEL= from review-tier.sh)" >&2; exit 2; }
    case "$EFFORT" in none|minimal|low|medium|high|xhigh) ;; *) echo "--effort must be one of none|minimal|low|medium|high|xhigh (got: '${EFFORT}')" >&2; exit 2 ;; esac
    PROMPT_FILE=$(new_tmp) || unavailable "could not create a temp prompt file"
    trap 'rm -f -- "$PROMPT_FILE"' EXIT   # the file is needed until the last launch (fallback after resume); any exit — cleanup
    cat > "$PROMPT_FILE"
    [ -s "$PROMPT_FILE" ] || { rm -- "$PROMPT_FILE"; unavailable "empty prompt on stdin"; }
    # Gate only on CLI presence: `setup` also reports ready=false when the shared broker is busy
    # ("Shared Codex broker is busy"), although task then goes to the direct app-server and runs;
    # a missing login will surface as a failed job with the real reason.
    codex_available=$(companion setup --cwd "$CWD" --json 2>/dev/null | jq -r '.codex.available // false' 2>/dev/null)
    [ "$codex_available" = "true" ] || { rm -- "$PROMPT_FILE"; unavailable "codex CLI not found (codex-companion setup: codex.available=false) — /codex:setup"; }
    NOT_RESUMED=""
    if [ -n "$RESUME_THREAD" ]; then
      candidate=$(companion task-resume-candidate --cwd "$CWD" --json 2>/dev/null | jq -r 'select(.available == true) | .candidate.threadId // empty' 2>/dev/null)
      if [ "$candidate" = "$RESUME_THREAD" ]; then
        if launch_task "$PROMPT_FILE" --resume-last; then
          # a resume error (a foreign job is running, thread not found) surfaces in the worker as failed —
          # catch it in the first wait window and fall back to a new thread
          wait_and_print "$JOB_ID" "$CWD" "$WAIT_MS" resume && exit 0
          NOT_RESUMED="$FAIL_REASON"
        else
          NOT_RESUMED="launch with --resume-last failed: ${LAUNCH_ERR}"
        fi
      else
        NOT_RESUMED="the last Codex thread in this tree is '${candidate:-none}', not '$RESUME_THREAD'"
      fi
      printf 'Round 1 thread not resumed: %s\n' "$NOT_RESUMED"
    fi
    launch_task "$PROMPT_FILE" --fresh || unavailable "Codex job launch failed: ${LAUNCH_ERR}"
    # the prompt was read by the runner synchronously and is stored in the job record — the trap removes the file
    wait_and_print "$JOB_ID" "$CWD" "$WAIT_MS" ;;
  wait)
    JOB_ID="${1:-}"; shift || true
    [ -n "$JOB_ID" ] || { echo "wait: job-id required" >&2; exit 2; }
    parse_common "$@"
    wait_and_print "$JOB_ID" "$CWD" "$WAIT_MS" ;;
  *)
    sed -n '2,12p' "$0" >&2; exit 2 ;;
esac
