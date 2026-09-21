---
name: status
description: Summary of autonomous work from the state files — todo.md counters, the progress header, pauses, blockers, the telemetry tail. Reads only headers and grep. Use on "/status", "what's the task status", "where are we".
---

Show the current status of autonomous work.

Do NOT read state files in full — `todo.md` grows to hundreds of KB over time; `blockers.md` is a short index, the history is in `blockers-archive.md`.
You need headers and `grep`:

1. `AGENTS.md` — already in context via the import in `CLAUDE.md`; if the "Project Snapshot" section is not in context — read it.
2. `{{EXEC_PLANS_DIR}}/` — the list of files; open only those mentioned in the progress header.
3. `head -30 claude-progress.md` — the state header and the last run.
4. Tasks — by counter and the first open ones, not by reading the file:
   - `grep -c '^- \[ \]' todo.md` and `grep -c '^- \[x\]' todo.md`
   - `grep -n -m 12 '^- \[ \]' todo.md | cut -c1-300` — the first open ones
   - `grep -n '⏸️' todo.md | cut -c1-160` — what is paused
   - `grep -nE '^\s*- \[ \] \*\*[^*]+\*\*( \[[^]]+\])* \[(MANUAL|ВРУЧНУЮ|OWNER)\]' todo.md | cut -c1-120` — what is waiting for the owner at the computer (`[MANUAL]`, legacy alias: `[ВРУЧНУЮ]`) or for the owner's actions (`[OWNER]`): the marker right after the task title; `/do-all` skips them
5. `git log --oneline -10`
6. Blockers — by headings: `grep -n '^## ' blockers.md | grep -v -E 'CLOSED|ЗАКРЫТ' | head -20`.
7. Run telemetry: `tail -10 .claude/state/runs.log 2>/dev/null` — the latest pipeline tasks
   (tier, rounds, who found S1/S2, runner tokens); no file — there have been no runs under the new
   scheme yet.

Output a brief summary:

- How many tasks are done / remaining (from the step 4 counters)
- Which active plans exist
- Current status (from the progress header)
- Open blockers (headings, not contents)
- Tasks paused with `⏸️`; `[MANUAL]` and `[OWNER]` tasks (waiting for the owner)
- Latest commits
- The `runs.log` tail as is (if the file exists)

Archives (`todo-archive*.md`, `claude-progress-archive.md`, `blockers-archive.md`) are not needed
for the status — open them only on an explicit question about history.
