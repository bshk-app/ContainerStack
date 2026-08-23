#!/usr/bin/env bash
set -euo pipefail

# Update the Homebrew cask for a published release.
#
#   TAP_GITHUB_TOKEN=... ./scripts/publish-cask.sh <dmg> <short-version> <tag>
#
# `zamokctl cask` renders and pushes it from Packaging/Homebrew/cask-containerstack.json
# and runs `brew audit` on the result. Requires zamokctl >= 1.3.2: earlier
# renderers had no field for `depends_on formula:` or `uninstall quit:` and always
# emitted `strategy :git`, and JSONDecoder dropped those keys silently -- a cask
# that installs but never pulls Apple Container. 1.3.2 decodes strictly, so an
# unknown key is now a loud error.
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

command -v zamokctl >/dev/null 2>&1 || die "zamokctl is required"
# 1.3.1 dropped unknown metadata keys instead of rejecting them, which shipped a
# cask that installed but never pulled Apple Container. Refuse it outright.
zamokctl_version="$(zamokctl --version 2>/dev/null | tr -d '[:space:]')"
[[ -n "$zamokctl_version" ]] || die "could not read zamokctl --version"
[[ "$(printf '1.3.2\n%s\n' "$zamokctl_version" | sort -V | head -1)" == "1.3.2" ]] \
    || die "zamokctl $zamokctl_version is too old; need >= 1.3.2. Run: brew upgrade bshk-app/tap/zamokctl"
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
    --metadata "$METADATA"

printf 'Cask: %s containerstack %s\n' "$TAP" "$SHORT_VERSION"
