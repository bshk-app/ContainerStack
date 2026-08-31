#!/usr/bin/env bash
set -euo pipefail

# User-run prerequisite for ContainerStack V1.
# This script deliberately stops the existing Apple Container service and moves
# its data directory aside. It never deletes data or starts a daemon for you.

readonly TARGET_CONTAINER_VERSION="1.3.1"
readonly TARGET_RELEASE_URL="https://github.com/apple/container/releases/tag/${TARGET_CONTAINER_VERSION}"
# Apple Container reports its own data directory as `appRoot`, and the path has moved between
# versions — 1.2.2 and later use com.apple.container, while com.apple.containerization is a
# leftover from earlier builds. Asking the runtime instead of hardcoding is what keeps "moved the
# old data aside" from silently moving nothing, which is worse than failing: the next run starts
# against data the operator believes was reset. The fallback is only for a runtime too broken to
# answer.
readonly DATA_ROOT_FALLBACK="${HOME}/Library/Application Support/com.apple.container"
# Pinned to our fork. #358 has since landed upstream, but do not unpin on that alone — the branch
# carries changes the app depends on, and dropping any of them regresses a shipped feature:
#   * POST /containers/{id}/rename, without which `compose up` fails on any edited service, so the
#     app's ports/volumes editing cannot be applied;
#   * a fix for an inspect trap that killed the daemon when two host ports publish one container
#     port — exactly what adding a second port produces.
#   * the port to Apple Container 1.3.1 / Containerization 0.42.0, which upstream has not made.
# Each was exercised against a live 1.3.1 runtime before this pin moved.
# Unpin only once every one of them is upstream.
readonly SOCKTAINER_REPO_URL="https://github.com/beshkenadze/socktainer.git"
readonly SOCKTAINER_REV="6cedf5e45f745c7f945babdb1f8a00a5de8d696e"
readonly SOCKTAINER_SOURCE_ROOT="${HOME}/Library/Application Support/ContainerStack/socktainer"
readonly SOCKTAINER_BIN_DIR="${HOME}/.local/bin"
readonly SOCKTAINER_BIN="${SOCKTAINER_BIN_DIR}/socktainer"
readonly SOCKTAINER_SOCKET="${HOME}/.socktainer/container.sock"

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    }
}

# Apple Container prints `appRoot` in its status table; trailing slashes are stripped so the
# directory can be moved.
resolve_data_root() {
    local reported
    # Everything after the field name: the path contains a space ("Application Support"), so $2
    # alone truncates it to /Users/<you>/Library/Application.
    reported="$(container system status 2>/dev/null | awk '$1 == "appRoot" { $1 = ""; sub(/^[ \t]+/, ""); print }')"
    reported="${reported%/}"
    if [[ -n "$reported" ]]; then
        printf '%s\n' "$reported"
        return 0
    fi
    printf 'Could not read appRoot from `container system status`; falling back to %s\n' \
        "$DATA_ROOT_FALLBACK" >&2
    printf '%s\n' "$DATA_ROOT_FALLBACK"
}

usage() {
    cat <<'EOF'
Usage:
  ./scripts/prepare-v1-runtime.sh prepare
  ./scripts/prepare-v1-runtime.sh verify
  ./scripts/prepare-v1-runtime.sh build-socktainer
  ./scripts/prepare-v1-runtime.sh pin              # print SOCKTAINER_REV

prepare:
  - downloads the signed Apple Container 1.3.1 installer
  - verifies its SHA-256 digest and package signature
  - stops the old runtime before changing its files
  - installs Apple Container and moves the old data directory aside
  - clones pinned Socktainer source
- rebuilds Socktainer against Container 1.3.1 / Containerization 0.42.0
  - installs Socktainer at ~/.local/bin/socktainer
  - does NOT start either daemon

verify:
  - checks Apple Container and Socktainer versions
  - checks Socktainer's Docker socket
  - verifies Docker API access through the socktainer context
  - runs `hello-world` through Docker CLI

build-socktainer:
  - clones and builds the pinned Socktainer only, into ~/.local/bin/socktainer
  - touches no daemon and moves no data, so it is safe on a build machine
  - this is what CI uses to stage the sidecar

Start both manually before `verify`:
  export PATH="$HOME/.local/bin:$PATH"
  container system start
  socktainer --no-check-compatibility --no-docker-context
EOF
}

