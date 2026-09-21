<!-- agent-pipeline:begin skill={{SKILL_REV}} date={{INIT_DATE}} lang={{PIPELINE_LANG}} -->
## Agent pipeline (agent-pipeline)

Set up by the `agent-pipeline` skill ({{INIT_DATE}}); principles and anti-patterns —
`docs/agent-pipeline-principles.md`. Here — only what Claude needs in this repo; the general
project rules (snapshot, commands, invariants, safety) are in `AGENTS.md`: Codex reads that same
file from the working directory, so there is no need to duplicate them here.

{{AGENTS_IMPORT}}

### Commands and roles

`/do-all [N | <prefix> | until <ID>]`, `/do-next [<ID>]`, `/status` — a thin loop: the queue from
`todo.md`, a check for someone else's active session, `task-runner` per task, `git merge --ff-only`,
a report. Every task is executed by the `task-runner` agent in an isolated context and its own git
worktree (`.claude/worktrees/<name>/`, branch `worktree-<name>`, base — HEAD of `main`); phases 0–5
are in `.claude/agents/task-runner.md`. The runner is the only writer of `todo.md`,
`claude-progress.md`, `blockers.md`; bookkeeping goes into the task's commit (ID in the subject).
The orchestrator does not write to the tree; its only write is the ff-merge and worktree cleanup
(on `BLOCKED`/`FAILED` with uncommitted code the worktree is left to the owner). No `git push` — the
owner pushes. Dependencies in the worktree — a symlink to the main checkout ({{SYMLINK_CMDS}}); the
runner's dev server — see `task-runner.md`, worktree.

### Review by tiers R0–R3

The tier and the review composition are decided by the script `.claude/scripts/review-tier.sh` (by
the files and lines of the diff; critical paths, thresholds, the profile `{{REVIEW_PROFILE}}`, the
backend `{{REVIEW_BACKEND}}` and the Codex model `{{CODEX_MODEL}}` live only in it). Tiers: `R0` —
bookkeeping and small docs, no review; `R1` — docs-only and code ≤2 files/≤60 lines; `R2` — other
code; `R3` — critical paths ({{CRITICAL_SUMMARY}}, `.claude/**`). The round composition is printed
in the fields `ROUND1` (`none|single|double`), `ROUND2` (`none|light|escalate|double`),
`CONSOLIDATOR` — agents follow them, not a table from memory; `double` = `reviewer` ‖
`codex-reviewer` in one message, they do not see each other. Round 2 — only on confirmed S1/S2,
Codex in `mode: verify` on the same thread (`threadId`), the verdict is binary `APPROVE`/`BLOCKED`,
there is no third pass. Codex `UNAVAILABLE` or `CODEX=none` — `reviewer` takes its place. The marker `[review: Rn]` in the task line overrides the tier. Fate of findings: a task is
spawned only by a confirmed S1/S2; S3/S4 — fix-in-place, an item in `CHORES-<block>` or won't
fix; subtasks from review — with `⏸️` until the owner's triage.

Codex is called through the Claude Code plugin `codex@openai-codex` (the `codex` MCP server is no longer supported, 2026-09): `codex-reviewer` calls the wrapper `.claude/scripts/codex-review.sh`, and it calls the plugin's runner `codex-companion.mjs task` (read-only, in the background, waiting in chunks of ≤ 9 min against the 10 min limit of a Bash call; `PENDING job=<id>` → `wait <id>`; round 2 continues the round 1 thread via `--resume-thread`). Required: the installed plugin, the `codex` CLI and a login (`/codex:setup` shows readiness; the configuration is per-user, not per-repository). Without them the wrapper prints `### Verdict: UNAVAILABLE`, and `reviewer` takes the Codex role.

{{ASSET_SECTION}}

### Model fallback

A call to `task-runner`/`coder`/`reviewer`/`architect` that failed with a model error (limit,
credits, `overloaded`, 429/402/529) is retried by the caller ONCE with `model: "opus"`; if the retry
fails too — stop and report to the owner. `fallbackModel: ["opus"]` in `settings.json` only covers
overload and 5xx. The emergency switch for a session — `CLAUDE_CODE_SUBAGENT_MODEL=opus` in the
launch environment.

### Manual mode: `[MANUAL]` and `[OWNER]`

`[MANUAL]` (legacy alias: `[ВРУЧНУЮ]`) — a task for an interactive session with the owner (edits to
`.claude/**`, configs, hooks, docs restructuring, research with forks); `[OWNER]` — the owner only
(deploy, DNS, billing). The marker goes right after the bold title; `/do-all`/`/do-next` skip both
groups. Review in manual mode — by the same script on the main checkout's diff
(`bash .claude/scripts/review-tier.sh --task-id <ID>`), the reviewers are given the root and an
explicit list of paths; two deliberate differences from the pipeline (the owner is in the loop
personally): the consolidator is called only if the two reports disagree on the verdict or on the
S1/S2 class, and round 2 is not terminal — after S1/S2 a light round 2 is mandatory, commit only
after `APPROVE`, `CHANGES_NEEDED` in it — one more fix with the owner. The bookkeeping writer in
manual mode is the main session. The collector task `CHORES-<block>` is closed in a batch in one
session with review by tier.

### State files

`todo.md` (open tasks only, one task — one line), `claude-progress.md` (header + the two latest
runs), `blockers.md` (open ones). Read by header and `grep`, never in full; the archives
`*-archive*.md` — only for questions about history. Plans for multi-step work —
`{{EXEC_PLANS_DIR}}`.
<!-- agent-pipeline:end -->
