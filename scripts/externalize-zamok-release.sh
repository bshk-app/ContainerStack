#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SHORT_VERSION="${1:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
readonly BUILD_NUMBER="${2:?usage: externalize-zamok-release.sh VERSION BUILD}"
readonly CHANNEL="$(printf '%s' "${RELEASE_CHANNEL:-stable}" | tr '[:lower:]' '[:upper:]')"
readonly REPOSITORY="${GITHUB_RELEASE_REPOSITORY:-bshk-app/ContainerStack}"
readonly PRODUCT_SLUG="${ZAMOK_PRODUCT_SLUG:-containerstack}"
readonly API_BASE="${ZAMOK_BASE_URL:?set ZAMOK_BASE_URL}"

[[ -n "${ZAMOK_API_KEY:-}" ]] || { printf 'ZAMOK_API_KEY is required.\n' >&2; exit 1; }
[[ "$ZAMOK_API_KEY" != av://* ]] || { printf 'Run through av env so ZAMOK_API_KEY resolves.\n' >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { printf 'curl is required.\n' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'jq is required.\n' >&2; exit 1; }

channel_lower="$(printf '%s' "$CHANNEL" | tr '[:upper:]' '[:lower:]')"
if [[ "$CHANNEL" == "STABLE" ]]; then
    tag="v${SHORT_VERSION}"
else
    tag="v${SHORT_VERSION}-${channel_lower}"
fi
artifact="ContainerStack-${SHORT_VERSION}.dmg"
enclosure_url="https://github.com/${REPOSITORY}/releases/download/${tag}/${artifact}"

payload="$(jq -cn \
    --arg version "$BUILD_NUMBER" \
    --arg channel "$CHANNEL" \
    --arg enclosureUrl "$enclosure_url" \
    '{version: $version, channel: $channel, enclosureUrl: $enclosureUrl}')"

printf 'x-api-key: %s\n' "$ZAMOK_API_KEY" | \
    curl --fail-with-body --silent --show-error \
        -X POST "${API_BASE%/}/api/products/${PRODUCT_SLUG}/releases/externalize" \
        -H @- \
        -H "content-type: application/json" \
        --data "$payload"
printf '\nExternal enclosure: %s\n' "$enclosure_url"
