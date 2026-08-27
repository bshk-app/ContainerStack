#!/usr/bin/env bash
# Gate comment bloat on ADDED lines only.
#
# A repo-wide rule was measured and rejected: comment blocks in this tree run
# p50 2, p75 3, p90 4, p95 7, p99 13 lines, and the longest ones carry the
# forensic detail worth keeping ("answered at 63s", "5.5 GB resident after 17
# hours"). Flagging them would demand churning exactly the comments that earn
# their length. So this only looks at what a change adds, and the threshold sits
# above p95 of what the repo already does.
#
# Agents get a hard stop, humans get a warning: measured over the last 60
# commits, a >=8 threshold would have blocked 4 of them, all four being
# hand-written forensics.
set -euo pipefail

readonly THRESHOLD="${MAX_ADDED_COMMENT_LINES:-8}"
readonly WARN_ONLY="${COMMENT_GROWTH_WARN_ONLY:-0}"

usage() {
    cat >&2 <<'EOF'
usage: check-comment-growth.sh [--staged | FILE...]

  --staged    inspect the staged diff (pre-commit hook)
  FILE...     inspect staged and unstaged changes to these files (agent hook)

env:
  MAX_ADDED_COMMENT_LINES   block at this run length (default 8)
  COMMENT_GROWTH_WARN_ONLY  1 reports without failing

exit: 0 nothing to say, 2 a run of added comment lines reached the threshold
EOF
}

# -U0 keeps only changed lines; the hunk header carries the new-file line number,
# so a finding can name the line a reviewer has to open.
scan() {
    awk -v threshold="$THRESHOLD" '
        function flush() {
            if (run >= threshold) {
                printf "%s:%d: %d added comment lines in one block (limit %d)\n", file, start, run, threshold
                found = 1
            }
            run = 0
        }
        /^\+\+\+ b\// { flush(); file = substr($0, 7); next }
        /^@@ / { flush(); split($3, hunk, ","); line = substr(hunk[1], 2) + 0; next }
        /^\+/ {
            if ($0 ~ /^\+[[:space:]]*\/\// && $0 !~ /swiftlint:/) {
                if (run == 0) { start = line }
                run++
            } else {
                flush()
            }
            line++
            next
        }
        { next }
        END { flush(); exit found ? 1 : 0 }
    '
}

main() {
    local diff=""
    case "${1:-}" in
        --staged)
            diff="$(git diff --cached -U0 -- '*.swift')"
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        "")
            usage
            exit 64
            ;;
        *)
            diff="$(git diff -U0 -- "$@"; git diff --cached -U0 -- "$@")"
            ;;
    esac

    local findings
    findings="$(printf '%s\n' "$diff" | scan)" || true
    [[ -n "$findings" ]] || exit 0

    printf '%s\n' "$findings" >&2
    printf '\nState the invariant, not the history: what breaks if this is wrong,\n' >&2
    printf 'and what was measured. Delete the narration.\n' >&2

    [[ "$WARN_ONLY" == "1" ]] && exit 0
    exit 2
}

main "$@"
