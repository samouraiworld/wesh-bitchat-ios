import SwiftUI
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#elseif os(macOS)
import AppKit
#endif

/// Stable stored IDs keep existing appearance preferences: `night` is Pavé Fluo Nuit (OLED
/// asphalt, the default), `day` is Jour (poster paper for full sun).
enum WeshAppearance: String, CaseIterable, Identifiable {
    case night, day
    var id: String { rawValue }
    var title: String { self == .night ? "Nuit" : "Jour" }
    var subtitle: String { self == .night ? "Asphalte, noir réel pour l’OLED" : "Papier d’affiche, pour le plein soleil" }
    var paveTheme: PaveThemeID { self == .night ? .nuit : .jour }
}

/// The Wesh screens' palette, read from the Pavé Fluo tokens (`WeshTokens.swift`) so every
/// screen shares one source. Flat colours only: no metal, no gradient.
struct WeshTheme {
    var appearance: WeshAppearance = .night
    private var pave: PaveTheme { PaveTheme(appearance.paveTheme) }
    var isDark: Bool { appearance == .night }
    var scheme: ColorScheme { pave.colorScheme }
    var canvas: Color { pave[.bg] }
    var ink: Color { pave[.ink] }
    var secondary: Color { pave[.inkMuted] }
    /// Interactive tint and emphasis: ink. Public yellow is reserved for public fills.
    var accent: Color { pave[.ink] }
    var publicFill: Color { pave[.publicFill] }
    var onPublic: Color { pave[.onPublic] }
    /// Kept for the call sites that fill a primary control: one flat `private` colour.
    var metallicStops: [Color] { [pave[.privateFill], pave[.privateFill]] }
    var metalFill: LinearGradient {
        LinearGradient(colors: metallicStops, startPoint: .top, endPoint: .bottom)
    }
    var onAccent: Color { pave[.onPrivate] }
    /// Field outlines, control strokes and separators: `lineStrong`, so every boundary meets 3:1
    /// against the ground (the hairline `line` token reads 1.4:1 by day and 1.7:1 by night).
    var line: Color { pave[.lineStrong] }
    var radius: CGFloat { PaveRadius.control }
    var messageRadius: CGFloat { PaveRadius.bubble }
    var contentInset: CGFloat { PaveSpace.s4 }
}

private struct WeshThemeKey: EnvironmentKey {
    static let defaultValue = WeshTheme()
}

extension EnvironmentValues {
    var weshTheme: WeshTheme {
        get { self[WeshThemeKey.self] }
        set { self[WeshThemeKey.self] = newValue }
    }
}

struct WeshPrimaryButtonStyle: ButtonStyle {
    @Environment(\.weshTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PaveDisplayStyle.displaySmall.font)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, minHeight: PaveTouch.primary)
            .padding(.horizontal, 16)
            .foregroundStyle(enabled ? theme.onAccent : theme.secondary)
            .background(enabled ? AnyShapeStyle(theme.metalFill) : AnyShapeStyle(theme.canvas), in: RoundedRectangle(cornerRadius: theme.radius))
            .overlay(RoundedRectangle(cornerRadius: theme.radius).strokeBorder(theme.line, lineWidth: enabled ? 0 : 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct WeshCanvas: ViewModifier {
    let title: String
    /// False for a contact's nickname: it keeps the system face and its own letters.
    var appCopy = true
    @Environment(\.weshTheme) private var theme
    func body(content: Content) -> some View {
        content
            .foregroundStyle(theme.ink)
            .background(theme.canvas.ignoresSafeArea())
            .weshNavigationBar(theme)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if appCopy {
                        // App titles: poster capitals, read as written.
                        Text(title)
                            .font(PaveDisplayStyle.displaySmall.font)
                            .textCase(.uppercase)
                            .foregroundStyle(theme.ink).accessibilityAddTraits(.isHeader)
                            .accessibilityLabel(Text(title))
                    } else {
                        // A nickname: never capitals or the Latin-only poster face.
                        Text(verbatim: title).font(.headline)
                            .foregroundStyle(theme.ink).accessibilityAddTraits(.isHeader)
                    }
                }
            }
    }
}

