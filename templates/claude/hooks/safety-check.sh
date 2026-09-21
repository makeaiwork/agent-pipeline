#!/bin/bash
# Safety hook: blocks dangerous operations before they run
# Invoked as PreToolUse for Bash commands
# exit 0 = allow, exit 2 = block
#
# What is caught:
#   - access to protected files (.env*, .git/config, docker-compose.prod, keys);
#   - any `git push` — including the workaround forms `git -C . push`, `git -c k=v push`,
#     `git --git-dir=/x push` (only options are allowed between `git` and the subcommand);
#   - `git reset … --hard` with any flags in between (`-q`, `--keep`, `-C .`);
#   - all of `git clean` (not just `-fd`);
#   - `git checkout [ref] -- <file>` (working-tree rollback);
#   - `rm` with any `-r`/`-f` in any form: `-rf`, `-fr`, `-Rf`, `-r`, `-f`, `-v -rf`,
#     `--recursive`, `--force`; including `/bin/rm`, `sudo rm`, `cd x && rm`,
#     `xargs rm`, `find … -exec rm`;
#   - drop table / mkfs / dd / fork bomb / chmod -R 777 / format / >/dev/disk /
#     curl|sh / wget|sh.
#
# Known trade-off: the whole command line is checked, not just the executable
# tokens, so literals inside strings are blocked too — for example
# `echo "rm -rf x"` or `git commit -m "… rm -rf …"`. This is deliberate: the hook
# prefers a false positive to letting a dangerous command through. Equally deliberately
# blocked are `npm rm -f pkg` and `git rm -r dir` — their form is indistinguishable from `rm -rf`
# without parsing the command line.

INPUT=$(cat)
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input // ""' 2>/dev/null)

# If parsing failed — let it through
if [ -z "$TOOL_INPUT" ] || [ "$TOOL_INPUT" = "null" ]; then
  exit 0
fi

# === Exception: the heredoc prompt body of the Codex wrappers ===
# `bash .claude/scripts/codex-review.sh run … <<'CODEX_PROMPT_END' … CODEX_PROMPT_END` (review) and
# `bash .claude/scripts/codex-image.sh … <<'CODEX_PROMPT_END' … CODEX_PROMPT_END` (image) pass
# text to a read-only Codex; the marker is quoted — the shell neither executes nor expands the body.
# Only the body (between the markers) is removed from the check; the command itself and everything after
# the closing marker are checked as usual. The condition is narrow: the first line is exactly a wrapper
# call (no `;`, `&&`, `|` before the marker), otherwise the exception does not apply.
HEREDOC_OPEN="<<'CODEX_PROMPT_END'"
if printf '%s\n' "$TOOL_INPUT" | head -1 | grep -qE "^bash \.claude/scripts/(codex-review\.sh run|codex-image\.sh) [^;&|]*${HEREDOC_OPEN}\$"; then
  TOOL_INPUT=$(printf '%s\n' "$TOOL_INPUT" | awk -v open="$HEREDOC_OPEN" '
    BEGIN { skip = 0 }
    skip == 0 && length($0) >= length(open) && substr($0, length($0) - length(open) + 1) == open { print; skip = 1; next }
    skip == 1 && $0 == "CODEX_PROMPT_END" { skip = 0; next }
    skip == 0 { print }')
fi

# === Protected files ===
# Matched as path tokens (no regex interpretation): ".env" catches ".env",
# "./.env", "server/.env", "--env-file=.env", ".env.local", but NOT "process.env.X",
# "printenv" or "environment".
# === PROJECT-SPECIFIC (agent-pipeline init) ===
PROTECTED_FILES=(
  # {{PROTECTED_FILES}}        # ← init adds the prod configs it found (docker-compose.prod*, Dockerfile.prod, keys)
  ".env"
  ".env.local"
  ".env.production"
  ".git/config"
  ".git/HEAD"
  "docker-compose.prod"
  "Dockerfile.prod"
  "credentials"
  "secrets"
  ".ssh/"
  ".aws/"
  "id_rsa"
)
# === /PROJECT-SPECIFIC ===

for pattern in "${PROTECTED_FILES[@]}"; do
  # escape ERE special characters in the literal
  lit=$(printf '%s' "$pattern" | sed 's/[][\.*^$+?(){}|\\/]/\\&/g')
  # directory (`.ssh/`, `.aws/`): all of its contents are protected — there is no right boundary
  case "$pattern" in */) tail='' ;; *) tail='([^A-Za-z0-9_-]|$)' ;; esac
  if printf '%s' "$TOOL_INPUT" | grep -qiE -- "(^|[^A-Za-z0-9_.-])${lit}${tail}"; then
    echo "BLOCKED: Attempting to access protected resource: $pattern. This file is in the protected list." >&2
    exit 2
  fi
