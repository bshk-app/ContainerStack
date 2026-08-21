#!/usr/bin/env bash
set -euo pipefail

# Sign a released DMG into the Sparkle feed and publish it on GitHub Pages.
#
#   ./scripts/publish-appcast.sh <dmg> <short-version> <channel> <tag>
#
# The feed lives on the gh-pages branch of this repository, so the DMG stays a
# GitHub Release asset and only a few KB of signed XML is hosted.
#
# The private key comes from SPARKLE_PRIVATE_ED_KEY (piped, never written to
# disk) or, when that is unset, from the local keychain account. Its public half
# must be the SUPublicEDKey baked into the app, or Sparkle silently rejects
# every update -- generate_appcast refuses to sign a mismatch rather than
# shipping an unsigned item.

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DMG="${1:?usage: publish-appcast.sh DMG SHORT_VERSION CHANNEL TAG}"
readonly SHORT_VERSION="${2:?usage: publish-appcast.sh DMG SHORT_VERSION CHANNEL TAG}"
readonly CHANNEL="$(printf '%s' "${3:?usage: publish-appcast.sh DMG SHORT_VERSION CHANNEL TAG}" | tr '[:upper:]' '[:lower:]')"
readonly TAG="${4:?usage: publish-appcast.sh DMG SHORT_VERSION CHANNEL TAG}"
readonly REPOSITORY="${GITHUB_RELEASE_REPOSITORY:-bshk-app/ContainerStack}"
readonly PAGES_BRANCH="${APPCAST_BRANCH:-gh-pages}"
readonly KEYCHAIN_ACCOUNT="${SPARKLE_KEYCHAIN_ACCOUNT:-containerstack}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }

[[ -f "$DMG" ]] || die "no DMG at $DMG"
# An unresolved reference would be signed as if it were a key, producing a
# signature no client can verify.
[[ "${SPARKLE_PRIVATE_ED_KEY:-}" != av://* ]] \
    || die "SPARKLE_PRIVATE_ED_KEY is still an av:// reference. Run: av env --profile sparkle -- $0 ..."

generate_appcast="${SPARKLE_BIN:-}"
if [[ -z "$generate_appcast" ]]; then
    # The Sparkle cask ships the tools; take the newest installed version. Only
    # search roots that exist: under `pipefail` a find over a missing directory
    # fails the whole pipeline, and with stderr hidden it fails silently.
    for root in /opt/homebrew/Caskroom/sparkle /usr/local/Caskroom/sparkle; do
        [[ -d "$root" ]] || continue
        generate_appcast="$(find "$root" -maxdepth 3 -name generate_appcast -type f | sort -V | tail -1)"
        [[ -n "$generate_appcast" ]] && break
    done
fi
[[ -n "$generate_appcast" && -x "$generate_appcast" ]] \
    || die "generate_appcast not found. Install it with: brew install --cask sparkle"

# generate_appcast reads every archive in one directory and rewrites the feed in
# place, so give it a directory holding just this release plus the current feed.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$DMG" "$work/"

feed="appcast/${CHANNEL}.xml"
worktree="$work/pages"
git -C "$ROOT" fetch --quiet origin "$PAGES_BRANCH" \
    || die "no $PAGES_BRANCH branch on origin; create it before releasing"
git -C "$ROOT" worktree add --quiet --detach "$worktree" "origin/$PAGES_BRANCH"
# The worktree is inside $work, so the EXIT trap would leave git's metadata
# pointing at a path that no longer exists.
trap 'git -C "$ROOT" worktree remove --force "$worktree" >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

[[ -f "$worktree/$feed" ]] && cp "$worktree/$feed" "$work/${CHANNEL}.xml"

note "== signing $(basename "$DMG") into $feed =="
appcast_args=(
    --download-url-prefix "https://github.com/${REPOSITORY}/releases/download/${TAG}/"
    --maximum-versions 10
    -o "$work/${CHANNEL}.xml"
    "$work"
)
if [[ -n "${SPARKLE_PRIVATE_ED_KEY:-}" ]]; then
    printf '%s' "$SPARKLE_PRIVATE_ED_KEY" \
        | "$generate_appcast" --ed-key-file - "${appcast_args[@]}"
else
    "$generate_appcast" --account "$KEYCHAIN_ACCOUNT" "${appcast_args[@]}"
fi

[[ -f "$work/${CHANNEL}.xml" ]] || die "generate_appcast wrote no feed"
# An unsigned item is worse than no item: Sparkle would reject the update and the
# feed would look healthy. This is what a key mismatch produces.
grep -q 'sparkle:edSignature=' "$work/${CHANNEL}.xml" \
    || die "the feed has no signature. The app's SUPublicEDKey does not match the signing key."

mkdir -p "$worktree/appcast"
cp "$work/${CHANNEL}.xml" "$worktree/$feed"
# Stage first: `git diff` reports nothing for an untracked path, so the very
# first feed would look unchanged and never be published.
git -C "$worktree" add "$feed"
if git -C "$worktree" diff --cached --quiet -- "$feed"; then
    note "feed already current; nothing to publish"
    exit 0
fi
# Unsigned on purpose: this commit is made by CI, which has no signing key, and
# the feed's integrity comes from the EdDSA signature inside the XML rather than
# from git. Requiring a signature here would make releases depend on whoever ran
# them having an unlocked agent.
git -C "$worktree" -c commit.gpgsign=false \
    -c "user.name=${GIT_AUTHOR_NAME:-release}" \
    -c "user.email=${GIT_AUTHOR_EMAIL:-release@users.noreply.github.com}" \
    commit --quiet -m "feed: ${CHANNEL} ${SHORT_VERSION}"
git -C "$worktree" push --quiet origin "HEAD:refs/heads/${PAGES_BRANCH}"

printf 'Feed: https://%s.github.io/%s/%s\n' \
    "${REPOSITORY%%/*}" "${REPOSITORY##*/}" "$feed"
