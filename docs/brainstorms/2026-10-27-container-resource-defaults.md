# Brainstorm: default CPUs and memory for containers without limits

Date: 2026-10-27
Status: validated

## Problem

A container that the Docker API creates without `HostConfig.Memory` or
`HostConfig.NanoCpus` gets the `[container]` defaults of Apple Container. When
no file sets them, the defaults are 4 CPUs and 1 GiB. buildx, compose and act
create containers this way. On 2026-10-27, a CI build made no progress for one
hour because its buildkit container had only 1 GiB.

The setting "Default Container Resources" applied only to the Run Container
sheet.

## Decisions

1. One store: `cpus` and `memory` in the `[container]` table of
   `$XDG_CONFIG_HOME/container/config.toml`. When `XDG_CONFIG_HOME` is not set,
   the file is `~/.config/container/config.toml`. socktainer, the `container`
   CLI and the Run Container sheet use these values. ContainerStack changes only
   these two lines. Other keys, tables and comments do not change.
2. New Docker API containers get a changed value after a bridge restart.
   Settings shows a notice and a Restart Docker Bridge button. ContainerStack
   does not restart the bridge automatically. A restart stops open builds, exec
   sessions and runner jobs.
3. The default for `memory` is a quarter of host memory in whole GiB, with a
   minimum of 2 GiB. The default for `cpus` is the number of host CPUs.
4. A hand-edited memory value keeps its exact bytes. Settings shows, for example,
   `1536m` as 1.5 GiB, and Run Container uses those same bytes. Only changing the
   memory control writes a new memory value; CPU edits leave its spelling alone.
   The memory control may write whole GiB when the user changes it.

## How it works

- `container system start` copies the user file to
  `~/Library/Application Support/com.apple.container/config/config.toml`, also
  when the API server runs. The runtime helper runs `container system start`
  each time it starts. socktainer, the Docker bridge, reads the copy one time
  and keeps the values until it stops.
- The bridge restart stops socktainer and starts the helper again, or runs
  `launchctl kickstart` when the LaunchAgent is registered. Containers continue
  to run and keep their size.
- The notice shows while the `[container]` values of the user file and of the
  copy are different.
- At launch, ContainerStack writes each key that the file does not set. It uses
  the value of the old `containerResourceDefaults.*` UserDefaults key if one
  exists. Otherwise it uses the default. Then it deletes the old keys.
  ContainerStack does not change a value that the file sets.
- ContainerStack does not edit a file where `container` is a dotted key or an
  inline table. A new `[container]` table makes such a file invalid.
- ContainerStack writes a temporary file and renames it. If the path is a
  symlink, the target gets the new content and the symlink stays.

## Memory commitment

Each container is one VM. socktainer reports the VM size in `HostConfig.Memory`,
so the Doctor sum includes the containers that got the default. Settings shows
the default as a percentage of host memory. It also shows the Doctor threshold
(`MemoryCommitment.approachingFraction`).

## Out of scope

- `CpuQuota` and `CpuPeriod` (buildx `cpu-quota`) do not change the CPU count.
- `launchctl kickstart` fails without a message when launchd does not have the
  agent. This also affects Restart.
