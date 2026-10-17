//
// Theme.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI

/// A user-selectable app-wide visual theme. Persisted by raw value.
enum AppTheme: String, CaseIterable, Identifiable {
    case matrix
    case liquidGlass

    var id: String { rawValue }

    /// Font design used for themed text. Matrix keeps the terminal monospace;
    /// liquid glass uses the system default.
    var bodyFontDesign: Font.Design {
        switch self {
        case .matrix: return .monospaced
        case .liquidGlass: return .default
        }
    }

    /// Discriminator mixed into per-message formatting caches so cached
    /// AttributedStrings from one theme are never served under another.
    /// Empty for matrix to keep its historical cache keys.
    var formatCacheVariant: String {
        switch self {
        case .matrix: return ""
        case .liquidGlass: return "lg:"
        }
    }

    /// Resolves the semantic color palette for this theme under the given color scheme.
    func palette(for colorScheme: ColorScheme) -> ThemePalette {
        switch self {
        case .matrix:
            return .matrix(colorScheme)
        case .liquidGlass:
            return .liquidGlass(colorScheme)
        }
    }
}

/// Semantic colors for the active theme, resolved against the current color scheme.
/// Views should consume these via `@ThemedPalette` rather than computing colors inline.
struct ThemePalette {
    /// De-emphasized text (timestamps, hints, captions).
    let secondary: Color

    static func matrix(_ colorScheme: ColorScheme) -> ThemePalette {
        let isDark = colorScheme == .dark
        let green = isDark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
        return ThemePalette(secondary: green.opacity(0.8))
    }

    static func liquidGlass(_: ColorScheme) -> ThemePalette {
        ThemePalette(secondary: .secondary)
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .matrix
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

/// Resolves the active theme's palette against the view's color scheme.
///
///     @ThemedPalette private var palette
///     var body: some View { Text("hi").foregroundColor(palette.secondary) }
@propertyWrapper
struct ThemedPalette: DynamicProperty {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var wrappedValue: ThemePalette { theme.palette(for: colorScheme) }
}

// MARK: - Themed view helpers

/// Themed replacement for `.font(.bitchatSystem(size:weight:design: .monospaced))`:
/// monospaced under matrix, system default under liquid glass.
private struct ThemedFontModifier: ViewModifier {
    @Environment(\.appTheme) private var theme
    let size: CGFloat
    let weight: Font.Weight

    func body(content: Content) -> some View {
        content.font(.bitchatSystem(size: size, weight: weight, design: theme.bodyFontDesign))
    }
}

extension View {
    func bitchatFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ThemedFontModifier(size: size, weight: weight))
    }
}
