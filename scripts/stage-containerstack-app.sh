#!/usr/bin/env bash
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CONFIGURATION="${CONFIGURATION:-release}"
readonly APP_VERSION="${APP_VERSION:-0.1.0}"
readonly BUILD_NUMBER="${BUILD_NUMBER:-1}"
readonly SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
readonly SOCKTAINER_BINARY="${SOCKTAINER_BINARY:-${HOME}/.local/bin/socktainer}"
readonly SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"

# Vendoring the Apple Container runtime into the bundle. Off by default: the
# Homebrew channel pins the version through a keg-only `container@1.2.2`
# formula, which costs ~30 MB instead of ~500 MB. Turn it on for a standalone
# .app handed out outside Homebrew, where nothing else can guarantee the
# version. See docs/vendoring-apple-container.md.
readonly VENDOR_CONTAINER_RUNTIME="${VENDOR_CONTAINER_RUNTIME:-0}"
readonly CONTAINER_RUNTIME_ROOT="${CONTAINER_RUNTIME_ROOT:-}"

output_bundle="${1:-${ROOT}/build/ContainerStack.app}"
if [[ "$output_bundle" != /* ]]; then
    output_bundle="${ROOT}/${output_bundle}"
fi

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    }
}

require_command swift
require_command install
require_command perl
require_command plutil
[[ -x "$SOCKTAINER_BINARY" ]] || {
    printf 'Socktainer binary not found: %s\nRun prepare-v1-runtime.sh first.\n' "$SOCKTAINER_BINARY" >&2
    exit 1
}
container_runtime_root=""
if [[ "$VENDOR_CONTAINER_RUNTIME" != "0" ]]; then
    container_runtime_root="${CONTAINER_RUNTIME_ROOT:-$("${ROOT}/scripts/prepare-container-runtime.sh" --print)}"
    [[ -x "$container_runtime_root/bin/container" ]] || {
        printf 'Vendored Apple Container not found: %s\n' "$container_runtime_root" >&2
        printf 'Run scripts/prepare-container-runtime.sh first.\n' >&2
        exit 1
    }
fi

if [[ -e "$output_bundle" ]]; then
    mv "$output_bundle" "${output_bundle}.previous.$(date +%Y%m%d-%H%M%S)"
fi

mkdir -p \
    "$output_bundle/Contents/MacOS" \
    "$output_bundle/Contents/Helpers" \
    "$output_bundle/Contents/Library/LaunchAgents" \
    "$output_bundle/Contents/Resources"

swift build --configuration "$CONFIGURATION" --product ContainerStack
swift build --configuration "$CONFIGURATION" --product cstack
swift build --configuration "$CONFIGURATION" --product ContainerStackRuntime
bin_path="$(swift build --configuration "$CONFIGURATION" --product ContainerStack --show-bin-path)"
runtime_bin_path="$(swift build --configuration "$CONFIGURATION" --product ContainerStackRuntime --show-bin-path)"
cli_bin_path="$(swift build --configuration "$CONFIGURATION" --product cstack --show-bin-path)"

install -m 0755 "$bin_path/ContainerStack" "$output_bundle/Contents/MacOS/ContainerStack"
install -m 0755 "$cli_bin_path/cstack" "$output_bundle/Contents/MacOS/cstack"
install -m 0755 "$runtime_bin_path/ContainerStackRuntime" "$output_bundle/Contents/Helpers/ContainerStackRuntime"
install -m 0755 "$SOCKTAINER_BINARY" "$output_bundle/Contents/Helpers/socktainer"
install -m 0644 "$ROOT/Packaging/ContainerStack.icns" "$output_bundle/Contents/Resources/ContainerStack.icns"
install -m 0644 "$ROOT/Packaging/socktainer.LICENSE" \
    "$output_bundle/Contents/Resources/socktainer.LICENSE"

# SwiftPM emits a flat resource directory with a `.bundle` suffix. Re-house it
# as a valid macOS resource bundle so zamokctl/codesign can traverse it while
# Bundle.url(forResource:) keeps finding the same paths.
swiftpm_bundle="$bin_path/ContainerStack_ContainerStackApp.bundle"
resource_bundle="$output_bundle/Contents/Resources/ContainerStack_ContainerStackApp.bundle"
if [[ -d "$swiftpm_bundle" ]]; then
    mkdir -p "$resource_bundle/Contents/Resources"
    ditto "$swiftpm_bundle" "$resource_bundle/Contents/Resources"
    install -m 0644 "$ROOT/Packaging/ContainerStackResources-Info.plist" \
        "$resource_bundle/Contents/Info.plist"
else
    echo "error: missing ContainerStack_ContainerStackApp.bundle next to $bin_path/ContainerStack" >&2
    exit 1
fi


# Resources, not Helpers, and the distinction is load-bearing. Under Helpers,
# codesign walks the plugin tree as nested code, reaches a `config.toml` sitting
# beside `bin/<plugin>`, and refuses to sign the bundle at all — leaving the
# linker's ad-hoc signature in place, which then fails verification for a reason
# that points at the wrong file. Under Resources the same tree is sealed as
# resources while its Mach-O keep their own signatures.
#
# `ditto` rather than cp -R: it preserves the Apple signatures on the way in, so
# anything that fails to verify later failed during OUR re-signing rather than
# arriving broken. The tree carries its own LICENSE and NOTICE.md (Apache-2.0
# §4a, §4d) — prepare-container-runtime.sh refuses to produce one without them.
if [[ -n "$container_runtime_root" ]]; then
    printf '== staging vendored Apple Container ==\n'
    ditto "$container_runtime_root" "$output_bundle/Contents/Resources/container"
fi

# A signed bundle is a bundle that can be shipped, and a shipped bundle whose
# SUPublicEDKey is empty would accept any appcast once Sparkle is wired in (#36).
# Refuse that combination here rather than discovering it after publication.
if [[ -n "$SIGNING_IDENTITY" && -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    printf 'SPARKLE_PUBLIC_ED_KEY is empty but the bundle is being signed for distribution.\n' >&2
    printf 'Set it in .env (see .env.example) and stage through the Taskfile.\n' >&2
    exit 1
fi

# Assert the provenance of the sidecar that actually landed in the bundle.
#
# socktainer stamps BUILD_GIT_COMMIT into itself (its Package.swift reads it,
# and prepare-v1-runtime.sh passes it), so the staged binary can be asked what
# it is instead of inferring it from some checkout's HEAD. Inferring was the
# earlier mistake: SOCKTAINER_BINARY can point anywhere, so a nearby checkout
# says nothing about what got copied. A release built by hand with a bare
# `swift build` reports "unspecified" and is refused here.
staged_socktainer_version="$("$output_bundle/Contents/Helpers/socktainer" --version 2>/dev/null || true)"
pinned_rev="$(grep -oE 'SOCKTAINER_REV="[0-9a-f]+"' "$ROOT/scripts/prepare-v1-runtime.sh" | cut -d'"' -f2)"

if [[ "$staged_socktainer_version" == *"$pinned_rev"* ]]; then
    printf 'socktainer: %s\n' "$staged_socktainer_version"
elif [[ -n "$SIGNING_IDENTITY" ]]; then
    printf 'Staged socktainer does not report the pinned revision %s.\n' "${pinned_rev:0:12}" >&2
    printf '  reported: %s\n' "${staged_socktainer_version:-<no version output>}" >&2
    printf '  staged from: %s\n' "$SOCKTAINER_BINARY" >&2
    printf 'Rebuild it with the stamp, e.g.\n' >&2
    printf '  BUILD_VERSION="containerstack-v1+%s" BUILD_GIT_COMMIT=%s \\\n' \
        "${pinned_rev:0:12}" "$pinned_rev" >&2
    printf '  BUILD_TIME="$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)" \\\n' >&2
    printf '    swift build --package-path <checkout> -c release\n' >&2
    printf 'or run scripts/prepare-v1-runtime.sh, which passes them for you.\n' >&2
    exit 1
else
    printf 'warning: staged socktainer does not report the pinned revision %s (reported: %s)\n' \
        "${pinned_rev:0:12}" "${staged_socktainer_version:-<none>}" >&2
fi

# `|` as the delimiter because the key is base64 and routinely contains `/`.
perl -pe "s/__APP_VERSION__/$APP_VERSION/g; s/__BUILD_NUMBER__/$BUILD_NUMBER/g; s|__SPARKLE_PUBLIC_ED_KEY__|$SPARKLE_PUBLIC_ED_KEY|g" \
    "$ROOT/Packaging/Info.plist" \
    > "$output_bundle/Contents/Info.plist"

runtime_path="$output_bundle/Contents/Helpers/ContainerStackRuntime"
install -m 0644 "$ROOT/Packaging/com.containerstack.runtime.plist.in" \
    "$output_bundle/Contents/Library/LaunchAgents/com.containerstack.runtime.plist"

plutil -lint "$output_bundle/Contents/Info.plist"
plutil -lint "$resource_bundle/Contents/Info.plist"
plutil -lint "$output_bundle/Contents/Library/LaunchAgents/com.containerstack.runtime.plist"

if [[ -n "$SIGNING_IDENTITY" ]]; then
    require_command codesign

    # The vendored runtime arrives signed by "Apple Inc. - Containerization".
    # Nested code under a different team identifier does not inherit our
    # bundle's designated requirement, so every Mach-O in it is re-signed with
    # ours. Deepest-first: signing a directory seals what is already inside it,
    # so an outer signature applied first is invalidated by the inner ones.
    #
    # `container-runtime-linux` is the one that boots the micro-VMs and is the
    # only binary upstream gives an entitlement. It keeps
    # com.apple.security.virtualization; nothing else asks for anything.
    container_dir="$output_bundle/Contents/Resources/container"
    vz_entitlements="$ROOT/Packaging/container-runtime.entitlements"

    if [[ -d "$container_dir" ]]; then
        printf '== re-signing vendored Apple Container ==\n'
        signed_count=0
        while IFS= read -r macho; do
            if [[ "$(basename "$macho")" == "container-runtime-linux" ]]; then
                codesign --force --options runtime --timestamp \
                    --entitlements "$vz_entitlements" \
                    --sign "$SIGNING_IDENTITY" "$macho"
            else
                codesign --force --options runtime --timestamp \
                    --sign "$SIGNING_IDENTITY" "$macho"
            fi
            signed_count=$((signed_count + 1))
        done < <(
            # Deepest paths first, so nested code is sealed before its container.
            find "$container_dir" -type f -perm -u+x -print0 \
                | xargs -0 file --mime-type 2>/dev/null \
                | awk -F': ' '$2 ~ /application\/x-mach-binary/ {print $1}' \
                | awk '{print gsub(/\//,"/"), $0}' \
                | sort -rn \
                | cut -d' ' -f2-
        )
        printf '   re-signed %d Mach-O files\n' "$signed_count"
    fi

    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
        "$output_bundle/Contents/Helpers/socktainer"
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
        "$output_bundle/Contents/Helpers/ContainerStackRuntime"
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
        "$output_bundle/Contents/MacOS/cstack"
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
        "$output_bundle"
    codesign --verify --deep --strict --verbose=2 "$output_bundle"
else
    printf 'Staged unsigned app bundle: %s\n' "$output_bundle"
    printf 'Set SIGNING_IDENTITY to sign the bundle with Developer ID.\n'
fi

printf 'Runtime helper: %s\n' "$runtime_path"
printf 'LaunchAgent: %s\n' \
    "$output_bundle/Contents/Library/LaunchAgents/com.containerstack.runtime.plist"
