# Verification after init and upgrade

All commands are run from the root of the target repo. Any red item goes into the init/upgrade
report under the "Failed checks" section, and the mode is not considered complete. §1–§7 are for
both modes, §9 is upgrade only.

## 1. Test matrices (7)

```bash
bash .claude/hooks/safety-check.test.sh        # expected passed: 86, failed: 0
bash .claude/hooks/agent-sync-check.test.sh    # 20/20
bash .claude/hooks/codex-prompt-write-guard.test.sh   # pass=31 fail=0
bash .claude/scripts/review-tier.test.sh       # PASS=78 FAIL=0 (the test builds the profile and backend variants itself; interview constants have no effect)
bash .claude/scripts/active-session.test.sh    # 34/34
bash .claude/scripts/task-commit.test.sh       # 19/19
bash .claude/scripts/codex-review.test.sh      # ALL PASS (the Codex wrapper on a stub of the plugin runner; Codex itself is not needed)
bash .claude/scripts/codex-image.test.sh       # ALL PASS (the image wrapper on a stub of the codex CLI; no quota is spent)
```

The tests create their fixtures themselves (temp git repos); they change nothing in the target tree.

## 2. Tier script on the real tree

```bash
bash .claude/scripts/review-tier.sh --task-id SMOKE-1
```

Expected: `TIER=R1`, `CODEX=<effort from the interview>` (or `none` in the `light` profile),
`CODEX_MODEL=<model>`, `ROUND1=…`, `ROUND2=…`, `CONSOLIDATOR=…`, `PROFILE=<profile>`. Until
`.claude/**` is committed, the script sees it in the diff and prints `WARN=marker lowered tier…` —
this is expected and in itself confirms that `.claude/*` is critical; after `.claude/**` is
committed there must be no `WARN` line. No `MODEL_WARN=` line either: it means the Codex catalog
flags the chosen model or effort — go back to A2 (`knobs.md` E). Additionally: `grep -n '{{[A-Z_]*}}' .claude/scripts/review-tier.sh` → empty.

## 3. Hooks on sample JSON

```bash
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}' | bash .claude/hooks/safety-check.sh; echo "exit=$?"   # BLOCKED, exit 2
printf '%s' '{"tool_name":"Agent","tool_input":{"subagent_type":"coder","run_in_background":true}}' | bash .claude/hooks/agent-sync-check.sh; echo "exit=$?"   # exit 2
printf '%s' '{"trigger":"manual","session_id":"verify"}' | bash .claude/hooks/pre-compact.sh && ls .claude/state/compact-context.md   # the file has appeared
bash .claude/hooks/session-start-compact.sh | head -3     # prints the snapshot
printf '%s' '{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"'"$PWD"'","tool_input":{"file_path":"'"$PWD"'/src/x.md"}}' | bash .claude/hooks/codex-prompt-write-guard.sh; echo "exit=$?"   # exit 2
jq -r '.hooks.PreToolUse[].hooks[].command' .claude/settings.json | grep -c 'safety-check.sh\|agent-sync-check.sh\|codex-prompt-write-guard.sh'   # 3 — all three PreToolUse hooks are registered (the owner may have their own as well)
git check-ignore -q artifacts/codex-prompts/x.md && echo ignored   # ignored — Codex prompt files never reach a task commit
```

## 4. Worktree

At least one commit is required (`git rev-parse --verify HEAD`); in a fresh `git init` the owner
makes it before init (the skill does not commit).

```bash
git worktree add .claude/worktrees/verify-smoke -b worktree-verify-smoke HEAD && git worktree remove .claude/worktrees/verify-smoke && git branch -D worktree-verify-smoke
git check-ignore .claude/worktrees .claude/state   # both are ignored
jq -r '.worktree.baseRef' .claude/settings.json    # head (or the chosen value)
```

## 5. Codex and environment

```bash
bash .claude/scripts/codex-review.sh check | jq '{ready, codex: .codex.detail, auth: .auth.detail}'
                                                   # ready:true → codex-reviewer works; UNAVAILABLE block → the plugin is missing
command -v codex && codex --version
command -v python3 && command -v jq                # needed by the hooks and scripts
# only when the "Assets" knob is enabled (do not run live generation here — it spends quota):
bash .claude/scripts/codex-image.sh check          # IMAGE=READY (a value with `codex`)
claude mcp get rembg | grep -c Connected           # 1 (a value with `rembg`); the session must be restarted for the tools to appear
grep -c 'codex-image.sh\|mcp__rembg' .claude/agents/coder.md   # >0 when the knob is enabled, 0 when it is "none"
```

The regression test of the wrapper itself (`codex-review.test.sh`) is in §1.

No plugin or CLI → installation by consent was already offered in phase 1 (`tools.md`); if the owner
declined or it failed — put `[OWNER]` into the report with the commands from `tools.md` §2 and "log
in (`codex login`); `/codex:setup` will show readiness. Until then `codex-reviewer` returns
`UNAVAILABLE`, and `reviewer` takes its place in the same mode". The `codex` MCP server is no longer
needed and is not supported.

## 6. Dropbox-guard (only if the repo path contains `Dropbox`)

