import SwiftUI

/// Wesh's two art directions share semantic roles, never a gray dark canvas.
enum WeshAppearance: String, CaseIterable, Identifiable {
    case night, day
    var id: String { rawValue }
    var title: String { self == .night ? "Nuit" : "Jour" }
    var subtitle: String { self == .night ? "Noir profond · menthe" : "Blanc lumineux · bleu" }
}

struct WeshTheme {
    var appearance: WeshAppearance = .night
    var isDark: Bool { appearance == .night }
    var scheme: ColorScheme { isDark ? .dark : .light }
    var canvas: Color { isDark ? .black : .white }
    var ink: Color { isDark ? .white : Color(red: 17/255, green: 17/255, blue: 17/255) }
    var secondary: Color { isDark ? Color(white: 0.76) : Color(white: 0.36) }
    var accent: Color {
        isDark ? Color(red: 158/255, green: 240/255, blue: 207/255)
            : Color(red: 20/255, green: 105/255, blue: 245/255)
    }
    var onAccent: Color { isDark ? .black : .white }
    var line: Color { accent.opacity(isDark ? 0.55 : 0.8) }
    var radius: CGFloat { isDark ? 26 : 14 }
    var messageRadius: CGFloat { isDark ? 23 : 15 }
    var contentInset: CGFloat { isDark ? 24 : 20 }
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
            .background(enabled ? theme.accent : theme.canvas, in: RoundedRectangle(cornerRadius: theme.radius))
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
            .toolbarBackground(theme.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(theme.scheme, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
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
