import SwiftUI
#if os(iOS)
import UIKit
#endif

// Pavé Fluo tokens (v2), transposed one to one from docs/plan/design/system/tokens.json.
// No other Pavé file hard-codes a color, size, radius or duration.

/// The two Pavé themes. Nuit is the default (true black for OLED), Jour is for full sun.
enum PaveThemeID: String, CaseIterable, Identifiable {
    case nuit, jour
    var id: String { rawValue }
}

/// Color roles shared by both themes.
enum PaveColorRole: String, CaseIterable {
    case bg, surface, surfaceRaised, ink, inkMuted, line, lineStrong
    case publicFill, onPublic, privateFill, onPrivate
    case internet, onInternet, danger, onDanger, success, warning, focus
}

/// An sRGB value kept alongside the SwiftUI color so contrast can be verified in tests.
struct PaveRGB: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(_ hex: UInt32) {
        red = UInt8((hex >> 16) & 0xFF)
        green = UInt8((hex >> 8) & 0xFF)
        blue = UInt8(hex & 0xFF)
    }

    var color: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: 1)
    }

    /// WCAG 2.x relative luminance.
    var luminance: Double {
        func channel(_ value: UInt8) -> Double {
            let srgb = Double(value) / 255
            return srgb <= 0.03928 ? srgb / 12.92 : pow((srgb + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    func contrast(with other: PaveRGB) -> Double {
        let lighter = max(luminance, other.luminance)
        let darker = min(luminance, other.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// One resolved theme. Views read colors with `theme[.ink]`.
struct PaveTheme {
    let id: PaveThemeID

    init(_ id: PaveThemeID = .nuit) {
        self.id = id
    }

    var colorScheme: ColorScheme { id == .nuit ? .dark : .light }

    func rgb(_ role: PaveColorRole) -> PaveRGB {
        let nuit = id == .nuit
        switch role {
        case .bg: return PaveRGB(nuit ? 0x0B0B0A : 0xEFEDE4)
        case .surface: return PaveRGB(nuit ? 0x171716 : 0xFFFFFF)
        case .surfaceRaised: return PaveRGB(nuit ? 0x242422 : 0xE3E0D5)
        case .ink: return PaveRGB(nuit ? 0xF4F3EE : 0x0B0B0A)
        case .inkMuted: return PaveRGB(nuit ? 0xA6A59F : 0x54534D)
        case .line: return PaveRGB(nuit ? 0x3A3A37 : 0xCAC7BC)
        case .lineStrong: return PaveRGB(nuit ? 0x8B8A84 : 0x6B6A63)
        case .publicFill: return PaveRGB(0xE4FF1A)
        case .onPublic: return PaveRGB(0x0B0B0A)
        case .privateFill: return PaveRGB(nuit ? 0xF4F3EE : 0x0B0B0A)
        case .onPrivate: return PaveRGB(nuit ? 0x0B0B0A : 0xF4F3EE)
        case .internet: return PaveRGB(nuit ? 0x86B6FF : 0x1D4ED8)
        case .onInternet: return PaveRGB(nuit ? 0x0B0B0A : 0xFFFFFF)
        case .danger: return PaveRGB(nuit ? 0xFF5640 : 0xC4302B)
        case .onDanger: return PaveRGB(nuit ? 0x0B0B0A : 0xFFFFFF)
        case .success: return PaveRGB(nuit ? 0x7CE0A3 : 0x1F7A47)
        case .warning: return PaveRGB(nuit ? 0xFFB547 : 0x8A5A00)
        case .focus: return PaveRGB(nuit ? 0xE4FF1A : 0x0B0B0A)
        }
    }

    subscript(_ role: PaveColorRole) -> Color { rgb(role).color }

    /// `delivery-*` tokens are aliases of the base roles.
    static func deliveryRole(_ state: PaveDeliveryState) -> PaveColorRole {
        switch state {
        case .waiting: return .inkMuted
        case .sent: return .ink
        case .received: return .success
        case .failed: return .danger
        }
    }
}

/// Type roles mapped to Dynamic Type text styles so every size follows the user's setting.
enum PaveTextStyle: CaseIterable {
    case title, headline, body, label, caption, fingerprint

    var font: Font {
        switch self {
        case .title: return .title.weight(.heavy)
        case .headline: return .title3.weight(.bold)
        case .body: return .body
        case .label: return .callout.weight(.semibold)
        case .caption: return .footnote.weight(.medium)
        case .fingerprint: return .system(.subheadline, design: .monospaced).weight(.medium)
        }
    }

    var tracking: CGFloat { self == .fingerprint ? 1 : 0 }
}

extension View {
    func paveText(_ style: PaveTextStyle) -> some View {
        font(style.font).tracking(style.tracking)
    }
}

/// The WESH word mark in the Pavé Fluo poster face, scaled with Dynamic Type from a 56 pt base.
struct PaveWordmark: View {
    @ScaledMetric private var size: CGFloat

    init(baseSize: CGFloat = 56) {
        _size = ScaledMetric(wrappedValue: baseSize, relativeTo: .largeTitle)
    }

    var body: some View {
        Text(verbatim: "WESH")
            .font(PaveDisplayFont.isAvailable
                ? .custom(PaveDisplayFont.postScriptName, fixedSize: size)
                : .system(size: size, weight: .black).width(.condensed))
            .tracking(-1)
            .accessibilityLabel(Text(verbatim: "Wesh"))
            .accessibilityAddTraits(.isHeader)
    }
}

/// 4-point grid. `s4` is the screen gutter.
enum PaveSpace {
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s6: CGFloat = 24
    static let s8: CGFloat = 32
    static let s12: CGFloat = 48
}

enum PaveRadius {
    static let control: CGFloat = 12
    static let bubble: CGFloat = 18
    static let tail: CGFloat = 4
    static let sheet: CGFloat = 24
    // radius-pill (999) is drawn with `Capsule()`, reserved for the status pill.
}

enum PaveStroke {
    static let hairline: CGFloat = 1
    static let control: CGFloat = 2
    static let focus: CGFloat = 3
}

enum PaveTouch {
    static let minimum: CGFloat = 48
    static let primary: CGFloat = 56
}

/// 120 ms for a state change, 200 ms for a sheet; nothing moves with Reduce Motion.
enum PaveMotion {
    static let stateChange: Double = 0.12
    static let sheet: Double = 0.2

    static func animation(_ duration: Double, reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0) : .easeOut(duration: duration)
    }

    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom))
    }
}

/// Haptics carry meaning only. Receiving a message in the foreground plays nothing.
enum PaveHaptic: Equatable {
    case send
    case scanSuccess
    case failure
    /// One rising pulse while holding to erase; `intensity` is in 0...1.
    case holdPulse(intensity: Double)
    case erase
}

enum PaveHaptics {
    @MainActor
    static func play(_ haptic: PaveHaptic) {
        #if os(iOS)
        switch haptic {
        case .send:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .scanSuccess:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .failure:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .holdPulse(let intensity):
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: CGFloat(min(max(intensity, 0), 1)))
        case .erase:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
        #endif
    }
}

private struct PaveThemeKey: EnvironmentKey {
    static let defaultValue = PaveTheme()
}

extension EnvironmentValues {
    var paveTheme: PaveTheme {
        get { self[PaveThemeKey.self] }
        set { self[PaveThemeKey.self] = newValue }
    }
}

extension View {
    /// Applies a Pavé theme and the matching system color scheme to a subtree.
    func paveTheme(_ id: PaveThemeID) -> some View {
        environment(\.paveTheme, PaveTheme(id))
            .environment(\.colorScheme, PaveTheme(id).colorScheme)
    }

    /// Screen background: always an explicit, opaque `bg`.
    func paveScreenBackground() -> some View {
        modifier(PaveScreenBackground())
    }
}

private struct PaveScreenBackground: ViewModifier {
    @Environment(\.paveTheme) private var theme
    func body(content: Content) -> some View {
        content
            .foregroundStyle(theme[.ink])
            .background(theme[.bg].ignoresSafeArea())
    }
}
