# Changelog

All notable changes to ContainerStack are recorded here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

This file is the single source of truth for release notes: the section matching
`VERSION` becomes both the Sparkle update description and the GitHub release
body. A publish with no matching section is refused.

release-please drafts each section from conventional commits and opens a release
PR. Those lines are commit subjects; rewrite them in the PR into what a user
should read in an update panel. Notes jotted under `## [Unreleased]` between
releases belong in that section — move them there while reviewing.

## [0.3.0](https://github.com/bshk-app/ContainerStack/compare/v0.2.0...v0.3.0) (2026-08-23)


### Added

* publish ContainerStack 0.1.0 source snapshot ([85e97c2](https://github.com/bshk-app/ContainerStack/commit/85e97c2c07125fc46f49162b54f71525311510aa))
* **release:** move Sparkle enclosures to GitHub assets ([e1e13ca](https://github.com/bshk-app/ContainerStack/commit/e1e13ca8a332f7bc8eba5b3f0ffac70dfb077b1c))
* **release:** serve updates from GitHub, drop the release server ([eed5e96](https://github.com/bshk-app/ContainerStack/commit/eed5e9646f224079669dc892da820d2e48583208))


### Fixed

* **ci:** repair the invalid release workflow and lint for the cause ([b3710a7](https://github.com/bshk-app/ContainerStack/commit/b3710a78048b5f50616e0538a35440b9452be40a))
* **release:** put the release notes back in the update panel ([50abe1b](https://github.com/bshk-app/ContainerStack/commit/50abe1b9c14dd90d117fbe8276b6fcb018136f05))
* **release:** stop a false preflight from blocking every CI release ([4d82ebb](https://github.com/bshk-app/ContainerStack/commit/4d82ebb6ea6c26a2ef23735edf913f6650774bcc))
* **release:** two silent failures on the repair and beta paths ([53dcccf](https://github.com/bshk-app/ContainerStack/commit/53dcccf0249e2a91d25af331909cfe7266b3ec56))

## [0.2.0](https://github.com/bshk-app/ContainerStack/compare/v0.1.0...v0.2.0) (2026-08-23)

Updates now come from GitHub. Nothing in the app itself changed: no file under
`Sources/` differs from 0.1.0, and the only edit to the shipped bundle is the
update feed it points at.

### Changed

- Updates are served from a signed feed on GitHub Pages, and the DMG is a GitHub
  Release asset. Both used to come from a server that had to be reachable for an
  update to be found at all; now the artifact lives where the source does.
- The update signing key was rotated as part of the move, so this build trusts a
  different key than 0.1.0 did.

### Known limitations

Unchanged from 0.1.0, and still the two worth knowing before installing:
published ports stop working until the runtime is restarted when a
bridge-created network's vmnet helper dies, and ContainerStack is slower than
OrbStack on an idle M1/16 GiB — container round trip 4.6x, bind mount writes
3.6x, because Apple Container boots one micro-VM per container.

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
