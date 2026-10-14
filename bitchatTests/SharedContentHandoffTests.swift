import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("Share extension handoff", .serialized)
struct SharedContentHandoffTests {
    private func makeStore() -> (suite: String, defaults: UserDefaults, store: SharedContentStore) {
        let suite = "SharedContentHandoffTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (suite, defaults, SharedContentStore(defaults: defaults))
    }

    @Test("A staged share survives an inactive app and a late open")
    func stagedShareSurvivesLateOpen() throws {
        let context = makeStore()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let stagedAt = Date(timeIntervalSince1970: 1_000_000)
        let payload = SharedContentPayload.text("review me later", createdAt: stagedAt)

        try context.store.stage(payload, now: stagedAt)

        #expect(context.store.pending(now: stagedAt.addingTimeInterval(60 * 60)) == payload)
        #expect(context.defaults.data(forKey: SharedContentStore.storageKey) != nil)
    }

    @Test("Malformed, oversized, unsupported, and expired payloads are rejected and cleared")
    func invalidPayloadsAreRejectedAndCleared() throws {
        let context = makeStore()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
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
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
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
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
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
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
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
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
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
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
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
            defer { context.defaults.removePersistentDomain(forName: context.suite) }
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
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
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
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
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
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
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
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
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
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
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
}
