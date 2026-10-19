// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
import BitFoundation
import CryptoKit
import Foundation
import Testing
@testable import bitchat

@Suite("Encrypted composer drafts", .serialized)
struct ComposerDraftPersistenceTests {
    private let owner = Data(repeating: 0x11, count: 32)
    private func peer(_ value: UInt8) -> ComposerDraftStore.Key { .privateNoiseKey(Data(repeating: value, count: 32)) }
    private func record(_ key: ComposerDraftStore.Key, _ text: String) -> ComposerDraftRecord {
        ComposerDraftRecord(key: key, text: text, updatedAt: Date(timeIntervalSince1970: 100))
    }
    private func settled(_ repository: ComposerDraftRepository) async {
        await withCheckedContinuation { continuation in
            repository.flush { continuation.resume() }
        }
    }
    private func arrived(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: semaphore.wait(timeout: .now() + TestConstants.settleTimeout) == .success) }
        }
    }
    private func eventually(_ condition: @escaping () -> Bool) async -> Bool {
        await TestHelpers.waitUntil(condition, timeout: TestConstants.settleTimeout)
    }

    @Test func ramOnlyEditsAfterConfirmedPersistentWriteKeepDurableStatus() async throws {
        struct CleanupFailure: Error, CustomStringConvertible {
            let primary: Error
            let cleanup: Error
            var description: String { "primary: \(primary); independent owned cleanup: \(cleanup)" }
        }
        let fixture = try DraftFixture()
        let repository = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
        var primary: Error?
        var observed: (status: ComposerDraftStatus, pending: Int, mesh: String, location: String,
                       fallback: String, writesBefore: Int, writesAfter: Int,
                       ciphertextBefore: Data, ciphertextAfter: Data)?
        do {
            try #require(repository.save("synthetic durable sentinel", for: .mesh))
            await settled(repository)
            try #require(repository.persistenceStatus == .durable)
            try #require(repository.pendingCountForTesting == 0)
            let writes = fixture.control.writeCount
            try #require(writes > 0)
            let ciphertext = try Data(contentsOf: fixture.url)
            try #require(!ciphertext.isEmpty)
            try #require(repository.load(.mesh) == "synthetic durable sentinel")

            let location = ComposerDraftStore.Key.location(geohash: "synthetic-session-only")
            let fallback = ComposerDraftStore.Key.privateChat(stableID: "synthetic-session-only")
            try #require(repository.save("synthetic location RAM", for: location))
            try #require(repository.save("synthetic fallback RAM", for: fallback))
            await settled(repository)
            observed = (repository.persistenceStatus, repository.pendingCountForTesting,
                        repository.load(.mesh), repository.load(location), repository.load(fallback),
                        writes, fixture.control.writeCount, ciphertext, try Data(contentsOf: fixture.url))
        } catch {
            primary = error
        }
        // Reach the existing real generation/IO barrier before removing only this owned directory.
        repository.suspendForPanic()
        var cleanup: Error?
        do {
            try FileManager.default.removeItem(at: fixture.root)
        } catch {
            cleanup = error
        }
        if let primary {
            if let cleanup { throw CleanupFailure(primary: primary, cleanup: cleanup) }
            throw primary
        }
        if let cleanup { throw cleanup }
        let observed = try #require(observed)
        #expect(observed.status == .durable)
        #expect(observed.pending == 0)
        #expect(observed.writesAfter == observed.writesBefore)
        #expect(observed.ciphertextAfter == observed.ciphertextBefore)
        #expect(observed.mesh == "synthetic durable sentinel")
        #expect(observed.location == "synthetic location RAM")
        #expect(observed.fallback == "synthetic fallback RAM")
    }

    @Test func restartRestoresOnlyMeshAndFullNoiseKeysWithoutPlaintext() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        let repository = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
        repository.save("synthetic mesh draft", for: .mesh)
        repository.save("synthetic private draft", for: peer(0x22))
        repository.save("geo stays RAM", for: .location(geohash: "synthetic"))
        repository.save("short stays RAM", for: .privateChat(stableID: "aabbccddeeff0011"))
        await settled(repository)
        #expect(repository.persistenceStatus == .durable)
        let ciphertext = try Data(contentsOf: fixture.url)
        for text in ["synthetic mesh draft", "synthetic private draft", "geo stays RAM", "short stays RAM"] {
            #expect(ciphertext.range(of: Data(text.utf8)) == nil)
        }
        let restarted = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
        await settled(restarted)
        #expect(restarted.load(.mesh) == "synthetic mesh draft")
        #expect(restarted.load(peer(0x22)) == "synthetic private draft")
        #expect(restarted.load(.location(geohash: "synthetic")).isEmpty)
        #expect(restarted.load(.privateChat(stableID: "aabbccddeeff0011")).isEmpty)
        #expect(restarted.load(peer(0x33)).isEmpty)
    }

    @Test func completeNoiseKeyIsExplicitAndFingerprintFallbackRemainsSessionOnly() {
        let full = PeerID(hexData: Data(repeating: 0x22, count: 32))
        #expect(ComposerDraftStore.Key.from(peerID: full, fingerprint: "ignored", channel: .mesh) == peer(0x22))
        let short = PeerID(str: "aabbccddeeff0011")
        let fallback = ComposerDraftStore.Key.from(peerID: short, fingerprint: String(repeating: "aa", count: 32), channel: .mesh)
        #expect(!fallback.isPersistentDestination)
        #expect(!ComposerDraftStore.Key.privateNoiseKey(Data([1])).isPersistentDestination)
        #expect(!ComposerDraftStore.Key.location(geohash: "synthetic").isPersistentDestination)
    }

    @Test func initialLoadMergesTypedShareAndTombstoneWithoutLosingOtherDestination() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        try fixture.seed([record(.mesh, "stored"), record(peer(0x22), "stored A"), record(peer(0x33), "stored B"), record(peer(0x44), "keep other")], owner: owner)
        fixture.control.blockNextRead()
        let repository = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
        #expect(await arrived(fixture.control.entered))
        repository.save("newly typed", for: .mesh)
        repository.save("explicit imported share", for: peer(0x22))
        repository.save("", for: peer(0x33))
        fixture.control.release.signal()
        await settled(repository)
        #expect(repository.load(.mesh) == "newly typed")
        #expect(repository.load(peer(0x22)) == "explicit imported share")
        #expect(repository.load(peer(0x33)).isEmpty)
        #expect(repository.load(peer(0x44)) == "keep other")
        let restarted = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
        await settled(restarted)
        #expect(restarted.load(.mesh) == "newly typed")
        #expect(restarted.load(peer(0x22)) == "explicit imported share")
        #expect(restarted.load(peer(0x33)).isEmpty)
        #expect(restarted.load(peer(0x44)) == "keep other")
    }

    @Test func initialProgrammaticReadDoesNotClearDurableDraft() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        try fixture.seed([record(.mesh, "restored later")], owner: owner)
        fixture.control.blockNextRead()
        let repository = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
        #expect(await arrived(fixture.control.entered))
        #expect(repository.load(.mesh).isEmpty) // UI read only; no save("").
        fixture.control.release.signal()
        await settled(repository)
        #expect(repository.load(.mesh) == "restored later")
    }

    @Test func clearIfUnchangedDoesNotEraseNewerTextOrAnotherDestination() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        let repository = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
        repository.save("sent text", for: .mesh)
        repository.save("other destination", for: peer(0x22))
        let submitted = repository.snapshot(.mesh)
        repository.save("newly typed after submission", for: .mesh)
        #expect(!repository.clearIfUnchanged(submitted))
        #expect(repository.load(.mesh) == "newly typed after submission")
        #expect(repository.load(peer(0x22)) == "other destination")
        #expect(repository.clearIfUnchanged(repository.snapshot(.mesh)))
        await settled(repository)
        let restarted = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
        await settled(restarted)
        #expect(restarted.load(.mesh).isEmpty)
        #expect(restarted.load(peer(0x22)) == "other destination")
    }

    @Test func deniedFileProbeDoesNotCreateEncryptionKeyOrReplaceCache() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        fixture.control.readFails = true
        let repository = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
        repository.save("RAM while unavailable", for: .mesh)
        await settled(repository)
        #expect(repository.persistenceStatus == .unavailable(.storageUnavailable))
        #expect(fixture.keychain.identitySaveCount == 0)
        #expect(fixture.control.writeCount == 0)
        fixture.control.readFails = false
        await settled(repository)
        #expect(repository.load(.mesh) == "RAM while unavailable")
        #expect(repository.persistenceStatus == .durable)
    }

    @Test func missingKeyMalformedKeyAndCorruptCacheArePreserved() async throws {
        for fault in 0..<4 {
            let fixture = try DraftFixture(); defer { fixture.remove() }
            try fixture.seed([record(.mesh, "old durable")], owner: owner)
            switch fault {
            case 0: _ = fixture.keychain.deleteIdentityKey(forKey: ComposerDraftPersistence.keychainKey)
            case 1: _ = fixture.keychain.saveIdentityKey(Data([1]), forKey: ComposerDraftPersistence.keychainKey)
            case 2: try Data([1, 2, 3]).write(to: fixture.url)
            default: try Data(repeating: 0xFF, count: ComposerDraftPersistence.maxFileBytes + 1).write(to: fixture.url)
            }
            let before = try Data(contentsOf: fixture.url)
            let saves = fixture.keychain.identitySaveCount
            let repository = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
            repository.save("new RAM", for: .mesh)
            await settled(repository)
            #expect(repository.persistenceStatus == .unavailable(fault == 3 ? .tooLarge : .recoveryRequired))
            #expect(try Data(contentsOf: fixture.url) == before)
            #expect(fixture.keychain.identitySaveCount == saves)
            #expect(repository.load(.mesh) == "new RAM")
        }
    }

    @Test func keyReadFailuresNeverReplaceStoredDataAndRetryKeepsPendingEdits() async throws {
        for failure: KeychainReadResult in [.deviceLocked, .authenticationFailed, .accessDenied, .otherError(-50)] {
            let fixture = try DraftFixture(); defer { fixture.remove() }
            try fixture.seed([record(peer(0x22), "other durable")], owner: owner)
            let original = try Data(contentsOf: fixture.url)
            let saves = fixture.keychain.identitySaveCount
            fixture.keychain.identityReadFault = { key, _ in key == ComposerDraftPersistence.keychainKey ? failure : nil }
            let repository = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
            repository.save("pending", for: .mesh)
            await settled(repository)
            #expect(repository.persistenceStatus == .unavailable(.storageUnavailable))
            #expect(fixture.keychain.identitySaveCount == saves)
            #expect(try Data(contentsOf: fixture.url) == original)
            fixture.keychain.identityReadFault = nil
            await settled(repository)
            #expect(repository.persistenceStatus == .durable)
            #expect(repository.load(.mesh) == "pending")
            #expect(repository.load(peer(0x22)) == "other durable")
        }
    }

    @Test func failedKeySaveOrReadbackCannotClaimDurability() async throws {
        for fakeSuccess in [false, true] {
            let fixture = try DraftFixture(); defer { fixture.remove() }
            fixture.keychain.identitySaveFault = { _, _, _ in fakeSuccess ? .success : .accessDenied }
            let repository = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
            repository.save("pending", for: .mesh)
            await settled(repository)
            #expect(repository.persistenceStatus == .unavailable(.writeUnconfirmed))
            #expect(fixture.control.writeCount == 0)
            fixture.keychain.identitySaveFault = nil
            await settled(repository)
            #expect(repository.persistenceStatus == .durable)
            #expect(repository.load(.mesh) == "pending")
        }
    }

    @Test func failedAtomicWriteAndUnavailableReadbackRemainDirtyUntilRetry() async throws {
        for unavailableReadback in [false, true] {
            let fixture = try DraftFixture(); defer { fixture.remove() }
            try fixture.seed([record(.mesh, "old")], owner: owner)
            let repository = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
            await settled(repository)
            fixture.control.writeFails = !unavailableReadback
            fixture.control.failReadAfterWrite = unavailableReadback
            repository.save("new pending", for: .mesh)
            await settled(repository)
            #expect(repository.persistenceStatus == .unavailable(.writeUnconfirmed))
            #expect(repository.load(.mesh) == "new pending")
            fixture.control.writeFails = false
            fixture.control.failReadAfterWrite = false
            fixture.control.readFails = false
            await settled(repository)
            #expect(repository.persistenceStatus == .durable)
            let restarted = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
            await settled(restarted)
            #expect(restarted.load(.mesh) == "new pending")
        }
    }

    @Test func ownerChangeNeverRestoresOldIdentityDraftsOrOverwritesTheirFile() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        try fixture.seed([record(.mesh, "old identity text")], owner: owner)
        let original = try Data(contentsOf: fixture.url)
        let repository = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
        await settled(repository)
        repository.setOwner(Data(repeating: 0x99, count: 32))
        #expect(repository.load(.mesh).isEmpty)
        repository.save("new identity RAM", for: .mesh)
        await settled(repository)
        #expect(repository.persistenceStatus == .unavailable(.ownerMismatch))
        #expect(repository.load(.mesh) == "new identity RAM")
        #expect(try Data(contentsOf: fixture.url) == original)
    }

    @Test func unknownOwnerKeepsRAMWithoutAnyFileOrKeyRead() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        let repository = ComposerDraftRepository(persistence: fixture.backend(), owner: nil)
        repository.save("typed before identity recovery", for: .mesh)
        #expect(repository.persistenceStatus == .waitingForIdentity)
        #expect(fixture.control.readCount == 0)
        #expect(fixture.keychain.identityReadCount == 0)
        repository.setOwner(owner)
        await settled(repository)
        #expect(repository.persistenceStatus == .durable)
        #expect(repository.load(.mesh) == "typed before identity recovery")
    }

    @Test func pendingTombstonesAreBoundedAndNeverEvictedToMakeRoom() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        let keys = (0..<64).map { value -> ComposerDraftStore.Key in
            var key = Data(repeating: 0, count: 32); key[31] = UInt8(value); return .privateNoiseKey(key)
        }
        try fixture.seed(keys.map { record($0, "old") }, owner: owner)
        fixture.control.readFails = true
        let repository = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
        await settled(repository)
        for key in keys { #expect(repository.save("", for: key)) }
        for _ in 0..<100 { #expect(!repository.save("", for: .mesh)) }
        #expect(repository.pendingCountForTesting == 64)
        #expect(repository.persistenceStatus == .unavailable(.capacityReached))
        fixture.control.readFails = false
        await settled(repository)
        #expect(repository.pendingCountForTesting == 0)
        let restarted = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
        await settled(restarted)
        for key in keys { #expect(restarted.load(key).isEmpty) }
    }

    @Test func oversizedCombiningGraphemeIsRefusedBeforeRAMCopyOrDiskWrite() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        let repository = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
        repository.save("keep", for: .mesh); await settled(repository)
        let writes = fixture.control.writeCount
        let huge = "a" + String(repeating: "\u{0301}", count: 40_000)
        #expect(huge.count == 1)
        #expect(!repository.save(huge, for: .mesh))
        #expect(repository.load(.mesh) == "keep")
        #expect(repository.status(for: .mesh, displayedText: huge) == .unavailable(.tooLarge))
        #expect(fixture.control.writeCount == writes)
    }

    @Test func strictBinarySchemaRejectsTrailingUnknownVersionDuplicateAndForeignOwner() throws {
        let valid = try ComposerDraftPersistence.encode([record(.mesh, "hello")], owner: owner)
        var version = valid; version[8] = 2
        for malformed in [Data(valid.dropLast()), valid + Data([0]), version] {
            #expect(throws: ComposerDraftFailure.recoveryRequired) { try ComposerDraftPersistence.decode(malformed, owner: owner) }
        }
        #expect(throws: ComposerDraftFailure.ownerMismatch) {
            try ComposerDraftPersistence.decode(valid, owner: Data(repeating: 0x99, count: 32))
        }
        #expect(throws: ComposerDraftFailure.tooLarge) {
            try ComposerDraftPersistence.encode([record(.mesh, "one"), record(.mesh, "two")], owner: owner)
        }
        let slice = (Data([0]) + valid).dropFirst()
        #expect(try ComposerDraftPersistence.decode(slice, owner: owner).first?.text == "hello")
    }

    @Test func panicDrainsOldWriteDeletesItAndRejectsStaleCallbacksAfterResume() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        let repository = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
        repository.save("old", for: .mesh); await settled(repository)
        let oldGeneration = repository.currentGeneration
        let oldSnapshot = repository.snapshot(.mesh)
        fixture.control.blockNextWrite()
        repository.save("in-flight old write", for: .mesh)
        repository.flush()
        #expect(await arrived(fixture.control.entered))
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            repository.suspendForPanic()
            try? repository.wipeForPanic()
            finished.signal()
        }
        #expect(await eventually { repository.persistenceStatus == .suspended })
        #expect(!repository.save("old callback during panic", for: .mesh))
        fixture.control.release.signal()
        #expect(await arrived(finished))
        _ = fixture.keychain.deleteAllKeychainData()
        repository.completePanic(success: true, owner: Data(repeating: 0x99, count: 32))
        #expect(!repository.save("old callback after panic", for: .mesh, generation: oldGeneration))
        #expect(!repository.clearIfUnchanged(oldSnapshot))
        await settled(repository)
        #expect(repository.load(.mesh).isEmpty)
        #expect(fixture.control.allIOOffMain)
        let restarted = ComposerDraftRepository(persistence: fixture.backend(), owner: Data(repeating: 0x99, count: 32))
        await settled(restarted)
        #expect(restarted.load(.mesh).isEmpty)
    }

    @Test func globalPanicRetainsMarkersWhenDraftWipeFailsAndAttemptsDraftsAfterMediaError() throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        let suite = "wesh.drafts.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var draftAttempts = 0
        let mediaRoot = fixture.root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        let operations = PanicRecoveryOperations.live(fileStore: PanicRecoveryFileStore(baseDirectory: mediaRoot), defaults: defaults,
            wipeDrafts: { draftAttempts += 1; throw ComposerDraftFailure.storageUnavailable })
        let intent = operations.begin()
        #expect(throws: (any Error).self) { try operations.wipeMedia(intent) }
        #expect(draftAttempts == 1)
        #expect(try operations.isPending())
        final class RefusingFileManager: FileManager {
            override func removeItem(at URL: URL) throws { throw CocoaError(.fileWriteNoPermission) }
        }
        let legacyMedia = mediaRoot.appendingPathComponent("files/images/incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyMedia, withIntermediateDirectories: true)
        let bothFail = PanicRecoveryOperations.live(
            fileStore: PanicRecoveryFileStore(fileManager: RefusingFileManager(), baseDirectory: mediaRoot),
            defaults: defaults,
            wipeDrafts: { draftAttempts += 1 })
        #expect(throws: (any Error).self) { try bothFail.wipeMedia(bothFail.begin()) }
        #expect(draftAttempts == 2)
    }

    @Test func refusedDisplayedEditsCannotBecomeDurableOrClearAnotherText() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        fixture.control.blockNextRead()
        let repository = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
        #expect(await arrived(fixture.control.entered))
        let generation = repository.currentGeneration
        #expect(repository.admitDisplayedText("previous", for: .mesh, generation: generation))
        for value in 1..<64 { #expect(repository.save("pending", for: peer(UInt8(value)))) }
        let refused = peer(200)
        #expect(!repository.admitDisplayedText("not admitted", for: refused, generation: generation))
        #expect(repository.submission(for: refused, displayedText: "not admitted", generation: generation) == nil)
        let huge = "a" + String(repeating: "\u{301}", count: 20_000)
        #expect(!repository.admitDisplayedText(huge, for: .mesh, generation: generation))
        #expect(repository.load(.mesh) == "previous")
        #expect(repository.submission(for: .mesh, displayedText: huge, generation: generation) == nil)
        fixture.control.release.signal()
        await settled(repository)
        #expect(repository.persistenceStatus == .durable)
        #expect(repository.status(for: refused, displayedText: "not admitted") == .unavailable(.capacityReached))
        #expect(repository.submission(for: .mesh, displayedText: "previous", generation: generation)?.text == "previous")
        repository.suspendForPanic()
        repository.completePanic(success: true, owner: owner)
        #expect(!repository.admitDisplayedText("stale", for: .mesh, generation: generation))
    }

    @Test func panicFencesBlockedLoaderAndFailedWipeKeepsSuspended() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        try fixture.seed([record(.mesh, "old identity draft")], owner: owner)
        fixture.control.blockNextRead()
        let repository = ComposerDraftRepository(persistence: fixture.backend(), owner: owner)
        #expect(await arrived(fixture.control.entered))
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { repository.suspendForPanic(); finished.signal() }
        #expect(await eventually { repository.persistenceStatus == .suspended })
        fixture.control.release.signal()
        #expect(await arrived(finished))
        repository.completePanic(success: false, owner: owner)
        #expect(repository.load(.mesh).isEmpty)
        #expect(!repository.save("stale", for: .mesh))
        #expect(repository.persistenceStatus == .suspended)
        #expect(try fixture.backend().load(owner: owner).first?.text == "old identity draft")
    }

    @Test @MainActor func defaultTestSingletonNeverConfiguresLiveStorage() {
        #expect(TestEnvironment.isRunningTests)
        let keychain = MockKeychain()
        ComposerDraftStore.configurePersistence(keychain: keychain, noiseKey: Data(repeating: 0x11, count: 32))
        #expect(keychain.identityReadCount == 0)
        #expect(keychain.identitySaveCount == 0)
    }
}

