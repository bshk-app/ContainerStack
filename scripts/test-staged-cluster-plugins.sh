#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bundle="$work/ContainerStack.app"
plugins="$bundle/Contents/Resources/container/libexec/container/plugins"
check="$root/check-staged-cluster-plugins.sh"

executables=(
    cluster/bin/cluster
    cluster/resources/cluster-shim
    cluster-hoststore/bin/cluster-hoststore
    container-core-clusters/bin/container-core-clusters
)
files=(
    "${executables[@]}"
    cluster/config.toml
    cluster/resources/kindnet.yaml
    cluster-hoststore/config.toml
    container-core-clusters/config.toml
)

for path in "${files[@]}"; do
    mkdir -p "$(dirname "$plugins/$path")"
    printf 'fixture\n' > "$plugins/$path"
done
for path in "${executables[@]}"; do
    chmod 755 "$plugins/$path"
done

# ELF64 little-endian, ET_EXEC, EM_AARCH64, one PT_LOAD and no interpreter.
shim="$plugins/cluster/resources/cluster-shim"
{
    printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000\267\000\001\000\000\000'
    printf '\000\000\000\000\000\000\000\000\100\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\100\000\070\000\001\000\000\000\000\000\000\000'
    printf '\001\000\000\000'
    dd if=/dev/zero bs=1 count=52 2>/dev/null
} > "$shim"

expect_failure() {
    local path="$1" output
    if output="$("$check" "$bundle" 2>&1)" || [[ "$output" != *"$path"* ]]; then
        printf 'Expected a staging error naming %s. Output: %s\n' "$path" "$output" >&2
        exit 1
    fi
    printf '%s\n' "$output"
}

"$check" "$bundle"
for path in "${files[@]}"; do
    mv "$plugins/$path" "$work/missing"
    expect_failure "$path"
    mv "$work/missing" "$plugins/$path"
done
for path in "${executables[@]}"; do
    chmod a-x "$plugins/$path"
    expect_failure "$path"
    chmod 755 "$plugins/$path"
done
printf 'not an ELF\n' > "$shim"
expect_failure cluster/resources/cluster-shim

printf 'Passed 14 staging cases (1 valid, 8 missing, 4 non-executable, 1 invalid shim).\n'
