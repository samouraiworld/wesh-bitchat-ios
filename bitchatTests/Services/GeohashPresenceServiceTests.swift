import Combine
import Foundation
import Testing
@testable import bitchat

@MainActor
struct GeographicPresenceRetirementTests {
    @Test
    func retiredPresenceCannotScheduleDeriveOrPublish() {
        let scheduler = MockGeohashPresenceScheduler()
        let locationChanges = PassthroughSubject<[GeohashChannel], Never>()
        let torReady = PassthroughSubject<Void, Never>()
        var derivations = 0
        var lookups = 0
        var publications = 0
        let service = GeohashPresenceService(
            availableChannelsProvider: { [GeohashChannel(level: .city, geohash: "00000")] },
            locationChanges: locationChanges.eraseToAnyPublisher(),
            torReadyPublisher: torReady.eraseToAnyPublisher(),
            torIsReady: { true },
            torIsForeground: { true },
            deriveIdentity: { _ in derivations += 1; return try NostrIdentity.generate() },
            relayLookup: { _, _ in lookups += 1; return ["wss://relay.invalid"] },
            relaySender: { _, _ in publications += 1 },
            sleeper: { _ in },
            scheduleTimer: scheduler.schedule(interval:handler:),
            loopMinInterval: 40,
            loopMaxInterval: 40,
            burstMinDelay: 0,
            burstMaxDelay: 0
        )
        defer { service.stopForPanic() }

        service.start()
        service.broadcastPresence(for: "00000")

        #expect(scheduler.intervals.isEmpty)
        #expect(derivations == 0)
        #expect(lookups == 0)
        #expect(publications == 0)
    }
}

@MainActor
struct GeohashPresenceServiceTests {
    @Test(arguments: [false, true])
    func everyLegacyTriggerStaysInertEvenWhenConnectivityChanges(ready: Bool) {
        let scheduler = MockGeohashPresenceScheduler()
        let location = PassthroughSubject<[GeohashChannel], Never>()
        let tor = PassthroughSubject<Void, Never>()
        var effects: [String] = []
        let service = GeohashPresenceService(
            availableChannelsProvider: { effects.append("channels"); return [] },
            locationChanges: location.eraseToAnyPublisher(), torReadyPublisher: tor.eraseToAnyPublisher(),
            torIsReady: { effects.append("tor"); return ready },
            torIsForeground: { effects.append("foreground"); return true },
            deriveIdentity: { _ in effects.append("derive"); return try NostrIdentity.generate() },
            relayLookup: { _, _ in effects.append("lookup"); return ["wss://synthetic.invalid"] },
            relaySender: { _, _ in effects.append("publish") },
            sleeper: { _ in effects.append("sleep") }, scheduleTimer: scheduler.schedule(interval:handler:))
        service.start()
        service.handleLocationChange()
        service.handleConnectivityChange()
        service.scheduleNextHeartbeat()
        service.performHeartbeat()
        location.send([GeohashChannel(level: .city, geohash: "00000")])
        tor.send(())
        service.broadcastPresence(for: "00000")
        service.stopForPanic()
        service.start()
        service.broadcastPresence(for: "zzzzz")
        #expect(scheduler.intervals.isEmpty)
        #expect(effects.isEmpty)
    }
}

private final class MockGeohashPresenceScheduler {
    private(set) var intervals: [TimeInterval] = []
    private(set) var timers: [MockGeohashPresenceTimer] = []

    func schedule(interval: TimeInterval, handler: @escaping () -> Void) -> GeohashPresenceTimerProtocol {
        intervals.append(interval)
        let timer = MockGeohashPresenceTimer(handler: handler)
        timers.append(timer)
        return timer
    }
}

private final class MockGeohashPresenceTimer: GeohashPresenceTimerProtocol {
    private let handler: () -> Void
    private(set) var isValid = true
    private(set) var invalidateCallCount = 0

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    func invalidate() {
        invalidateCallCount += 1
        isValid = false
    }
}
