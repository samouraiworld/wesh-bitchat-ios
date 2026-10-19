import BitFoundation
import Foundation
import Darwin
import Testing
@testable import bitchat

private final class ControlledSynchronizeDefaults: UserDefaults, @unchecked Sendable {
    var synchronizeResults: [Bool] = []
    var refuseEnvelopeRemoval = false
    var beforeRemoval: ((String) -> Void)?
    var beforeSynchronize: (() -> Void)?
    override func removeObject(forKey defaultName: String) {
        beforeRemoval?(defaultName)
        if refuseEnvelopeRemoval && defaultName == SharedContentStore.storageKey { return }
        super.removeObject(forKey: defaultName)
    }
    override func synchronize() -> Bool {
        beforeSynchronize?()
        if !synchronizeResults.isEmpty, !synchronizeResults.removeFirst() { return false }
        return super.synchronize()
    }
}

@Suite("Legacy shared-content erasure", .serialized)
struct SharedContentHandoffTests {
    private static let keys = ["sharedContentEnvelopeV1", "sharedContent", "sharedContentType", "sharedContentDate"]

    private func fixture() throws -> (suite: String, defaults: ControlledSynchronizeDefaults, root: URL, lock: URL) {
        let suite = "SharedContentHandoffTests.\(UUID().uuidString)"
        let defaults = try #require(ControlledSynchronizeDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (suite, defaults, root, root.appendingPathComponent("handoff.lock"))
    }

    private func seed(_ defaults: UserDefaults) -> Data {
        // Erasure must handle arbitrary old bytes without parsing or importing them.
        let bytes = Data("synthetic legacy payload".utf8)
        for key in Self.keys { defaults.set(bytes, forKey: key) }
        return bytes
    }

    private func cleanup(_ context: (suite: String, defaults: ControlledSynchronizeDefaults, root: URL, lock: URL)) {
        context.defaults.beforeRemoval = nil
        context.defaults.beforeSynchronize = nil
        context.defaults.removePersistentDomain(forName: context.suite)
        try? FileManager.default.removeItem(at: context.root)
    }

