import Combine
import Foundation
import Testing
@testable import bitchat

@MainActor
struct GeographicNotesRetirementTests {
    @Test
    func retiredNotesCannotSubscribeEvenWhenSyntheticRelaysAreAvailable() {
        let fixture = NotesRetirementFixture()
        let manager = LocationNotesManager(geohash: "00000000", dependencies: fixture.dependencies)
        defer { manager.cancel() }

        #expect(fixture.subscriptions.isEmpty)
        #expect(fixture.lookups.isEmpty)
    }

    @Test
    func retiredNotesCannotPublishOrCreateALocalEcho() {
        let fixture = NotesRetirementFixture()
        let manager = LocationNotesManager(geohash: "00000000", dependencies: fixture.dependencies)
        defer { manager.cancel() }

        manager.send(content: "Synthetic retired geographic note", nickname: "Synthetic sender")

        #expect(fixture.publications.isEmpty)
        #expect(manager.notes.isEmpty)
        #expect(fixture.identityDerivations == 0)
    }

    @Test
    func emptyNotesInputCannotPublish() {
        let fixture = NotesRetirementFixture()
        let manager = LocationNotesManager(geohash: "00000000", dependencies: fixture.dependencies)
        defer { manager.cancel() }

        manager.send(content: "   ", nickname: "Synthetic sender")

        #expect(fixture.publications.isEmpty)
        #expect(fixture.identityDerivations == 0)
    }
}

@MainActor
private final class NotesRetirementFixture {
    var subscriptions: [String] = []
    var lookups: [String] = []
    var publications: [NostrEvent] = []
    var identityDerivations = 0

    var dependencies: LocationNotesDependencies {
        LocationNotesDependencies(
            relayLookup: { cell, _ in self.lookups.append(cell); return ["wss://relay.invalid"] },
            subscribe: { _, id, _, _, _ in self.subscriptions.append(id) },
            unsubscribe: { _ in },
            sendEvent: { event, _ in self.publications.append(event) },
            deriveIdentity: { _ in self.identityDerivations += 1; return try NostrIdentity.generate() },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }
}
