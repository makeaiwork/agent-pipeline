# Pipeline principles — why the templates are built this way

A distillation of the playbooks of two live source repositories (hereafter the first repo and the
second repo), which grew out of one scheme and half a year of runs. Here are the rules and the cost
of breaking them; the prompt templates contain only rules and commands (incident archaeology in
prompts lowers quality on Fable 5.x and bloats the runner).

## 1. Five principles

1. **The unit of context and the unit of working tree is one task.** The main session is a thin loop
   (`/do-all`, `/do-next`): it reads the queue, calls `task-runner`, merges the branch with
   `git merge --ff-only`, removes the worktree. The runner works in an isolated context and its own
   git worktree (`isolation: worktree` → `.claude/worktrees/<name>/`, branch `worktree-<name>`) and
   returns ≤15 lines. The main session grows by 1–2K per task instead of 300–400K of "inheritance".
2. **State lives in files, not in context.** `todo.md` (the queue, one task — one line),
   `claude-progress.md` (current-state header + the two latest runs), `blockers.md`
   (open blockers), git. Context is expendable — it can be thrown away at any moment.
3. **Save by isolation, not by skipping.** Verification depth is not cut for the sake of tokens;
   heavy work is moved into a subagent with a fresh context that returns a short verdict.
4. **Writer ≠ reviewer; review depth follows the risk of the diff.** The tier `R0`–`R3` is decided by
   the script `review-tier.sh` from files and lines, not by an agent's gut feeling. The main review
   is carried by external Codex (its own subscription, the Claude limit is not spent); an
   independent Claude reader and a consolidator are added where a mistake is expensive. Round 2 —
   only on confirmed S1/S2, light, final: there is no third pass.
5. **Subagent reports are short and in a fixed format.** Everything the next step does not need
   stays in the subagent's context.

## 2. Roles

| Agent                 | Model (default) | Writes                | Purpose                                                                                                   |
| --------------------- | --------------- | --------------------- | --------------------------------------------------------------------------------------------------------- |
| `task-runner`         | opus            | bookkeeping, worktree | phases 0–5 of one task; the only writer of `todo.md`/`claude-progress.md`/`blockers.md`; `Agent(…)` allow |
| `researcher`          | opus            | —                     | what is here (unknown area, >3 files)                                                                     |
| `architect`           | opus            | —                     | how to rework it (large tasks, `ARCHITECTURE_REVIEW`)                                                     |
| `coder`               | opus            | code                  | one atomic implementation                                                                                 |
| `tester`              | sonnet          | —                     | test run, diagnostics, visual UI check                                                                    |
| `codex-reviewer`      | (Codex, plugin) | —                     | main review of round 1, fix verification in round 2 on the same thread                                    |
| `reviewer`            | opus            | —                     | second independent reader (double review) and replacement for Codex on `UNAVAILABLE`                      |
| `review-consolidator` | opus            | scratchpad file       | with two reports: checks only the disagreements against the code, issues the routing verdict              |
| `committer`           | sonnet          | docs, git             | commit by an explicit set of paths + docs by trigger rules; ≤1 commit per runner exit                     |

There is deliberately no separate `designer`: over 149 UI commits of the first repo it was called
once — the role dissolved into coder (by the design guide), tester (two viewports) and reviewer (UI
checklist).

Assets follow the same logic: a tool of `coder`, not a role. Raster image generation is
`.claude/scripts/codex-image.sh`: Codex CLI with the built-in `image_gen` (the `codex@openai-codex`
plugin does not make images), read-only sandbox, the wrapper itself puts the file into the tree and
only inside the working directory; background removal is the `rembg` MCP. Both tools are installed
on the owner's side, not in the repo, and are enabled by the "Assets" knob only in UI projects.
Unavailability (`IMAGE=UNAVAILABLE`, no rembg) is not a blocker: the task is closed with an item in
"Needs attention", the owner finishes the image. A generated file is an ordinary binary in the
diff: the review tier is computed by the rules, there is no separate "art review".

## 3. Pipeline of one task (inside the runner)

0. **Worktree**: `pwd` = worktree, symlinks to the main checkout's dependencies, its own dev server
   port.
