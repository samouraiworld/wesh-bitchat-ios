import Foundation
import Testing
@testable import bitchat

/// Exercises the same preflight and retry used before transport admission,
/// with dictionary-only preferences and owned synthetic files.
@MainActor
struct GeographyStartupPreflightTests {
    @Test
    func ordinaryLaunchErasesAllLegacyGeographyWithoutTouchingNeighboringState() throws {
        let fixture = try GeographyStartupFixture()
        defer { fixture.removeFiles() }
        var markerReads = 0
        var sightingsCalls = 0
        let decision = PanicStartupDecision.preflight(checkPending: {
            markerReads += 1
            return false
        }, wipeSightings: {
            sightingsCalls += 1
            return true
        }, wipeGeography: fixture.erase)

        #expect(markerReads == 1)
        #expect(sightingsCalls == 1)
        #expect(fixture.eraseCalls == 1)
        fixture.expectErased()
        try fixture.expectNeighborsPreserved()
        #expect(!decision.suspendTransport)
        #expect(!decision.blockOrdinaryAdmission)
        #expect(!decision.replayPanic)
    }

    @Test(arguments: [false, true])
    func actualGeographyFailureBlocksOrdinaryAdmissionWithoutAuthorizingPanic(stickyPreference: Bool) throws {
        let fixture = try GeographyStartupFixture()
        defer { fixture.removeFiles() }
        fixture.defaults.flushSucceeds = stickyPreference
        fixture.defaults.refuseRemoval = stickyPreference
        var sightingsCalls = 0

        let decision = PanicStartupDecision.preflight(checkPending: { false }, wipeSightings: {
            sightingsCalls += 1
            return true
        }, wipeGeography: fixture.erase)

        #expect(sightingsCalls == 1)
        #expect(fixture.eraseCalls == 1)
        #expect(decision.suspendTransport)
        #expect(decision.blockOrdinaryAdmission)
        #expect(!decision.replayPanic)
        try fixture.expectNeighborsPreserved()
    }

    @Test
    func sightingsFailureStillAttemptsActualGeographyCleanup() throws {
        let fixture = try GeographyStartupFixture()
        defer { fixture.removeFiles() }
        var sightingsCalls = 0

        let decision = PanicStartupDecision.preflight(checkPending: { false }, wipeSightings: {
            sightingsCalls += 1
            return false
        }, wipeGeography: fixture.erase)

        #expect(sightingsCalls == 1)
        #expect(fixture.eraseCalls == 1)
        fixture.expectErased()
        #expect(decision.suspendTransport)
        #expect(decision.blockOrdinaryAdmission)
        #expect(!decision.replayPanic)
    }

    @Test
    func ordinaryRetryRechecksBothStoresAndStaysBlockedUntilGeographyConfirms() throws {
        let fixture = try GeographyStartupFixture()
        defer { fixture.removeFiles() }
        fixture.defaults.flushSucceeds = false
        var markerReads = 0
        var sightingsCalls = 0
        let checkPending = { markerReads += 1; return false }
        let wipeSightings = { sightingsCalls += 1; return true }

        let failed = PanicStartupDecision.retry(checkPending: checkPending,
            wipeSightings: wipeSightings, wipeGeography: fixture.erase)

        #expect(failed.suspendTransport)
        #expect(failed.blockOrdinaryAdmission)
        #expect(!failed.replayPanic)
        fixture.defaults.flushSucceeds = true

        let confirmed = PanicStartupDecision.retry(checkPending: checkPending,
            wipeSightings: wipeSightings, wipeGeography: fixture.erase)

        #expect(!confirmed.suspendTransport)
        #expect(!confirmed.blockOrdinaryAdmission)
        #expect(!confirmed.replayPanic)
        #expect(markerReads == 2)
        #expect(sightingsCalls == 2)
        #expect(fixture.eraseCalls == 2)
        fixture.expectErased()
        try fixture.expectNeighborsPreserved()
    }

    @Test
    func ordinaryRetryCannotSkipGeographyBecauseSightingsCleanupFailed() throws {
        let fixture = try GeographyStartupFixture()
        defer { fixture.removeFiles() }
        var sightingsCalls = 0

        let decision = PanicStartupDecision.retry(checkPending: { false }, wipeSightings: {
            sightingsCalls += 1
            return false
        }, wipeGeography: fixture.erase)

        #expect(sightingsCalls == 1)
        #expect(fixture.eraseCalls == 1)
        fixture.expectErased()
        #expect(decision.blockOrdinaryAdmission)
        #expect(!decision.replayPanic)
    }

