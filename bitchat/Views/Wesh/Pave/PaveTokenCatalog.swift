import SwiftUI

/// A living sample of every Pavé token, for design review in previews.
struct PaveTokenCatalog: View {
    @Environment(\.paveTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PaveSpace.s6) {
                PaveWordmark()
                colors
                type
                shapes
                delivery
                Text(verbatim: "\(Int(PaveMotion.stateChange * 1000)) ms · \(Int(PaveMotion.sheet * 1000)) ms")
                    .paveText(.caption)
                    .foregroundStyle(theme[.inkMuted])
            }
            .padding(PaveSpace.s4)
        }
        .paveScreenBackground()
    }

    private var colors: some View {
        VStack(alignment: .leading, spacing: PaveSpace.s2) {
            ForEach(PaveColorRole.allCases, id: \.self) { role in
                HStack(spacing: PaveSpace.s3) {
                    RoundedRectangle(cornerRadius: PaveRadius.tail)
                        .fill(theme[role])
                        .overlay(RoundedRectangle(cornerRadius: PaveRadius.tail)
                            .strokeBorder(theme[.line], lineWidth: PaveStroke.hairline))
                        .frame(width: PaveTouch.minimum, height: PaveTouch.minimum)
                    Text(verbatim: role.rawValue).paveText(.label)
                    Spacer()
                    Text(verbatim: String(format: "%.1f:1", theme.rgb(role).contrast(with: theme.rgb(.bg))))
                        .paveText(.caption)
                        .foregroundStyle(theme[.inkMuted])
                }
            }
        }
    }

    private var type: some View {
        VStack(alignment: .leading, spacing: PaveSpace.s2) {
            ForEach(PaveTextStyle.allCases, id: \.self) { style in
                Text(verbatim: style == .fingerprint ? "7F3A 91C2 0B5E 44D8" : "Salon public")
                    .paveText(style)
            }
        }
    }

    private var shapes: some View {
        HStack(alignment: .bottom, spacing: PaveSpace.s2) {
            ForEach([PaveSpace.s1, PaveSpace.s2, PaveSpace.s3, PaveSpace.s4, PaveSpace.s6, PaveSpace.s8, PaveSpace.s12],
                    id: \.self) { size in
                Rectangle().fill(theme[.publicFill]).frame(width: size, height: size)
            }
            RoundedRectangle(cornerRadius: PaveRadius.sheet)
                .strokeBorder(theme[.focus], lineWidth: PaveStroke.focus)
                .frame(width: PaveTouch.primary, height: PaveTouch.primary)
        }
        .accessibilityHidden(true)
    }

    private var delivery: some View {
        HStack(spacing: PaveSpace.s3) {
            ForEach(PaveDeliveryState.allCases, id: \.self) { state in
                Text(state.label)
                    .paveText(.caption)
                    .foregroundStyle(theme[PaveTheme.deliveryRole(state)])
            }
        }
    }
}

struct PaveTokenCatalog_Previews: PreviewProvider {
    static var previews: some View {
        ForEach(PaveThemeID.allCases) { id in
            PaveTokenCatalog().paveTheme(id).previewDisplayName(id.rawValue)
        }
    }
}
