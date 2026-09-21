# init and upgrade settings — interview matrix

The single source for the "Interview" phase of `SKILL.md` (in `upgrade` — with recommendations taken
from the current files per `upgrade.md` §2 and the additional U questions per `upgrade.md` §3). For
every setting: options, pros and cons, default, **the rule for recommending from reconnaissance**
(the skill must name the recommended option for this particular project and the reason from
reconnaissance), what changes in the templates.

Question format in chat: 1) the mechanics of the fork in 2–3 lines; 2) options with "+"/"−"; 3) the
line "**Recommended for this project: <option> — because <reconnaissance fact>**"; 4) an
`AskUserQuestion` screen, the recommended option first, labelled "(Recommended for this project)".
Between questions — one line "accepted: … → changes …".

## A. Mandatory questions (always asked, one at a time)

### A1. Critical paths → `CRITICAL_GLOBS` (`review-tier.sh`)

A diff touching these paths = tier `R3` (double review), even a single line and even `.md`.

| Candidate                                                                | Why                                           |
| ------------------------------------------------------------------------ | --------------------------------------------- |
| `.claude/*`, `.worktreeinclude`                                          | always: pipeline code                         |
| auth/session/permissions/rbac                                            | access                                        |
| payments/billing/invoice/pricing/subscription/webhook                    | money                                         |
| schema/models/migrations/alembic/prisma/drizzle                          | data; rollback is expensive                   |
| docker-compose*/Dockerfile*/deploy/infra/.github/workflows/k8s/terraform | deploy; breaks prod silently                  |
| security/crypto/secrets/env-loader                                       | security                                      |
| domain core (calculation, scoring, rules) — from `AGENTS.md`/invariants  | a mistake costs money or the user's trust     |

Question form: a list of what was found with checkboxes (`multiSelect`) + an "add your own" option.
**Recommendation:** check everything the heuristics above found; the domain core — if `AGENTS.md`
or the README contains the words "calculation", "payment", "permissions", "personal data". − Too
broad a list → everything is `R3`, the scheme gets expensive; too narrow → an S1 in R2 is caught by
one model. Guideline: ≤10 globs.

### A2. Who reviews — review models

| Option | + | − |
| --- | --- | --- |
| **Codex primary + Claude reader on double review** | Codex runs on its own subscription — the Claude limit is not spent; a second independent look where a mistake is expensive | needs the `codex` CLI and the `codex@openai-codex` plugin; two subscriptions |
| Codex primary + Claude reader on **Opus** | cheaper than Fable, the limit lasts longer; the second source repo has worked this way since 05.09.2026 with no increase in review returns | weaker than Fable on complex domain logic and long diffs |
| Claude only (no Codex) | one subscription, nothing to install | one model sees its own blind spots (writer and reviewer are the same family); every review eats the Claude limit |
| Codex only | minimum of Claude calls | on `R3` there is no second independent reader and no arbiter |

Inside the choice:

- **Codex model** — the catalogue is `~/.codex/models_cache.json`, the owner's current choice is
  `~/.codex/config.toml` (`model =`). Known ones: `gpt-6-astra` (newer; in the second source repo
  since 05.09.2026, flat `high`), `gpt-5.6-sol` (in the first, `high`/`xhigh` by tier, half a year
  of runs). Recommendation: whatever
  is set in the owner's `config.toml` — the owner has already chosen; if it is the default there
  and the project handles money — `gpt-5.6-sol` with `xhigh` on R3 (a proven combination).
- **Codex effort** (`CODEX_EFFORT_R12` / `CODEX_EFFORT_R3`): `high`/`xhigh` (default) · flat
  `high` (the second repo; cheaper, no margin on R3) · `xhigh` (expensive, for money and legal
  matters). The `codex@openai-codex` plugin does not accept `max`/`ultra` (the set is
  `none|minimal|low|medium|high|xhigh`); `ultra` is also unsuitable by design: it delegates subtasks
  on its own, so review time becomes unpredictable.
