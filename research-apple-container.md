# Apple Container (CLI + daemon) research brief

**Scope and date.** This brief pins source analysis to the `apple/container` **1.2.2** tag (published 8 Aug 2026) and contrasts the locally installed **0.5.0** (2 Oct 2025). “Apple Container” means `github.com/apple/container`; “Containerization” means `github.com/apple/containerization`. Claims are tagged **OBSERVED** (read in a primary source) or **INFERRED** (reasoned from observed source).

## Answers

### 1. Process architecture, shipped binaries, launchd and XPC names

**OBSERVED — architecture.** The current technical overview says each container runs in its own lightweight VM and that the CLI client library communicates with `container-apiserver` and helpers. It names the API server, image helper, network helper, and one runtime helper per container ([technical-overview.md](https://github.com/apple/container/blob/1.2.2/docs/technical-overview.md), 2026-08). The 1.2.2 `Makefile` is more complete than that overview: the package stages these executables:

| Binary / role | Installed location | launchd label | Mach service(s) / lifecycle |
|---|---|---|---|
| `container` (CLI) | `/usr/local/bin/container` | none | launches commands and clients; not a daemon |
| `container-apiserver` | `/usr/local/bin/container-apiserver` | `com.apple.container.apiserver` | `com.apple.container.apiserver`; `container system start` writes a plist with `RunAtLoad=true`, Aqua/Background/System session types, registers it with launchd, then pings it |
| `container-core-images` | `libexec/container/plugins/container-core-images/bin/container-core-images` | `com.apple.container.container-core-images` | `com.apple.container.core.container-core-images`; core plugin, loaded at boot, not run-at-load |
| `container-network-vmnet` | `libexec/container/plugins/container-network-vmnet/bin/container-network-vmnet` | `com.apple.container.container-network-vmnet.<network-id>` | `com.apple.container.network.container-network-vmnet.<network-id>`; network plugin instances are registered per network, run-at-load |
| `container-runtime-linux` | `libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux` | `com.apple.container.container-runtime-linux.<container-UUID>` | `com.apple.container.runtime.container-runtime-linux.<container-UUID>`; one runtime helper per container; launchd instance is on demand |
| `machine-apiserver` | `libexec/container/plugins/machine-apiserver/bin/machine-apiserver` | `com.apple.container.machine-apiserver` | `com.apple.container.core.machine-apiserver`; core plugin for `container machine`, loaded at boot |
| `k8s` | `libexec/container/plugins/k8s/bin/k8s` | none | CLI-only plugin (`config.toml` has no `servicesConfig`), with `kindnet.yaml` resource |

These paths and binaries are literal `Makefile` install rules ([Makefile](https://github.com/apple/container/blob/1.2.2/Makefile), 2026-08). Plugin configs and labels are in [Sources/Plugins](https://github.com/apple/container/tree/1.2.2/Sources/Plugins), 2026-08. `Plugin.getLaunchdLabel` and `Plugin.getMachServices` define the `com.apple.container.` prefix and the exact type/name/instance expansion ([Plugin.swift](https://github.com/apple/container/blob/1.2.2/Sources/ContainerPlugin/Plugin.swift), 2025-2026).

`container-apiserver` also hosts the DNS servers in-process: container-hostname DNS on `127.0.0.1:2053` and host resolver DNS on `127.0.0.1:1053` ([APIServer+Start.swift](https://github.com/apple/container/blob/1.2.2/Sources/APIServer/APIServer%2BStart.swift), 2026-08). Runtime helpers expose a per-container endpoint service and a separate anonymous XPC connection used by the API server for lifecycle routes ([RuntimeLinuxHelper+Start.swift](https://github.com/apple/container/blob/1.2.2/Sources/Plugins/RuntimeLinux/RuntimeLinuxHelper%2BStart.swift), 2026-08).

**OBSERVED — plugin extension point.** `PluginConfig` explicitly describes a user plugin directory containing `config.toml`/legacy `config.json` and a same-named `bin/<plugin>` executable. Service types are `runtime`, `network`, `core`, and reserved `auxiliary`; a service **must** expose `com.apple.container.{type}.{name}.[{id}]` ([PluginConfig.swift](https://github.com/apple/container/blob/1.2.2/Sources/ContainerPlugin/PluginConfig.swift), 2025-2026). The API server discovers a user plugin directory and built-in plugin directory ([APIServer+Start.swift](https://github.com/apple/container/blob/1.2.2/Sources/APIServer/APIServer%2BStart.swift), 2026-08). **Caveat:** the doc comment says `<application-root>/user-plugins`, while the 1.2.2 implementation computes `installRoot/libexec/container-plugins`; verify the packaged path before building an extension installer.

### 2. CLI-to-daemon API, publicness, and connection gates (headline)

**OBSERVED — the client is a public Swift package target.** `Package.swift` publishes `ContainerAPIClient` and `ContainerXPC` products (along with server/client targets), and the `ContainerAPIClient` target points at `Sources/Services/ContainerAPIService/Client`. `ContainerClient` is `public`, `Sendable`, has `public init()`, and its lifecycle methods (`create`, `list`, `get`, `bootstrap`, `kill`, `stop`, `delete`, `createProcess`, etc.) are public ([Package.swift](https://github.com/apple/container/blob/1.2.2/Package.swift), [ContainerClient.swift](https://github.com/apple/container/blob/1.2.2/Sources/Services/ContainerAPIService/Client/ContainerClient.swift), 2026-08). A third-party Swift app can therefore link the source package and use the client, or use the lower-level public `ContainerXPC.XPCClient`.

**OBSERVED — transport.** `ContainerClient` hard-codes `com.apple.container.apiserver`, constructs `XPCClient(service:)`, and sends `XPCMessage` route dictionaries over XPC. `XPCClient.init(service:)` calls `xpc_connection_create_mach_service(service, queue, 0)`; it has no code-signing, Team ID, entitlement, or hardened-runtime check ([XPCClient.swift](https://github.com/apple/container/blob/1.2.2/Sources/ContainerXPC/XPCClient.swift), 2025-2026).

**OBSERVED — server-side authorization.** `XPCServer.handleMessage` extracts the request audit token, computes `geteuid()`, computes the client EUID, and rejects a mismatch with `"unauthorized request"`. That same-UID check is the only authorization gate in the XPC server source; there is no entitlement, signing-identity, or application-group check ([XPCServer.swift](https://github.com/apple/container/blob/1.2.2/Sources/ContainerXPC/XPCServer.swift), 2025-2026).

> Verbatim source quote: `// Ensure that the client has our EUID` … `guard clientEuid == serverEuid else {` … `message: "unauthorized request"`.

**OBSERVED — entitlements/build.** The 1.2.2 Makefile passes `--entitlements=signing/container-runtime-linux.entitlements` only to `container-runtime-linux` and `--entitlements=signing/container-network-vmnet.entitlements` only to `container-network-vmnet`; the two entitlement files each contain only `com.apple.security.virtualization = true` ([Makefile](https://github.com/apple/container/blob/1.2.2/Makefile), [runtime entitlement](https://github.com/apple/container/blob/1.2.2/signing/container-runtime-linux.entitlements), [network entitlement](https://github.com/apple/container/blob/1.2.2/signing/container-network-vmnet.entitlements), 2026-08). The CLI, API server, image helper, machine helper and K8s helper are codesigned without an entitlement argument in this build recipe. Local 0.5.0 verification additionally found plain Apple Developer ID + hardened runtime and no entitlements on CLI/API server/core-images; no special Apple-internal certificate is required. **INFERRED:** a third-party app does not need an Apple-private entitlement to connect, but it must run under the same UID as the launchd service. It should also pin the exact `container` package revision because no stable wire/API contract is promised.

**OBSERVED — stability warning.** The 1.0.0 release explicitly says: “Removed compatibility with application major version 0 XPC APIs. A subsequent release will introduce a version on the API itself so that clients and server can check compatibility” ([1.0.0 release](https://github.com/apple/container/releases/tag/1.0.0), 9 Jun 2026). In the 1.2.2 sources, health ping returns daemon release version/commit/build metadata, but no negotiated API-major field or compatibility handshake is present in `ContainerClient`/`XPCClient`. The README still contains the pre-1.0 statement that stability is only guaranteed within patch versions and minor versions may break until 1.0 ([README](https://github.com/apple/container/blob/1.2.2/README.md), 2026-08); it was not replaced with a positive 1.x API guarantee. **Conclusion:** linkable/public, yes; supported stable SDK, no evidence.

### 3. Release history and 0.5.0 → 1.2.2 delta

Dates below are official GitHub release publication dates (UTC; pages and signed tags checked 11 Aug 2026).

| Release | Date | Material change (condensed from official notes/tag) |
|---|---|---|
| 0.1.0 | 2025-06-09 | Initial public release; no detailed highlights. |
| 0.2.0 | 2025-06-27 | Added `container network` for macOS 26; Containerization 0.2.0; one-interface network limitation noted in tag body. |
| 0.3.0 | 2025-07-30 | Nested virtualization; localhost TCP/UDP publishing; build/platform improvements; user plugin discovery; Rosetta-disable build option. |
| 0.4.0 | 2025-08-27 | Release/tag centered on platform work (full flag details landed adjacent in 0.4.1). |
| 0.4.1 | 2025-08-28 | Uniform `--platform/--os/--arch`; systemd; `/etc/hosts`/DNS conflict handling; SSH socket forwarding; named volumes; native builder; custom `--app-root`. |
| 0.5.0 | 2025-10-02 | Removed `images` alias and `system property`; changed registry keychain ID; **exposed `ContainerCommands` externally**; moved sandbox operations behind APIServer with significant `ContainerClient` changes; multi-image save; network labels; virtiofs relative-source fix. |
| 0.6.0 | 2025-10-27 | `network create --subnet`; `--network none`; anonymous volumes, implicit named-volume creation, `volume prune`; proxy/env fixes. |
| 0.7.0 | 2025-12-03 | Rosetta for image builds; build progress/stdin Dockerfile and stdio image save/load; stats; port ranges; sync mount mode; `system df`; broader image prune. |
| 0.7.1 | 2025-12-08 | Containerization data-integrity bump and sync-mode adjustment. |
| 0.8.0 | 2026-01-22 | Read-only root; amd64/arm64 aliases; IPv6 networks, container DNS and port forwarding; network prune; volume filesystem performance; **reorganized/breaking client APIs**. |
| 0.9.0 | 2026-02-03 | Kata 3.26 kernel and zstd artifacts; resource limits; `host.docker.internal`; host-only/isolated networks; build `--dns`; app-root image-store placement. |
| 0.10.0 | 2026-02-25 | Network privacy-alert trigger for port publishing; maintenance release. |
| 0.11.0 | 2026-03-30 | CLI status integration-test coverage and assertion fixes; maintenance/reliability release. |
| 0.12.0 | 2026-04-27 | Plugin-loader shadowing startup-log fix; integration/dependency work. |
| 0.12.1 | 2026-04-28 | Sequoia test-escape patch. |
| 0.12.2 | 2026-04-30 | Security patches. |
| 0.12.3 | 2026-04-30 | Security fixes including HTTP-downgrade prevention in registry commands. |
| 1.0.0 | 2026-06-09 | `container machine`; TOML config replaces UserDefaults/system-property commands; structured-output cleanup; `--stop-signal`; `container cp`; NetworkResource and XPC-lease network fixes; removed application-major-0 XPC compatibility (quote above). |
| 1.1.0 | 2026-07-06 | Non-root Unix-socket mounts; host-to-container socket permission propagation; machine docs/nested virt; default network follows system config; Containerization 0.33.4→0.34.0. Breaking CLI/API annotations. |
| 1.2.0 | 2026-07-29 | Containerization 0.36/0.37/0.40.1 updates; gRPC transport; XPC-helper integration coverage; kernel archive integrity; ordered image journaling; masked/read-only paths and reliability fixes. |
| 1.2.1 | 2026-08-07 | Turnkey `k8s` plugin; live-container `export`; builder `--ssh`; `--read-only-path`/`--masked-path`; builder shim 0.13.1. |
| 1.2.2 | 2026-08-08 | Fix release-package `container k8s`; extract K8s logic into `ContainerK8s` and plugin-resource management; test migration. |

Primary release feed: [releases.atom](https://github.com/apple/container/releases.atom) (updated 8 Aug 2026); release pages are linked at [releases](https://github.com/apple/container/releases). **OBSERVED delta:** from 0.5.0 to 1.2.2 networking became IPv6/host-only/isolated/lease-based with per-network plugin helpers, volumes gained anonymous/prune/performance/socket-mount semantics, Rosetta build support became default, and K8s/machine features landed. **OBSERVED negative:** no 0.6.0–1.2.2 release note announces Docker Engine HTTP API, Docker socket, or Compose.

### 4. Documented limitations and compatibility gaps

**OBSERVED.** Current README requires Apple silicon and says `container` is supported on macOS 26; older macOS versions are not supported ([README](https://github.com/apple/container/blob/1.2.2/README.md), 2026-08). The technical overview documents macOS 15 fallback limitations: vmnet isolates containers with no container-to-container communication; `container network` is unavailable; all containers use the default vmnet network; and helper/vmnet subnet races can leave containers without network access ([technical-overview.md](https://github.com/apple/container/blob/1.2.2/docs/technical-overview.md), 2026-08).

**OBSERVED.** Rosetta is explicit, not a full x86 VM: `container run --rosetta`/`--arch amd64` exists, build config defaults `rosetta=true`, and the how-to shows amd64 `uname` under Rosetta returning `x86_64` ([command-reference.md](https://github.com/apple/container/blob/1.2.2/docs/command-reference.md), [how-to.md](https://github.com/apple/container/blob/1.2.2/docs/how-to.md), [container-system-config.md](https://github.com/apple/container/blob/1.2.2/docs/container-system-config.md), 2026-08). Rosetta requires host/guest support; users can disable it for arm64-only builds.

**OBSERVED.** Host sharing is explicit per VM/container (`--volume/--mount`, named/anonymous volumes, socket/SSH forwarding), not a shared Docker-Desktop-style VM filesystem. The overview emphasizes only necessary host data is mounted into each VM. The 0.5.0 release fixed a relative-path virtiofs regression; 0.8.0 notes volume filesystem-performance improvements. No Apple source promises native-host bind-mount performance or gives a benchmark.

**OBSERVED.** Virtualization has a memory-reclaim limitation: freed Linux guest pages are not relinquished to macOS, so memory-intensive containers may need restarting. The docs expose no GPU device/passthrough command, and no GPU entitlement is in the 1.2.2 signing recipe. **INFERRED:** GPU acceleration/passthrough is not a supported Container API feature today.

**OBSERVED/INFERRED.** The CLI is OCI-image and XPC based, not Docker Engine API based. There is no documented Docker-compatible Unix socket, Swarm mode, or Compose command in 1.2.2 CLI/docs; technical overview instead says many common containerization features remain to be implemented. Treat Docker API/Compose/Swarm as ContainerStack-owned compatibility layers. The local 0.5.0 machine confirms Apple Container publishes no Docker-compatible socket.

### 5. What `container system` manages

**OBSERVED.** `container system` includes `start`, `stop`, `status`, `version`, `df`, `logs`, `dns`, and `kernel` ([SystemCommand.swift](https://github.com/apple/container/blob/1.2.2/Sources/ContainerCommands/System/SystemCommand.swift), 2025-2026).

* `system start` copies TOML configuration, writes/registers the API-server launchd plist, waits for XPC health, verifies machine API, pulls configured `vminit` if absent, and installs the recommended kernel if missing ([SystemStart.swift](https://github.com/apple/container/blob/1.2.2/Sources/ContainerCommands/System/SystemStart.swift), 2025-2026).
* `system dns create|delete|list` manages local DNS domains. `dns create` validates a domain, optionally redirects an IP to localhost with packet-filter rules, reinitializes mDNSResponder, and needs admin privileges ([DNSCreate.swift](https://github.com/apple/container/blob/1.2.2/Sources/ContainerCommands/System/DNS/DNSCreate.swift), 2025-2026). `[dns].domain` appends a suffix to container hostnames.
* TOML `[registry].domain` defaults unqualified references to `docker.io`; `[network]` configures default IPv4/IPv6 subnets; `[kernel]` stores binary path, URL and digest; `[build].rosetta` defaults true ([container-system-config.md](https://github.com/apple/container/blob/1.2.2/docs/container-system-config.md), 2026-08).
* `system kernel set` installs recommended/custom binary/archive for `arm64` or `amd64`, with overwrite and digest verification ([KernelSet.swift](https://github.com/apple/container/blob/1.2.2/Sources/ContainerCommands/System/Kernel/KernelSet.swift), 2025-2026).
* `system logs` delegates to `/usr/bin/env log show` or `log stream`, filters `subsystem = 'com.apple.container'`, supports `--last` and `--follow` ([SystemLogs.swift](https://github.com/apple/container/blob/1.2.2/Sources/ContainerCommands/System/SystemLogs.swift), 2025-2026).

### 6. License, governance and stability posture

**OBSERVED.** Source headers and `LICENSE` identify Apache License 2.0; the standard notice says software is distributed “AS IS” without warranties ([LICENSE](https://github.com/apple/container/blob/1.2.2/LICENSE), [Package.swift](https://github.com/apple/container/blob/1.2.2/Package.swift), 2026). README says contributions are welcome and points to the Containerization project guide; `MAINTAINERS.txt` records the maintainer set ([CONTRIBUTING.md](https://github.com/apple/container/blob/1.2.2/CONTRIBUTING.md), [MAINTAINERS.txt](https://github.com/apple/container/blob/1.2.2/MAINTAINERS.txt), 2026). The repository is actively developed by Apple and external contributors with signed release tags.

**OBSERVED.** No positive semantic-version/API stability guarantee appears in 1.2.2 README, Package manifest, or API docs. 1.0.0 instead records removal of old XPC compatibility and says a future API-version mechanism would be introduced. Treat this as source-available Apache-2.0, not a stable binary SDK.

### 7. Docker API / Compose / third-party GUI discussion posture

**OBSERVED.** The 1.2.2 command surface, Package products, technical overview and release history expose OCI/XPC APIs, not Docker Engine HTTP endpoints. Searches of official 0.6→1.2.2 release notes found no Docker API, `docker.sock`, or Compose feature. The architecture separates `container` from Docker’s long-running daemon model. **INFERRED:** a Docker-compatible GUI cannot simply point Docker tooling at Apple Container; it needs a compatibility daemon/adapter (`containerstackd`) or CLI adapter.

**OBSERVED.** The source provides two integration ingredients: public `ContainerAPIClient` and documented plugin service types. But same-UID audit-token authorization, unversioned route dictionaries, and the 1.0 breaking-XPC note mean a GUI must not rely on private routes or assume cross-release wire compatibility. Use public client APIs where possible, pin versions, and isolate compatibility code behind ContainerStack’s daemon.

**Verbatim Apple position:** “Removed compatibility with application major version 0 XPC APIs. A subsequent release will introduce a version on the API itself so that clients and server can check compatibility.” ([1.0.0 release](https://github.com/apple/container/releases/tag/1.0.0), published 9 Jun 2026.)

No official Apple issue/discussion located in the checked 1.2.2 source/release material promises Docker API, Compose, Swarm, or an Apple GUI. The documented posture is an open-source Swift CLI/package with contributions welcome, not a Docker drop-in or GUI SDK. Stronger claims should cite specific issue/comment evidence rather than infer intent from silence.

## Evidence: exact 1.2.2 Package.swift platform and dependencies

**OBSERVED:** `swift-tools-version: 6.2`; `platforms: [.macOS("15")]`; `scVersion = "0.40.1"`; `builderShimVersion = "0.13.1"`. Direct dependencies:

* `apple/containerization.git` exact `0.40.1`
* `apple/swift-argument-parser` from `1.7.0`
* `apple/swift-collections` from `1.2.0`
* `apple/swift-configuration` from `1.0.0`
* `apple/swift-log` from `1.10.1`
* `apple/swift-nio` from `2.80.0`
* `apple/swift-protobuf` from `1.36.0`
* `apple/swift-system` from `1.6.4`
* `grpc/grpc-swift-2` from `2.3.0`
* `grpc/grpc-swift-nio-transport` from `2.9.0`
* `grpc/grpc-swift-protobuf` from `2.2.0`
* `swift-server/async-http-client` from `1.20.1`
* `swiftlang/swift-docc-plugin` from `1.1.0`
* `mattt/swift-toml` from `2.0.0`
* `mattt/swift-configuration-toml` from `2.0.0`
* `jpsim/Yams` from `6.2.1`

Products include `ContainerAPIClient`, `ContainerXPC`, `ContainerResource`, `ContainerPlugin`, network/runtime client/server libraries, machine API libraries, `ContainerK8s`, build/image/persistence/log libraries and test support.

## Implications for ContainerStack

1. **Feasible substrate:** public Swift clients, OCI image/registry behavior, launchd/XPC, VM-per-container isolation, vmnet networking, volumes, Rosetta, and plugins are all present.
2. **Not a drop-in Docker engine:** implement `containerstackd` as the stable Docker-compatible façade; use Apple’s client/package behind it.
3. **Security boundary:** preserve same-UID behavior for direct XPC; expose Docker API only through a deliberate local socket/HTTP authorization boundary.
4. **Version pinning:** pin `container` and `containerization` together; add a ContainerStack-owned protocol version and startup compatibility check.
5. **macOS policy:** require macOS 26 for full networking behavior; label macOS 15 fallback limitations. GPU, Swarm, Compose and bind-mount parity need explicit ContainerStack decisions/tests.
6. **Plugins:** test actual packaged plugin path (`installRoot/libexec/container-plugins` vs stale `application-root/user-plugins` comment).

## Sources

1. README (requirements/status/contributions): https://github.com/apple/container/blob/1.2.2/README.md (accessed 11 Aug 2026).
2. Technical overview (architecture/macOS 15 limitations): https://github.com/apple/container/blob/1.2.2/docs/technical-overview.md (accessed 11 Aug 2026).
3. Package.swift (platform/products/dependencies): https://github.com/apple/container/blob/1.2.2/Package.swift (accessed 11 Aug 2026).
4. ContainerClient.swift (public client): https://github.com/apple/container/blob/1.2.2/Sources/Services/ContainerAPIService/Client/ContainerClient.swift (accessed 11 Aug 2026).
5. ContainerXPC sources (Mach transport/EUID gate): https://github.com/apple/container/tree/1.2.2/Sources/ContainerXPC (accessed 11 Aug 2026).
6. ContainerPlugin sources (schema/service names): https://github.com/apple/container/tree/1.2.2/Sources/ContainerPlugin (accessed 11 Aug 2026).
7. Makefile (binaries/signing): https://github.com/apple/container/blob/1.2.2/Makefile (accessed 11 Aug 2026).
8. System commands: https://github.com/apple/container/tree/1.2.2/Sources/ContainerCommands/System (accessed 11 Aug 2026).
9. 1.0.0 official release (published 9 Jun 2026): https://github.com/apple/container/releases/tag/1.0.0.
10. 1.1.0 official release (published 6 Jul 2026): https://github.com/apple/container/releases/tag/1.1.0.
11. 1.2.0 official release (published 29 Jul 2026): https://github.com/apple/container/releases/tag/1.2.0.
12. 1.2.1 official release (published 7 Aug 2026): https://github.com/apple/container/releases/tag/1.2.1.
13. 1.2.2 official release (published 8 Aug 2026): https://github.com/apple/container/releases/tag/1.2.2.
14. Official release Atom feed: https://github.com/apple/container/releases.atom (updated 8 Aug 2026).
15. Apache-2.0/license + governance: https://github.com/apple/container/blob/1.2.2/LICENSE, https://github.com/apple/container/blob/1.2.2/CONTRIBUTING.md, https://github.com/apple/container/blob/1.2.2/MAINTAINERS.txt.
