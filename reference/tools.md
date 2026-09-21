# Owner's tools — detection and installation by consent

The single source of detection and installation commands for `SKILL.md` (init phase 1 "Tools" step, the
"Assets" knob, upgrade, audit item 16). Everything here is installed into the owner's user scope, **outside
the repo** — therefore only after explicit consent; this is the only exception to the rule "do not touch
files outside the phase 3 list".

## 1. Rules

1. **Detect first, ask second.** Only missing tools that this project needs go into the question
   (the "When to offer" column). Everything is in place — no question.
2. **Before the question — in the chat**: for each candidate, the verbatim commands from §2, where they
   write (`~/.claude/**`, global `npm`, `~/rembg-mcp`, `~/.u2net`), and what is left to the owner
   afterwards. For rembg additionally: it is a third-party repository (neither Anthropic nor OpenAI) —
   give the link; models are downloaded on the first call (`birefnet-general` ≈ 970 MB, the others
   are smaller).
3. **Consent is a single `AskUserQuestion`**, `multiSelect`, one line per tool, recommended ones
   first with the note "(Recommended for this project)" and the reason from reconnaissance; the
   option "install nothing" is always present. Checked — install; not checked — an `[OWNER]` line in
   the report, as before.
4. **Installation** — the §2 commands one at a time, show the output of each. If one fails — do not
   fix the owner's environment (`npm` permissions, Python version, proxy): stop installing this
   tool, put the reason and the command into `[OWNER]`.
5. **After installation** — repeat the detection, update the row in the reconnaissance table; the
   interview recommendations (A2, "Assets") are computed from the new state.
6. `audit` installs nothing: detection → a report with the §2 commands.
7. The skill does not perform interactive steps (`codex login`, session restart, `/reload-plugins`) —
   always `[OWNER]`; for the login, suggest `! codex login` right in the session prompt.

## 2. Tools table

| Tool                           | When to offer                                      | Detection                                                                                                                                                                               | Installation after consent                                                                                                                                                                                                                                | Left to `[OWNER]`                                                                   |
| ------------------------------ | -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Plugin `codex@openai-codex`    | always (init/upgrade, after the reconnaissance table) | `claude plugin list --json \| jq -e '.[] \| select(.id=="codex@openai-codex" and .enabled)'`; no such subcommand — `jq '(.plugins // .)["codex@openai-codex"]' ~/.claude/plugins/installed_plugins.json` | `claude plugin marketplace add openai/codex-plugin-cc` → `claude plugin install codex@openai-codex` (scope `user`). Requires `node` ≥ 18.18 (`node --version`); if missing — `[OWNER]` only                                                                 | `/reload-plugins` or a session restart; `/codex:setup` will show readiness          |
| Codex CLI                      | together with the plugin                           | `command -v codex && codex --version`                                                                                                                                                   | `npm i -g @openai/codex` (requires `npm`; if missing — `[OWNER]` with a link to the plugin README)                                                                                                                                                         | `codex login` (ChatGPT subscription or API key)                                     |
| Image generation in Codex      | the "Assets" knob includes `codex`                 | `codex features list \| grep -E '^image_generation +[^ ]+ +true'`                                                                                                                         | `codex features enable image_generation` (writes to `~/.codex/config.toml`)                                                                                                                                                                                | —                                                                                   |
| rembg MCP (background removal) | the "Assets" knob includes `rembg`                 | `claude mcp get rembg` (exit code 0 and `Connected`)                                                                                                                                    | `git clone https://github.com/croef/rembg-mcp ~/rembg-mcp` → `cd ~/rembg-mcp && python3 -m venv rembg && rembg/bin/pip install --upgrade pip && rembg/bin/pip install mcp "rembg[cpu,cli]" pillow && rembg/bin/pip install -e .` → `claude mcp add rembg -s user -- ~/rembg-mcp/start_server.sh` | a session restart (MCP servers are read at startup)                                 |

Notes on rembg: requires `python3` ≥ 3.10 (`python3 -c 'import sys; print(sys.version_info >= (3,10))'`);
the venv must be named `rembg` and live in the clone directory — that is where `start_server.sh` looks
for it; do not use `./setup.sh` from the README — it is interactive (two `read` calls); if the
directory `~/rembg-mcp` already exists and is not a clone of `croef/rembg-mcp`
(`git -C ~/rembg-mcp remote get-url origin`) — do not touch it, ask the owner for another path. The
server's tools: `mcp__rembg__rembg-i` (a single file: `input_path`, `output_path`, optional `model`,
`alpha_matting`, `only_mask`) and `mcp__rembg__rembg-p` (a directory: `input_folder`,
`output_folder`; the result is `<name>.out.png`). Model: without the `model` parameter `u2net` is
used — on the first call it is downloaded into `~/.u2net`; already downloaded models are visible in
`ls ~/.u2net` and in the tool schema — substitute one of them into `{{ASSET_RULE}}` if there are
any (`birefnet-general` gives higher quality).

## 3. What the skill does not do

- It installs nothing silently and nothing "while at it": only what was checked in the §1.3 question.
- It does not write the plugin into the project `.claude/settings.json`
  (`enabledPlugins`/`extraKnownMarketplaces`): since Claude Code 2.1.195 a plugin from an external
  source is not installed that way — Claude Code merely shows the same `claude plugin install`
  command.
- It does not update what is already installed (`claude plugin update`, `npm update -g`) — that is
  the owner's version.
- It does not enter or read keys and tokens; `codex login` is for the owner only.
