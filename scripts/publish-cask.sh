#!/usr/bin/env bash
set -euo pipefail

# Update the Homebrew cask for a published release.
#
#   TAP_GITHUB_TOKEN=... ./scripts/publish-cask.sh <dmg> <short-version> <tag>
#
# `zamokctl cask` renders and pushes it from Packaging/Homebrew/cask-containerstack.json
# and runs `brew audit` on the result. Requires zamokctl >= 1.8.0: 1.3.2 made metadata
# decoding strict (an unknown key used to drop silently -- a cask that installed but
# never pulled Apple Container); 1.8.0 added the `--set` flag this script now passes,
# without which the `#{container}` placeholder below fails the publish outright rather
# than shipping a cask with a literal `#{container}` in a depends_on line.
#
# The tap is a different repository, so a workflow's own GITHUB_TOKEN cannot
# write it. This is the only credential the pipeline cannot avoid.

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DMG="${1:?usage: publish-cask.sh DMG SHORT_VERSION TAG}"
readonly SHORT_VERSION="${2:?usage: publish-cask.sh DMG SHORT_VERSION TAG}"
readonly TAG="${3:?usage: publish-cask.sh DMG SHORT_VERSION TAG}"
readonly REPOSITORY="${GITHUB_RELEASE_REPOSITORY:-bshk-app/ContainerStack}"
readonly TAP="${HOMEBREW_TAP:-bshk-app/homebrew-tap}"
readonly METADATA="${CASK_METADATA:-$ROOT/Packaging/Homebrew/cask-containerstack.json}"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# The cask's dependsOnFormulae carries a `#{container}` placeholder rather than a literal
# version, so `zamokctl cask` needs `--set container=<version>` or it refuses to publish.
# Read that version from RuntimeProcessConfiguration.pinnedContainerVersion -- the same
# constant the app itself pins its runtime search paths to -- instead of hardcoding a fourth
# copy of it here.
readonly PIN_SOURCE="$ROOT/Sources/ContainerStackCore/RuntimeProcessConfiguration.swift"
container_version="$(grep -oE 'pinnedContainerVersion = "[0-9]+\.[0-9]+\.[0-9]+"' "$PIN_SOURCE" |
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
[[ -n "$container_version" ]] || die "could not read pinnedContainerVersion from $PIN_SOURCE"
readonly CONTAINER_VERSION="$container_version"

command -v zamokctl >/dev/null 2>&1 || die "zamokctl is required"
# 1.3.2 decodes metadata strictly instead of dropping unknown keys; 1.8.0 added
# --set, which this script relies on below.
zamokctl_version="$(zamokctl --version 2>/dev/null | tr -d '[:space:]')"
[[ -n "$zamokctl_version" ]] || die "could not read zamokctl --version"
[[ "$(printf '1.8.0\n%s\n' "$zamokctl_version" | sort -V | head -1)" == "1.8.0" ]] \
    || die "zamokctl $zamokctl_version is too old; need >= 1.8.0 (for --set). Run: brew upgrade bshk-app/tap/zamokctl"
[[ -f "$DMG" ]] || die "no DMG at $DMG"
[[ -f "$METADATA" ]] || die "no cask metadata at $METADATA"
[[ -n "${TAP_GITHUB_TOKEN:-}" ]] || die "TAP_GITHUB_TOKEN is required to write $TAP"

# zamokctl resolves the artifact beside the manifest, so hand it the manifest
# `zamokctl package` wrote for this DMG.
manifest="$(find "$(dirname "$DMG")" -maxdepth 1 -type f -name 'manifest.json' -print | head -1)"
[[ -n "$manifest" ]] || die "no manifest.json beside $DMG; zamokctl package writes one"

# --store url: the DMG is already a GitHub Release asset, so the cask points at
# it rather than uploading a second copy anywhere.
GITHUB_TOKEN="$TAP_GITHUB_TOKEN" zamokctl cask \
    --manifest "$manifest" \
    --store url \
    --url "https://github.com/${REPOSITORY}/releases/download/${TAG}/$(basename "$DMG")" \
    --tap "$TAP" \
    --metadata "$METADATA" \
    --set "container=$CONTAINER_VERSION"

printf 'Cask: %s containerstack %s\n' "$TAP" "$SHORT_VERSION"
