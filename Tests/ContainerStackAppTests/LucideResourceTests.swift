import Foundation
import XCTest

@testable import ContainerStackApp

final class LucideResourceTests: XCTestCase {
    func testStagedAppFindsSwiftPMBundleInsideContentsResources() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "LucideResourceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let bundleURL = root.appending(
            path: "ContainerStack_ContainerStackApp.bundle",
            directoryHint: .isDirectory
        )
        let contentsURL = bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
        let lucideURL = contentsURL.appending(path: "Resources/Lucide", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lucideURL, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "app.bshk.containerstack.tests.resources",
            "CFBundlePackageType": "BNDL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contentsURL.appending(path: "Info.plist"))
        try Data("<svg/>".utf8).write(to: lucideURL.appending(path: "activity.svg"))

        let bundle = try XCTUnwrap(Lucide.stagedResourceBundle(mainResourceURL: root))
        XCTAssertEqual(bundle.bundleURL.standardizedFileURL, bundleURL.standardizedFileURL)
        XCTAssertNotNil(bundle.url(forResource: "activity", withExtension: "svg", subdirectory: "Lucide"))
    }

    /// The reported symptom was a toolbar control with no icon. Every case resolving in the
    /// bundle is what turns a renamed or unstaged asset into a test failure instead.
    func testEveryIconResolvesInTheAppResourceBundle() throws {
        let bundle = Lucide.resourceBundle
        let unresolved = Lucide.allCases.filter { $0.assetURL(in: bundle) == nil }

        XCTAssertEqual(unresolved.map(\.rawValue), [], "missing Lucide assets in \(bundle.bundleURL.path)")
    }

    func testAssetLookupFailsInABundleThatCarriesNoIcons() throws {
        let bundle = try XCTUnwrap(Bundle(url: FileManager.default.temporaryDirectory))

        XCTAssertNil(Lucide.container.assetURL(in: bundle))
    }
}
