import BitFoundation
import Foundation
import SwiftUI
import Testing
@testable import bitchat

@Suite("Wesh private data at rest", .serialized)
@MainActor
struct WeshPrivateDataAtRestTests {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wesh-at-rest-\(UUID().uuidString)", isDirectory: true)
        let keychain = MockKeychain()
        let suite = "wesh-at-rest-\(UUID().uuidString)"
        lazy var defaults = UserDefaults(suiteName: suite)!
        var url: URL { root.appendingPathComponent("record.enc") }

        func store() -> WeshSealedStore {
            WeshSealedStore(keychain: keychain, fileURL: url, keyName: "record.test", context: "wesh.record.test")
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    private let alice = Data(repeating: 21, count: 32)
    private let bob = Data(repeating: 22, count: 32)

    // MARK: Sealed store

    @Test func sealedRecordIsEncryptedExcludedFromBackupAndRoundTrips() throws {
        let fixture = Fixture()
        let plaintext = Data("Nora synthétique, rendez-vous place synthétique".utf8)
        try fixture.store().save(plaintext)
        let raw = try Data(contentsOf: fixture.url)
        #expect(raw.range(of: Data("Nora".utf8)) == nil)
        #expect(raw.range(of: Data("synthétique".utf8)) == nil)
        let values = try fixture.url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #expect(try fixture.store().load() == plaintext)
    }

    @Test func sealedStoreNeverReadsAnUnreadableRecordAsEmptyOrOverwritesIt() throws {
        let fixture = Fixture()
        try fixture.store().save(Data("original".utf8))
        let original = try Data(contentsOf: fixture.url)

        fixture.keychain.simulatedReadError = .deviceLocked
        #expect(throws: WeshSealedStore.Failure.storageUnavailable) { try fixture.store().load() }
        #expect(throws: WeshSealedStore.Failure.storageUnavailable) { try fixture.store().save(Data("x".utf8)) }
        fixture.keychain.simulatedReadError = nil

        _ = fixture.keychain.deleteIdentityKey(forKey: "record.test")
        #expect(throws: WeshSealedStore.Failure.recoveryRequired) { try fixture.store().load() }
        #expect(throws: WeshSealedStore.Failure.recoveryRequired) { try fixture.store().save(Data("x".utf8)) }
        #expect(try Data(contentsOf: fixture.url) == original)

        _ = fixture.keychain.saveIdentityKey(Data(repeating: 9, count: 32), forKey: "record.test")
        #expect(throws: WeshSealedStore.Failure.recoveryRequired) { try fixture.store().load() }
        #expect(throws: WeshSealedStore.Failure.recoveryRequired) { try fixture.store().save(Data("x".utf8)) }
        #expect(try Data(contentsOf: fixture.url) == original)
    }

    @Test func sealedStoreWipeConfirmsFileAndKeyAreGone() throws {
        let fixture = Fixture()
        try fixture.store().save(Data("secret".utf8))
        try fixture.store().wipe()
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(fixture.keychain.getIdentityKey(forKey: "record.test") == nil)
        #expect(try fixture.store().load() == nil)
        try fixture.store().wipe()
    }

    // MARK: QR contacts

    @Test func qrContactsMigrateFromPlaintextDefaultsOnceThenDeleteThem() throws {
        let fixture = Fixture()
        let legacy = [WeshQRTrust.Contact(noiseKeyHex: alice.hexEncodedString(), nickname: "Alice")]
        fixture.defaults.set(try JSONEncoder().encode(legacy), forKey: WeshQRTrust.legacyContactsKey)
        fixture.defaults.set([alice.sha256Fingerprint()], forKey: WeshQRTrust.legacyFingerprintsKey)

        let trust = WeshQRTrust(storage: fixture.store(), legacyDefaults: fixture.defaults)
        #expect(trust.storageState == .available)
        #expect(trust.contacts == legacy)
        #expect(trust.fingerprints == [alice.sha256Fingerprint()])
        #expect(fixture.defaults.object(forKey: WeshQRTrust.legacyContactsKey) == nil)
        #expect(fixture.defaults.object(forKey: WeshQRTrust.legacyFingerprintsKey) == nil)
        let raw = try Data(contentsOf: fixture.url)
        #expect(raw.range(of: Data("Alice".utf8)) == nil)

        let reloaded = WeshQRTrust(storage: fixture.store(), legacyDefaults: fixture.defaults)
        #expect(reloaded.contacts == legacy)
    }

    @Test func qrContactsMigrationKeepsPlaintextWhenSealedWriteFails() throws {
        let fixture = Fixture()
        let legacy = [WeshQRTrust.Contact(noiseKeyHex: alice.hexEncodedString(), nickname: "Alice")]
        fixture.defaults.set(try JSONEncoder().encode(legacy), forKey: WeshQRTrust.legacyContactsKey)
        fixture.keychain.simulatedSaveError = .deviceLocked

        let trust = WeshQRTrust(storage: fixture.store(), legacyDefaults: fixture.defaults)
        #expect(trust.storageState == .unavailable)
        #expect(trust.contacts.isEmpty)
        #expect(fixture.defaults.object(forKey: WeshQRTrust.legacyContactsKey) != nil)

        fixture.keychain.simulatedSaveError = nil
        trust.reloadIfNeeded()
        #expect(trust.storageState == .available)
        #expect(trust.contacts == legacy)
        #expect(fixture.defaults.object(forKey: WeshQRTrust.legacyContactsKey) == nil)
    }

    @Test func lockedContactStoreFailsClosedAndRecoversAfterUnlock() throws {
        let fixture = Fixture()
        #expect(WeshQRTrust(storage: fixture.store()).record(sessionKey: alice, nickname: "Alice"))
        let saved = try Data(contentsOf: fixture.url)

        fixture.keychain.simulatedReadError = .deviceLocked
        let trust = WeshQRTrust(storage: fixture.store())
        #expect(trust.storageState == .unavailable)
        #expect(trust.contacts.isEmpty && trust.fingerprints.isEmpty)
        #expect(!trust.record(sessionKey: bob, nickname: "Bob"))
        #expect(!WeshQRTrust.canSend(sessionKey: alice, qrFingerprints: trust.fingerprints, locallyVerified: true))
        #expect(try Data(contentsOf: fixture.url) == saved)

        fixture.keychain.simulatedReadError = nil
        trust.reloadIfNeeded()
        #expect(trust.storageState == .available)
        #expect(trust.contacts.map(\.nickname) == ["Alice"])
    }

    @Test func corruptContactStoreIsPreservedUntilExplicitClear() throws {
        let fixture = Fixture()
        #expect(WeshQRTrust(storage: fixture.store()).record(sessionKey: alice, nickname: "Alice"))
        _ = fixture.keychain.saveIdentityKey(Data(repeating: 7, count: 32), forKey: "record.test")
        let saved = try Data(contentsOf: fixture.url)

        let trust = WeshQRTrust(storage: fixture.store())
        #expect(trust.storageState == .recoveryRequired)
        #expect(!trust.record(sessionKey: bob, nickname: "Bob"))
        trust.reloadIfNeeded()
        #expect(trust.storageState == .recoveryRequired)
        #expect(try Data(contentsOf: fixture.url) == saved)

        #expect(trust.clear())
        #expect(trust.storageState == .available)
        #expect(trust.record(sessionKey: bob, nickname: "Bob"))
        #expect(WeshQRTrust(storage: fixture.store()).contacts.map(\.nickname) == ["Bob"])
    }

    @Test func clearingContactsRemovesSealedFileKeyAndLegacyCopy() throws {
        let fixture = Fixture()
        let trust = WeshQRTrust(storage: fixture.store(), legacyDefaults: fixture.defaults)
        #expect(trust.record(sessionKey: alice, nickname: "Alice"))
        fixture.defaults.set(Data("stale".utf8), forKey: WeshQRTrust.legacyContactsKey)
        #expect(trust.clear())
        #expect(trust.contacts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(fixture.keychain.getIdentityKey(forKey: "record.test") == nil)
        #expect(fixture.defaults.object(forKey: WeshQRTrust.legacyContactsKey) == nil)
    }

    // MARK: Meeting note

    @Test func meetingNoteMigratesFromPlaintextDefaultsAndDeletesThem() throws {
        let fixture = Fixture()
        fixture.defaults.set("Titre", forKey: "wesh.meeting.title")
        fixture.defaults.set("Lieu synthétique", forKey: "wesh.meeting.place")
        fixture.defaults.set(42.0, forKey: "wesh.meeting.date")

        let note = WeshMeetingNoteStore(storage: fixture.store(), legacyDefaults: fixture.defaults)
        #expect(note.content == .init(title: "Titre", place: "Lieu synthétique", note: "", date: 42))
        for key in WeshMeetingNoteStore.legacyKeys { #expect(fixture.defaults.object(forKey: key) == nil) }
        #expect(try Data(contentsOf: fixture.url).range(of: Data("Lieu".utf8)) == nil)
        #expect(WeshMeetingNoteStore(storage: fixture.store()).content.place == "Lieu synthétique")
    }

    @Test func unreadableMeetingNoteRefusesEditsUntilCleared() throws {
        let fixture = Fixture()
        let first = WeshMeetingNoteStore(storage: fixture.store())
        #expect(first.edit(\.note, value: "Original", generation: first.generation))
        _ = fixture.keychain.saveIdentityKey(Data(repeating: 5, count: 32), forKey: "record.test")
        let saved = try Data(contentsOf: fixture.url)

        let note = WeshMeetingNoteStore(storage: fixture.store())
        #expect(note.storageState == .recoveryRequired)
        #expect(!note.edit(\.note, value: "Remplacement", generation: note.generation))
        #expect(try Data(contentsOf: fixture.url) == saved)
        #expect(note.clear(generation: note.generation))
        #expect(note.storageState == .available)
        #expect(note.edit(\.note, value: "Nouvelle", generation: note.generation))
    }

    // MARK: Panic wipe

    @Test(arguments: [false, true])
    func panicWipeClearsNotificationsAndCommitsOnlyAfterContactWipe(failContacts: Bool) {
        var notificationsCleared = 0
        var contactWipes = 0
        var wipes = PanicPersistentStoreWipes(
            courier: { true }, bridge: { true }, publicArchive: { true },
            prekeys: { true }, board: { true }, sharedContent: { true }
        )
        wipes.qrContacts = { contactWipes += 1; return !failContacts }
        wipes.notifications = { notificationsCleared += 1 }
        var committed = 0
        let operations = PanicRecoveryOperations(isPending: { false }, begin: {
            PanicRecoveryIntent(fileMarkerEstablished: true, externalMarkerEstablished: false)
        }, wipeMedia: { _ in }, complete: { committed += 1 })
        let keychain = MockKeychain()
        let vm = ChatViewModel(keychain: keychain, idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain), transport: MockTransport(),
            panicRecoveryOperations: operations, weshPrivatePolicyEnabled: true,
            panicPersistentStoreWipes: wipes)
        #expect(vm.panicClearAllData() == !failContacts)
        #expect(contactWipes == 1)
        #expect(notificationsCleared == 1)
        #expect(committed == (failContacts ? 0 : 1))
        #expect(vm.panicRecoveryBlocked == failContacts)
    }

    @Test func panicWipeCommitsOnlyOnceTheIdentityCacheIsWritableAgain() {
        let keychain = MockKeychain()
        let identity = SecureIdentityStateManager(keychain)
        var committed = 0
        let operations = PanicRecoveryOperations(isPending: { false }, begin: {
            PanicRecoveryIntent(fileMarkerEstablished: true, externalMarkerEstablished: false)
        }, wipeMedia: { _ in }, complete: { committed += 1 })
        let wipes = PanicPersistentStoreWipes(
            courier: { true }, bridge: { true }, publicArchive: { true },
            prekeys: { true }, board: { true }, sharedContent: { true }
        )
        let vm = ChatViewModel(keychain: keychain, idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: identity, transport: MockTransport(),
            panicRecoveryOperations: operations, weshPrivatePolicyEnabled: true,
            panicPersistentStoreWipes: wipes)
        keychain.identitySaveFault = { _, _, _ in .deviceLocked }
        #expect(!vm.panicClearAllData())
        #expect(committed == 0)
        keychain.identitySaveFault = nil
        #expect(vm.panicClearAllData())
        #expect(committed == 1 && identity.isPersistenceAvailable)
    }

    // MARK: Identity cache recovery

    @Test func unreadableIdentityCacheOffersAnExplicitResetThatRestoresPersistence() {
        let keychain = MockKeychain()
        _ = keychain.saveIdentityKey(Data(repeating: 1, count: 32), forKey: "identityCacheEncryptionKey")
        _ = keychain.saveIdentityKey(Data("not a sealed cache".utf8), forKey: "bitchat.identityCache.v2")
        let identity = SecureIdentityStateManager(keychain)
        #expect(!identity.isPersistenceAvailable)
        #expect(identity.persistenceRequiresRecovery)
        identity.forceSave()
        #expect(identity.persistenceRequiresRecovery)

        let notice = WeshContactStorageNotice(identityAvailable: identity.isPersistenceAvailable,
                                              identityRequiresRecovery: identity.persistenceRequiresRecovery,
                                              contactsState: .available)
        #expect(notice?.offersReset == true)

        identity.clearAllIdentityData()
        #expect(identity.isPersistenceAvailable)
        #expect(!identity.persistenceRequiresRecovery)
    }

    @Test func lockedIdentityCacheIsRetryableAndNeverOffersReset() {
        let keychain = MockKeychain()
        keychain.simulatedReadError = .deviceLocked
        let identity = SecureIdentityStateManager(keychain)
        #expect(!identity.isPersistenceAvailable)
        #expect(!identity.persistenceRequiresRecovery)
        let notice = WeshContactStorageNotice(identityAvailable: false, identityRequiresRecovery: false,
                                              contactsState: .available)
        #expect(notice?.offersReset == false)
        keychain.simulatedReadError = nil
        identity.forceSave()
        #expect(identity.isPersistenceAvailable)
    }

    @Test func contactStorageNoticeMapsEveryState() {
        #expect(WeshContactStorageNotice(identityAvailable: true, identityRequiresRecovery: false, contactsState: .available) == nil)
        #expect(WeshContactStorageNotice(identityAvailable: true, identityRequiresRecovery: false, contactsState: .unavailable)?.offersReset == false)
        #expect(WeshContactStorageNotice(identityAvailable: true, identityRequiresRecovery: false, contactsState: .recoveryRequired)?.offersReset == true)
    }

    // MARK: App switcher

    @Test func privacyCoverHidesContentWheneverTheSceneIsNotActive() {
        #expect(!WeshPrivacyCover.covers(.active))
        #expect(WeshPrivacyCover.covers(.inactive))
        #expect(WeshPrivacyCover.covers(.background))
    }
}
