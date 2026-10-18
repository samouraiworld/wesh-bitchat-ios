import BitLogger
import Combine
import Foundation

/// Dependencies for location notes, allowing tests to stub relay/identity behavior.
struct LocationNotesDependencies {
    typealias RelayLookup = @MainActor (_ geohash: String, _ count: Int) -> [String]
    typealias Subscribe = @MainActor (_ filter: NostrFilter, _ id: String, _ relays: [String], _ handler: @escaping (NostrEvent) -> Void, _ onEOSE: (() -> Void)?) -> Void
    typealias Unsubscribe = @MainActor (_ id: String) -> Void
    typealias SendEvent = @MainActor (_ event: NostrEvent, _ relayUrls: [String]) -> Void

    var relayLookup: RelayLookup
    var subscribe: Subscribe
    var unsubscribe: Unsubscribe
    var sendEvent: SendEvent
    var deriveIdentity: (_ geohash: String) throws -> NostrIdentity
    var now: () -> Date
    // Fires when the geo relay directory refreshes; used to retry after "no relays".
    var relayDirectoryUpdates: AnyPublisher<Void, Never> = Empty(completeImmediately: false).eraseToAnyPublisher()
    /// Whether any of the target relays has a live connection — distinguishes
    /// "loaded, empty" from "still connecting (Tor warming up)" when EOSE
    /// fires without data. Defaults to true so tests keep legacy behavior.
    var anyRelayConnected: @MainActor (_ relayUrls: [String]) -> Bool = { _ in true }

    private static let idBridge = NostrIdentityBridge()

    static let live = LocationNotesDependencies(
        relayLookup: { geohash, count in
            GeoRelayDirectory.shared.closestRelays(toGeohash: geohash, count: count)
        },
        subscribe: { filter, id, relays, handler, onEOSE in
            NostrRelayManager.shared.subscribe(
                filter: filter,
                id: id,
                relayUrls: relays,
                handler: handler,
                onEOSE: onEOSE
            )
        },
        unsubscribe: { id in
            NostrRelayManager.shared.unsubscribe(id: id)
        },
        sendEvent: { event, relays in
            NostrRelayManager.shared.sendEvent(event, to: relays)
        },
        deriveIdentity: { geohash in
            try idBridge.deriveIdentity(forGeohash: geohash)
        },
        now: { Date() },
        relayDirectoryUpdates: NotificationCenter.default
            .publisher(for: .geoRelayDirectoryDidRefresh)
            .map { _ in () }
            .eraseToAnyPublisher(),
        anyRelayConnected: { relayUrls in
            NostrRelayManager.shared.isAnyRelayConnected(among: relayUrls)
        }
    )
}

/// Retired geographic notes compatibility model. Public subscription and
/// publication APIs refuse work while historical note decoding stays available.
@MainActor
final class LocationNotesManager: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        /// The initial fetch timed out with zero target relays connected
        /// (usually Tor still bootstrapping): not "empty", just not there
        /// yet. Retries automatically once a relay comes up.
        case connecting
        case ready
        case noRelays
    }

    struct Note: Identifiable, Equatable {
        let id: String
        let pubkey: String
        let content: String
        let createdAt: Date
        let nickname: String?
        /// NIP-40 expiration, when the note carries one (dead drops do).
        let expiresAt: Date?

        init(
            id: String,
            pubkey: String,
            content: String,
            createdAt: Date,
            nickname: String?,
            expiresAt: Date? = nil
        ) {
            self.id = id
            self.pubkey = pubkey
            self.content = content
            self.createdAt = createdAt
            self.nickname = nickname
            self.expiresAt = expiresAt
        }

        var displayName: String {
            let suffix = String(pubkey.suffix(4))
            if let nick = nickname?.trimmedOrNilIfEmpty {
                return "\(nick)#\(suffix)"
            }
            return "anon#\(suffix)"
        }
    }

    @Published private(set) var notes: [Note] = [] // reverse-chron sorted
    @Published private(set) var geohash: String
    @Published private(set) var initialLoadComplete: Bool = false
    @Published private(set) var state: State = .loading
    @Published private(set) var errorMessage: String?
    private let dependencies: LocationNotesDependencies

    init(geohash: String, dependencies: LocationNotesDependencies = .live) {
        self.geohash = geohash.lowercased()
        self.dependencies = dependencies
        // Retired notes keep their compatibility state without creating a
        // subscription, directory observer, timer or local echo.
        state = .idle
        initialLoadComplete = true
    }

    /// Drops expired notes from the retained historical presentation model.
    func pruneExpiredNotes() {
        let now = dependencies.now()
        let expired = notes.contains { note in
            if let expiresAt = note.expiresAt { return expiresAt <= now }
            return false
        }
        guard expired else { return }
        notes.removeAll { note in
            if let expiresAt = note.expiresAt { return expiresAt <= now }
            return false
        }
    }

    // A manager's geohash is fixed for its lifetime: instances are pooled
    // per geohash (`LocationNotesPool`), so retargeting one in place would
    // corrupt the pool's keying and refcounts. Release the manager and
    // acquire the new cell instead.

    func refresh() {
        notes.removeAll()
        state = .idle
        initialLoadComplete = true
        errorMessage = nil
    }

    func clearError() { errorMessage = nil }

    func retryIfRelaysAvailable(relays: [String]) {
        // Old connectivity callbacks cannot revive a geographic subscription.
    }

    /// Send a location note for the current geohash using the per-geohash
    /// identity, optionally expiring via NIP-40 (dead drops pass 24h; the
    /// composer's ∞ option passes nil) and optionally tagged urgent.
    func send(content: String, nickname: String, expiresAt: Date? = nil, urgent: Bool = false) {
        // Retired notes never derive identities, publish, or create a local echo.
    }

    /// The NIP-40 `expiration` tag as a date, if the event carries one.
    static func expirationDate(of event: NostrEvent) -> Date? {
        guard let tag = event.tags.first(where: { $0.count >= 2 && $0[0].lowercased() == "expiration" }),
              let seconds = TimeInterval(tag[1])
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Retained command boundary: geographic drops are refused without
    /// resolving relay directories or identities.
    @MainActor
    static func postDrop(
        content: String,
        nickname: String,
        geohash: String,
        expiry: TimeInterval = TransportConfig.locationDropExpirySeconds,
        dependencies: LocationNotesDependencies = .live
    ) -> Bool {
        // Legacy command callers cannot revive geographic publication.
        return false
    }

    func cancel() {
        state = .idle
        errorMessage = nil
    }
}
