import Foundation
import Testing
@testable import bitchat

/// Real retired-store erasers, dictionary-only preferences and owned fixture
/// files exercise the production preflight without an application graph.
@MainActor
struct RetiredStorageStartupTests {
    enum Failure: String, CaseIterable {
        case sharedFlush, sharedSticky, sharedLock, board, bridge
    }

    @Test
    func ordinaryStartupPurgesOnlyTheThreeRetiredOwners() throws {
        let fixture = try RetiredStorageFixture()
        defer { fixture.removeFiles() }

        let decision = fixture.decision()

        #expect(!decision.suspendTransport)
        #expect(!decision.blockOrdinaryAdmission)
        #expect(!decision.replayPanic)
        #expect(fixture.attempts == RetiredStorageFixture.owners)
        fixture.expectErased()
        try fixture.expectNeighborsPreserved()
    }

    @Test(arguments: Failure.allCases)
    func eachActualCleanupFailureBlocksOrdinaryAdmissionWithoutAuthorizingPanic(failure: Failure) throws {
        let fixture = try RetiredStorageFixture(failure: failure)
        defer { fixture.removeFiles() }

        let decision = fixture.decision()

        #expect(decision.suspendTransport)
        #expect(decision.blockOrdinaryAdmission)
        #expect(!decision.replayPanic)
        #expect(fixture.attempts == RetiredStorageFixture.owners)
        try fixture.expectNeighborsPreserved()
    }

    @Test(arguments: ["sightings", "geography", "sharedContent", "board", "bridge"])
    func allFiveIndependentOwnersAreAttemptedEvenWhenOneFails(failedOwner: String) {
        var attempts: [String] = []
        func cleanup(_ owner: String) -> Bool {
            attempts.append(owner)
            return owner != failedOwner
        }

        let decision = PanicStartupDecision.preflight(checkPending: { false },
            wipeSightings: { cleanup("sightings") }, wipeGeography: { cleanup("geography") },
            wipeSharedContent: { cleanup("sharedContent") }, wipeBoard: { cleanup("board") },
            wipeBridge: { cleanup("bridge") })

        #expect(attempts == RetiredStorageFixture.owners)
        #expect(decision.suspendTransport)
        #expect(decision.blockOrdinaryAdmission)
        #expect(!decision.replayPanic)
    }

    @Test(arguments: Failure.allCases)
    func explicitRetryRequiresEveryRetiredStoreToConfirmBeforeReopening(failure: Failure) throws {
        let fixture = try RetiredStorageFixture(failure: failure)
        defer { fixture.removeFiles() }
        var markerReads = 0
        let marker = { markerReads += 1; return false }

        let failed = fixture.decision(retry: true, checkPending: marker)

        #expect(failed.suspendTransport)
        #expect(failed.blockOrdinaryAdmission)
        #expect(!failed.replayPanic)
        try fixture.allowCleanupRetry()

        let confirmed = fixture.decision(retry: true, checkPending: marker)

        #expect(!confirmed.suspendTransport)
        #expect(!confirmed.blockOrdinaryAdmission)
        #expect(!confirmed.replayPanic)
        #expect(markerReads == 2)
        #expect(fixture.attempts == RetiredStorageFixture.owners + RetiredStorageFixture.owners)
        fixture.expectErased()
        try fixture.expectNeighborsPreserved()
    }

    @Test(arguments: [false, true])
    func pendingOrUnreadableMarkerStillRequiresExplicitFullRecovery(unreadable: Bool) throws {
        let fixture = try RetiredStorageFixture()
        defer { fixture.removeFiles() }
        var markerReads = 0
        let marker = {
            markerReads += 1
            if unreadable { throw MarkerFailure.unavailable }
            return true
        }

        let initial = fixture.decision(checkPending: marker)
        #expect(initial.replayPanic)
        #expect(initial.suspendTransport)
        #expect(markerReads == 1)
        let retry = fixture.decision(retry: true, checkPending: marker)
        #expect(retry.replayPanic)
        #expect(retry.suspendTransport)
        #expect(markerReads == 2)
    }

    @Test
    func absentLegacyPayloadsRemainAbsentWithoutCreatingBoardOrCourierDirectories() throws {
        let fixture = try RetiredStorageFixture(seedLegacy: false)
        defer { fixture.removeFiles() }

        let decision = fixture.decision()

        #expect(!decision.suspendTransport)
        fixture.expectErased()
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("board").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("courier").path))
        #expect(fixture.defaults.writes.isEmpty)
        // The shared eraser may create its lock file even when all payloads
        // are already absent. The lock is not a retired payload or import.
    }

    private enum MarkerFailure: Error { case unavailable }
}

@MainActor
private final class RetiredStorageFixture {
    static let owners = ["sightings", "geography", "sharedContent", "board", "bridge"]
    static let sharedKeys = ["sharedContentEnvelopeV1", "sharedContent", "sharedContentType", "sharedContentDate"]
    private static let bytes = Data("Synthetic invalid retired payload".utf8)
    private static let neighborBytes = Data("Synthetic preserved neighbor".utf8)
    let root: URL
    let defaults: RetiredStartupDefaults
    private let lockURL: URL
    private let files: RetiredStartupFiles
    private let shared: SharedContentStore
    private let board: RetiredBoardStore
    private let bridge: RetiredBridgeDropStore
    private(set) var attempts: [String] = []

