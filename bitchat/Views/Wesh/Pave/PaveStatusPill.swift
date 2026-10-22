import SwiftUI

/// The Internet status pill on the home screen (spec §3 « Pill »). It never says a message was
/// received; that is the delivery state's job. Tapping retries after a failure and opens
/// Connexion otherwise.
struct PaveStatusPill: View {
    let status: PaveInternetStatus
    let action: () -> Void
    @Environment(\.paveTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: PaveSpace.s2) {
                Image(systemName: symbol)
                    .font(PaveTextStyle.label.font)
                    .foregroundStyle(theme[iconRole])
                    .accessibilityHidden(true)
                Text(status.label)
                    .paveText(.label)
                    .monospacedDigit()
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(theme[textRole])
            .padding(.horizontal, PaveSpace.s4)
            .padding(.vertical, PaveSpace.s2)
            .frame(minHeight: PaveTouch.minimum)
            .background(status == .connected ? theme[.internet] : theme[.surface], in: Capsule())
            .overlay(Capsule().strokeBorder(theme[borderRole], lineWidth: PaveStroke.control))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PaveCopy.text("pave.status.a11y", status.label))
        .accessibilityHint(PaveCopy.text(status.offersRetry ? "pave.status.retryHint" : "pave.status.hint"))
    }

    private var textRole: PaveColorRole {
        switch status {
        case .connected: return .onInternet
        case .failed: return .danger
        case .off, .connecting, .paused: return .ink
        }
    }

    private var iconRole: PaveColorRole {
        switch status {
        case .connected: return .onInternet
        case .connecting: return .internet
        case .failed: return .danger
        case .off, .paused: return .inkMuted
        }
    }

    private var borderRole: PaveColorRole {
        switch status {
        case .connected, .connecting: return .internet
        case .failed: return .danger
        case .off, .paused: return .lineStrong
        }
    }

    private var symbol: String {
        switch status {
        case .off: return "dot.radiowaves.left.and.right"
        case .connecting, .connected: return "globe"
        case .paused: return "pause.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

/// Whether a QR contact can be reached over the Internet (spec §3 « Contact badge »).
enum PaveContactInternetBadge: Equatable {
    case reachable
    case rescanRequired

    /// Nil while Internet is off: then every message goes over Bluetooth and either badge is noise.
    /// « Joignable » follows the route itself, so a binding under review (conflict, proof warning)
    /// is never shown as reachable; it gets no badge until the user resolves it.
    init?(contact: WeshQRTrust.Contact, internet: PaveInternetStatus) {
        guard internet.isEnabled else { return nil }
        if WeshInternetRoute.deliveryNpub(for: contact) != nil {
            self = .reachable
        } else if contact.requiresRescanForInternet {
            self = .rescanRequired
        } else {
            return nil
        }
    }

    var label: String { label() }

    func label(bundle: Bundle = PaveCopy.bundle, locale: Locale = .current) -> String {
        switch self {
        case .reachable: return PaveCopy.text("pave.contact.internetReachable", bundle: bundle, locale: locale)
        case .rescanRequired: return PaveCopy.text("pave.contact.rescanRequired", bundle: bundle, locale: locale)
        }
    }
}

/// The contact badge: an icon and a short label, read as plain text.
struct PaveInternetBadge: View {
    let badge: PaveContactInternetBadge
    @Environment(\.paveTheme) private var theme

    var body: some View {
        Label(badge.label, systemImage: badge == .reachable ? "globe" : "qrcode.viewfinder")
            .paveText(.caption)
            .foregroundStyle(theme[badge == .reachable ? .internet : .warning])
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct PaveStatusPill_Previews: PreviewProvider {
    static var previews: some View {
        PavePreview.variants {
            VStack(alignment: .leading, spacing: PaveSpace.s3) {
                PaveStatusPill(status: .off) {}
                PaveStatusPill(status: .connecting(torProgress: 42)) {}
                PaveStatusPill(status: .connected) {}
                PaveStatusPill(status: .paused) {}
                PaveStatusPill(status: .failed) {}
                PaveInternetBadge(badge: .reachable)
                PaveInternetBadge(badge: .rescanRequired)
            }
            .padding(PaveSpace.s4)
        }
    }
}
