#!/usr/bin/env bash
set -euo pipefail

# Repair the mutable distribution surfaces of an already-published immutable
# release from its exact hosted bytes. Never rebuild: Developer ID timestamps,
# notarization tickets and the DMG itself make a second package byte-different,
# so signing a rebuilt DMG into Sparkle would make every client reject the
# GitHub-hosted enclosure.
#
#   ./scripts/repair-release-distribution.sh TAG [stable|beta]

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TAG="${1:?usage: repair-release-distribution.sh TAG [CHANNEL]}"
readonly CHANNEL="$(printf '%s' "${2:-stable}" | tr '[:upper:]' '[:lower:]')"
readonly REPOSITORY="${GITHUB_RELEASE_REPOSITORY:-bshk-app/ContainerStack}"
readonly VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
readonly ASSET="ContainerStack-${VERSION}.dmg"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v shasum >/dev/null 2>&1 || die "shasum is required"

expected_tag="v${VERSION}"
[[ "$CHANNEL" == "stable" ]] || expected_tag="v${VERSION}-${CHANNEL}"
[[ "$TAG" == "$expected_tag" ]] \
    || die "tag $TAG does not match $expected_tag from VERSION and channel"

release_json="$(gh release view "$TAG" --repo "$REPOSITORY" --json isDraft,isImmutable,assets)"
[[ "$(jq -r '.isDraft' <<< "$release_json")" == "false" ]] \
    || die "$TAG is still a draft; run the normal Release workflow instead"
# Only an immutable release can promise the bytes measured here stay hosted. A
# mutable one can be re-uploaded after this check, which would leave Sparkle
# holding a signature for bytes nobody can download; that case belongs to the
# normal Release workflow, which can simply replace the asset.
[[ "$(jq -r '.isImmutable' <<< "$release_json")" == "true" ]] \
    || die "$TAG is mutable; re-run the Release workflow instead of repairing it"
remote_digest="$(
    jq -r --arg name "$ASSET" '.assets[] | select(.name == $name) | .digest // empty' \
        <<< "$release_json"
)"
[[ -n "$remote_digest" ]] || die "$TAG has no $ASSET"
jq -e '.assets[] | select(.name == "manifest.json")' <<< "$release_json" >/dev/null \
    || die "$TAG has no manifest.json; it cannot regenerate the cask without rebuilding"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
gh release download "$TAG" --repo "$REPOSITORY" \
    --pattern "$ASSET" --pattern manifest.json --dir "$work"

local_digest="sha256:$(shasum -a 256 "$work/$ASSET" | cut -d' ' -f1)"
[[ "$local_digest" == "$remote_digest" ]] \
    || die "downloaded DMG digest does not match GitHub's immutable asset digest"
[[ "$(jq -r '.artifact' "$work/manifest.json")" == "$ASSET" ]] \
    || die "manifest artifact does not match $ASSET"
[[ "sha256:$(jq -r '.sha256' "$work/manifest.json")" == "$remote_digest" ]] \
    || die "manifest SHA-256 does not match the immutable asset"
[[ "$(jq -r '.shortVersion' "$work/manifest.json")" == "$VERSION" ]] \
    || die "manifest version does not match VERSION"
[[ "$(jq -r '.notarized and .stapled' "$work/manifest.json")" == "true" ]] \
    || die "manifest does not record a notarized and stapled artifact"
xcrun stapler validate "$work/$ASSET" >/dev/null

notes="$work/release-notes.md"
"$ROOT/scripts/extract-release-notes.sh" "$VERSION" "$ROOT/CHANGELOG.md" > "$notes"
[[ -s "$notes" ]] || die "CHANGELOG has no release notes for $VERSION"

"$ROOT/scripts/publish-appcast.sh" "$work/$ASSET" "$VERSION" "$CHANNEL" "$TAG" "$notes"

if [[ "$CHANNEL" != "stable" ]]; then
    printf 'Prerelease channel %s: the stable cask is intentionally unchanged.\n' "$CHANNEL"
elif [[ -z "${TAP_GITHUB_TOKEN:-}" ]]; then
    printf 'TAP_GITHUB_TOKEN unset: feed repaired; cask skipped.\n' >&2
else
    "$ROOT/scripts/publish-cask.sh" "$work/$ASSET" "$VERSION" "$TAG"
fi

surfaces="feed"
[[ "$CHANNEL" == "stable" && -n "${TAP_GITHUB_TOKEN:-}" ]] && surfaces="feed and cask"
printf 'Repaired %s from immutable release %s (%s).\n' \
    "$surfaces" "$TAG" "$remote_digest"
