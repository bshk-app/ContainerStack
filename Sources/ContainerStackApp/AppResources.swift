import Foundation

enum AppResources {
    static func bundle(mainResourceURL: URL? = Bundle.main.resourceURL) -> Bundle {
        // SwiftPM's generated lookup can miss the staged bundle in Contents/Resources.
        if let url = mainResourceURL?.appending(
            path: "ContainerStack_ContainerStackApp.bundle",
            directoryHint: .isDirectory
        ), let stagedBundle = Bundle(url: url) {
            return stagedBundle
        }
        #if SWIFT_PACKAGE
            return Bundle.module
        #else
            return Bundle.main
        #endif
    }
}
