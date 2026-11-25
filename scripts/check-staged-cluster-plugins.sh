#!/usr/bin/env bash
set -euo pipefail

plugins="$1/Contents/Resources/container/libexec/container/plugins"

for path in \
    cluster/bin/cluster \
    cluster/resources/cluster-shim \
    cluster-hoststore/bin/cluster-hoststore \
    container-core-clusters/bin/container-core-clusters; do
    if [[ ! -f "$plugins/$path" || ! -x "$plugins/$path" ]]; then
        printf 'error: missing or non-executable staged plugin file: %s\n' "$plugins/$path" >&2
        exit 1
    fi
done

for path in \
    cluster/config.toml \
    cluster/resources/kindnet.yaml \
    cluster-hoststore/config.toml \
    container-core-clusters/config.toml; do
    if [[ ! -f "$plugins/$path" ]]; then
        printf 'error: missing staged plugin file: %s\n' "$plugins/$path" >&2
        exit 1
    fi
done

shim="$plugins/cluster/resources/cluster-shim"
description="$(LC_ALL=C file -b "$shim")"
case "$description" in
    'ELF 64-bit LSB executable, ARM aarch64,'*'statically linked'*) ;;
    *)
        printf 'error: %s must be a static aarch64 ELF executable; found %s\n' "$shim" "$description" >&2
        exit 1
        ;;
esac
