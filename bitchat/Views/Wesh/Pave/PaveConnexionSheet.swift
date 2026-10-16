import SwiftUI

/// What the Internet mode is doing, as shown to people.
enum PaveInternetStatus: Equatable {
    case off
    case connecting
    case connected(relayCount: Int?)
    case paused
    case failed

    var isEnabled: Bool { self != .off }

    var label: String {
        switch self {
        case .off: return PaveCopy.text("pave.internet.off")
        case .connecting: return PaveCopy.text("pave.internet.connecting")
        case .connected(let relays?): return PaveCopy.text("pave.internet.connectedRelays", relays)
        case .connected(nil): return PaveCopy.text("pave.internet.connected")
        case .paused: return PaveCopy.text("pave.internet.paused")
        case .failed: return PaveCopy.text("pave.internet.failed")
        }
    }
}

/// The Internet mode as the Connexion sheet needs it. The Internet state machine adopts this
/// when its UI is wired; until then `PaveInternetModeStub` stands in.
@MainActor
protocol WeshInternetModeProviding: ObservableObject {
    var internetStatus: PaveInternetStatus { get }
    func setInternetModeEnabled(_ enabled: Bool)
}

/// Placeholder until the real Internet mode lands: off by default, toggles locally only.
@MainActor
final class PaveInternetModeStub: WeshInternetModeProviding {
    @Published private(set) var internetStatus: PaveInternetStatus

    init(internetStatus: PaveInternetStatus = .off) {
        self.internetStatus = internetStatus
    }

    func setInternetModeEnabled(_ enabled: Bool) {
        internetStatus = enabled ? .connecting : .off
    }
}

enum PaveBluetoothStatus {
    case on, off, unauthorized
}

/// Connexion: Bluetooth, phones in range, the Internet switch and what it reveals.
struct PaveConnexionSheet<InternetMode: WeshInternetModeProviding>: View {
    let bluetooth: PaveBluetoothStatus
    let peersInRange: Int
    @ObservedObject var internet: InternetMode
    let onClose: () -> Void

    @Environment(\.paveTheme) private var theme
    @Environment(\.openURL) private var openURL

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
                                 set: { internet.setInternetModeEnabled($0) })) {
                Label(PaveCopy.text("pave.connexion.internetMode"), systemImage: "globe")
                    .paveText(.body)
                    .fontWeight(.semibold)
            }
            .tint(theme[.internet])
            .frame(minHeight: PaveTouch.minimum)
            Text(internet.internetStatus.label)
                .paveText(.label)
                .fontWeight(.regular)
            Text(PaveCopy.text("pave.connexion.internetDisclosure"))
                .paveText(.caption)
                .foregroundStyle(theme[.inkMuted])
        }
        .padding(PaveSpace.s4)
        .background(theme[.surface], in: RoundedRectangle(cornerRadius: PaveRadius.control))
        .overlay(RoundedRectangle(cornerRadius: PaveRadius.control)
            .strokeBorder(internet.internetStatus.isEnabled ? theme[.internet] : theme[.line],
                          lineWidth: PaveStroke.control))
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
                               internet: PaveInternetModeStub(internetStatus: .connected(relayCount: 3)), onClose: {})
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