- **Claude reviewer model** (`reviewer.md` → `model:`): `fable` (default with money/legal/access)
  / `opus` (everything else). **Consolidator** (`review-consolidator.md`): `opus` (default; it reads
  two reports and spot-checks code — Fable's depth is not needed) / `sonnet` (pet project).

**Recommendation rule:** the `codex@openai-codex` plugin and the `codex` CLI with a login are
present (detection — `tools.md` §2; by this question installation by consent has already been
offered, look at the state after it) → option 1; Claude reviewer `fable` if money/access/data are
checked in A1, otherwise `opus`. The plugin and CLI are installed but there is no login yet → still
option 1 with an `[OWNER]` item "`codex login`": until login the wrapper returns `UNAVAILABLE`, and
`reviewer` takes the Codex role. The owner declined the installation or it failed → "Claude only"
(`REVIEW_BACKEND=claude`: the script prints `CODEX=none`, `reviewer` takes all Codex slots, there is
no double review and no consolidator) with an `[OWNER]` line "install the Codex CLI + the
`codex@openai-codex` plugin (commands — `tools.md`); then `REVIEW_BACKEND=both`" in the report; the
`codex-reviewer.md` template is installed anyway. "Codex only" — `REVIEW_BACKEND=codex`: there is no
Claude reader, `double → single`, no consolidator.

**Changes:** `REVIEW_BACKEND`, `CODEX_MODEL`, `CODEX_EFFORT_R12`, `CODEX_EFFORT_R3` in
`review-tier.sh`; `model:` in the frontmatter of `reviewer.md`, `review-consolidator.md`.

### A3. Strictness of the review scheme → `REVIEW_PROFILE`

| Profile | What | + | − |
| --- | --- | --- | --- |
| `standard` | R1/R2 — one Codex, R3 — Codex ‖ Claude + consolidator; round 2 is light everywhere (Codex verify in the same thread) | cost is proportional to risk; proven on two repos (scheme B, 2026-09-02) | one model on R1/R2 |
| `strict` | like `standard`, plus: R2 — double review with a consolidator; round 2 on R1 is escalated (Codex verify ‖ Claude full read — its first one); on R2/R3 round 2 is double (Codex verify ‖ Claude verification of the fix) | maximum of findings; a task with S1/S2 always sees both reviewers (scheme 2.5) | ~3 heavy calls per task; the queue reproduces itself (in an observed run: 6 closed, 12 spawned); the Claude limit |
| `light` | R1 — no review; R2 — one Codex; R3 — Codex ‖ Claude, the runner merges them without a consolidator; round 2 is light | cheap: pet project, docs, prototype | an S1 in R2 code is caught by one model; no arbiter on R3 |

**Recommendation rule:** A1 contains money/access/personal data → `standard`; the same, but the
repo has no tests or <20 test files → `strict` (review is the only safety net); a prototype,
documentation, a pet project without users → `light`.

**Changes:** `REVIEW_PROFILE` in `review-tier.sh` (agents read `ROUND1`/`ROUND2`/`CONSOLIDATOR` from
its output, their prompts do not change); `review-consolidator.md` is always installed (in `light`
it is not called).

### A4. Models and effort of the executors

| Role | Model options | + / − | Default |
| --- | --- | --- | --- |
| `task-runner` | `fable` / `opus` | Fable: holds 5 phases and the merging of reviews without losing the thread; − the Fable limit — the run will stall (the fallback is one retry on Opus). Opus: cheaper, weaker at merging | `fable` |
| `coder` | `fable` / `opus` | Fable: fewer returns from review on complex logic. Opus: the limit lasts longer; − per the second repo's data, more returns on complex tasks | `fable` |
| `architect` | `fable` / `opus` | called rarely, cost is not critical; Fable — plan quality | `fable` |
| `researcher` | `opus` / `sonnet` | read-only; Opus is enough | `opus` |
| `tester` | `sonnet` / `opus` | mechanics of a test run; Opus — if the tests are flaky and diagnosis is needed | `sonnet` |
| `committer` | `sonnet` | mechanics | `sonnet` |

**Effort of Claude roles:** the global `effortLevel` in `settings.json` (`low`/`medium`/`high`)
applies to the main session and the subagents; default `high`. Per-role — the `effort:` key in the
agent's frontmatter (`low`/`medium`/`high`/`xhigh`/`max`, availability depends on the model; the key
is in the list of frontmatter keys of Claude Code 2.1.251, it has not yet been used in live repos —
after the first init with a non-default, check in the transcript that the subagent's effort
changed); the templates do not set it, init adds it only if the owner chose a non-default for the
role. Options: `high` everywhere (default) · `max`/`xhigh` for `reviewer` and `architect` (deeper,
longer; for money and legal matters) · `medium` for `tester`/`committer` (faster; we leave the
default alone — the savings are negligible).

