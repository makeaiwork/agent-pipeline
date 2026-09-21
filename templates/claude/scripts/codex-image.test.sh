#!/bin/bash
# Regression test for the codex-image.sh wrapper — no live Codex: a stub (CODEX_BIN) is substituted
# for the CLI; it writes the arguments and the prompt to a log, prints JSONL events and puts an "image"
# into $CODEX_HOME/generated_images/<thread_id>/. Run: bash .claude/scripts/codex-image.test.sh

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/codex-image.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/codex-image-test.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
STUB="$TMP/stub-codex"
LOG="$TMP/calls.log"
REPO="$TMP/repo"
export CODEX_HOME="$TMP/codex-home"
FAIL=0
mkdir -p "$REPO" "$CODEX_HOME" "$TMP/outside"

cat > "$STUB" <<'EOS'
#!/bin/bash
mode="${STUB_MODE:-ok}"
printf '%s\n' "$*" >> "$STUB_LOG"
if [ "$1" = "--version" ]; then echo "codex-cli 0.0.0-stub"; exit 0; fi
if [ "$1" = "features" ]; then
  if [ "$mode" = "feature-off" ]; then echo "image_generation                         stable             false"
  else echo "image_generation                         stable             true"; fi
  exit 0
fi
[ "$1" = "exec" ] || exit 3
last=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && last="$a"; prev="$a"; done
{ printf 'PROMPT<<'; cat; printf '>>\n'; } >> "$STUB_LOG"
[ "$mode" = "hang" ] && sleep 30
[ "$mode" = "no-thread" ] && { echo "not logged in" >&2; exit 1; }
tid="thread-$mode"
echo "{\"type\":\"thread.started\",\"thread_id\":\"$tid\"}"
if [ "$mode" = "no-image" ]; then printf 'NO_IMAGE_TOOL' > "$last"; exit 0; fi
mkdir -p "$CODEX_HOME/generated_images/$tid" "$CODEX_HOME/generated_images/thread-other"
printf 'PNG-foreign' > "$CODEX_HOME/generated_images/thread-other/zzz.png"
printf 'PNG-stub-%s' "$mode" > "$CODEX_HOME/generated_images/$tid/exec-1.png"
printf 'DONE' > "$last"
echo '{"type":"turn.completed"}'
EOS
chmod +x "$STUB"

run_wrapper() { # mode, args...
  local mode="$1"; shift
  : > "$LOG"
  printf 'Red fox, flat icon\nsecond line\n' | CODEX_BIN="$STUB" STUB_LOG="$LOG" STUB_MODE="$mode" bash "$SCRIPT" --cwd "$REPO" "$@" 2>&1
}

check() { # name, output, expected-substring
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "PASS: $1"; else echo "FAIL: $1 — expected '$3', got:"; printf '%s\n' "$2" | sed 's/^/    /'; FAIL=1; fi
}

# happy path: the file is copied to --out (creating the subdirectory), taken from the thread of THIS run
out=$(run_wrapper ok --out assets/img/fox.png)
if printf '%s' "$out" | grep -qF "IMAGE=$REPO/assets/img/fox.png" && [ "$(cat "$REPO/assets/img/fox.png")" = "PNG-stub-ok" ] \
   && printf '%s' "$out" | grep -qF "SOURCE=$CODEX_HOME/generated_images/thread-ok/exec-1.png"; then
  echo "PASS: happy path (copy in --out, source — the thread of this run)"
else echo "FAIL: happy path:"; printf '%s\n' "$out" | sed 's/^/    /'; FAIL=1; fi

# codex exec arguments: read-only, cwd, JSONL, the prompt from stdin in full, size and background hints
run_wrapper ok --out a.png --size 512x512 --transparent --model gpt-img >/dev/null
if grep -q "^exec --skip-git-repo-check -s read-only -C $REPO --json -o .* -m gpt-img -\$" "$LOG" \
   && grep -q '^Red fox' "$LOG" && grep -q '^second line' "$LOG" \
   && grep -q '512x512' "$LOG" && grep -q 'transparent' "$LOG" && ! grep -q 'workspace-write' "$LOG"; then
  echo "PASS: exec arguments (read-only, -C, model, prompt from stdin, size and transparency)"
else echo "FAIL: exec arguments:"; sed 's/^/    /' "$LOG"; FAIL=1; fi

