# upgrade — mechanics of updating a deployed pipeline

The single source of rules for the `upgrade` mode in `SKILL.md`. The mode's job: bring the target
repo's `.claude/**` up to the current templates without losing project-specific work and without
overwriting a single owner file for which the skill has no merge rule. Everything that does not fit
a rule goes into the migration table (§5) — the owner decides.

## 0. Two origins

| Origin      | Sign                                                                                                                                       | What it means                                                                                  |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| **own**     | the marker `<!-- agent-pipeline:begin skill=<rev> date=<date> lang=<code> -->` in `CLAUDE.md`; PROJECT blocks in `.claude/hooks/*.sh`, `.claude/scripts/*.sh` | interview values are recovered from the files; PROJECT blocks are carried over verbatim        |
| **foreign** | none of this: `.claude/agents` was assembled by hand or by another tool                                                                    | values are taken by heuristics (§2); the content of the old files — as a table for the owner (§5) |

The mixed case (an own pipeline, but the owner added to files outside the PROJECT blocks) — treat
as own; edits outside the blocks go into the migration table §5, as with a foreign one. init
versions from before markers existed (the heading `## Agent pipeline (agent-pipeline)` without
`<!-- … -->`; legacy deployments: `## Агентный конвейер (agent-pipeline)`) — own. The marker is
recognised with and without attributes: `<!-- agent-pipeline:begin -->` in `AGENTS.md` was written
by versions before SKILL-4, the new section carries `skill=`/`date=`/`lang=` in both files; the
version, date and language of an "own" pipeline are still read from `CLAUDE.md`.

**Language.** `lang=<code>` in the marker is the pipeline's current `PIPELINE_LANG` — keep it, do
not ask. No `lang=` (deployments before SKILL-5) → run the detection from `knobs.md` D; a legacy
heading or Cyrillic prose in `.claude/agents/*.md` is a strong signal for `ru`. The owner may change
the language during upgrade — only through the `knobs.md` B question, never silently.

## 1. File classes

The set **T** — the template paths after mapping into the target repo: `templates/claude/**` →
`.claude/**`, `templates/state/*` → the root (taking U2 into account), `worktreeinclude` →
`.worktreeinclude`, the sections → `CLAUDE.md`/`AGENTS.md`, `reference/principles.md` →
`docs/agent-pipeline-principles.md`. The set **R** — what is in the repo.

| Class    | Definition                                                                                                          | Action                                                                                              |
| -------- | ------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `T∩R =`  | the path is in both; the content after substituting the current values matches (`diff` is empty). With `PIPELINE_LANG` ≠ `en` the prose of `.md` files is a translation and `diff` is meaningless for them: an `.md` file is `T∩R =` only when the marker's `skill=` equals the current revision and `lang=` is unchanged; scripts, hooks and `settings.json` are compared by `diff` in every language | nothing                                                                                             |
| `T∩R ≠`  | the path is in both; the content differs (for a foreign one — always)                                               | replace; the old one goes to legacy. The owner may keep the old one via U1 — then do not touch the file |
| `T∖R`    | in the template, not in the repo                                                                                    | add as in init                                                                                      |
| `R∖T`    | in the repo, not in the template (project agents, commands, hooks, scripts)                                         | **do not touch**; frontmatter lint — into the report                                                |
| `R∖T ✗`  | `R∖T` with a name conflict: `.claude/commands/<x>.md` when there is `templates/claude/skills/<x>/SKILL.md`          | the old file goes to legacy — otherwise there are two handlers for `/x`                             |

Always outside the classes and outside legacy: `.claude/settings.local.json` (do not read, do not
copy, do not mention its content), `.claude/state/`, `.claude/worktrees/`, `.env*`, `.git/config`.

The inventory is built from `git ls-files .claude CLAUDE.md AGENTS.md .worktreeinclude` plus the
state files; untracked files in these paths are a reason to stop under the clean-tree rule
(`SKILL.md`, phase 1 item 10).

## 2. Where to take the current values from (interview recommendations)

