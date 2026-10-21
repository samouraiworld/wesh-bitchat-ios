// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

import Foundation
import Testing
@testable import bitchat

struct RetiredSightingsStoreTests {
    private static let keys = [
        "meshSightings.dayKey", "meshSightings.salt", "meshSightings.hashes", "meshSightings.lastSeenAt"
    ]
    private static let sentinel = "synthetic.unrelated.preference"

    private func seededDefaults() -> SightingsMemoryDefaults {
        var values = Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, Data("Synthetic retired bytes".utf8) as Any) })
        values[Self.sentinel] = "preserved"
        return SightingsMemoryDefaults(values: values)
    }

    private var completeLedger: [SightingsMemoryDefaults.Operation] {
        Self.keys.map { .remove($0) } + [.flush] + Self.keys.map { .presence($0) }
    }

    @Test func initializationDoesNotReadOrCreateEncounterPayload() {
        let defaults = seededDefaults()
        _ = RetiredSightingsStore(defaults: defaults)
        #expect(defaults.operations.isEmpty)
        #expect(Set(defaults.values.keys) == Set(Self.keys + [Self.sentinel]))
    }

    @Test func removalTargetsOnlyTheFourLegacyKeysAndPreservesUnrelatedPreferences() {
        let defaults = seededDefaults()
        #expect(RetiredSightingsStore(defaults: defaults).wipe())
        #expect(Set(defaults.values.keys) == [Self.sentinel])
        #expect(defaults.values[Self.sentinel] as? String == "preserved")
        #expect(defaults.removals == Self.keys)
        #expect(defaults.payloadReads.isEmpty)
        #expect(defaults.writes.isEmpty)
    }

    @Test func successRequiresFlushThenAnAbsenceReadForEveryKey() {
        let defaults = seededDefaults()
        #expect(RetiredSightingsStore(defaults: defaults).wipe())
        #expect(defaults.operations == completeLedger)
    }

    @Test func failedFlushRejectsCleanupButStillChecksEveryKey() {
        let defaults = seededDefaults()
        defaults.flushSucceeds = false
        #expect(!RetiredSightingsStore(defaults: defaults).wipe())
        #expect(defaults.operations == completeLedger)
        #expect(defaults.values[Self.sentinel] as? String == "preserved")
    }

    @Test func eachStickyLegacyKeyRejectsCleanupWithoutShortCircuitingOtherAttempts() {
        for stickyKey in Self.keys {
            let defaults = seededDefaults()
            defaults.stickyKeys = [stickyKey]
            #expect(!RetiredSightingsStore(defaults: defaults).wipe())
            #expect(defaults.operations == completeLedger)
            #expect(Set(defaults.values.keys) == [stickyKey, Self.sentinel])
            #expect(defaults.payloadReads.isEmpty)
            #expect(defaults.writes.isEmpty)
        }
    }

    @Test func removingAlreadyAbsentHistoryCreatesNothingAndIsIdempotent() {
        let defaults = SightingsMemoryDefaults(values: [Self.sentinel: "preserved"])
        let store = RetiredSightingsStore(defaults: defaults)
        #expect(store.wipe())
        #expect(store.wipe())
        #expect(Set(defaults.values.keys) == [Self.sentinel])
        #expect(defaults.payloadReads.isEmpty)
        #expect(defaults.writes.isEmpty)
    }

    @Test func anActualFailedEraseCannotCompleteTheInjectedGlobalMarker() throws {
        let defaults = seededDefaults()
        defaults.flushSucceeds = false
        var pending = true
        var completions = 0
        let operations = PanicRecoveryOperations(isPending: { pending }, begin: {
            PanicRecoveryIntent(fileMarkerEstablished: true, externalMarkerEstablished: false)
        }, wipeMedia: { _ in }, complete: {
            completions += 1
            pending = false
        })

        let erased = RetiredSightingsStore(defaults: defaults).wipe()
        #expect(try !operations.completeIfConfirmed(existingStoreResults: [true], legacySightingsConfirmed: erased))
        #expect(try operations.isPending())
        #expect(completions == 0)
    }
}

/// All payload lives in this dictionary; no backing-domain values are read.
private final class SightingsMemoryDefaults: UserDefaults, @unchecked Sendable {
    enum Operation: Equatable {
        case remove(String), flush, presence(String), payload(String), write(String)
    }
    private(set) var values: [String: Any]
    private(set) var operations: [Operation] = []
    var stickyKeys: Set<String> = []
    var flushSucceeds = true

    init(values: [String: Any]) {
        self.values = values
        super.init(suiteName: "SyntheticSightings-\(UUID().uuidString)")!
    }

    var removals: [String] { operations.compactMap { if case let .remove(key) = $0 { return key }; return nil } }
    var payloadReads: [Operation] { operations.filter { if case .payload = $0 { return true }; return false } }
    var writes: [Operation] { operations.filter { if case .write = $0 { return true }; return false } }

    override func removeObject(forKey key: String) {
        operations.append(.remove(key))
        if !stickyKeys.contains(key) { values.removeValue(forKey: key) }
    }
    override func synchronize() -> Bool {
        operations.append(.flush)
        return flushSucceeds
    }
    override func object(forKey key: String) -> Any? {
        operations.append(.presence(key))
        return values[key]
    }
    override func data(forKey key: String) -> Data? { operations.append(.payload(key)); return values[key] as? Data }
    override func string(forKey key: String) -> String? { operations.append(.payload(key)); return values[key] as? String }
    override func stringArray(forKey key: String) -> [String]? { operations.append(.payload(key)); return values[key] as? [String] }
    override func array(forKey key: String) -> [Any]? { operations.append(.payload(key)); return values[key] as? [Any] }
    override func set(_ value: Any?, forKey key: String) { operations.append(.write(key)); values[key] = value }
}
