import SwiftUI

/// The status pill at the top of each screen: who is in range, and which way messages travel.
/// It never says a message was received; that is the delivery state's job. Tapping opens Connexion.
struct PaveStatusPill: View {
    let status: PaveConnectionStatus
    let action: () -> Void
    @Environment(\.paveTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: PaveSpace.s2) {
                Image(systemName: symbol)
                    .font(PaveTextStyle.label.font)
                    .foregroundStyle(isInternet ? theme[.onInternet] : theme[dotRole])
                    .accessibilityHidden(true)
                Text(status.label)
                    .paveText(.label)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(isInternet ? theme[.onInternet] : theme[.ink])
            .padding(.horizontal, PaveSpace.s4)
            .frame(minHeight: PaveTouch.minimum)
            .background(isInternet ? theme[.internet] : theme[.surface], in: Capsule())
            .overlay(Capsule().strokeBorder(isInternet ? theme[.internet] : theme[.lineStrong],
                                            lineWidth: PaveStroke.control))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PaveCopy.text("pave.status.a11y", status.label))
        .accessibilityHint(PaveCopy.text("pave.status.hint"))
    }

    private var isInternet: Bool {
        if case .internet = status { return true }
        return false
    }

    private var dotRole: PaveColorRole {
        switch status {
        case .inRange: return .success
        case .nobodyInRange: return .warning
        case .bluetoothOff: return .danger
        case .internet: return .onInternet
        }
    }

    private var symbol: String {
        switch status {
        case .inRange, .nobodyInRange: return "dot.radiowaves.left.and.right"
        case .bluetoothOff: return "exclamationmark.triangle.fill"
        case .internet: return "globe"
        }
    }
}

struct PaveStatusPill_Previews: PreviewProvider {
    static var previews: some View {
        PavePreview.variants {
            VStack(alignment: .leading, spacing: PaveSpace.s3) {
                PaveStatusPill(status: PaveConnectionStatus(bluetoothOn: true, peersInRange: 7, internetActive: false)) {}
                PaveStatusPill(status: .inRange(1)) {}
                PaveStatusPill(status: .nobodyInRange) {}
                PaveStatusPill(status: .bluetoothOff) {}
                PaveStatusPill(status: .internet(inRange: 3)) {}
            }
            .padding(PaveSpace.s4)
        }
    }
}
