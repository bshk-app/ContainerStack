#!/usr/bin/env bash
set -euo pipefail

# Ship a ContainerStack release through Zamok, then mirror the same artifact and
# notes to GitHub:
#
#   unsigned stage -> zamokctl codesign -> notarize -> staple -> DMG
#                  -> Zamok publish/appcast -> GitHub Release
#
# Run it through the Taskfile, which wraps this in `av env` so the `av://`
# references in .env resolve without ever touching disk:
#
#   task release:zamok            # publish
#   task release:zamok PUBLISH=0  # upload a DRAFT, skip appcast verify
#
# Everything is read from .env plus the committed VERSION file; there are no
# arguments. DMG assembly, signing, notarization and stapling all happen inside
# zamokctl -- that is why this script does no hdiutil work of its own.

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PUBLISH_MODE="${PUBLISH-1}"
readonly OUT_DIR="${ROOT}/out"
readonly APP_PATH="${ROOT}/build/ContainerStack.app"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_env() {
    [[ -n "${!1:-}" ]] || die "$1 is not set. Copy .env.example to .env and fill it in."
}

# A value that still looks like an unresolved AgentVault reference means this ran
# outside `av env`, and passing the literal string on to zamokctl would fail much
# later with a confusing 401.
reject_unresolved() {
    [[ "${!1:-}" != av://* ]] \
        || die "$1 is still an av:// reference. Run through the Taskfile, or wrap with: av env -- $0"
}

case "$PUBLISH_MODE" in
    0|1) ;;
    *) die "PUBLISH must be 0 or 1, got: $PUBLISH_MODE" ;;
esac

require_command zamokctl
require_command security
require_command /usr/libexec/PlistBuddy
require_command gh
require_command shasum

require_env ZAMOK_PRODUCT_SLUG
require_env ZAMOK_API_KEY
reject_unresolved ZAMOK_API_KEY
require_env SPARKLE_PUBLIC_ED_KEY

readonly ZAMOK_BASE_URL="${ZAMOK_BASE_URL:?set ZAMOK_BASE_URL}"
readonly RELEASE_CHANNEL_LOWER="$(printf '%s' "${RELEASE_CHANNEL:-stable}" | tr '[:upper:]' '[:lower:]')"
readonly RELEASE_CHANNEL_UPPER="$(printf '%s' "$RELEASE_CHANNEL_LOWER" | tr '[:lower:]' '[:upper:]')"

# ── Version SSOT ─────────────────────────────────────────────────────────────
# Marketing version is committed in VERSION. BUILD_NUMBER_BASE preserves
# monotonic Sparkle versions across the sanitized public-history reset; each
# subsequent commit increments the result.
[[ -f "$ROOT/VERSION" ]] || die "VERSION is missing"
[[ -f "$ROOT/BUILD_NUMBER_BASE" ]] || die "BUILD_NUMBER_BASE is missing"
SHORT_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_NUMBER="$("$ROOT/scripts/build-number.sh")"
[[ -n "$SHORT_VERSION" ]] || die "VERSION is empty"

# GitHub tags and release artifacts must be reproducible from already-pushed
# source. Drafts obey the same rule.
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] \
    || die "working tree is dirty; commit the release inputs first"
# A detached checkout of a tag -- what CI does for a release event -- has no
# upstream. publish-github-release.sh still proves the commit is on the remote
# by asking GitHub for it, which is stronger than an upstream ref.
if upstream="$(git -C "$ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
    [[ "$(git -C "$ROOT" rev-parse HEAD)" == "$(git -C "$ROOT" rev-parse "$upstream")" ]] \
        || die "HEAD is not pushed to $upstream"
elif git -C "$ROOT" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
    die "current branch has no upstream"
fi

# zamokctl signs arbitrary Helpers/loose Mach-O deepest-first with hardened
# runtime + timestamp. A vendored Apple Container runtime additionally needs a
# per-binary virtualization entitlement that zamokctl 1.3.1 cannot express yet.
[[ "${VENDOR_CONTAINER_RUNTIME:-0}" == "0" ]] \
    || die "zamokctl signing does not yet support the vendored runtime's per-binary entitlement"

"$ROOT/scripts/check-socktainer.sh" --strict

# ── Signing identity ─────────────────────────────────────────────────────────
SIGNING_SHA1="${RELEASE_SIGNING_IDENTITY_SHA1:-}"
if [[ -z "$SIGNING_SHA1" ]]; then
    require_env RELEASE_DEVELOPER_ID_APPLICATION
    SIGNING_SHA1="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | grep -F "$RELEASE_DEVELOPER_ID_APPLICATION" \
            | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40}).*/\1/' \
            | head -1
    )"
fi
[[ -n "$SIGNING_SHA1" ]] \
    || die "could not resolve a Developer ID SHA1. Set RELEASE_SIGNING_IDENTITY_SHA1 in .env."
mkdir -p "$OUT_DIR"

# ── Notarization credentials ─────────────────────────────────────────────────
notary_args=()
if [[ -n "${RELEASE_NOTARY_PROFILE:-}" ]]; then
    notary_args=(--notary-profile "$RELEASE_NOTARY_PROFILE")