    @Test("Panic discard requires absence after the locked flush and allows a checked retry")
    func panicDiscardRejectsRetainedEnvelopeAndClearsAllKeysOnRetry() throws {
        let context = try fixture()
        defer { cleanup(context) }
        let bytes = seed(context.defaults)
        let store = SharedContentStore(defaults: context.defaults, lockURL: context.lock)
        context.defaults.refuseEnvelopeRemoval = true
        #expect(!store.discardAll())
        for key in Self.keys { #expect(context.defaults.data(forKey: key) == bytes) }
        context.defaults.refuseEnvelopeRemoval = false
        #expect(store.discardAll())
        #expect(store.discardAll(), "An already absent legacy mailbox is a successful erase")
        for key in Self.keys { #expect(context.defaults.object(forKey: key) == nil) }
    }

    @Test("Unavailable shared locking fails closed without deleting legacy payloads")
    func unavailableLockPreservesEveryLegacyKey() throws {
        let context = try fixture()
        defer { cleanup(context) }
        let bytes = seed(context.defaults)
        let missing = context.root.appendingPathComponent("missing/lock")
        let store = SharedContentStore(defaults: context.defaults, lockURL: missing)
        #expect(!store.discardAll())
        for key in Self.keys { #expect(context.defaults.data(forKey: key) == bytes) }
    }

    @Test("A failed locked preference flush restores every key for checked erasure retry")
    func failedFlushRestoresEveryLegacyKey() throws {
        let context = try fixture()
        defer { cleanup(context) }
        let bytes = seed(context.defaults)
        let store = SharedContentStore(defaults: context.defaults, lockURL: context.lock)
        context.defaults.synchronizeResults = [true, false, true]
        #expect(!store.discardAll())
        for key in Self.keys { #expect(context.defaults.data(forKey: key) == bytes) }
        #expect(store.discardAll())
        for key in Self.keys { #expect(context.defaults.object(forKey: key) == nil) }
    }

    @Test("A suspended legacy writer cannot make erasure wait without a bound")
    func contendedLockTimesOutWithoutDeletingLegacyData() throws {
        let context = try fixture()
        defer { cleanup(context) }
        let bytes = seed(context.defaults)
        let descriptor = Darwin.open(context.lock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        try #require(descriptor >= 0)
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        var ticks = 0
        let store = SharedContentStore(defaults: context.defaults, lockURL: context.lock,
            lockTimeout: 0.05, monotonicNow: { Double(ticks) / 1000 },
            pauseBeforeLockRetry: { ticks += 10 })
        #expect(!store.discardAll())
        #expect(ticks >= 50 && ticks < 100)
        for key in Self.keys { #expect(context.defaults.data(forKey: key) == bytes) }
        try #require(flock(descriptor, LOCK_UN) == 0)
        #expect(store.discardAll())
        for key in Self.keys { #expect(context.defaults.object(forKey: key) == nil) }
    }

    @Test("Deletion and both preference flushes remain inside the legacy writer lock")
    func erasureHoldsTheWriterLockThroughVerifiedFlush() throws {
        let context = try fixture()
        defer { cleanup(context) }
        _ = seed(context.defaults)
        let contender = Darwin.open(context.lock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        try #require(contender >= 0)
        defer { flock(contender, LOCK_UN); Darwin.close(contender) }
        var removals = Set<String>()
        var synchronizations = 0
        func verifyLocked() {
            let result = flock(contender, LOCK_EX | LOCK_NB)
            #expect(result != 0 && (errno == EWOULDBLOCK || errno == EAGAIN))
            if result == 0 { flock(contender, LOCK_UN) }
        }
        context.defaults.beforeRemoval = { key in
            removals.insert(key)
            verifyLocked()
        }
        context.defaults.beforeSynchronize = {
            synchronizations += 1
            verifyLocked()
        }
        let store = SharedContentStore(defaults: context.defaults, lockURL: context.lock)
        #expect(store.discardAll())
        #expect(removals == Set(Self.keys))
        #expect(synchronizations == 2)
        #expect(flock(contender, LOCK_EX | LOCK_NB) == 0, "The writer lock is released after confirmation")
        for key in Self.keys { #expect(context.defaults.object(forKey: key) == nil) }
    }
}

/// Exercises the production panic transaction with a real, isolated legacy
/// mailbox. No runtime, Bluetooth manager, live app group, or network is used.
@Suite("Retired shared-content erasure", .serialized)
struct SharedContentRetirementTests {
    @Test(arguments: ["none", "retainedEnvelope", "failedFlush", "unavailableLock"])
    @MainActor
    func legacyMailboxErasureParticipatesInTheRealPanicCommit(failureMode: String) throws {
        let suite = "SharedContentRetirementTests.\(UUID().uuidString)"
        let defaults = try #require(ControlledSynchronizeDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        let lockURL = (failureMode == "unavailableLock" ? missing : root).appendingPathComponent("handoff.lock")
        let legacyKeys = ["sharedContentEnvelopeV1", "sharedContent", "sharedContentType", "sharedContentDate"]
        let retained = Data("synthetic retired payload, intentionally not decoded".utf8)
        for key in legacyKeys { defaults.set(retained, forKey: key) }
        defaults.set("keep unrelated preferences", forKey: "unrelatedFixture")
        let store = SharedContentStore(defaults: defaults, lockURL: lockURL)
        var wipes = PanicPersistentStoreWipes(
            courier: { true }, bridge: { true }, publicArchive: { true }, prekeys: { true },
            board: { true }, legacyGroups: { true }, sharedContent: { store.discardAll() }
        )
        wipes.qrContacts = { true }
        wipes.notifications = {}
        wipes.pasteboard = {}
        var commits = 0
        let operations = PanicRecoveryOperations(collectAppOwners: PanicAppOwnerAdmissionFixture.confirmedNoWork, isPending: { false }, begin: {
            PanicRecoveryIntent(fileMarkerEstablished: true, externalMarkerEstablished: false)
        }, wipeMedia: { _ in }, complete: { commits += 1 })
        let keychain = MockKeychain()
        let transport = MockTransport()
        let viewModel = ChatViewModel(
            keychain: keychain, idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain), transport: transport,
            readReceiptsDefaults: defaults,
            panicRecoveryOperations: operations, panicNetworkLifecycle: .noop,
            weshPrivatePolicyEnabled: true, weshMeetingNote: WeshMeetingNoteStore(),
            panicPersistentStoreWipes: wipes
        )
        let starts = transport.startServicesCallCount
        if failureMode == "retainedEnvelope" { defaults.refuseEnvelopeRemoval = true }
        if failureMode == "failedFlush" { defaults.synchronizeResults = [true, false, true] }

        let completed = viewModel.panicClearAllData(restartMesh: false)
        #expect(defaults.string(forKey: "unrelatedFixture") == "keep unrelated preferences")
        #expect(transport.startServicesCallCount == starts)
        if failureMode == "none" {
            #expect(completed)
            #expect(commits == 1 && !viewModel.panicRecoveryBlocked)
        } else {
            #expect(!completed)
            #expect(commits == 0 && viewModel.panicRecoveryBlocked)
            for key in legacyKeys { #expect(defaults.data(forKey: key) == retained) }
            defaults.refuseEnvelopeRemoval = false
            if failureMode == "unavailableLock" {
                try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
            }
            #expect(viewModel.panicClearAllData(restartMesh: false))
            #expect(commits == 1 && !viewModel.panicRecoveryBlocked)
        }
        for key in legacyKeys { #expect(defaults.object(forKey: key) == nil) }
        #expect(defaults.string(forKey: "unrelatedFixture") == "keep unrelated preferences")
    }
}
