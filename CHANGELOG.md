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

## [0.5.1](https://github.com/bshk-app/ContainerStack/compare/v0.5.0...v0.5.1) (2026-08-30)


### Fixed

* **app:** clear the liveness filter whenever health is published ([1708051](https://github.com/bshk-app/ContainerStack/commit/1708051b80ed9e5a3e1a458860701e6fa80490ff))
* **app:** drop the inventory a failed runtime described ([6055e63](https://github.com/bshk-app/ContainerStack/commit/6055e632110a36c29562c78a3fd1d2bb07071540))
* **app:** drop the inventory a failed runtime described ([ac76c13](https://github.com/bshk-app/ContainerStack/commit/ac76c13c5cfddc212c632ad74b2a8f631112b362)), closes [#39](https://github.com/bshk-app/ContainerStack/issues/39)
* **app:** finish the class — stack statuses and the startup probes ([d32a26e](https://github.com/bshk-app/ContainerStack/commit/d32a26e6c138932912de663efb9cf4ee7d43cc90))
* **app:** let an explicit runtime failure outrank Starting ([897744b](https://github.com/bshk-app/ContainerStack/commit/897744b38fc11fa7ffe8dc36c0b48c622bc564ae))
* **app:** let an explicit runtime failure outrank Starting ([965d945](https://github.com/bshk-app/ContainerStack/commit/965d945c075367ffcdeae4b3100da601a070219d)), closes [#44](https://github.com/bshk-app/ContainerStack/issues/44)
* **app:** make an unresolved Lucide asset loud instead of blank ([0df025a](https://github.com/bshk-app/ContainerStack/commit/0df025a4415406833d9606e9bfa8f5f579fec3d4))
* **app:** make an unresolved Lucide asset loud instead of blank ([bd52beb](https://github.com/bshk-app/ContainerStack/commit/bd52beb2512eb9ad57fe0b9d0e597b53b840a285)), closes [#14](https://github.com/bshk-app/ContainerStack/issues/14)
* **app:** one unanswered probe no longer declares the runtime dead ([7b046b0](https://github.com/bshk-app/ContainerStack/commit/7b046b006938a94dc9166efab71d8be4a1b11789))
* **app:** one unanswered probe no longer declares the runtime dead ([d26cd66](https://github.com/bshk-app/ContainerStack/commit/d26cd66a4311a7f16c7a755afd1358b679d7f85f))
* **app:** re-check the epoch before publishing a socket as responding ([0b423d8](https://github.com/bshk-app/ContainerStack/commit/0b423d80e3d243a8c5b69ae7383dd45825330c94))
* **app:** stop a dead runtime's inventory and health surviving its death ([cc45b09](https://github.com/bshk-app/ContainerStack/commit/cc45b0960a270e504187176acacefbc83675343d))
* **app:** stop an in-flight refresh resurrecting cleared inventory ([3b27ecc](https://github.com/bshk-app/ContainerStack/commit/3b27eccb8ae9f386d6190aa7e19633e4c357ede9)), closes [#43](https://github.com/bshk-app/ContainerStack/issues/43)
* **cli:** do not treat a missing routing table as NO ROUTE ([740ab2d](https://github.com/bshk-app/ContainerStack/commit/740ab2df7765d64f1928e7a3bb7d3027e454a0e6))
* **cli:** do not treat a missing routing table as NO ROUTE ([9c59866](https://github.com/bshk-app/ContainerStack/commit/9c598665099e9bc70d5ea61fc3e12715d2c21c2f))
* **cli:** judge only the networks a published port depends on ([6d06092](https://github.com/bshk-app/ContainerStack/commit/6d06092df70872f64967b4d5a325244442bfbf19))
* **cli:** judge only the networks a published port depends on ([5a5202e](https://github.com/bshk-app/ContainerStack/commit/5a5202e3afc0a61e7cb4e6bbe2d048c8409862c8)), closes [#36](https://github.com/bshk-app/ContainerStack/issues/36)
* **cli:** tell "nothing publishes" apart from "nothing could be checked" ([31a02f0](https://github.com/bshk-app/ContainerStack/commit/31a02f00955e282823614977943d5a1b56ecbed5))
* **cli:** tell "nothing publishes" apart from "nothing could be checked" ([bd89318](https://github.com/bshk-app/ContainerStack/commit/bd893182d98186c17ac4bf8c3a61efa93f3ee739)), closes [#45](https://github.com/bshk-app/ContainerStack/issues/45)
* **compose:** give the validation temp file a unique name ([40f6f2e](https://github.com/bshk-app/ContainerStack/commit/40f6f2e3071bb62bb97829c6f76cb95daed3573d))
* **compose:** give the validation temp file a unique name ([2fa9a29](https://github.com/bshk-app/ContainerStack/commit/2fa9a29faaacf94cea7ad6bd8b1d9211d8bad80c)), closes [#63](https://github.com/bshk-app/ContainerStack/issues/63)
* **compose:** keep the validation temp name within the filename limit ([6b31c68](https://github.com/bshk-app/ContainerStack/commit/6b31c6820fcedeb316271a7ceb099e04987b99bb))
* **core:** treat an empty subnet as uncheckable, not unroutable ([4c8f91e](https://github.com/bshk-app/ContainerStack/commit/4c8f91e7a88b0ad80cdc6c443f19f242a643795f))
* **hooks:** close five holes cross-model review found in the comment gate ([a265ead](https://github.com/bshk-app/ContainerStack/commit/a265eade3d181b94f94416d18212219205d0d884))
* **hooks:** make the gate path-safe and stop it from looping on a bad payload ([574f36e](https://github.com/bshk-app/ContainerStack/commit/574f36e7737b866e36a2de607501fbb36b77439a))
* **http:** bound failed run cleanup ([8084343](https://github.com/bshk-app/ContainerStack/commit/808434364caa8c1e8dfec39ef073501f85828708))
* **http:** give run() the same VM lifecycle timeout as start and delete ([15c4a23](https://github.com/bshk-app/ContainerStack/commit/15c4a2301614bab6e3734c13e54330e210641c44))
* **http:** give run() the same VM lifecycle timeout as start and delete ([7f7e29c](https://github.com/bshk-app/ContainerStack/commit/7f7e29c94e776fb22bc0ff9695702b0eaa0c0565))
* **runtime:** ask the containers to exit before stopping the service ([0b55d3a](https://github.com/bshk-app/ContainerStack/commit/0b55d3ab914758e18c70e14342fc160a0dfbc10b))
* **runtime:** ask the containers to exit before stopping the service ([8bd9910](https://github.com/bshk-app/ContainerStack/commit/8bd9910526b9edca8ade440162767a1d9af19541)), closes [#55](https://github.com/bshk-app/ContainerStack/issues/55)
* **runtime:** fail the candidate when dup2 does not redirect ([615f6f3](https://github.com/bshk-app/ContainerStack/commit/615f6f32f654f957bd27888e5c1a6b29ddd3822f))
* **runtime:** stop the helper running blind when its log cannot be opened ([5690ea8](https://github.com/bshk-app/ContainerStack/commit/5690ea8d5d8055dc4b884f1f03877233ffef06e9))
* **runtime:** stop the helper running blind when its log cannot be opened ([108a922](https://github.com/bshk-app/ContainerStack/commit/108a922516736812546b4457652220d616e62124)), closes [#10](https://github.com/bshk-app/ContainerStack/issues/10)

## [0.5.0](https://github.com/bshk-app/ContainerStack/compare/v0.4.2...v0.5.0) (2026-08-27)

Containers can be sized now, and a stop that loses the runtime's XPC service no
longer hangs the app with no way out.

### Added

- Global CPU and memory defaults in Settings, clamped to this Mac's capacity,
  and per-container overrides in the image Run dialog. Apple Container gives
  every container its own VM, and until now each one got the runtime's built-in
  4 CPUs and 1 GiB. The values travel as Docker's `HostConfig.Memory` and
  `HostConfig.NanoCpus`. Fractional CPUs are deliberately not offered: the
  bridge floors them to whole vCPUs, so 0.5 would silently become 1. `cstack`
  keeps its previous behaviour and passes no limits.

### Fixed

- Stopping a container no longer hangs on "Stopping…" indefinitely. Measured
  cause: Apple Container's API server had lost its XPC service, so both stop and
  kill answered HTTP 500 "XPC connection error: Connection interrupted" and
  every later ping answered "Connection invalid", while the app waited out the
  full lifecycle timeout. Stop now pins the daemon's grace window at five
  seconds, bounds its own wait, and treats 304 and 404 as the requested end
  state rather than a failure.
- A lost connection is repaired once instead of repeatedly. The health monitor
  is the only owner of restarts and first proves the API server is really gone
  with `container system status`, so a single transient ping timeout can no
  longer cycle a stack that is serving traffic. A recovery that fails ends the
  startup window, so the manual restart stays available instead of the sidebar
  sitting in a starting state with nothing to click.

### Known limitations

Published ports still require a runtime restart if a bridge-created network's
vmnet helper dies; restarting only the containers does not repair the host route.
The per-container micro-VM architecture also remains slower than OrbStack on the
measured M1 system (4.6x container round trip, 3.6x bind-mount writes).

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
