#!/bin/bash
# Raster image generation through the Codex CLI (built-in `image_gen` tool, `image_generation`
# feature) — the only path by which pipeline agents obtain generated images. The
# `codex@openai-codex` plugin does not generate images; the `codex` CLI itself, logged in, is required.
#
# Usage (image description on stdin, a heredoc with a quoted marker):
#   bash .claude/scripts/codex-image.sh --out <path.png> [--cwd <abs-dir>] [--size <WxH>] \
#        [--transparent] [--force] [--model <model>] [--wait-s <sec>] <<'CODEX_PROMPT_END'
#   ...what to draw: subject, style, palette...
#   CODEX_PROMPT_END
#   bash .claude/scripts/codex-image.sh check         # readiness: CLI and the image_generation feature
#
# What it does: runs `codex exec` in a read-only sandbox (Codex does not write to the tree) in the
# `--cwd` directory (default — the current one), waits up to `--wait-s` (default 480 s — a Claude
# Bash call is limited to 10 minutes; generation usually takes 1–3 minutes), finds the result in
# `$CODEX_HOME/generated_images/<thread_id>/` (thread_id — from the JSONL events of this same run,
# foreign images are not picked up) and copies it to `--out` itself. Prints:
#   IMAGE=<absolute path of the copy>
#   SOURCE=<source file in $CODEX_HOME>
# `--out` — `.png` only, only inside `--cwd` (no `..`, a symlink leading outside will not pass); an
# existing file is not overwritten without `--force`. `--size` and `--transparent` are hints to the
# model, not a guarantee: check size and alpha channel afterwards (`file <path>`); rembg removes the background more cleanly.
# Any engine failure (CLI not found, feature disabled, no login, the tool returned no file,
# timeout) — `IMAGE=UNAVAILABLE` + `Reason: …`, exit code 0: the task is not blocked by this,
# the caller writes the reason into "Needs attention". Argument errors — exit code 2.
#
# Environment variable CODEX_BIN — explicit path to `codex` (for tests, overrides the PATH lookup).
#
# Regression test: bash .claude/scripts/codex-image.test.sh

set -u

DEFAULT_WAIT_S=480
CODEX_HOME_DIR="${CODEX_HOME:-${HOME:-/tmp}/.codex}"

unavailable() {
  printf 'IMAGE=UNAVAILABLE\nReason: %s\n' "$1"
  exit 0
}

usage_error() { echo "$1" >&2; exit 2; }

resolve_codex() {
  if [ -n "${CODEX_BIN:-}" ]; then
    [ -x "$CODEX_BIN" ] && { echo "$CODEX_BIN"; return 0; }
    return 1
  fi
  command -v codex 2>/dev/null
}

feature_enabled() {
  "$CODEX" features list 2>/dev/null | grep -qE '^image_generation +[^ ]+ +true'
}

CMD_OR_FLAG="${1:-}"
CODEX=$(resolve_codex) || unavailable "codex CLI not found in PATH; install: npm i -g @openai/codex, then codex login"

if [ "$CMD_OR_FLAG" = "check" ]; then
  feature_enabled || unavailable "image_generation feature is disabled; enable: codex features enable image_generation"
  printf 'IMAGE=READY\ncodex=%s\n' "$("$CODEX" --version 2>/dev/null | head -1)"
  exit 0
fi

OUT=""; CWD=""; SIZE=""; TRANSPARENT=0; FORCE=0; MODEL=""; WAIT_S="$DEFAULT_WAIT_S"
while [ $# -gt 0 ]; do
  case "$1" in
    --out|--cwd|--size|--model|--wait-s)
      [ -n "${2:-}" ] || usage_error "$1: value required"
      case "$1" in
        --out) OUT="$2" ;;
        --cwd) CWD="$2" ;;
        --size) SIZE="$2" ;;
        --model) MODEL="$2" ;;
        --wait-s) WAIT_S="$2" ;;
      esac
      shift 2 ;;
    --transparent) TRANSPARENT=1; shift ;;
    --force) FORCE=1; shift ;;
    *) sed -n '6,11p' "$0" >&2; usage_error "unknown argument: $1" ;;
  esac
done

[ -n "$OUT" ] || usage_error "--out is required (path to a .png inside the working directory)"
case "$OUT" in *.png) ;; *) usage_error "--out must end with .png (got: '$OUT')" ;; esac
case "$SIZE" in ""|[0-9]*x[0-9]*) ;; *) usage_error "--size must be WxH, e.g. 1024x1024 (got: '$SIZE')" ;; esac
case "$WAIT_S" in ""|*[!0-9]*) usage_error "--wait-s must be a whole number of seconds (got: '$WAIT_S')" ;; esac
[ -n "$CWD" ] || CWD="$(pwd)"
[ -d "$CWD" ] || usage_error "--cwd directory does not exist: $CWD"
CWD_REAL=$(cd "$CWD" && pwd -P) || usage_error "--cwd directory is not accessible: $CWD"