| Setting | Own | Foreign (heuristics) |
| --- | --- | --- |
| `CRITICAL_GLOBS`, `REVIEW_PROFILE`, `REVIEW_BACKEND`, `CODEX_MODEL`, `CODEX_EFFORT_*`, thresholds | the PROJECT block of `review-tier.sh` | the `knobs.md` A1/A3 rules from reconnaissance; plus the paths that the old agents call critical ("security", "safety", "payments", "auth") |
| `PROTECTED_FILES`, secret patterns | the PROJECT block of `safety-check.sh` | `grep -nE 'secret\|token\|key\|BLOCK\|pattern' .claude/hooks/*.sh` — show the lines to the owner |
| `model:`, `effort:` of the roles | the frontmatter of the agents of the same name | the same; for roles the repo does not have (`task-runner`, `codex-reviewer`, `review-consolidator`) — the `knobs.md` A4 default |
| `fallbackModel`, `{{FALLBACK_MODEL}}` | `settings.json` → `fallbackModel`; the `model: "…"` of the "Model fallback" rule in `task-runner.md` | the same; a fallback equal to the runner's own model (the old default `opus` next to an `opus` runner) is flagged — `knobs.md` A4 |
| `{{DOC_TRIGGERS}}`, `{{CANON_DOCS}}` | `committer.md`, the triggers section | the documentation section of the old `committer.md`; `CANON_DOCS` — init reconnaissance item 5 |
| `{{DOMAIN_CHECKLIST}}`, `{{UI_CHECKLIST}}` | `reviewer.md` `### Domain` / `### UI` | any section of the old `reviewer.md` with "domain", "security", "invariant", "UI" in the heading |
| `{{DEV_SERVER_RULE}}`, `{{SYMLINK_CMDS}}`, `{{FORMAT_CMD}}` | `task-runner.md`, the PROJECT block of `post-edit.sh` | init reconnaissance item 2; the old `post-edit.sh` — into §5 |
| `STATE_FILES` / `STATE_RE` | the PROJECT block of `task-commit.sh` | the fact: `ls todo.md progress.md claude-progress.md blockers.md` → U2 |
| `notify.sh` transport (Telegram, ntfy, osascript) | the PROJECT block of `notify.sh` | the whole body of the old `notify.sh` — into §5 |
| `{{EXEC_PLANS_DIR}}` | `task-runner.md` | reconnaissance (`knobs.md` B "Plans") |
| The "Assets" knob | `tools:` in `coder.md`: `codex-image.sh` → `codex`, `mcp__rembg__` → `rembg`, both → `codex+rembg`, nothing → `none` | the same by the `tools:` of any old agent; none — the `knobs.md` B rule |

