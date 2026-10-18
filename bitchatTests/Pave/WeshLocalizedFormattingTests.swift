import Foundation
import Testing
@testable import bitchat

@Suite("Wesh localized formats")
struct WeshLocalizedFormattingTests {
    private func resources(_ language: String) throws -> Bundle {
        let path = try #require(PaveCopy.bundle.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test func requestCountsFollowEachLanguagesPluralRules() throws {
        let english = try resources("en")
        let french = try resources("fr")
        for (count, englishText, frenchText) in [
            (0, "Not verified · 0 messages", "Non vérifié · 0 message"),
            (1, "Not verified · 1 message", "Non vérifié · 1 message"),
            (2, "Not verified · 2 messages", "Non vérifié · 2 messages")
        ] {
            #expect(PaveCopy.text("pave.wesh.request.count", bundle: english, locale: Locale(identifier: "en"), count)
                == englishText)
            #expect(PaveCopy.text("pave.wesh.request.count", bundle: french, locale: Locale(identifier: "fr"), count)
                == frenchText)
        }
    }

    @Test func requestAccessibilityKeepsNicknameAndFingerprintAsArguments() throws {
        let name = "Nora %lld 🪨"
        let fingerprint = "12 AB, 34 CD"
        let english = try resources("en")
        let french = try resources("fr")
        #expect(PaveCopy.text("pave.wesh.request.accessibility", bundle: english, locale: Locale(identifier: "en"), name, fingerprint)
            == "Request from " + name + ", not verified, " + fingerprint)
        #expect(PaveCopy.text("pave.wesh.request.accessibility", bundle: french, locale: Locale(identifier: "fr"), name, fingerprint)
            == "Demande de " + name + ", non vérifiée, " + fingerprint)
    }

    @Test func englishDeliveryStillDistinguishesTransmissionFromReceiptAndKeepsStoredAppearanceIDs() throws {
        let english = try resources("en")
        let locale = Locale(identifier: "en")
        #expect(WeshDelivery.label(.sent, bundle: english, locale: locale) == "Transmission unconfirmed")
        #expect(WeshDelivery.label(.carried, bundle: english, locale: locale) == "Handed to a relay · receipt unconfirmed")
        #expect(WeshDelivery.label(.delivered(to: "Nora", at: Date()), bundle: english, locale: locale) == "Receipt confirmed")
        #expect(WeshDelivery.publicLabel(.read(by: "Nora", at: Date()), bundle: english, locale: locale)
            == "Public broadcast · receipt unconfirmed")
        #expect(WeshAppearance(rawValue: "night")?.title(bundle: english, locale: locale) == "Night")
        #expect(WeshAppearance(rawValue: "day")?.title(bundle: english, locale: locale) == "Day")
        #expect(WeshAppearance(rawValue: "night")?.paveTheme == .nuit)
        #expect(WeshAppearance(rawValue: "day")?.paveTheme == .jour)
    }
}
