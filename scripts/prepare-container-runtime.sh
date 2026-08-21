#!/usr/bin/env bash
set -euo pipefail

# Fetch the pinned Apple Container release and unpack it into a local cache, so
# a build can vendor it into the app bundle.
#
# Why vendor it at all: Homebrew cannot pin a dependency's version. Declaring
# `depends_on formula: "container"` gets the user whatever homebrew-core happens
# to hold that day, and when Apple Container's API moves, ContainerStack breaks
# on a machine we never touched — silently, because nothing on either side is
# checking. The pin only protects us while it reaches the user, and a pin that
# lives in a developer script does not.
#
# This is a supported deployment mode, not a trick: `container system start`
# takes --install-root, --app-root and --log-root, so the whole runtime is
# designed to live somewhere other than /usr/local.
#
# Redistribution is permitted (Apache-2.0); the LICENSE travels with the payload
# and is staged into the bundle beside it.
#
#   ./scripts/prepare-container-runtime.sh            # fetch + unpack to the cache
#   ./scripts/prepare-container-runtime.sh --print    # just print the cache path
#
# Unlike prepare-v1-runtime.sh this touches no running service and moves no
# data: it only writes inside its own cache directory.

readonly CONTAINER_VERSION="1.2.2"
readonly CONTAINER_PKG_SHA256="f4c7e73f7203725a3512676dfd9ec6c6a98a37093b6fd4a1b0fdcfcb227e2118"
readonly CONTAINER_PKG="container-${CONTAINER_VERSION}-installer-signed.pkg"
readonly CONTAINER_URL="https://github.com/apple/container/releases/download/${CONTAINER_VERSION}/${CONTAINER_PKG}"

readonly CACHE_ROOT="${CONTAINERSTACK_RUNTIME_CACHE:-${HOME}/Library/Application Support/ContainerStack/container-runtime}"
readonly INSTALL_ROOT="${CACHE_ROOT}/${CONTAINER_VERSION}"

if [[ "${1:-}" == "--print" ]]; then
    printf '%s\n' "$INSTALL_ROOT"
    exit 0
fi

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    }
}

require_command curl
require_command shasum
require_command pkgutil

# `bin/container` plus the plugin tree under `libexec/container` is the whole
# install root; its presence is what "already prepared" means.
# "Prepared" means redistributable, not merely present: an earlier run that died
# between staging and the licence fetch leaves a tree that runs fine and cannot
# legally ship. Checking only for the binaries would wave that through.
if [[ -x "$INSTALL_ROOT/bin/container" && -d "$INSTALL_ROOT/libexec/container" &&
      -s "$INSTALL_ROOT/LICENSE" && -s "$INSTALL_ROOT/NOTICE.md" ]]; then
    reported="$("$INSTALL_ROOT/bin/container" --version 2>/dev/null || true)"
    if [[ "$reported" == *"$CONTAINER_VERSION"* ]]; then
        printf 'Apple Container %s already unpacked: %s\n' "$CONTAINER_VERSION" "$INSTALL_ROOT"
        exit 0
    fi
    printf 'Cache holds an unexpected build (%s); re-fetching.\n' "${reported:-unknown}" >&2
    rm -rf "$INSTALL_ROOT"
elif [[ -e "$INSTALL_ROOT" ]]; then
    printf 'Cache is incomplete (missing binaries or licence); re-fetching.\n' >&2
    rm -rf "$INSTALL_ROOT"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

printf '== downloading Apple Container %s ==\n' "$CONTAINER_VERSION"
curl -fSL --progress-bar -o "$work/$CONTAINER_PKG" "$CONTAINER_URL"

printf '== verifying checksum ==\n'
actual="$(shasum -a 256 "$work/$CONTAINER_PKG" | awk '{print $1}')"
if [[ "$actual" != "$CONTAINER_PKG_SHA256" ]]; then
    printf 'Checksum mismatch for %s\n  expected %s\n  actual   %s\n' \
        "$CONTAINER_PKG" "$CONTAINER_PKG_SHA256" "$actual" >&2
    exit 1
fi

# Expanded rather than installed: `installer` would write to /usr/local and
# register a system service, which is exactly the machine-wide state this
# vendoring exists to avoid.
printf '== expanding ==\n'
pkgutil --expand-full "$work/$CONTAINER_PKG" "$work/expanded" >/dev/null

payload="$work/expanded/Payload"
[[ -x "$payload/bin/container" ]] || {
    printf 'Unexpected package layout: no bin/container under %s\n' "$payload" >&2
    exit 1
}

printf '== staging into the cache ==\n'
mkdir -p "$(dirname "$INSTALL_ROOT")"
rm -rf "$INSTALL_ROOT"
# ditto rather than cp: it preserves the code signatures on the way in, so what
# lands here still verifies as Apple's before we re-sign it.
ditto "$payload" "$INSTALL_ROOT"

# Apache-2.0 (§4a, §4d) requires the licence and any NOTICE to travel with a
# redistributed binary. The installer package ships neither, so they come from
# the source tree at the same tag — pinned to the tag, not to a branch, so the
# text matches the binaries beside it.
printf '== fetching licence and notice ==\n'

# raw.githubusercontent rate-limits anonymous requests hard enough to 429 on a
# second run, so prefer the authenticated API when gh is present and keep the
# anonymous path as a retrying fallback. A transient 429 must not fail a build,
# but a genuinely missing licence must.
fetch_doc() {
    local doc="$1" dest="$2"

    if command -v gh >/dev/null 2>&1 &&
        gh api "repos/apple/container/contents/${doc}?ref=${CONTAINER_VERSION}" \
            --jq '.content' 2>/dev/null | base64 -d > "$dest" 2>/dev/null &&
        [[ -s "$dest" ]]; then
        return 0
    fi

    for attempt in 1 2 3; do
        if curl -fsSL --retry 2 --retry-delay 3 -o "$dest" \
            "https://raw.githubusercontent.com/apple/container/${CONTAINER_VERSION}/${doc}" &&
            [[ -s "$dest" ]]; then
            return 0
        fi
        sleep $((attempt * 5))
    done
    return 1
}

for doc in LICENSE NOTICE.md; do
    if fetch_doc "$doc" "$INSTALL_ROOT/$doc"; then
        printf '  %s (%s bytes)\n' "$doc" "$(wc -c < "$INSTALL_ROOT/$doc" | tr -d ' ')"
    else
        rm -f "$INSTALL_ROOT/$doc"
        printf 'ERROR: could not fetch %s. Apache-2.0 requires it to accompany the\n' "$doc" >&2
        printf '       binaries; refusing to leave a redistributable tree without it.\n' >&2
        exit 1
    fi
done

reported="$("$INSTALL_ROOT/bin/container" --version 2>&1 | head -1)"
printf '\nUnpacked: %s\n' "$INSTALL_ROOT"
printf 'Reports:  %s\n' "$reported"
printf 'Size:     %s\n' "$(du -sh "$INSTALL_ROOT" | awk '{print $1}')"
