import XCTest

@testable import ContainerStackApp

final class LaunchAgentStatusTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appending(path: "agent-status-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if workDir != nil {
            try? FileManager.default.removeItem(at: workDir!)
        }
    }

    private func makeBundle(staged: Bool) throws -> URL {
        let bundle = workDir.appending(path: "Fake-\(staged ? "staged" : "bare").app")
        if staged {
            let agentsDir = bundle.appending(path: "Contents/Library/LaunchAgents")
            try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: agentsDir.appending(path: RuntimeViewModel.launchAgentPlistName).path,
                contents: Data("<plist/>".utf8)
            )
        }
        return bundle
    }

    func testNotFoundMessageKeepsStagedBundleFromReadingAsBroken() {
        XCTAssertEqual(
            RuntimeViewModel.notFoundStatusDescription(plistStaged: true),
            "Not registered — use 'Enable at Login' to start the runtime at login"
        )
        XCTAssertEqual(
            RuntimeViewModel.notFoundStatusDescription(plistStaged: false),
            "Not staged in this build — run the app from an installed bundle"
        )
    }

    func testPlistDetectionDistinguishesStagedFromMissing() throws {
        XCTAssertTrue(try RuntimeViewModel.launchAgentPlistIsStaged(in: makeBundle(staged: true)))
        XCTAssertFalse(try RuntimeViewModel.launchAgentPlistIsStaged(in: makeBundle(staged: false)))
    }

    func testPlistDetectionWithoutBundleURLIsMissing() {
        XCTAssertFalse(RuntimeViewModel.launchAgentPlistIsStaged(in: nil))
    }
}
