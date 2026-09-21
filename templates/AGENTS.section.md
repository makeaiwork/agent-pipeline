<!-- agent-pipeline:begin skill={{SKILL_REV}} date={{INIT_DATE}} lang={{PIPELINE_LANG}} -->
## Project Snapshot

{{PROJECT_ONE_LINER}}. Stack: {{STACK_SUMMARY}}.

## Essential Commands

{{COMMANDS_TABLE}}

## Task Routing

- The task queue — `todo.md` (one task — one line, ID `<BLOCK>-<N>`); progress —
  `claude-progress.md`; blockers — `blockers.md`. An autonomous run — `/do-all`, a single task —
  `/do-next`, a summary — `/status` (see `CLAUDE.md` → "Agent pipeline").
- The run skips the markers `[MANUAL]` (interactively with the owner) and `[OWNER]` (the owner only).
- Plans for multi-step work — `{{EXEC_PLANS_DIR}}`.

## Hard Invariants

{{INVARIANTS}}

## Safety Rules

- Do not touch `.env*`, `.git/config`, {{PROTECTED_SUMMARY}} without an explicit request.
- Never `git add .` / `git add -A`; commit by an explicit list of paths. `git push` is done by the owner.
- Read state files by header and `grep`, not in full.
{{LANG_RULE}}
<!-- agent-pipeline:end -->
