#!/usr/bin/env bash
# Coverage matrix for codex-prompt-write-guard.sh: "expected exit|JSON hook_input".
# The project root in the fixture is /r (env CLAUDE_PROJECT_DIR). Run: bash .claude/hooks/codex-prompt-write-guard.test.sh
HOOK="$(dirname "$0")/codex-prompt-write-guard.sh"
export CLAUDE_PROJECT_DIR=/r
pass=0; fail=0
while IFS='|' read -r want payload; do
  [ -z "$want" ] && continue
  case "$want" in \#*) continue;; esac
  got=$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null; echo $?)
  if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL want=$want got=$got :: $payload"; fi
done <<'CASES'
# --- allow (0): the prompt file in the root or in the task worktree ---
0|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/r","tool_input":{"file_path":"/r/artifacts/codex-prompts/PIPE-3-review.md"}}
0|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/r/.claude/worktrees/agent-x","tool_input":{"file_path":"/r/.claude/worktrees/agent-x/artifacts/codex-prompts/ECON-6-a-verify.md"}}
0|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/r/.claude/worktrees/agent-x","tool_input":{"file_path":"artifacts/codex-prompts/task-review.md"}}
# --- block (2): a foreign tree — a sibling worktree, the root from a worktree, cwd outside the project ---
2|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/r","tool_input":{"file_path":"/r/.claude/worktrees/agent-y/artifacts/codex-prompts/X-review.md"}}
2|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/r/.claude/worktrees/agent-x","tool_input":{"file_path":"/r/.claude/worktrees/agent-y/artifacts/codex-prompts/X-review.md"}}
2|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/r/.claude/worktrees/agent-x","tool_input":{"file_path":"/r/artifacts/codex-prompts/X-review.md"}}
2|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/tmp","tool_input":{"file_path":"/tmp/artifacts/codex-prompts/X-review.md"}}
2|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/r/src","tool_input":{"file_path":"/r/src/artifacts/codex-prompts/X-review.md"}}
# --- allow (0): other agents and the main session, garbage ---
0|{"agent_type":"coder","tool_name":"Write","cwd":"/r","tool_input":{"file_path":"/r/src/preview.ts"}}
0|{"tool_name":"Write","cwd":"/r","tool_input":{"file_path":"/r/.claude/agents/codex-reviewer.md"}}
0|{"agent_type":"review-consolidator","tool_name":"Write","cwd":"/r","tool_input":{"file_path":"/tmp/x.md"}}
0|not json
# --- block (2): codex-reviewer writes to the wrong place or with the wrong tool ---
2|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/r","tool_input":{"file_path":"/r/src/preview.ts"}}
2|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/r","tool_input":{"file_path":"/r/.claude/settings.json"}}
2|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/r","tool_input":{"file_path":"/r/codex-prompts/X-review.md"}}
2|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/r","tool_input":{"file_path":"/r/artifacts/X-review.md"}}
2|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/r","tool_input":{"file_path":"/r/artifacts/codex-prompts/X-review.sh"}}
2|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/r","tool_input":{"file_path":"/r/artifacts/codex-prompts/sub/X-review.md"}}
2|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/r","tool_input":{"file_path":"/r/artifacts/codex-prompts/../../src/x.md"}}
2|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/r","tool_input":{"file_path":"/r/src/artifacts/codex-prompts/X-review.md"}}
2|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/r","tool_input":{"file_path":"/tmp/artifacts/codex-prompts/X-review.md"}}
2|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/r","tool_input":{"file_path":"/r/.claude/worktrees/a/b/artifacts/codex-prompts/X-review.md"}}
2|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/r","tool_input":{"file_path":"/r/artifacts/codex-prompts/.hidden.md"}}
2|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/r","tool_input":{}}
2|{"agent_type":"codex-reviewer","tool_name":"Edit","cwd":"/r","tool_input":{"file_path":"/r/artifacts/codex-prompts/X-review.md"}}
2|{"agent_type":"codex-reviewer","tool_name":"NotebookEdit","cwd":"/r","tool_input":{"notebook_path":"/r/artifacts/codex-prompts/X.ipynb"}}
CASES
# empty PATH (no python3, no cat/grep/dirname): codex-reviewer is blocked (2), others pass (0)
NOPY="$(mktemp -d)"; trap 'rm -rf "$NOPY"' EXIT
for c in '2|{"agent_type":"codex-reviewer","tool_name":"Write","cwd":"/r","tool_input":{"file_path":"/r/artifacts/codex-prompts/X-review.md"}}' \
         '2|{"agent_type" : "codex-reviewer","tool_name":"Write","cwd":"/r","tool_input":{"file_path":"/r/src/preview.ts"}}' \
         '0|{"agent_type":"coder","tool_name":"Write","cwd":"/r","tool_input":{"file_path":"/r/src/preview.ts"}}' \
         '0|{"agent_type":"coder","tool_name":"Write","cwd":"/r","tool_input":{"file_path":"/r/.claude/agents/codex-reviewer.md","content":"codex-reviewer"}}' \
         '0|{"tool_name":"Edit","cwd":"/r","tool_input":{"file_path":"/r/.claude/agents/codex-reviewer.md"}}'; do
  want="${c%%|*}"; payload="${c#*|}"
  got=$(printf '%s' "$payload" | PATH="$NOPY" /bin/bash "$HOOK" 2>/dev/null; echo $?)
  if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL (no python3) want=$want got=$got :: $payload"; fi
done
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
