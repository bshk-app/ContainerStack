import AppKit
import ContainerStackCore
import SwiftUI
import Testing

@testable import ContainerStackApp

@MainActor @Suite(.serialized)
struct KubernetesPresentationTests {
    @Test func restartResultDoesNotResizeSplitViewFooter() {
        let model = RuntimeViewModel(startsRuntime: false)
        let footer = SidebarRuntimePanel(model: model)
        func height() -> CGFloat {
            NSHostingView(rootView: footer.frame(width: 210)).fittingSize.height
        }
        let before = height()
        model.clusterRestartResult = ["cs-proof-alpha: stopped in order", "cs-proof-beta: stopped in order"]
        #expect(height() == before)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func selectedStatusAndErrorUseContrastForeground(scheme: ColorScheme) throws {
        let cluster = try clusterFixture()
        let row = ClusterRow(
            cluster: cluster, state: .startFailed("Node could not start"), missing: [],
            hasContext: true, localNetworkHint: false, error: "Node could not start")
        let renderer = ImageRenderer(
            content:
                KubernetesRow(row: row, allowsActions: false, perform: { _ in }, write: {})
                .environment(\.backgroundProminence, .increased)
                .environment(\.colorScheme, scheme)
                .environment(\.appTheme, .resolve(scheme))
                .padding(8)
                .frame(width: 450, alignment: .leading)
                .background(Color(nsColor: .alternateSelectedControlColor))
        )
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        if let directory = ProcessInfo.processInfo.environment["KUBERNETES_ROW_RENDER_DIR"] {
            let root = URL(filePath: directory, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let output = root.appending(path: scheme == .dark ? "selected-dark.png" : "selected-light.png")
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output)
        }
        let redPixels = (0..<bitmap.pixelsHigh).reduce(into: 0) { count, row in
            for column in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB),
                    color.redComponent > color.greenComponent + 0.2,
                    color.redComponent > color.blueComponent + 0.15
                {
                    count += 1
                }
            }
        }
        #expect(redPixels == 0)
    }

    @Test func degradedLabelsUseTheNodeCountForAgreement() {
        #expect(ClusterRowState.degraded(0, 1).label == "Degraded: 0 of 1 node running")
        #expect(ClusterRowState.degraded(1, 2).label == "Degraded: 1 of 2 nodes running")
    }
}