1. **Reconnaissance** — the runner itself or `researcher`; `architect` for large work.
2. **Implementation** — `coder` (small stuff of ≤2 files the runner edits itself).
3. **Tests** — `tester`; UI — visually in two viewports.
4. **Review** — `bash .claude/scripts/review-tier.sh --task-id <ID>` → `TIER`, `CODEX`, `CODEX_MODEL`,
   `ROUND1`, `ROUND2`, `CONSOLIDATOR`; the round composition is strictly by these fields (§4). Two
   reviewers — in one message, they do not see each other.
   4.5. **Consolidation** — with two reports and `CONSOLIDATOR=yes`.
   The fix for S1/S2 is made by the runner (a large one — by `coder`), round 2 verifies only the fix.
5. **Bookkeeping and commit** — `[x]`, progress line, S3/S4 → `CHORES-<block>` / won't fix /
   `⏸️` subtask; then `committer` by an explicit list of paths. No `git push`.

Runner outcomes: `DONE <hash>` · `BLOCKED` (bookkeeping committed, code not; the blocker is in
`blockers.md`, the worktree is left to the owner) · `FAILED` · `SKIPPED` (`[MANUAL]`/`[OWNER]`/`⏸️`).

## 4. Tiers and strictness profiles

The tier follows the diff: `R0` bookkeeping and docs-only ≤20 lines outside critical paths · `R1`
docs-only, code ≤2 files/≤60 lines, empty diff · `R2` other code · `R3` critical paths
(`CRITICAL_GLOBS`: money, access, schema, migrations, deploy, `.claude/**`). The `[review: Rn]`
marker overrides; before round 2 the tier is recomputed and can only grow; a script error = `R3`.

The composition is set by the profile (`REVIEW_PROFILE` in the script), the script prints it as
fields:

| Profile    | R1                                     | R2                                         | R3                                           |
| ---------- | -------------------------------------- | ------------------------------------------ | -------------------------------------------- |
| `standard` | Codex → verify                         | Codex → verify                             | Codex ‖ Claude + consolidator → verify       |
| `strict`   | Codex → **escalate** (verify ‖ Claude) | Codex ‖ Claude + consolidator → **double** | Codex ‖ Claude + consolidator → **double**   |
| `light`    | no review                              | Codex → verify                             | Codex ‖ Claude, runner consolidates → verify |

History: `strict` is the scheme of the first repo until 2026-09-02 and of the second repo at version
2.5 (the double round 2 on R3 was cancelled in the first repo on 2026-09-02: round 2 verifies a
small fix, and the full apparatus on it cost as much as round 1; the second repo keeps the
escalation on R1/R2 — "a task with S1/S2 sees both reviewers at least once"). `standard` is scheme B
of the first repo: after the Fable limit was exhausted on 2026-08-26, heavy Claude calls per R3 task
dropped from 6 to 3, on R1/R2 from 2–4 to 1. Revisit by `found=` in `.claude/state/runs.log`: if the
Claude reader on R3 for months finds nothing that Codex did not find, the profile can be lowered;
if Codex alone misses S1/S2 on R2 — raise it.

Severity is shared by all reviewers: `S1` money/security/data loss · `S2` logic, statuses,
permissions, lying to the user about state/deadline/permissions, a dead end with no way out · `S3`
confusing code or text · `S4` cosmetics. Verdicts: `APPROVE` / `CHANGES_NEEDED` /
`ARCHITECTURE_REVIEW` (consolidator and single reviewer), `APPROVE` / `BLOCKED` (round 2).

## 5. Fate of findings — against a self-reproducing queue

A run of the first repo (2026-08-25): 6 tasks closed, 12 spawned. The second repo after version 2.4:
4 collector items per task, none rejected. Rules: a task is spawned only by a confirmed S1/S2;
S3/S4 — fix-in-place along with the S1/S2 fix (verified by round 2), an item in the collector task
`CHORES-<block>` `[MANUAL]`, or won't fix ("accepted as is: reason" — no data is lost,
money/permissions are not affected, the scenario requires artificial conditions); subtasks from
review get `⏸️` until the owner's triage (except S1 with loss of data/money); when in doubt — towards
the smaller route. A finding can be rejected only with a code quote; "only one of them found it" is
not a reason.

