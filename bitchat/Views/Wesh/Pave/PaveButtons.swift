import SwiftUI

/// Principal: `private` fill, full width, 56 pt. One per screen.
struct PavePrimaryButtonStyle: ButtonStyle {
    @Environment(\.paveTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .paveText(.label)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: PaveTouch.primary)
            .padding(.horizontal, PaveSpace.s4)
            .foregroundStyle(isEnabled ? theme[.onPrivate] : theme[.inkMuted])
            .background(isEnabled ? theme[.privateFill] : theme[.surfaceRaised],
                        in: RoundedRectangle(cornerRadius: PaveRadius.control))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: PaveRadius.control))
    }
}

/// Secondaire: transparent with a 2 pt `line-strong` border, 48 pt.
struct PaveSecondaryButtonStyle: ButtonStyle {
    @Environment(\.paveTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .paveText(.label)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: PaveTouch.minimum)
            .padding(.horizontal, PaveSpace.s4)
            .foregroundStyle(theme[.ink])
            .background(configuration.isPressed ? theme[.surfaceRaised] : .clear,
                        in: RoundedRectangle(cornerRadius: PaveRadius.control))
            .overlay(RoundedRectangle(cornerRadius: PaveRadius.control)
                .strokeBorder(theme[.lineStrong], lineWidth: PaveStroke.control))
            .contentShape(RoundedRectangle(cornerRadius: PaveRadius.control))
    }
}

/// Danger: `danger` text and border. Erasing everything goes through `PaveHoldToErase`, never this.
struct PaveDangerButtonStyle: ButtonStyle {
    @Environment(\.paveTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .paveText(.label)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: PaveTouch.minimum)
            .padding(.horizontal, PaveSpace.s4)
            .foregroundStyle(theme[.danger])
            .background(configuration.isPressed ? theme[.surfaceRaised] : .clear,
                        in: RoundedRectangle(cornerRadius: PaveRadius.control))
            .overlay(RoundedRectangle(cornerRadius: PaveRadius.control)
                .strokeBorder(theme[.danger], lineWidth: PaveStroke.control))
            .contentShape(RoundedRectangle(cornerRadius: PaveRadius.control))
    }
}

extension ButtonStyle where Self == PavePrimaryButtonStyle {
    static var pavePrimary: PavePrimaryButtonStyle { PavePrimaryButtonStyle() }
}

extension ButtonStyle where Self == PaveSecondaryButtonStyle {
    static var paveSecondary: PaveSecondaryButtonStyle { PaveSecondaryButtonStyle() }
}

extension ButtonStyle where Self == PaveDangerButtonStyle {
    static var paveDanger: PaveDangerButtonStyle { PaveDangerButtonStyle() }
}

/// Previews in Nuit, Jour, and at the largest accessibility text size.
enum PavePreview {
    static func variants<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let view = content()
        return Group {
            view.paveScreenBackground().paveTheme(.nuit)
                .previewDisplayName("Nuit")
            view.paveScreenBackground().paveTheme(.jour)
                .previewDisplayName("Jour")
            view.paveScreenBackground().paveTheme(.nuit)
                .environment(\.dynamicTypeSize, .accessibility5)
                .previewDisplayName("Nuit · AX5")
        }
    }
}

struct PaveButtons_Previews: PreviewProvider {
    static var previews: some View {
        PavePreview.variants {
            VStack(spacing: PaveSpace.s3) {
                Button(PaveCopy.text("pave.action.exchange")) {}.buttonStyle(.pavePrimary)
                Button(PaveCopy.text("pave.action.showMyCode")) {}.buttonStyle(.paveSecondary)
                Button(PaveCopy.text("pave.action.block", "Nora")) {}.buttonStyle(.paveDanger)
                Button(PaveCopy.text("pave.action.start")) {}.buttonStyle(.pavePrimary).disabled(true)
            }
            .padding(PaveSpace.s4)
        }
    }
}
