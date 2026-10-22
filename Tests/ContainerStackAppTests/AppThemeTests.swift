import AppKit
import SwiftUI
import XCTest

@testable import ContainerStackApp

/// Selected rows draw white text and glyphs on `AppTheme.selection`.
final class AppThemeTests: XCTestCase {
    /// AppKit pairs white selected-row text with `selectedContentBackgroundColor`, a darker shade
    /// than the accent. With the default accent, white on the accent measured 4.0:1; white on the
    /// selection color measured 5.4:1 (light) and 6.3:1 (dark). Other accents are skipped: the fill
    /// is then AppKit's own, as in Finder, and a light accent stays low. Yellow measured 2.1:1 and 2.4:1.
    func testWhiteTextIsLegibleOnTheSelectionFill() throws {
        try XCTSkipIf(
            UserDefaults.standard.object(forKey: "AppleAccentColor") != nil,
            "the bound is measured with the default accent"
        )
        for (theme, appearance) in [(AppTheme.light, NSAppearance.Name.aqua), (AppTheme.dark, .darkAqua)] {
            var ratio = 0.0
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                ratio = Self.contrast(NSColor(theme.selection), .white)
            }
            XCTAssertGreaterThanOrEqual(ratio, 4.5, appearance.rawValue)
        }
    }

    private static func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        let sorted = [luminance(first), luminance(second)].sorted()
        return (sorted[1] + 0.05) / (sorted[0] + 0.05)
    }

    private static func luminance(_ color: NSColor) -> Double {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }
}
