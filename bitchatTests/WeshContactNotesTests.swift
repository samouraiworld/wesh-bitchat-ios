import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("Wesh local contact notes", .serialized)
@MainActor
struct WeshContactNotesTests {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wesh-contact-notes-\(UUID().uuidString)", isDirectory: true)
        let keychain = MockKeychain()
        let suite = "wesh-contact-notes-\(UUID().uuidString)"
        lazy var defaults = UserDefaults(suiteName: suite)!
        var url: URL { root.appendingPathComponent("contacts.enc") }
        var failWrites = false
        var failRemovals = false

        func storage() -> WeshSealedStore {
            let live = ComposerDraftPersistence.FileAccess.live
            let files = ComposerDraftPersistence.FileAccess(read: live.read, write: { [unowned self] data, url in
                if self.failWrites { throw CocoaError(.fileWriteNoPermission) }
                try live.write(data, url)
            }, remove: { [unowned self] url in
                if self.failRemovals { throw CocoaError(.fileWriteNoPermission) }
                try live.remove(url)
            })
            return WeshSealedStore(keychain: keychain, fileURL: url, keyName: "contacts.test",
                                   context: "wesh.contact-notes.test", files: files)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    private let first = Data(repeating: 71, count: 32)
    private let second = Data(repeating: 72, count: 32)

    @Test func aMissingRequiredBackendCannotPretendToSaveNotesInMemory() {
        let trust = WeshQRTrust(requirePersistence: true)
        #expect(trust.storageState == .unavailable)
        #expect(!trust.record(sessionKey: first, nickname: "QR name"))
        #expect(!trust.setNote(sessionKey: first, alias: "Original", memo: "Memo", generation: trust.noteGeneration))
        #expect(!trust.clear())
        #expect(trust.storageState == .unavailable)
        #expect(trust.contacts.isEmpty && trust.fingerprints.isEmpty)
    }

    @Test func notesRoundTripSealedAndStayOutOfBackups() throws {
        let fixture = Fixture()
        let trust = WeshQRTrust(storage: fixture.storage())
        #expect(trust.record(sessionKey: first, nickname: "QR name"))
        #expect(trust.setNote(sessionKey: first, alias: "Original", memo: "Synthetic memo, line one\nline two",
                              generation: trust.noteGeneration))
        let raw = try Data(contentsOf: fixture.url)
        #expect(raw.range(of: Data("Original".utf8)) == nil)
        #expect(raw.range(of: Data("Synthetic memo".utf8)) == nil)
        #expect(LocalFileProtection.isExcludedFromBackup(fixture.url))
        let reloaded = WeshQRTrust(storage: fixture.storage())
        let contact = try #require(reloaded.contacts.first)
        #expect(contact.nickname == "QR name")
        #expect(contact.alias == "Original")
        #expect(contact.memo == "Synthetic memo, line one\nline two")
        #expect(contact.displayName == "Original")
        #expect(reloaded.fingerprints == [first.sha256Fingerprint()])
        #expect(!WeshQRTrust.canSend(sessionKey: first, qrFingerprints: reloaded.fingerprints, locallyVerified: false))
    }

    @Test func anOlderSnapshotWithoutNotesLoadsAndCanBeEdited() throws {
        let fixture = Fixture()
        let snapshot: [String: Any] = [
            "contacts": [["noiseKeyHex": first.hexEncodedString(), "nickname": "Old contact"]],
            "fingerprints": [first.sha256Fingerprint()],
        ]
        try fixture.storage().save(JSONSerialization.data(withJSONObject: snapshot))
        let trust = WeshQRTrust(storage: fixture.storage())
        #expect(trust.storageState == .available)
        #expect(trust.contacts.first?.alias == nil && trust.contacts.first?.memo == nil)
        #expect(trust.contacts.first?.displayName == "Old contact")
        #expect(trust.setNote(sessionKey: first, alias: "Original", memo: "Memo", generation: trust.noteGeneration))
        #expect(WeshQRTrust(storage: fixture.storage()).contacts.first?.alias == "Original")
    }

    @Test func legacyDefaultsMigrateWithoutCreatingAPlaintextNoteCopy() throws {
        let fixture = Fixture()
        let legacy: [[String: String]] = [["noiseKeyHex": first.hexEncodedString().uppercased(), "nickname": "Legacy QR"]]
        fixture.defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: WeshQRTrust.legacyContactsKey)
        fixture.defaults.set([first.sha256Fingerprint()], forKey: WeshQRTrust.legacyFingerprintsKey)
        let trust = WeshQRTrust(storage: fixture.storage(), legacyDefaults: fixture.defaults)
        #expect(trust.storageState == .available)
        #expect(trust.setNote(sessionKey: first, alias: "Original", memo: "Memo", generation: trust.noteGeneration))
        #expect(fixture.defaults.object(forKey: WeshQRTrust.legacyContactsKey) == nil)
        #expect(fixture.defaults.object(forKey: WeshQRTrust.legacyFingerprintsKey) == nil)
        #expect(fixture.defaults.dictionaryRepresentation().values.allSatisfy { !String(describing: $0).contains("Original") })
        #expect(trust.record(sessionKey: first, nickname: "New QR name"))
        #expect(trust.contacts.count == 1 && trust.contacts.first?.alias == "Original")
    }

    @Test func failedWritePublishesNoNewNotesAndKeepsThePreviousRecord() throws {
        let fixture = Fixture()
        let trust = WeshQRTrust(storage: fixture.storage())
        #expect(trust.record(sessionKey: first, nickname: "QR name"))
        #expect(trust.setNote(sessionKey: first, alias: "Original", memo: "Original memo", generation: trust.noteGeneration))
        let original = try Data(contentsOf: fixture.url)
        fixture.failWrites = true
        #expect(!trust.setNote(sessionKey: first, alias: "Replacement", memo: "Replacement memo", generation: trust.noteGeneration))
        #expect(trust.contacts.first?.alias == "Original" && trust.contacts.first?.memo == "Original memo")
        #expect(try Data(contentsOf: fixture.url) == original)
        fixture.failWrites = false
        #expect(WeshQRTrust(storage: fixture.storage()).contacts.first?.alias == "Original")
    }

    @Test func lockedOrCorruptReadsNeverOverwriteContactNotes() throws {
        let fixture = Fixture()
        let original = WeshQRTrust(storage: fixture.storage())
        #expect(original.record(sessionKey: first, nickname: "QR name"))
        #expect(original.setNote(sessionKey: first, alias: "Original", memo: "Memo", generation: original.noteGeneration))
        let saved = try Data(contentsOf: fixture.url)
        fixture.keychain.simulatedReadError = .deviceLocked
        let locked = WeshQRTrust(storage: fixture.storage())
        #expect(locked.storageState == .unavailable)
        #expect(!locked.setNote(sessionKey: first, alias: "Other", memo: "Other", generation: locked.noteGeneration))
        #expect(try Data(contentsOf: fixture.url) == saved)
        fixture.keychain.simulatedReadError = nil
        locked.reloadIfNeeded()
        #expect(locked.contacts.first?.alias == "Original")
        _ = fixture.keychain.saveIdentityKey(Data(repeating: 4, count: 32), forKey: "contacts.test")
        let corrupt = WeshQRTrust(storage: fixture.storage())
        #expect(corrupt.storageState == .recoveryRequired)
        #expect(!corrupt.setNote(sessionKey: first, alias: "Other", memo: "Other", generation: corrupt.noteGeneration))
        #expect(try Data(contentsOf: fixture.url) == saved)
    }

    @Test func aNoteCanOnlyUpdateTheCompleteEnrolledIdentity() throws {
        let trust = WeshQRTrust()
        var similar = first
        similar[31] = 99
        #expect(trust.record(sessionKey: first, nickname: "Same name"))
        #expect(trust.record(sessionKey: similar, nickname: "Same name"))
        let prints = trust.fingerprints
        #expect(!trust.setNote(sessionKey: Data(first.prefix(31)), alias: "Wrong", memo: "Wrong", generation: trust.noteGeneration))
        #expect(!trust.setNote(sessionKey: second, alias: "Unknown", memo: "Unknown", generation: trust.noteGeneration))
        #expect(trust.setNote(sessionKey: first, alias: "First", memo: "First memo", generation: trust.noteGeneration))
        #expect(trust.contacts.first(where: { $0.peerID.noiseKey == first })?.alias == "First")
        #expect(trust.contacts.first(where: { $0.peerID.noiseKey == similar })?.alias == nil)
        #expect(trust.fingerprints == prints)
    }

    @Test func reenrollmentAndNpubReviewKeepLocalNotesButDoNotRenameTheQR() throws {
        let fixture = Fixture()
        let trust = WeshQRTrust(storage: fixture.storage())
        #expect(trust.record(sessionKey: first, nickname: "Old QR", npub: "synthetic-npub", npubProven: true))
        #expect(trust.setNote(sessionKey: first, alias: "Original", memo: "Memo", generation: trust.noteGeneration))
        #expect(trust.record(sessionKey: first, nickname: "New QR", npub: "synthetic-npub", npubProven: true))
        #expect(trust.contacts.first?.nickname == "New QR")
        #expect(trust.contacts.first?.alias == "Original" && trust.contacts.first?.memo == "Memo")
        #expect(trust.flagNpubConflict(noiseKeysHex: [first.hexEncodedString()]))
        let reloaded = try #require(WeshQRTrust(storage: fixture.storage()).contacts.first)
        #expect(reloaded.alias == "Original" && reloaded.memo == "Memo")
        #expect(reloaded.npub == nil && reloaded.hasNpubConflict)
    }

    @Test func aliasesAndMemosHaveUnicodeScalarBoundsWithoutSplittingEmoji() throws {
        #expect(WeshContactNotes.maximumAliasScalars == 15)
        #expect(WeshContactNotes.maximumMemoScalars == 500)
        let alias = try #require(WeshContactNotes.cleanAlias(String(repeating: "😀", count: 20)))
        let memo = try #require(WeshContactNotes.cleanMemo(String(repeating: "😀", count: 600)))
        #expect(alias.unicodeScalars.count == 15 && alias.utf16.count == 30)
        #expect(memo.unicodeScalars.count == 500 && memo.utf16.count == 1000)
        #expect(WeshContactNotes.cleanAlias("  Lo\u{202E}cal\u{0000}  ") == "Local")
        #expect(WeshContactNotes.cleanMemo("a\r\nb\t\u{0000}\u{202E}c") == "a\nbc")
        #expect(WeshContactNotes.cleanAlias("e\u{0301}") == "é")
        #expect(WeshContactNotes.cleanMemo("e\u{0301}") == "é")
    }

    @Test func localNotesDoNotChangeInternetRoutingOrInboundIdentityResolution() throws {
        // Shared synthetic public-key fixture, not an account from a device.
        let npub = "npub1r799vmpq2ceaq2gfgara9cv0gns9ny7a57jl3r6fvpuzqhm9devsg53zcr"
        let trust = WeshQRTrust()
        #expect(trust.record(sessionKey: first, nickname: "QR name", npub: npub, npubProven: true))
        let before = WeshInternetRoute.recipients(contacts: trust.contacts, blockedFingerprints: [])
        #expect(before == [PeerID(hexData: first): npub])
        #expect(trust.setNote(sessionKey: first, alias: "Original", memo: "Synthetic private memo", generation: trust.noteGeneration))
        #expect(WeshInternetRoute.recipients(contacts: trust.contacts, blockedFingerprints: []) == before)
        #expect(WeshInternetRoute.senderNoiseKey(forNostrPubkey: npub, contacts: trust.contacts, blockedFingerprints: []) == first)
        #expect(trust.contacts.first?.nickname == "QR name")
    }

    @Test func removedControlsAndLeadingPaddingDoNotConsumeTheUsefulTextBudget() throws {
        let alias = String(repeating: "\u{202E}", count: 30) + "   Original"
        let memo = String(repeating: "\t", count: 600) + "\nOriginal memo"
        #expect(WeshContactNotes.cleanAlias(alias) == "Original")
        #expect(WeshContactNotes.cleanMemo(memo) == "Original memo")
        #expect(WeshContactNotes.editingText(alias + " ", limit: 15, multiline: false) == "Original ")
        #expect(WeshContactNotes.editingText(memo + "\n", limit: 500, multiline: true) == "Original memo\n")
        #expect(WeshContactNotes.cleanAlias(String(repeating: "e\u{0301}", count: 20)) == String(repeating: "é", count: 15))
        let trust = WeshQRTrust()
        #expect(trust.record(sessionKey: first, nickname: "QR name"))
        #expect(trust.setNote(sessionKey: first, alias: alias, memo: memo, generation: trust.noteGeneration))
        #expect(trust.contacts.first?.alias == "Original" && trust.contacts.first?.memo == "Original memo")
    }

    @Test func blankFieldsClearNotesAndReservedNamesAreNotSaved() throws {
        let trust = WeshQRTrust()
        #expect(trust.record(sessionKey: first, nickname: "QR name"))
        #expect(trust.setNote(sessionKey: first, alias: "Original", memo: "Memo", generation: trust.noteGeneration))
        #expect(!trust.setNote(sessionKey: first, alias: PaveCopy.text("pave.bubble.you"), memo: "Replacement", generation: trust.noteGeneration))
        #expect(trust.contacts.first?.memo == "Memo")
        #expect(trust.setNote(sessionKey: first, alias: " \n ", memo: " \n ", generation: trust.noteGeneration))
        #expect(trust.contacts.first?.alias == nil && trust.contacts.first?.memo == nil)
        #expect(trust.contacts.first?.displayName == "QR name")
    }

    @Test func removingAContactDeletesItsNotesAndFencesOldEditorsAfterReenrollment() throws {
        let fixture = Fixture()
        let trust = WeshQRTrust(storage: fixture.storage())
        #expect(trust.record(sessionKey: first, nickname: "QR name"))
        let oldGeneration = trust.noteGeneration
        #expect(trust.setNote(sessionKey: first, alias: "Original", memo: "Memo", generation: oldGeneration))
        #expect(trust.remove(sessionKey: first))
        #expect(WeshQRTrust(storage: fixture.storage()).contacts.isEmpty)
        #expect(trust.record(sessionKey: first, nickname: "New QR"))
        #expect(!trust.setNote(sessionKey: first, alias: "Stale alias", memo: "Stale memo", generation: oldGeneration))
        #expect(trust.contacts.first?.alias == nil && trust.contacts.first?.memo == nil)
    }

    @Test func panicWipeRemovesNotesTheirSealedFileAndTheirKeyAndFencesOldEditors() throws {
        let fixture = Fixture()
        let trust = WeshQRTrust(storage: fixture.storage())
        #expect(trust.record(sessionKey: first, nickname: "QR name"))
        let oldGeneration = trust.noteGeneration
        #expect(trust.setNote(sessionKey: first, alias: "Original", memo: "Memo", generation: oldGeneration))
        #expect(trust.clear())
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(fixture.keychain.getIdentityKey(forKey: "contacts.test") == nil)
        #expect(trust.record(sessionKey: first, nickname: "New QR"))
        #expect(!trust.setNote(sessionKey: first, alias: "Stale alias", memo: "Stale memo", generation: oldGeneration))
        #expect(WeshQRTrust(storage: fixture.storage()).contacts.first?.memo == nil)
    }

    @Test func anUnconfirmedWipeCannotBeCancelledByANoteSave() throws {
        let fixture = Fixture()
        let trust = WeshQRTrust(storage: fixture.storage())
        #expect(trust.record(sessionKey: first, nickname: "QR name"))
        let oldGeneration = trust.noteGeneration
        #expect(trust.setNote(sessionKey: first, alias: "Original", memo: "Memo", generation: oldGeneration))
        fixture.failRemovals = true
        #expect(!trust.clear())
        #expect(trust.contacts.isEmpty)
        #expect(!trust.setNote(sessionKey: first, alias: "Stale alias", memo: "Stale memo", generation: oldGeneration))
        #expect(!trust.setNote(sessionKey: first, alias: "New alias", memo: "New memo", generation: trust.noteGeneration))
        fixture.failRemovals = false
        trust.reloadIfNeeded()
        #expect(trust.storageState == .available)
        #expect(WeshQRTrust(storage: fixture.storage()).contacts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
    }
}
