#!/usr/bin/env bash
# Claude Code PostToolUse hook: reads the tool payload on stdin and reports on
# the file the agent just wrote. PostToolUse runs after the edit, so exit 2 is
# feedback the agent has to act on, not a veto - the veto is the Stop hook.
#
# `jq` is used when present and not required: a hook that disappears on a
# machine without jq is worse than a hook with a plainer parser, and `set -e`
# would have turned a missing jq into a silent success.
set -euo pipefail

if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    ROOT="$CLAUDE_PROJECT_DIR"
else
    ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
readonly ROOT

payload="$(cat)"

file=""
if command -v jq >/dev/null 2>&1; then
    file="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || true)"
fi
if [[ -z "$file" ]]; then
    file="$(printf '%s' "$payload" |
        sed -n 's/.*"\(file_path\|path\)"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\2/p' |
        head -1)"
fi

case "$file" in
    "") exit 0 ;; # a payload shape this hook does not know
    *.swift) ;;
    *) exit 0 ;;
esac

# Hooks do not promise a working directory, and the payload may carry a
# repo-relative path.
case "$file" in
    /*) ;;
    *) file="$ROOT/$file" ;;
esac
[[ -f "$file" ]] || exit 0

cd "$ROOT"
exec "$ROOT/scripts/hooks/check-comment-growth.sh" "$file"
