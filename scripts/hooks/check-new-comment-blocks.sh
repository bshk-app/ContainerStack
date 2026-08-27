#!/usr/bin/env bash
# Report comment blocks a change introduces, and only those.
#
# Detection belongs to SwiftLint (.swiftlint-comments.yml): it knows what a
# comment token is, so `//` lines inside a `"""` literal are not prose, and the
# block bound lives in one declarative place. The only thing SwiftLint cannot do
# is restrict itself to what a change added - that filter is this script, and it
# is the whole reason the script exists.
#
# Filtering on the reported line, which is the block's first line, is what keeps
# the existing corpus quiet: a wholly new block starts on an added line, while a
# line added inside a block that was already long does not move its start.
#
# One file per SwiftLint run, matched on line numbers alone: `git` reports
# `/private/tmp/...` where SwiftLint prints `/tmp/...` on macOS, and comparing
# paths across that symlink is a bug waiting for a Tuesday.
set -euo pipefail

readonly THRESHOLD="${MAX_NEW_COMMENT_LINES:-8}"
readonly WARN_ONLY="${COMMENT_BLOCK_WARN_ONLY:-0}"
ROOT="$(git rev-parse --show-toplevel)"
readonly ROOT
readonly CONFIG="$ROOT/.swiftlint-comments.yml"

usage() {
    cat >&2 <<'EOF'
usage: check-new-comment-blocks.sh [FILE...]

  no arguments   every Swift file this tree touched since HEAD, untracked included
  FILE...        only these files

env:
  MAX_NEW_COMMENT_LINES     new lines in one block before it reports (default 8)
  COMMENT_BLOCK_WARN_ONLY  1 reports without failing

exit: 0 nothing to say, 2 a comment block gained at least the threshold
EOF
}

changed_files() {
    git diff HEAD --name-only --diff-filter=ACMR -z
    git ls-files --others --exclude-standard -z -- 'Sources/*.swift' 'Tests/*.swift'
}

# Line numbers this change adds to one file. An untracked file has no HEAD side,
# so every line of it is new.
added_lines() {
    local file="$1"
    if git ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
        git diff HEAD -U0 -- "$file"
    else
        git diff --no-index -U0 /dev/null "$file" 2>/dev/null || true
    fi | awk '
        /^@@ / { split($3, hunk, ","); line = substr(hunk[1], 2) + 0; next }
        /^\+\+\+ / { next }
        /^\+/ { print line; line++ }
    '
}

# SwiftLint names a candidate block by its first line; how much of that block is
# new is counted here, by walking it in the file. Filtering on the start line
# alone was not enough: narration appended to an existing block merges with it,
# so the block grows by eleven lines while its start never moves.
gate_file() {
    local file="$1" added findings
    added="$(mktemp)"
    added_lines "$file" >"$added"

    findings="$(
        swiftlint lint --quiet --no-cache --config "$CONFIG" -- "$file" 2>/dev/null |
            awk -F: '{ print $2 }' |
            awk -v file="$file" -v added="$added" -v threshold="$THRESHOLD" '
                BEGIN {
                    while ((getline line < added) > 0) { introduced[line] = 1 }
                    while ((getline line < file) > 0) { text[++last] = line }
                }
                {
                    start = $1 + 0
                    gained = 0
                    total = 0
                    for (n = start; n <= last && text[n] ~ /^[ \t]*\/\//; n++) {
                        # Directives are machinery, not prose.
                        if (text[n] ~ /swiftlint:/) { continue }
                        total++
                        if (n in introduced) { gained++ }
                    }
                    if (gained >= threshold) {
                        printf "%s:%d: %d of %d lines in this comment block are new (limit %d)\n",
                            file, start, gained, total, threshold
                    }
                }
            ' || true
    )"
    rm -f -- "$added"

    [[ -n "$findings" ]] || return 0
    printf '%s\n' "$findings"
    return 1
}

main() {
    case "${1:-}" in
        -h | --help)
            usage
            exit 0
            ;;
    esac

    # Detection lives in SwiftLint, so without it there is no gate. Say so:
    # a check that disappears quietly is worse than one that is absent loudly.
    if ! command -v swiftlint >/dev/null 2>&1; then
        printf 'check-new-comment-blocks: swiftlint not installed, comment gate skipped (brew install swiftlint)\n' >&2
        exit 0
    fi

    cd "$ROOT"

    if [[ $# -eq 0 ]]; then
        while IFS= read -r -d '' file; do
            case "$file" in
                Sources/*.swift | Tests/*.swift) ;;
                *) continue ;;
            esac
            [[ -f "$file" ]] || continue
            set -- "$@" "$file"
        done < <(changed_files)
    fi

    [[ $# -gt 0 ]] || exit 0

    local found=0 file
    for file in "$@"; do
        [[ -f "$file" ]] || continue
        gate_file "$file" >&2 || found=1
    done

    [[ "$found" -eq 1 ]] || exit 0
    [[ "$WARN_ONLY" == "1" ]] && exit 0
    exit 2
}

main "$@"
