import Testing
import Combine
import Foundation
@testable import bitchat

/// The retired compatibility manager is exercised only with synthetic deps.
@MainActor
struct LocationNotesManagerTests {
    @Test(arguments: [false, true])
    func constructionRefusesSubscriptionsRegardlessOfRelayAvailability(available: Bool) {
        let fixture = RetiredNotesFixture(relaysAvailable: available)
        let manager = LocationNotesManager(geohash: "00000000", dependencies: fixture.dependencies)
        #expect(fixture.effects.isEmpty)
        #expect(manager.state == .idle)
        #expect(manager.initialLoadComplete)
        #expect(manager.notes.isEmpty)
        #expect(manager.errorMessage == nil)
    }

    @Test
    func directoryConnectivityRefreshAndCancellationCannotReviveSubscription() async {
        let fixture = RetiredNotesFixture(relaysAvailable: true)
        let manager = LocationNotesManager(geohash: "00000000", dependencies: fixture.dependencies)
        fixture.directory.send(())
        manager.retryIfRelaysAvailable(relays: ["wss://synthetic.invalid"])
        manager.refresh()
        manager.cancel()
        manager.refresh()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(fixture.effects.isEmpty)
        #expect(manager.state == .idle)
        #expect(manager.initialLoadComplete)
    }

    @Test(arguments: ["", "   ", "Synthetic retired note"])
    func sendsCannotDerivePublishOrEcho(content: String) {
        let fixture = RetiredNotesFixture(relaysAvailable: true)
        let manager = LocationNotesManager(geohash: "00000000", dependencies: fixture.dependencies)
        manager.send(content: content, nickname: "Synthetic", expiresAt: Date(timeIntervalSince1970: 1_700_000_000), urgent: true)
        manager.clearError()
        #expect(fixture.effects.isEmpty)
        #expect(manager.notes.isEmpty)
        #expect(manager.errorMessage == nil)
    }

    @Test(arguments: [false, true])
    func oneShotDropRefusesWithoutConsultingRelays(available: Bool) {
        let fixture = RetiredNotesFixture(relaysAvailable: available)
        #expect(!LocationNotesManager.postDrop(content: "Synthetic retired drop", nickname: "Synthetic",
            geohash: "00000000", dependencies: fixture.dependencies))
        #expect(fixture.effects.isEmpty)
    }

    @Test
    func historicalExpirationDecoderKeepsValidAndMissingTagSemantics() {
        func event(tags: [[String]]) -> NostrEvent {
            NostrEvent(pubkey: String(repeating: "ab", count: 32), createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                kind: .textNote, tags: tags, content: "Synthetic historical note")
        }
        #expect(LocationNotesManager.expirationDate(of: event(tags: [["expiration", "1700000060"]]))
            == Date(timeIntervalSince1970: 1_700_000_060))
        #expect(LocationNotesManager.expirationDate(of: event(tags: [["EXPIRATION", "1700000060"]]))
            == Date(timeIntervalSince1970: 1_700_000_060))
        #expect(LocationNotesManager.expirationDate(of: event(tags: [])) == nil)
        #expect(LocationNotesManager.expirationDate(of: event(tags: [["expiration", "invalid"]])) == nil)
        #expect(LocationNotesManager.expirationDate(of: event(tags: [["expiration"]])) == nil)
    }

    @Test
    func historicalNoteNamesRemainStableWithoutNetworkWork() {
        let note = LocationNotesManager.Note(id: "synthetic-note", pubkey: String(repeating: "ab", count: 32),
            content: "Synthetic", createdAt: Date(timeIntervalSince1970: 1_700_000_000), nickname: "Synthetic")
        #expect(note.displayName == "Synthetic#abab")
        let anonymous = LocationNotesManager.Note(id: "synthetic-anon", pubkey: note.pubkey,
            content: "Synthetic", createdAt: note.createdAt, nickname: nil)
        #expect(anonymous.displayName == "anon#abab")
    }
}

@MainActor
private final class RetiredNotesFixture {
    let directory = PassthroughSubject<Void, Never>()
    private(set) var effects: [String] = []
    let relaysAvailable: Bool
    init(relaysAvailable: Bool) { self.relaysAvailable = relaysAvailable }
    var dependencies: LocationNotesDependencies {
        LocationNotesDependencies(
            relayLookup: { _, _ in self.effects.append("lookup"); return self.relaysAvailable ? ["wss://synthetic.invalid"] : [] },
            subscribe: { _, _, _, _, _ in self.effects.append("subscribe") },
            unsubscribe: { _ in self.effects.append("unsubscribe") },
            sendEvent: { _, _ in self.effects.append("send") },
            deriveIdentity: { _ in self.effects.append("derive"); return try NostrIdentity.generate() },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            relayDirectoryUpdates: directory.eraseToAnyPublisher(),
            anyRelayConnected: { _ in self.effects.append("connected"); return true })
    }
}
