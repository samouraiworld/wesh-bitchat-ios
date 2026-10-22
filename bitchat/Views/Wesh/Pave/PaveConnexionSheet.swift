import CoreBluetooth
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// What the Internet mode is doing, as shown to people (spec §3 « Pill »).
enum PaveInternetStatus: Equatable {
    case off
    /// Tor bootstrap, 0 to 100.
    case connecting(torProgress: Int)
    case connected
    case paused
    case failed

    var isEnabled: Bool { self != .off }

    /// Failed is the only state a touch on the status retries.
    var offersRetry: Bool { self == .failed }

    /// The home pill adds nothing while Internet is off: the reach card already says
    /// everything travels over Bluetooth, and Internet stays opt-in.
    var showsHomePill: Bool { isEnabled }

    var label: String { label() }

    func label(bundle: Bundle = PaveCopy.bundle, locale: Locale = .current) -> String {
        switch self {
        case .off: return PaveCopy.text("pave.internet.off", bundle: bundle, locale: locale)
        case .connecting(let progress):
            return PaveCopy.text("pave.internet.connecting", bundle: bundle, locale: locale, min(max(progress, 0), 100))
        case .connected: return PaveCopy.text("pave.internet.connected", bundle: bundle, locale: locale)
        case .paused: return PaveCopy.text("pave.internet.paused", bundle: bundle, locale: locale)
        case .failed: return PaveCopy.text("pave.internet.failed", bundle: bundle, locale: locale)
        }
    }
}

extension PaveInternetStatus {
    init(_ state: WeshInternetState) {
        switch state {
        case .off: self = .off
        case .connecting(let progress): self = .connecting(torProgress: progress)
        case .on: self = .connected
        case .paused: self = .paused
        case .error: self = .failed
        }
    }
}

/// The Internet mode as the Connexion sheet needs it. `WeshInternetMode` (opt-in, Tor only, off by
/// default) adopts it; `PaveInternetModeStub` stands in for previews and tests.
@MainActor
protocol WeshInternetModeProviding: ObservableObject {
    var internetStatus: PaveInternetStatus { get }
    /// Whether the full disclosure was accepted; turning Internet on is refused until then.
    var disclosureAccepted: Bool { get }
    func acceptDisclosure()
    /// False when turning on is refused: no disclosure yet, or Tor could not be forced.
    @discardableResult func setInternetModeEnabled(_ enabled: Bool) -> Bool
    func retryInternet()
}

extension WeshInternetMode: WeshInternetModeProviding {
    var internetStatus: PaveInternetStatus { PaveInternetStatus(state) }

    @discardableResult func setInternetModeEnabled(_ enabled: Bool) -> Bool { setEnabled(enabled) }

    func retryInternet() { retry() }
}

/// In-memory stand-in for previews and tests: never touches the network.
@MainActor
final class PaveInternetModeStub: WeshInternetModeProviding {
    @Published private(set) var internetStatus: PaveInternetStatus
    @Published private(set) var disclosureAccepted: Bool
    private let refusesEnabling: Bool

    init(internetStatus: PaveInternetStatus = .off, disclosureAccepted: Bool = false, refusesEnabling: Bool = false) {
        self.internetStatus = internetStatus
        self.disclosureAccepted = disclosureAccepted
        self.refusesEnabling = refusesEnabling
    }

    func acceptDisclosure() { disclosureAccepted = true }

    @discardableResult func setInternetModeEnabled(_ enabled: Bool) -> Bool {
        if enabled, !disclosureAccepted || refusesEnabling { return false }
        internetStatus = enabled ? .connecting(torProgress: 0) : .off
        return true
    }

    func retryInternet() {
        if internetStatus == .failed { internetStatus = .connecting(torProgress: 0) }
    }
}

/// What a touch on the Internet switch did.
enum PaveInternetToggle: Equatable {
    case changed, needsDisclosure, refused

    /// The first time on, the full disclosure (spec section 4) comes first; a refusal is reported.
    @MainActor static func toggle<Mode: WeshInternetModeProviding>(_ internet: Mode, on: Bool) -> PaveInternetToggle {
        if on && !internet.disclosureAccepted { return .needsDisclosure }
        return internet.setInternetModeEnabled(on) ? .changed : .refused
    }