## 6. State files

- `todo.md`: open tasks only; one task — one line (>1500 characters — into a plan, by link);
  closed ones — as snapshots in `todo-archive*.md`. Read by header and `grep`, never in full.
- `claude-progress.md`: a one-line "Status" header + the two latest runs; the rest goes to the
  archive. An append-only log is an anti-pattern (329KB in the first repo before the cleanup).
- `blockers.md`: open ones only; the history verbatim in `blockers-archive.md` (it was 1.2MB).
- `.claude/state/runs.log` (gitignored): telemetry — task, tier, rounds, `found=`, `codex=`, tokens.
- One writer per file — `task-runner` (in manual mode — the main session), before the committer is
  called; bookkeeping is part of the task commit, the link key is the ID in the subject.

Instruction files follow the same "one place per fact" rule. `AGENTS.md` holds the project's common
rules for all agents: Codex reads it itself, from the working directory (the chain from the root to
cwd, ≤ 32 KiB in total — `project_doc_max_bytes`; anything beyond is silently dropped), and it
reaches Claude through the `@AGENTS.md` line in `CLAUDE.md`. `CLAUDE.md` holds only Claude
specifics: the pipeline section and the import. Native reading of `AGENTS.md` in Claude Code (since
2.1.277) does not affect this and does not replace it: it kicks in only when there is no
`CLAUDE.md`, and the pipeline always keeps one — it carries the version marker for `upgrade`; the
import works on any version, does not cause double reading and preserves `/memory` and the
`InstructionsLoaded` hooks. The `instructionFiles` setting of the `agents-md@builtin` plugin works
only in user/managed settings — in the project `settings.json` it is dead. Duplicated rules
between the two files are an anti-pattern: after the import Claude sees them twice, and they diverge
on the very first edit.

## 7. Manual mode and markers

`[MANUAL]` (legacy alias: `[ВРУЧНУЮ]`) — edits to `.claude/**`, configs, hooks, memory, docs
restructuring, research with forks: the main session with the owner in 15–20 minutes instead of an
hour-long run; review — by the same script on the main checkout's diff, the reviewers are given the
root and an explicit list of paths. `[OWNER]` — the owner only (deploy, DNS, bills). `/do-all` skips
both groups and lists them in the report.

## 8. Mechanics backed by hooks and scripts

- `safety-check.sh` (PreToolUse Bash): `git push`, `reset --hard`, `rm -rf`, access to secrets —
  block. Test matrix of 76 cases.
- `agent-sync-check.sh` (PreToolUse Agent): a background call of a pipeline agent — block. A runner
  with `run_in_background: true` ended its turn without a report, and the worktree with an empty
  diff was removed as unused (both repos, 19–20.08.2026: 4 nudges for 2 tasks).
- `review-tier.sh`, `task-commit.sh`, `active-session.sh` — deterministic logic as scripts with
  test matrices, not as prose in a prompt (an agent reproduces prose with variations).
- `pre-compact.sh` / `session-start-compact.sh`: a snapshot of the tree and the header before
  compaction and its display afterwards; `autoCompactWindow: 400000` is insurance, not a mechanism
  (on a 1M model the default auto-compact fired at 950K and lost the phase/verdicts).
