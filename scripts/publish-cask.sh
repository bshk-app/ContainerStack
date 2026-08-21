#!/usr/bin/env bash
set -euo pipefail

# Update the Homebrew cask for a published release.
#
#   TAP_GITHUB_TOKEN=... ./scripts/publish-cask.sh <dmg> <short-version>
#
# The cask is rendered here from Packaging/Homebrew/containerstack.rb.in rather
# than by `zamokctl cask`: that renderer's CaskMetadata has no field for
# `depends_on formula:` or `uninstall quit:`, and its livecheck emits
# `strategy :git`. It would silently ship a cask that no longer pulls Apple
# Container, which is the one dependency without which the app cannot run.
#
# The tap is a different repository, so a workflow's own GITHUB_TOKEN cannot
# write it. This is the only credential the pipeline cannot avoid.

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DMG="${1:?usage: publish-cask.sh DMG SHORT_VERSION}"
readonly SHORT_VERSION="${2:?usage: publish-cask.sh DMG SHORT_VERSION}"
readonly REPOSITORY="${GITHUB_RELEASE_REPOSITORY:-bshk-app/ContainerStack}"
readonly TAP="${HOMEBREW_TAP:-bshk-app/homebrew-tap}"
readonly TEMPLATE="${CASK_TEMPLATE:-$ROOT/Packaging/Homebrew/containerstack.rb.in}"
readonly CASK_PATH="Casks/containerstack.rb"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh is required"
command -v shasum >/dev/null 2>&1 || die "shasum is required"
[[ -f "$DMG" ]] || die "no DMG at $DMG"
[[ -f "$TEMPLATE" ]] || die "no cask template at $TEMPLATE"
[[ -n "${TAP_GITHUB_TOKEN:-}" ]] || die "TAP_GITHUB_TOKEN is required to write $TAP"

appcast="${APPCAST_URL:-https://${REPOSITORY%%/*}.github.io/${REPOSITORY##*/}/appcast/stable.xml}"
sha256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

# The version and sha256 are the release's own facts; everything else is the
# committed template, so a cask change is a reviewable diff rather than a
# server-side surprise.
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT
sed -e "s|@@VERSION@@|${SHORT_VERSION}|g" \
    -e "s|@@SHA256@@|${sha256}|g" \
    -e "s|@@REPOSITORY@@|${REPOSITORY}|g" \
    -e "s|@@APPCAST@@|${appcast}|g" \
    "$TEMPLATE" > "$rendered"

grep -q '@@' "$rendered" && die "unsubstituted placeholder left in the rendered cask"

existing_sha="$(GH_TOKEN="$TAP_GITHUB_TOKEN" gh api \
    "repos/${TAP}/contents/${CASK_PATH}" --jq '.sha' 2>/dev/null || true)"

args=(
    -X PUT "repos/${TAP}/contents/${CASK_PATH}"
    -f "message=cask containerstack ${SHORT_VERSION}"
    -f "content=$(base64 < "$rendered" | tr -d '\n')"
)
[[ -n "$existing_sha" ]] && args+=(-f "sha=${existing_sha}")

GH_TOKEN="$TAP_GITHUB_TOKEN" gh api "${args[@]}" --jq '.commit.sha' \
    | sed 's/^/cask commit: /'

printf 'Cask: %s %s (sha256 %s)\n' "$TAP" "$SHORT_VERSION" "${sha256:0:12}…"
