import Foundation
import Testing
@testable import bitchat

/// The private screenshot notice: what goes on the wire, what each side reads, and its setting.
struct WeshScreenshotNoticeTests {
    private static func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "wesh.screenshot.\(UUID().uuidString)")!
    }

    private static func french() throws -> Bundle {
        let path = try #require(PaveCopy.bundle.path(forResource: "fr", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test func theNoticeIsOnUntilSomeoneTurnsItOffAndAnEraseTurnsItBackOn() {
        let defaults = Self.freshDefaults()
        #expect(WeshScreenshotNotice.isEnabled(in: defaults))
        defaults.set(false, forKey: WeshScreenshotNotice.enabledKey)
        #expect(!WeshScreenshotNotice.isEnabled(in: defaults))
        WeshScreenshotNotice.reset(in: defaults)
        #expect(WeshScreenshotNotice.isEnabled(in: defaults))
    }

    /// BitChat and Wesh 1.0.0 recognise this exact English text: it is never translated.
    @Test func theWireTextStaysTheBitChatActionMessage() {
        #expect(WeshScreenshotNotice.wireText(nickname: "Renard 42") == "* Renard 42 took a screenshot *")
        #expect(WeshScreenshotNotice.nickname(inActionBody: "Renard 42 took a screenshot") == "Renard 42")
        #expect(WeshScreenshotNotice.nickname(inActionBody: "Renard 42 sent a hug") == nil)
        #expect(WeshScreenshotNotice.nickname(inActionBody: " took a screenshot") == nil)
    }

    @Test func eachSideReadsTheNoticeInItsOwnLanguage() throws {
        let french = try Self.french()
        let locale = Locale(identifier: "fr")
        #expect(WeshScreenshotNotice.peerLine(nickname: "Renard 42", bundle: french, locale: locale)
            == "Renard 42 a fait une capture d’écran")
        #expect(WeshScreenshotNotice.outgoingNoticeLine(bundle: french, locale: locale)
            == "Votre contact peut recevoir un avis de cette capture d’écran.")
        let englishPath = try #require(PaveCopy.bundle.path(forResource: "en", ofType: "lproj"))
        let english = try #require(Bundle(path: englishPath))
        #expect(WeshScreenshotNotice.outgoingNoticeLine(bundle: english, locale: Locale(identifier: "en"))
            == "Your contact may receive a notice about this screenshot.")
    }
}
