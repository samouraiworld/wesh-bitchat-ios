import BitFoundation
import Foundation
import Darwin
import Testing
@testable import bitchat

private final class ControlledSynchronizeDefaults: UserDefaults, @unchecked Sendable {
    var synchronizeResults: [Bool] = []
    var refuseEnvelopeRemoval = false
    override func removeObject(forKey defaultName: String) {
        if refuseEnvelopeRemoval && defaultName == SharedContentStore.storageKey { return }
        super.removeObject(forKey: defaultName)
    }
    override func synchronize() -> Bool {
        if !synchronizeResults.isEmpty, !synchronizeResults.removeFirst() { return false }
        return super.synchronize()
    }
}

/// Isolated notification center delivers synchronously on the test's main actor.
private final class ImportedDraftKeyRecorder: @unchecked Sendable {
    var keys: [ComposerDraftStore.Key] = []
}

@Suite("Share extension handoff", .serialized)
struct SharedContentHandoffTests {
    @Test("Panic discard requires absence after the locked flush and allows a checked retry")
    func panicDiscardRejectsRetainedEnvelopeAndClearsAllKeysOnRetry() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let payload = SharedContentPayload.text("synthetic pending share")
        try context.store.stage(payload)
        let controlled = ControlledSynchronizeDefaults(suiteName: context.suite)!
        for key in ["sharedContent", "sharedContentType", "sharedContentDate"] {
            controlled.set("synthetic legacy fixture", forKey: key)
        }
        controlled.refuseEnvelopeRemoval = true
        let store = SharedContentStore(defaults: controlled, lockURL: context.lockURL)
        #expect(!store.discardAll())
        #expect(controlled.data(forKey: SharedContentStore.storageKey) != nil)
        controlled.refuseEnvelopeRemoval = false
        #expect(store.discardAll())
        for key in [SharedContentStore.storageKey, "sharedContent", "sharedContentType", "sharedContentDate"] {
            #expect(controlled.object(forKey: key) == nil)
        }
    }

    private func makeStore() -> (suite: String, defaults: UserDefaults, lockURL: URL, store: SharedContentStore) {
        let suite = "SharedContentHandoffTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".lock")
        return (suite, defaults, lockURL, SharedContentStore(defaults: defaults, lockURL: lockURL))
    }

    @Test("A staged share survives an inactive app and a late open")
    func stagedShareSurvivesLateOpen() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let stagedAt = Date(timeIntervalSince1970: 1_000_000)
        let payload = SharedContentPayload.text("review me later", createdAt: stagedAt)

        try context.store.stage(payload, now: stagedAt)

        #expect(context.store.pending(now: stagedAt.addingTimeInterval(60 * 60)) == payload)
        #expect(context.defaults.data(forKey: SharedContentStore.storageKey) != nil)
    }

    @Test("Malformed, oversized, unsupported, and expired payloads are rejected and cleared")
    func invalidPayloadsAreRejectedAndCleared() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let now = Date(timeIntervalSince1970: 2_000_000)

        context.defaults.set(Data("not-json".utf8), forKey: SharedContentStore.storageKey)
        #expect(context.store.pending(now: now) == nil)
        #expect(context.defaults.object(forKey: SharedContentStore.storageKey) == nil)

        context.defaults.set(
            Data(repeating: 0x41, count: SharedContentPayload.maxEnvelopeBytes + 1),
            forKey: SharedContentStore.storageKey
        )
        #expect(context.store.pending(now: now) == nil)
        #expect(context.defaults.object(forKey: SharedContentStore.storageKey) == nil)

        let oversized = SharedContentPayload.text(
            String(repeating: "x", count: SharedContentPayload.maxContentBytes + 1),
            createdAt: now
        )
        #expect(throws: SharedContentHandoffError.contentTooLarge) {
            try context.store.stage(oversized, now: now)
        }
        #expect(context.defaults.object(forKey: SharedContentStore.storageKey) == nil)

        let unsupportedURL = SharedContentPayload(
            kind: .url,
            content: "file:///private/tmp/secret.txt",
            createdAt: now
        )
        #expect(throws: SharedContentHandoffError.unsupportedURL) {
            try context.store.stage(unsupportedURL, now: now)
        }

        let misleadingControl = SharedContentPayload.text("safe\u{202E}txt", createdAt: now)
        #expect(throws: SharedContentHandoffError.invalidCharacters) {
            try context.store.stage(misleadingControl, now: now)
        }

        let expired = SharedContentPayload.text(
            "too old",
            createdAt: now.addingTimeInterval(-SharedContentPayload.retentionSeconds - 1)
        )
        context.defaults.set(try JSONEncoder().encode(expired), forKey: SharedContentStore.storageKey)
        #expect(context.store.pending(now: now) == nil)
        #expect(context.defaults.object(forKey: SharedContentStore.storageKey) == nil)
    }

    @Test("Mesh, geohash, and stale private selections resolve to explicit destinations")
    func destinationsAreExplicit() {
        let geohashChannel = ChannelID.location(
            GeohashChannel(level: .city, geohash: "9Q8YY")
        )
        let stalePeer = PeerID(str: "0011223344556677")

        #expect(SharedContentDestination.resolve(
            selectedPrivatePeerID: nil,
            privateDisplayName: nil,
            activeChannel: .mesh
        ) == .mesh)
        #expect(SharedContentDestination.resolve(
            selectedPrivatePeerID: nil,
            privateDisplayName: nil,
            activeChannel: geohashChannel
        ) == .geohash("9q8yy"))
        #expect(SharedContentDestination.resolve(
            selectedPrivatePeerID: stalePeer,
            privateDisplayName: "alice",
            activeChannel: geohashChannel
        ) == .privateConversation(peerID: stalePeer, displayName: "alice"))
    }

    @Test("A destination change requires a new confirmation and never consumes on the stale tap")
    @MainActor
    func staleDestinationCannotBeConfirmed() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let now = Date(timeIntervalSince1970: 3_000_000)
        let payload = SharedContentPayload.text("do not auto-send", createdAt: now)
        let peer = PeerID(str: "8899aabbccddeeff")
        let privateDestination = SharedContentDestination.privateConversation(
            peerID: peer,
            displayName: "alice"
        )
        let model = SharedContentImportModel(store: context.store)
        try context.store.stage(payload, now: now)
        model.refresh(destination: privateDestination, now: now)

        #expect(model.confirm(destination: .mesh, now: now) == nil)
        #expect(model.offer?.destination == .mesh)
        #expect(context.store.pending(now: now) == payload)

        #expect(model.confirm(destination: .mesh, now: now) == payload.content)
        #expect(model.offer == nil)
        #expect(context.store.pending(now: now) == nil)
    }

    @Test("Confirmation consumes once and cancellation explicitly clears without producing composer text")
    @MainActor
    func oneTimeConfirmationAndCancellation() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let now = Date(timeIntervalSince1970: 4_000_000)
        let model = SharedContentImportModel(store: context.store)

        let first = SharedContentPayload.text("confirmed", createdAt: now)
        try context.store.stage(first, now: now)
        model.refresh(destination: .geohash("u4pruy"), now: now)
        #expect(model.confirm(destination: .geohash("u4pruy"), now: now) == "confirmed")
        #expect(model.confirm(destination: .geohash("u4pruy"), now: now) == nil)

        let second = SharedContentPayload.text("cancelled", createdAt: now)
        try context.store.stage(second, now: now)
        model.refresh(destination: .mesh, now: now)
        model.cancel(destination: .mesh, now: now)
        #expect(model.offer == nil)
        #expect(context.store.pending(now: now) == nil)

        let third = SharedContentPayload.text("panic-wiped", createdAt: now)
        try context.store.stage(third, now: now)
        model.refresh(destination: .mesh, now: now)
        model.discardAll()
        #expect(model.offer == nil)
        #expect(context.store.pending(now: now) == nil)
    }

    @Test("Cancelling an old review never deletes a newer staged share")
    @MainActor
    func cancellationPreservesNewerShare() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let now = Date(timeIntervalSince1970: 5_000_000)
        let model = SharedContentImportModel(store: context.store)
        let old = SharedContentPayload.text("old", createdAt: now)
        let newer = SharedContentPayload.text("new", createdAt: now)

        try context.store.stage(old, now: now)
        model.refresh(destination: .mesh, now: now)
        try context.store.stage(newer, now: now)
        model.cancel(destination: .mesh, now: now)

        #expect(model.offer?.payload == newer)
        #expect(context.store.pending(now: now) == newer)
    }

    @Test("Wesh refuses short aliases and location routes without consuming the share")
    @MainActor
    func weshRequiresAnExplicitStableRoute() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let now = Date(timeIntervalSince1970: 6_000_000)
        let payload = SharedContentPayload.text("route explicitly", createdAt: now)
        let model = SharedContentImportModel(store: context.store)
        try context.store.stage(payload, now: now)
        model.refresh(destination: .mesh, now: now)

        let unsupported: [SharedContentDestination] = [
            .geohash("u4pruy"),
            .privateConversation(peerID: PeerID(str: "0011223344556677"), displayName: "Alias")
        ]
        for destination in unsupported {
            #expect(throws: WeshSharedContentReview.Issue.unavailableDestination) {
                try WeshSharedContentReview.prepare(id: payload.id, destination: destination,
                    model: model, destinationAllowed: true, now: now).get()
            }
            #expect(model.offer?.destination == .mesh)
            #expect(context.store.pending(now: now) == payload)
        }
    }

    @Test("A Wesh confirmation pins the full Noise key and rejects a changed destination")
    @MainActor
    func weshConfirmationRejectsRouteDrift() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let now = Date(timeIntervalSince1970: 7_000_000)
        let payload = SharedContentPayload.text("private draft", createdAt: now)
        let peer = PeerID(hexData: Data(repeating: 0x11, count: 32))
        let destination = SharedContentDestination.privateConversation(peerID: peer, displayName: "Nora")
        let model = SharedContentImportModel(store: context.store)
        try context.store.stage(payload, now: now)
        model.refresh(destination: .mesh, now: now)
        let reviewed = try WeshSharedContentReview.prepare(id: payload.id, destination: destination,
            model: model, destinationAllowed: true, now: now).get()
        #expect(reviewed.destination == destination)
        model.updateDestination(.mesh)

        #expect(throws: WeshSharedContentReview.Issue.changed) {
            try WeshSharedContentReview.confirm(reviewed: reviewed, model: model,
                destinationAllowed: true, now: now).get()
        }
        #expect(model.offer?.destination == .mesh)
        #expect(context.store.pending(now: now) == payload)
    }

    @Test("A stale Wesh confirmation and cancellation preserve a newer share, refreshed or not")
    @MainActor
    func weshReviewPreservesNewerEnvelope() throws {
        for refreshBeforeTap in [false, true] {
            let context = makeStore()
            defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
            let now = Date(timeIntervalSince1970: 8_000_000)
            let old = SharedContentPayload.text("old review", createdAt: now)
            let newer = SharedContentPayload.text("new review needed", createdAt: now)
            let model = SharedContentImportModel(store: context.store)
            try context.store.stage(old, now: now)
            model.refresh(destination: .mesh, now: now)
            let reviewed = try WeshSharedContentReview.prepare(id: old.id, destination: .mesh,
                model: model, destinationAllowed: true, now: now).get()
            try context.store.stage(newer, now: now)
            if refreshBeforeTap { model.refresh(destination: .mesh, now: now) }

            #expect(throws: WeshSharedContentReview.Issue.changed) {
                try WeshSharedContentReview.confirm(reviewed: reviewed, model: model,
                    destinationAllowed: true, now: now).get()
            }
            WeshSharedContentReview.cancel(id: old.id, destination: .mesh, model: model, now: now)
            #expect(model.offer?.payload == newer)
            #expect(context.store.pending(now: now) == newer)
        }
    }

    @Test("A Wesh review compares the complete payload even when an envelope ID is reused")
    @MainActor
    func weshReviewRejectsChangedContentWithSameID() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let now = Date(timeIntervalSince1970: 9_000_000)
        let payload = SharedContentPayload.text("reviewed text", createdAt: now)
        let model = SharedContentImportModel(store: context.store)
        try context.store.stage(payload, now: now)
        model.refresh(destination: .mesh, now: now)
        let reviewed = try WeshSharedContentReview.prepare(id: payload.id, destination: .mesh,
            model: model, destinationAllowed: true, now: now).get()
        let changed = SharedContentPayload(id: payload.id, kind: .text, content: "not reviewed", createdAt: now)
        try context.store.stage(changed, now: now)

        #expect(throws: WeshSharedContentReview.Issue.changed) {
            try WeshSharedContentReview.confirm(reviewed: reviewed, model: model,
                destinationAllowed: true, now: now).get()
        }
        #expect(context.store.pending(now: now) == changed)
    }

    @Test("Revoking a QR destination after review prevents draft import and keeps the envelope")
    @MainActor
    func weshRechecksDestinationEligibility() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let now = Date(timeIntervalSince1970: 10_000_000)
        let payload = SharedContentPayload.text("blocked while reviewing", createdAt: now)
        let destination = SharedContentDestination.privateConversation(
            peerID: PeerID(hexData: Data(repeating: 0x22, count: 32)), displayName: "Nora")
        let model = SharedContentImportModel(store: context.store)
        try context.store.stage(payload, now: now)
        model.refresh(destination: .mesh, now: now)
        let reviewed = try WeshSharedContentReview.prepare(id: payload.id, destination: destination,
            model: model, destinationAllowed: true, now: now).get()

        #expect(throws: WeshSharedContentReview.Issue.unavailableDestination) {
            try WeshSharedContentReview.confirm(reviewed: reviewed, model: model,
                destinationAllowed: false, now: now).get()
        }
        #expect(context.store.pending(now: now) == payload)
    }

    @Test("Oversized Wesh drafts are neither consumed nor silently truncated")
    @MainActor
    func weshRejectsOversizedDraft() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let now = Date(timeIntervalSince1970: 11_000_000)
        let payload = SharedContentPayload.text(
            String(repeating: "x", count: ComposerDraftStore.maxDraftLength + 1), createdAt: now)
        let model = SharedContentImportModel(store: context.store)
        try context.store.stage(payload, now: now)
        model.refresh(destination: .mesh, now: now)
        let reviewed = try #require(model.offer)

        #expect(throws: WeshSharedContentReview.Issue.tooLong) {
            try WeshSharedContentReview.prepare(id: payload.id, destination: .mesh,
                model: model, destinationAllowed: true, now: now).get()
        }
        #expect(throws: WeshSharedContentReview.Issue.tooLong) {
            try WeshSharedContentReview.confirm(reviewed: reviewed, model: model,
                destinationAllowed: true, now: now).get()
        }
        #expect(context.store.pending(now: now) == payload)
    }

    @Test("A Unicode draft at the exact Wesh character limit imports intact once")
    @MainActor
    func weshImportsExactUnicodeLimitOnce() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let now = Date(timeIntervalSince1970: 12_000_000)
        let payload = SharedContentPayload.text(
            String(repeating: "é", count: ComposerDraftStore.maxDraftLength), createdAt: now)
        let model = SharedContentImportModel(store: context.store)
        try context.store.stage(payload, now: now)
        model.refresh(destination: .mesh, now: now)
        let reviewed = try WeshSharedContentReview.prepare(id: payload.id, destination: .mesh,
            model: model, destinationAllowed: true, now: now).get()

        #expect(try WeshSharedContentReview.confirm(reviewed: reviewed, model: model,
            destinationAllowed: true, now: now).get() == payload.content)
        #expect(context.store.pending(now: now) == nil)
        #expect(throws: WeshSharedContentReview.Issue.changed) {
            try WeshSharedContentReview.confirm(reviewed: reviewed, model: model,
                destinationAllowed: true, now: now).get()
        }
    }

    @Test("An envelope that expires while the Wesh confirmation is open cannot be imported")
    @MainActor
    func weshRechecksExpiryBeforeImport() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let now = Date(timeIntervalSince1970: 13_000_000)
        let payload = SharedContentPayload.text("expires before consent", createdAt: now)
        let model = SharedContentImportModel(store: context.store)
        try context.store.stage(payload, now: now)
        model.refresh(destination: .mesh, now: now)
        let reviewed = try WeshSharedContentReview.prepare(id: payload.id, destination: .mesh,
            model: model, destinationAllowed: true, now: now).get()

        #expect(throws: WeshSharedContentReview.Issue.changed) {
            try WeshSharedContentReview.confirm(reviewed: reviewed, model: model,
                destinationAllowed: true, now: now.addingTimeInterval(SharedContentPayload.retentionSeconds + 1)).get()
        }
        #expect(model.offer == nil)
    }
    @Test("An extension stage between lookup and deletion waits for the app-group file lock")
    func concurrentStagePreservesNewEnvelope() throws {
        for operation in ["consume", "discard", "expired"] {
            let context = makeStore()
            defer {
                context.defaults.removePersistentDomain(forName: context.suite)
                try? FileManager.default.removeItem(at: context.lockURL)
            }
            let oldTime = Date(timeIntervalSince1970: 20_000_000)
            let reviewTime = operation == "expired" ? oldTime.addingTimeInterval(SharedContentPayload.retentionSeconds + 1) : oldTime
            let old = SharedContentPayload.text("old", createdAt: oldTime)
            let newer = SharedContentPayload.text("new from extension", createdAt: reviewTime)
            try context.store.stage(old, now: oldTime)
            let extensionStore = SharedContentStore(defaults: UserDefaults(suiteName: context.suite)!, lockURL: context.lockURL)
            let started = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            context.store.beforeRemovalForTesting = {
                DispatchQueue.global().async {
                    started.signal()
                    try? extensionStore.stage(newer, now: reviewTime)
                    finished.signal()
                }
                #expect(started.wait(timeout: .now() + 2) == .success)
                // A distinct BSD descriptor cannot acquire this shared lock,
                // as an extension process would not be able to acquire it.
                let descriptor = Darwin.open(context.lockURL.path, O_RDWR)
                #expect(descriptor >= 0)
                if descriptor >= 0 {
                    #expect(flock(descriptor, LOCK_EX | LOCK_NB) != 0)
                    Darwin.close(descriptor)
                }
                #expect(finished.wait(timeout: .now()) == .timedOut)
            }
            switch operation {
            case "consume": #expect(context.store.consume(id: old.id, now: reviewTime) == old)
            case "discard": context.store.discard(id: old.id)
            default: #expect(context.store.pending(now: reviewTime) == nil)
            }
            #expect(finished.wait(timeout: .now() + 2) == .success)
            #expect(context.store.pending(now: reviewTime) == newer)
        }
    }

    @Test("Unavailable shared locking fails closed without deleting the existing envelope")
    func unavailableLockPreservesPendingData() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let payload = SharedContentPayload.text("retain me")
        let encoded = try JSONEncoder().encode(payload)
        context.defaults.set(encoded, forKey: SharedContentStore.storageKey)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("missing.lock")
        let unavailable = SharedContentStore(defaults: context.defaults, lockURL: missing)
        #expect(throws: SharedContentHandoffError.storageUnavailable) { try unavailable.stage(.text("replacement")) }
        #expect(unavailable.pending() == nil)
        #expect(unavailable.consume(id: payload.id) == nil)
        unavailable.discard(id: payload.id)
        #expect(!unavailable.discardAll())
        #expect(context.defaults.data(forKey: SharedContentStore.storageKey) == encoded)
    }

    @Test("A failed preference flush restores an envelope instead of losing a review")
    func failedFlushRestoresPreviousEnvelope() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let payload = SharedContentPayload.text("retain reviewed text")
        try context.store.stage(payload)
        let controlled = ControlledSynchronizeDefaults(suiteName: context.suite)!
        let store = SharedContentStore(defaults: controlled, lockURL: context.lockURL)
        controlled.synchronizeResults = [true, false, true]
        #expect(throws: SharedContentHandoffError.storageUnavailable) { try store.stage(.text("new text")) }
        #expect(store.pending() == payload)
        controlled.synchronizeResults = [true, false, true]
        #expect(store.consume(id: payload.id) == nil)
        #expect(store.pending() == payload)
        controlled.synchronizeResults = [true, false, true]
        store.discard(id: payload.id)
        #expect(store.pending() == payload)
        controlled.synchronizeResults = [true, false, true]
        #expect(!store.discardAll())
        #expect(store.pending() == payload)
        #expect(store.discardAll())
        #expect(controlled.object(forKey: SharedContentStore.storageKey) == nil)
        let malformed = Data("invalid json".utf8)
        controlled.set(malformed, forKey: SharedContentStore.storageKey)
        controlled.synchronizeResults = [true, false, true]
        #expect(store.pending() == nil)
        #expect(controlled.data(forKey: SharedContentStore.storageKey) == malformed)
    }

    @Test("A suspended writer cannot make the app wait without a bound or delete its payload")
    func heldLockRefusesAfterDeterministicBudget() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let payload = SharedContentPayload.text("held by extension")
        try context.store.stage(payload)
        let descriptor = Darwin.open(context.lockURL.path, O_RDWR)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        var clock: TimeInterval = 0
        var pauses = 0
        let contender = SharedContentStore(defaults: context.defaults, lockURL: context.lockURL,
            lockTimeout: 0.05, monotonicNow: { clock }, pauseBeforeLockRetry: { pauses += 1; clock += 0.05 })
        #expect(contender.consume(id: payload.id) == nil)
        #expect(pauses == 1)
        #expect(context.defaults.data(forKey: SharedContentStore.storageKey) != nil)
        #expect(throws: SharedContentHandoffError.storageUnavailable) { try contender.stage(.text("new")) }
        #expect(pauses == 2)
        flock(descriptor, LOCK_UN)
        #expect(contender.pending() == payload)
    }

    @Test("Cancel replacement preserves the pending review and existing draft; explicit discard removes only the share")
    @MainActor
    func cancelledReplacementDefersRatherThanDiscards() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let previousDrafts = ComposerDraftStore.replaceAllForTesting(["mesh": "existing draft"])
        defer { ComposerDraftStore.replaceAllForTesting(previousDrafts) }
        let now = Date(timeIntervalSince1970: 21_000_000)
        let payload = SharedContentPayload.text("shared draft", createdAt: now)
        try context.store.stage(payload, now: now)
        let model = SharedContentImportModel(store: context.store)
        model.refresh(destination: .mesh, now: now)
        let reviewed = try WeshSharedContentReview.prepare(id: payload.id, destination: .mesh,
            model: model, destinationAllowed: true, now: now).get()
        #expect(try WeshSharedContentReview.deferReplacement(reviewed: reviewed, model: model, now: now).get() == reviewed)
        #expect(model.offer == reviewed)
        #expect(context.store.pending(now: now) == payload)
        #expect(ComposerDraftStore.load(.mesh) == "existing draft")
        #expect(try WeshSharedContentReview.prepare(id: payload.id, destination: .mesh,
            model: model, destinationAllowed: true, now: now).get() == reviewed)
        WeshSharedContentReview.cancel(id: payload.id, destination: .mesh, model: model, now: now)
        #expect(model.offer == nil)
        #expect(context.store.pending(now: now) == nil)
        #expect(ComposerDraftStore.load(.mesh) == "existing draft")
    }

    @Test("Successful import stores only the reviewed identity draft before closing, exactly once")
    @MainActor
    func successfulImportClosesAfterScopedDraftSave() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let first = PeerID(hexData: Data(repeating: 0x41, count: 32))
        let second = PeerID(hexData: Data(repeating: 0x42, count: 32))
        let firstKey = ComposerDraftStore.Key.from(peerID: first, fingerprint: first.noiseKey?.sha256Fingerprint(), channel: .mesh)
        let secondKey = ComposerDraftStore.Key.from(peerID: second, fingerprint: second.noiseKey?.sha256Fingerprint(), channel: .mesh)
        let previousDrafts = ComposerDraftStore.replaceAllForTesting(["mesh": "public draft", firstKey.storageString: "first draft", secondKey.storageString: "second draft"])
        defer { ComposerDraftStore.replaceAllForTesting(previousDrafts) }
        let now = Date(timeIntervalSince1970: 22_000_000)
        let payload = SharedContentPayload.text("private shared draft", createdAt: now)
        try context.store.stage(payload, now: now)
        let model = SharedContentImportModel(store: context.store)
        model.refresh(destination: .mesh, now: now)
        let reviewed = try WeshSharedContentReview.prepare(id: payload.id,
            destination: .privateConversation(peerID: first, displayName: "Same nickname"),
            model: model, destinationAllowed: true, now: now).get()
        let center = NotificationCenter()
        let recorded = ImportedDraftKeyRecorder()
        let token = center.addObserver(forName: WeshSharedContentReview.importedDraftNotification, object: nil, queue: nil) { note in
            if let key = note.object as? ComposerDraftStore.Key { recorded.keys.append(key) }
        }
        defer { center.removeObserver(token) }
        var closed = 0
        let imported = try WeshSharedContentReview.importDraft(reviewed: reviewed, model: model,
            destinationAllowed: true, notificationCenter: center, onImported: {
                closed += 1
                #expect(model.offer == nil)
                #expect(ComposerDraftStore.load(firstKey) == payload.content)
            }, now: now).get()
        #expect(imported == payload.content)
        #expect(closed == 1)
        #expect(recorded.keys == [firstKey])
        #expect(context.store.pending(now: now) == nil)
        #expect(ComposerDraftStore.load(.mesh) == "public draft")
        #expect(ComposerDraftStore.load(secondKey) == "second draft")
        #expect(throws: WeshSharedContentReview.Issue.changed) {
            try WeshSharedContentReview.importDraft(reviewed: reviewed, model: model,
                destinationAllowed: true, notificationCenter: center, onImported: { closed += 1 }, now: now).get()
        }
        #expect(closed == 1)
        #expect(recorded.keys == [firstKey])
    }

    @Test("Refused draft admission preserves the reviewed share for retry without success notification")
    @MainActor
    func refusedDraftAdmissionKeepsOfferAndCanRetry() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let now = Date(timeIntervalSince1970: 22_000_000)
        let payload = SharedContentPayload.text("synthetic pending share", createdAt: now)
        try context.store.stage(payload, now: now)
        let model = SharedContentImportModel(store: context.store)
        model.refresh(destination: .mesh, now: now)
        let reviewed = try WeshSharedContentReview.prepare(id: payload.id, destination: .mesh,
            model: model, destinationAllowed: true, now: now).get()
        let repository = ComposerDraftRepository()
        repository.suspendForPanic()
        let center = NotificationCenter()
        let recorded = ImportedDraftKeyRecorder()
        let token = center.addObserver(forName: WeshSharedContentReview.importedDraftNotification, object: nil, queue: nil) { note in
            if let key = note.object as? ComposerDraftStore.Key { recorded.keys.append(key) }
        }
        defer { center.removeObserver(token) }
        var closed = 0
        #expect(throws: WeshSharedContentReview.Issue.draftUnavailable) {
            try WeshSharedContentReview.importDraft(reviewed: reviewed, model: model, destinationAllowed: true,
                notificationCenter: center, repository: repository, onImported: { closed += 1 }, now: now).get()
        }
        #expect(model.offer == reviewed)
        #expect(context.store.pending(now: now) == payload)
        #expect(recorded.keys.isEmpty)
        #expect(closed == 0)
        repository.completePanic(success: true, owner: nil)
        #expect(try WeshSharedContentReview.importDraft(reviewed: reviewed, model: model, destinationAllowed: true,
            notificationCenter: center, repository: repository, onImported: { closed += 1 }, now: now).get() == payload.content)
        #expect(recorded.keys == [.mesh])
        #expect(closed == 1)
        #expect(model.offer == nil)
    }

    @Test("Combining text over the byte limit remains a pending share")
    @MainActor
    func sharedCombiningTextCannotBypassDraftByteLimit() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let now = Date(timeIntervalSince1970: 22_000_000)
        let original = SharedContentPayload.text("pending original", createdAt: now)
        try context.store.stage(original, now: now)
        let model = SharedContentImportModel(store: context.store)
        model.refresh(destination: .mesh, now: now)
        let payload = SharedContentPayload.text("a" + String(repeating: "\u{301}", count: 16_001), createdAt: now)
        #expect(throws: SharedContentHandoffError.contentTooLarge) { try context.store.stage(payload, now: now) }
        #expect(context.store.pending(now: now) == original)
        #expect(model.offer?.id == original.id)
    }

    @Test("Deferring an older confirmation refreshes but cannot erase a newer share or import stale content")
    @MainActor
    func deferredOldReviewPreservesNewShare() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let previousDrafts = ComposerDraftStore.replaceAllForTesting(["mesh": "existing"])
        defer { ComposerDraftStore.replaceAllForTesting(previousDrafts) }
        let now = Date(timeIntervalSince1970: 23_000_000)
        let old = SharedContentPayload.text("old", createdAt: now)
        let newer = SharedContentPayload.text("new", createdAt: now)
        try context.store.stage(old, now: now)
        let model = SharedContentImportModel(store: context.store)
        model.refresh(destination: .mesh, now: now)
        let reviewed = try #require(model.offer)
        try context.store.stage(newer, now: now)
        #expect(throws: WeshSharedContentReview.Issue.changed) {
            try WeshSharedContentReview.deferReplacement(reviewed: reviewed, model: model, now: now).get()
        }
        var closed = false
        #expect(throws: WeshSharedContentReview.Issue.changed) {
            try WeshSharedContentReview.importDraft(reviewed: reviewed, model: model,
                destinationAllowed: true, notificationCenter: NotificationCenter(), onImported: { closed = true }, now: now).get()
        }
        WeshSharedContentReview.cancel(id: old.id, destination: .mesh, model: model, now: now)
        #expect(!closed)
        #expect(model.offer?.payload == newer)
        #expect(context.store.pending(now: now) == newer)
        #expect(ComposerDraftStore.load(.mesh) == "existing")
    }

    @Test("A revoked destination cannot update a draft or close review")
    @MainActor
    func revokedDestinationCannotCloseImport() throws {
        let context = makeStore()
        defer {
            context.defaults.removePersistentDomain(forName: context.suite)
            try? FileManager.default.removeItem(at: context.lockURL)
        }
        let previousDrafts = ComposerDraftStore.replaceAllForTesting(["mesh": "existing"])
        defer { ComposerDraftStore.replaceAllForTesting(previousDrafts) }
        let now = Date(timeIntervalSince1970: 24_000_000)
        let payload = SharedContentPayload.text("review only", createdAt: now)
        try context.store.stage(payload, now: now)
        let model = SharedContentImportModel(store: context.store)
        model.refresh(destination: .mesh, now: now)
        let reviewed = try #require(model.offer)
        var closed = false
        #expect(throws: WeshSharedContentReview.Issue.unavailableDestination) {
            try WeshSharedContentReview.importDraft(reviewed: reviewed, model: model,
                destinationAllowed: false, notificationCenter: NotificationCenter(), onImported: { closed = true }, now: now).get()
        }
        #expect(!closed)
        #expect(model.offer == reviewed)
        #expect(context.store.pending(now: now) == payload)
        #expect(ComposerDraftStore.load(.mesh) == "existing")
    }

}
