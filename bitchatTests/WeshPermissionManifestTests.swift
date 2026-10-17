import Foundation
import Testing

/// The V1 has no voice: the app must not declare a microphone purpose
/// string or the macOS microphone entitlement, or the stores would show a
/// permission the app never uses.
@Suite("Wesh permission manifest")
struct WeshPermissionManifestTests {
    /// Under SwiftPM, Bundle.main is the test runner, so read from source.
    private static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // bitchatTests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("bitchat", isDirectory: true)

    private func propertyList(_ relativePath: String) throws -> [String: Any] {
        let url = Self.appSources.appendingPathComponent(relativePath)
        let object = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            format: nil
        )
        return try #require(object as? [String: Any], "\(relativePath) is not a dictionary")
    }

    @Test func infoPlistDeclaresNoMicrophonePurpose() throws {
        let plist = try propertyList("Info.plist")
        #expect(plist["NSMicrophoneUsageDescription"] == nil)
        // Guard against a silently empty read passing the check above.
        #expect(plist["NSCameraUsageDescription"] != nil)
    }

    @Test(arguments: ["en.lproj/InfoPlist.strings", "fr.lproj/InfoPlist.strings"])
    func localizedInfoPlistDeclaresNoMicrophonePurpose(_ relativePath: String) throws {
        let strings = try propertyList(relativePath)
        #expect(strings["NSMicrophoneUsageDescription"] == nil)
        #expect(strings["NSCameraUsageDescription"] != nil)
    }

    @Test func macOSEntitlementsRequestNoMicrophone() throws {
        let entitlements = try propertyList("bitchat-macOS.entitlements")
        #expect(entitlements["com.apple.security.device.microphone"] == nil)
        #expect(entitlements["com.apple.security.device.bluetooth"] as? Bool == true)
    }
}
