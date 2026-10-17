import Foundation
import Testing

/// The V1 has no voice and no media: the app must not declare a microphone
/// or photo-library purpose string, nor the macOS microphone, file or
/// picture entitlements, or the stores would show a permission the app
/// never uses.
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

    @Test func infoPlistDeclaresNoMicrophoneOrPhotoPurpose() throws {
        let plist = try propertyList("Info.plist")
        #expect(plist["NSMicrophoneUsageDescription"] == nil)
        #expect(plist["NSPhotoLibraryUsageDescription"] == nil)
        #expect(plist["NSPhotoLibraryAddUsageDescription"] == nil)
        // Guard against a silently empty read passing the checks above.
        #expect(plist["NSCameraUsageDescription"] != nil)
    }

    @Test(arguments: ["en.lproj/InfoPlist.strings", "fr.lproj/InfoPlist.strings"])
    func localizedInfoPlistDeclaresNoMicrophoneOrPhotoPurpose(_ relativePath: String) throws {
        let strings = try propertyList(relativePath)
        #expect(strings["NSMicrophoneUsageDescription"] == nil)
        #expect(strings["NSPhotoLibraryUsageDescription"] == nil)
        #expect(strings["NSPhotoLibraryAddUsageDescription"] == nil)
        #expect(strings["NSCameraUsageDescription"] != nil)
    }

    @Test func macOSEntitlementsRequestNoMicrophoneFilesOrPictures() throws {
        let entitlements = try propertyList("bitchat-macOS.entitlements")
        #expect(entitlements["com.apple.security.device.microphone"] == nil)
        #expect(entitlements["com.apple.security.files.user-selected.read-only"] == nil)
        #expect(entitlements["com.apple.security.files.user-selected.read-write"] == nil)
        #expect(entitlements["com.apple.security.assets.pictures.read-only"] == nil)
        #expect(entitlements["com.apple.security.assets.pictures.read-write"] == nil)
        // The QR scanner keeps the camera.
        #expect(entitlements["com.apple.security.device.camera"] as? Bool == true)
        #expect(entitlements["com.apple.security.device.bluetooth"] as? Bool == true)
    }
}
