#!/usr/bin/env bash
set -euo pipefail

# Prepare a machine for the OrbStack vs ContainerStack comparison.
#
#   ./scripts/prepare-benchmark-host.sh
#
# Downloads and verifies the signed Apple Container installer, then installs it.
# The install step needs sudo, so run this yourself — it is the only interactive part.
# ContainerStack itself ships socktainer inside the app bundle, so nothing is built here.

readonly CONTAINER_VERSION="1.2.2"
readonly PKG_URL="https://github.com/apple/container/releases/download/${CONTAINER_VERSION}/container-${CONTAINER_VERSION}-installer-signed.pkg"
readonly APP_SOURCE="${APP_SOURCE:-/tmp/ContainerStack.app}"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    }
}

require_command curl
require_command installer
require_command pkgutil

if container --version 2>/dev/null | grep -q "$CONTAINER_VERSION"; then
    printf 'Apple Container %s already installed.\n' "$CONTAINER_VERSION"
else
    workdir="$(mktemp -d)"
    trap 'rm -rf "$workdir"' EXIT
    pkg="${workdir}/container.pkg"

    printf '== downloading Apple Container %s ==\n' "$CONTAINER_VERSION"
    curl -fsSL "$PKG_URL" -o "$pkg"

    printf '== verifying package signature ==\n'
    pkgutil --check-signature "$pkg" | sed -n '1,4p'

    printf '== installing (sudo) ==\n'
    sudo installer -pkg "$pkg" -target /
fi

if [[ -d "$APP_SOURCE" ]]; then
    printf '== installing ContainerStack.app ==\n'
    rm -rf /Applications/ContainerStack.app
    cp -R "$APP_SOURCE" /Applications/ContainerStack.app
    codesign --verify --strict /Applications/ContainerStack.app
fi

printf '\nReady. Start the runtime once, then benchmark:\n'
printf '  open /Applications/ContainerStack.app\n'
printf '  /tmp/benchmark-compare.sh 5\n'
