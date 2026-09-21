---
name: do-next
description: Same as /do-all, but exactly one task from todo.md via task-runner. Use on "/do-next", "/do-next <ID>", "do the next task".
argument-hint: "[<ID> | <ID prefix>]"
---

Same as `/do-all`, but the scope is exactly ONE task. Read
`.claude/skills/do-all/SKILL.md` and execute it in full (initialization, markers, second session
check, model fallback, loop, ff-merge, report) for one task, then stop — do not take the
next one.

Call arguments: `$ARGUMENTS` — if an ID or a prefix is passed (`/do-next AUTH-2`, `/do-next M-`),
take the first open task matching it; otherwise — the first `[ ]` from the top that is not skipped by
`⏸️`/`[MANUAL]` (legacy alias: `[ВРУЧНУЮ]`)/`[OWNER]`. Name the skipped ones in the report. No open
tasks — say so.
