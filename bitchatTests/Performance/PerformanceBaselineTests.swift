//
// PerformanceBaselineTests.swift
// bitchatTests
//
// Performance baselines for hot paths so regressions are measured, not
// guessed. Uses XCTest `measure {}` (swift-testing has no equivalent) with
// NO recorded baselines — these tests record timing in CI logs but never
// fail on timing, so they cannot flake.
//
// Each benchmark builds its fixtures OUTSIDE the measure block with fixed
// seeds/content so every iteration does deterministic work: no network,
// no Tor, no sleeps.
//
// Skippable via the BITCHAT_SKIP_PERF_BASELINES=1 environment variable;
// runs by default.
//

import XCTest
import SwiftUI
import BitFoundation
@testable import bitchat

@MainActor
final class PerformanceBaselineTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BITCHAT_SKIP_PERF_BASELINES"] == "1",
            "Performance baselines skipped via BITCHAT_SKIP_PERF_BASELINES"
        )
    }

    override func tearDown() {
        // Drain main-queue tasks spawned by coordinators (handlePublicMessage
        // hops etc.) so they don't bleed into the next test's measure block.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        super.tearDown()
    }

    /// Reports one human-readable throughput line per benchmark so CI logs
    /// are readable without parsing XCTest's measure output. The same line is
    /// appended to the file named by `BITCHAT_PERF_LOG` (if set): under
    /// `swift test --parallel` the runner swallows stdout of passing tests,
    /// so the CI floor gate (scripts/check-perf-floors.sh) reads the file.
    private func reportThroughput(_ name: String, samples: [TimeInterval], operations: Int, unit: String) {
        guard !samples.isEmpty else { return }
        let avg = samples.reduce(0, +) / Double(samples.count)
        let opsPerSec = avg > 0 ? Double(operations) / avg : .infinity
        let line = String(
            format: "PERF[%@]: %.0f %@/sec (avg %.3f ms per pass of %d, %d passes)",
            name, opsPerSec, unit, avg * 1000, operations, samples.count
        )
        print(line)
        Self.appendToPerfLog(line)
    }

    private static var perfLogPath: String? {
        let path = ProcessInfo.processInfo.environment["BITCHAT_PERF_LOG"]
        return (path?.isEmpty ?? true) ? nil : path
    }

    /// Appends with `O_APPEND` because `swift test --parallel` may split this
    /// class across worker processes that write concurrently. The file is
    /// append-only (CI workspaces start fresh); delete it between local runs
    /// if you reuse a path.
    private static func appendToPerfLog(_ line: String) {
        guard let path = perfLogPath else { return }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array((line + "\n").utf8)
        bytes.withUnsafeBufferPointer { buffer in
            _ = write(fd, buffer.baseAddress, buffer.count)
        }
    }

    // MARK: - 1a. Nostr inbound event handling (fresh events)

    // MARK: - 1b. Nostr inbound event handling (duplicate events)

    // MARK: - 2. BLE inbound packet pipeline (decode + dedup)

    /// Binary encode/decode round trip plus `MessageDeduplicator` at
    /// realistic mesh sizes: 1000 packets with 100-300 byte payloads, each
    /// dedup-checked twice (first-seen insert, then duplicate hit) the way
    /// relayed packets arrive on multiple links.
    func testBLEInboundPacketPipeline() throws {
        var rng = SeededGenerator(seed: 0xB17C4A7)
        let baseTimestamp = UInt64(1_700_000_000_000)
        var packets: [BitchatPacket] = []
        var dedupIDs: [String] = []
        packets.reserveCapacity(1000)
        dedupIDs.reserveCapacity(1000)
        for index in 0..<1000 {
            let senderID = Data((0..<8).map { _ in UInt8.random(in: 0...255, using: &rng) })
            let payloadSize = Int.random(in: 100...300, using: &rng)
            let payload = Data((0..<payloadSize).map { _ in UInt8.random(in: 0...255, using: &rng) })
            let packet = BitchatPacket(
                type: MessageType.message.rawValue,
                senderID: senderID,
                recipientID: nil,
                timestamp: baseTimestamp + UInt64(index),
                payload: payload,
                signature: nil,
                ttl: 7
            )
            packets.append(packet)
            // Same dedup key shape BLEService uses: sender-timestamp-type.
            dedupIDs.append("\(senderID.hexEncodedString())-\(packet.timestamp)-\(packet.type)")
        }
        let deduplicator = MessageDeduplicator()
        var samples: [TimeInterval] = []

        measure {
            deduplicator.reset() // identical work every pass
            let start = Date()
            var decodedCount = 0
            var duplicateCount = 0
            for (index, packet) in packets.enumerated() {
                guard let data = packet.toBinaryData(),
                      let decoded = BitchatPacket.from(data) else { continue }
                decodedCount += 1
                _ = decoded.payload.count
                if deduplicator.isDuplicate(dedupIDs[index]) { duplicateCount += 1 }
            }
            for id in dedupIDs where deduplicator.isDuplicate(id) {
                duplicateCount += 1
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertEqual(decodedCount, packets.count)
            XCTAssertEqual(duplicateCount, packets.count)
        }

        reportThroughput("bleInbound.roundTripAndDedup", samples: samples, operations: packets.count, unit: "packets")
    }

    // MARK: - 3. GCS sync filters

    /// `GCSFilter.buildFilter` + `decodeToSortedSet` at the production gossip
    /// config (`TransportConfig.syncGCSMaxBytes` / `syncGCSTargetFpr`) with
    /// 1000 candidate packet IDs (the filter caps to its byte budget).
    func testGCSFilterBuildAndDecode() {
        var rng = SeededGenerator(seed: 0x6C5F11)
        let ids: [Data] = (0..<1000).map { _ in
            Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) })
        }
        let maxBytes = TransportConfig.syncGCSMaxBytes
        let targetFpr = TransportConfig.syncGCSTargetFpr
        let repsPerPass = 20
        var samples: [TimeInterval] = []

        measure {
            let start = Date()
            var decodedTotal = 0
            for _ in 0..<repsPerPass {
                let params = GCSFilter.buildFilter(ids: ids, maxBytes: maxBytes, targetFpr: targetFpr)
                let decoded = GCSFilter.decodeToSortedSet(p: params.p, m: params.m, data: params.data)
                decodedTotal += decoded.count
                XCTAssertLessThanOrEqual(params.data.count, maxBytes)
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertGreaterThan(decodedTotal, 0)
        }

        reportThroughput("gcs.buildAndDecode", samples: samples, operations: repsPerPass, unit: "filters")
    }

    // MARK: - 4a. Delivery status updates through the coordinator (store path)

    /// `ChatDeliveryCoordinator.updateMessageDeliveryStatus` over the
    /// `ConversationStore`'s message-ID → conversation map: 2000 public
    /// (split mesh + geohash to stay under the per-conversation cap) + 50x40
    /// private messages, 500 status updates per pass. Statuses alternate
    /// between two `delivered` timestamps so every call performs a real update
    /// (never the skip path). A sent <-> delivered alternation would now hit
    /// the store's no-downgrade guard on the delivered -> sent half.
    func testDeliveryStatusIncrementalUpdates() {
        let context = PerfDeliveryContext.makeCorpus(publicCount: 2000, peerCount: 50, messagesPerPeer: 40)
        let coordinator = ChatDeliveryCoordinator(context: context)
        let targetIDs = context.makeTargetIDs(publicTargets: 250, privateTargets: 250)
        XCTAssertEqual(targetIDs.count, 500)

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let fixedDate2 = Date(timeIntervalSince1970: 1_700_000_001)
        var toggle = false
        var samples: [TimeInterval] = []

        measure {
            toggle.toggle()
            let status: DeliveryStatus = toggle ? .delivered(to: "peer", at: fixedDate) : .delivered(to: "peer", at: fixedDate2)
            let start = Date()
            var updated = 0
            for id in targetIDs where coordinator.updateMessageDeliveryStatus(id, status: status) {
                updated += 1
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertEqual(updated, targetIDs.count)
        }

        reportThroughput("delivery.incrementalUpdate", samples: samples, operations: targetIDs.count, unit: "updates")
    }

    // MARK: - 4b. Delivery status updates against the store directly

    /// `ConversationStore.setDeliveryStatus(_:forMessageID:)` at the same
    /// scale as 4a, without the coordinator/context wrapping — the store-side
    /// cost of an ID-only delivery update (map lookup + per-conversation
    /// ID-index apply + change emission). Replaces the deleted
    /// `delivery.indexRebuild` benchmark: the positional location index and
    /// its rebuild path no longer exist; the store's ID indexes are
    /// maintained inside each mutation, so there is no rebuild to measure.
    func testDeliveryStatusStoreUpdates() {
        let context = PerfDeliveryContext.makeCorpus(publicCount: 2000, peerCount: 50, messagesPerPeer: 40)
        let store = context.store
        let targetIDs = context.makeTargetIDs(publicTargets: 250, privateTargets: 250)
        XCTAssertEqual(targetIDs.count, 500)

        // Alternate two delivered timestamps so every update is real; a
        // sent <-> delivered swing would hit the no-downgrade guard.
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let fixedDate2 = Date(timeIntervalSince1970: 1_700_000_001)
        var toggle = false
        var samples: [TimeInterval] = []

        measure {
            toggle.toggle()
            let status: DeliveryStatus = toggle ? .delivered(to: "peer", at: fixedDate) : .delivered(to: "peer", at: fixedDate2)
            let start = Date()
            var updated = 0
            for id in targetIDs where store.setDeliveryStatus(status, forMessageID: id) {
                updated += 1
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertEqual(updated, targetIDs.count)
        }

        reportThroughput("delivery.storeUpdate", samples: samples, operations: targetIDs.count, unit: "updates")
    }

    // MARK: - 5. Message formatting

    /// `MessageFormattingEngine.formatMessage` over 200 messages with
    /// mentions, hashtags, and URLs. Formatting caches per message, so each
    /// measure pass consumes a fresh pre-built batch (cache-miss path, which
    /// is the cost paid when messages first render).
    func testMessageFormatting() {
        let context = PerfFormattingContext(nickname: "carol")
        let batchCount = 16 // > XCTest's default 10 measure iterations
        let batchSize = 200
        let contents: [(String, [String]?)] = [
            ("hello mesh, anyone around tonight?", nil),
            ("@carol#a1b2 did you see this? https://example.com/threads/42", ["carol"]),
            ("checking in from the harbor #bitchat #mesh", nil),
            ("@bob#0042 ping me when you get this", ["bob#0042"]),
            ("long form update with a link https://news.example.org/articles/2026/06/mesh-networks and a tag #geohash", nil)
        ]
        let batches: [[BitchatMessage]] = (0..<batchCount).map { batch in
            (0..<batchSize).map { i in
                let (content, mentions) = contents[i % contents.count]
                return BitchatMessage(
                    id: "fmt-\(batch)-\(i)",
                    sender: "alice#a1b\(i % 10)",
                    content: content,
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                    isRelay: false,
                    senderPeerID: PeerID(str: "abcdef123456789\(i % 10)"),
                    mentions: mentions
                )
            }
        }
        var pass = 0
        var samples: [TimeInterval] = []

        measure {
            precondition(pass < batches.count, "add more pre-built batches")
            let batch = batches[pass]
            pass += 1
            let start = Date()
            var formattedCharacters = 0
            for message in batch {
                let formatted = MessageFormattingEngine.formatMessage(message, context: context, colorScheme: .light)
                formattedCharacters += formatted.characters.count
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertGreaterThan(formattedCharacters, 0)
        }

        reportThroughput("formatting.formatMessage", samples: samples, operations: batchSize, unit: "messages")
    }

    // MARK: - 6a. End-to-end private ingest pipeline (current architecture)

    /// Baseline for the full private-message ingest cycle through a real
    /// `ChatViewModel`: `handlePrivateMessage` → `ConversationStore.append`
    /// intent (ordered insert + ID-index dedup) → per-conversation publish +
    /// `changes` emission → `PrivateInboxModel` (direct store reads).
    /// Measures wall time from first ingest until the store AND the feature
    /// model both reflect every message. The peer is not mesh-active and no
    /// chat is selected, so notification/read-receipt side paths stay cold
    /// (notifications are no-ops under test anyway).
    func testPipelinePrivateIngest() {
        let messageCount = 200
        // 64-hex (stable Noise key) peer ID: skips the short-ID consolidation
        // and ephemeral-mirror paths so every pass does identical work.
        let peerID = PeerID(str: String(repeating: "ab", count: 32))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let messages: [BitchatMessage] = (0..<messageCount).map { i in
            BitchatMessage(
                id: "perf-dm-\(i)",
                sender: "perfsender",
                content: "private pipeline message \(i)",
                timestamp: base.addingTimeInterval(Double(i)),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "me",
                senderPeerID: peerID
            )
        }
        // Fresh fixture per pass so dedup scans and store syncs start from the
        // same empty state every iteration. Kept alive so weakly captured
        // coordinator Task hops stay valid.
        var keepAlive: [PerfPipelineFixture] = []
        var samples: [TimeInterval] = []

        measure {
            let fixture = PerfPipelineFixture()
            keepAlive.append(fixture)
            let start = Date()
            for message in messages {
                fixture.viewModel.handlePrivateMessage(message)
            }
            // Reads are synchronous against the single-writer store; the
            // spin covers any coordinator main-actor hops.
            let consistent = spinMainRunLoop(timeout: 10) {
                fixture.conversations.conversationsByID[.directPeer(peerID)]?.messages.count == messageCount
                    && fixture.privateInbox.messages(for: peerID).count == messageCount
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertTrue(consistent, "ConversationStore/PrivateInboxModel never converged")
            XCTAssertEqual(fixture.viewModel.privateChats[peerID]?.count, messageCount)
        }

        reportThroughput("pipeline.privateIngest", samples: samples, operations: messageCount, unit: "messages")
    }

    // MARK: - 6b. End-to-end public ingest pipeline (current architecture)

    /// Sustained batched throughput for the full public ingest cycle through a real
    /// `ChatViewModel`: `didReceivePublicMessage` (transport delegate entry,
    /// main-actor Task hop per message) → `handlePublicMessage` (rate limit,
    /// pipeline enqueue) → `PublicMessagePipeline` timer-batched flush into
    /// the `ConversationStore` (derived `ChatViewModel.messages` view;
    /// `PublicChatModel` observes the active `Conversation` directly).
    /// Measures until `messages` and the feature model reflect every message.
    /// The 1,000-message workload amortizes the unchanged default batching delay;
    /// this is not a latency measurement equivalent to the old 200-message burst.
    /// It stays below the 1,337-row timeline cap, with four messages per sender
    /// to stay under the five-token sender rate bucket.
    func testPipelinePublicIngest() {
        let messageCount = 1000
        let senderCount = 250
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        struct InboundPublic {
            let peerID: PeerID
            let nickname: String
            let content: String
            let timestamp: Date
            let messageID: String
        }
        let items: [InboundPublic] = (0..<messageCount).map { i in
            let sender = i % senderCount
            return InboundPublic(
                peerID: PeerID(str: String(format: "%016x", 0xC0DE_0000 + sender)),
                nickname: "perfpeer\(sender)",
                content: "public pipeline message \(i) from sender \(sender)",
                timestamp: base.addingTimeInterval(Double(i)),
                messageID: "perf-pub-\(i)"
            )
        }
        let expectedIDs = Set(items.map(\.messageID))
        var keepAlive: [PerfPipelineFixture] = []
        var samples: [TimeInterval] = []

        measure {
            let fixture = PerfPipelineFixture()
            keepAlive.append(fixture)
            let start = Date()
            for item in items {
                fixture.viewModel.didReceivePublicMessage(
                    from: item.peerID,
                    nickname: item.nickname,
                    content: item.content,
                    timestamp: item.timestamp,
                    messageID: item.messageID
                )
            }
            // Drain the per-message main-actor hops and the actual default
            // pipeline timer. Both views must reflect the whole synthetic corpus.
            let consistent = spinMainRunLoop(timeout: 10) {
                fixture.viewModel.messages.filter { expectedIDs.contains($0.id) }.count == messageCount
                    && fixture.publicChat.messages.filter { expectedIDs.contains($0.id) }.count == messageCount
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertTrue(consistent, "messages/PublicChatModel never converged")
            let ingested = fixture.viewModel.messages.filter { expectedIDs.contains($0.id) }
            XCTAssertEqual(ingested.count, messageCount)
            XCTAssertEqual(Set(ingested.map(\.id)), expectedIDs)
            let publicIngested = fixture.publicChat.messages.filter { expectedIDs.contains($0.id) }
            XCTAssertEqual(publicIngested.count, messageCount)
            XCTAssertEqual(Set(publicIngested.map(\.id)), expectedIDs)
        }

        reportThroughput("pipeline.publicIngest", samples: samples, operations: messageCount, unit: "messages")
    }

    /// Preserve the original 200-message default-timer scenario independently
    /// from the sustained-throughput floor. Run this actual VM fixture only in
    /// disposable CI; local validation selects the injected pipeline controls.
    func testDefaultPublicIngest200AutomaticallyConverges() {
        let messageCount = 200
        let senderCount = 50
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let fixture = PerfPipelineFixture()
        let expectedIDs = Set((0..<messageCount).map { "perf-default-pub-\($0)" })

        for i in 0..<messageCount {
            let sender = i % senderCount
            fixture.viewModel.didReceivePublicMessage(
                from: PeerID(str: String(format: "%016x", 0xC0DE_0000 + sender)),
                nickname: "perfpeer\(sender)",
                content: "public pipeline message \(i) from sender \(sender)",
                timestamp: base.addingTimeInterval(Double(i)),
                messageID: "perf-default-pub-\(i)"
            )
        }
        let consistent = spinMainRunLoop(timeout: 10) {
            fixture.viewModel.messages.filter { expectedIDs.contains($0.id) }.count == messageCount
                && fixture.publicChat.messages.filter { expectedIDs.contains($0.id) }.count == messageCount
        }
        XCTAssertTrue(consistent, "default-timer messages/PublicChatModel never converged")
        let ingested = fixture.viewModel.messages.filter { expectedIDs.contains($0.id) }
        XCTAssertEqual(ingested.count, messageCount)
        XCTAssertEqual(Set(ingested.map(\.id)), expectedIDs)
        let publicIngested = fixture.publicChat.messages.filter { expectedIDs.contains($0.id) }
        XCTAssertEqual(publicIngested.count, messageCount)
        XCTAssertEqual(Set(publicIngested.map(\.id)), expectedIDs)
    }

    // MARK: - 7. ConversationStore append (to-be architecture)

    /// Core op of the new single-source-of-truth `ConversationStore`
    /// (docs/CONVERSATION-STORE-DESIGN.md): 1000 appends into one
    /// conversation, every 10th arriving out of order so the binary-search
    /// insert path (plus suffix reindex) is part of the measured work.
    /// Includes per-message ID-index dedup and the per-conversation
    /// `@Published` array write.
    func testConversationStoreAppend() {
        let messageCount = 1000
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let messages: [BitchatMessage] = (0..<messageCount).map { i in
            // Every 10th message is "late": its timestamp predates already
            // appended messages, forcing the ordered-insert slow path.
            let offset = (i % 10 == 9) ? Double(i) - 5.5 : Double(i)
            return BitchatMessage(
                id: "perf-store-\(i)",
                sender: "perfsender",
                content: "store append message \(i)",
                timestamp: base.addingTimeInterval(offset),
                isRelay: false
            )
        }
        var samples: [TimeInterval] = []

        measure {
            let store = ConversationStore()
            let start = Date()
            for message in messages {
                store.append(message, to: .mesh)
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertEqual(store.conversation(for: .mesh).messages.count, messageCount)
        }

        reportThroughput("store.append", samples: samples, operations: messageCount, unit: "messages")
    }

    // MARK: - 7b. ConversationStore append at the retention cap

    /// Steady-state public timeline traffic after the 1337-message retention
    /// cap has been reached. Every tail append evicts the oldest row, which is
    /// the long-lived workload the cold `store.append` benchmark does not
    /// exercise.
    func testConversationStoreSteadyStateAppend() {
        let store = ConversationStore()
        let cap = TransportConfig.meshTimelineCap
        let messagesPerPass = 500
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for i in 0..<cap {
            store.append(
                BitchatMessage(
                    id: "perf-steady-seed-\(i)",
                    sender: "perfsender",
                    content: "steady-state seed \(i)",
                    timestamp: base.addingTimeInterval(Double(i)),
                    isRelay: false
                ),
                to: .mesh
            )
        }

        var pass = 0
        var samples: [TimeInterval] = []
        measure {
            let startIndex = cap + pass * messagesPerPass
            let start = Date()
            for offset in 0..<messagesPerPass {
                let i = startIndex + offset
                store.append(
                    BitchatMessage(
                        id: "perf-steady-\(i)",
                        sender: "perfsender",
                        content: "steady-state message \(i)",
                        timestamp: base.addingTimeInterval(Double(i)),
                        isRelay: false
                    ),
                    to: .mesh
                )
            }
            samples.append(Date().timeIntervalSince(start))
            pass += 1
            XCTAssertEqual(store.conversation(for: .mesh).messages.count, cap)
        }

        reportThroughput(
            "store.steadyStateAppend",
            samples: samples,
            operations: messagesPerPass,
            unit: "messages"
        )
    }

    // MARK: - 8. ConversationStore invariant audit (field observability)

    /// `ConversationStore.auditInvariants()` over a realistic 5k-message
    /// corpus (mesh + geohash + 75 private chats). The audit runs in the
    /// field on the read-receipt cleanup cadence
    /// (`ChatViewModel.auditConversationStore`), so this measures the
    /// per-audit cost that piggybacks on peer-list updates — it must stay
    /// trivially cheap relative to that cadence.
    func testConversationStoreAudit() {
        let context = PerfDeliveryContext.makeCorpus(publicCount: 2000, peerCount: 75, messagesPerPeer: 40)
        let store = context.store
        XCTAssertEqual(store.totalMessageCount, 5000)
        let repsPerPass = 20
        var samples: [TimeInterval] = []

        measure {
            let start = Date()
            var violationCount = 0
            for _ in 0..<repsPerPass {
                violationCount += store.auditInvariants().count
            }
            samples.append(Date().timeIntervalSince(start))
            XCTAssertEqual(violationCount, 0, "healthy corpus must audit clean")
        }

        reportThroughput("store.audit", samples: samples, operations: repsPerPass, unit: "audits")
    }

    /// Spins the main run loop in small slices (draining main-queue tasks and
    /// timers) until `condition` holds or `timeout` elapses.
    private func spinMainRunLoop(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        return true
    }

    // MARK: - Fixtures

}

// MARK: - Deterministic RNG

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Mock ChatNostrContext

/// Minimal `ChatNostrContext` for benchmarking the `ChatNostrCoordinator`
/// stack (`NostrInboundPipeline` in particular) without a `ChatViewModel`
/// (mirrors `ChatNostrCoordinatorContextTests`).
/// Callbacks are cheap dictionary/array operations so the measured cost is
/// the coordinator's own pipeline.
@MainActor
private final class PerfDeliveryContext: ChatDeliveryContext {
    let store = ConversationStore()
    var sentReadReceipts: Set<String> = []
    var isStartupPhase: Bool { false }
    private var publicIDs: [String] = []
    private var privateIDsByPeer: [(peerID: PeerID, messageIDs: [String])] = []

    func notifyUIChanged() {}
    func markMessageDelivered(_ messageID: String) {}
    func markMessageDelivered(_ messageID: String, from peerIDs: Set<PeerID>) {}
    func isOutgoingPrivateMessage(_ messageID: String, toAny peerIDs: Set<PeerID>) -> Bool {
        true
    }

    @discardableResult
    func setDeliveryStatus(_ status: DeliveryStatus, forMessageID messageID: String) -> Bool {
        store.setDeliveryStatus(status, forMessageID: messageID)
    }

    func setTransport(
        _ transport: MessageTransport,
        forMessageID messageID: String,
        inDirectPeerAliases peerIDs: Set<PeerID>
    ) {
        store.setTransport(transport, forMessageID: messageID, inDirectPeerAliases: peerIDs)
    }

    @discardableResult
    func setDeliveryStatus(
        _ status: DeliveryStatus,
        forMessageID messageID: String,
        inDirectPeerAliases peerIDs: Set<PeerID>
    ) -> Bool {
        store.setDeliveryStatus(
            status,
            forMessageID: messageID,
            inDirectPeerAliases: peerIDs
        )
    }

    func deliveryStatus(forMessageID messageID: String) -> DeliveryStatus? {
        store.deliveryStatus(forMessageID: messageID)
    }

    func privateMessageIDs() -> Set<String> {
        store.directMessageIDs()
    }

    func pruneSentReadReceipts(keeping validMessageIDs: Set<String>) -> Int {
        let oldCount = sentReadReceipts.count
        sentReadReceipts = sentReadReceipts.intersection(validMessageIDs)
        return oldCount - sentReadReceipts.count
    }

    /// `publicCount` public messages (split evenly between mesh and one
    /// geohash conversation so the corpus stays under the per-conversation
    /// cap) + `peerCount` x `messagesPerPeer` private messages, seeded into
    /// the store with deterministic IDs and timestamps.
    static func makeCorpus(publicCount: Int, peerCount: Int, messagesPerPeer: Int) -> PerfDeliveryContext {
        let context = PerfDeliveryContext()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let geohashID = ConversationID.geohash("u4pruyd")
        for i in 0..<publicCount {
            let message = BitchatMessage(
                id: "pub-\(i)",
                sender: "peer\(i % 20)",
                content: "public message number \(i)",
                timestamp: base.addingTimeInterval(Double(i)),
                isRelay: false
            )
            context.store.append(message, to: i % 2 == 0 ? .mesh : geohashID)
            context.publicIDs.append(message.id)
        }
        for p in 0..<peerCount {
            let peerID = PeerID(str: String(format: "%016x", 0xA000_0000 + p))
            var messageIDs: [String] = []
            for i in 0..<messagesPerPeer {
                let message = BitchatMessage(
                    id: "dm-\(p)-\(i)",
                    sender: "peer\(p)",
                    content: "private message \(i) for peer \(p)",
                    timestamp: base.addingTimeInterval(Double(i)),
                    isRelay: false,
                    isPrivate: true,
                    recipientNickname: "me",
                    senderPeerID: peerID
                )
                context.store.append(message, to: .directPeer(peerID))
                messageIDs.append(message.id)
            }
            context.privateIDsByPeer.append((peerID, messageIDs))
        }
        return context
    }

    /// Deterministic update targets spread across the corpus: `publicTargets`
    /// public IDs plus `privateTargets` private IDs.
    func makeTargetIDs(publicTargets: Int, privateTargets: Int) -> [String] {
        var targetIDs: [String] = []
        let publicStride = max(1, publicIDs.count / publicTargets)
        for i in stride(from: 0, to: publicIDs.count, by: publicStride) where targetIDs.count < publicTargets {
            targetIDs.append(publicIDs[i])
        }
        var privateCount = 0
        outer: for (_, messageIDs) in privateIDsByPeer {
            for i in stride(from: 0, to: messageIDs.count, by: 4) {
                guard privateCount < privateTargets else { break outer }
                targetIDs.append(messageIDs[i])
                privateCount += 1
            }
        }
        return targetIDs
    }
}

// MARK: - End-to-end pipeline fixture

/// A real `ChatViewModel` over `MockTransport` plus the AppRuntime-style
/// feature models (`PrivateInboxModel` / `PublicChatModel`) bound to the same
/// single-writer `ConversationStore`, so end-to-end ingest benchmarks cover
/// the full ingest-to-feature-model chain. Mirrors the construction used by
/// `ChatViewModelExtensionsTests`.
@MainActor
private final class PerfPipelineFixture {
    let viewModel: ChatViewModel
    let conversations: ConversationStore
    let privateInbox: PrivateInboxModel
    let publicChat: PublicChatModel

    init() {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
        let identityManager = MockIdentityManager(keychain)
        let transport = MockTransport()
        let conversations = ConversationStore()

        self.conversations = conversations
        self.viewModel = ChatViewModel(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: identityManager,
            transport: transport,
            conversations: conversations,
        )
        self.privateInbox = PrivateInboxModel(conversations: conversations)
        self.publicChat = PublicChatModel(conversations: conversations)
    }
}

// MARK: - Mock MessageFormattingContext

@MainActor
private final class PerfFormattingContext: MessageFormattingContext {
    let nickname: String
    init(nickname: String) { self.nickname = nickname }
    func isSelfMessage(_ message: BitchatMessage) -> Bool { false }
    func senderColor(for message: BitchatMessage, isDark: Bool) -> Color { .blue }
    func peerURL(for peerID: PeerID) -> URL? { URL(string: "bitchat://peer/\(peerID.id)") }
}