    @Test(arguments: [false, true])
    func pendingOrUnreadableMarkerStillRequiresFullRecoveryOnStartupAndRetry(unreadable: Bool) {
        var markerReads = 0
        let checkPending = {
            markerReads += 1
            if unreadable { throw MarkerFailure.unavailable }
            return true
        }
        let initial = PanicStartupDecision.preflight(checkPending: checkPending,
            wipeSightings: { true }, wipeGeography: { true })
        #expect(initial.replayPanic)
        #expect(initial.suspendTransport)
        #expect(markerReads == 1)

        let retry = PanicStartupDecision.retry(checkPending: checkPending,
            wipeSightings: { true }, wipeGeography: { true })
        #expect(retry.replayPanic)
        #expect(retry.suspendTransport)
        #expect(markerReads == 2)
    }

    @Test
    func absentLegacyStateCreatesNoPreferencesOrDirectories() {
        let defaults = GeographyStartupDefaults(values: [:])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RetiredGeographyStore(defaults: defaults, applicationSupportURL: root)

        let decision = PanicStartupDecision.preflight(checkPending: { false },
            wipeSightings: { true }, wipeGeography: store.wipe)

        #expect(!decision.suspendTransport)
        #expect(defaults.values.isEmpty)
        #expect(defaults.writes.isEmpty)
        #expect(defaults.payloadReads.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    private enum MarkerFailure: Error { case unavailable }
}

@MainActor
private final class GeographyStartupFixture {
    static let keys = [
        "locationChannel.selected", "locationChannel.teleportedSet",
        "locationChannel.bookmarks", "locationChannel.bookmarkNames",
        "locationChannel.bookmarkNamesSchemaVersion", "locationNotes.enabled",
        "georelay.lastFetchAt"
    ]
    private static let cacheNames = ["georelays_cache.csv", "georelays_cache_v2.csv"]
    private static let sentinel = Data("Synthetic neighboring state".utf8)
    let defaults: GeographyStartupDefaults
    private let root: URL
    private let directory: URL
    private let store: RetiredGeographyStore
    private(set) var eraseCalls = 0

    init() throws {
        let values = Dictionary(uniqueKeysWithValues: Self.keys.map {
            ($0, Data("Synthetic invalid legacy bytes".utf8) as Any)
        }).merging(["synthetic.unrelated.preference": "preserved"]) { first, _ in first }
        defaults = GeographyStartupDefaults(values: values)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        directory = root.appendingPathComponent("bitchat", isDirectory: true)
        store = RetiredGeographyStore(defaults: defaults, applicationSupportURL: root)
        do {
            let arti = directory.appendingPathComponent("arti/state", isDirectory: true)
            try FileManager.default.createDirectory(at: arti, withIntermediateDirectories: true)
            try Self.sentinel.write(to: arti.appendingPathComponent("synthetic-state"))
            try Self.sentinel.write(to: directory.appendingPathComponent("courier-synthetic.bin"))
            try Self.sentinel.write(to: directory.appendingPathComponent("georelays_cache_unrelated.csv"))
            for name in Self.cacheNames {
                try Data("Synthetic invalid legacy CSV".utf8).write(to: directory.appendingPathComponent(name))
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func erase() -> Bool { eraseCalls += 1; return store.wipe() }

    func expectErased() {
        for key in Self.keys { #expect(defaults.values[key] == nil) }
        for name in Self.cacheNames {
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
        }
        #expect(defaults.payloadReads.isEmpty)
        #expect(defaults.writes.isEmpty)
    }

    func expectNeighborsPreserved() throws {
        #expect(defaults.values["synthetic.unrelated.preference"] as? String == "preserved")
        for relative in ["arti/state/synthetic-state", "courier-synthetic.bin", "georelays_cache_unrelated.csv"] {
            #expect(try Data(contentsOf: directory.appendingPathComponent(relative)) == Self.sentinel)
        }
    }

    func removeFiles() { try? FileManager.default.removeItem(at: root) }
}

/// Every payload operation stays inside this dictionary, never a real domain.
private final class GeographyStartupDefaults: UserDefaults, @unchecked Sendable {
    private(set) var values: [String: Any]
    private(set) var payloadReads: [String] = []
    private(set) var writes: [String] = []
    var refuseRemoval = false
    var flushSucceeds = true

    init(values: [String: Any]) {
        self.values = values
        super.init(suiteName: "SyntheticGeographyStartup-\(UUID().uuidString)")!
    }

    override func removeObject(forKey key: String) {
        if !refuseRemoval { values.removeValue(forKey: key) }
    }
    override func synchronize() -> Bool { flushSucceeds }
    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { payloadReads.append(key); return values[key] as? Data }
    override func string(forKey key: String) -> String? { payloadReads.append(key); return values[key] as? String }
    override func array(forKey key: String) -> [Any]? { payloadReads.append(key); return values[key] as? [Any] }
    override func integer(forKey key: String) -> Int { payloadReads.append(key); return values[key] as? Int ?? 0 }
    override func set(_ value: Any?, forKey key: String) { writes.append(key); values[key] = value }
    override func set(_ value: Int, forKey key: String) { writes.append(key); values[key] = value }
}
