#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
readonly ROOT

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

git init -q "$scratch"
cp "$ROOT/.swiftlint-comments.yml" "$scratch/"
mkdir -p "$scratch/Sources"
git -C "$scratch" -c user.email=ci@example.com -c user.name=ci -c commit.gpgsign=false \
    commit -q --allow-empty -m base

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