# existing file: without --force — refusal (exit code 2), with --force — overwrite
out=$(run_wrapper ok --out a.png); rc=$?
if [ $rc -eq 2 ] && printf '%s' "$out" | grep -qF "already exists"; then echo "PASS: an existing file is not overwritten"; else echo "FAIL: existing file (rc=$rc): $out"; FAIL=1; fi
check "--force overwrites"                      "$(run_wrapper ok --out a.png --force)"            "IMAGE=$REPO/a.png"
check "absolute --out inside cwd"               "$(run_wrapper ok --out "$REPO/abs.png")"          "IMAGE=$REPO/abs.png"

# --out outside: `..`, an absolute path outside cwd, a symlinked directory leading outside — exit code 2, Codex is not called
for bad in "../escape.png" "$TMP/outside/x.png" "assets/../../y.png"; do
  out=$(run_wrapper ok --out "$bad"); rc=$?
  if [ $rc -eq 2 ] && ! grep -q '^exec ' "$LOG"; then echo "PASS: --out outside rejected ($bad)"; else echo "FAIL: --out outside ($bad, rc=$rc): $out"; FAIL=1; fi
done
ln -s "$TMP/outside" "$REPO/link-out"
out=$(run_wrapper ok --out link-out/z.png); rc=$?
if [ $rc -eq 2 ] && [ ! -e "$TMP/outside/z.png" ] && ! grep -q '^exec ' "$LOG"; then echo "PASS: symlinked directory leading outside rejected"; else echo "FAIL: symlink outside (rc=$rc): $out"; FAIL=1; fi

# argument validation — exit code 2
out=$(run_wrapper ok); rc=$?
if [ $rc -eq 2 ] && printf '%s' "$out" | grep -qF -- "--out is required"; then echo "PASS: --out is required"; else echo "FAIL: no --out (rc=$rc): $out"; FAIL=1; fi
if run_wrapper ok --out b.jpg >/dev/null; then echo "FAIL: a non-.png must be rejected"; FAIL=1; else echo "PASS: .png only"; fi
if run_wrapper ok --out b.png --size big >/dev/null; then echo "FAIL: --size big must be rejected"; FAIL=1; else echo "PASS: --size only WxH"; fi
out=$(run_wrapper ok --out b.png --size); rc=$?
if [ $rc -eq 2 ] && printf '%s' "$out" | grep -qF "value required"; then echo "PASS: flag without a value"; else echo "FAIL: flag without a value (rc=$rc): $out"; FAIL=1; fi

# engine failures → IMAGE=UNAVAILABLE, exit code 0, no file
for case_ in "feature-off|image_generation feature is disabled" "no-image|NO_IMAGE_TOOL" "no-thread|did not open a thread"; do
  mode="${case_%%|*}"; want="${case_#*|}"
  out=$(run_wrapper "$mode" --out "u-$mode.png"); rc=$?
  if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qF "IMAGE=UNAVAILABLE" && printf '%s' "$out" | grep -qF "$want" && [ ! -e "$REPO/u-$mode.png" ]; then
    echo "PASS: $mode → UNAVAILABLE"
  else echo "FAIL: $mode (rc=$rc):"; printf '%s\n' "$out" | sed 's/^/    /'; FAIL=1; fi
done

out=$(run_wrapper hang --out hang.png --wait-s 1); rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qF "timeout 1 s" && [ ! -e "$REPO/hang.png" ]; then echo "PASS: timeout → UNAVAILABLE"; else echo "FAIL: timeout (rc=$rc): $out"; FAIL=1; fi

out=$(printf '  \n' | CODEX_BIN="$STUB" STUB_LOG="$LOG" STUB_MODE=ok bash "$SCRIPT" --cwd "$REPO" --out empty.png 2>&1); rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qF "empty image description"; then echo "PASS: empty description → UNAVAILABLE"; else echo "FAIL: empty description (rc=$rc): $out"; FAIL=1; fi

out=$(printf 'x\n' | CODEX_BIN="$TMP/nope" bash "$SCRIPT" --cwd "$REPO" --out n.png 2>&1); rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qF "codex CLI not found"; then echo "PASS: CLI not found → UNAVAILABLE"; else echo "FAIL: CLI not found (rc=$rc): $out"; FAIL=1; fi

# check: readiness without generation
check "check: ready"                            "$(CODEX_BIN="$STUB" STUB_LOG="$LOG" STUB_MODE=ok bash "$SCRIPT" check 2>&1)"          "IMAGE=READY"
check "check: feature disabled"                 "$(CODEX_BIN="$STUB" STUB_LOG="$LOG" STUB_MODE=feature-off bash "$SCRIPT" check 2>&1)" "IMAGE=UNAVAILABLE"

rm -rf -- "$TMP"
[ $FAIL -eq 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
