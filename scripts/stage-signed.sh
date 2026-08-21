#!/usr/bin/env bash
set -euo pipefail

# Stage a Developer ID signed bundle. Thin wrapper over
# stage-containerstack-app.sh that supplies the identity from .env, so the
# Taskfile does not have to interpolate a credential-bearing variable itself.
#
#   av env -- ./scripts/stage-signed.sh <app-path> <short-version> <build-number>

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

app_path="${1:-${ROOT}/build/ContainerStack.app}"
short_version="${2:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
build_number="${3:-$(git -C "$ROOT" rev-list --count HEAD)}"

[[ -n "${RELEASE_DEVELOPER_ID_APPLICATION:-}" ]] || {
    printf 'RELEASE_DEVELOPER_ID_APPLICATION is not set.\n' >&2
    printf 'Copy .env.example to .env and fill it in, then run through the Taskfile.\n' >&2
    exit 1
}

APP_VERSION="$short_version" \
BUILD_NUMBER="$build_number" \
SIGNING_IDENTITY="$RELEASE_DEVELOPER_ID_APPLICATION" \
SOCKTAINER_BINARY="${SOCKTAINER_BINARY:-${HOME}/.local/bin/socktainer}" \
    "$ROOT/scripts/stage-containerstack-app.sh" "$app_path"
