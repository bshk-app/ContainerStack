# ContainerStack macOS platform brief

**Research date:** 2026-08-11. Apple Developer pages below were retrieved on this date; current pages carry `Copyright © 2026 Apple Inc.` (Apple generally does not expose a separate publication date). WWDC22 material is dated 2022. Apple Container 1.2.2 was released 2026-08-08. Claims are tagged **OBSERVED** (the cited source states it) or **INFERRED** (engineering conclusion).

## Answers

### 1. Virtualization.framework and entitlements

**OBSERVED — `com.apple.security.virtualization`.** Apple’s *Adding the Virtualization Entitlement to Your Project* says: “To use the Virtualization APIs, a process must have the `com.apple.security.virtualization` entitlement.” The documented Xcode setup is Signing & Capabilities → turn on App Sandbox to create an entitlements file → add the “Virtualization” Boolean → set it to `YES`; the same page explicitly says the app-sandbox key can then be removed unless another capability needs it. The entitlement reference describes a Boolean that indicates whether an app can use Virtualization.framework; `VZVirtualMachineConfiguration.validate()` checks entitlement availability. Apple does not document a special approval/request process for this entitlement.

**INFERRED — normal Developer ID capability.** Unlike vmnet networking, the Virtualization entitlement has no Apple “restricted; contact your representative” warning. Treat it as the normal public capability for a signed macOS VM app, with runtime validation and distribution-profile testing. This is a source-based distinction, not a promise that Apple’s portal can never change.

**OBSERVED — `com.apple.vm.networking`.** Apple’s entitlement reference says this Boolean indicates the app manages virtual network interfaces “without escalating privileges to the root user,” is required for vmnet APIs, and is **restricted to developers of virtualization software**. Exact request instruction: “To request this entitlement, contact your Apple representative.” There is no self-service approval flow documented.

**OBSERVED — VZ consequences.** `VZBridgedNetworkDeviceAttachment` requires `com.apple.vm.networking` and otherwise makes the VM configuration invalid. `VZNATNetworkDeviceAttachment` explicitly does not require it.

### 2. Networking, addresses, host reachability, DNS

**OBSERVED — Virtualization.framework choices.**

| API | Behavior | Entitlement/privilege |
|---|---|---|
| `VZNATNetworkDeviceAttachment.init()` attached to `VZVirtioNetworkDeviceConfiguration` | Host NAT for guest packets and indirect external-network access | No `com.apple.vm.networking`; Apple describes no root requirement |
| `VZBridgedNetworkInterface.networkInterfaces` + `VZBridgedNetworkDeviceAttachment.init(interface:)` | Guest shares a physical host interface at a distinct network layer and can receive a LAN address | Requires restricted `com.apple.vm.networking` / Apple approval |
| `vmnet` `VMNET_HOST_MODE` | Host and other host-mode VMs; no outside network | vmnet docs: a **sandboxed** user-space process needs `com.apple.vm.networking`; an unsandboxed/privileged helper is the practical fallback without it (**INFERRED fallback**) |
| `vmnet` `VMNET_SHARED_MODE` | NAT to Internet plus host/other shared-mode VMs | Same entitlement statement; use entitlement for a non-root sandboxed process or a separate unsandboxed helper (**INFERRED**) |
| `vmnet` `VMNET_BRIDGED_MODE` | Bridges to physical interface named by `vmnet_shared_interface_name_key` | Restricted entitlement; keep in an approved/unsandboxed helper unless Apple grants it |

Exact vmnet API/constant names include `vmnet_network_create`, `vmnet_network_configuration_create`, `vmnet_start_interface`, `vmnet_interface_start_with_network`, `vmnet_stop_interface`, `vmnet_network_configuration_add_port_forwarding_rule`, `VMNET_HOST_MODE`, `VMNET_SHARED_MODE`, and `VMNET_BRIDGED_MODE`. Apple’s vmnet overview says its interface receives a private IPv4 address through DHCP and traffic must source that address. The public docs state the sandbox entitlement requirement but do not enumerate every root exception; therefore any “root fallback” is explicitly an inference and must be validated in ContainerStack’s chosen daemon architecture.

