#!/bin/bash
# Regression test of task-commit.sh.
# Run from the repository root:  bash .claude/scripts/task-commit.test.sh
# Runs on a TEMPORARY git repository (mktemp), does not touch the working tree.
# exit 0 — the matrix is green, exit 1 — there are mismatches.

SCRIPT="$(cd "$(dirname "$0")" && pwd)/task-commit.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/task-commit-test.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "TMP is empty" >&2; exit 1; }
cleanup() { [ -d "$TMP" ] && find "$TMP" -depth -delete 2>/dev/null; }
trap cleanup EXIT

PASS=0; FAIL=0

fresh_repo() {
  [ -d "$TMP/repo" ] && find "$TMP/repo" -depth -delete 2>/dev/null
  mkdir -p "$TMP/repo"; cd "$TMP/repo" || exit 1
  git init -q -b main .
  git config user.email t@t; git config user.name t
  mkdir -p server
  printf -- '- [ ] **M-A3. Task.** text\n- [ ] **M-A3-1. Child.** text\n- [ ] **AG-1. More.**\n' > todo.md
  printf 'base\n' > claude-progress.md; printf 'base\n' > blockers.md; printf 'base\n' > server/x.ts
  git add -A >/dev/null; git commit -q -m base
}
# commit <subject> <files…> — append a line to each file and commit with that subject
commit() { local s="$1"; shift; for f in "$@"; do echo "x" >> "$f"; done; git add -A >/dev/null; git commit -q -m "$s"; }
close_todo() { sed -i.bak "s/^- \[ \] \*\*$1\./- [x] **$1./" todo.md; rm -f todo.md.bak; }

# expect <name> <ID> <RESULT-regex> <TODO>
expect() {
  local name="$1" id="$2" want="$3" todo="$4" out got_res got_todo
  out=$(bash "$SCRIPT" --task-id "$id")
  got_res=$(printf '%s\n' "$out" | sed -n 's/^RESULT=//p')
  got_todo=$(printf '%s\n' "$out" | sed -n 's/^TODO=//p')
  if printf '%s' "$got_res" | grep -qE "^$want$" && [ "$got_todo" = "$todo" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); echo "FAIL: $name — expected RESULT~/$want/ TODO=$todo, got RESULT=$got_res TODO=$got_todo"
  fi
}
hash_of() { git log --format=%h --grep="$1" -1; }

# 1. no commits → NONE, the line is open
fresh_repo; expect "none" M-A3 'NONE' open

# 2. work commit with code → DONE <hash>
fresh_repo; commit 'feat(x): M-A3 — done' server/x.ts; expect "work commit" M-A3 "DONE $(hash_of 'M-A3 — done')" open

# 3. a child task's work commit does NOT match the parent (a hyphen is not a boundary)
fresh_repo; commit 'feat(x): M-A3-1 — child' server/x.ts; expect "child not parent" M-A3 'NONE' open
expect "child itself" M-A3-1 "DONE $(hash_of 'M-A3-1')" open

# 4. ID mid-subject — not a work commit
fresh_repo; commit 'docs(todo): close M-A3 and open M-A3-1' server/x.ts; expect "id mid-subject" M-A3 'NONE' open

# 5. ID only in the commit body — not a work commit
fresh_repo; echo x >> server/x.ts; git add -A >/dev/null; git commit -q -m 'feat(x): something else' -m 'see M-A3'; expect "id in body" M-A3 'NONE' open

# 6. blocked state commit (ID in the scope) — not a work commit
fresh_repo; commit 'chore(M-A3): blocked — the gist' blockers.md; expect "blocked state" M-A3 'NONE' open

# 7. bookkeeping commit with the ID in the anchor, but state files only and no [x] → not a work commit
fresh_repo; commit 'chore(state): M-A3 — progress' claude-progress.md; expect "state-only anchored" M-A3 'NONE' open

# 8. a bookkeeping commit that closes the line with [x] → work commit (DONE)
fresh_repo; close_todo M-A3; git add -A >/dev/null; git commit -q -m 'chore(todo): M-A3 — closed manually'
expect "todo [x] transition" M-A3 "DONE $(hash_of 'closed manually')" closed

# 9. `chore(todo): <ID> done in <hash>` → STATE <hash from the subject>, the commit itself is filtered out
fresh_repo; commit 'chore(todo): M-A3 done in abc1234' todo.md; expect "done-in state" M-A3 'STATE abc1234' open

# 10. work + bookkeeping: the work one is taken (after the filter, not the first one met)
fresh_repo; commit 'feat(x): M-A3 — code' server/x.ts; commit 'chore(state): M-A3 — progress' claude-progress.md
expect "work after state" M-A3 "DONE $(hash_of 'M-A3 — code')" open

# 11. ID with a disallowed character → SKIP, but TODO is still read
fresh_repo; printf -- '- [x] **PR7/Q. Weird.**\n' >> todo.md; expect "skip weird id" 'PR7/Q' 'SKIP reason=.*' closed

# 12. no line in todo.md → TODO=missing
fresh_repo; expect "missing todo line" ZZ-9 'NONE' missing

# 12a. a closed line of ANOTHER task mentions `**ID.` in its description — not the task's own, TODO goes by its own line
fresh_repo; printf -- '- [x] **META. Summary.** see **M-A3. Title** and **ZZ-9.**\n' | cat - todo.md > todo.tmp && mv todo.tmp todo.md
expect "mention in other line" M-A3 'NONE' open
expect "mention only, no own line" ZZ-9 'NONE' missing

# 13. --base limits the history
fresh_repo; commit 'feat(x): M-A3 — code' server/x.ts
out=$(bash "$SCRIPT" --task-id M-A3 --base HEAD~1); if printf '%s\n' "$out" | grep -q '^RESULT=NONE$'; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: --base"; printf '%s\n' "$out"; fi

# 14. run from a subdirectory
fresh_repo; commit 'fix(y): AG-1 — test' server/x.ts; cd server; expect "subdir" AG-1 "DONE $(hash_of 'AG-1')" open; cd "$TMP/repo"

# 15. argument errors
fresh_repo
if bash "$SCRIPT" >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: a run without --task-id must fail"; else PASS=$((PASS+1)); fi
if bash "$SCRIPT" --task-id M-A3 --base refs/heads/missing >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "FAIL: a bad --base must fail"; else PASS=$((PASS+1)); fi

echo "task-commit: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
