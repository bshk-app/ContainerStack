#!/usr/bin/env bash
# Regression pin for the case that motivated lowering the candidate bound in
# .swiftlint-comments.yml from 8 lines to 1: a short, wrong comment that the
# old floor could never have surfaced no matter how MAX_NEW_COMMENT_LINES was
# set (#78's connectPollFailure doc comment, 4 lines, claimed EINTR "spent no
# time at all" -- see PR #91's follow-up commit for why that was false).
#
# Runs the real script and config against a scratch repo, not this project's
# own tree: a check against this tree would stop meaning anything the day
# every comment here happens to be long enough to dodge a coincidental floor.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
readonly ROOT

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

git init -q "$scratch"
cp "$ROOT/.swiftlint-comments.yml" "$scratch/"
mkdir -p "$scratch/Sources"
git -C "$scratch" -c user.email=ci@example.com -c user.name=ci commit -q --allow-empty -m base

# The exact shape of the offending comment: four lines, plausible, wrong. Any
# comment length above 0 has to trigger under the current floor.
cat >"$scratch/Sources/Short.swift" <<'EOF'
// `poll` returning 0 spent the whole deadline: a real timeout, worth reporting as one. Any
// negative result is a syscall failure that spent no time at all -- EINTR among them, which is
// why it was worth splitting out (#78) -- so every negative result keeps its own errno instead
// of being folded into a timeout it never was.
enum Short {}
EOF

cd "$scratch"
git add Sources/Short.swift

status=0
COMMENT_BLOCK_DIFF_BASE=HEAD "$ROOT/scripts/hooks/check-new-comment-blocks.sh" Sources/Short.swift || status=$?

if [[ "$status" -ne 2 ]]; then
    printf 'test-comment-gate: expected exit 2 (a short new comment flagged), got %d\n' "$status" >&2
    exit 1
fi

printf 'test-comment-gate: a 4-line new comment is flagged as expected\n'
