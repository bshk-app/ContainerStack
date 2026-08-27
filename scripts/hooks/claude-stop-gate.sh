#!/usr/bin/env bash
# Claude Code Stop hook: the blocking half of the comment gate.
#
# PostToolUse fires after an edit is already on disk, so it can only report.
# Stop is where a non-zero exit actually keeps the agent from finishing, so the
# whole working tree is checked here rather than one file.
#
# File lists live in the positional parameters: bash 3.2 (which is /bin/bash on
# macOS) has no arrays worth the ceremony, and word splitting on a path is how
# hooks break on the one repository with a space in a directory name.
set -euo pipefail

if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    ROOT="$CLAUDE_PROJECT_DIR"
else
    ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
readonly ROOT
cd "$ROOT"

# Drain stdin: the payload is unused, but a writer blocked on a full pipe is not
# a failure mode worth having.
cat >/dev/null || true

set --
while IFS= read -r -d '' path; do
    case "$path" in
        Sources/*.swift | Tests/*.swift) ;;
        *) continue ;;
    esac
    [[ -f "$path" ]] || continue
    set -- "$@" "$path"
done < <(
    git diff HEAD --name-only --diff-filter=ACMR -z
    git ls-files --others --exclude-standard -z -- 'Sources/*.swift' 'Tests/*.swift'
)

[[ $# -gt 0 ]] || exit 0

exec "$ROOT/scripts/hooks/check-comment-growth.sh" "$@"