# --out: inside --cwd. A relative one is taken from --cwd; `..` is forbidden; after mkdir — a check of
# the parent's physical path (a symlinked directory leading outside will not pass).
case "/$OUT/" in */../*) usage_error "--out must not contain '..': $OUT" ;; esac
case "$OUT" in
  /*) case "$OUT" in "$CWD_REAL"/*|"${CWD%/}"/*) OUT_ABS="$OUT" ;; *) usage_error "--out is outside the working directory ($CWD_REAL): $OUT" ;; esac ;;
  *) OUT_ABS="$CWD_REAL/$OUT" ;;
esac
OUT_DIR=$(dirname "$OUT_ABS")
mkdir -p "$OUT_DIR" || usage_error "could not create directory: $OUT_DIR"
OUT_DIR_REAL=$(cd "$OUT_DIR" && pwd -P)
case "$OUT_DIR_REAL/" in "$CWD_REAL"/*) ;; *) usage_error "--out leads outside the working directory ($CWD_REAL): $OUT_DIR_REAL" ;; esac
OUT_ABS="$OUT_DIR_REAL/$(basename "$OUT_ABS")"
[ ! -e "$OUT_ABS" ] || [ $FORCE -eq 1 ] || usage_error "file already exists (overwrite — with --force): $OUT_ABS"

command -v jq >/dev/null 2>&1 || unavailable "jq not found in PATH"
feature_enabled || unavailable "image_generation feature is disabled; enable: codex features enable image_generation"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/codex-image.XXXXXX") || unavailable "could not create a temp directory"
CODEX_PID=""
cleanup() { [ -n "$CODEX_PID" ] && kill "$CODEX_PID" 2>/dev/null; rm -rf -- "$WORK"; }
trap cleanup EXIT

{
  printf '%s\n' "Use the built-in image generation tool (image_gen) to generate exactly ONE raster image described below."
  printf '%s\n' "Do not write code to draw it. Do not create, modify, move or copy any files in the workspace — the caller collects the generated file itself."
  printf '%s\n' "If the image generation tool is not available in this session, reply exactly: NO_IMAGE_TOOL. Otherwise reply with one line: DONE."
  [ -n "$SIZE" ] && printf 'Target size / aspect ratio: %s pixels.\n' "$SIZE"
  [ $TRANSPARENT -eq 1 ] && printf '%s\n' "Background: fully transparent (alpha channel); the subject fits inside the canvas with a small margin."
  printf '\nImage description:\n'
  cat
} > "$WORK/prompt.txt"
# the description is everything that came from stdin after the service header
[ -n "$(sed -n '/^Image description:$/,$p' "$WORK/prompt.txt" | sed '1d' | tr -d '[:space:]')" ] || unavailable "empty image description on stdin"

set -- exec --skip-git-repo-check -s read-only -C "$CWD_REAL" --json -o "$WORK/last.txt"
[ -n "$MODEL" ] && set -- "$@" -m "$MODEL"
"$CODEX" "$@" - < "$WORK/prompt.txt" > "$WORK/events.jsonl" 2> "$WORK/stderr.txt" &
CODEX_PID=$!

START=$(date +%s)
while kill -0 "$CODEX_PID" 2>/dev/null; do
  if [ $(( $(date +%s) - START )) -ge "$WAIT_S" ]; then
    kill "$CODEX_PID" 2>/dev/null
    unavailable "timeout ${WAIT_S} s — Codex did not finish generating (process stopped)"
  fi
  sleep 1
done
wait "$CODEX_PID"; RC=$?
CODEX_PID=""

LAST=$(head -c 600 "$WORK/last.txt" 2>/dev/null | tr '\n' ' ')
ERR=$(tail -c 600 "$WORK/stderr.txt" 2>/dev/null | tr '\n' ' ')
THREAD_ID=$(jq -r 'select(.type == "thread.started") | .thread_id // empty' "$WORK/events.jsonl" 2>/dev/null | head -1)
[ -n "$THREAD_ID" ] || unavailable "codex exec did not open a thread (rc=$RC; not logged in? — codex login): ${LAST}${ERR}"

SOURCE=$(ls -t "$CODEX_HOME_DIR/generated_images/$THREAD_ID"/*.png 2>/dev/null | head -1)
[ -n "$SOURCE" ] && [ -s "$SOURCE" ] || unavailable "Codex returned no image (rc=$RC, thread $THREAD_ID): ${LAST:-no reply} ${ERR}"

cp -- "$SOURCE" "$OUT_ABS" || unavailable "could not copy $SOURCE → $OUT_ABS"
printf 'IMAGE=%s\nSOURCE=%s\n' "$OUT_ABS" "$SOURCE"
