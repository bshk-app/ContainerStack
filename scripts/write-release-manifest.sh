#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ARTIFACT="${1:?usage: write-release-manifest.sh ARTIFACT NOTES VERSION BUILD CHANNEL PUBLISH OUTPUT}"
readonly NOTES="${2:?usage: write-release-manifest.sh ARTIFACT NOTES VERSION BUILD CHANNEL PUBLISH OUTPUT}"
readonly SHORT_VERSION="${3:?usage: write-release-manifest.sh ARTIFACT NOTES VERSION BUILD CHANNEL PUBLISH OUTPUT}"
readonly BUILD_NUMBER="${4:?usage: write-release-manifest.sh ARTIFACT NOTES VERSION BUILD CHANNEL PUBLISH OUTPUT}"
readonly CHANNEL="$(printf '%s' "${5:?usage: write-release-manifest.sh ARTIFACT NOTES VERSION BUILD CHANNEL PUBLISH OUTPUT}" | tr '[:upper:]' '[:lower:]')"
readonly PUBLISH_MODE="${6:?usage: write-release-manifest.sh ARTIFACT NOTES VERSION BUILD CHANNEL PUBLISH OUTPUT}"
readonly OUTPUT="${7:?usage: write-release-manifest.sh ARTIFACT NOTES VERSION BUILD CHANNEL PUBLISH OUTPUT}"

case "$PUBLISH_MODE" in
    0|1) ;;
    *) printf 'PUBLISH must be 0 or 1, got: %s\n' "$PUBLISH_MODE" >&2; exit 2 ;;
esac
[[ -f "$ARTIFACT" ]] || { printf 'Artifact is missing: %s\n' "$ARTIFACT" >&2; exit 1; }
[[ -f "$NOTES" ]] || { printf 'Notes are missing: %s\n' "$NOTES" >&2; exit 1; }

artifact_sha="$(shasum -a 256 "$ARTIFACT" | cut -d' ' -f1)"
notes_sha="$(shasum -a 256 "$NOTES" | cut -d' ' -f1)"

cat > "$OUTPUT" <<MANIFEST
commit=$(git -C "$ROOT" rev-parse HEAD)
version=$SHORT_VERSION
build=$BUILD_NUMBER
channel=$CHANNEL
publish=$PUBLISH_MODE
artifact=$(basename "$ARTIFACT")
artifact_sha256=$artifact_sha
notes_sha256=$notes_sha
MANIFEST
