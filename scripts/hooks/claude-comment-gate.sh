#!/usr/bin/env bash
# Claude Code hook for the comment gate, one script for both events it applies
# to. The event comes from the argument the hook is registered with, not from the
# payload: a payload missing `hook_event_name` used to fall through as if it were
# an edit, which silently disabled the Stop gate.
#
#   --edit  PostToolUse. Runs after the edit is on disk, so it can only report;
#           exit 2 puts the finding in front of the agent.
#   --stop  Stop. The only event where a non-zero exit actually refuses, so it
#           checks the whole tree and honours `stop_hook_active` - without that
#           flag, refusing a stop loops the agent against the same file forever.
#
# `jq` is used when present and never required. The fallback reader is not a JSON
# parser, so when it cannot produce a usable path the gate widens to the whole
# changed set rather than skipping: a gate that says nothing because it could not
# read its input is the failure this file exists to avoid.
set -euo pipefail

if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    ROOT="$CLAUDE_PROJECT_DIR"
else
    ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
readonly ROOT
readonly CHECKER="$ROOT/scripts/hooks/check-new-comment-blocks.sh"

readonly MODE="${1:-}"
case "$MODE" in
    --edit | --stop) ;;
    *)
        printf 'usage: claude-comment-gate.sh --edit | --stop  (payload on stdin)\n' >&2
        exit 64
        ;;
esac

payload="$(cat)"

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

if [[ "$MODE" == "--stop" ]]; then
    active="$(field stop_hook_active)"
    [[ "$active" == "true" ]] && exit 0

    # A refusal is only safe when this payload was actually read. If nothing at
    # all parses out of it, refusing would repeat on the next stop against the
    # same unchanged file - the loop `stop_hook_active` exists to prevent. A
    # payload that parses but omits the flag is a first stop, and does get gated.
    if [[ -z "$active" ]]; then
        readable="$(field hook_event_name)$(field session_id)$(field transcript_path)$(field cwd)"
        if [[ -z "$readable" ]]; then
            printf 'claude-comment-gate: unreadable stop payload, letting the stop through\n' >&2
            exit 0
        fi
    fi

    exec "$CHECKER"
fi

file="$(field file_path)"
case "$file" in
    "") exec "$CHECKER" ;; # unreadable payload: check everything rather than nothing
    *.swift) ;;
    *) exit 0 ;;
esac

case "$file" in
    /*) ;;
    *) file="$ROOT/$file" ;;
esac
[[ -f "$file" ]] || exec "$CHECKER"

exec "$CHECKER" "$file"
