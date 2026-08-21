# Changelog

All notable changes to ContainerStack are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

This file is the single source of truth for release notes: `task release`
extracts the `## [<version>]` section matching `VERSION` and ships it as the
Sparkle update description. A publish with no matching section is refused.

## [Unreleased]

## [0.1.0] - 2026-08-20

First distributed build. Everything below is verified end to end on Apple
Silicon; see `docs/ROADMAP.md` for what is deliberately not here yet.

### Added

- Apple Container 1.2.2 supervised by a bundled runtime helper, with socktainer
  shipped as a sidecar in `Contents/Helpers`.
- A Docker-compatible socket at `~/.socktainer/container.sock`; the app can
  register it as the `containerstack` Docker context when the user opts in.
- `docker` and `docker compose` work unmodified: networks, volumes, published
  ports, `exec`, and `down -v`.
- `cstack`, covering ps, inspect, logs, start/stop/restart/rm, run, images,
  pull, rmi, volumes, networks, df, prune, context, and compose.
- App surfaces for overview, containers grouped by Compose project, images with
  pull/run/delete, volumes, networks, and a runtime panel with polled state.
- A LaunchAgent that keeps the runtime alive without the GUI running.

### Known limitations

- Published ports stop working until the runtime is restarted, when a
  bridge-created network's vmnet helper dies. Restarting the *containers* does
  not help and loses their addresses; the app and `cstack doctor` both say so.
  The root cause sits in Apple's daemon, which owns the re-attach.
- Slower than OrbStack on an idle M1/16 GiB: container round trip 4.6x, bind
  mount writes 3.6x. The gap is architectural — Apple Container boots one
  micro-VM per container.

[Unreleased]: https://github.com/bshk-app/ContainerStack/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/bshk-app/ContainerStack/releases/tag/v0.1.0
