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
}
