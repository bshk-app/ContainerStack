# scripts

## Build and release

Driven by `Taskfile.yml` — see `task --list`.

| | |
|---|---|
| `build-number.sh` | `BUILD_NUMBER_BASE` + commit count, the Sparkle build number |
| `check-socktainer.sh` | reports which socktainer binary would be staged |
| `stage-containerstack-app.sh` | assembles the unsigned `.app`; the release path's only stager |
| `stage-signed.sh` | standalone Developer ID `.app`, outside the Zamok pipeline |
| `extract-release-notes.sh` | the `CHANGELOG.md` section for a version |
| `write-release-manifest.sh` | records what was released, for GitHub to verify against |
| `release.sh` | the whole release: package, GitHub asset, signed feed, cask |
| `publish-github-release.sh` | GitHub Release mirror |
| `publish-appcast.sh` | zamokctl signs the DMG into the gh-pages Sparkle feed |
| `publish-cask.sh` | zamokctl renders and pushes the Homebrew cask (needs a tap token) |
| `configure-notary-profile.sh` | one-time notarytool keychain profile |

## Runtime preparation

| | |
|---|---|
| `prepare-v1-runtime.sh` | builds socktainer at the pin; stops the Apple Container service, so it is user-run |
| `prepare-container-runtime.sh` | fetches and verifies a vendored Apple Container runtime |

## Verification harnesses

Not part of any build. These produced the numbers and limitations stated in
`CHANGELOG.md` and `docs/ROADMAP.md`; they are kept so those claims can be
re-measured rather than trusted.

| | |
|---|---|
| `smoke-test.sh` | end-to-end pass over the Docker-compatible socket |
| `verify-stacks.sh` | Stacks acceptance; throwaway project, own `cstack-verify-*` names |
| `verify-network-recovery.sh` | whether restarting containers or the runtime restores published ports (one arm per run) |
| `verify-exit-code-durability.sh` | exit codes survive a bridge restart; own bridge, socket and data root |
| `scratch-runtime.sh` | disposable daemon + bridge on a temp root, because measuring damages a real runtime |
| `benchmark-runtime.sh` | benchmarks one runtime through its socket |
| `benchmark-compare.sh` | OrbStack vs ContainerStack, back to back |
| `prepare-benchmark-host.sh` | sets a host up for that comparison |
| `apiv2-conformance.sh` | Podman's Docker-compat suite against any socket |
| `docker-api-coverage.sh` | Docker Engine API endpoint coverage |
| `api-diff.py`, `api-scenarios.json` | response diff between two daemons |
