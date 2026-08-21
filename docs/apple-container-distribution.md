# Shipping Apple Container with ContainerStack

ContainerStack supervises Apple Container; it does not install it. That leaves a
question every distribution channel has to answer separately: **how does the
user end up with the version this build was tested against?**

The pin lives in two places that must agree:

| | |
|---|---|
| `scripts/prepare-v1-runtime.sh` | `SOCKTAINER_REV` — the bridge |
| `RuntimeProcessConfiguration.pinnedContainerVersion` | Apple Container, currently `1.2.2` |

## Why a plain Homebrew dependency is not enough

Homebrew has no way to express a version constraint. `depends_on formula:
"container"` installs whatever homebrew-core holds that day. When Apple
Container's API moves, an unrelated `brew upgrade` breaks ContainerStack on a
machine nobody touched — and it breaks *silently*, because the cask cannot state
a version and Homebrew believes it did its job.

There are exactly two ways to make the pin reach a user.

---

## Channel 1 — Homebrew, via a versioned formula (current default)

Homebrew's own answer to pinning is to put the version in the formula's **name**:
`node@20`, `postgresql@16`. So the tap carries `container@1.2.2`.

The formula lives in `bshk-app/homebrew-tap` as `Formula/container@1.2.2.rb` and
**only** there — a second copy in this repo would be one more pin to drift out of
sync, which is the failure this whole page exists to prevent. The link back to
the source is `RuntimeProcessConfiguration.pinnedContainerVersion`, which must
name the same version.

Note what is and is not generated. Zamok renders the **cask** for this product
from its `CaskConfig`, so nothing about the cask belongs in this repo. The
formula is a third-party dependency Zamok knows nothing about, so it is written
by hand. Two properties of it matter:

- **`keg_only :versioned_formula`** keeps it out of `PATH`, so it never shadows
  or conflicts with a homebrew-core `container`. Both can be installed at once.
- It installs **Apple's signed release package**, not a source build.
  homebrew-core's formula runs `swift build` with Xcode 26 as a build
  dependency — minutes on a user's machine, and a toolchain most users of a GUI
  app do not have.

The dependency is declared on the Zamok product, not in a file here: set
`CaskConfig.dependsOnFormulae` to `["bshk-app/tap/container@1.2.2"]` and the
generated cask carries `depends_on formula:` on the next regeneration. The app
finds the formula at the stable
`/opt/homebrew/opt/container@1.2.2/bin/container`, which is first in
`RuntimeProcessConfiguration.containerSearchPaths`.

Bumping the version means a new formula file, a new `pinnedContainerVersion`, and
one line in the cask. Users who have not upgraded keep the old formula.

Cost: ~30 MB DMG, one artifact, one notarization.

---

## Channel 2 — a standalone `.app`, via vendoring

Outside Homebrew nothing can guarantee the version, so the app carries its own
copy. Turn it on with an environment variable:

```bash
./scripts/prepare-container-runtime.sh          # fetch + verify + unpack, once
VENDOR_CONTAINER_RUNTIME=1 task build:signed    # stage it into the bundle
```

`prepare-container-runtime.sh` downloads Apple's signed pkg, checks it against a
pinned sha256, expands it into a cache, and adds `LICENSE` and `NOTICE.md`.
`stage-containerstack-app.sh` then copies that tree into the bundle and re-signs
it.

Cost: the bundle goes from ~30 MB to **~494 MB**, and notarization takes
proportionally longer.

### Four things that are not obvious

**It goes in `Contents/Resources`, not `Contents/Helpers`.** Under `Helpers`,
codesign walks the plugin tree as nested code, reaches a `config.toml` sitting
beside `bin/<plugin>`, and **refuses to sign the bundle at all** — leaving the
linker's ad-hoc signature in place. Verification then fails pointing at
`config.toml`, which is not the problem. Under `Resources` the same tree is
sealed as resources while its Mach-O keep their own signatures.

**Apple's pkg contains no licence.** Neither `LICENSE` nor `NOTICE.md` ships in
the installer, and Apache-2.0 §4a and §4d require both to accompany a
redistributed binary. They are fetched from the source tree at the same tag —
pinned to the tag, not a branch, so the text matches the binaries beside it.
`prepare-container-runtime.sh` refuses to produce a tree without them, and its
"already prepared" check requires them too: an earlier run that died between
unpacking and the licence fetch leaves a tree that runs fine and cannot legally
ship.

**One binary needs an entitlement.** `container-runtime-linux` boots the
micro-VMs and carries `com.apple.security.virtualization`. A Developer ID
certificate can sign it with no provisioning profile — verified on a real signed
build. Nothing else in the tree asks for anything, and the entitlements plist
must carry no XML comments or AMFI rejects it.

**Re-sign deepest-first.** The tree arrives signed by "Apple Inc. -
Containerization". Nested code under a different team identifier does not
inherit our bundle's designated requirement, so every Mach-O is re-signed with
ours — innermost first, because signing a directory seals what is already inside
it.

### Relocation is supported, not a trick

`container system start` takes `--install-root`, `--app-root` and `--log-root`;
Homebrew's own package relocates the runtime the same way. When the vendored copy
is present, `RuntimeProcessConfiguration.containerInstallRoot` is set and the flag
is passed. For a system install the flag is **omitted rather than emptied** — that
copy already knows its own root, and naming a wrong one sends the daemon looking
for plugins that are not there.

---

## Choosing

| | Homebrew | Standalone |
|---|---|---|
| Artifact | ~30 MB | ~494 MB |
| Version pinned by | formula name | the build itself |
| Extra machinery | a formula in the tap | none |

The two are not exclusive: the same source builds both, and
`resolvedContainerPath` prefers a vendored copy when one is present and falls
back to the search paths when it is not. What they cannot share is one DMG — a
vendored build is the fat one by definition.
