#!/usr/bin/env bash
set -euo pipefail

# Report which socktainer build would be staged into the bundle.
#
# Ask the binary, not a checkout beside it. SOCKTAINER_BINARY can point
# anywhere — a release has already been staged from a fork outside this tree —
# so a nearby checkout's HEAD says nothing about what gets copied in. socktainer
# stamps BUILD_GIT_COMMIT into itself, so the answer is in the file.
#
# Run through the Taskfile, which wraps this in `av env` so SOCKTAINER_BINARY
# from .env is honoured.

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BIN="${SOCKTAINER_BINARY:-${HOME}/.local/bin/socktainer}"
readonly STRICT="${1:-}"

if [[ -n "$STRICT" && "$STRICT" != "--strict" ]]; then
    printf 'usage: check-socktainer.sh [--strict]\n' >&2
    exit 2
fi

if [[ ! -x "$BIN" ]]; then
    printf 'socktainer not found at %s\n' "$BIN" >&2
    printf 'Run scripts/prepare-v1-runtime.sh first — note it stops the Apple\n' >&2
    printf 'Container service and moves its data directory aside.\n' >&2
    exit 1
fi

pinned="$("$ROOT/scripts/prepare-v1-runtime.sh" pin)"
reported="$("$BIN" --version 2>/dev/null || true)"

case "$reported" in
    *"$pinned"*)
        printf 'socktainer OK — %s\n' "$reported"
        printf '  from: %s\n' "$BIN"
        ;;
    *unspecified*)
        printf 'WARNING: socktainer at %s carries no build stamp.\n' "$BIN" >&2
        printf '         Built without BUILD_GIT_COMMIT, so its revision cannot be\n' >&2
        printf '         established. See .env.example for the stamped build command.\n' >&2
        [[ "$STRICT" != "--strict" ]] || exit 1
        ;;
    *)
        printf 'WARNING: socktainer reports %s, pinned is %s\n' \
            "${reported:-<no version output>}" "${pinned:0:12}" >&2
        [[ "$STRICT" != "--strict" ]] || exit 1
        ;;
esac
