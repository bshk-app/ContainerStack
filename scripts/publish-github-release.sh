#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

preflight=false
if [[ "${1:-}" == "--preflight" ]]; then
    preflight=true
    shift
    readonly SHORT_VERSION="${1:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
    readonly ARTIFACT=""
    readonly NOTES_FILE=""
    readonly MANIFEST=""
else
    readonly SHORT_VERSION="${3:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
    # zamokctl chooses the subdirectory under out/, so a bare invocation looks
    # for the DMG rather than assuming one path. `|| true` is load-bearing: under
    # `pipefail` a find over a missing out/ fails the assignment and `set -e`
    # exits with no message at all -- on the documented repair path, from a clean
    # clone, this script would simply say nothing.
    readonly ARTIFACT="${1:-$(find "$ROOT/out" -maxdepth 3 -type f -name "ContainerStack-${SHORT_VERSION}.dmg" -print 2>/dev/null | head -1 || true)}"
    readonly NOTES_FILE="${2:-${ROOT}/out/release-notes.md}"
    readonly MANIFEST="${4:-${ROOT}/out/github-release-manifest}"
fi

readonly REPOSITORY="${GITHUB_RELEASE_REPOSITORY:-bshk-app/ContainerStack}"
readonly CHANNEL="$(printf '%s' "${RELEASE_CHANNEL:-stable}" | tr '[:upper:]' '[:lower:]')"
readonly PUBLISH_MODE="${PUBLISH-1}"
readonly HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

case "$PUBLISH_MODE" in
    0|1) ;;
    *) die "PUBLISH must be 0 or 1, got: $PUBLISH_MODE" ;;
esac

command -v gh >/dev/null 2>&1 || die "gh is required. Install it and run gh auth login."
gh auth status --hostname github.com >/dev/null 2>&1 || die "gh is not authenticated for github.com"
can_push="$(gh api "repos/${REPOSITORY}" --jq '.permissions.push // false')" \
    || die "could not verify GitHub permissions for $REPOSITORY"
[[ "$can_push" == "true" ]] || die "GitHub credential cannot publish to $REPOSITORY"
gh api "repos/${REPOSITORY}/commits/${HEAD_SHA}" --silent >/dev/null \
    || die "$HEAD_SHA is not present in $REPOSITORY"

[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || die "working tree is dirty; commit the release inputs first"
# A release build must come from source that is already on the remote. On a
# branch the upstream ref proves it. A detached checkout of a tag -- what CI does
# for a release event -- has no upstream, and the commit check above is stronger
# evidence anyway: GitHub itself confirmed the SHA is in the repository.
if upstream="$(git -C "$ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
    [[ "$HEAD_SHA" == "$(git -C "$ROOT" rev-parse "$upstream")" ]] \
        || die "HEAD is not pushed to $upstream"
elif git -C "$ROOT" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
    die "current branch has no upstream"
fi

if [[ "$CHANNEL" == "stable" ]]; then
    tag="v${SHORT_VERSION}"
    title="ContainerStack ${SHORT_VERSION}"
    prerelease=false
    latest=true
else
    tag="v${SHORT_VERSION}-${CHANNEL}"
    title="ContainerStack ${SHORT_VERSION} (${CHANNEL})"
    prerelease=true
    latest=false
fi

draft=false
if [[ "$PUBLISH_MODE" == "0" ]]; then
    draft=true
    latest=false
fi

TAG_EXISTS=false
TAG_SHA=""
resolve_github_tag() {
    local response error_file error_text object_type object_sha
    error_file="$(mktemp)"
    if response="$(gh api "repos/${REPOSITORY}/git/ref/tags/${tag}" --jq '.object.type + " " + .object.sha' 2>"$error_file")"; then
        rm -f "$error_file"
        read -r object_type object_sha <<< "$response"
        if [[ "$object_type" == "tag" ]]; then
            TAG_SHA="$(gh api "repos/${REPOSITORY}/git/tags/${object_sha}" --jq '.object.sha')" \
                || die "could not peel annotated tag $tag"
        else
            TAG_SHA="$object_sha"
        fi
        TAG_EXISTS=true
        return
    fi

    error_text="$(<"$error_file")"
    rm -f "$error_file"
    case "$error_text" in
        *"HTTP 404"*) ;;
        *) die "could not inspect GitHub tag $tag: $error_text" ;;
    esac
}
resolve_github_tag