private final class DraftFixture {
    let root: URL
    let url: URL
    let keychain = MockKeychain()
    let control = DraftIOControl()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wesh-drafts-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("drafts/state.enc")
    }
    func backend() -> ComposerDraftPersistence {
        ComposerDraftPersistence(keychain: keychain, fileURL: url, files: control.files)
    }
    func seed(_ records: [ComposerDraftRecord], owner: Data) throws {
        let backend = backend()
        _ = try backend.load(owner: owner)
        try backend.persist(records, owner: owner)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class DraftIOControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _readFails = false
    private var _writeFails = false
    private var _failReadAfterWrite = false
    private var blockRead = false
    private var blockWrite = false
    private var _readCount = 0
    private var _writeCount = 0
    private var offMain = true
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var readFails: Bool { get { locked { _readFails } } set { locked { _readFails = newValue } } }
    var writeFails: Bool { get { locked { _writeFails } } set { locked { _writeFails = newValue } } }
    var failReadAfterWrite: Bool { get { locked { _failReadAfterWrite } } set { locked { _failReadAfterWrite = newValue } } }
    var readCount: Int { locked { _readCount } }
    var writeCount: Int { locked { _writeCount } }
    var allIOOffMain: Bool { locked { offMain } }
    func blockNextRead() { locked { blockRead = true } }
    func blockNextWrite() { locked { blockWrite = true } }
    var files: ComposerDraftPersistence.FileAccess {
        let live = ComposerDraftPersistence.FileAccess.live
        return .init(read: { [self] url in
            let mode = locked { () -> (Bool, Bool) in
                _readCount += 1; offMain = offMain && !Thread.isMainThread
                let block = blockRead; blockRead = false; return (_readFails, block)
            }
            if mode.1 { entered.signal(); _ = release.wait(timeout: .now() + TestConstants.settleTimeout) }
            if mode.0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
            return try live.read(url)
        }, write: { [self] data, url in
            let mode = locked { () -> (Bool, Bool, Bool) in
                _writeCount += 1; offMain = offMain && !Thread.isMainThread
                let block = blockWrite; blockWrite = false; return (_writeFails, block, _failReadAfterWrite)
            }
            if mode.1 { entered.signal(); _ = release.wait(timeout: .now() + TestConstants.settleTimeout) }
            if mode.0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
            try live.write(data, url)
            if mode.2 { readFails = true }
        }, remove: { url in try live.remove(url) })
    }
}
