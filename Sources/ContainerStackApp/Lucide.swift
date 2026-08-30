import AppKit
import ContainerStackCore
import SwiftUI

enum Lucide: String, Equatable, Sendable, CaseIterable {
    case activity
    case arrowRight = "arrow-right"
    case chevronDown = "chevron-down"
    case chevronRight = "chevron-right"
    case circleCheck = "circle-check"
    case circleMinus = "circle-minus"
    case circlePlay = "circle-play"
    case circleQuestion = "circle-question-mark"
    case container
    case database
    case download
    case ellipsis
    case fileQuestion = "file-question-mark"
    case hardDrive = "hard-drive"
    case info
    case layers
    case loader = "loader-circle"
    case minus
    case network
    case package
    case play
    case plus
    case rotateCw = "rotate-cw"
    case scrollText = "scroll-text"
    case sparkles
    case square
    case trash = "trash-2"
    case triangleAlert = "triangle-alert"
    case close = "x"
}

struct LucideIcon: View {
    let icon: Lucide

    init(_ icon: Lucide) {
        self.icon = icon
    }

    var body: some View {
        Image(nsImage: icon.templateImage)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
    }
}

struct LucideLabel: View {
    let title: String
    let icon: Lucide

    var body: some View {
        Label {
            Text(title)
        } icon: {
            LucideIcon(icon)
                .frame(width: 13, height: 13)
        }
    }
}

extension Lucide {
    static func stagedResourceBundle(mainResourceURL: URL?) -> Bundle? {
        guard let mainResourceURL else { return nil }
        return Bundle(
            url: mainResourceURL.appending(
                path: "ContainerStack_ContainerStackApp.bundle",
                directoryHint: .isDirectory
            )
        )
    }

    /// The bundle icons are loaded from: the staged app's own resource bundle when running from
    /// `Contents/Resources`, and the SwiftPM one otherwise.
    static var resourceBundle: Bundle {
        stagedResourceBundle(mainResourceURL: Bundle.main.resourceURL) ?? .module
    }

    func assetURL(in bundle: Bundle) -> URL? {
        bundle.url(forResource: rawValue, withExtension: "svg", subdirectory: "Lucide")
            ?? bundle.url(forResource: rawValue, withExtension: "svg")
    }

    /// A blank image reads as a control that has no icon, which is how an unstaged asset used to
    /// pass for a design choice. Debug builds stop; release builds draw something visibly wrong.
    var templateImage: NSImage {
        let bundle = Self.resourceBundle
        guard let url = assetURL(in: bundle), let image = NSImage(contentsOf: url) else {
            assertionFailure("Lucide asset \(rawValue).svg did not resolve in \(bundle.bundleURL.path)")
            return Self.unresolvedPlaceholder
        }
        image.isTemplate = true
        return image
    }

    private static let unresolvedPlaceholder: NSImage = {
        let image =
            NSImage(
                systemSymbolName: "questionmark.square.dashed",
                accessibilityDescription: "Icon failed to load"
            ) ?? NSImage(size: NSSize(width: 24, height: 24))
        image.isTemplate = true
        return image
    }()
}

extension RuntimeState {
    var lucide: Lucide {
        switch self {
        case .unknown: .circleQuestion
        case .starting: .loader
        case .running: .circleCheck
        case .degraded, .offline, .foreignBridge: .triangleAlert
        case .detached: .hardDrive
        }
    }
}

extension DashboardDestination {
    var lucide: Lucide {
        switch self {
        case .overview: .activity
        case .containers: .container
        case .images: .package
        case .volumes: .hardDrive
        case .networks: .network
        case .stacks: .layers
        }
    }
}