else
    require_env NOTARY_KEY_PATH
    require_env NOTARY_KEY_ID
    require_env NOTARY_ISSUER
    [[ -f "$NOTARY_KEY_PATH" ]] || die "notary key not found at $NOTARY_KEY_PATH"
    notary_args=(
        --notary-api-key "$NOTARY_KEY_PATH"
        --notary-key-id  "$NOTARY_KEY_ID"
        --notary-issuer  "$NOTARY_ISSUER"
    )
fi

notes_file="$OUT_DIR/release-notes.md"
"$ROOT/scripts/extract-release-notes.sh" "$SHORT_VERSION" "$ROOT/CHANGELOG.md" > "$notes_file"

notes_args=()
if [[ -s "$notes_file" ]]; then
    notes_args=(--release-notes-path "$notes_file")
elif [[ "$PUBLISH_MODE" == "0" ]]; then
    note "note: CHANGELOG has no '## [$SHORT_VERSION]' section — draft without notes."
else
    die "CHANGELOG.md has no '## [$SHORT_VERSION]' section.
Move the entries from '## [Unreleased]' into '## [$SHORT_VERSION]' before releasing."
fi

# Fail before codesign/notarization/upload if GitHub auth, tag ownership, or
# draft/live state would make the final mirror unsafe.
note "== GitHub release preflight =="
env PUBLISH="$PUBLISH_MODE" RELEASE_CHANNEL="$RELEASE_CHANNEL_LOWER" \
    "$ROOT/scripts/publish-github-release.sh" --preflight "$SHORT_VERSION"

# ── Stage an unsigned bundle; zamokctl owns the release signature ─────────────
# SwiftPM's linker signatures are only build artifacts. The release path gives
# zamokctl the .app without --no-codesign so it signs nested code inside-out,
# notarizes, staples, and packages the DMG itself.
note "== staging unsigned bundle for zamokctl =="
APP_VERSION="$SHORT_VERSION" \
BUILD_NUMBER="$BUILD_NUMBER" \
    "$ROOT/scripts/stage-containerstack-app.sh" "$APP_PATH"

[[ -d "$APP_PATH" ]] || die "staging produced no bundle at $APP_PATH"

# Read the versions back out of the bundle rather than reusing the variables, so
# what is registered with Zamok is what is actually baked into the signed app.
staged_short="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
staged_build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP_PATH/Contents/Info.plist")"

publish_args=(--publish --verify)
if [[ "$PUBLISH_MODE" == "0" ]]; then
    publish_args=(--no-publish --no-verify)
    note "note: PUBLISH=0 — uploading a DRAFT, which is never served to users."
fi

cat >&2 <<INFO

== releasing ==
  product   $ZAMOK_PRODUCT_SLUG
  version   $staged_short ($staged_build)
  channel   $RELEASE_CHANNEL_LOWER
  identity  $SIGNING_SHA1
  endpoint  $ZAMOK_BASE_URL

INFO

dmg_path="${OUT_DIR}/${ZAMOK_PRODUCT_SLUG}/ContainerStack-${staged_short}.dmg"
rm -f "$dmg_path"

zamokctl release \
    --artifact "$APP_PATH" \
    --product-slug "$ZAMOK_PRODUCT_SLUG" \
    --short-version "$staged_short" \
    --version "$staged_build" \
    --channel "$RELEASE_CHANNEL_UPPER" \
    --signing-identity-sha1 "$SIGNING_SHA1" \
    "${notary_args[@]}" \
    --format dmg \
    --output-dir "$OUT_DIR" \
    --api-base-url "$ZAMOK_BASE_URL" \
    --api-key-env ZAMOK_API_KEY \
    "${notes_args[@]}" \
    "${publish_args[@]}"

[[ -f "$dmg_path" ]] || die "zamokctl produced no fresh DMG at $dmg_path"

github_manifest="${OUT_DIR}/github-release-manifest"
"$ROOT/scripts/write-release-manifest.sh" \
    "$dmg_path" "$notes_file" "$staged_short" "$staged_build" \
    "$RELEASE_CHANNEL_LOWER" "$PUBLISH_MODE" "$github_manifest"

note "== mirroring the same artifact and notes to GitHub Releases =="
env PUBLISH="$PUBLISH_MODE" RELEASE_CHANNEL="$RELEASE_CHANNEL_LOWER" \
    "$ROOT/scripts/publish-github-release.sh" \
        "$dmg_path" "$notes_file" "$staged_short" "$github_manifest"

if [[ "$PUBLISH_MODE" == "1" ]]; then
    note "== moving the published enclosure to GitHub storage =="
    RELEASE_CHANNEL="$RELEASE_CHANNEL_LOWER" \
        "$ROOT/scripts/externalize-zamok-release.sh" "$staged_short" "$staged_build"
fi

printf '\nReleased %s %s (%s) to the %s channel.\n' \
    "$ZAMOK_PRODUCT_SLUG" "$staged_short" "$staged_build" "$RELEASE_CHANNEL_LOWER"
printf 'Appcast: https://dl.bshk.app/products/%s/appcast/%s.xml\n' \
    "$ZAMOK_PRODUCT_SLUG" "$RELEASE_CHANNEL_LOWER"