**OBSERVED — macOS 26 change in Apple Container 1.2.2.** Its technical overview says `container` relies on new macOS 26 features/enhancements. On macOS 15, vmnet only provides networks whose containers are isolated from each other (no container-to-container communication); all containers attach to the default network; `container network` is unavailable and `--network` errors; and the network can only be created when the first container starts, so the network helper and vmnet can disagree on the subnet and cut containers off. The supported macOS 26 path removes those limitations: custom/multiple networks and container-to-container communication are available and stable addresses can be allocated by the network helper. This is Apple Container behavior documented against OS versions, not a promise of an unchanged OS ABI.

**OBSERVED — per-container IP/DNS in Apple Container 1.2.2.** `container inspect` reports addresses such as `192.168.64.3/24`, gateway `192.168.64.1`, and hostname `my-web-server.test.`; `container ls --format json --all` exposes the same network object. `container run -p 127.0.0.1:8080:8000 ...` is the documented stable host path: loopback port forwarding to the first attached container network. Bridged mode can provide a LAN-visible guest address, but is entitlement-gated.

**OBSERVED — `*.test` resolver.** Apple Container’s documented command is `sudo container system dns create host.container.internal --localhost 203.0.113.113`. Its `HostDNSResolver` source defines `defaultConfigPath = FilePath("/etc/resolver")`, filename prefix `containerization.`, and resolver contents `domain`, `search`, `nameserver 127.0.0.1`, with port `2053` (or `1053` when `--localhost` is used). It HUPs `mDNSResponder` after changes. A ContainerStack domain therefore needs an `/etc/resolver/containerization.test`-style file pointing to its local DNS server; this normally requires admin authorization because `/etc/resolver` is system-owned. A root-owned privileged helper or authenticated installer must create/delete it and clean up stale entries.

### 3. Rosetta in Linux VMs / x86_64 OCI images

**OBSERVED — setup/API.** `VZLinuxRosettaDirectoryShare` exposes the host Rosetta directory to an ARM Linux guest. Attach it with `VZVirtioFileSystemDeviceConfiguration(tag:)` and `.share = VZLinuxRosettaDirectoryShare()`. In the guest mount with `mount -t virtiofs <tag> <mountpoint>`, then register the `rosetta` binary using Linux `update-binfmts` for x86_64 ELF. Apple requires guest `sudo` for this registration and says these activation steps must be done by a person/script logged into the guest, not by host framework APIs.

**OBSERVED — macOS 26 lifecycle.** Apple’s current “Running Intel Binaries in Linux VMs” says macOS 13+ Apple-silicon hosts support Intel binary translation in ARM Linux VMs. On macOS 26 and earlier, `VZLinuxRosettaDirectoryShare.availability` may be `notInstalled`; `installRosetta()` downloads/installs Rosetta and requires user permission. Starting macOS 27, translation is integrated, availability is always `installed`, and installation returns immediately (future-facing from this macOS 26 target). AOT cache choices are available from macOS 14 via `setCachingOptions(.unixSocket(...))` or `.abstractSocket(...)`.

**OBSERVED — limitations.** The framework does not bootstrap/install an Intel Linux distribution; it supports Intel apps inside an ARM Linux distribution. Static x86_64 binaries can run; dynamically linked binaries require their shared-library hierarchy in guest paths accessible to Rosetta. **INFERRED for OCI:** an `linux/amd64` image can run only as ARM guest userspace translated by Rosetta/binfmt; it is not an x86_64 kernel/VM, and images with missing dynamic libraries or x86-kernel requirements fail.

**OBSERVED — licensing boundary.** Apple documents Rosetta as a host capability installed by macOS (`installRosetta()`/system installer), not a redistributable SDK/library. No Apple Developer page grants third parties permission to package or redistribute Rosetta binaries. ContainerStack must not copy Rosetta into images or ship it in its bundle; have the end user/admin install/accept Apple’s host component and obtain legal review for any enterprise redistribution question. The applicable host terms are the macOS Software License Agreement.