Rule: in the interview "**Recommended for this project: <current> — because that is what is set now
in `<file>:<line>`**". The current value contradicts a `knobs.md` rule (for example, `light` with
money in A1 or `sonnet` for `coder` on domain logic) → recommend per `knobs.md`, give the current
value as the second option labelled "current". The same for models: a current `CODEX_MODEL`,
`CODEX_EFFORT_*` or role `model:` that `knobs.md` E flags (a missing, retiring or "Older" Codex
model, an effort the plugin rejects, a Claude family that is no longer the leader, a fallback equal
to the primary) is not recommended just because it is set now — recommend by the E leader rule and
give the current value as "current", with the reason from E ("`gpt-5.6-sol` is marked Older in the
catalog fetched <date>"). A value that is neither in the files nor given by a
rule — the `knobs.md` C default, without a question.

## 3. U questions (upgrade only; each one only under its own condition)

| #  | Condition | Question | Options | Recommendation and reason | Changes |
| -- | --- | --- | --- | --- | --- |
| U1 | there are `T∩R ≠` files | which differing files to keep in their old form | `multiSelect` over the list, labelled "own/foreign, PROJECT block present/absent"; nothing checked = replace everything | replace everything: the old version is in git and in legacy, what is needed is carried over per §5; an old file that is kept will not get the new `review-tier.sh` fields or the new placeholders and will not pass `verify.md` | classes → actions |
| U2 | the state file names ≠ `todo.md` / `claude-progress.md` / `blockers.md` | rename or substitute | rename with `git mv` / keep and substitute `STATE_RE` + the names in the texts of agents and skills | rename: the skills, the runner, `CLAUDE.section.md` and the tests use the template names; `STATE_RE` is the only parameterised place, the texts are edited by hand and drift apart | `task-commit.sh`, `review-tier.sh`, texts of agents/skills |
| U3 | `R∖T` contains agents (`.claude/agents/*.md` without a template counterpart) | whether to let them into the runner | do not add / add the listed ones to `tools: Agent(…)` of `task-runner.md` | do not add: the runner calls the pipeline roles, the project ones (analytics, deploy, acceptance) are called from the main session or through `[MANUAL]` (legacy alias: `[ВРУЧНУЮ]`)/`[OWNER]` tasks; otherwise the runner grows and loses the thread | `task-runner.md` → `tools:` |
| U4 | the state files violate `principles.md` §6 (size, `[x]`, lines >1500, header) | who archives | the skill: `[x]` lines → `todo-archive-<date>.md`; progress except the header and the last two runs → `claude-progress-archive.md`; closed blockers → `blockers-archive.md`; the instruction header from `templates/state/*` on top / the owner does it | the skill: the archives are verbatim, nothing is lost; without this the runner reads 40KB on every task | state files |

Everything else — without questions: the legacy directory `.claude-legacy/<YYYY-MM-DD>/`, an
`R∖T ✗` conflict → legacy, replacement of `docs/agent-pipeline-principles.md`. `git mv` under U2 is
the only git write command that upgrade runs; the commit is still made by the owner.

## 4. Generation order

4.1. **Legacy copy** — `.claude-legacy/<YYYY-MM-DD>/` in the repo root, not inside `.claude/` (so
that Claude Code does not pick up the old agents, hooks and commands). Copy preserving relative
paths: all `T∩R ≠` (except those kept under U1), all `R∖T ✗`, the old `CLAUDE.md`/`AGENTS.md`
sections (no markers — the whole file), `docs/agent-pipeline-principles.md`. Do not copy
`settings.local.json`, `state/`, `worktrees/`, `.env*`. Do not add legacy to `.gitignore`: the
directory lives until the migration is finished and is deleted by the owner (`[OWNER]`); the
originals are in git anyway (phase 1 item 10). Before this step — not a single write to the repo.

4.2. **`T∖R`** — as init phase 3, per the interview table.

4.3. **`T∩R ≠`, own** — generate from the template per the interview table; replace the content
between `# === PROJECT-SPECIFIC … ===` and `# === /PROJECT-SPECIFIC ===` with the old one verbatim.
If the old block and what the interview would produce differ — one `AskUserQuestion` for all such
files: "old block" (recommendation: the owner edited it by hand) / "from the interview". The owner's
edits outside the blocks — into §5.

4.4. **`T∩R ≠`, foreign** — generate from the template per the interview table; the values from §2
— into the PROJECT blocks; the body of the old file — into §5.

4.5. **`settings.json`** — merge with a `python3` script (not `jq '*'`), as in init, with two
differences: (a) a template `hooks.<event>` entry **replaces** an existing entry with the same
`command` if that `command`'s file fell into `T∩R ≠` or `T∖R`; existing entries whose `command`
points to a file that moved to legacy are removed and shown; the owner's entries for their own
hooks (`R∖T`) stay; (b) the interview scalars (`effortLevel`, `worktree.baseRef`,
`autoCompactWindow`, `fallbackModel`) — from the interview; the owner's other scalars stay, template
keys are added only when missing. `permissions.allow`/`deny`, `env` — a union without duplicates,
the owner first. Show the diff before writing.

4.6. **`CLAUDE.md` / `AGENTS.md`** — there is a pair of markers `<!-- agent-pipeline:begin … -->` …
`<!-- agent-pipeline:end -->` → replace everything between them inclusive with the new section; no
markers, but there is the heading `## Agent pipeline (agent-pipeline)` (legacy deployments:
`## Агентный конвейер (agent-pipeline)`) (for `AGENTS.md` — `## Task Routing` next to
`## Project Snapshot`) → replace from it to the next `## ` of the same level or the end of the
file; nothing at all → append as in init. Do not touch the rest of the file's text; contradictions
(phase 1 item 15) — only into the report. The `@AGENTS.md` import arrives together with the new
`CLAUDE.md` section (`{{AGENTS_IMPORT}}`; the owner already imports `AGENTS.md` outside the section
— the value is empty, no second import line appears); the `CLAUDE.md → AGENTS.md` symlink — the
`knobs.md` B question, as in init. Old prompts saying "first read `AGENTS.md`" go away with the
`T∩R ≠` replacement; in files kept under U1 they are harmless (an extra Read).

4.7. **State files** — per U2 (`git mv` before editing the texts) and U4 (archives); otherwise do
not touch. Add `SMOKE-1` and `CHORES-SMOKE` from `templates/state/todo.md` only if there are no
tasks with those IDs.

4.8. **`docs/agent-pipeline-principles.md`** — replace entirely: it is the skill's file, not the
owner's.

4.9. `.gitignore`, `.worktreeinclude`, `chmod +x`, `mkdir -p .claude/state .claude/worktrees`,
Dropbox guard — as in init.

## 5. Migration table (report)

For every file in legacy — a row "legacy path → what is there that the new one lacks → where to
move it". The "what is there" column is computed mechanically, not from memory:

- `.md`: `##`/`###` headings of the old file that are missing from the new one; lines of the old
  file with paths from `git ls-files` or commands (`bash `, `python`, `npm`, `curl`, `/name`) that
  the new one lacks.
- `.sh`: top-level functions and variables (`^[a-z_]+\(\)`, `^[A-Z_]+=`) missing from the new one;
  for `notify.sh` and `safety-check.sh` of foreign origin — the whole body.
- `settings.json`: keys and hook entries removed or replaced during the merge.
- `CLAUDE.md`/`AGENTS.md` without markers: the headings of the old section.

The "where to move it" column — one address from the list: the PROJECT block of `<file>` · the
placeholder's place in an agent (`DOMAIN_CHECKLIST` → `reviewer.md` `### Domain` and
`codex-reviewer.md`; `DOC_TRIGGERS` → `committer.md`; `DEV_SERVER_RULE`, `SYMLINK_CMDS` →
`task-runner.md`; `ARCH_REVIEW_TRIGGERS` → `review-consolidator.md`) · a new project agent/skill in
`R∖T` · the text of `CLAUDE.md` outside the markers · a `[MANUAL]` task in `todo.md` (written only
on the owner's word). The content is moved by the owner or by the main session on the owner's word;
upgrade itself does not move anything.

## 6. What upgrade does not do

- Does not rewrite `R∖T`, even with broken frontmatter — report only (the exception is `R∖T ✗`).
- Does not change the pipeline's language on its own: `lang=` from the marker stays unless the owner
  chose another one in the interview. Replaced `.md` files are written in `PIPELINE_LANG` as in
  init (`knobs.md` D); `R∖T` files and the text outside the markers are never translated.
- Does not rewrite legacy markers in the owner's state files (`[ВРУЧНУЮ]`, `[ревью: Rn]`,
  `ЗАКРЫТ`): the scripts and skills accept both spellings. Switching to `[MANUAL]` /
  `[review: Rn]` / `CLOSED` is offered as one line in the report, the owner does it.
- Does not commit, does not push, does not run `/do-next`; the only git write is `git mv` under U2.
- Does not delete `.claude-legacy/` — the owner does, after the migration.
- Does not read or copy `settings.local.json`, `.env*`.
- Does not downgrade: if the skill version in the marker is newer than the current `SKILL_DIR` —
  stop and report.
