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

## [0.3.0](https://github.com/bshk-app/ContainerStack/compare/v0.2.0...v0.3.0) (2026-08-24)


### Added

* **a11y:** label the icon-only row action buttons ([fede7a7](https://github.com/bshk-app/ContainerStack/commit/fede7a7034b1df7e84000f21a44e28c4fa662a93))
* **doctor:** report the host memory running containers have claimed ([0433e22](https://github.com/bshk-app/ContainerStack/commit/0433e2249fabcf02b612dca29ec101191751c5a3))
* **sidebar:** let users hide resource sections they do not use ([57616b7](https://github.com/bshk-app/ContainerStack/commit/57616b7fdac4a2aa1798018ecafad036604c1c26))


### Fixed

* **a11y:** give every icon action a contextual name ([b151eb9](https://github.com/bshk-app/ContainerStack/commit/b151eb94adcfec719ad175bb362762b1575ad102))
* **cstack:** stop claiming a restart that did not happen ([5c8608c](https://github.com/bshk-app/ContainerStack/commit/5c8608c90e1a1bfed34c2e44d8dde3d17da2ad2a))
* **http:** reject malformed chunk sizes instead of trapping ([9ebc39e](https://github.com/bshk-app/ContainerStack/commit/9ebc39e67a2a95d7f9b48f29b9d3555ccfb1789b))
* **images:** read Arch and OS from image inspect ([fb7f84d](https://github.com/bshk-app/ContainerStack/commit/fb7f84d4b132b938063bf1401581548808206248))
* **images:** show unknown instead of 1970 when Created is absent ([2b7540b](https://github.com/bshk-app/ContainerStack/commit/2b7540bea3f8b7228393fd23085a64929e034327))
* **memory:** report configured limits without overstating RSS ([038ec29](https://github.com/bshk-app/ContainerStack/commit/038ec29482a133332f4ea795d9b8b16e0cc0f327))
* **process:** bound drains held open by descendants ([808da22](https://github.com/bshk-app/ContainerStack/commit/808da225e28b934414aab4781c7f545d1adb3c02))
* **runtime:** give every subprocess wait a deadline ([39e4f77](https://github.com/bshk-app/ContainerStack/commit/39e4f77a1485e52606ff8a86e424a89919db0f7c))
* **runtime:** give runtime resolution a single owner ([00a3461](https://github.com/bshk-app/ContainerStack/commit/00a3461d0e21fc63fe8d21275dda6afd1f80892e))
* **runtime:** stop the bridge from filling runtime.log with request lines ([5356691](https://github.com/bshk-app/ContainerStack/commit/5356691ebc904b7139e3bc5b905e7e55c40a497d))
* **tests:** make service-message expiry deterministic ([deb1f14](https://github.com/bshk-app/ContainerStack/commit/deb1f148a86fe5d1036bebc93dc1ebf4c8d47d35))
* **ui:** confirm single-item deletes before destroying ([5ce79d4](https://github.com/bshk-app/ContainerStack/commit/5ce79d435cf15c628a12fe805fadc1b9b718315e))


### Changed

* **runtime:** remove the bypass around resolution ownership ([f965f38](https://github.com/bshk-app/ContainerStack/commit/f965f38040b738b035848c436694984274be42d9))
* **runtime:** stop spawning the container CLI on every monitor tick ([8c6377d](https://github.com/bshk-app/ContainerStack/commit/8c6377d2d8966cdadaf6a3acdb07afba37eae105))

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
