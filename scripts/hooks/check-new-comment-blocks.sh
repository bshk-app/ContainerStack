#!/usr/bin/env bash
# Report comment blocks a change introduces, and only those.
#
# Detection belongs to SwiftLint (.swiftlint-comments.yml): it knows what a
# comment token is, so `//` lines inside a `"""` literal are not prose, and the
# block bound lives in one declarative place. The only thing SwiftLint cannot do
# is restrict itself to what a change added - that filter is this script, and it
# is the whole reason the script exists.
#
# The added-line map comes from one rename-aware diff of the whole tree, not from
# a diff per path: restricting `git diff` to a rename's new path defeats rename
# detection, so git calls the file new and every line in it counts as added. A
# renamed file with an old long comment would then block the gate.
#
# Threshold note: MAX_NEW_COMMENT_LINES can only raise the bar. SwiftLint never
# offers a candidate block shorter than the bound in .swiftlint-comments.yml.
set -euo pipefail

readonly THRESHOLD="${MAX_NEW_COMMENT_LINES:-8}"
readonly WARN_ONLY="${COMMENT_BLOCK_WARN_ONLY:-0}"
ROOT="$(git rev-parse --show-toplevel)"
readonly ROOT
readonly CONFIG="$ROOT/.swiftlint-comments.yml"

# What "added" is measured against. The hook wants the working tree, so HEAD is the
# default; CI has nothing uncommitted and must compare the branch against its base
# instead, or the gate inspects an empty diff and passes without checking anything.
# The merge base, not the ref itself: commits that landed on the base after this
# branch started did not add these lines.
DIFF_BASE="${COMMENT_BLOCK_DIFF_BASE:-HEAD}"
if [[ "$DIFF_BASE" != "HEAD" ]]; then
    DIFF_BASE="$(git merge-base "$DIFF_BASE" HEAD)" || {
        printf 'check-new-comment-blocks: no merge base with %s\n' "$COMMENT_BLOCK_DIFF_BASE" >&2
        exit 1
    }
fi
readonly DIFF_BASE

usage() {
    cat >&2 <<'EOF'
usage: check-new-comment-blocks.sh [FILE...]

  no arguments   every Swift file this tree touched since the diff base, untracked
                 included
  FILE...        only these files

env:
  MAX_NEW_COMMENT_LINES     new lines in one block before it reports (default 8,
                            cannot go below the bound in .swiftlint-comments.yml)
  COMMENT_BLOCK_WARN_ONLY   1 reports without failing
  COMMENT_BLOCK_DIFF_BASE   ref the added lines are measured against (default HEAD,
                            i.e. the working tree; CI passes origin/main)

exit: 0 nothing to say, 1 the gate could not run, 2 a block gained the threshold
EOF
}

changed_files() {
    git diff "$DIFF_BASE" --name-only --diff-filter=ACMR -z
    git ls-files --others --exclude-standard -z -- 'Sources/*.swift' 'Tests/*.swift'
}