### 4. Filesystem sharing / fast mounts

**OBSERVED — public API.** `VZVirtioFileSystemDeviceConfiguration(tag:)` is the VirtioFS device. Set `.share` to `VZSingleDirectoryShare(directory: VZSharedDirectory(url:readOnly:))` or `VZMultipleDirectoryShare(directories:)`; Linux mounts with `mount -t virtiofs <tag> <directory>`. Apple says host/guest changes are reflected through the share; tags can be checked with `validateTag(_:)`. WWDC22 demonstrates this and describes the changes as instantly reflected. Apple does **not** publish a current numeric throughput/latency guarantee in these API docs, so ContainerStack must not promise a fixed percentage or “native speed.”

**INFERRED fast-bind strategy.** Use VirtioFS for deliberate source/artifact bind mounts; do not export all of `$HOME`. Put metadata-heavy repositories, databases, package caches, and build state in VM-local ext4/APFS-backed virtual disks/managed volumes. Keep Rosetta on a separate share tag. VirtioFS is the documented high-level host-directory share; NFS/9p would be separate guest/network designs.

**OBSERVED competitor product behavior.** Docker Desktop documents file-sharing settings and has used gRPC-FUSE/VirtioFS implementations; OrbStack documents VirtioFS plus recommends VM-local volumes for I/O-heavy workloads. These are product-layer guest/daemon optimizations rather than a different public Apple VZ file-share API.

### 5. Distribution and privileged helper

**OBSERVED — Developer ID/notarization.** Apple’s notarization guide requires direct-distributed software to be Developer ID signed, use Hardened Runtime, have a secure timestamp, correctly formatted entitlements, and no `com.apple.security.get-task-allow=true`. Notarization is automated malware/code-signing checking, not App Review. Submit with `notarytool` or Xcode Organizer’s Developer ID workflow and staple the ticket. Sign/notarize every executable (GUI, CLI, daemon, installer components).

**OBSERVED — sandboxed VM app is technically possible.** Apple’s Virtualization setup page says to add the entitlement and then says the sandbox key may be removed unless needed. Thus a narrow MAS VM manager/demo can use Virtualization.framework. **INFERRED — full ContainerStack cannot fit MAS rules:** OCI image download/execution, system paths, privileged daemon/socket, and DNS resolver changes collide with App Review rules in §7.

**OBSERVED — `SMAppService` flow (macOS 13+).** `SMJobBless` is deprecated by the Xcode SDK header (`__OSX_DEPRECATED(10.6, 13.0, "Please use SMAppService instead")`). For `containerstackd`:

1. Embed the signed daemon and plist at `Contents/Library/LaunchDaemons/com.example.containerstackd.plist`; keep the app in `/Applications` when it must bootstrap before login.
2. Use standard launchd plist keys (`Label`, `ProgramArguments`/`BundleProgram`, `MachServices` or `Sockets`, `KeepAlive`, etc.). `BundleProgram` is Apple’s special app-bundle-relative executable path; the header says the plist must be inside `Contents/Library/LaunchDaemons` and the path supports app relocation.
3. Create `let service = SMAppService.daemon(plistName: "com.example.containerstackd.plist")` (Obj-C `+[SMAppService daemonServiceWithPlistName:]`).
4. Call `try service.register()` (Obj-C `registerAndReturnError:`). The app must be code signed; apps containing LaunchDaemons must be notarized.
5. Registration does not start the daemon until an admin approves it in System Settings. Check `service.status`: `.notRegistered`, `.enabled`, `.requiresApproval`, `.notFound`.
6. If `.requiresApproval`, explain the action and call `SMAppService.openSystemSettingsLoginItems()` to open the Login Items panel. The admin enables the helper; recheck status and connect over XPC/Mach service.
7. On disable/uninstall call `try service.unregister()`; after changing a plist/executable unregister/re-register (the SDK header recommends this).

