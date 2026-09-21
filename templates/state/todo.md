# Project tasks

## Instructions

Tasks are executed top to bottom; each completed one is marked `[x]`. One task — one line
(no line breaks inside the line: the runner fetches the task statement by ID via `grep`), format:

`- [ ] **<ID>. <Task title.>** [markers] Task: what to do, where, how to verify. Do not: … Done when: …`

- **ID** — `<BLOCK>-<number>` (for example `AUTH-3`, `UI-12`, `M-2`); block = the prefix up to the first hyphen.
  The ID goes into the commit subject — it is the key that links the task, the progress and the history.
- **Markers** go right after the bold title:
  - `[review: R0|R1|R2|R3]` — override the review tier (the script `.claude/scripts/review-tier.sh`
    computes it from the diff by itself; the marker is needed when the risk is not visible in the
    diff — for example an edit touches money, access or user data through a "harmless" file);
  - `[MANUAL]` (legacy alias: `[ВРУЧНУЮ]`) — a task for an interactive session with the owner (edits
    to `.claude/**`, configs, hooks, docs restructuring, research with forks); `/do-all` and
    `/do-next` skip it;
  - `[OWNER]` — an action only the owner can perform (deploy, DNS, billing, keys);
  - `⏸️` (right after the bold title, like the other markers) — the task is paused until the owner's triage; the run does not take it.
- **Subtasks** — lines indented by two spaces under the parent: `  - [ ] **<ID>-<letter>. …**`.
- **Collector task `CHORES-<BLOCK>`** — a special `[MANUAL]` task of the block: the runner appends
  review findings S3/S4 to it as items (a), (b)… (cosmetics, naming, copy, test hygiene); the owner
  closes the batch in one session. S3/S4 never becomes a separate task.
- Closed tasks eventually move to `todo-archive.md`; here — open ones only.

---

## 🎯 EXECUTION QUEUE

- [ ] **SMOKE-1. Pipeline check: runner, worktree, review, commit.** [review: R1] Task: add to `README.md` (or to `docs/`, if there is no README) a three-line "Agent pipeline" section: how to run `/do-next`, where the queue lives (`todo.md`) and where the log is (`claude-progress.md`). Do not: do not touch code or configs. Done when: the runner's report contains a `Worktree:` line, the ff-merge went through, `git worktree list` is clean, the main session grew by less than 5K tokens.

- [ ] **CHORES-SMOKE. S3/S4 collector for the SMOKE block.** [MANUAL] The runner appends items in Phase 5.1; the owner closes them in a batch.
