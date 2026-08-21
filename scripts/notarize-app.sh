#!/usr/bin/env bash
set -euo pipefail

# Notarize a signed ContainerStack.app.
#
# Credentials never live on disk: run this under AgentVault, which injects them
# from 1Password for the lifetime of the command only.
#
#   av run --profile notarize -- ./scripts/notarize-app.sh build/ContainerStack.app
#
# Or use credentials already stored by notarytool:
#
#   NOTARY_KEYCHAIN_PROFILE=containerstack ./scripts/notarize-app.sh build/ContainerStack.app

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

app_bundle="${1:-${ROOT}/build/ContainerStack.app}"
if [[ "$app_bundle" != /* ]]; then
    app_bundle="${ROOT}/${app_bundle}"
fi

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    }
}

require_env() {
    [[ -n "${!1:-}" ]] || {
        printf '%s is not set. Run under: av run --profile notarize -- %s\n' \
            "$1" "${BASH_SOURCE[0]}" >&2
        exit 1
    }
}

require_command xcrun
require_command ditto
require_command codesign
credential_args=()
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    credential_args=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
else
    require_env NOTARY_APPLE_ID
    require_env NOTARY_PASSWORD
    require_env NOTARY_TEAM_ID
    credential_args=(
        --apple-id "$NOTARY_APPLE_ID"
        --password "$NOTARY_PASSWORD"
        --team-id "$NOTARY_TEAM_ID"
    )
fi

[[ -d "$app_bundle" ]] || {
    printf 'App bundle not found: %s\nRun scripts/stage-containerstack-app.sh first.\n' \
        "$app_bundle" >&2
    exit 1
}

printf '== verifying signature ==\n'
codesign --verify --deep --strict --verbose=2 "$app_bundle"

archive="$(mktemp -d)/$(basename "${app_bundle%.app}").zip"
printf '== packing %s ==\n' "$archive"
ditto -c -k --keepParent "$app_bundle" "$archive"

printf '== submitting to Apple notary service ==\n'
xcrun notarytool submit "$archive" "${credential_args[@]}" --wait

printf '== stapling ticket ==\n'
xcrun stapler staple "$app_bundle"
xcrun stapler validate "$app_bundle"

printf '== gatekeeper assessment ==\n'
spctl --assess --type execute --verbose=2 "$app_bundle"

rm -f "$archive"
printf 'Notarized bundle: %s\n' "$app_bundle"
