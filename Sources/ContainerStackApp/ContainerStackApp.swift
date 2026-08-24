import AppKit
import SwiftUI

@main
struct ContainerStackApp: App {
    @NSApplicationDelegateAdaptor(ContainerStackAppDelegate.self) private var appDelegate
    @State private var model = RuntimeViewModel()
    @State private var updates = AppUpdates()

    var body: some Scene {
        Window("ContainerStack", id: "dashboard") {
            DashboardView(model: model)
        }
        .commands {
            // The app menu is where macOS users look for this, and the menu bar
            // extra is the only surface visible when no window is open.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            }
        }

        MenuBarExtra {
            MenuBarView(model: model, updates: updates)
        } label: {
            ContainerStackMenuBarIcon()
                .accessibilityLabel("ContainerStack, \(model.statusTitle)")
                .help("ContainerStack — \(model.statusTitle)")
        }
    }
}

/// A monochrome reduction of the app icon for the macOS menu bar.
/// The bottom module keeps the app icon's small runtime indicator as negative space.
@MainActor
private struct ContainerStackMenuBarIcon: View {
    private static let templateImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let path = NSBezierPath()
            let blockWidth: CGFloat = 16
            let blockHeight: CGFloat = 4
            let originX: CGFloat = 1
            let moduleOriginsY: [CGFloat] = [1, 7, 13]

            for originY in moduleOriginsY {
                path.appendRoundedRect(
                    NSRect(x: originX, y: originY, width: blockWidth, height: blockHeight),
                    xRadius: 1.2,
                    yRadius: 1.2
                )
            }

            for originY in moduleOriginsY {
                let isBottomModule = originY == moduleOriginsY.last
                path.appendRoundedRect(
                    NSRect(
                        x: 4,
                        y: originY + 1.5,
                        width: isBottomModule ? 7 : 10,
                        height: 1
                    ),
                    xRadius: 0.5,
                    yRadius: 0.5
                )
            }

            path.appendOval(in: NSRect(x: 13.5, y: 14.25, width: 1.5, height: 1.5))
            path.windingRule = .evenOdd
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Image(nsImage: Self.templateImage)
            .renderingMode(.template)
    }
}

@MainActor
private final class ContainerStackAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let existingInstance =
            NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != currentProcessID }

        guard let existingInstance else { return }
        existingInstance.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            sender.windows
                .first(where: { $0.canBecomeKey && $0.styleMask.contains(.titled) })?
                .makeKeyAndOrderFront(nil)
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }
}

private struct MenuBarView: View {
    let model: RuntimeViewModel
    let updates: AppUpdates
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LucideLabel(title: model.statusTitle, icon: model.runtimeState.lucide)
                .font(.headline)

            if let snapshot = model.snapshot {
                Text("Docker API \(snapshot.version.apiVersion ?? "unknown")")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Open Dashboard") {
                openWindow(id: "dashboard")
            }

            Button("Refresh") {
                Task { await model.refresh() }
            }
            .disabled(model.isLoading)

            Button("Check for Updates…") {
                updates.checkForUpdates()
            }
            .disabled(!updates.canCheckForUpdates)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 250)
        .task {
            await model.refresh()
        }
    }
}