install_socktainer() {
    require_command git
    require_command swift
    require_command install
    require_command perl
    require_command jq

    mkdir -p "$SOCKTAINER_BIN_DIR" "$(dirname "$SOCKTAINER_SOURCE_ROOT")"
    if [[ ! -d "$SOCKTAINER_SOURCE_ROOT/.git" ]]; then
        git clone --filter=blob:none "$SOCKTAINER_REPO_URL" "$SOCKTAINER_SOURCE_ROOT"
    fi

    git -C "$SOCKTAINER_SOURCE_ROOT" fetch --depth 1 origin "$SOCKTAINER_REV"
    git -C "$SOCKTAINER_SOURCE_ROOT" checkout --detach "$SOCKTAINER_REV"

    # The pinned revision declares Container 1.3.1 and Containerization 0.42.0 itself, and
    # carries the `ssh` field Builder.BuildConfig gained. Both used to be patched in here; a
    # rewrite that silently matches nothing is worse than no rewrite, so the resolution check
    # below is what guards the versions now.
    swift package --package-path "$SOCKTAINER_SOURCE_ROOT" resolve

    local resolved_container resolved_containerization
    resolved_container="$(jq -r '.pins[] | select(.identity == "container") | .state.version' "$SOCKTAINER_SOURCE_ROOT/Package.resolved")"
    resolved_containerization="$(jq -r '.pins[] | select(.identity == "containerization") | .state.version' "$SOCKTAINER_SOURCE_ROOT/Package.resolved")"
    [[ "$resolved_container" == "1.3.1" && "$resolved_containerization" == "0.42.0" ]] || {
        printf 'Unexpected Socktainer dependency resolution: container=%s containerization=%s\n' \
            "$resolved_container" "$resolved_containerization" >&2
        exit 1
    }

    # Reported as Components[0].Version by GET /version. Since that endpoint now names the emulated
    # Docker Engine in `Version` (socktainer issue #9), this is the only field telling a client what
    # actually serves it — so name the build and the exact bridge revision behind it.
    BUILD_VERSION="containerstack-v1+${SOCKTAINER_REV:0:12}" \
    BUILD_GIT_COMMIT="$SOCKTAINER_REV" \
    BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        swift build --package-path "$SOCKTAINER_SOURCE_ROOT" -c release

    local bin_path="$(swift build --package-path "$SOCKTAINER_SOURCE_ROOT" -c release --show-bin-path)"
    install -m 0755 "$bin_path/socktainer" "$SOCKTAINER_BIN"
    "$SOCKTAINER_BIN" --version
}

