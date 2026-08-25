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
# This is the public releasing clone. BUILD_NUMBER_BASE preserves monotonic
# Sparkle versions across the sanitized-history reset; raw commit count would
# mint a number below 0.4.0's build 140 and installed apps would ignore it.
[[ -f "$ROOT/BUILD_NUMBER_BASE" ]] || die "BUILD_NUMBER_BASE is missing.
Release from a clone of bshk-app/ContainerStack with .env and agentvault.yaml copied in."

[[ -f "$ROOT/VERSION" ]] || die "VERSION file is missing"
SHORT_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_NUMBER="$("$ROOT/scripts/build-number.sh")"
[[ -n "$SHORT_VERSION" ]] || die "VERSION is empty"

# GitHub tags and release artifacts must be reproducible from already-pushed
# source. Drafts obey the same rule.
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] \
    || die "working tree is dirty; commit the release inputs first"
upstream="$(git -C "$ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" \
    || die "current branch has no upstream"
[[ "$(git -C "$ROOT" rev-parse HEAD)" == "$(git -C "$ROOT" rev-parse "$upstream")" ]] \
    || die "HEAD is not pushed to $upstream"

# zamokctl signs arbitrary Helpers/loose Mach-O deepest-first with hardened
# runtime + timestamp. The vendored Apple Container runtime additionally needs a
# per-binary virtualization entitlement: zamokctl >= 1.6.0 expresses that through
# signing.nestedEntitlements in zamok.config.json, and refuses the release when a
# rule matches nothing — so a renamed upstream binary fails here, loudly, rather
# than shipping unentitled and failing at runtime on someone's machine.
if [[ "${VENDOR_CONTAINER_RUNTIME:-0}" != "0" ]]; then
    # Parsed with a version regex, not `tr -d`: a future prefixed output such as
    # "zamokctl 1.5.0" would leave a leading letter, `sort -V` would call the pair
    # already-sorted, and the guard would PASS on a binary too old to entitle the
    # runtime. An unparsable version must fail here instead.
    zamokctl_version="$(zamokctl --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    [[ -n "$zamokctl_version" ]] \
        || die "cannot read a version from 'zamokctl --version'"
    printf '%s\n%s\n' "1.6.0" "$zamokctl_version" | sort -V -C \
        || die "vendored runtime needs zamokctl >= 1.6.0 (have $zamokctl_version).
Upgrade with: brew upgrade bshk-app/tap/zamokctl   (the bare formula name is ambiguous)"
    [[ -f "$ROOT/zamok.config.json" ]] \
        || die "VENDOR_CONTAINER_RUNTIME=1 needs zamok.config.json with signing.nestedEntitlements"
fi

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

# A draft here proves the new Zamok signing path. Creating a GitHub draft for a
# release-please tag before its PR merges would make release-please's own release
# creation fail and strand the normal pipeline. GitHub preflight/mirroring remain
# part of the live path only.
if [[ "$PUBLISH_MODE" == "1" ]]; then
    note "== GitHub release preflight =="
    RELEASE_CHANNEL="$RELEASE_CHANNEL_LOWER" \
        "$ROOT/scripts/publish-github-release.sh" --preflight "$SHORT_VERSION"
else
    note "note: PUBLISH=0 — GitHub is untouched; this is a Zamok-only draft."
fi

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

if [[ "$PUBLISH_MODE" == "1" ]]; then
    github_manifest="${OUT_DIR}/github-release-manifest"
    "$ROOT/scripts/write-release-manifest.sh" \
        "$dmg_path" "$notes_file" "$staged_short" "$staged_build" \
        "$RELEASE_CHANNEL_LOWER" "$PUBLISH_MODE" "$github_manifest"

    note "== mirroring the same artifact and notes to GitHub Releases =="
    RELEASE_CHANNEL="$RELEASE_CHANNEL_LOWER" \
        "$ROOT/scripts/publish-github-release.sh" \
            "$dmg_path" "$notes_file" "$staged_short" "$github_manifest"

    note "== moving the published enclosure to GitHub storage =="
    RELEASE_CHANNEL="$RELEASE_CHANNEL_LOWER" \
        "$ROOT/scripts/externalize-zamok-release.sh" "$staged_short" "$staged_build"
fi

if [[ "$PUBLISH_MODE" == "0" ]]; then
    printf '\nDrafted %s %s (%s) on the %s channel.\n' \
        "$ZAMOK_PRODUCT_SLUG" "$staged_short" "$staged_build" "$RELEASE_CHANNEL_LOWER"
else
    printf '\nReleased %s %s (%s) to the %s channel.\n' \
        "$ZAMOK_PRODUCT_SLUG" "$staged_short" "$staged_build" "$RELEASE_CHANNEL_LOWER"
fi
