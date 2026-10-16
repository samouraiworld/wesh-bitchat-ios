import SwiftUI

/// The app-switcher snapshot is taken while the scene is not active. Anything
/// other than `.active` hides the conversation behind an opaque cover.
enum WeshPrivacyCover {
    static func covers(_ phase: ScenePhase) -> Bool { phase != .active }
}

struct WeshPrivacyCoverView: View {
    @Environment(\.weshTheme) private var theme
    var body: some View {
        ZStack {
            theme.canvas.ignoresSafeArea()
            Text("Wesh").font(.system(.title, design: .rounded).weight(.bold)).foregroundStyle(theme.secondary)
        }
        .accessibilityHidden(true)
    }
}

/// Contacts and their verifications live in the identity cache and the sealed
/// QR list. Retrying never erases them; only the explicit reset does.
struct WeshContactStorageNotice: Equatable {
    let title: String
    let message: String
    let offersReset: Bool

    init?(identityAvailable: Bool, identityRequiresRecovery: Bool, contactsState: WeshQRTrust.StorageState) {
        if identityRequiresRecovery || contactsState == .recoveryRequired {
            title = "Contacts illisibles"
            message = "Les contacts et vérifications conservés sur ce téléphone ne peuvent pas être lus. Réessayer ne les efface pas. Pour repartir de zéro, réinitialisez : toutes les données de Wesh sur ce téléphone seront effacées."
            offersReset = true
        } else if !identityAvailable || contactsState == .unavailable {
            title = "Contacts indisponibles"
            message = "Wesh ne peut pas lire vos contacts pour le moment. Déverrouillez le téléphone, puis réessayez."
            offersReset = false
        } else {
            return nil
        }
    }
}

struct WeshContactStorageRecoveryPanel: View {
    let notice: WeshContactStorageNotice
    let retry: () -> Void
    @EnvironmentObject private var chrome: AppChromeModel
    @Environment(\.weshTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(notice.title, systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.headline).accessibilityAddTraits(.isHeader)
            Text(notice.message).font(.subheadline).foregroundStyle(theme.secondary)
            Button("Réessayer", action: retry).frame(minHeight: 44)
                .accessibilityHint("Relire les contacts sans rien effacer")
            if notice.offersReset {
                Button("Réinitialiser les contacts et l’identité", role: .destructive) {
                    chrome.requestPanicWipe()
                }.frame(minHeight: 44)
                    .accessibilityHint("Demande confirmation avant d’effacer toutes les données de Wesh sur ce téléphone")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
