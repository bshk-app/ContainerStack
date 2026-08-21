# ContainerStack

Native macOS container stack on Apple Container, exposing a Docker-compatible
socket. Swift 6, SwiftPM for the build, Tuist only for local Xcode work.

## Layout

| Path | What it is |
|---|---|
| `Sources/ContainerStackApp` | SwiftUI app (dashboard + menu bar) |
| `Sources/ContainerStackCore` | Shared client and models |
| `Sources/CStackCLI` | `cstack` |
| `Sources/ContainerStackRuntime` | Runtime supervisor helper, shipped in `Contents/Helpers` |
| `Packaging/` | `Info.plist` template, `.icns`, LaunchAgent template |
| `Distribution/Homebrew/` | Cask metadata consumed by `zamokctl cask` |

## Build

```bash
task build          # debug
task test           # swift test
task build:app      # stage an unsigned .app
task build:signed   # stage a Developer ID signed .app
```

The app bundle is assembled by `scripts/stage-containerstack-app.sh`, not by
Xcode. **`Project.swift` is development-signed and its copy phase is not
equivalent to the staging script** — never treat a plain Tuist Release build as a
distribution artifact (signing audit, gap 6).

`socktainer` is a sidecar built from a pinned fork by
`scripts/prepare-v1-runtime.sh`. That script stops the Apple Container service
and moves its data directory aside, so it is user-run and never called by a
build task. `task runtime:check` verifies the checkout is at the pin.

## Release

One command, everything from `.env` plus the committed `VERSION`:

```bash
task release            # publish
task release PUBLISH=0  # draft, safe pipeline test
```

- **Version SSOT** — marketing version in `VERSION`; build number is
  `BUILD_NUMBER_BASE + git rev-list --count HEAD` via `scripts/build-number.sh`.
  The base preserves monotonic Sparkle versions after the sanitized history
  reset. Never hand-set a release build number; each publish needs a new commit.
- **Release-notes SSOT** — `CHANGELOG.md`. Move entries from `## [Unreleased]`
  into `## [<version>]` before releasing; a publish without that section is
  refused. One extractor produces `out/release-notes.md`; both Sparkle and
  GitHub Releases consume that exact file.
- **DMG assembly, signing, notarization and stapling happen inside `zamokctl`.**
  The staging script only assembles an unsigned `.app` for the release path.
  Do not add parallel `hdiutil`, codesign, or notarytool release steps.
- **The Homebrew cask is Zamok's job, not this repo's.** Publishing a release
  regenerates and pushes it server-side, from the org's `HomebrewTapConfig` plus
  the product's `CaskConfig`. There is deliberately no cask metadata file, no tap
  token and no `zamokctl cask` call here — `zamokctl cask` exists for products
  released outside the API, which this is not.
- GitHub Releases is the durable DMG store. Zamok verifies the GitHub bytes,
  repoints and signs the Sparkle appcast, regenerates the cask, then deletes its
  temporary enclosure object. Apple credentials never enter GitHub Actions.

## Secrets

`agentvault.yaml` is local-only (gitignored). `task signing:notary-profile`
resolves the 1Password references once and stores a validated notarytool profile
in the release Mac's Keychain. `.env` holds `av://` references, never literal
values, and release tasks run under `av env` so nothing resolves to disk.

## Skills

Zamok release skills live outside this repo. Point `.claude/skills/` at them
locally if you need them; they are not shipped.


## Product facts

| | |
|---|---|
| Bundle id | `app.bshk.containerstack` |
| Team | `Q8H6GWJ658` |
| Signing identity | Developer ID Application (SHA1 `2A2950821B52BF1AC289AC2ED60F8740732FCCC6`) |
| Appcast | `https://bshk-app.github.io/ContainerStack/appcast/stable.xml` (gh-pages) |
| Landing | `https://containerstack.bshk.app` |
| Source | MIT. The product has no license check; GitHub hosts every artifact. |

## Not yet wired

In-app updates (#36). The feed URL and `SUPublicEDKey` are already in the
`Info.plist` template and the staging script refuses to sign a bundle with an
empty key, but the Sparkle framework itself is not embedded and there is no
updater UI. That is deliberate sequencing: it depends on a signed release and a
populated channel existing first.
