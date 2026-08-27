#!/usr/bin/env bash
# One Claude Code hook for both events that can carry the comment gate, because
# they need the same payload and the same checker.
#
#   PostToolUse  runs after the edit is on disk, so it can only report: exit 2
#                puts the finding in front of the agent.
#   Stop         is the only event where a non-zero exit actually refuses, so it
#                checks the whole working tree.
#
# `stop_hook_active` is the loop breaker: without it, refusing a stop makes
# Claude continue, reach the next stop, and be refused again by the same
# unchanged file, forever.
set -euo pipefail

if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    ROOT="$CLAUDE_PROJECT_DIR"
else
    ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
readonly ROOT
readonly CHECKER="$ROOT/scripts/hooks/check-new-comment-blocks.sh"

payload="$(cat)"

# jq when it is there, a plainer reader when it is not: a gate that disappears
# on a machine without jq is worse than one with a simpler parser.
field() {
    local name="$1" value=""
    if command -v jq >/dev/null 2>&1; then
        value="$(printf '%s' "$payload" | jq -r --arg n "$name" '.[$n] // .tool_input[$n] // empty' 2>/dev/null || true)"
    fi
    if [[ -z "$value" ]]; then
        value="$(printf '%s' "$payload" |
            sed -n "s/.*\"$name\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" |
            head -1)"
    fi
    printf '%s' "$value"
}

cd "$ROOT"

if [[ "$(field hook_event_name)" == "Stop" ]]; then
    [[ "$(field stop_hook_active)" == "true" ]] && exit 0
    exec "$CHECKER"
fi

file="$(field file_path)"
[[ -n "$file" && "$file" == *.swift ]] || exit 0
case "$file" in
    /*) ;;
    *) file="$ROOT/$file" ;;
esac
[[ -f "$file" ]] || exit 0

exec "$CHECKER" "$file"
