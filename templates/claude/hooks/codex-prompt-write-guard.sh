#!/usr/bin/env bash
# PreToolUse(Write|Edit|MultiEdit|NotebookEdit): @codex-reviewer writes exactly one kind of file —
# the Codex prompt `<working directory>/artifacts/codex-prompts/<name>.md`. Everything else is
# forbidden to it: Write is granted only for `codex-review.sh run --prompt-file`, because Claude
# Code's worktree-isolation guard rejects a heredoc fed to bash. Other agents and the main session
# are not touched. Exit 2 = the write is blocked (the reason is on stderr, the model sees it).
#
# The working directory is the project root (manual mode) or the task worktree
# `<root>/.claude/worktrees/<name>`. Root: env CLAUDE_PROJECT_DIR, else two levels above the hook's
# directory. Coverage matrix — codex-prompt-write-guard.test.sh.
set -u
# bash builtins only up to the python check: a crashed hook does not block the tool call
IFS= read -r -d '' HOOK_INPUT || true
export HOOK_INPUT
HOOK_DIR="${0%/*}"; [ "$HOOK_DIR" = "$0" ] && HOOK_DIR=.
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$HOOK_DIR/../.." 2>/dev/null && pwd)}"
export PROJECT_ROOT
# no python3: fail closed for codex-reviewer, pass everyone else. Rough builtin match on the
# agent_type field; an escaped copy of it inside file content also matches — a rare false block
AGENT_RE='"agent_type"[[:space:]]*:[[:space:]]*"codex-reviewer"'
if ! command -v python3 >/dev/null 2>&1; then
  if [[ "$HOOK_INPUT" =~ $AGENT_RE ]]; then
    echo "codex-prompt-write-guard: blocked — python3 not found, the write path of @codex-reviewer cannot be checked. Return \`### Verdict: UNAVAILABLE\` with this text." >&2
    exit 2
  fi
  exit 0
fi
python3 - <<'PY'
import json, os, sys

try:
    data = json.loads(os.environ.get("HOOK_INPUT") or "{}")
except Exception:
    sys.exit(0)
if not isinstance(data, dict) or data.get("agent_type") != "codex-reviewer":
    sys.exit(0)

def deny(why):
    sys.stderr.write(
        "codex-prompt-write-guard: blocked — @codex-reviewer writes only the prompt file "
        "<working directory>/artifacts/codex-prompts/<name>.md and only with the Write tool (" + why + "). "
        "Do not work around it: return `### Verdict: UNAVAILABLE` with this text.\n")
    sys.exit(2)

tool = data.get("tool_name") or ""
if tool != "Write":
    deny("tool " + (tool or "?"))
ti = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
path = ti.get("file_path")
if not isinstance(path, str) or not path:
    deny("no file_path")
if ".." in path.replace("\\", "/").split("/"):
    deny("path with '..'")
cwd = data.get("cwd") if isinstance(data.get("cwd"), str) and data.get("cwd") else os.getcwd()
full = os.path.normpath(os.path.join(cwd, path))
name = os.path.basename(full)
prompts_dir = os.path.dirname(full)
workdir = os.path.dirname(os.path.dirname(prompts_dir))
if not name.endswith(".md") or name.startswith("."):
    deny("not .md: " + name)
if os.path.basename(prompts_dir) != "codex-prompts" or os.path.basename(os.path.dirname(prompts_dir)) != "artifacts":
    deny("not the artifacts/codex-prompts directory: " + full)
for d in (os.path.dirname(prompts_dir), prompts_dir, full):
    if os.path.islink(d):
        deny("symbolic link: " + d)
# only the agent's own tree (not a sibling worktree), and that tree must be the project root or a
# task worktree: there `/artifacts/codex-prompts/` is ignored by the root-anchored .gitignore rule
root = os.path.normpath(os.environ.get("PROJECT_ROOT") or "/nonexistent")
own = os.path.normpath(cwd)
if workdir != own:
    deny("not its own working directory " + own + ": " + full)
if own != root and os.path.dirname(own) != os.path.join(root, ".claude", "worktrees"):
    deny("the working directory is neither the project root nor a task worktree: " + own)
sys.exit(0)
PY
