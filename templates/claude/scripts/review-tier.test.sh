#!/bin/bash
# Regression test of the review-tier.sh matrix (agent-pipeline).
# Run from the repository root:  bash .claude/scripts/review-tier.test.sh
# Runs on a TEMPORARY git repository (mktemp), does not touch the working tree.
# Besides the tier matrix it checks the strictness profiles REVIEW_PROFILE=standard|strict|light.
# Variants are built by replacing the WHOLE CRITICAL_GLOBS array with a fixture one — the test works
# the same on the raw template (init marker not substituted) and in a deployed repo.
# exit 0 — the matrix is green, exit 1 — there are mismatches.

RAW="$(cd "$(dirname "$0")" && pwd)/review-tier.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/review-tier-test.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "TMP is empty" >&2; exit 1; }
cleanup() { [ -d "$TMP" ] && find "$TMP" -depth -delete 2>/dev/null; }
trap cleanup EXIT

PASS=0; FAIL=0

# A copy of the script "after init": the CRITICAL_GLOBS array is replaced as a whole (globs — one line inside the array).
# The CODEX_* constants and REVIEW_BACKEND are pinned too: the matrix checks the logic, not the owner's choice in the interview.
make_variant() { # <out> <profile> <globs-line> [backend]
  awk -v prof="$2" -v globs="$3" -v backend="${4:-both}" '
    /^CRITICAL_GLOBS=\(/ { print "CRITICAL_GLOBS="; print globs; print ")"; skip=1; next }
    skip && /^\)/ { skip=0; next }
    skip { next }
    /^REVIEW_PROFILE=/ { print "REVIEW_PROFILE=\"" prof "\""; next }
    /^REVIEW_BACKEND=/ { print "REVIEW_BACKEND=\"" backend "\""; next }
    /^CODEX_MODEL=/ { print "CODEX_MODEL=\"gpt-5.6-sol\""; next }
    /^CODEX_EFFORT_R12=/ { print "CODEX_EFFORT_R12=\"high\""; next }
    /^CODEX_EFFORT_R3=/ { print "CODEX_EFFORT_R3=\"xhigh\""; next }
    { print }
  ' "$RAW" | sed 's/^CRITICAL_GLOBS=$/CRITICAL_GLOBS=(/' > "$1"
}
PROJECT_GLOBS="  '.claude/*' '.worktreeinclude' 'server/auth.ts' 'shared/schema.ts' 'migrations/*' 'server/payment*' 'docs/verified/*'"
BASE_GLOBS="  '.claude/*' '.worktreeinclude'"
SCRIPT="$TMP/review-tier.standard.sh"; make_variant "$SCRIPT" standard "$PROJECT_GLOBS"
STRICT="$TMP/review-tier.strict.sh";   make_variant "$STRICT" strict "$PROJECT_GLOBS"
LIGHT="$TMP/review-tier.light.sh";     make_variant "$LIGHT" light "$PROJECT_GLOBS"
# The "base paths only" variant — checks that .claude/* is critical by itself.
BASE="$TMP/review-tier.base.sh";       make_variant "$BASE" standard "$BASE_GLOBS"
ONLYCL="$TMP/review-tier.claude.sh";   make_variant "$ONLYCL" standard "$PROJECT_GLOBS" claude
ONLYCX="$TMP/review-tier.codex.sh";    make_variant "$ONLYCX" standard "$PROJECT_GLOBS" codex
STRICTCL="$TMP/review-tier.strict-claude.sh"; make_variant "$STRICTCL" strict "$PROJECT_GLOBS" claude

# fresh_repo — a clean repository with one commit holding every file a case is going to "change"
fresh_repo() {
  [ -d "$TMP/repo" ] && find "$TMP/repo" -depth -delete 2>/dev/null
  mkdir -p "$TMP/repo"; cd "$TMP/repo" || exit 1
  git init -q -b main .
  git config user.email t@t; git config user.name t
  for f in todo.md claude-progress.md blockers.md README.md docs/a.md docs/verified/R5.md \
           server/routes.ts server/x.ts server/y.ts server/z.ts client/src/x.tsx \
           server/payments/charge.ts .claude/agents/x.md .worktreeinclude shared/schema.ts \
           server/auth.ts migrations/0001.sql; do
    mkdir -p "$(dirname "$f")"; printf 'base\n' > "$f"
  done
  git add -A >/dev/null; git commit -q -m base
}
# add_lines <file> <n> — append n lines (to a tracked file = n added diff lines)
add_lines() { mkdir -p "$(dirname "$1")"; local i=0; while [ $i -lt "$2" ]; do echo "line $i" >> "$1"; i=$((i+1)); done; }

# expect <name> <TIER> <CODEX> <ROUND2> [--task "<line>"] [--script <path>] [WARN|NOWARN]
expect() {
  local name="$1" tier="$2" codex="$3" round2="$4"; shift 4
  local task="" wantwarn="NOWARN" script="$SCRIPT"
  while [ $# -gt 0 ]; do case "$1" in --task) task="$2"; shift 2;; --script) script="$2"; shift 2;; WARN|NOWARN) wantwarn="$1"; shift;; esac; done
  local out
  if [ -n "$task" ]; then out=$(bash "$script" --task "$task"); else out=$(bash "$script"); fi
  local got_tier got_codex got_round2 got_warn
  got_tier=$(printf '%s\n' "$out" | sed -n 's/^TIER=//p')
  got_codex=$(printf '%s\n' "$out" | sed -n 's/^CODEX=//p')
  got_round2=$(printf '%s\n' "$out" | sed -n 's/^ROUND2=//p')
  if printf '%s\n' "$out" | grep -q '^WARN='; then got_warn=WARN; else got_warn=NOWARN; fi
  if [ "$got_tier" = "$tier" ] && [ "$got_codex" = "$codex" ] && [ "$got_round2" = "$round2" ] && [ "$got_warn" = "$wantwarn" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $name — expected $tier/$codex/$round2/$wantwarn, got $got_tier/$got_codex/$got_round2/$got_warn"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}
# field <script> <KEY> — the value of the KEY= line from the output
field() { bash "$1" | sed -n "s/^$2=//p"; }
# check <name> <got> <want>
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected '$3', got '$2'"; fi; }

# 1. empty diff → R1
fresh_repo; expect "empty diff" R1 high light

# 2. bookkeeping only → R0
fresh_repo; add_lines todo.md 30; add_lines claude-progress.md 5; expect "state-only" R0 none none

# 3. docs, 15 lines → R0
fresh_repo; add_lines README.md 10; add_lines docs/a.md 5; expect "docs 15 lines" R0 none none

# 4. docs, 40 lines → R1
fresh_repo; add_lines docs/a.md 40; expect "docs 40 lines" R1 high light

# 5. exactly 20 lines of docs → R0 (boundary inclusive)
fresh_repo; add_lines docs/a.md 20; expect "docs exactly 20" R0 none none

# 6. critical doc, 3 lines → R3 (a critical path outranks docs-only)
fresh_repo; add_lines docs/verified/R5.md 3; expect "critical doc" R3 xhigh light

# 7. code, 2 files / 50 lines → R1
fresh_repo; add_lines server/x.ts 25; add_lines server/y.ts 25; expect "code 2 files 50 lines" R1 high light

# 8. code, 3 files of 5 lines each → R2 (files > 2)
fresh_repo; add_lines server/x.ts 5; add_lines server/y.ts 5; add_lines server/z.ts 5; expect "code 3 files" R2 high light

# 9. code, 1 file / 61 lines → R2 (lines > 60)
fresh_repo; add_lines server/x.ts 61; expect "code 61 lines" R2 high light

# 10. routes.ts, 200 lines → R2 (not critical)
fresh_repo; add_lines server/routes.ts 200; expect "routes.ts" R2 high light

# 11. client/src → R2 above 60 lines, R1 when small
fresh_repo; add_lines client/src/x.tsx 100; expect "client big" R2 high light
fresh_repo; add_lines client/src/x.tsx 10; expect "client small" R1 high light

# 12. payment path (glob with a directory), 1 line → R3
fresh_repo; add_lines server/payments/charge.ts 1; expect "payment glob 1 line" R3 xhigh light

# 13. schema → R3
fresh_repo; add_lines shared/schema.ts 2; expect "schema" R3 xhigh light

# 14. .claude/** (md!) → R3, not docs-only; .worktreeinclude → R3
fresh_repo; add_lines .claude/agents/x.md 3; expect ".claude md" R3 xhigh light
fresh_repo; add_lines .worktreeinclude 1; expect ".worktreeinclude" R3 xhigh light

# 15. auth / migrations → R3
fresh_repo; add_lines server/auth.ts 1; expect "auth" R3 xhigh light
fresh_repo; add_lines migrations/0001.sql 1; expect "migration" R3 xhigh light

# 16. code + bookkeeping together → by the code (bookkeeping does not make the diff state-only)
fresh_repo; add_lines server/x.ts 5; add_lines todo.md 3; expect "code + state" R1 high light

# 17. an untracked file counts: a new code file of 70 lines → R2
fresh_repo; add_lines server/new.ts 70; expect "untracked code 70" R2 high light
# a new untracked critical file → R3
fresh_repo; add_lines server/payments/new.ts 1; expect "untracked critical" R3 xhigh light

# 18. the marker overrides: [review: R1] on critical paths → R1 + WARN
fresh_repo; add_lines server/auth.ts 1
expect "marker R1 on critical" R1 high light --task '- [ ] **X-1. Task.** [review: R1] text' WARN
# the marker raises: [review: R3] on small code → R3 without WARN
fresh_repo; add_lines server/x.ts 2
expect "marker R3 on small" R3 xhigh light --task '- [ ] **X-2. Task.** [review: R3]' NOWARN
# a marker with a double space inside the brackets and R0 on docs
fresh_repo; add_lines docs/a.md 100
expect "marker R0 docs" R0 none none --task '**X-3.** [review:  R0]' NOWARN
# a task line without a marker → auto
fresh_repo; add_lines server/x.ts 2
expect "no marker" R1 high light --task '- [ ] **X-4. No marker.** [MANUAL]' NOWARN
# 18a. legacy spelling `[ревью: Rn]` (todo.md written by earlier versions) still works; REASON prints the canonical one
fresh_repo; add_lines server/x.ts 2
expect "legacy marker R3 on small" R3 xhigh light --task '- [ ] **X-5. Task.** [ревью: R3]' NOWARN
check "legacy marker: canonical spelling in REASON" "$(bash "$SCRIPT" --task '- [ ] **X-5. Task.** [ревью: R3]' | sed -n 's/^REASON=\(marker \[review: R3\]\).*/\1/p')" "marker [review: R3]"
fresh_repo; add_lines server/auth.ts 1
expect "legacy marker R1 on critical" R1 high light --task '- [ ] **X-6. Task.** [ревью: R1] text' WARN

# 19. binary file → "large" → R2
fresh_repo; printf 'PNG\000\000\001binary\000payload\n' > server/blob.bin; expect "binary untracked" R2 high light

# 20. file deletion — the lines count, the tier goes by the code
fresh_repo; git rm -q server/x.ts; expect "deleted file" R1 high light

# 21. an untracked docs file of 21 lines WITHOUT a final newline → 21 lines → R1 (not R0)
fresh_repo; { i=0; while [ $i -lt 20 ]; do echo "l$i"; i=$((i+1)); done; printf 'last'; } > docs/b.md
expect "untracked no trailing newline 21 lines" R1 high light

# 22. a path with a space and a non-ASCII path (core.quotePath) — the critical path is recognized
fresh_repo; add_lines "docs/verified/ø 1.md" 2; expect "non-ascii+space critical untracked" R3 xhigh light
fresh_repo; mkdir -p "docs/verified"; printf 'base\n' > "docs/verified/ø2.md"; git add -A >/dev/null; git commit -q -m add
add_lines "docs/verified/ø2.md" 1; expect "non-ascii critical tracked" R3 xhigh light

# 23. rename of a tracked file (--no-renames: deletion + addition, both sides count)
fresh_repo; git mv server/x.ts server/renamed.ts; expect "rename" R1 high light

# 24. staged-only new file (in the index, not in untracked) — counted through the diff against HEAD
fresh_repo; add_lines server/staged.ts 70; git add server/staged.ts; expect "staged new file" R2 high light

# 25. run from a subdirectory — same result
fresh_repo; add_lines server/auth.ts 1; cd server
expect "run from subdir" R3 xhigh light; cd "$TMP/repo"

# 26. --task-id takes the line from the repository's todo.md
fresh_repo; printf -- '- [ ] **X-9. Task.** [review: R3] text\n' >> todo.md; git add todo.md; git commit -q -m todo
add_lines server/x.ts 2
out=$(bash "$SCRIPT" --task-id X-9); if printf '%s\n' "$out" | grep -q '^TIER=R3$'; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: --task-id"; printf '%s\n' "$out"; fi
out=$(bash "$SCRIPT" --task-id NOPE 2>/dev/null); if printf '%s\n' "$out" | grep -q '^TIER=R1$'; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: --task-id unknown → auto"; printf '%s\n' "$out"; fi
# 26a. --task-id with the legacy marker spelling in todo.md
fresh_repo; printf -- '- [ ] **X-10. Task.** [ревью: R3] text\n' >> todo.md; git add todo.md; git commit -q -m todo
add_lines server/x.ts 2
out=$(bash "$SCRIPT" --task-id X-10); if printf '%s\n' "$out" | grep -q '^TIER=R3$'; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: --task-id legacy marker"; printf '%s\n' "$out"; fi

# 27. argument errors: missing value / bad base → non-zero exit code, no hang
fresh_repo
if bash "$SCRIPT" --task >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: --task without a value must fail"; else PASS=$((PASS+1)); fi
if bash "$SCRIPT" --base refs/heads/missing >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: a bad --base must fail"; else PASS=$((PASS+1)); fi

# 28. Raw template (placeholder not substituted): no project paths, but .claude/* is critical
fresh_repo; add_lines server/auth.ts 1; expect "base globs: auth not critical" R1 high light --script "$BASE"
fresh_repo; add_lines .claude/agents/x.md 1; expect "base globs: .claude critical" R3 xhigh light --script "$BASE"

# 29. CODEX_MODEL and ROUND1 are printed; on R0 the model is none
fresh_repo; add_lines server/auth.ts 1
check "CODEX_MODEL on R3" "$(field "$SCRIPT" CODEX_MODEL)" "gpt-5.6-sol"
check "ROUND1 on R3" "$(field "$SCRIPT" ROUND1)" "double"
check "PROFILE printed" "$(field "$SCRIPT" PROFILE)" "standard"
fresh_repo; add_lines server/x.ts 2
check "ROUND1 on R1" "$(field "$SCRIPT" ROUND1)" "single"
fresh_repo; add_lines todo.md 1
check "CODEX_MODEL on R0" "$(field "$SCRIPT" CODEX_MODEL)" "none"
check "ROUND1 on R0" "$(field "$SCRIPT" ROUND1)" "none"

# 30. Profile strict: R1 → round 2 escalation; R2 → round 1 double + round 2 double; R3 → round 2 double
fresh_repo; add_lines server/x.ts 2;  expect "strict R1" R1 high escalate --script "$STRICT"
fresh_repo; add_lines server/x.ts 61; expect "strict R2" R2 high double --script "$STRICT"
check "strict R2 round1 double" "$(field "$STRICT" ROUND1)" "double"
fresh_repo; add_lines server/auth.ts 1; expect "strict R3" R3 xhigh double --script "$STRICT"

# 31. Profile light: R1 no review; R2 one Codex; R3 double round 1, light round 2
fresh_repo; add_lines server/x.ts 2;  expect "light R1" R1 none none --script "$LIGHT"
check "light R1 round1 none" "$(field "$LIGHT" ROUND1)" "none"
fresh_repo; add_lines server/x.ts 61; expect "light R2" R2 high light --script "$LIGHT"
fresh_repo; add_lines server/auth.ts 1; expect "light R3" R3 xhigh light --script "$LIGHT"
check "light R3 round1 double" "$(field "$LIGHT" ROUND1)" "double"
check "light R3 consolidator no" "$(field "$LIGHT" CONSOLIDATOR)" "no"
check "standard R3 consolidator yes" "$(field "$SCRIPT" CONSOLIDATOR)" "yes"
fresh_repo; add_lines server/x.ts 2
check "standard R1 consolidator no" "$(field "$SCRIPT" CONSOLIDATOR)" "no"

# 31. REVIEW_BACKEND=claude: Codex is not called, double → single, no consolidator
fresh_repo; add_lines server/auth.ts 1; expect "backend claude R3" R3 none light --script "$ONLYCL"
check "backend claude R3 round1 single" "$(field "$ONLYCL" ROUND1)" "single"
check "backend claude R3 consolidator no" "$(field "$ONLYCL" CONSOLIDATOR)" "no"
check "backend claude R3 model none" "$(field "$ONLYCL" CODEX_MODEL)" "none"
fresh_repo; add_lines server/x.ts 2; expect "backend claude R1" R1 none light --script "$ONLYCL"
fresh_repo; add_lines todo.md 1; expect "backend claude R0" R0 none none --script "$ONLYCL"
# 32. REVIEW_BACKEND=codex: no Claude reader, double → single
fresh_repo; add_lines server/auth.ts 1; expect "backend codex R3" R3 xhigh light --script "$ONLYCX"
check "backend codex R3 round1 single" "$(field "$ONLYCX" ROUND1)" "single"
check "backend codex R3 consolidator no" "$(field "$ONLYCX" CONSOLIDATOR)" "no"
check "backend line printed" "$(field "$ONLYCX" BACKEND)" "codex"
# 32a. strict + backend claude: round 2 escalate/double → light, round 1 double → single
fresh_repo; add_lines server/x.ts 2;  expect "strict+claude R1" R1 none light --script "$STRICTCL"
fresh_repo; add_lines server/x.ts 61; expect "strict+claude R2" R2 none light --script "$STRICTCL"
check "strict+claude R2 round1 single" "$(field "$STRICTCL" ROUND1)" "single"
check "strict+claude R2 consolidator no" "$(field "$STRICTCL" CONSOLIDATOR)" "no"
fresh_repo; add_lines server/auth.ts 1; expect "strict+claude R3" R3 none light --script "$STRICTCL"
# 33. The task line is the task's own only: a mention of **ID. in another line with a marker is not applied
fresh_repo; add_lines server/auth.ts 1
printf -- '- [ ] **META-1. Summary.** [review: R0] see **AUTH-3. Login.**\n- [ ] **AUTH-3. Login.** [review: R3] text\n' > todo.md
out=$(bash "$SCRIPT" --task-id AUTH-3); check "anchored task line: own marker R3" "$(printf '%s\n' "$out" | sed -n 's/^TIER=//p')" "R3"
printf -- '- [ ] **META-1. Summary.** [review: R0] see **AUTH-3. Login.**\n- [ ] **AUTH-3. Login.** text\n' > todo.md
out=$(bash "$SCRIPT" --task-id AUTH-3); check "anchored task line: no foreign marker" "$(printf '%s\n' "$out" | sed -n 's/^TIER=//p')" "R3"

echo "review-tier: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
