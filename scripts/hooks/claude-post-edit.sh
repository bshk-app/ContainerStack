#!/usr/bin/env bash
# Claude Code PostToolUse hook: reads the tool payload on stdin and gates the
# file the agent just wrote. Kept separate from check-comment-growth.sh so the
# checker stays usable by hand and by the pre-commit hook.
set -euo pipefail

readonly ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

payload="$(cat)"
file="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.path // empty')"

# Not a Swift edit, or a payload shape this hook does not know: say nothing.
[[ -n "$file" && "$file" == *.swift ]] || exit 0
[[ -f "$file" ]] || exit 0

exec "$ROOT/scripts/hooks/check-comment-growth.sh" "$file"
