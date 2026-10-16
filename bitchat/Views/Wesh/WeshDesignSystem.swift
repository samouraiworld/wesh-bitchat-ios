import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Stable stored IDs keep existing appearance preferences while both metals use pure black.
enum WeshAppearance: String, CaseIterable, Identifiable {
    case night, day
    var id: String { rawValue }
    var title: String { self == .night ? "Argent" : "Or" }
    var subtitle: String { self == .night ? "Noir pur · argent poli" : "Noir pur · or lumineux" }
}

struct WeshTheme {
    var appearance: WeshAppearance = .night
    var isDark: Bool { true }
    var scheme: ColorScheme { .dark }
    var canvas: Color { .black }
    var ink: Color { .white }
    var secondary: Color { Color(white: 180/255) }
    var accent: Color {
        appearance == .night ? Color(red: 203/255, green: 209/255, blue: 217/255)
            : Color(red: 217/255, green: 180/255, blue: 95/255)
    }
    var metallicStops: [Color] {
        appearance == .night
            ? [Color(red: 174/255, green: 182/255, blue: 192/255), .white,
               Color(red: 203/255, green: 209/255, blue: 217/255)]
            : [Color(red: 200/255, green: 155/255, blue: 60/255),
               Color(red: 255/255, green: 240/255, blue: 184/255),
               Color(red: 217/255, green: 180/255, blue: 95/255)]
    }
    var metalFill: LinearGradient {
        LinearGradient(colors: metallicStops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var onAccent: Color { .black }
    var line: Color { accent.opacity(0.55) }
    var radius: CGFloat { appearance == .night ? 26 : 14 }
    var messageRadius: CGFloat { appearance == .night ? 23 : 15 }
    var contentInset: CGFloat { appearance == .night ? 24 : 20 }
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
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 16)
            .foregroundStyle(enabled ? theme.onAccent : theme.secondary)
            .background(enabled ? AnyShapeStyle(theme.metalFill) : AnyShapeStyle(theme.canvas), in: RoundedRectangle(cornerRadius: theme.radius))
            .overlay(RoundedRectangle(cornerRadius: theme.radius).strokeBorder(theme.line, lineWidth: enabled ? 0 : 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct WeshCanvas: ViewModifier {
    let title: String
    @Environment(\.weshTheme) private var theme
    func body(content: Content) -> some View {
        content
            .foregroundStyle(theme.ink)
            .background(theme.canvas.ignoresSafeArea())
            .weshNavigationBar(theme)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title == "Wesh" ? "wesh" : title)
                        .font(title == "Wesh" ? .system(.title2, design: .rounded).weight(.bold) : .headline)
                        .foregroundStyle(theme.ink).accessibilityAddTraits(.isHeader)
                }
            }
    }
}

extension View {
    func weshCanvas(title: String) -> some View { modifier(WeshCanvas(title: title)) }
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

    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
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
