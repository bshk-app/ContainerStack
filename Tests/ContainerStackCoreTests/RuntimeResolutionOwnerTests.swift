import Foundation
import Testing

@testable import ContainerStackCore

/// Guards the property the helper's own comment asks for: whatever decides the binary must
/// also decide the install root, and the environment override must be honoured wherever a
/// configuration is built rather than at one call site out of four.
struct RuntimeResolutionOwnerTests {
    private let bundleRoot = "/Applications/ContainerStack.app/Contents/Resources/container"
    private var vendored: String { "\(bundleRoot)/bin/container" }
    private var pinnedKeg: String {
        "/opt/homebrew/opt/container@\(RuntimeProcessConfiguration.pinnedContainerVersion)/bin/container"
    }

    private func make(
        bundled: String?,
        present: Set<String>,
        environment: [String: String] = [:]
    ) -> RuntimeProcessConfiguration {
        RuntimeProcessConfiguration.make(
            socktainerPath: "/tmp/socktainer",
            bundledInstallRoot: bundled,
            environment: environment,
            exists: { present.contains($0) }
        )
    }

    @Test
    func vendoredCopyCarriesItsInstallRootSoSystemStartIsToldWhereToLook() {
        let config = make(bundled: bundleRoot, present: [vendored, pinnedKeg])
        #expect(config.containerPath == vendored)
        #expect(config.containerInstallRoot == bundleRoot)
        #expect(config.containerStartArguments == ["system", "start", "--install-root", bundleRoot])
    }

    /// The regression this exists for: dropping `bundledInstallRoot` resolved a system
    /// binary and omitted `--install-root`, so a Restart drove a different copy than the
    /// helper had started.
    @Test
    func droppingTheBundledRootSilentlyChangesBothTheBinaryAndTheRoot() {
        let withRoot = make(bundled: bundleRoot, present: [vendored, pinnedKeg])
        let withoutRoot = make(bundled: nil, present: [vendored, pinnedKeg])
        #expect(withRoot.containerPath != withoutRoot.containerPath)
        #expect(withoutRoot.containerInstallRoot == nil)
        #expect(withoutRoot.containerStartArguments == ["system", "start"])
    }

    @Test
    func environmentOverrideIsHonouredAndClaimsNoInstallRoot() {
        let config = make(
            bundled: bundleRoot,
            present: [vendored, pinnedKeg],
            environment: ["CONTAINERSTACK_CONTAINER_PATH": "/opt/custom/container"]
        )
        #expect(config.containerPath == "/opt/custom/container")
        #expect(config.containerInstallRoot == nil)
    }

    @Test
    func emptyOverrideIsIgnoredRatherThanTreatedAsAPath() {
        let config = make(
            bundled: nil,
            present: [pinnedKeg],
            environment: ["CONTAINERSTACK_CONTAINER_PATH": ""]
        )
        #expect(config.containerPath == pinnedKeg)
    }

    @Test
    func fallsBackToTheSearchOrderWhenNothingIsVendored() {
        let config = make(bundled: nil, present: [pinnedKeg])
        #expect(config.containerPath == pinnedKeg)
        #expect(config.containerInstallRoot == nil)
    }

    @Test
    func aBundledRootWithNoBinaryIsNotTrusted() {
        // The directory exists in the bundle layout but the binary was never staged.
        let config = make(bundled: bundleRoot, present: [pinnedKeg])
        #expect(config.containerPath == pinnedKeg)
        #expect(config.containerInstallRoot == nil)
    }

    @Test
    func installRootIsDerivedFromTheExecutableForBothBundledBinaries() {
        let app = URL(fileURLWithPath: "/Applications/ContainerStack.app/Contents/MacOS/ContainerStack")
        let helper = URL(fileURLWithPath: "/Applications/ContainerStack.app/Contents/Helpers/ContainerStackRuntime")
        let present: Set<String> = [vendored]
        #expect(
            RuntimeProcessConfiguration.bundledInstallRoot(forExecutableAt: app) { present.contains($0) }
                == bundleRoot
        )
        #expect(
            RuntimeProcessConfiguration.bundledInstallRoot(forExecutableAt: helper) { present.contains($0) }
                == bundleRoot
        )
        #expect(
            RuntimeProcessConfiguration.bundledInstallRoot(forExecutableAt: nil) { present.contains($0) }
                == nil
        )
    }
}
