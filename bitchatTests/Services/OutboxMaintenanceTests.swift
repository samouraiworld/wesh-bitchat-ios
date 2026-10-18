import BitFoundation
import Foundation
import Testing
@testable import bitchat

@MainActor
struct OutboxMaintenanceTests {
    @Test
    func aMaintenanceTickExpiresOldMailWithoutAnInternetBridge() async throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let transport = MockTransport()
        let peer = PeerID(str: "1020304050607080")
        let router = MessageRouter(transports: [transport], now: { now },
            courierDirectory: CourierDirectory(noiseKey: { _ in nil }, isTrustedCourier: { _ in false }))
        var dropped: [String] = []
        router.onMessageDropped = { messageID, _ in dropped.append(messageID) }
        router.sendPrivate("Synthetic old mail", to: peer, recipientNickname: "Synthetic peer", messageID: "old")
        let gate = MaintenanceSleepGate()
        let maintenance = router.startOutboxMaintenance(sleep: gate.sleep)
        defer {
            maintenance.cancel()
            gate.resume(throwing: CancellationError())
        }
        try #require(await TestHelpers.waitUntil({ gate.isWaiting }, timeout: TestConstants.longTimeout))
        #expect(gate.intervals == [120_000_000_000])
        now = now.addingTimeInterval(24 * 60 * 60 - 60)
        router.sendPrivate("Synthetic fresh mail", to: peer, recipientNickname: "Synthetic peer", messageID: "fresh")
        now = now.addingTimeInterval(120)

        gate.resume()
        try #require(await TestHelpers.waitUntil({ dropped == ["old"] && gate.isWaiting },
            timeout: TestConstants.longTimeout))
        maintenance.cancel()
        gate.resume(throwing: CancellationError())
        await maintenance.value

        transport.reachablePeers.insert(peer)
        router.flushOutbox(for: peer)
        #expect(transport.sentPrivateMessages.map(\.messageID) == ["fresh"])
        #expect(dropped == ["old"])
    }

    @Test
    func cancellingMaintenanceCannotExpireMailFromAResumedOldTick() async throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let router = MessageRouter(transports: [], now: { now },
            courierDirectory: CourierDirectory(noiseKey: { _ in nil }, isTrustedCourier: { _ in false }))
        let peer = PeerID(str: "1020304050607080")
        var dropped: [String] = []
        router.onMessageDropped = { messageID, _ in dropped.append(messageID) }
        router.sendPrivate("Synthetic retained mail", to: peer, recipientNickname: "Synthetic peer", messageID: "retained")
        let gate = MaintenanceSleepGate()
        let maintenance = router.startOutboxMaintenance(sleep: gate.sleep)
        defer {
            maintenance.cancel()
            gate.resume(throwing: CancellationError())
        }
        try #require(await TestHelpers.waitUntil({ gate.isWaiting }, timeout: TestConstants.longTimeout))
        now = now.addingTimeInterval(24 * 60 * 60 + 1)

        maintenance.cancel()
        gate.resume()
        await maintenance.value

        #expect(dropped.isEmpty)
        router.cleanupExpiredMessages()
        #expect(dropped == ["retained"])
    }
}

/// Controls completion of the actual maintenance sleep without waiting for
/// elapsed wall time. Every test cancels and resumes its owned task on exit.
@MainActor
private final class MaintenanceSleepGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var intervals: [UInt64] = []
    var isWaiting: Bool { continuation != nil }

    func sleep(_ nanoseconds: UInt64) async throws {
        intervals.append(nanoseconds)
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func resume(throwing error: Error? = nil) {
        let pending = continuation
        continuation = nil
        if let error { pending?.resume(throwing: error) }
        else { pending?.resume() }
    }
}
