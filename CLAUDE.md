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

## Style, hooks and the language server

```bash
task hooks:install  # once per clone - git does not carry hooks
task lint           # exactly what CI runs
task format         # swift format in place, then swiftlint --fix
```

Layout belongs to `swift-format` (`.swift-format`); `.swiftlint.yml` keeps size,
complexity and naming and delegates the layout rules, because with both tools
enforcing layout the formatter's own output became SwiftLint findings.

Comment length is gated on **added** lines only: this hook stops an agent at 8
added comment lines in one block and warns a human at 10. Existing long blocks
carry measured detail and are deliberately never flagged.

`sourcekit-lsp` runs with background indexing on, but its cross-file index still
lags an edit: **after a rename or any cross-file change, run `swift build`
before trusting LSP diagnostics or a "rename applied" report** - a stale index
has already claimed a rename landed while the old names were still on disk.

## Release

Merge the release PR release-please keeps open. It bumps `VERSION` and drafts a
`CHANGELOG.md` section; the prose in that section is the release, so rewrite it
before merging. Merging tags the commit and creates a draft. CI signs and uploads
the DMG, then publishes the complete release; publishing an empty release first
would make it immutable. `task release` remains the local path.

```bash
task release            # local publish
task release PUBLISH=0  # local draft, safe pipeline test
```

- **Version SSOT** — marketing version in `VERSION`, written by release-please;
  build number is `BUILD_NUMBER_BASE + git rev-list --count HEAD` via
  `scripts/build-number.sh`. The base preserves monotonic Sparkle versions after
  the sanitized history reset. Never hand-set a build number; each publish needs
  a new commit, which the release PR provides.
- **Release-notes SSOT** — `CHANGELOG.md`. The generated lines are commit
  subjects: precise for a reviewer, useless in a Sparkle "What's new" panel, so
  they are a starting point rather than the release. CI syncs the GitHub release
  body from the file, and the same bytes reach the appcast.
- The build is *called* by the release-please workflow, not triggered by the
  release: a release created with `GITHUB_TOKEN` starts no workflow, and the
  alternative is a long-lived PAT this repo does not need.
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
| Signing | Developer ID Application; the team and identity live in `CLAUDE.local.md` |
| Appcast | `https://bshk-app.github.io/ContainerStack/appcast/stable.xml` (gh-pages) |
| Landing | `https://containerstack.bshk.app` |
| Source | MIT. The product has no license check; GitHub hosts every artifact. |
