import Foundation
import Testing
@testable import bitchat

@Suite("Wesh presentation localization")
struct WeshPresentationLocalizationTests {
    private func resources(_ language: String) throws -> Bundle {
        let path = try #require(PaveCopy.bundle.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test func englishIdentityRecoveryExplainsEveryStateWithoutChangingRetryAdmission() throws {
        let bundle = try resources("en")
        let locale = Locale(identifier: "en")
        let states: [(NoiseIdentityAvailability, String)] = [
            (.storageUnavailable, "Identity unavailable"),
            (.persistenceUnconfirmed, "Identity pending"),
            (.recoveryRequired, "Identity recovery needed"),
            (.invalidated, "Identity suspended")
        ]
        for (state, title) in states {
            let notice = try #require(WeshNoiseIdentityNotice(state, bundle: bundle, locale: locale))
            #expect(notice.title == title)
            #expect(notice.message.contains("identity") || notice.message.contains("keys"))
            #expect(notice.allowsRetry == (state != .invalidated))
        }
        #expect(WeshNoiseIdentityNotice(.available, bundle: bundle, locale: locale) == nil)
    }

    @Test func englishContactRecoveryKeepsRetryAndExplicitResetDistinct() throws {
        let bundle = try resources("en")
        let locale = Locale(identifier: "en")
        let locked = try #require(WeshContactStorageNotice(
            identityAvailable: false, identityRequiresRecovery: false, contactsState: .unavailable,
            bundle: bundle, locale: locale))
        #expect(locked.title == "Contacts unavailable")
        #expect(!locked.offersReset)
        let recovery = try #require(WeshContactStorageNotice(
            identityAvailable: false, identityRequiresRecovery: true, contactsState: .available,
            bundle: bundle, locale: locale))
        #expect(recovery.title == "Unreadable contacts")
        #expect(recovery.message.contains("does not erase"))
        #expect(recovery.offersReset)
    }

    @Test func englishEraseFeedbackPreservesLocalScopeAndUnconfirmedFailure() throws {
        let bundle = try resources("en")
        let locale = Locale(identifier: "en")
        #expect(WeshFeedbackCopy.eraseOutcome(true, bundle: bundle, locale: locale)
            == "Local erasure confirmed. Verify your contacts again before any private exchange.")
        #expect(WeshFeedbackCopy.eraseOutcome(false, bundle: bundle, locale: locale)
            == "Local erasure not finished. Wesh erases everything again the next time it opens, before connecting. Until then, it stays offline.")
        let warning = WeshFeedbackCopy.eraseWarning(bundle: bundle, locale: locale)
        #expect(warning.contains("other people") && warning.contains("backups"))
        #expect(warning.contains("does not guarantee physical erasure"))
        #expect(warning.contains("irreversible"))
    }

    @Test func englishComposerRefusalsExplainThatTheDraftIsRetained() throws {
        let bundle = try resources("en")
        let locale = Locale(identifier: "en")
        #expect(WeshFeedbackCopy.composerTooLong(bundle: bundle, locale: locale)
            == "Message too long. Shorten it to send. Your draft is kept.")
        #expect(WeshFeedbackCopy.composerChanged(bundle: bundle, locale: locale)
            == "The draft changed. Read the text again before sending.")
    }

    @Test func frenchCopyAndRecoveryFlagsArePreserved() throws {
        let bundle = try resources("fr")
        let locale = Locale(identifier: "fr")
        let notice = try #require(WeshNoiseIdentityNotice(.storageUnavailable, bundle: bundle, locale: locale))
        #expect(notice.title == "Identité indisponible")
        #expect(notice.message == "Wesh ne peut pas lire ses clés sur ce téléphone. Déverrouillez-le, puis réessayez. L’envoi et votre QR sont suspendus.")
        #expect(notice.allowsRetry)
        #expect(WeshNoiseIdentityNotice(.invalidated, bundle: bundle, locale: locale)?.allowsRetry == false)
        #expect(WeshContactStorageNotice(identityAvailable: true, identityRequiresRecovery: false,
                                        contactsState: .available, bundle: bundle, locale: locale) == nil)
        #expect(WeshFeedbackCopy.eraseOutcome(false, bundle: bundle, locale: locale)
            == "Effacement local à terminer. Wesh efface tout à nouveau à sa prochaine ouverture, avant de se connecter. D’ici là, il reste hors ligne.")
        #expect(WeshFeedbackCopy.composerTooLong(bundle: bundle, locale: locale)
            == "Message trop long. Raccourcissez-le pour l’envoyer. Votre brouillon est conservé.")
    }

    @Test func scopedResourcesFormatCountsAndKeepUserTextVerbatim() throws {
        let english = try resources("en")
        let french = try resources("fr")
        let name = "Nora %@ 100% 🪨"
        #expect(PaveCopy.text("pave.action.block", bundle: english, locale: Locale(identifier: "en"), name)
            == "Block " + name)
        #expect(PaveCopy.text("pave.action.block", bundle: french, locale: Locale(identifier: "fr"), name)
            == "Bloquer " + name)
        #expect(PaveCopy.text("pave.inbox.publicInRange", bundle: english, locale: Locale(identifier: "en"), 12)
            == "12 in range")
        #expect(PaveCopy.text("pave.inbox.publicInRange", bundle: french, locale: Locale(identifier: "fr"), 12)
            == "12 à portée")
        #expect(PaveCopy.text("pave.composer.counter", bundle: english, locale: Locale(identifier: "en"), "2001", "2000")
            == "2001 / 2000 bytes")
    }
}
