#!/usr/bin/env bash
set -euo pipefail

readonly source_root="${1:?usage: stage-welcome-release-resources.sh SOURCE_ROOT RESOURCES}"
readonly resources="${2:?usage: stage-welcome-release-resources.sh SOURCE_ROOT RESOURCES}"
readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
release_version="$(tr -d '[:space:]' < "$source_root/VERSION")"

mkdir -p "$resources"
/bin/rm -f "$resources/WelcomeVersion.txt" "$resources/WelcomeChangelog.md"
install -m 0644 "$source_root/VERSION" "$resources/WelcomeVersion.txt"
{
    printf '## [%s]\n' "$release_version"
    "$script_dir/extract-release-notes.sh" "$release_version" "$source_root/CHANGELOG.md"
} > "$resources/WelcomeChangelog.md"
chmod 0644 "$resources/WelcomeChangelog.md"