**Recommendation rule:** complex domain logic (calculations, permissions, statuses, multi-step
forms) → Fable for runner/coder/architect, `high`; CRUD/frontend/docs/scripts → `opus` for `coder`,
the rest default. `fallbackModel: ["opus"]` always.

**Changes:** `model:`/`effort:` in the frontmatter; `effortLevel` in `settings.json`.

### A5. Docs and UI

- **Doc update triggers** (`{{DOC_TRIGGERS}}` in `committer.md`): candidates from reconnaissance —
  the API doc on a new route, the DB schema on a migration, `ARCHITECTURE.md` on a new module, the
  design guide on a new UI pattern, `README` on a new command. Form: checkboxes over the docs found.
  Default for "no docs" — a single rule: "new command/script → a line in the README".
  Rule format: `**Rule N — <when>:** if the diff has <sign> → update <file>, section <…>`.
- **Design guide** (`{{UI_GUIDE_DOC}}`): the file found (`design_guidelines.md`, `DESIGN.md`,
  `docs/ui/*`) or "no UI — do not do the visual check". Changes `coder.md`, `tester.md`,
  `task-runner.md`; with UI + Playwright MCP — `{{UI_VISUAL_CMDS}}` and `{{UI_MCP_TOOLS}}` (six
  `mcp__plugin_playwright_playwright__browser_*`) in the tester's `tools:` — the tester does the
  visual check.
- **Canonical docs** (`{{CANON_DOCS}}`): `AGENTS.md`, `ARCHITECTURE.md`, `README.md`, whatever was
  found. **One line about the project** (`{{PROJECT_ONE_LINER}}`): "<name> (<what it is>, <stack>)"
  — from the README/`package.json` `description`, show it to the owner for editing.

**Recommendation rule:** there is `client/`, `src/components`, `.vue`, `.svelte`, `app/` with TSX →
there is a UI; the design guide — the first one found by the names above; triggers — only for docs
that exist and were edited within the last 90 days (`git log --since`).

## B. Optional questions — only when reconnaissance is ambiguous