prepare() {
    require_command curl
    require_command jq
    require_command shasum
    require_command pkgutil
    require_command installer
    require_command container
    require_command uname

    [[ "$(uname -m)" == "arm64" ]] || {
        printf 'ContainerStack V1 requires Apple Silicon (arm64).\n' >&2
        exit 1
    }

    local release_json tmp_dir pkg_url pkg_name expected_digest actual_digest
    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/containerstack-v1.XXXXXX")"
    release_json="${tmp_dir}/release.json"
    curl --fail --silent --show-error --location \
        "https://api.github.com/repos/apple/container/releases/tags/${TARGET_CONTAINER_VERSION}" \
        --output "$release_json"

    pkg_url="$(jq -r '[.assets[] | select(.name | endswith("-installer-signed.pkg")) | .browser_download_url] | if length == 1 then .[0] else empty end' "$release_json")"
    pkg_name="$(jq -r '[.assets[] | select(.name | endswith("-installer-signed.pkg")) | .name] | if length == 1 then .[0] else empty end' "$release_json")"
    [[ -n "$pkg_url" && -n "$pkg_name" ]] || {
        printf 'Could not identify exactly one .pkg asset in %s\n' "$TARGET_RELEASE_URL" >&2
        exit 1
    }

    local pkg_path="${tmp_dir}/${pkg_name}"
    curl --fail --silent --show-error --location "$pkg_url" --output "$pkg_path"

    expected_digest="$(jq -r --arg name "$pkg_name" '.assets[] | select(.name == $name) | .digest' "$release_json")"
    actual_digest="sha256:$(shasum -a 256 "$pkg_path" | cut -d ' ' -f 1)"
    [[ "$expected_digest" == "$actual_digest" ]] || {
        printf 'SHA-256 mismatch for %s\nexpected: %s\nactual:   %s\n' "$pkg_name" "$expected_digest" "$actual_digest" >&2
        exit 1
    }

    pkgutil --check-signature "$pkg_path"

    # Resolved while the service still answers; a stopped runtime reports nothing.
    local data_root backup_root
    data_root="$(resolve_data_root)"
    backup_root="${data_root}.pre-containerstack-v1.$(date +%Y%m%d-%H%M%S)"

    local status_output
    status_output="$(container system status 2>&1)" || true
    if [[ "$status_output" != *"not running"* ]]; then
        container system stop
    fi

    local stopped=false
    for _ in {1..30}; do
        status_output="$(container system status 2>&1)" || true
        if [[ "$status_output" == *"not running"* ]]; then
            stopped=true
            break
        fi
        sleep 1
    done
    if [[ "$stopped" != true ]]; then
        printf 'Apple Container did not stop safely; refusing to move its data.\n%s\n' "$status_output" >&2
        exit 1
    fi

    if [[ -d "$data_root" ]]; then
        mv "$data_root" "$backup_root"
        printf 'Moved old data to: %s\n' "$backup_root"
    else
        printf 'No data directory at %s — nothing to move aside.\n' "$data_root"
    fi

    sudo installer -pkg "$pkg_path" -target /
    install_socktainer

    printf '\nApple Container and Socktainer are prepared. Do not start either daemon from this script.\n'
    printf 'Next: container system start\n'
    printf 'Then start Socktainer with: socktainer --no-check-compatibility --no-docker-context\n'
    printf 'Finally run: ./scripts/prepare-v1-runtime.sh verify\n'
}

verify() {
    require_command container
    require_command docker
    require_command socktainer

    local container_version socktainer_version
    container_version="$(container --version)"
    printf '%s\n' "$container_version"
    [[ "$container_version" == *"$TARGET_CONTAINER_VERSION"* ]] || {
        printf 'Expected Apple Container %s, got: %s\n' "$TARGET_CONTAINER_VERSION" "$container_version" >&2
        exit 1
    }

    socktainer_version="$(socktainer --version)"
    printf '%s\n' "$socktainer_version"
    [[ "$socktainer_version" == *"$SOCKTAINER_REV"* ]] || {
        printf 'Expected Socktainer commit %s, got: %s\n' "$SOCKTAINER_REV" "$socktainer_version" >&2
        exit 1
    }

    container system status
    for _ in {1..30}; do
        [[ -S "$SOCKTAINER_SOCKET" ]] && break
        sleep 1
    done
    [[ -S "$SOCKTAINER_SOCKET" ]] || {
        printf 'Socktainer socket not found: %s\nStart Socktainer, then retry.\n' \
            "$SOCKTAINER_SOCKET" >&2
        exit 1
    }

    if ! docker --host "unix://$SOCKTAINER_SOCKET" version >/dev/null 2>&1; then
        printf 'Socktainer socket is not responding: %s\nStart Socktainer, then retry.\n' \
            "$SOCKTAINER_SOCKET" >&2
        exit 1
    fi

    if ! docker context inspect socktainer >/dev/null 2>&1; then
        docker context create socktainer \
            --docker "host=unix://$SOCKTAINER_SOCKET"
    fi

    docker --context socktainer version
    docker --context socktainer info
    docker --context socktainer ps --all
    docker --context socktainer run hello-world
    docker --context socktainer ps --all --filter ancestor=hello-world
}

case "${1:-}" in
    prepare) prepare ;;
    verify) verify ;;
    build-socktainer) install_socktainer ;;
    # The pin decides which binary ships, so everything that needs to know it
    # asks here rather than re-implementing the same grep somewhere else.
    pin) printf '%s\n' "$SOCKTAINER_REV" ;;
    *) usage; exit 2 ;;
esac