This is an explicit approval flow; a LaunchDaemon is normally run as root when its launchd config omits `UserName` (standard launchd behavior; verify daemon policy during implementation).

### 6. CLI and socket paths

**OBSERVED — MAS cannot do the required install.** App Review 2.4.5(ii) requires a self-contained single-app bundle, disallows third-party installers, and forbids installing code/resources in shared locations. 2.4.5(v) forbids root escalation/setuid. 2.5.2 forbids reading/writing outside the designated container and downloading/installing/executing code that changes app features. Therefore a MAS app cannot reliably install `cstack` in `/usr/local/bin`, edit `/etc/resolver`, or create `/var/run/docker.sock`.

**INFERRED — Developer ID patterns.** Put `cstack` in the app bundle and provide a user-owned `~/bin`/`~/.local/bin` symlink or shim; alternatively use a signed/notarized installer package with explicit admin auth for `/usr/local/bin/cstack`, daemon registration, and a compatibility socket. Create the primary socket in a user-owned Application Support directory with restrictive permissions/peer credentials; expose `/var/run/docker.sock` only from the privileged daemon if Docker clients require it. `/var/run` and `/usr/local/bin` are system locations; App Sandbox/security-scoped bookmarks do not grant arbitrary system writes. Default API listeners to loopback; non-loopback listeners may trigger macOS firewall/network controls.

### 7. Policy and final verdict

**OBSERVED — current App Review rules.** §2.4.5(ii) no installers/shared-location code; (iii) no background code continuing after quit without consent; (iv) no downloading/installing standalone apps, additional code, or resources that add functionality/change what was reviewed; (v) no root escalation/setuid. §2.5.2 bars downloading/installing/executing code that introduces or changes app features (only a narrow educational-code exception). §2.5.1 requires public APIs.

**VERDICT:** A sandboxed MAS VM demonstrator/manager is technically possible with `com.apple.security.virtualization`; **the full ContainerStack product is NO for Mac App Store distribution** because its core product is an OCI code-execution environment requiring image downloads, long-lived daemon, privileged/system integration, global CLI/socket, and `/etc/resolver`. Ship the complete product as a Developer ID-signed, Hardened Runtime, notarized app/installer with explicit helper approval/admin authentication. No Apple rule specifically names “container runtime” as banned for Developer ID; ordinary malware, code-signing, privacy, and acceptable-use obligations remain.

## Evidence and exact API table

| Exact identifier | Source-verified meaning |
|---|---|
| `com.apple.security.virtualization` | Boolean entitlement required by a process using Virtualization APIs |
| `com.apple.vm.networking` | Restricted entitlement for vmnet/bridged virtual interfaces; request Apple representative |
| `VZVirtualMachine` | VM state/lifecycle object |
| `VZNATNetworkDeviceAttachment.init()` | NAT attachment; no vm networking entitlement |
| `VZBridgedNetworkInterface.networkInterfaces` | Supported host physical interfaces |
| `VZBridgedNetworkDeviceAttachment.init(interface:)` | Bridged attachment; requires vm networking entitlement |
| `VZVirtioFileSystemDeviceConfiguration.init(tag:)` | VirtioFS device; `.share` accepts `VZSingleDirectoryShare` / `VZMultipleDirectoryShare` |
| `VZLinuxRosettaDirectoryShare()` | Rosetta share for ARM Linux guest |
| `VZLinuxRosettaDirectoryShare.availability`, `installRosetta()` | Check/install host Rosetta on macOS 26 and earlier |
| `SMAppService.daemon(plistName:)` | Embedded LaunchDaemon service object |
| `SMAppService.register()`, `.unregister()`, `.status`, `SMAppService.openSystemSettingsLoginItems()` | Registration, removal, status, approval UI |
| `VMNET_HOST_MODE`, `VMNET_SHARED_MODE`, `VMNET_BRIDGED_MODE` | vmnet operating modes |

## Implications for ContainerStack