| Setting | When to ask | Options and recommendation | Changes |
| --- | --- | --- | --- |
| Runner port | a dev server was found, but the port cannot be derived from scripts/config | `<port> + 100` (recommendation; the owner keeps their own server on the base port) / custom | `{{DEV_SERVER_RULE}}` |
| `worktree.baseRef` | there is an `origin` and `origin/main` ≠ local `main` | `head` (recommendation: branch from the local HEAD, otherwise the worktree lags behind) / `origin/main` | `settings.json` |
| Port/DB slots | the repo already has `AGENT_ID`, a `docker-compose` with several DBs, signs of parallel sessions | one port (recommendation for a single session) / slots by `AGENT_ID` (describe to the owner, not implemented in the template) | `{{DEV_SERVER_RULE}}` |
| Task ID format | the repo already has a tracker with different IDs (Jira keys, `#123`) | `<BLOCK>-<N>` (recommendation: block = collector task `CHORES-<BLOCK>`) / external keys in the title, the ID is our own | header of `state/todo.md` |
| Plans | a plans directory was found (`docs/exec-plans`, `docs/plans`, `PLANS.md`) | the one found (recommendation) / `docs/plans/active` (create) / no plans | `{{EXEC_PLANS_DIR}}` |
| Tier thresholds | a monorepo or very large files (median diff >200 lines per `git log --shortstat`) | default `20/2/60` (recommendation if the median is ordinary) / raise `CODE_R1_MAX_LINES` to 120 | `DOCS_R0_MAX_LINES`, `CODE_R1_MAX_FILES`, `CODE_R1_MAX_LINES` |
| Assets | a UI was found (reconnaissance item 7) | `codex+rembg` — image generation through the Codex CLI and background removal with rembg (+ `coder` makes illustrations, icons, backgrounds itself; − minutes and Codex quota per image, rembg is a third-party server and models up to ~1 GB) / `codex` (+ no third-party installs; − the background is removed only by the `--transparent` hint) / `rembg` (+ local and free; − the owner supplies the images) / `none` (+ nothing extra on `coder`; − assets are done manually). Recommendation: the repo has raster assets (`git ls-files \| grep -cE '\.(png\|jpe?g\|webp)$'` > 0) → `codex+rembg`; none → `none`. After the answer — detect and install what is missing per `tools.md` (`image_generation`, rembg); a refusal or failure → the value narrows to what is installed, the rest goes to `[OWNER]` | `{{ASSET_TOOLS}}`, `{{ASSET_RULE}}`, `{{ASSET_SECTION}}`, `__ASSET_ALLOW__` |
| `CLAUDE.md` is a symlink | `test -L CLAUDE.md` and the target is `AGENTS.md` | replace the symlink with a regular `CLAUDE.md`: the line `@AGENTS.md` + the pipeline section (recommendation: the content Claude sees is the same, while the section and the version marker get a file of their own; on Windows a symlink requires administrator rights anyway) / stop — the owner decides; do not write both sections into a single `AGENTS.md`: `upgrade` looks for one pair of markers per file | `CLAUDE.md` |
| Language of generated files | the language signals disagree, are mixed or are absent (section D) | the repository's language / the owner's conversation language / English — the recommendation follows the rules of section D; never asked when the signals agree | `{{PIPELINE_LANG}}`, `{{LANG_RULE}}`, the prose of all generated `.md` files |

## C. Accepted by default (in the report — as a "where to switch" table)