```bash
mkdir -p .claude/worktrees .claude/state
xattr -w com.dropbox.ignored 1 .claude/worktrees && xattr -w com.dropbox.ignored 1 .claude/state
xattr -p com.dropbox.ignored .claude/worktrees   # 1
# Linux: attr -s com.dropbox.ignored -V 1 .claude/worktrees && attr -s com.dropbox.ignored -V 1 .claude/state
```

Without this Dropbox syncs the task worktrees and fights git over the files (`.git/worktrees/*`
lock files, conflicted copies). The attribute does not survive deletion of the directory: the runner
creates worktrees inside `.claude/worktrees/`, the directory itself is not deleted — the attribute
holds.

## 7. Placeholders and foreign names

```bash
grep -rn '{{[A-Z_]*}}' .claude/ .worktreeinclude todo.md claude-progress.md blockers.md CLAUDE.md AGENTS.md   # empty
grep -rn '__STACK_ALLOW__\|__ASSET_ALLOW__\|__FALLBACK_MODEL__' .claude/settings.json   # empty
jq -r '.fallbackModel[0]' .claude/settings.json; grep -m1 '^model:' .claude/agents/task-runner.md   # different families
jq -e . .claude/settings.json >/dev/null && echo "settings.json ok"               # the JSON is valid after substitutions
test -L CLAUDE.md || grep -cE '^@(\./)?AGENTS\.md' CLAUDE.md                      # 1: AGENTS.md reaches Claude via the import (a symlink is ok too)
grep -c 'agent-pipeline:begin skill=' CLAUDE.md AGENTS.md                         # 1 per file
grep -ohE 'agent-pipeline:begin [^>]*lang=[a-z-]+' CLAUDE.md AGENTS.md | grep -oE 'lang=[a-z-]+' | sort -u   # exactly one line: lang=<PIPELINE_LANG>, the same in both files
grep -rnE '\[(MANUAL|OWNER)\]|\[review: *R[0-3]\]' todo.md | head -3                  # contract strings stayed English in every language (`knobs.md` D)
```

With `PIPELINE_LANG` ≠ `en`: open one translated agent (`.claude/agents/coder.md`) and check by eye
that the frontmatter, the commands in backticks, the `### Verdict:` / `IMAGE=` / `Worktree:` report
keys and the section names that scripts grep for are untouched — only the prose is translated.

## 8. First run (done by the owner, not the skill)

Only AFTER `.claude/**`, `.worktreeinclude` and the state files are committed: the runner's worktree
is taken from HEAD, and without the commit it has neither scripts nor hooks. Then `/do-next SMOKE-1`. Check: the runner's report contains `Worktree:`; the ff-merge went through; `git worktree
list` shows only the main checkout; `.claude/state/runs.log` got a line with `tier=R1`; the main
session grew by < 5K tokens (`/context` before and after). The commit `docs: SMOKE-1 — …` is in `git log`.
The runner ran on the intended model and effort: `grep -ho '"model":"[^"]*"\|"effort":"[^"]*"' <the
runner's subagent transcript> | sort | uniq -c` shows the model of the chosen family (today
`claude-opus-5-5`, not `claude-opus-5`: an older Claude Code resolves `opus` to Opus 5, `knobs.md` E)
and `"effort":"high"`.
After that `SMOKE-1` and `CHORES-SMOKE` can be deleted from `todo.md` or left as a sample.

## 9. Additionally after upgrade

Only for the `upgrade` mode — on top of §1–§7 (§8 is done by the owner). Every command gives empty
output or the stated value; otherwise — into the report under the "Failed checks" section.

```bash
ls -d .claude/legacy .claude/*legacy* 2>/dev/null                                   # empty: legacy lives outside .claude/
ls .claude-legacy/                                                                  # <YYYY-MM-DD>/ — copies of the replaced files
for c in .claude/commands/*.md; do n=$(basename "$c" .md); [ -d ".claude/skills/$n" ] && echo "CLASH $n"; done   # empty
jq -r '.hooks[][].hooks[].command' .claude/settings.json | sed 's/^bash //' | while read -r f; do [ -f "$f" ] || echo "MISSING $f"; done   # empty
grep -c 'agent-pipeline:begin' CLAUDE.md                                            # 1 (and 1 in AGENTS.md, if it exists)
grep -rn 'claude-progress\.md' .claude/ >/dev/null && grep -rln '\bprogress\.md' .claude/ | grep -v legacy   # empty after U2 "rename"
git diff --quiet HEAD -- <R∖T list from the inventory> && echo "R∖T untouched"           # R∖T untouched
git status --porcelain | grep -v '^??' | grep -vE ' (\.claude/|CLAUDE\.md|AGENTS\.md|\.worktreeinclude|\.gitignore|docs/agent-pipeline-principles\.md|todo|claude-progress|blockers|progress)'   # empty: changes only in the allowed paths
for a in .claude/agents/*.md; do grep -q '^model:' "$a" || echo "NO model: $a"; grep -q '^allowedTools:' "$a" && echo "DEAD allowedTools: $a"; done   # only R∖T files — into the report, do not fix
```

The legacy directory must not end up in the owner's commit: the `[OWNER]` item of the report says
"after the migration delete `.claude-legacy/`; do not add it to the commit".
