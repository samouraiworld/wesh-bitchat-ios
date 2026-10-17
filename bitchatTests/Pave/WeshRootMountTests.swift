import Foundation
import Testing
@testable import bitchat

/// What a first launch, an update and an erase put on screen, and what waits for the welcome.
struct WeshRootMountTests {
    private static func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "wesh.root.\(UUID().uuidString)")!
    }

    @Test func aFirstLaunchOpensOnTheWelcome() {
        let fresh = Self.freshDefaults()
        #expect(WeshRootScreen(panicRecoveryBlocked: false, welcomed: WeshWelcome.isDone(in: fresh)) == .welcome)
        fresh.set(true, forKey: WeshWelcome.key)
        #expect(WeshRootScreen(panicRecoveryBlocked: false, welcomed: WeshWelcome.isDone(in: fresh)) == .tabs)
        // An unfinished erase outranks everything, the welcome included.
        #expect(WeshRootScreen(panicRecoveryBlocked: true, welcomed: false) == .eraseRecovery)
    }

    @Test func anUpdateKeepsANicknameSomeoneChose() {
        #expect(WeshWelcome.keptNickname(" Renard 42 ") == "Renard 42")
        // The stand-in set before any choice, or nothing, gives way to a suggested name.
        #expect(WeshWelcome.keptNickname("anon1234") == nil)
        #expect(WeshWelcome.keptNickname("   ") == nil)
        #expect(WeshWelcome.keptNickname("anon12345") == "anon12345")
    }

    @Test func noBluetoothManagerExistsBeforeTheWelcomeStep() {
        let keychain = MockKeychain()
        let service = BLEService(keychain: keychain, idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
                                 identityManager: MockIdentityManager(keychain),
                                 initializeBluetoothManagers: true, deferBluetoothPrompt: true)
        defer { service.stopServices() }
        #expect(service.holdsBluetoothPrompt)
        #expect(service.centralManager == nil && service.peripheralManager == nil)
    }

    @Test func theWelcomeStepReleasesTheBluetoothPromptOnce() {
        let keychain = MockKeychain()
        let service = BLEService(keychain: keychain, idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
                                 identityManager: MockIdentityManager(keychain),
                                 initializeBluetoothManagers: false, deferBluetoothPrompt: true)
        defer { service.stopServices() }
        #expect(service.holdsBluetoothPrompt)
        service.allowBluetoothPrompt()
        #expect(!service.holdsBluetoothPrompt)
        service.allowBluetoothPrompt()
        #expect(!service.holdsBluetoothPrompt)
    }

    @Test func aServiceBuiltWithoutTheWelcomeNeverHoldsThePrompt() {
        let keychain = MockKeychain()
        let service = BLEService(keychain: keychain, idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
                                 identityManager: MockIdentityManager(keychain), initializeBluetoothManagers: false)
        defer { service.stopServices() }
        #expect(!service.holdsBluetoothPrompt)
    }

    @Test func theDiscretionRowFollowsTheNotificationPreviewSetting() {
        let defaults = Self.freshDefaults()
        let note = WeshMeetingNoteStore.Content()
        // Hidden by default.
        #expect(PaveSettingsSummary.wesh(nickname: "Renard", meetingNote: note, blockedCount: 0, defaults: defaults)
            .value(for: .discretion) == PaveCopy.text("pave.settings.previewsHidden"))
        defaults.set(false, forKey: NotificationPrivacySettings.hidePreviewsKey)
        #expect(PaveSettingsSummary.wesh(nickname: "Renard", meetingNote: note, blockedCount: 0, defaults: defaults)
            .value(for: .discretion) == PaveCopy.text("pave.settings.previewsShown"))
        defaults.set("day", forKey: "wesh.appearance.v1")
        #expect(PaveSettingsSummary.wesh(nickname: "Renard", meetingNote: note, blockedCount: 2, defaults: defaults)
            .value(for: .appearance) == PaveCopy.text("pave.theme.jour"))
    }
}