extension View {
    func weshCanvas(title: String, appCopy: Bool = true) -> some View { modifier(WeshCanvas(title: title, appCopy: appCopy)) }
    func weshSheetBackground() -> some View { modifier(WeshSheetBackground()) }
}

private struct WeshSheetBackground: ViewModifier {
    @Environment(\.weshTheme) private var theme
    func body(content: Content) -> some View {
        if #available(iOS 16.4, macOS 13.3, *) {
            content.presentationBackground(theme.canvas)
        } else {
            content.background(theme.canvas.ignoresSafeArea())
        }
    }
}

struct WeshSectionLabel: View {
    let text: String
    @Environment(\.weshTheme) private var theme
    var body: some View {
        Text(text).font(.subheadline.weight(.semibold))
            .foregroundStyle(theme.secondary).textCase(nil)
            .padding(.top, 12).padding(.bottom, 4)
    }
}

protocol WeshPasteboard: AnyObject {
    var changeCount: Int { get }
    func write(_ text: String, expiringAt date: Date)
    func clear()
}

/// Copied messages stay on this device (no Universal Clipboard), expire
/// quickly, and a panic wipe removes them unless the user copied something else since.
@MainActor
final class WeshClipboard {
    static let lifetime: TimeInterval = 120
    static let shared = WeshClipboard(pasteboard: SystemPasteboard())
    private let pasteboard: WeshPasteboard
    private let now: () -> Date
    private var ownedChangeCount: Int?

    init(pasteboard: WeshPasteboard, now: @escaping () -> Date = Date.init) {
        self.pasteboard = pasteboard
        self.now = now
    }

    func copy(_ text: String) {
        pasteboard.write(text, expiringAt: now().addingTimeInterval(Self.lifetime))
        ownedChangeCount = pasteboard.changeCount
    }

    func clearOwnedCopy() {
        if let owned = ownedChangeCount, pasteboard.changeCount == owned { pasteboard.clear() }
        ownedChangeCount = nil
    }

    private final class SystemPasteboard: WeshPasteboard {
        #if os(iOS)
        var changeCount: Int { UIPasteboard.general.changeCount }
        func write(_ text: String, expiringAt date: Date) {
            UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]],
                                          options: [.localOnly: true, .expirationDate: date])
        }
        func clear() { UIPasteboard.general.items = [] }
        #elseif os(macOS)
        var changeCount: Int { NSPasteboard.general.changeCount }
        func write(_ text: String, expiringAt date: Date) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        func clear() { NSPasteboard.general.clearContents() }
        #else
        var changeCount: Int { 0 }
        func write(_ text: String, expiringAt date: Date) {}
        func clear() {}
        #endif
    }
}

/// Wesh ships on iPhone only; these shims keep the inherited macOS target building.
enum WeshPlatform {
    #if os(iOS)
    static let keyboardWillShow = UIResponder.keyboardWillShowNotification
    static let keyboardWillHide = UIResponder.keyboardWillHideNotification
    static let keyboardDidHide = UIResponder.keyboardDidHideNotification
    #else
    static let keyboardWillShow = Notification.Name("WeshPlatform.keyboardUnavailable")
    static let keyboardWillHide = keyboardWillShow
    static let keyboardDidHide = keyboardWillShow
    #endif

    @MainActor static func copy(_ text: String) {
        WeshClipboard.shared.copy(text)
    }
}

extension View {
    @ViewBuilder func weshInlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// For a screen that draws its own title, like the Pavé settings.
    @ViewBuilder func weshHiddenNavigationBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    @ViewBuilder func weshNoAutocapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    @ViewBuilder func weshHiddenTabBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .tabBar)
        #else
        self
        #endif
    }

    @ViewBuilder func weshNavigationBar(_ theme: WeshTheme) -> some View {
        #if os(iOS)
        toolbarBackground(theme.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(theme.scheme, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
