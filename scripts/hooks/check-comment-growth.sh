#!/usr/bin/env bash
# Gate comment bloat on lines a change ADDS.
#
# A repo-wide rule was measured and rejected: comment blocks here run p50 2,
# p75 3, p90 4, p95 7, p99 13 lines, and the longest carry the forensic detail
# worth keeping ("answered at 63s", "5.5 GB resident after 17 hours"). Flagging
# them would demand churning exactly the comments that earn their length.
#
# The unit is "new lines landing in one comment block of the resulting file",
# not "a run of added lines". Counting runs of added lines let a block evade the
# limit by growing on both sides of an unchanged comment line: with -U0 that is
# two hunks, so 5 + 5 added lines around one untouched line read as two runs of
# five and passed an eight-line bar while the file gained an eleven-line block.
#
# Written for bash 3.2, which is what /bin/bash on macOS still is: no mapfile,
# no associative arrays.
set -euo pipefail

readonly THRESHOLD="${MAX_ADDED_COMMENT_LINES:-8}"
readonly WARN_ONLY="${COMMENT_GROWTH_WARN_ONLY:-0}"

usage() {
    cat >&2 <<'EOF'
usage: check-comment-growth.sh [--staged | FILE...]

  --staged    inspect the staged snapshot (pre-commit, Stop hook)
  FILE...     inspect HEAD -> working tree, including untracked files (agent hook)

env:
  MAX_ADDED_COMMENT_LINES   report at this many new lines in one block (default 8)
  COMMENT_GROWTH_WARN_ONLY  1 reports without failing

exit: 0 nothing to say, 2 a comment block gained at least the threshold
EOF
}

# New-file line numbers of every added line. Whether a line is a comment is
# decided later, against the resulting file, so a `//` inside a multiline string
# literal cannot be counted here.
added_lines() {
    awk '
        /^diff --git / { in_header = 1; next }
        in_header && /^\+\+\+ / { in_header = 0; next }
        /^@@ / { in_header = 0; split($3, hunk, ","); line = substr(hunk[1], 2) + 0; next }
        /^\+/ { print line; line++; next }
        { next }
    '
}

# Group those line numbers by the comment block they land in. A block is a run
# of comment lines outside any multiline string literal; swiftlint directives are
# machinery, not prose, so they never count.
report_blocks() {
    local numbers="$1" content="$2" label="$3"
    awk -v threshold="$THRESHOLD" -v label="$label" '
        # `length` is an awk builtin, hence `total`.
        function flush() {
            if (gained >= threshold) {
                printf "%s:%d: %d of %d lines in this comment block are new (limit %d)\n",
                    label, start, gained, total, threshold
                found = 1
            }
            total = 0
            gained = 0
        }
        FNR == NR { added[$1 + 0] = 1; next }
        {
            quotes = gsub(/"""/, "\"\"\"")
            if (in_string) {
                flush()
                if (quotes > 0) { in_string = 0 }
                next
            }
            if (quotes > 0) {
                flush()
                if (quotes % 2 == 1) { in_string = 1 }
                next
            }
            if ($0 ~ /^[[:space:]]*\/\// && $0 !~ /swiftlint:/) {
                if (total == 0) { start = FNR }
                total++
                if (FNR in added) { gained++ }
                next
            }
            flush()
        }
        END { flush(); exit found ? 1 : 0 }
    ' "$numbers" "$content"
}

# HEAD -> working tree in one diff, so a partially staged block is counted once
# rather than twice. An untracked file has no HEAD side; diff it against nothing.
inspect_worktree_file() {
    local file="$1" numbers content status
    numbers="$(mktemp)"
    content="$(mktemp)"
    if git ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
        git diff HEAD -U0 -- "$file" | added_lines >"$numbers"
    else
        git diff --no-index -U0 /dev/null "$file" 2>/dev/null | added_lines >"$numbers"
    fi
    cat -- "$file" >"$content"
    status=0
    report_blocks "$numbers" "$content" "$file" || status=$?
    rm -f -- "$numbers" "$content"
    return "$status"
}

# The bytes a commit would actually contain: the staged blob, not the file on
# disk. Reading the working tree here would pass a staged violation whose fix is
# still unstaged.
inspect_staged_file() {
    local file="$1" numbers content status
    numbers="$(mktemp)"
    content="$(mktemp)"
    git diff --cached -U0 -- "$file" | added_lines >"$numbers"
    git show ":$file" >"$content" 2>/dev/null || : >"$content"
    status=0
    report_blocks "$numbers" "$content" "$file" || status=$?
    rm -f -- "$numbers" "$content"
    return "$status"
}

finish() {
    local found="$1"
    [[ "$found" -eq 1 ]] || exit 0
    printf '\nState the invariant, not the history: what breaks if this is wrong,\n' >&2
    printf 'and what was measured. Delete the narration.\n' >&2
    [[ "$WARN_ONLY" == "1" ]] && exit 0
    exit 2
}

main() {
    local found=0 file

    case "${1:-}" in
        -h | --help)
            usage
            exit 0
            ;;
        "")
            usage
            exit 64
            ;;
        --staged)
            while IFS= read -r -d '' file; do
                case "$file" in
                    Sources/*.swift | Tests/*.swift) ;;
                    *) continue ;;
                esac
                inspect_staged_file "$file" >&2 || found=1
            done < <(git diff --cached --name-only --diff-filter=ACMR -z)
            ;;
        *)
            for file in "$@"; do
                [[ -f "$file" ]] || continue
                inspect_worktree_file "$file" >&2 || found=1
            done
            ;;
    esac

    finish "$found"
}

main "$@"