# `path<TAB>line` for every line this tree adds, from one rename-aware diff plus
# the untracked files, whose every line is new.
#
# Tab-separated and matched by exact string later, not `path:line` matched by a
# regex: a colon is legal in a POSIX filename and would split the record, and a
# path with `[` in it would turn a `grep` prefix into a character class.
# `core.quotePath=false` keeps git from C-quoting non-ASCII paths into a shape
# the parser would read as empty.
added_map() {
    git -c core.quotePath=false diff "$DIFF_BASE" -U0 --find-renames | awk '
        /^diff --git / { path = ""; in_header = 1; next }
        in_header && /^\+\+\+ / {
            in_header = 0
            path = ($0 ~ /^\+\+\+ b\//) ? substr($0, 7) : ""
            next
        }
        /^@@ / { in_header = 0; split($3, hunk, ","); line = substr(hunk[1], 2) + 0; next }
        /^\+/ { if (path != "") { print path "\t" line; line++ } }
    '

    local file
    while IFS= read -r -d '' file; do
        case "$file" in
            Sources/*.swift | Tests/*.swift) ;;
            *) continue ;;
        esac
        [[ -f "$file" ]] || continue
        # `< "$file"` rather than a filename argument: BSD awk reads `--` as a
        # file to open, so the usual end-of-options guard breaks it.
        awk -v path="$file" '{ print path "\t" FNR }' <"$file"
    done < <(git ls-files --others --exclude-standard -z -- 'Sources/*.swift' 'Tests/*.swift')
}

# The added-line map is keyed by repository-relative paths, so an argument has to
# arrive in the same shape. The hook passes an absolute path, and on macOS the
# repository root reads as `/private/tmp/...` through git while a caller's `$PWD`
# says `/tmp/...`, so both sides are resolved before comparing.
repo_relative() {
    local path="$1" abs dir base root_physical prefix
    case "$path" in
        /*) abs="$path" ;;
        *) abs="$PWD/$path" ;;
    esac
    dir="$(cd -- "$(dirname -- "$abs")" 2>/dev/null && pwd -P)" || {
        printf '%s' "$path"
        return
    }
    base="$(basename -- "$abs")"
    root_physical="$(cd -- "$ROOT" && pwd -P)"
    prefix="$root_physical/"
    # The prefix is a variable for readability; `${dir#"$root_physical"/}` parses
    # fine in bash 3.2 (checked). What that shell does mis-parse is an apostrophe
    # in a comment inside a command substitution - see the note further down.
    if [[ "$dir" == "$root_physical" ]]; then
        printf '%s' "$base"
    elif [[ "$dir" == "$prefix"* ]]; then
        printf '%s/%s' "${dir#"$prefix"}" "$base"
    else
        printf '%s' "$path"
    fi
}

# The detector has to be proven alive, not assumed: an invalid custom rule makes
# SwiftLint warn and fall back to its default rules, exit 0, and report nothing
# our rule would have caught. So a canary block it must flag is the cheapest
# proof - and the canary ends without a trailing newline, which exercises the
# end-of-file branch of the regex at the same time.
#
# The rule id has to appear in the output: any other finding would mean the
# fallback rules ran, which is precisely the failure being ruled out.
detector_alive() {
    local dir canary alive=1
    dir="$(mktemp -d)" || return 1
    canary="$dir/Canary.swift"
    {
        printf 'let canary = 1\n'
        for _ in 1 2 3 4 5 6 7 8 9; do printf '// canary\n'; done
        printf '// canary'
    } >"$canary" || alive=0

    if [[ "$alive" -eq 1 ]]; then
        swiftlint lint --quiet --no-cache --config "$CONFIG" -- "$canary" 2>/dev/null |
            grep -q 'long_comment_block' || alive=0
    fi
    rm -rf -- "$dir"
    [[ "$alive" -eq 1 ]]
}

# SwiftLint names a candidate block by its first line; how much of that block is
# new is counted here, by walking it in the file. Filtering on the start line
# alone was not enough: narration appended to an existing block merges with it,
# so the block grows by eleven lines while its start never moves.
gate_file() {
    local file="$1" map="$2" lines status output
    lines="$(mktemp)"
    # Exact field compare, so a colon or a regex metacharacter in the path cannot
    # match the wrong record or none at all.
    awk -F'\t' -v file="$file" '$1 == file { print $2 }' "$map" >"$lines" || true

    output="$(mktemp)"
    status=0
    swiftlint lint --quiet --no-cache --config "$CONFIG" -- "$file" >"$output" 2>"$output.err" || status=$?

    # A broken config, a SourceKit failure or an unreadable file must not read as
    # "nothing to report": the gate is only meaningful when its detector ran.
    if [[ "$status" -ne 0 ]]; then
        printf 'check-new-comment-blocks: swiftlint failed on %s (exit %d)\n' "$file" "$status" >&2
        sed 's/^/  /' "$output.err" >&2 || true
        rm -f -- "$lines" "$output" "$output.err"
        return 3
    fi

    local findings
    findings="$(
        # The line number comes from the trailing `:line:column:` of the location
        # rather than a field index, because the rule message itself contains
        # colons and counting fields from either end lands in prose. And no
        # apostrophes in here: bash 3.2 tracks quotes through comments inside a
        # command substitution and stops parsing at the first stray one.
        sed -n 's/^.*:\([0-9][0-9]*\):[0-9][0-9]*: .*$/\1/p' "$output" |
            awk -v file="$file" -v lines="$lines" -v threshold="$THRESHOLD" '
                BEGIN {
                    while ((getline line < lines) > 0) { introduced[line + 0] = 1 }
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
            '
    )"
    rm -f -- "$lines" "$output" "$output.err"

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

    if ! detector_alive; then
        printf 'check-new-comment-blocks: the rule in %s did not fire on a canary block;\n' "$CONFIG" >&2
        printf '  the config is broken or SwiftLint cannot read it, so nothing is being checked\n' >&2
        exit 1
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

    local map found=0 broken=0 file status
    map="$(mktemp)"
    added_map >"$map"

    for file in "$@"; do
        file="$(repo_relative "$file")"
        # An absolute path here means repo_relative could not place it inside the
        # tree. Judging it would compare against a map keyed relative and report
        # a clean bill for a file nobody checked, so say so instead.
        case "$file" in
            /*)
                printf 'check-new-comment-blocks: %s is outside %s, skipped\n' "$file" "$ROOT" >&2
                continue
                ;;
        esac
        if [[ ! -f "$file" ]]; then
            printf 'check-new-comment-blocks: %s does not exist, skipped\n' "$file" >&2
            continue
        fi
        status=0
        gate_file "$file" "$map" >&2 || status=$?
        case "$status" in
            1) found=1 ;;
            3) broken=1 ;;
        esac
    done
    rm -f -- "$map"

    [[ "$broken" -eq 0 ]] || exit 1
    [[ "$found" -eq 1 ]] || exit 0
    [[ "$WARN_ONLY" == "1" ]] && exit 0
    exit 2
}

main "$@"
