#!/usr/bin/env bash
set -euo pipefail

# Sign a released DMG into the Sparkle feed and publish it on GitHub Pages.
#
#   ./scripts/publish-appcast.sh <dmg> <short-version> <channel> <tag>
#
# The feed lives on the gh-pages branch of this repository, so the DMG stays a
# GitHub Release asset and only a few KB of signed XML is hosted.
#
# `zamokctl appcast` wraps Sparkle's generate_appcast: it pins the output name
# with -o, seeds history under that same name, and fails when the tool exits 0
# without writing a feed. Requires zamokctl >= 1.3.2; 1.3.1 reported success for
# a file it never created, which is why this once called generate_appcast direct.
#
# The private key comes from SPARKLE_PRIVATE_ED_KEY, or from the local keychain
# account when that is unset. Its public half must be the SUPublicEDKey baked
# into the app, or Sparkle silently rejects every update.

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DMG="${1:?usage: publish-appcast.sh DMG SHORT_VERSION CHANNEL TAG [NOTES.md]}"
readonly SHORT_VERSION="${2:?usage: publish-appcast.sh DMG SHORT_VERSION CHANNEL TAG [NOTES.md]}"
readonly CHANNEL="$(printf '%s' "${3:?usage: publish-appcast.sh DMG SHORT_VERSION CHANNEL TAG [NOTES.md]}" | tr '[:upper:]' '[:lower:]')"
readonly TAG="${4:?usage: publish-appcast.sh DMG SHORT_VERSION CHANNEL TAG [NOTES.md]}"
readonly NOTES_MD="${5:-}"
readonly REPOSITORY="${GITHUB_RELEASE_REPOSITORY:-bshk-app/ContainerStack}"
readonly PAGES_BRANCH="${APPCAST_BRANCH:-gh-pages}"
readonly KEYCHAIN_ACCOUNT="${SPARKLE_KEYCHAIN_ACCOUNT:-containerstack}"
readonly DOWNLOAD_URL_PREFIX="${APPCAST_DOWNLOAD_URL_PREFIX:-https://github.com/${REPOSITORY}/releases/download/${TAG}/}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }

command -v zamokctl >/dev/null 2>&1 || die "zamokctl is required"
# Both failure modes this pipeline depends on being fixed are SILENT in 1.3.1:
# appcast reported success without writing the feed, and cask metadata keys were
# dropped rather than rejected. A version check is the only way to notice.
require_zamokctl() {
    local want="1.3.2" have
    have="$(zamokctl --version 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$have" ]] || die "could not read zamokctl --version"
    [[ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -1)" == "$want" ]] \
        || die "zamokctl $have is too old; need >= $want. Run: brew upgrade bshk-app/tap/zamokctl"
}
require_zamokctl
[[ -f "$DMG" ]] || die "no DMG at $DMG"
# An unresolved reference would be signed as if it were a key, producing a
# signature no client can verify.
[[ "${SPARKLE_PRIVATE_ED_KEY:-}" != av://* ]] \
    || die "SPARKLE_PRIVATE_ED_KEY is still an av:// reference. Run: av env --profile sparkle -- $0 ..."

work="$(umask 077; mktemp -d)"
worktree="$work/pages"
cleanup() {
    if [[ -f "$work/ed-key" ]]; then rm -P "$work/ed-key" 2>/dev/null || rm -f "$work/ed-key"; fi
    git -C "$ROOT" worktree remove --force "$worktree" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

# zamokctl takes a key *file* -- it has no stdin form and no keychain lookup, so
# the key is materialised at 0600 and shredded on the way out.
if [[ -n "${SPARKLE_PRIVATE_ED_KEY:-}" ]]; then
    (umask 077; printf '%s' "$SPARKLE_PRIVATE_ED_KEY" > "$work/ed-key")
else
    generate_keys="$(
        for r in /opt/homebrew/Caskroom/sparkle /usr/local/Caskroom/sparkle; do
            [[ -d "$r" ]] || continue
            find "$r" -maxdepth 3 -name generate_keys -type f | sort -V | tail -1
        done | tail -1
    )"
    [[ -n "$generate_keys" ]] \
        || die "no SPARKLE_PRIVATE_ED_KEY and no generate_keys. Install: brew install --cask sparkle"
    (umask 077; "$generate_keys" --account "$KEYCHAIN_ACCOUNT" -x "$work/ed-key" >/dev/null) \
        || die "could not export the '$KEYCHAIN_ACCOUNT' Sparkle key from the keychain"
fi
[[ -s "$work/ed-key" ]] || die "the Sparkle private key is empty"

feed="appcast/${CHANNEL}.xml"
git -C "$ROOT" fetch --quiet origin "$PAGES_BRANCH" \
    || die "no $PAGES_BRANCH branch on origin; create it before releasing"
git -C "$ROOT" worktree add --quiet --detach "$worktree" "origin/$PAGES_BRANCH"
mkdir -p "$worktree/appcast"

# Sparkle shows the item's <description> as "What's new". generate_appcast reads
# it from an HTML file beside the archive, and the CHANGELOG is markdown, so
# without this step the panel is empty -- the prose the release PR exists to get
# right would reach nobody. Rendering goes through the GitHub markdown API
# because `gh` is already a requirement here and a second markdown converter is
# one more thing to install and keep honest.
notes_args=()
if [[ -n "$NOTES_MD" ]]; then
    [[ -s "$NOTES_MD" ]] || die "release notes file is empty: $NOTES_MD"
    command -v jq >/dev/null 2>&1 || die "jq is required to render release notes"
    jq -n --arg t "$(cat "$NOTES_MD")" '{mode:"gfm",text:$t}' \
        | gh api -X POST /markdown --input - > "$work/notes.html" \
        || die "could not render release notes to HTML"
    [[ -s "$work/notes.html" ]] || die "rendered release notes are empty"
    notes_args=(--release-notes "$work/notes.html")
else
    note "note: no release notes given — the update panel will be empty."
fi

note "== signing $(basename "$DMG") into $feed =="
zamokctl appcast \
    --input "$DMG" \
    --ed-key-file "$work/ed-key" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --appcast "$worktree/$feed" \
    "${notes_args[@]}" \
    --maximum-versions 10
[[ -f "$worktree/$feed" ]] || die "zamokctl appcast wrote no feed"
# An unsigned item is worse than no item: Sparkle would reject the update while
# the feed still looked healthy. That is what a key mismatch produces.
grep -q 'sparkle:edSignature=' "$worktree/$feed" \
    || die "the feed has no signature. The app's SUPublicEDKey does not match the signing key."

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
