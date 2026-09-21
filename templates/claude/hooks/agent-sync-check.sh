#!/usr/bin/env bash
# PreToolUse(Agent|Task): pipeline agents are called only synchronously.
# Exit 2 = the call is blocked (the reason goes to stderr, where the model sees it).
#
# Why: by default the harness starts a subagent in the background, and a background subagent
# reports to the MAIN session, not to whoever called it. The runner then
# ends its turn with "waiting for the coder" and no report, and its worktree with an empty diff
# is removed as unused. Coverage matrix — agent-sync-check.test.sh.
#
# Which agents are "pipeline" agents: the file names `.claude/agents/*.md` next to the hook
# (`<hook dir>/../agents`); directory override — env AGENT_PIPELINE_AGENTS_DIR
# (used by the test). No directory — the hook blocks nothing.
set -u
HOOK_INPUT="$(cat)"
export HOOK_INPUT
AGENTS_DIR="${AGENT_PIPELINE_AGENTS_DIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/agents}"
export AGENTS_DIR
python3 - <<'PY'
import json, os, sys

try:
    data = json.loads(os.environ.get("HOOK_INPUT") or "{}")
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)

ti = data.get("tool_input")
if not isinstance(ti, dict):
    sys.exit(0)

subagent = ti.get("subagent_type")
if not isinstance(subagent, str):
    sys.exit(0)
agents_dir = os.environ.get("AGENTS_DIR") or ""
try:
    pipeline = {f[:-3] for f in os.listdir(agents_dir) if f.endswith(".md")}
except OSError:
    sys.exit(0)
if subagent not in pipeline:
    sys.exit(0)

bg = ti.get("run_in_background")
if bg is False:
    sys.exit(0)

sys.stderr.write(
    "agent-sync-check: blocked — the pipeline agent `%s` is called only "
    "synchronously. Repeat the same call with `run_in_background: false`. A background "
    "subagent reports to the main session, not to you: you will end your turn with "
    "'waiting for the worker' and will not wake up on your own. Going back to an agent that has "
    "already finished is also a new synchronous call (not SendMessage: the reply will never come, "
    "and the resumed agent would write into the same tree in parallel).\n"
    % subagent
)
sys.exit(2)
PY
