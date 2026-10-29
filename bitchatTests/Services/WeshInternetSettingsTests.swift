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

    @Test func aBuildWithoutInternetIgnoresAStoredOn() throws {
        let suite = "wesh.internet.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: WeshInternetSettings.enabledKey)
        #expect(!WeshInternetSettings.isEnabled(in: defaults, available: false))
        // This build offers the Internet opt-in, still off until the user accepts the disclosure and turns it on.
        #expect(WeshInternetSettings.isAvailable)
    }

    @Test func releaseConfigShipsBuild108WithInternetOptInAvailable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let xcconfig = try String(
            contentsOf: root.appendingPathComponent("Configs/Release.xcconfig"),
            encoding: .utf8
        )
        let uncommented = xcconfig
            .split(whereSeparator: \.isNewline)
            .map { $0.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
        #expect(uncommented.contains("MARKETING_VERSION = 1.0.1"))
        #expect(uncommented.contains("CURRENT_PROJECT_VERSION = 109"))
        #expect(uncommented.contains("WESH_INTERNET_AVAILABLE = YES"))
        #expect(!uncommented.contains("WESH_INTERNET_AVAILABLE = NO"))
    }
}