    /// « Activer » under the disclosure: records it, then turns Internet on.
    @MainActor static func confirmDisclosure<Mode: WeshInternetModeProviding>(_ internet: Mode) -> PaveInternetToggle {
        internet.acceptDisclosure()
        return internet.setInternetModeEnabled(true) ? .changed : .refused
    }
}

enum PaveBluetoothStatus {
    case on, off, unauthorized

    /// Anything but on or refused reads as off: the card then says how to turn it on.
    init(_ state: CBManagerState) {
        switch state {
        case .poweredOn: self = .on
        case .unauthorized: self = .unauthorized
        default: self = .off
        }
    }
}

/// Connexion: Bluetooth, phones in range, the Internet switch and what it reveals.
struct PaveConnexionSheet<InternetMode: WeshInternetModeProviding>: View {
    let bluetooth: PaveBluetoothStatus
    let peersInRange: Int
    @ObservedObject var internet: InternetMode
    let onClose: () -> Void

    @Environment(\.paveTheme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var askDisclosure = false
    @State private var refused = false
    @AccessibilityFocusState private var disclosureFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PaveSpace.s4) {
                Text(PaveCopy.text("pave.connexion.title"))
                    .paveText(.headline)
                    .accessibilityAddTraits(.isHeader)
                bluetoothCard
                internetCard
                Label(PaveCopy.text("pave.connexion.visibility"), systemImage: "exclamationmark.triangle.fill")
                    .paveText(.caption)
                    .foregroundStyle(theme[.ink])
                    .padding(.horizontal, PaveSpace.s4)
                    .padding(.vertical, PaveSpace.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: PaveRadius.control)
                        .strokeBorder(theme[.warning], lineWidth: PaveStroke.control))
                Button(PaveCopy.text("pave.action.close"), action: onClose)
                    .buttonStyle(.paveSecondary)
            }
            .padding(.horizontal, PaveSpace.s4)
            .padding(.top, PaveSpace.s8)
            .padding(.bottom, PaveSpace.s8)
        }
        .foregroundStyle(theme[.ink])
        .background(theme[.surfaceRaised].ignoresSafeArea())
        .modifier(PaveSheetChrome())
    }

    private var bluetoothCard: some View {
        HStack(alignment: .top, spacing: PaveSpace.s3) {
            Image(systemName: bluetooth == .on ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle.fill")
                .font(PaveTextStyle.label.font)
                .foregroundStyle(theme[bluetoothRole])
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PaveSpace.s1) {
                Text(bluetoothTitle).paveText(.body).fontWeight(.semibold)
                Text(bluetoothDetail).paveText(.label).fontWeight(.regular).foregroundStyle(theme[.inkMuted])
                if bluetooth == .unauthorized, let settings = PaveSystemSettings.url {
                    Button(PaveCopy.text("pave.action.openSettings")) { openURL(settings) }
                        .buttonStyle(.paveSecondary)
                        .padding(.top, PaveSpace.s2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(PaveSpace.s4)
        .background(theme[.surface], in: RoundedRectangle(cornerRadius: PaveRadius.control))
        .accessibilityElement(children: .combine)
    }

    private var internetCard: some View {
        VStack(alignment: .leading, spacing: PaveSpace.s3) {
            Toggle(isOn: Binding(get: { internet.internetStatus.isEnabled },
                                 set: { show(PaveInternetToggle.toggle(internet, on: $0)) })) {
                Label(PaveCopy.text("pave.connexion.internetMode"), systemImage: "globe")
                    .paveText(.body)
                    .fontWeight(.semibold)
            }
            .tint(theme[.internet])
            .frame(minHeight: PaveTouch.minimum)
            if internet.internetStatus.offersRetry {
                // « Internet indisponible — Réessayer »: the status is the retry button.
                Button(internet.internetStatus.label) { internet.retryInternet() }
                    .buttonStyle(.paveDanger)
                    .accessibilityHint(PaveCopy.text("pave.status.retryHint"))
            } else {
                Text(internet.internetStatus.label)
                    .paveText(.label)
                    .fontWeight(.regular)
                    .foregroundStyle(theme[.ink])
            }
            if refused {
                Text(PaveCopy.text("pave.internet.refused"))
                    .paveText(.label)
                    .foregroundStyle(theme[.danger])
            }
            if askDisclosure {
                // First activation: the full disclosure, then an explicit choice.
                Text(PaveCopy.text("pave.internet.confirmTitle"))
                    .paveText(.label)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($disclosureFocused)
                Text(PaveCopy.text("pave.internet.disclosureFull"))
                    .paveText(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Button(PaveCopy.text("pave.internet.confirmAction")) {
                    show(PaveInternetToggle.confirmDisclosure(internet))
                }
                .buttonStyle(.pavePrimary)
                Button(PaveCopy.text("pave.action.cancel")) { askDisclosure = false }
                    .buttonStyle(.paveSecondary)
            } else {
                Text(PaveCopy.text("pave.connexion.internetDisclosure"))
                    .paveText(.caption)
                    .foregroundStyle(theme[.inkMuted])
            }
        }
        .padding(PaveSpace.s4)
        .background(theme[.surface], in: RoundedRectangle(cornerRadius: PaveRadius.control))
        .overlay(RoundedRectangle(cornerRadius: PaveRadius.control)
            .strokeBorder(internet.internetStatus.isEnabled ? theme[.internet] : theme[.line],
                          lineWidth: PaveStroke.control))
    }

    private func show(_ outcome: PaveInternetToggle) {
        askDisclosure = outcome == .needsDisclosure
        refused = outcome == .refused
        if askDisclosure {
            // VoiceOver moves to the disclosure it must hear before « Activer ».
            DispatchQueue.main.async { disclosureFocused = true }
        }
        if refused { PaveAccessibility.announce(PaveCopy.text("pave.internet.refused")) }
    }

    private var bluetoothRole: PaveColorRole {
        switch bluetooth {
        case .on: return peersInRange > 0 ? .success : .warning
        case .off, .unauthorized: return .danger
        }
    }

    private var bluetoothTitle: String {
        switch bluetooth {
        case .on: return PaveCopy.text("pave.connexion.bluetoothOn")
        case .off: return PaveCopy.text("pave.status.bluetoothOff")
        case .unauthorized: return PaveCopy.text("pave.connexion.bluetoothDenied")
        }
    }

    private var bluetoothDetail: String {
        switch bluetooth {
        case .on where peersInRange > 0: return PaveCopy.text("pave.connexion.peers", peersInRange)
        case .on: return PaveCopy.text("pave.status.nobody")
        case .off: return PaveCopy.text("pave.connexion.bluetoothOffHelp")
        case .unauthorized: return PaveCopy.text("pave.connexion.bluetoothDeniedHelp")
        }
    }
}

/// Spoken feedback for changes VoiceOver would otherwise miss.
enum PaveAccessibility {
    static func announce(_ message: String) {
        #if os(iOS)
        UIAccessibility.post(notification: .announcement, argument: message)
        #elseif os(macOS)
        guard let window = NSApp.keyWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        #endif
    }
}

/// Sheet corners use `radius-sheet`; the grabber stays visible.
struct PaveSheetChrome: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 16.4, *) {
            content
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(PaveRadius.sheet)
        } else {
            content.presentationDragIndicator(.visible)
        }
        #else
        content
        #endif
    }
}

struct PaveConnexionSheet_Previews: PreviewProvider {
    static var previews: some View {
        PavePreview.variants {
            PaveConnexionSheet(bluetooth: .on, peersInRange: 7,
                               internet: PaveInternetModeStub(internetStatus: .connected), onClose: {})
        }
        PavePreview.variants {
            PaveConnexionSheet(bluetooth: .unauthorized, peersInRange: 0, internet: PaveInternetModeStub(), onClose: {})
        }
        PavePreview.variants {
            VStack {
                PaveConnexionSheet(bluetooth: .off, peersInRange: 0,
                                   internet: PaveInternetModeStub(internetStatus: .failed), onClose: {})
                PaveConnexionSheet(bluetooth: .on, peersInRange: 0,
                                   internet: PaveInternetModeStub(internetStatus: .paused), onClose: {})
            }
        }
    }
}
