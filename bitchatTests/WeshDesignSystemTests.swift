#if canImport(UIKit)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import bitchat

@Suite("Wesh native palette contrast")
@MainActor
struct WeshDesignSystemTests {
    @Test func nightCanvasIsOpaquePureBlack() throws {
        let canvas = try rgba(WeshTheme(appearance: .night).canvas, appearance: .night)
        #expect(canvas.red == 0)
        #expect(canvas.green == 0)
        #expect(canvas.blue == 0)
        #expect(canvas.alpha == 1)
    }

    @Test(arguments: WeshAppearance.allCases)
    func textAndActionsMeetNormalTextContrast(_ appearance: WeshAppearance) throws {
        let theme = WeshTheme(appearance: appearance)
        let canvas = try rgba(theme.canvas, appearance: appearance)
        #expect(canvas.alpha == 1)
        // Body text, supporting text, and text-only actions all use normal-size text.
        for (role, color) in [("body", theme.ink), ("supporting", theme.secondary), ("action", theme.accent)] {
            let foreground = try rgba(color, appearance: appearance).over(canvas)
            let ratio = contrast(foreground, canvas)
            #expect(ratio >= 4.5, "\(appearance.rawValue) \(role) contrast is \(ratio):1; needs 4.5:1")
        }
        // Primary buttons and outgoing message bubbles share this filled surface.
        let accent = try rgba(theme.accent, appearance: appearance).over(canvas)
        let label = try rgba(theme.onAccent, appearance: appearance).over(accent)
        let ratio = contrast(label, accent)
        #expect(ratio >= 4.5, "\(appearance.rawValue) filled-action/message text contrast is \(ratio):1; needs 4.5:1")
    }

    @Test(arguments: WeshAppearance.allCases)
    func compositedInputBoundariesMeetNonTextContrast(_ appearance: WeshAppearance) throws {
        let theme = WeshTheme(appearance: appearance)
        let canvas = try rgba(theme.canvas, appearance: appearance)
        // Checking the opaque accent would miss a faint stroke: controls render `line`
        // with its actual alpha over the canvas, including an empty composer outline.
        let line = try rgba(theme.line, appearance: appearance).over(canvas)
        let ratio = contrast(line, canvas)
        #expect(ratio >= 3, "\(appearance.rawValue) composited boundary contrast is \(ratio):1; needs 3:1")
    }

    private func rgba(_ color: Color, appearance: WeshAppearance) throws -> RGBA {
        let traits = UITraitCollection(userInterfaceStyle: appearance == .night ? .dark : .light)
        let resolved = UIColor(color).resolvedColor(with: traits)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        try #require(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha), "Palette color must resolve to RGB")
        let components = [red, green, blue, alpha].map(Double.init)
        try #require(components.allSatisfy { $0.isFinite && (0...1).contains($0) }, "Palette components must be finite sRGB values")
        return RGBA(red: components[0], green: components[1], blue: components[2], alpha: components[3])
    }

    private func contrast(_ first: RGBA, _ second: RGBA) -> Double {
        (max(first.luminance, second.luminance) + 0.05) / (min(first.luminance, second.luminance) + 0.05)
    }

    private struct RGBA {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        func over(_ opaqueBackground: RGBA) -> RGBA {
            RGBA(red: red * alpha + opaqueBackground.red * (1 - alpha),
                 green: green * alpha + opaqueBackground.green * (1 - alpha),
                 blue: blue * alpha + opaqueBackground.blue * (1 - alpha), alpha: 1)
        }

        var luminance: Double {
            func linear(_ channel: Double) -> Double {
                channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
    }
}
#endif