| Setting | Default | Where |
| --- | --- | --- |
| `autoCompactWindow` | `400000` | `settings.json` |
| `fallbackModel` | `["opus"]` | `settings.json` |
| `MCP_TOOL_TIMEOUT` | `1800000` (30 min; historically — for the Codex MCP, now Codex goes through the plugin and the `codex-review.sh` wrapper enforces the limit; kept for the playwright MCP) | `settings.json` → `env` |
| `PLAYWRIGHT_MCP_ISOLATED` | `"true"` only with UI + Playwright MCP | `settings.json` → `env` |
| `__STACK_ALLOW__` | allow list of the stack's commands: `npm/npx/node` · `pnpm` · `yarn` · `python/pip/pytest/uv` · `cargo` · `go` · `make`; from reconnaissance | `settings.json` → `permissions.allow` |
| `{{TEST_TOOLS}}` | `Bash(<test cmd> *)` by stack (`Bash(npx vitest *)`, `Bash(pytest *)`, …) | `tester.md` → `tools:` |
| `{{TEST_CMDS}}`, `{{CHECK_CMDS}}` | test / type-check / lint commands from `scripts`, `Makefile`, CI | `tester.md`, `coder.md` |
| `{{TEST_DIRS}}` | test directories from reconnaissance | `architect.md` |
| `{{SYMLINK_CMDS}}` | `ln -s ../../../node_modules node_modules` / `.venv` / `target` — per package root; monorepo — one per root | `task-runner.md` |
| `{{FORMAT_CMD}}` | `npx prettier --write` when `prettier` is in devDeps; `ruff format`; `gofmt -w`; `cargo fmt --`; otherwise empty | `post-edit.sh` + `FORMAT_EXT_RE`, `FORMAT_BIN_CHECK` |
| `{{PROTECTED_FILES}}` | the `docker-compose.prod*`, `Dockerfile.prod`, `*.pem`, `*.key` files found | `safety-check.sh` |
| `{{ARCH_REVIEW_TRIGGERS}}` | "API routes, the data schema, the response format of the public API" + the contract files found (`routes`, `schema`, `openapi`) | `review-consolidator.md` |
| `{{DOMAIN_CHECKLIST}}` | 3–6 items from the "invariants" of `AGENTS.md`/README (`### Domain` + checkboxes); none — the section is empty | `reviewer.md`; `_QUOTED` — the same lines with `> ` in `codex-reviewer.md` |
| `{{UI_CHECKLIST}}` | with UI: "colors/radii/spacing from the system; touch target ≥44px; both viewports; copy reads naturally, not as a literal translation"; otherwise empty | `reviewer.md`; `_QUOTED` — in `codex-reviewer.md` |
| `{{DEV_SERVER_RULE}}` | there is a dev server: "The owner's dev server in the main checkout may be holding port `<P>`: start your own from the worktree as `<cmd on P+100>` in the background, view pages at `http://localhost:<P+100>`, and stop the process when the task is finished (`kill -TERM`)."; none: "The project has no dev server — verify with tests and the CLI." | `task-runner.md` |
| `{{STACK_TOOLS}}` | `Bash(<pm> *)`, `Bash(<runtime> *)` by stack — the same selection as `__STACK_ALLOW__` (`Bash(npm *), Bash(npx *), Bash(node *)` / `Bash(pnpm *)` / `Bash(python *), Bash(pip *), Bash(uv *)` / `Bash(go *)` / `Bash(cargo *)` / `Bash(make *)`) | `coder.md` → `tools:` |
| `{{UI_MCP_TOOLS}}` | with UI + Playwright MCP: `, mcp__plugin_playwright_playwright__browser_navigate, …_snapshot, …_take_screenshot, …_resize, …_click, …_evaluate`; otherwise empty | `tester.md` → `tools:` |
| `{{ASSET_TOOLS}}` | by the "Assets" knob (B), appended to the end of the `tools:` line: `codex` → `, Bash(bash .claude/scripts/codex-image.sh *)`; `rembg` → `, mcp__rembg__rembg-i, mcp__rembg__rembg-p`; `codex+rembg` → both; `none` or no UI → empty. `codex-image.sh` itself (+ its test) is always installed, like `codex-reviewer.md` | `coder.md` → `tools:` |
| `{{ASSET_RULE}}` | an item of the rules list, assembled from two sentences according to the knob. Generation: "- **Assets**: do not draw a raster image (illustration, icon, background) with code and do not take one from the web — generate it: `bash .claude/scripts/codex-image.sh --out <path.png> [--size WxH] [--transparent] <<'CODEX_PROMPT_END'` … `CODEX_PROMPT_END` (in the description — subject, style, palette from the design guide; give the Bash call `timeout: 600000`); check the result with `file <path>`, no more than two attempts per asset. `IMAGE=UNAVAILABLE` — do not stop the task: describe in "Needs attention" what to generate and where." Background: "Remove the background with `mcp__rembg__rembg-i` (`input_path`/`output_path` — absolute paths inside the worktree; do not put the source image with the background into the commit)." `rembg` only — the item starts with "- **Assets**: remove the background of images…"; `none` → empty | `coder.md` |
| `{{ASSET_SECTION}}` | the `### Assets` subsection (3–5 lines): what is enabled by the knob; generation — `.claude/scripts/codex-image.sh` (Codex CLI, `image_generation`, read-only, the wrapper copies the file to `--out`, a refusal → `IMAGE=UNAVAILABLE` and the task is not blocked); background — the `rembg` MCP; the tools are installed on the owner's machine, not in the repo (`docs/agent-pipeline-principles.md`); generated files go through the ordinary review tier. `none` → empty | `CLAUDE.section.md` |
| `__ASSET_ALLOW__` | with `rembg` in the knob: `"mcp__rembg__rembg-i", "mcp__rembg__rembg-p"`; otherwise the line is removed (the `codex-image.sh` wrapper is already covered by `Bash(bash .claude/scripts/*)`) | `settings.json` → `permissions.allow` |
| `{{EXEC_PLANS_DIR}}` | the plans directory found; none — `docs/plans/active` (create with `.gitkeep`) | `task-runner.md`, skills, `CLAUDE.section.md` |
| `{{REVIEW_BACKEND}}` | `both` / `claude` / `codex` from A2 | `review-tier.sh`, `CLAUDE.section.md` |
| `{{RUNNER_EXTRA_READS}}` | empty; when `ARCHITECTURE.md` was found — " Then `ARCHITECTURE.md`." | `task-runner.md` |
| `{{INIT_DATE}}` | the init date (in `upgrade` — the upgrade date) | `state/claude-progress.md`, `CLAUDE.section.md` (text and marker) |
| `{{SKILL_REV}}` | `git -C SKILL_DIR rev-parse --short HEAD` — the skill version by which `upgrade` recognises an "own" pipeline and its age | `CLAUDE.section.md`, `AGENTS.section.md` (the `agent-pipeline:begin` marker) |
| `{{AGENTS_IMPORT}}` | the bare line `@AGENTS.md` (no backticks and no indent — otherwise Claude Code will not expand the import): when `CLAUDE.md` exists, the native reading of `AGENTS.md` (Claude Code ≥2.1.277) does not kick in, the import works on any version and does not cause a double read; empty if the owner already imports `AGENTS.md` outside the section | `CLAUDE.section.md` |
| `{{DOMAIN_CHECKLIST_QUOTED}}`, `{{UI_CHECKLIST_QUOTED}}` | the same checklists, every line prefixed with `> ` (a quote inside the Codex prompt) | `codex-reviewer.md` |
| `{{CRITICAL_GLOBS}}` | a marker line in the array; replaced with the items from A1, one per line, in quotes | `review-tier.sh` |
| `{{REVIEW_PROFILE}}`, `{{CODEX_MODEL}}` | the values from A3/A2 — for the text of `CLAUDE.md` | `CLAUDE.section.md` |
| `{{CRITICAL_SUMMARY}}` | the critical paths from A1 in words ("payments, auth, migrations") | `CLAUDE.section.md` |
| `{{STACK_SUMMARY}}`, `{{COMMANDS_TABLE}}` | the stack in one line; the commands table (tests/types/lint/build/dev server) from reconnaissance | `AGENTS.section.md` |
| `{{INVARIANTS}}` | 3–6 project invariants from the README/docs (they match `{{DOMAIN_CHECKLIST}}`); none — "(filled in by the owner)" | `AGENTS.section.md` |
| `{{PROTECTED_SUMMARY}}` | `{{PROTECTED_FILES}}` in words | `AGENTS.section.md` |
| `{{PIPELINE_LANG}}` | the language code from section D (`en` by default, `ru`, `de`, …) | the `agent-pipeline:begin` marker of `CLAUDE.section.md`, `AGENTS.section.md` |
| `{{LANG_RULE}}` | `en` → empty. Otherwise one bullet, written in that language: "Language: write bookkeeping lines, blockers, commit subjects, docs and reports to the owner in <language>. Fixed tokens, report headings and field labels, and script output stay English — do not translate them." | `AGENTS.section.md` (reaches Claude through the `@AGENTS.md` import and Codex natively) |
| `STATE_FILES` / `STATE_RE` | `todo.md`, `claude-progress.md`, `blockers.md` in the root | `review-tier.sh`, `task-commit.sh` |
| `.worktreeinclude` | gitignored env files from reconnaissance (`.env`, `.env.local`, `.envrc`) | the file's PROJECT block |

