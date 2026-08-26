#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/ContainerStack.xcodeproj"
DERIVED_DATA="$ROOT/.build/tuist-smoke"
SOCKET_PATH="${CONTAINERSTACK_SOCKET:-$HOME/.containerstack/docker.sock}"
TEAM_ID="${CONTAINERSTACK_TEAM_ID:?set CONTAINERSTACK_TEAM_ID}"
SIGNING_CERTIFICATE="${CONTAINERSTACK_SIGNING_CERTIFICATE:?set CONTAINERSTACK_SIGNING_CERTIFICATE}"
SIGNING_ARGS=(
    "CODE_SIGN_STYLE=Manual"
    "CODE_SIGN_IDENTITY=$SIGNING_CERTIFICATE"
    "DEVELOPMENT_TEAM=$TEAM_ID"
)

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$1" >&2
        exit 2
    }
}

require_command tuist
require_command xcodebuild
require_command codesign

cd "$ROOT"
printf '%s\n' '==> Generating Xcode project with Tuist'
tuist generate --no-open

printf '%s\n' '==> Building ContainerStack app'
xcodebuild -quiet \
    -project "$PROJECT" \
    -scheme ContainerStack \
    -configuration Debug \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    "${SIGNING_ARGS[@]}" \
    build

printf '%s\n' '==> Building cstack CLI'
xcodebuild -quiet \
    -project "$PROJECT" \
    -scheme cstack \
    -configuration Debug \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    "${SIGNING_ARGS[@]}" \
    build

printf '%s\n' '==> Building runtime helper'
xcodebuild -quiet \
    -project "$PROJECT" \
    -scheme ContainerStackRuntime \
    -configuration Debug \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    "${SIGNING_ARGS[@]}" \
    build

printf '%s\n' '==> Running core tests'
xcodebuild -quiet \
    -project "$PROJECT" \
    -scheme ContainerStackTests \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    "${SIGNING_ARGS[@]}" \
    test

CLI="$DERIVED_DATA/Build/Products/Debug/cstack"
APP="$DERIVED_DATA/Build/Products/Debug/ContainerStack.app"

printf '%s\n' '==> Running CLI help smoke test'
"$CLI" help

test -d "$APP"
test "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" = "app.bshk.containerstack"
test "$(plutil -extract LSUIElement raw "$APP/Contents/Info.plist")" = "false"
test "$(plutil -extract LSMultipleInstancesProhibited raw "$APP/Contents/Info.plist")" = "true"
HELPER="$APP/Contents/Helpers/ContainerStackRuntime"
AGENT_PLIST="$APP/Contents/Library/LaunchAgents/com.containerstack.runtime.plist"
test -x "$HELPER"
test -f "$AGENT_PLIST"
test "$(plutil -extract BundleProgram raw "$AGENT_PLIST")" = "Contents/Helpers/ContainerStackRuntime"
signed_team="$(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
helper_team="$(codesign -dv --verbose=2 "$HELPER" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [[ "$signed_team" != "$TEAM_ID" || "$helper_team" != "$TEAM_ID" ]]; then
    printf 'Unexpected signing team: app=%s helper=%s (expected %s)\n' "$signed_team" "$helper_team" "$TEAM_ID" >&2
    exit 1
fi
printf 'App bundle: %s\n' "$APP"

if [[ -S "$SOCKET_PATH" ]]; then
    printf '==> Running live Docker API smoke test against %s\n' "$SOCKET_PATH"
    "$CLI" doctor --socket "$SOCKET_PATH"
else
    printf '==> Skipping live Docker API smoke test; socket not found: %s\n' "$SOCKET_PATH"
fi

printf '%s\n' 'Smoke tests passed.'