[[ "$TAG_EXISTS" == "false" || "$TAG_SHA" == "$HEAD_SHA" ]] \
    || die "$tag points to $TAG_SHA, but the artifact was built from $HEAD_SHA"

RELEASE_EXISTS=false
RELEASE_IS_DRAFT=false
RELEASE_IS_IMMUTABLE=false
resolve_github_release() {
    local response error_file error_text
    error_file="$(mktemp)"
    if response="$(gh release view "$tag" --repo "$REPOSITORY" --json isDraft,isImmutable --jq '[.isDraft, .isImmutable] | @tsv' 2>"$error_file")"; then
        rm -f "$error_file"
        RELEASE_EXISTS=true
        read -r RELEASE_IS_DRAFT RELEASE_IS_IMMUTABLE <<< "$response"
        return
    fi

    error_text="$(<"$error_file")"
    rm -f "$error_file"
    case "$error_text" in
        *"release not found"*|*"Release not found"*|*"HTTP 404"*) ;;
        *) die "could not inspect GitHub release $tag: $error_text" ;;
    esac
}
resolve_github_release

if [[ "$PUBLISH_MODE" == "0" && "$RELEASE_EXISTS" == "true" && "$RELEASE_IS_DRAFT" != "true" ]]; then
    die "$tag is already published; a draft run will not replace or demote it"
fi
if [[ "$RELEASE_EXISTS" == "true" && "$RELEASE_IS_IMMUTABLE" == "true" ]]; then
    die "$tag is immutable; refusing to replace its artifact or notes"
fi

if [[ "$preflight" == "true" ]]; then
    printf 'GitHub preflight OK: %s @ %s\n' "$tag" "$HEAD_SHA"
    exit 0
fi

command -v shasum >/dev/null 2>&1 || die "shasum is required"
[[ -f "$ARTIFACT" ]] || die "release artifact is missing: $ARTIFACT"
[[ -f "$MANIFEST" ]] || die "release provenance manifest is missing: $MANIFEST"
if [[ "$PUBLISH_MODE" != "0" && ! -s "$NOTES_FILE" ]]; then
    die "release notes are missing: $NOTES_FILE"
fi

manifest_value() { sed -n "s/^${1}=//p" "$MANIFEST"; }
manifest_commit="$(manifest_value commit)"
manifest_version="$(manifest_value version)"
manifest_build="$(manifest_value build)"
manifest_channel="$(manifest_value channel)"
manifest_publish="$(manifest_value publish)"
manifest_artifact="$(manifest_value artifact)"
manifest_artifact_sha="$(manifest_value artifact_sha256)"
manifest_notes_sha="$(manifest_value notes_sha256)"

[[ "$manifest_commit" == "$HEAD_SHA" ]] || die "manifest commit does not match HEAD"
[[ "$manifest_version" == "$SHORT_VERSION" ]] || die "manifest version does not match $SHORT_VERSION"
[[ -n "$manifest_build" ]] || die "manifest build is empty"
[[ "$manifest_channel" == "$CHANNEL" ]] || die "manifest channel does not match $CHANNEL"
[[ "$manifest_publish" == "$PUBLISH_MODE" ]] || die "manifest draft/live mode does not match PUBLISH=$PUBLISH_MODE"
[[ "$manifest_artifact" == "$(basename "$ARTIFACT")" ]] || die "manifest artifact name does not match"
[[ "$manifest_artifact_sha" == "$(shasum -a 256 "$ARTIFACT" | cut -d' ' -f1)" ]] \
    || die "artifact SHA-256 does not match the Zamok release manifest"
[[ "$manifest_notes_sha" == "$(shasum -a 256 "$NOTES_FILE" | cut -d' ' -f1)" ]] \
    || die "release notes differ from the Markdown sent to Sparkle"

common=(
    --repo "$REPOSITORY"
    --title "$title"
    --notes-file "$NOTES_FILE"
    --draft="$draft"
    --prerelease="$prerelease"
    --latest="$latest"
    --target "$HEAD_SHA"
)

if [[ "$RELEASE_EXISTS" == "true" ]]; then
    gh release upload "$tag" "$ARTIFACT" --repo "$REPOSITORY" --clobber
    gh release edit "$tag" "${common[@]}"
else
    gh release create "$tag" "$ARTIFACT" "${common[@]}"
fi

printf 'GitHub release: https://github.com/%s/releases/tag/%s\n' "$REPOSITORY" "$tag"