Reconciliation: `grep -rhno '{{[A-Z_]*}}' templates/ | sort -u` — every placeholder is in this table
or in sections A/B.

## D. Language

The skill, its reference docs and all templates are English. Two languages are chosen per run, and
neither is ever assumed from the skill's own language.

**1. Conversation language** — the language the owner writes in. Everything the skill says to the
owner is in it: the reconnaissance table, explanations, pros and cons, `AskUserQuestion` labels and
descriptions, the final report. File names, commands, placeholders and the contract strings below
stay verbatim. The owner switches language mid-run — follow. No question is ever asked about this.

**2. `PIPELINE_LANG`** — the language of the prose in the generated files, and the language the
pipeline agents will write in (bookkeeping lines, blockers, commit subjects, reports to the owner).
Default `en`. It follows the repository, not the skill:

| Signal (reconnaissance)                                                                       | Weight                       |
| --------------------------------------------------------------------------------------------- | ---------------------------- |
| prose of `AGENTS.md`, `CLAUDE.md`, `README*`, `docs/**`                                       | main                         |
| existing `todo.md` / progress / blockers files                                                | main                         |
| subjects of the last 30 commits (`git log -30 --format=%s`)                                   | main                         |
| the owner's conversation language                                                             | tie-breaker                  |
| identifiers, code comments, dependency names                                                  | not a signal (English anyway) |

