#!/usr/bin/env bash
# Coverage matrix for agent-sync-check.sh: "expected exit|JSON hook_input".
# Run: bash .claude/hooks/agent-sync-check.test.sh
HOOK="$(dirname "$0")/agent-sync-check.sh"
# Fixture of "pipeline" agents: the hook reads the names from the agents directory.
FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT
for a in task-runner coder tester reviewer codex-reviewer review-consolidator committer researcher architect; do : > "$FIX/$a.md"; done
export AGENT_PIPELINE_AGENTS_DIR="$FIX"
pass=0; fail=0
while IFS='|' read -r want payload; do
  [ -z "$want" ] && continue
  case "$want" in \#*) continue;; esac
  got=$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null; echo $?)
  if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL want=$want got=$got :: $payload"; fi
done <<'CASES'
# --- block (2): pipeline agent not synchronous ---
2|{"tool_name":"Agent","tool_input":{"subagent_type":"coder","run_in_background":true}}
2|{"tool_name":"Agent","tool_input":{"subagent_type":"coder"}}
2|{"tool_name":"Task","tool_input":{"subagent_type":"task-runner","prompt":"x"}}
2|{"tool_name":"Agent","tool_input":{"subagent_type":"tester","run_in_background":"false"}}
2|{"tool_name":"Agent","tool_input":{"subagent_type":"codex-reviewer","run_in_background":null}}
2|{"tool_name":"Agent","tool_input":{"subagent_type":"committer","isolation":"worktree"}}
2|{"tool_name":"Agent","tool_input":{"subagent_type":"task-runner","run_in_background":1}}
# --- pass (0): synchronous, non-pipeline agent, garbage ---
0|{"tool_name":"Agent","tool_input":{"subagent_type":"coder","run_in_background":false}}
0|{"tool_name":"Agent","tool_input":{"subagent_type":"task-runner","run_in_background":false,"isolation":"worktree"}}
0|{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","run_in_background":true}}
0|{"tool_name":"Agent","tool_input":{"subagent_type":"Explore"}}
0|{"tool_name":"Agent","tool_input":{"subagent_type":"coder-x","run_in_background":true}}
0|{"tool_name":"Agent","tool_input":{"prompt":"no subagent_type"}}
0|{"tool_name":"Agent","tool_input":{"subagent_type":123,"run_in_background":true}}
0|{"tool_name":"Agent","tool_input":"not an object"}
0|{"tool_name":"Agent"}
0|{}
0|not json at all
0|[1,2,3]
CASES
# no agents directory → the hook blocks nothing
got=$(printf '%s' '{"tool_name":"Agent","tool_input":{"subagent_type":"coder","run_in_background":true}}' | AGENT_PIPELINE_AGENTS_DIR=/nonexistent bash "$HOOK" 2>/dev/null; echo $?)
if [ "$got" = "0" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL want=0 got=$got :: no agents dir"; fi
echo "$pass/$((pass+fail)) ok"
[ "$fail" -eq 0 ] && [ "$pass" -ge 20 ]