- `fallbackModel` (the fallback family — the other of `opus`/`fable`, never the runner's own model)
  covers only overload and 5xx; for limit/billing (429/402) — the rule "one retry with the fallback
  model" in the prompts, and the emergency switch `CLAUDE_CODE_SUBAGENT_MODEL=<fallback>` in the
  environment.
- Models age: agents name families (`opus`/`fable`/`sonnet`), which Claude Code resolves to the
  newest version, and the Codex model lives in one constant of `review-tier.sh`, which prints
  `MODEL_WARN=` when the local Codex catalog marks it as missing, retiring or older. Which family
  leads is re-checked by the skill on every init/upgrade/audit. History: until 2026-09-23 the
  defaults were `fable` for runner/coder/architect/reviewer with an `opus` fallback and Codex
  `gpt-5.6-sol` `high`/`xhigh` by tier; on 2026-09-23 they moved to `opus` (Opus 5.5 led Fable 5.1
  on agentic benchmarks at 40% of the price) with a `fable` fallback, and to Codex `gpt-6-sol`
  (half the price of `gpt-5.6-sol`), still `high`/`xhigh` by tier — on vendor figures, to be
  confirmed by `runs.log`.
- Agent frontmatter: `tools:` is an allow-list; `disallowedTools: Bash(…)` disables Bash entirely;
  `allowedTools` is a dead key.
- Dropbox: mark `.claude/worktrees` and `.claude/state` with `com.dropbox.ignored`, otherwise the
  sync fights git over the worktree files.

## 9. Anti-patterns (observed, with their cost)

| Anti-pattern                                                        | Cost                                                              | Replacement                                                       |
| ------------------------------------------------------------------- | ----------------------------------------------------------------- | ----------------------------------------------------------------- |
| The main session does the tasks itself                              | 946K context by the end of the session                            | `task-runner` per task                                            |
| "Read todo.md" without a limit                                      | 150–400K tokens per read                                          | header + grep; archives                                           |
| Reviewers run sequentially / one sees the other's report            | the second one adjusts to the first                               | two `Agent` calls in one message                                  |
| Taking subagent reports at their word                               | false findings undermine trust                                    | reject only with a code quote                                     |
| Two sessions in one tree with a shared index                        | someone else's staged files in your commit                        | worktree per task + ff-merge; active-session check                |
| Three writers in one state file                                     | `[x]` and the commit diverge                                      | one writer, before the committer                                  |
| A third review round "to finish it off"                             | the cost of a full review for one live finding                    | round 2 is final: `APPROVE`/`BLOCKED`                             |
| The consolidator re-checks agreed findings                          | the stage costs twice as much, the verdict is the same            | against the code — only the disagreements                         |
| One review price for any diff                                       | three heavy calls for a one-line fix                              | tiers by script; profiles                                         |
| A pipeline task for every S4                                        | an hour of machine time for a 10-minute edit; 7 levels of nesting | fix-in-place / `CHORES-<block>` / won't fix / `⏸️`                 |
| Incident archaeology and deterministic logic as prose in the prompt | a 340-line runner prompt, variations on reproduction              | rule + command in the prompt; history here; logic — into a script |
| A "just in case" role (`designer`)                                  | an extra phase, the temptation to skip it                         | dissolve into the existing roles                                  |
| Dead env vars "for thinking"                                        | confusion, zero effect                                            | `effortLevel`                                                     |

## 10. Taken from the second scheme and deliberately left out

**Taken into the templates:** the `agent-sync-check.sh` hook; Codex round 2 on the same thread
(`threadId`); the Codex model and effort are printed by the tier script, agents do not hardcode
them; Dropbox-guard; `SessionStart` `startup|clear|compact`; `MCP_TOOL_TIMEOUT`; the S2 wording
"lying to the user about state, deadline, permissions; a dead end with no way out"; the `strict`
profile = round 2 escalation (version 2.5).

**Left out:**

- `board.py` — a structured board with fields and a CLI instead of `todo.md` lines. Stronger for
  multi-package work, but it requires a Python tool in every repo and learning the formats; v1 of
  the skill stays with lines that are read with `grep`.
- Task tiers `light`/`core` as a tier input — a project classification; here the tier follows the
  diff only.
- A value filter with the classes `code-only`/`second-order`/`new-mechanism`/`not-now`/`stale` and
  two gates — a strong idea against collector growth, but its mechanics live in `board.py`; here
  there are three destinations: `CHORES`, won't fix with a reason, `⏸️`.
- Telemetry in the repo (`runs.jsonl`, `board.py runs`) — here it is the gitignored
  `.claude/state/runs.log`.
- A `ctx.py` checkpoint between tasks and a statusline — not needed with a runner per task.
- `AGENT_ID` port/DB slots for parallel sessions — a project-specific thing; the runner has a single
  parameter `{{DEV_SERVER_RULE}}`; it is asked in the interview only when there are signs of
  parallel sessions.
- The `dual-review` skill as a separate procedure — here consolidation is described in
  `task-runner.md` (section "Reconciliation without a consolidator") and `review-consolidator.md`.