- The main signals agree with each other and with the conversation language → that language, no
  question (shown in the reconnaissance table as a fact).
- The main signals agree with each other but not with the conversation language → "⚠ will ask"
  (row "Language of generated files" in B); recommend the repository's language — because the
  agents read those docs and continue those commit subjects and state files.
- The main signals are mixed, or there are none (a new or near-empty repo) → "⚠ will ask";
  recommend the conversation language — because the owner will write `todo.md` in it.
- Nothing points anywhere → `en`.

**What `PIPELINE_LANG ≠ en` changes.** On generation the skill translates the prose of the `.md`
templates (agents, skills, the `CLAUDE.md`/`AGENTS.md` sections, state-file headers) and produces
the text values of section C (`{{DOMAIN_CHECKLIST}}`, `{{UI_CHECKLIST}}`, `{{DOC_TRIGGERS}}`,
`{{DEV_SERVER_RULE}}`, `{{ASSET_RULE}}`, `{{ASSET_SECTION}}`, `{{ARCH_REVIEW_TRIGGERS}}`,
`{{INVARIANTS}}`, …) directly in that language. Translate meaning-for-meaning, keep every rule,
number, condition and the order; do not shorten. `{{LANG_RULE}}` tells the agents which language to
write in.

**Contract strings — English in every language.** They are what scripts parse and what agents
exchange, so they are never translated:

- everything in `.sh` and `.json` files, script output (`TIER=`, `ROUND1=`, `REASON=`, `IMAGE=`,
  `RESULT=`, `ACTIVE`, `PENDING job=…`, `### Verdict: UNAVAILABLE`, `Reason:`, `threadId:`);
- YAML frontmatter except `description:`; tool names, paths, commands, placeholders, markers
  `<!-- agent-pipeline:… -->` and `# === PROJECT-SPECIFIC … ===`;
- task markers `[MANUAL]`, `[OWNER]`, `[review: Rn]`, `⏸️`, `[fix-in-place]`, `[won't fix: …]`, task
  IDs, `CHORES-<block>`; verdicts and outcomes (`APPROVE`, `CHANGES_NEEDED`, `ARCHITECTURE_REVIEW`,
  `BLOCKED`, `UNAVAILABLE`, `DONE`, `FAILED`, `SKIPPED`, `TESTS_PASS`, `TESTS_FAIL`), `S1`–`S4`,
  `R0`–`R3`;
- report-format headings and field labels of the agents (`### Verdict`, `### Findings`,
  `### Coverage`, `### Needs attention`, `Summary:`, `Review:`, `Files:`, `Task files:`, …), the
  headings of the `CLAUDE.md`/`AGENTS.md` sections, commit types (`feat`, `fix`, `chore(todo)`);
- `docs/agent-pipeline-principles.md` — copied as is; the skill explains any part of it in the
  conversation language on request.

The chosen value is recorded as `lang=<code>` in the section markers (`{{PIPELINE_LANG}}`), which is
where `upgrade` reads it from.