1. Make the supported core Developer ID first: `ContainerStack.app`, `cstack`, signed/notarized `containerstackd`.
2. Use `VZNATNetworkDeviceAttachment` for outbound NAT and loopback port publishing; treat bridged networking as contingent on Apple approval for `com.apple.vm.networking`.
3. On macOS 26 use the vmnet-backed network helper for private per-container addresses and network metadata; expose addresses via inspect and stable ports via forwarding.
4. Make `.test` DNS explicitly admin-authorized: `/etc/resolver`, local DNS, mDNSResponder HUP, conflict/cleanup handling.
5. Treat Rosetta as optional: detect availability, prompt for `installRosetta()`, ensure guest binfmt/shared libraries, never redistribute Rosetta bits.
6. Use VirtioFS only for deliberate bind mounts; recommend VM-local volumes for databases/build metadata.
7. A MAS companion may expose monitoring/settings, but image execution, helper, global CLI/socket, DNS, and admin operations belong in notarized Developer ID distribution.

## Sources

1. Apple, “Adding the Virtualization Entitlement to Your Project” (current docs, copyright 2026): https://developer.apple.com/documentation/virtualization/adding-the-virtualization-entitlement-to-your-project
2. Apple, `com.apple.security.virtualization` entitlement (current docs, copyright 2026): https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.virtualization
3. Apple, `com.apple.vm.networking` entitlement (current docs, copyright 2026): https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.vm.networking
4. Apple, `VZNATNetworkDeviceAttachment` (current docs, copyright 2026): https://developer.apple.com/documentation/virtualization/vznatnetworkdeviceattachment
5. Apple, `VZBridgedNetworkDeviceAttachment` (current docs, copyright 2026): https://developer.apple.com/documentation/virtualization/vzbridgednetworkdeviceattachment
6. Apple, `VZBridgedNetworkInterface` (current docs, copyright 2026): https://developer.apple.com/documentation/virtualization/vzbridgednetworkinterface
7. Apple, vmnet framework (current docs, copyright 2026): https://developer.apple.com/documentation/vmnet
8. Apple, `VZVirtioFileSystemDeviceConfiguration` (current docs, copyright 2026): https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdeviceconfiguration
9. Apple, “Running Intel Binaries in Linux VMs” (current docs, copyright 2026): https://developer.apple.com/documentation/virtualization/running-intel-binaries-in-linux-vms
10. Apple, “Create macOS or Linux virtual machines,” WWDC22 session 10002 (2022): https://developer.apple.com/videos/play/wwdc2022/10002/
11. Apple, `SMAppService` (current docs, copyright 2026): https://developer.apple.com/documentation/servicemanagement/smappservice
12. Apple, Xcode 26 SDK `SMAppService.h` (macOS 26 SDK header; exact APIs/deprecation comments): `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/ServiceManagement.framework/Versions/A/Headers/SMAppService.h`
13. Apple, “Notarizing macOS software before distribution” (current docs, copyright 2026): https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
14. Apple, App Review Guidelines (current page accessed 2026-08-11): https://developer.apple.com/app-store/review/guidelines/
15. Apple, Container 1.2.2 `docs/technical-overview.md` (released 2026-08-08): https://github.com/apple/container/blob/1.2.2/docs/technical-overview.md
16. Apple, Container 1.2.2 `docs/how-to.md` (released 2026-08-08): https://github.com/apple/container/blob/1.2.2/docs/how-to.md
17. Apple, Container `HostDNSResolver.swift` source: https://github.com/apple/container/blob/main/Sources/Services/ContainerAPIService/Client/HostDNSResolver.swift
18. Docker, Desktop settings/file sharing documentation (current docs accessed 2026-08-11): https://docs.docker.com/desktop/settings-and-maintenance/settings/
19. OrbStack, native files/filesystem documentation (current docs accessed 2026-08-11): https://docs.orbstack.dev/features/native-files
20. Apple, macOS Software License Agreements index (host Rosetta/macOS terms; current index accessed 2026-08-11): https://www.apple.com/legal/sla/
