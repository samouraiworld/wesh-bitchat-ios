// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

import Foundation
import Combine

protocol GeohashPresenceTimerProtocol: AnyObject {
    var isValid: Bool { get }
    func invalidate()
}

private final class RetiredGeohashPresenceTimer: GeohashPresenceTimerProtocol {
    var isValid: Bool { false }
    func invalidate() {}
}

/// Compatibility surface until the retired geographic platform graph is
/// removed. Construction and all entrypoints are inert: no location owner,
/// observers, timers, identities or relay adapters are resolved.
@MainActor
final class GeohashPresenceService: ObservableObject {
    private static var existingShared: GeohashPresenceService?
    static var shared: GeohashPresenceService {
        if let existingShared { return existingShared }
        let service = GeohashPresenceService()
        existingShared = service
        return service
    }

    static func stopExistingForPanic() {
        existingShared?.stopForPanic()
    }

    private init() {}

    internal init(
        availableChannelsProvider _: @escaping () -> [GeohashChannel],
        locationChanges _: AnyPublisher<[GeohashChannel], Never>,
        torReadyPublisher _: AnyPublisher<Void, Never>,
        torIsReady _: @escaping () -> Bool,
        torIsForeground _: @escaping () -> Bool,
        deriveIdentity _: @escaping (String) throws -> NostrIdentity,
        relayLookup _: @escaping (String, Int) -> [String],
        relaySender _: @escaping (NostrEvent, [String]) -> Void,
        sleeper _: @escaping (UInt64) async -> Void = { _ in },
        scheduleTimer _: @escaping (TimeInterval, @escaping () -> Void) -> GeohashPresenceTimerProtocol = { _, _ in
            RetiredGeohashPresenceTimer()
        },
        loopMinInterval _: TimeInterval = 40,
        loopMaxInterval _: TimeInterval = 80,
        burstMinDelay _: TimeInterval = 2,
        burstMaxDelay _: TimeInterval = 5
    ) {}

    func start() {}
    func stopForPanic() {}
    func handleLocationChange() {}
    func handleConnectivityChange() {}
    func scheduleNextHeartbeat() {}
    func performHeartbeat() {}
    func broadcastPresence(for geohash: String) {}
}
