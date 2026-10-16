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

        var failWrites = false
        var failRemovals = false

        func store() -> WeshSealedStore {
            let live = ComposerDraftPersistence.FileAccess.live
            let files = ComposerDraftPersistence.FileAccess(read: live.read, write: { [unowned self] data, url in
                if self.failWrites { throw CocoaError(.fileWriteNoPermission) }
                try live.write(data, url)
            }, remove: { [unowned self] url in
                if self.failRemovals { throw CocoaError(.fileWriteNoPermission) }
                try live.remove(url)
            })
            return WeshSealedStore(keychain: keychain, fileURL: url, keyName: "record.test",
                                   context: "wesh.record.test", files: files)
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

    @Test func unconfirmedRevocationLeavesTheAllowlistAtOnceAndIsRetriedAfterRelaunch() throws {
        let fixture = Fixture()
        let trust = WeshQRTrust(storage: fixture.store())
        #expect(trust.record(sessionKey: alice, nickname: "Alice"))
        #expect(trust.record(sessionKey: bob, nickname: "Bob"))

        fixture.failWrites = true
        #expect(!trust.remove(sessionKey: alice))
        #expect(!trust.fingerprints.contains(alice.sha256Fingerprint()))
        #expect(!WeshQRTrust.canSend(sessionKey: alice, qrFingerprints: trust.fingerprints, locallyVerified: true))
        #expect(trust.contacts.map(\.nickname) == ["Bob"])

        // Relaunch while the file still lists Alice: the Keychain intent wins.
        fixture.failWrites = false
        let relaunched = WeshQRTrust(storage: fixture.store())
        #expect(relaunched.contacts.map(\.nickname) == ["Bob"])
        #expect(!relaunched.fingerprints.contains(alice.sha256Fingerprint()))
        #expect(WeshQRTrust(storage: fixture.store()).contacts.map(\.nickname) == ["Bob"])
    }

    @Test func failedRevocationCanBeRetriedInProcess() throws {
        let fixture = Fixture()
        let trust = WeshQRTrust(storage: fixture.store())
        #expect(trust.record(sessionKey: alice, nickname: "Alice"))
        fixture.keychain.simulatedReadError = .deviceLocked
        #expect(!trust.remove(sessionKey: alice))
        #expect(trust.fingerprints.isEmpty)
        fixture.keychain.simulatedReadError = nil
        #expect(trust.remove(sessionKey: alice))
        #expect(WeshQRTrust(storage: fixture.store()).contacts.isEmpty)
    }

    @Test func failedWipeIsNeverUndoneByAReloadOrRelaunch() throws {
        let fixture = Fixture()
        let trust = WeshQRTrust(storage: fixture.store())
        #expect(trust.record(sessionKey: alice, nickname: "Alice"))

        fixture.failRemovals = true
        #expect(!trust.clear())
        #expect(trust.contacts.isEmpty && trust.fingerprints.isEmpty)
        #expect(trust.storageState == .unavailable)
        trust.reloadIfNeeded()
        #expect(trust.contacts.isEmpty && trust.storageState == .unavailable)
        #expect(!trust.record(sessionKey: bob, nickname: "Bob"))
        #expect(WeshQRTrust(storage: fixture.store()).contacts.isEmpty)

        fixture.failRemovals = false
        trust.reloadIfNeeded()
        #expect(trust.storageState == .available && trust.contacts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        // The marker is gone: a new enrollment survives the next relaunch.
        #expect(trust.record(sessionKey: bob, nickname: "Bob"))
        #expect(WeshQRTrust(storage: fixture.store()).contacts.map(\.nickname) == ["Bob"])
    }

    @Test func wipeDestroysEvenWhenNoMarkerCanBeWrittenButReportsFailure() throws {
        let fixture = Fixture()
        let trust = WeshQRTrust(storage: fixture.store())
        #expect(trust.record(sessionKey: alice, nickname: "Alice"))
        // Neither the Keychain intent nor the sentinel file can be written.
        fixture.keychain.identitySaveFault = { key, _, _ in key == "record.test.intent" ? .deviceLocked : nil }
        fixture.failWrites = true

        #expect(!trust.clear())
        #expect(trust.contacts.isEmpty && trust.storageState == .unavailable)
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(fixture.keychain.getIdentityKey(forKey: "record.test") == nil)
        #expect(!trust.record(sessionKey: bob, nickname: "Bob"))

        fixture.keychain.identitySaveFault = nil
        fixture.failWrites = false
        trust.reloadIfNeeded()
        #expect(trust.storageState == .available && trust.contacts.isEmpty)
        #expect(trust.record(sessionKey: bob, nickname: "Bob"))
        #expect(WeshQRTrust(storage: fixture.store()).contacts.map(\.nickname) == ["Bob"])
    }

    @Test func failedDestructionKeepsTheSentinelWhenTheKeychainIsUnavailable() throws {
        let fixture = Fixture()
        #expect(WeshQRTrust(storage: fixture.store()).record(sessionKey: alice, nickname: "Alice"))
        let trust = WeshQRTrust(storage: fixture.store())
        fixture.keychain.identitySaveFault = { key, _, _ in key == "record.test.intent" ? .deviceLocked : nil }
        fixture.failRemovals = true

        #expect(!trust.clear())
        #expect(FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(try fixture.store().isWipePending())
        // A relaunch with a readable Keychain still refuses the old list.
        fixture.keychain.identitySaveFault = nil
        let relaunched = WeshQRTrust(storage: fixture.store())
        #expect(relaunched.contacts.isEmpty && relaunched.storageState == .unavailable)

        fixture.failRemovals = false
        relaunched.reloadIfNeeded()
        #expect(relaunched.storageState == .available && relaunched.contacts.isEmpty)
        #expect(!(try fixture.store().isWipePending()))
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
    }

    @Test func unreadableIntentFailsClosedInsteadOfLoadingTheList() throws {
        let fixture = Fixture()
        #expect(WeshQRTrust(storage: fixture.store()).record(sessionKey: alice, nickname: "Alice"))
        fixture.keychain.identityReadFault = { key, _ in key == "record.test.intent" ? .deviceLocked : nil }
        let locked = WeshQRTrust(storage: fixture.store())
        #expect(locked.storageState == .unavailable && locked.contacts.isEmpty && locked.fingerprints.isEmpty)
        fixture.keychain.identityReadFault = nil

        _ = fixture.keychain.saveIdentityKey(Data("not json".utf8), forKey: "record.test.intent")
        let corrupt = WeshQRTrust(storage: fixture.store())
        #expect(corrupt.storageState == .recoveryRequired && corrupt.contacts.isEmpty)
    }

    @Test func revocationRequestedWhileTheListIsUnreadableSurvivesRelaunch() throws {
        let fixture = Fixture()
        let first = WeshQRTrust(storage: fixture.store())
        #expect(first.record(sessionKey: alice, nickname: "Alice"))
        #expect(first.record(sessionKey: bob, nickname: "Bob"))
        // The file key is unreadable, the intent item is not.
        fixture.keychain.identityReadFault = { key, _ in key == "record.test" ? .deviceLocked : nil }
        let locked = WeshQRTrust(storage: fixture.store())
        #expect(locked.storageState == .unavailable)
        #expect(!locked.remove(sessionKey: alice))

        fixture.keychain.identityReadFault = nil
        let relaunched = WeshQRTrust(storage: fixture.store())
        #expect(relaunched.contacts.map(\.nickname) == ["Bob"])
        #expect(!relaunched.fingerprints.contains(alice.sha256Fingerprint()))
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

    @Test func failedNoteEraseIsRetriedInsteadOfRestored() throws {
        let fixture = Fixture()
        let note = WeshMeetingNoteStore(storage: fixture.store())
        #expect(note.edit(\.note, value: "Rendez-vous synthétique", generation: note.generation))

        fixture.failRemovals = true
        #expect(!note.clear(generation: note.generation))
        #expect(note.content.note.isEmpty)
        let relaunchedWhileBlocked = WeshMeetingNoteStore(storage: fixture.store())
        #expect(relaunchedWhileBlocked.content.note.isEmpty)
        #expect(relaunchedWhileBlocked.storageState == .unavailable)

        fixture.failRemovals = false
        relaunchedWhileBlocked.reloadIfNeeded()
        #expect(relaunchedWhileBlocked.storageState == .available)
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(relaunchedWhileBlocked.edit(\.note, value: "Nouvelle", generation: relaunchedWhileBlocked.generation))
        #expect(WeshMeetingNoteStore(storage: fixture.store()).content.note == "Nouvelle")
    }

    @Test func noteEraseDestroysEvenWhenNoMarkerCanBeWrittenButReportsFailure() throws {
        let fixture = Fixture()
        let note = WeshMeetingNoteStore(storage: fixture.store())
        #expect(note.edit(\.note, value: "Rendez-vous", generation: note.generation))
        fixture.keychain.identitySaveFault = { key, _, _ in key == "record.test.intent" ? .deviceLocked : nil }
        fixture.failWrites = true
        #expect(!note.clear(generation: note.generation))
        #expect(note.content.note.isEmpty && note.isSuspended)
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))

        fixture.keychain.identitySaveFault = nil
        fixture.failWrites = false
        note.reloadIfNeeded()
        #expect(!note.isSuspended && note.storageState == .available)
        #expect(note.edit(\.note, value: "Nouvelle", generation: note.generation))
        #expect(WeshMeetingNoteStore(storage: fixture.store()).content.note == "Nouvelle")
    }

    @Test func failedNoteDestructionKeepsTheSentinelAndRefusesTheOldNote() throws {
        let fixture = Fixture()
        let note = WeshMeetingNoteStore(storage: fixture.store())
        #expect(note.edit(\.note, value: "Secret", generation: note.generation))
        fixture.keychain.identitySaveFault = { key, _, _ in key == "record.test.intent" ? .deviceLocked : nil }
        fixture.failRemovals = true
        #expect(!note.clear(generation: note.generation))
        #expect(try fixture.store().isWipePending())
        fixture.keychain.identitySaveFault = nil
        let relaunched = WeshMeetingNoteStore(storage: fixture.store())
        #expect(relaunched.content.note.isEmpty && relaunched.isSuspended)
    }

    @Test func pendingNoteEraseInvalidatesOldEditorsAndResumesOnlyAfterConfirmation() throws {
        let fixture = Fixture()
        let seeded = WeshMeetingNoteStore(storage: fixture.store())
        #expect(seeded.edit(\.note, value: "Ancienne note", generation: seeded.generation))
        #expect(fixture.store().writeIntent(Data("wipe".utf8)))
        fixture.failRemovals = true

        let note = WeshMeetingNoteStore(storage: fixture.store())
        let staleGeneration = note.generation
        #expect(note.isSuspended && note.content.note.isEmpty && note.storageState == .unavailable)
        #expect(!note.edit(\.note, value: "Écriture tardive", generation: staleGeneration))

        fixture.failRemovals = false
        note.reloadIfNeeded()
        #expect(!note.isSuspended && note.storageState == .available)
        #expect(note.generation != staleGeneration)
        #expect(!note.edit(\.note, value: "Écriture tardive", generation: staleGeneration))
        #expect(note.edit(\.note, value: "Nouvelle", generation: note.generation))
        // A later foreground must not erase the new note again.
        note.reloadIfNeeded()
        #expect(WeshMeetingNoteStore(storage: fixture.store()).content.note == "Nouvelle")
    }

    @Test func meetingNoteKeystrokesAreCoalescedIntoOneDelayedOrFlushedWrite() async throws {
        let fixture = Fixture()
        let note = WeshMeetingNoteStore(storage: fixture.store(), saveDelay: 60)
        #expect(note.edit(\.note, value: "R", generation: note.generation))
        #expect(note.edit(\.note, value: "Rendez-vous", generation: note.generation))
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        note.flushPendingSave()
        #expect(note.isSaveConfirmed)
        #expect(WeshMeetingNoteStore(storage: fixture.store()).content.note == "Rendez-vous")

        let delayed = WeshMeetingNoteStore(storage: fixture.store(), saveDelay: 0.05)
        #expect(delayed.edit(\.place, value: "Gare", generation: delayed.generation))
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(WeshMeetingNoteStore(storage: fixture.store()).content.place == "Gare")
    }

    @Test func panicCancelsAPendingNoteWriteSoNothingIsWrittenAfterTheWipe() async throws {
        let fixture = Fixture()
        let note = WeshMeetingNoteStore(storage: fixture.store(), saveDelay: 0.05)
        #expect(note.edit(\.note, value: "Rendez-vous secret", generation: note.generation))
        note.suspendForPanic()
        #expect(note.wipeForPanic())
        note.completePanic()
        try await Task.sleep(nanoseconds: 400_000_000)
        note.flushPendingSave()
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(WeshMeetingNoteStore(storage: fixture.store()).content.note.isEmpty)
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
