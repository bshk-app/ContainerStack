import AppKit
import ContainerStackCore
import SwiftUI
import Testing

@testable import ContainerStackApp

@MainActor @Suite(.serialized)
struct WelcomeRenderTests {
    @Test func rendersEveryStepInBothThemesOffscreen() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "welcome-render-\(UUID())")
        let suite = "WelcomeRenderTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = DockerContextStore(
            read: { _ in
                DockerContextReading(
                    active: "default", installed: false,
                    defaultSocket: DockerSocketStatus(target: "/var/run/docker.sock", isReachable: false))
            },
            install: { _ in }, uninstall: { false }, recordedSocketPath: { _ in nil }, repairRecord: { _ in })
        let model = RuntimeViewModel(
            socketPath: root.appending(path: "docker.sock").path, startsRuntime: false,
            dockerContextStore: store,
            dockerContextTakeoverPreference: DockerContextTakeoverPreference(defaults: defaults))
        let config = root.appending(path: "config.toml")
        let resources = ContainerResourceSettings(
            defaults: defaults, userFile: config, appRootCopy: config, processorCount: 8,
            physicalMemory: 16 * 1_024 * 1_024 * 1_024)
        let builder = ContainerResourceSettings(
            table: .build, defaults: defaults, userFile: config, appRootCopy: config)
        let shared = SharedRuntimeSettings(home: root)
        let skill = AgentSkillSettings(defaults: defaults, links: nil)
        let cli = CommandLineSettings(
            command: CStackCommand(executable: root.appending(path: "cstack")), path: { root.path })
        let doctor = DoctorViewModel(run: { DiagnosticReport(checks: [], ranAt: .distantPast) })
        _ = NSApplication.shared
        for mode in ["first", "update"] {
            if mode == "update" { defaults.set("0.10.0", forKey: WelcomeSession.lastVersionKey) }
            for scheme in [ColorScheme.light, .dark] {
                for step in WelcomeCatalog.steps {
                    let session = WelcomeSession(
                        defaults: defaults, version: "0.12.0")
                    session.select(step.id)
                    let view = WelcomeView(session: session) { selected in
                        WelcomeControls(
                            step: selected, model: model, resources: resources, builder: builder, shared: shared,
                            commandLine: cli, skill: skill, doctor: doctor)
                    } openLocation: { _ in
                    } close: {
                    }
                    let host = NSHostingView(
                        rootView: view.environment(\.colorScheme, scheme).defaultAppStorage(defaults))
                    host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    host.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    #expect(bitmap.pixelsWide >= 760)
                    #expect(bitmap.pixelsHigh >= 520)
                    #expect(data.count > 5_000)
                    if let output = ProcessInfo.processInfo.environment["CONTAINERSTACK_RENDER_OUTPUT"] {
                        let directory = URL(filePath: output)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try data.write(to: directory.appending(path: "\(mode)-\(scheme)-\(step.id).png"))
                    }
                }
            }
        }
    }
}
