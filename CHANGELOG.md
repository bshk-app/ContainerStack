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

## [0.4.2](https://github.com/bshk-app/ContainerStack/compare/v0.4.1...v0.4.2) (2026-08-26)

ContainerStack now owns a Docker socket separate from a standalone Socktainer
installation. Upgrading moves the app and its Docker context without stopping or
removing a bridge you run yourself.

### Changed

- The app, `cstack`, Docker context, and verification tools now use
  `~/.containerstack/docker.sock` instead of `~/.socktainer/container.sock`.
  An active `containerstack` Docker context is refreshed during the upgrade. If
  you set `DOCKER_HOST` yourself, update it to the new path.
- The bundled bridge explicitly owns startup housekeeping for the shared Apple
  Container runtime. Homebrew cleanup removes only ContainerStack's state and
  no longer treats `~/.socktainer` as app-owned data.

### Fixed

- Upgrading retires the old bundled bridge before starting its replacement. The
  migration matches both the exact helper path inside ContainerStack.app and the
  old argument list, waits for that process to exit, and aborts safely if it
  cannot confirm retirement. A standalone Socktainer process is left running.

### Known limitations

Published ports still require a runtime restart if a bridge-created network's
vmnet helper dies; restarting only the containers does not repair the host route.
The per-container micro-VM architecture also remains slower than OrbStack on the
measured M1 system (4.6x container round trip, 3.6x bind-mount writes).

## [0.4.1](https://github.com/bshk-app/ContainerStack/compare/v0.4.0...v0.4.1) (2026-08-25)

Starting and stopping containers works again on a machine where another Docker
bridge got there first, and one slow container no longer freezes the rest.

### Fixed

- Another program listening on the Docker socket is now named instead of adopted.
  A bridge from a different build answers every status check while start and stop
  hang - measured past 150 seconds against a container the bundled bridge started
  in 2 - so the app reported a healthy engine while nothing could be controlled.
  It now says which socket is held and what to do, keeps saying it while it is
  true, and stops offering the actions that cannot succeed. Listing containers and
  reading their logs keep working, since that is what you need at that point.
- Acting on one container no longer disables every other one. Stopping can take
  the full two-minute timeout, and for that whole time no other container could be
  started, stopped, deleted or have its logs opened - and a click on a different
  container did nothing at all, without a word.
- Quitting no longer leaves runtime commands running. A command the app was
  waiting on used to survive the app that started it: eight of them were found on
  one machine, the oldest four days old, each wedged and invisible. The Docker
  bridge is unaffected and still outlives the app on purpose.

## [0.4.0](https://github.com/bshk-app/ContainerStack/compare/v0.2.0...v0.4.0) (2026-08-24)

The app can finally update itself. Beyond that: runtime control is harder to
wedge, destructive actions are harder to trigger by accident, and diagnostics
are more honest.

### Added

- In-app updates. Every build since 0.1.0 advertised an update feed and the
  signed feed has been live the whole time, but nothing read it: there was no
  Sparkle, no menu item, and no way to learn a new version existed. "Check for
  Updates…" now sits in the app menu and the menu bar. Checking happens on its
  own; installing waits for you, because replacing the app while containers run
  is not a decision to make on your behalf.
- Docker sections can be hidden from the sidebar through its context menu. Even
  with every Docker item hidden, the same menu remains available to restore them.
- `cstack doctor` reports the configured memory limits of running containers
  against host memory. Unlimited containers and failed inspections are named
  separately instead of being counted as zero.
- Every icon-only action has a descriptive, resource-specific VoiceOver name.

### Fixed

- Releases carry their download again. 0.3.0 was published before its DMG was
  built, and GitHub freezes a release's files the moment it is published, so
  that version shipped empty and could not be repaired. The installer is now
  attached while the release is still a draft, and publishing is the last step.
- Every subprocess wait now has an explicit deadline, except the deliberately
  supervised socktainer process. A child that hangs — or exits while a descendant
  keeps its output pipe open — can no longer wedge monitoring and runtime controls
  forever.
- `cstack runtime restart` continues best-effort recovery after a failed step,
  names each failure, and exits non-zero instead of claiming success.
- GUI, helper, `cstack runtime`, and `cstack doctor` resolve the Apple Container
  binary and its install root through one owner. Environment overrides and the
  vendored runtime no longer apply to only part of the system.
- The bridge no longer writes an INFO request line for every 3-second poll into
  `runtime.log`; warnings, errors, startup and DNS fallback messages remain.
- Deleting a container, image, volume, or network now requires confirmation.
  In-use volumes are not force-deleted.
- Malformed chunked HTTP sizes return a parse error instead of trapping on
  integer overflow or a reversed range.
- Image creation time reports unknown when the runtime returns zero, rather than
  “56 years ago”. Architecture and OS now come from image inspect, the endpoint
  that actually provides them.

### Changed

- The expensive missing-app-root diagnostic runs at most every 30 seconds
  instead of spawning the `container` CLI on every 3-second monitor tick. Manual
  refresh still probes immediately.

### Known limitations

Published ports still require a runtime restart if a bridge-created network's
vmnet helper dies; restarting only the containers does not repair the host route.
The per-container micro-VM architecture also remains slower than OrbStack on the
measured M1 system (4.6x container round trip, 3.6x bind-mount writes).

## 0.3.0

Never released: it was published without its installer and cannot be rebuilt
under that tag. Everything intended for it ships in 0.4.0 above.

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
