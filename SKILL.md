---
name: agent-pipeline
description: Deploys a Claude Code agent pipeline into any repository (todo.md queue, a task-runner in a worktree per task, review by tiers R0–R3 decided by a script, Codex as the primary reviewer, a single bookkeeping writer, no auto-push), adapted to the project through a mandatory interview; upgrade mode updates an already deployed or hand-built .claude/** to the current templates while preserving project-specific work; audit mode checks an existing .claude/** against the principles. Use on "set up the agent pipeline", "deploy the do-all pipeline in this repo", "update/reinstall/rebuild the pipeline", "/agent-pipeline init", "/agent-pipeline upgrade", "/agent-pipeline audit", "audit our pipeline against the principles"; also on the Russian phrases «разверни агентный flow», «настрой конвейер do-all в этом репо», «обнови/переустанови/пересобери конвейер», «проверь наш пайплайн по принципам».
argument-hint: "init | upgrade | audit"
---

# agent-pipeline — init | upgrade | audit

Below, `SKILL_DIR` = the directory of this file (symlink `~/.claude/skills/agent-pipeline` → the skill's
git repo). Everything is done in the main session with the owner; the skill itself does not
run `/do-next`, does not commit and does not push.

Before starting, read `SKILL_DIR/reference/principles.md` (why it is this way) and
`SKILL_DIR/reference/knobs.md` (the interview matrix — the single source of options, pros/cons
and recommendation rules) and `SKILL_DIR/reference/tools.md` (detection and installation of the
owner's tools by consent); for `upgrade` — also `SKILL_DIR/reference/upgrade.md` (file classes,
merge rules, U questions). Argument empty — ask `init`, `upgrade` or `audit`. This skill is written
in English; talk to the owner in the language they write in (`knobs.md` D).

## init — five phases

### Phase 1. Reconnaissance (read-only, ask no questions)

Collect and show the owner ONE "found → proposed" table before any questions:

1. **Stack and package roots**: `package.json` (+ `pnpm-lock`/`yarn.lock`/`package-lock`),
   `pyproject.toml`/`requirements*.txt`/`uv.lock`, `go.mod`, `Cargo.toml`, `Makefile`; monorepo —
   several roots (`workspaces`, `apps/*`, `packages/*`).
2. **Commands**: tests, types, lint, build, formatter — from `scripts`, `Makefile`, CI yaml
   (`.github/workflows`, `.gitlab-ci.yml`). Dev server and port (`scripts.dev`, `vite.config`,
   `PORT=` in code/`.env.example`, `docker-compose`).
3. **Environment**: gitignored env files (`git check-ignore .env .env.local .envrc`), dependency
   directories (`node_modules`, `.venv`, `target`, `vendor`).
4. **Git**: `git remote -v`; `git rev-parse main origin/main` (they diverge → `baseRef: head`);
   `git log --shortstat -50` → median diff lines; presence of `.claude/**`, `AGENTS.md`, `CLAUDE.md`,
   `.worktreeinclude`, `todo.md`/`claude-progress.md`/`blockers.md`.
   **Non-empty `.claude/agents` or a `.claude/settings.json` with hooks → stop: offer `upgrade`
   (update while preserving existing work) or `audit` (report only), do not touch files.**
   `git rev-parse --verify HEAD` fails (not a single
   commit) → ask the owner to make the first commit before generation: the worktree and the tier
   script require HEAD, and the skill does not commit.
   **Instruction files**: `test -L CLAUDE.md` (symlink to `AGENTS.md` → "⚠ will ask", `knobs.md` B);
   `grep -nE '^@(\./)?AGENTS\.md' CLAUDE.md` (import already present → `{{AGENTS_IMPORT}}` is empty);
   nested ones — `git ls-files '*AGENTS.md' '*CLAUDE.md'`; `AGENTS.override.md`, `AGENTS.local.md`,
   `.agents/` (Claude Code does not read them — into the table as a fact); `claude --version`
   (`AGENTS.md` is read natively since 2.1.277 and only when there is no `CLAUDE.md` — that is why
   the pipeline keeps the import, `principles.md` §6).
5. **Candidate docs** for `CANON_DOCS`: `AGENTS.md`, `ARCHITECTURE.md`, `README.md`, `DESIGN.md`,
   `docs/index.md`, design guide (`design_guidelines.md`, `docs/ui/*`), API doc, plans directory;
   for each — the date of the last change (`git log -1 --format=%cs -- <file>`). Rules of other
   tools — `.cursorrules`, `.cursor/rules/`, `.github/copilot-instructions.md`,
   `.windsurfrules`, `.clinerules` — read as a source of invariants and commands, do not include
   in `CANON_DOCS`. **Language signals** for `PIPELINE_LANG` (`knobs.md` D): the prose language of
   these docs, of existing state files and of `git log -30 --format=%s`; they agree with the
   owner's conversation language → a fact in the table, otherwise "⚠ will ask".
6. **Critical path candidates** — by the heuristics of `knobs.md` A1 (`git ls-files | grep -iE
'auth|session|payment|billing|schema|migration|docker-compose|Dockerfile|workflows|secret'`),
   plus the domain core from the invariants in `AGENTS.md`/README.
7. **UI**: `client/`, `src/components`, `.tsx/.vue/.svelte`; Playwright (`playwright.config*`,
   MCP `playwright` in `claude mcp list`). UI present → the number of raster assets (`git ls-files | grep
   -cE '\.(png|jpe?g|webp)$'`) and the "Assets" knob (`knobs.md` B) — "⚠ will ask".
8. **Owner's environment**: `command -v codex python3 jq node`; the Codex plugin, Codex CLI, the
   `image_generation` feature, MCP `rembg` — with the detection commands of `tools.md` §2 (the last
   two — only with UI from item 7); `~/.codex/config.toml` (`model`, `model_reasoning_effort`), the
   catalog `~/.codex/models_cache.json`; `pwd` contains `Dropbox`. **Model freshness** per
   `knobs.md` E: the Codex catalog and the plugin's effort set (§2, local) and the Claude snapshot
   against Anthropic's official pages (§3, network) → a "Models" row in the table: "configured →
   status (current / flagged: why / snapshot stale) → proposed".
9. **Signs of parallel agent sessions** (`AGENT_ID`, several DBs in compose) and of an external
   tracker (Jira keys in commits) — they enable the optional questions of `knobs.md` B.

Table format: one row per item — "what was found (file/value) → what will be substituted
(placeholder)". Mark anything ambiguous "⚠ will ask". Do not move on to the interview without this
table (rule: explain first, then options).

**Tools — right after the table, before the interview.** No `codex@openai-codex` plugin or Codex
CLI → offer to install per `tools.md` §1: the commands and where they write — in the chat,
consent — one `AskUserQuestion`, install only what was checked, afterwards — repeat detection and
an updated table row (recommendation A2 depends on it). Refusal or installation failure — an
`[OWNER]` line in the report, the interview goes on. rembg and `image_generation` are offered
later — after the answer to the "Assets" knob (`knobs.md` B).

### Phase 2. Interview — mandatory, must not be skipped

Five questions `knobs.md` A1–A5, one at a time, each strictly in this format:

1. In the chat: the mechanics of the fork (2–3 lines); options with "+" and "−"; the line
   "**Recommended for this project: <option> — because <fact from reconnaissance>**".
2. `AskUserQuestion`: the recommended option first, labeled "(Recommended for this project)";
   `multiSelect` for lists (critical paths, doc triggers).
3. After the answer — one line "accepted: … → changes …" (what exactly in which files).

Order and content:

- **A1 critical paths** → `CRITICAL_GLOBS`.
- **A2 review models** — the review backend (Codex + Claude reader / Codex + Fable reader / Claude
  only / Codex only), then the Codex model and effort (`CODEX_MODEL`, `CODEX_EFFORT_R12`,
  `CODEX_EFFORT_R3`; the catalog from reconnaissance; the owner's current choice from `config.toml`
  is recommended unless `knobs.md` E flags it), the model of `reviewer` and `review-consolidator`.
- **A3 strictness profile** — `standard` / `strict` / `light` → `REVIEW_PROFILE`.
- **A4 executor models and effort** — `task-runner`, `coder`, `architect`, `researcher`,
  `tester`; `effortLevel` globally and per-role `effort:` only when non-default; the fallback
  family (`{{FALLBACK_MODEL}}`). One screen with 4 options: "default (Opus for
  runner/coder/architect/reviewer, high; fallback Fable)" / "Fable for architect and reviewer" /
  "everything on Fable (fallback Opus)" / "default + `xhigh`/`max` for reviewer/architect" — plus
  Other. The family names follow the `knobs.md` E leader rule: when the snapshot is stale, the
  screen is built from the current leader.
- **A5 docs and UI** — `committer` triggers, design guide, canonical docs, one line about the
  project.

Optional questions (`knobs.md` B) — only those that reconnaissance marked "⚠ will ask". Everything
else — the defaults of `knobs.md` C, without questions. The outcome of the phase — a
"setting → value → file" table in the chat; the owner confirms with one word, then generation.

### Phase 3. Generation

From `SKILL_DIR/templates/` into the target repo, substitutions — per the phase 2 table. Mechanics:

- **Language.** Templates are English. `PIPELINE_LANG = en` → copy as is. Otherwise translate the
  prose of every generated `.md` (agents, skills, both sections, state-file headers) into
  `PIPELINE_LANG` while substituting, and write the text values of `knobs.md` C in that language;
  the contract strings listed in `knobs.md` D stay English (script and JSON content, frontmatter
  except `description:`, markers, verdicts, report headings and field labels, section headings).
  `.sh`, `.json` and `docs/agent-pipeline-principles.md` are never translated. `{{PIPELINE_LANG}}` →
  `lang=` in both section markers; `{{LANG_RULE}}` → `AGENTS.md` section (empty for `en`).
- `.claude/agents/*.md`, `.claude/skills/{do-all,do-next,status}/SKILL.md`,
  `.claude/scripts/*`, `.claude/hooks/*` — copy + replace `{{NAME}}` (in `.md`) and edit the
  PROJECT blocks (`# === PROJECT-SPECIFIC (agent-pipeline init) === … # === /PROJECT-SPECIFIC ===`
  in `.sh`): `CRITICAL_GLOBS`, `CODEX_*`, `REVIEW_PROFILE`, thresholds, `PROTECTED_FILES`,
  `FORMAT_CMD`/`FORMAT_EXT_RE`/`FORMAT_BIN_CHECK`, `STATE_RE`. Replace the marker lines
  `# {{CRITICAL_GLOBS}}` / `# {{PROTECTED_FILES}}` with array elements, one per
  line, in quotes. `model:`/`effort:` in frontmatter — per A2/A4. UI + Playwright MCP —
  `{{UI_MCP_TOOLS}}` in the tester's `tools:` (the visual check is done by the tester, not the
  runner). The "Assets" knob — `{{ASSET_TOOLS}}` and `{{ASSET_RULE}}` in `coder.md`,
  `{{ASSET_SECTION}}` in the `CLAUDE.md` section (values — `knobs.md` C; `codex-image.sh` is always
  copied). Multi-line placeholders
  (`{{DOMAIN_CHECKLIST}}`, `{{UI_CHECKLIST}}`, `{{DOC_TRIGGERS}}`) — as ready text; `_QUOTED` —
  the same lines with the prefix `> `; empty value — remove the placeholder line and the empty line
  after it.
- `.claude/settings.json`: `__STACK_ALLOW__` → the stack's allow lines; `__FALLBACK_MODEL__` → the
  fallback family from A4; `__ASSET_ALLOW__` →
  `mcp__rembg__*` lines when `rembg` is in the "Assets" knob, otherwise the line is removed; **if the
  file already exists — merge with a `python3` script (not `jq '*'`: it overwrites scalars and
  arrays with the right-hand document)**:
  scalars — the owner's value stays, template keys are added only when missing;
  `permissions.allow`/`deny` and `env` — union (no duplicates, owner first); `hooks.<event>` —
  a template entry is added if no existing entry has the same `command`, otherwise it is
  skipped. Show the owner the diff before writing.
- `.gitignore` — append the lines from `gitignore.append` that are missing. `.worktreeinclude` — from
  the template, PROJECT block per reconnaissance; if the file exists — append what is missing.
- `AGENTS.md` / `CLAUDE.md`: exists — append the section from `AGENTS.section.md` /
  `CLAUDE.section.md` to the end (do not create duplicate headings); absent — create from the
  template. `{{STACK_SUMMARY}}`, `{{COMMANDS_TABLE}}`, `{{INVARIANTS}}`, `{{CRITICAL_SUMMARY}}`,
  `{{PROTECTED_SUMMARY}}` — from reconnaissance; `{{SKILL_REV}}` — `git -C SKILL_DIR rev-parse --short
  HEAD`. Keep the markers `<!-- agent-pipeline:begin … -->` / `<!-- agent-pipeline:end -->` from
  the section templates: `upgrade` uses them to find and replace its own section. `{{AGENTS_IMPORT}}`
  in the `CLAUDE.md` section — the bare line `@AGENTS.md` (no backticks and no indent — otherwise
  Claude Code will not expand the import); empty if the owner already imports `AGENTS.md` outside
  the section. `CLAUDE.md` is a
  symlink to `AGENTS.md` → per the answer to the `knobs.md` B question: replace the symlink with a
  regular file (import + section) or stop; do not write both sections into one file.
- `todo.md`, `claude-progress.md`, `blockers.md` — from `templates/state/` **only if they do not
  exist**; they exist — show the owner the instruction header from the template and offer to insert
  it and `SMOKE-1`.
- `SKILL_DIR/reference/principles.md` → `docs/agent-pipeline-principles.md` of the target repo
  (`CLAUDE.md` refers to it); there is a docs directory with a different name — put it there.
- `chmod +x .claude/scripts/*.sh .claude/hooks/*.sh`; `mkdir -p .claude/state .claude/worktrees`
  (+ `{{EXEC_PLANS_DIR}}/.gitkeep`, if the directory does not exist); Dropbox guard per `verify.md` §6.
- Keep a "file → substitutions" list for the report. Do not touch files outside `.claude/**`,
  `.worktreeinclude`, `.gitignore`, `AGENTS.md`, `CLAUDE.md`, `docs/agent-pipeline-principles.md`,
  `{{EXEC_PLANS_DIR}}/.gitkeep` and the three state files.

### Phase 4. Verification

Strictly per `SKILL_DIR/reference/verify.md` §1–§7: seven test matrices green, `review-tier.sh
--task-id SMOKE-1` yields `TIER=R1` and `PROFILE=`, hooks block/print, worktree add/remove,
`git check-ignore`, the `codex@openai-codex` plugin, Dropbox xattr, `grep '{{[A-Z_]*}}'` empty.
Red — fix it (the template or the
substitution) until green; the foreign tree is not changed in the process.

### Phase 5. Report and handoff

In the chat:

1. A table of created/changed files with substitutions.
2. An "accepted by default → where to switch" table (from `knobs.md` C).
3. `[OWNER]` actions: from `tools.md` — what the owner declined to install or what failed to
   install (with commands), `codex login`, `/reload-plugins` after installing the plugin;
   `/autocompact 400k` in user scope if desired,
   a commit of `.claude/**` + `AGENTS.md`/`CLAUDE.md` + the state files (done by the owner or, at
   the owner's word, by `committer` with an explicit list of paths; subject `chore(pipeline): set up
agent pipeline (agent-pipeline init)`), a restart of the Claude Code session (hooks and skills are
   read at startup).
4. The first run — `verify.md` §8: `/do-next SMOKE-1` and what to check.
5. Where to tune things later: the Codex profile and model — `review-tier.sh`; role models —
   frontmatter, the fallback — `fallbackModel` + `{{FALLBACK_MODEL}}` lines; revisiting the profile
   and the new models — by `found=`/`rounds=`/`codex=` in `.claude/state/runs.log`; an aged Codex
   model shows up as `MODEL_WARN` in the runner's report, an aged Claude choice — in
   `/agent-pipeline audit`. A stale `knobs.md` E snapshot → a line "update `knobs.md` E in the skill
   repository".

## upgrade — update a deployed or foreign pipeline

For a repo where `.claude/agents` is non-empty or `settings.json` has hooks. The pipeline there is
either "own" (installed by a previous version of the skill: PROJECT blocks in `.sh`, the
`agent-pipeline:begin` marker in `CLAUDE.md`) or "foreign" (built by hand or by another tool). The
mechanics of classification, merging and migration — `SKILL_DIR/reference/upgrade.md`; here — the
procedure. The same five phases as in init; only the differences are listed below.

### Phase 1. Reconnaissance

Everything from init items 1–9 (the "stop" rule from item 4 does not apply) and the "Tools" step
after the table, plus:

10. **Tree cleanliness**: `git status --porcelain -- .claude CLAUDE.md AGENTS.md .worktreeinclude
    .gitignore todo.md progress.md claude-progress.md blockers.md` is empty. Not empty → stop: the
    owner commits or sets the changes aside (`git stash`) themselves; upgrade does not start until
    the old versions are in git.
11. **Origin**: the marker `<!-- agent-pipeline:begin skill=… date=… lang=… -->` in `CLAUDE.md` and
    PROJECT blocks in `.claude/{hooks,scripts}/*.sh` → "own" (name the version, date and language);
    none of this → "foreign". The current skill version — `git -C SKILL_DIR rev-parse --short HEAD`.
    `lang=` is the pipeline's `PIPELINE_LANG` — keep it; no `lang=` → detect per `knobs.md` D
    (`upgrade.md` §0).
12. **Inventory** of `.claude/**`, `CLAUDE.md`, `AGENTS.md`, `.worktreeinclude`, the state files —
    each path into a class of `upgrade.md` §1: `T∩R =` (matches), `T∩R ≠` (differs; for own ones —
    "PROJECT block present/absent"), `T∖R` (will appear), `R∖T` (project file, not touched),
    `R∖T ✗` (name conflict `commands/<x>.md` ↔ `skills/<x>/`).
13. **Current setting values** — as interview recommendations, per the table in `upgrade.md` §2:
    `CRITICAL_GLOBS`, `REVIEW_*`, `CODEX_*`, thresholds from the old `review-tier.sh`;
    `model:`/`effort:` from the frontmatter of same-named agents; `PROTECTED_FILES` and secret
    patterns from the old `safety-check.sh`; doc triggers from the old `committer.md`; the actual
    state file names (`progress.md` ≠ `claude-progress.md` → "⚠ will ask").
14. **State files against the norms** of `principles.md` §6: size, `[x]` lines in `todo.md`, lines
    >1500 characters, the progress header not on one line → "⚠ will ask" (U4).
15. **`CLAUDE.md`/`AGENTS.md` prose that contradicts the pipeline**: direct calls of
    `@coder`/`@reviewer` from the main session, a custom `/do-all` loop, `git add .`, a different
    review backend, other state file names; rules duplicated in both files (after the `@AGENTS.md`
    import Claude sees them twice) — a list of lines with numbers. Into the report as `[MANUAL]`,
    do not edit.

The "found → proposed" table — as in init, plus an inventory table "class → path → action".

### Phase 2. Interview

A1–A5 from `knobs.md` are mandatory and in the same format, but "**Recommended for this project**" =
the current value from item 13, if there is one ("because that is what `<file>:<line>` has now");
the current value contradicts a `knobs.md` rule → recommend per `knobs.md`, give the current value
as the second option labeled "current". Then the U questions from `upgrade.md` §3 — only those
that reconnaissance marked "⚠ will ask":

- **U1 differing files `T∩R ≠`** — `multiSelect`: which to keep as old; empty = replace everything
  (recommendation), the old goes to legacy.
- **U2 state file names** — rename with `git mv` (recommendation) / keep and substitute
  `STATE_RE`.
- **U3 project agents from `R∖T`** — do not add to the runner's `Agent(…)` allow (recommendation) /
  add the listed ones.
- **U4 state archive** — the skill prepares the archives verbatim (recommendation) / the owner does
  it themselves.

The outcome — a "setting → value → file" table and the inventory table with final actions;
the owner confirms with one word.

### Phase 3. Generation

Strictly in the order of `upgrade.md` §4:

1. Legacy copy `.claude-legacy/<YYYY-MM-DD>/` of everything that will be replaced or moved (without
   `settings.local.json`, `state/`, `worktrees/`, `.env*`). Before this step — not a single write.
2. `T∖R` — as in init phase 3.
3. `T∩R ≠` — replace: own → the PROJECT blocks of the old file are carried over verbatim, show the
   diff "old block ↔ interview value" and ask once for all files; foreign → the values from
   item 13 into the PROJECT blocks of the new file, the body of the old one — into the migration
   table.
4. `R∖T ✗` — the old file goes to legacy.
5. `settings.json` — merge per `upgrade.md` §4.5: the template's hook entry wins if its `command`
   points to a replaced or new file; entries for files that moved to legacy are removed, shown to
   the owner; interview scalars (`effortLevel`, `worktree.baseRef`, `autoCompactWindow`,
   `fallbackModel`) — from the interview, the owner's other scalars stay; `allow`/`deny`/`env` —
   union. Diff before writing.
6. `CLAUDE.md`/`AGENTS.md` — replace between the `agent-pipeline:begin`/`end` markers; no markers,
   but there is a heading `## Agent pipeline (agent-pipeline)` (legacy: `## Агентный конвейер (agent-pipeline)`) — replace from it to the next `## `;
   nothing at all — append as in init. Do not touch the rest of the text.
7. State files — only per U2 (`git mv`) and U4 (archives); `SMOKE-1` — if there is no such ID.
8. `docs/agent-pipeline-principles.md` — replace entirely.
9. `chmod`, directories, Dropbox guard, `.gitignore`, `.worktreeinclude` — as in init.

Do not touch `R∖T` files under any circumstances. Keep a "file → class → action → substitutions"
list.

### Phase 4. Verification

`verify.md` §1–§7 plus §9 (upgrade only): legacy is outside `.claude/`, no
`commands`↔`skills` conflicts, every hook `command` points to an existing file, `R∖T` files are
byte-identical to HEAD, exactly one section marker, no old state file names in `.claude/**`.

### Phase 5. Report and handoff

As in init, plus:

1. The migration table of `upgrade.md` §5: "legacy file → what it has that the new one lacks →
   where to move it". Moving the content is done by the owner or by the main session at the
   owner's word; upgrade itself does not move it.
2. The `R∖T` list with a frontmatter lint (`model:` present; no `allowedTools`; `disallowedTools:
   Bash(…)` does not disable Bash) — report only.
3. The item 15 lines from `CLAUDE.md`/`AGENTS.md` — as one `[MANUAL]` task (writing to `todo.md` —
   at the owner's word).
4. `[OWNER]`: migrate per the table, delete `.claude-legacy/`, a commit `chore(pipeline): update
   agent pipeline (agent-pipeline upgrade)` with an explicit list of paths, a session restart,
   `/do-next SMOKE-1` (`verify.md` §8).

## audit — report only, no edits

A check of the target repo's `.claude/**` against the principles. The outcome — a table "item →
present / absent / differs → `principles.md` section". Items:

| #   | Check                                                                                                                                                             | How                                                                               |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| 1   | A runner per task: an agent with `isolation: worktree`, `tools: Agent(<allow list>)`, report ≤15 lines                                                            | frontmatter of `.claude/agents/*.md`                                              |
| 2   | The orchestrator is thin: `/do-all`/`/do-next`/`/status` (skills or commands), does not write state files, ff-merge                                               | command texts                                                                     |
| 3   | The tier is decided by a script (`review-tier.*`), not an agent; it prints the Codex model/effort; the profile/lineup come from the script                        | `grep -n 'CODEX_MODEL\|ROUND1\|PLAN' .claude/scripts/*`; hardcoded model in agents |
| 4   | Codex is the primary reviewer via the `codex@openai-codex` plugin (wrapper `codex-review.sh`); round 2 verifies in the same thread (`threadId`); `UNAVAILABLE` ≠ APPROVE | `codex-reviewer*.md`, `bash .claude/scripts/codex-review.sh check`                |
| 5   | Double review in a single message, the consolidator checks only the disagreements; two rounds, the second is final                                                | `task-runner`, `review-consolidator` (in a hand-built setup they may be named differently — look for the consolidating role and the double-review skill) |
| 6   | Fate of S3/S4: collector task/won't fix/`⏸️`; only S1/S2 spawns a task                                                                                            | runner prompts, `todo.md` header                                                  |
| 7   | Hooks: `safety-check` (Bash), `agent-sync-check` (Agent), `codex-prompt-write-guard` (Write), `post-edit`, `pre-compact`, `session-start`, `notify`; registered in `settings.json`; tests green | `jq .hooks`, a run of `*.test.sh`                                                 |
| 8   | `settings.json`: `worktree.baseRef`, `fallbackModel`, `autoCompactWindow`, `MCP_TOOL_TIMEOUT`, `git push` in deny                                                 | `jq`                                                                              |
| 9   | Frontmatter: no dead `allowedTools`; `disallowedTools: Bash(…)` does not accidentally disable Bash; `model:` on every agent                                       | grep                                                                              |
| 10  | `run_in_background` appears in prompts only as a prohibition; the item 7 hook is present                                                                          | grep                                                                              |
| 11  | State files: only open items in `todo.md`, lines ≤1500 characters, the progress header is one line, archives                                                      | `wc -c`, `awk 'length>1500'`                                                      |
| 12  | `.claude/state`, `.claude/worktrees`, `/artifacts/codex-prompts` in `.gitignore`; `.worktreeinclude`; Dropbox xattr                                              | `git check-ignore`, `xattr -p`                                                    |
| 13  | A single bookkeeping writer; ≤1 commit per runner exit; ID in the subject; no auto-push                                                                           | prompts, `git log --format=%s -30`                                                |
| 14  | Deliberate divergences (a task board instead of `todo.md` lines, task tiers, a value filter, telemetry in the repo, a context checkpoint, port slots)            | mark "deliberately absent", not as a defect (`principles.md` §10)                 |
| 15  | Instruction files: `CLAUDE.md` imports `@AGENTS.md` (or is a symlink to it) — otherwise Claude Code does not see `AGENTS.md`: it is read natively since 2.1.277 and only without a `CLAUDE.md`; shared rules — in `AGENTS.md` (Codex reads the same file from cwd), in `CLAUDE.md` — only Claude specifics, no duplicates; the section marker — one per file; prompts do not require a separate Read of `AGENTS.md`; a nested `AGENTS.md` next to a `CLAUDE.md` without an import, `AGENTS.override.md`, `AGENTS.local.md`, `.agents/` — Claude does not read them; the `AGENTS.md` chain from the root to cwd ≤ 32 KiB (the Codex limit `project_doc_max_bytes`: beyond it the rules silently do not reach the reviewer); `pluginConfigs."agents-md@builtin"` in the project `settings.json` — a dead setting (it works only in user/managed) | `grep -cE '^@(\./)?AGENTS\.md' CLAUDE.md`, `test -L CLAUDE.md`, `grep -c 'agent-pipeline:begin' CLAUDE.md AGENTS.md`, `git ls-files '*AGENTS*.md' '*CLAUDE.md' .agents`, `wc -c AGENTS.md`, `jq .pluginConfigs .claude/settings.json`, `grep -rniE 'read .AGENTS|прочитай .AGENTS' .claude/` (`principles.md` §6) |
| 16  | The owner's tools against what the config expects: `REVIEW_BACKEND≠claude` → the `codex@openai-codex` plugin, Codex CLI, login; `codex-image.sh` in the `tools:` of `coder` → `image_generation`; `mcp__rembg__*` in `tools:`/`allow` → MCP `rembg`. "Differs" — only when the config expects something absent; an extra installed tool is not a defect | the detection of `tools.md` §2, `bash .claude/scripts/codex-review.sh check`; into the report — the installation commands, audit itself installs nothing |
| 17  | Model freshness (`knobs.md` E): `CODEX_MODEL`/`CODEX_EFFORT_*` of `review-tier.sh` against the Codex catalog and the plugin's effort set; `model:` of runner/coder/architect/reviewer against the leader rule, and the owner's Claude Code versions against the one the alias needs (`opus` = Opus 5.5 from 2.1.280); `fallbackModel` ≠ the runner's model and matches the fallback in the prompts. "Differs" — a flagged model or effort, a non-leader family without a recorded reason, fallback = primary | `knobs.md` E §2 commands; `claude --version`; `bash .claude/scripts/review-tier.sh` (a `MODEL_WARN=` line); `grep -n '^model:' .claude/agents/*.md`; `jq .fallbackModel .claude/settings.json`; `grep -rn 'model: "' .claude/agents/task-runner.md .claude/skills/do-all/SKILL.md` |

For every "absent/differs" — one line: what, where, which `principles.md` section it refers
to, what to change (no edits — report only). At the end — the three most costly divergences and
a proposal: file them as `[MANUAL]` tasks in `todo.md` (writing — only at the owner's word).

## Rules

- Reconnaissance → table → interview → confirmation → generation → verification → report. No phase
  is skipped; the interview is not replaced by defaults even on a request like "do as you see
  fit" — in that case all five screens are shown with the recommended option, and the owner picks
  the first item.
- Every question — with the pros/cons of all options and a recommendation for this project with a
  reason.
- The owner's existing files are not overwritten: merge (`settings.json`), append (`.gitignore`,
  `AGENTS.md`, `CLAUDE.md`), skip (state files). There is already `.claude/agents/*` or hooks in
  `settings.json` → `upgrade` or `audit`, not `init` (the Phase 1 rule).
- In `upgrade`, only files that have a template counterpart (`T∩R ≠`) or a name conflict
  (`R∖T ✗`) are replaced, and only after the legacy copy with a clean tree; project files (`R∖T`)
  are not rewritten; `settings.local.json` is neither read nor copied; the only git write is
  `git mv` of the state files per U2.
- Do not run `/do-next`, do not commit, do not push, do not change `.env*`, `.git/config`.
- Outside the target repo the skill writes only by installing the owner's tools (the Codex plugin,
  Codex CLI, `image_generation`, rembg MCP) and only per `tools.md`: the commands are shown in
  advance, consent — via `AskUserQuestion`, only what was checked is installed; `audit` installs
  nothing.
- Language (`knobs.md` D): talk to the owner in the language they write in — tables, questions,
  options, reports; never ask about it. The generated files follow the repository
  (`PIPELINE_LANG`, default `en`); ask only when the signals disagree or are absent. Contract
  strings and scripts are English in every language.
- Long material goes in `reference/`; this file is the procedure and the checklist.