    init(failure: RetiredStorageStartupTests.Failure? = nil, seedLegacy: Bool = true) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.root = root
        let values = seedLegacy ? Dictionary(uniqueKeysWithValues: Self.sharedKeys.map { ($0, Self.bytes as Any) }) : [:]
        defaults = RetiredStartupDefaults(values: values.merging(["synthetic.unrelated.preference": "preserved"]) { first, _ in first })
        files = RetiredStartupFiles()
        lockURL = (failure == .sharedLock ? root.appendingPathComponent("missing-lock-parent") : root)
            .appendingPathComponent("handoff.lock")
        shared = SharedContentStore(defaults: defaults, lockURL: lockURL)
        board = RetiredBoardStore(fileURL: root.appendingPathComponent("board/posts.json"), wipeFileManager: files)
        bridge = RetiredBridgeDropStore(fileURL: root.appendingPathComponent("courier/bridge-drop-dedup.json"),
                                        wipeFileManager: files)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if seedLegacy {
                for name in ["board/posts.json", "courier/bridge-drop-dedup.json"] {
                    let url = root.appendingPathComponent(name)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.bytes.write(to: url)
                }
                for name in ["board/unrelated.json", "courier/envelopes.json", "bitchat/arti/state/synthetic-state"] {
                    let url = root.appendingPathComponent(name)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.neighborBytes.write(to: url)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        if failure == .sharedFlush { defaults.flushResults = [true, false, true] }
        if failure == .sharedSticky { defaults.stickyKeys = [Self.sharedKeys[0]] }
        if failure == .board { files.refusedName = "posts.json" }
        if failure == .bridge { files.refusedName = "bridge-drop-dedup.json" }
    }

    func decision(retry: Bool = false, checkPending: () throws -> Bool = { false }) -> PanicStartupDecision {
        let sightings = { self.attempts.append("sightings"); return true }
        let geography = { self.attempts.append("geography"); return true }
        let sharedContent = { self.attempts.append("sharedContent"); return self.shared.discardAll() }
        let board = { self.attempts.append("board"); return self.board.wipe() }
        let bridge = { self.attempts.append("bridge"); return self.bridge.wipe() }
        if retry {
            return PanicStartupDecision.retry(checkPending: checkPending,
                wipeSightings: sightings, wipeGeography: geography, wipeSharedContent: sharedContent,
                wipeBoard: board, wipeBridge: bridge)
        }
        return PanicStartupDecision.preflight(checkPending: checkPending,
            wipeSightings: sightings, wipeGeography: geography, wipeSharedContent: sharedContent,
            wipeBoard: board, wipeBridge: bridge)
    }

    func allowCleanupRetry() throws {
        defaults.flushResults = []
        defaults.stickyKeys = []
        files.refusedName = nil
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func expectErased() {
        for key in Self.sharedKeys { #expect(defaults.values[key] == nil) }
        for name in ["board/posts.json", "courier/bridge-drop-dedup.json"] {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
        #expect(defaults.typedPayloadReads.isEmpty)
        #expect(defaults.values["synthetic.unrelated.preference"] as? String == "preserved")
    }

    func expectNeighborsPreserved() throws {
        #expect(defaults.values["synthetic.unrelated.preference"] as? String == "preserved")
        for name in ["board/unrelated.json", "courier/envelopes.json", "bitchat/arti/state/synthetic-state"] {
            #expect(try Data(contentsOf: root.appendingPathComponent(name)) == Self.neighborBytes)
        }
        #expect(defaults.typedPayloadReads.isEmpty)
    }

    func removeFiles() { try? FileManager.default.removeItem(at: root) }
}

private final class RetiredStartupDefaults: UserDefaults, @unchecked Sendable {
    private(set) var values: [String: Any]
    private(set) var typedPayloadReads: [String] = []
    private(set) var writes: [String] = []
    var stickyKeys: Set<String> = []
    var flushResults: [Bool] = []

    init(values: [String: Any]) {
        self.values = values
        super.init(suiteName: "SyntheticRetiredStorageStartup-\(UUID().uuidString)")!
    }
    override func object(forKey key: String) -> Any? { values[key] }
    override func removeObject(forKey key: String) { if !stickyKeys.contains(key) { values.removeValue(forKey: key) } }
    override func synchronize() -> Bool { flushResults.isEmpty ? true : flushResults.removeFirst() }
    override func set(_ value: Any?, forKey key: String) { writes.append(key); values[key] = value }
    override func data(forKey key: String) -> Data? { typedPayloadReads.append(key); return values[key] as? Data }
    override func string(forKey key: String) -> String? { typedPayloadReads.append(key); return values[key] as? String }
    override func array(forKey key: String) -> [Any]? { typedPayloadReads.append(key); return values[key] as? [Any] }
}

private final class RetiredStartupFiles: FileManager, @unchecked Sendable {
    var refusedName: String?
    override func removeItem(at url: URL) throws {
        if url.lastPathComponent == refusedName { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: url)
    }
}
