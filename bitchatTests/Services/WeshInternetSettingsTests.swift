import Foundation
import Testing
@testable import bitchat

struct WeshInternetSettingsTests {
    @Test func keysMatchTheSpecAndTheToggleDefaultsOff() throws {
        #expect(WeshInternetSettings.enabledKey == "wesh.internetMode.enabled.v1")
        #expect(WeshInternetSettings.disclosureAcceptedKey == "wesh.internetDisclosureAccepted.v1")
        let suite = "wesh.internet.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!WeshInternetSettings.isEnabled(in: defaults))
        defaults.set(true, forKey: WeshInternetSettings.enabledKey)
        #expect(WeshInternetSettings.isEnabled(in: defaults))
    }
}