done

# === Destructive commands: fixed strings (grep -F, no regex) ===
DANGEROUS_FIXED=(
  "drop table"
  "drop database"
  "truncate table"
  "mkfs"
  "dd if="
  ":(){ :|:& };:"
  "chmod -R 777"
)

for pattern in "${DANGEROUS_FIXED[@]}"; do
  if printf '%s' "$TOOL_INPUT" | grep -qiF -- "$pattern"; then
    echo "BLOCKED: Dangerous command detected: matches pattern '$pattern'. This operation is not allowed in autonomous mode." >&2
    exit 2
  fi
done

# === Destructive commands: regular expressions (ERE) ===
# BSD grep on macOS: POSIX classes only ([[:space:]]), no \s.
#
# GIT — the prefix "git with any options before the subcommand". Between `git` and the subcommand
# only options are allowed (`-C .`, `-c k=v`, `--git-dir=/x`), so
# `git commit -m "do not push yet"` does NOT fall under the push rule.
# `git` by absolute path too (`/usr/bin/git push`): `…/` is allowed before the name.
GIT='(^|[^A-Za-z0-9_.-])([^[:space:];&|]*/)?git([[:space:]]+-[^[:space:]]*([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+'

DANGEROUS_REGEX=(
  # git push in any form (project policy: permissions.deny "Bash(git push *)")
  "${GIT}"'push([^A-Za-z0-9_-]|$)'
  # git reset --hard with any flags in between; --soft and `reset HEAD file` are not caught
  "${GIT}"'reset([[:space:]]+[^[:space:];&|]+)*[[:space:]]+--hard([^A-Za-z0-9_-]|$)'
  # all of git clean
  "${GIT}"'clean([^A-Za-z0-9_-]|$)'
  # git checkout [ref] -- <file>; `checkout -b x` and `checkout --detach` are not caught
  "${GIT}"'checkout([[:space:]]+[^[:space:];&|]+)*[[:space:]]+--([^A-Za-z0-9_-]|$)'
  # rm with -r/-f in any form; rmdir, `rm file`, `npm rm pkg`, `git rm --cached` — no
  # -r/-R/-f at any position in the flag group: -rf, -rv, -rfv, -rI, -Rf, -vr
  '(^|/|[[:space:]])rm([[:space:]]+-[^[:space:]]+)*[[:space:]]+(-[A-Za-z]*[rfR][A-Za-z]*|--recursive|--force)([[:space:]]|$)'
  '(^|[;&|[:space:]])format[[:space:]]'
  '>[[:space:]]*/dev/(r?disk|sd|nvme|hd)'
  'curl.*\|[[:space:]]*(ba)?sh([[:space:]]|$)'
  'wget.*\|[[:space:]]*(ba)?sh([[:space:]]|$)'
)

for pattern in "${DANGEROUS_REGEX[@]}"; do
  if printf '%s' "$TOOL_INPUT" | grep -qiE -- "$pattern"; then
    echo "BLOCKED: Dangerous command detected: matches pattern '$pattern'. This operation is not allowed in autonomous mode." >&2
    exit 2
  fi
done

# All clear — allow
exit 0
