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

    init?(identityAvailable: Bool, identityRequiresRecovery: Bool, contactsState: WeshQRTrust.StorageState,
          bundle: Bundle = PaveCopy.bundle, locale: Locale = .current) {
        if identityRequiresRecovery || contactsState == .recoveryRequired {
            title = PaveCopy.text("pave.contacts.recovery.title", bundle: bundle, locale: locale)
            message = PaveCopy.text("pave.contacts.recovery.message", bundle: bundle, locale: locale)
            offersReset = true
        } else if !identityAvailable || contactsState == .unavailable {
            title = PaveCopy.text("pave.contacts.unavailable.title", bundle: bundle, locale: locale)
            message = PaveCopy.text("pave.contacts.unavailable.message", bundle: bundle, locale: locale)
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
            Button(PaveCopy.text("pave.delivery.retry"), action: retry).frame(minHeight: 44)
                .accessibilityHint(PaveCopy.text("pave.wesh.contacts.retryHint"))
            if notice.offersReset {
                Button(PaveCopy.text("pave.wesh.contacts.reset"), role: .destructive) {
                    chrome.requestPanicWipe()
                }.frame(minHeight: 44)
                    .accessibilityHint(PaveCopy.text("pave.wesh.contacts.resetHint"))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
