#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base="$(tr -d '[:space:]' < "$ROOT/BUILD_NUMBER_BASE")"
count="$(git -C "$ROOT" rev-list --count HEAD)"
[[ "$base" =~ ^[0-9]+$ ]] || { printf 'BUILD_NUMBER_BASE must be an integer.\n' >&2; exit 1; }
printf '%s\n' "$((base + count))"
