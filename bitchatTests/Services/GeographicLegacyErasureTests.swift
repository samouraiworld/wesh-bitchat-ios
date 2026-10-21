import Foundation
import Testing
@testable import bitchat

/// Private in-memory preferences and temporary fixture files only. Erasure
/// never constructs a location service or decodes historical payloads.
@MainActor
struct GeographicLegacyErasureTests {
    private static let legacyKeys = [
        "locationChannel.selected", "locationChannel.teleportedSet",
        "locationChannel.bookmarks", "locationChannel.bookmarkNames",
        "locationChannel.bookmarkNamesSchemaVersion", "locationNotes.enabled",
        "georelay.lastFetchAt"
    ]

    @Test(arguments: GeographicLegacyErasureTests.legacyKeys)
    func legacyWipeRemovesEveryRetiredPreferenceWithoutRemovingUnrelatedState(key: String) {
        let storage = GeographyMemoryDefaults(values: seededPreferences())
        let store = RetiredGeographyStore(defaults: storage)

        #expect(store.wipe())

        #expect(storage.values[key] == nil)
        #expect(storage.values["synthetic.unrelated.preference"] as? String == "preserved")
    }

    @Test
    func preparingLegacyErasureNeverLoadsRetiredPreferencePayloads() {
        let storage = GeographyMemoryDefaults(values: seededPreferences())
        let store = RetiredGeographyStore(defaults: storage)
        #expect(storage.operations.isEmpty, "Preparing an eraser must not read preferences")

        #expect(store.wipe())

        // Record every operation, including object reads returning nil. The
        // required post-removal absence checks are distinct from payload loads.
        #expect(storage.operations == Self.legacyKeys.map { .remove($0) }
            + [.synchronize] + Self.legacyKeys.map { .object($0) })
        #expect(storage.payloadReads.isEmpty)
    }

    @Test
    func absentLegacyPreferencesAreNotCreatedOrMigratedDuringErasure() {
        let storage = GeographyMemoryDefaults()
        let store = RetiredGeographyStore(defaults: storage)

        #expect(store.wipe())

        #expect(storage.writes.isEmpty)
        #expect(storage.values.isEmpty)
    }

    @Test(arguments: ["georelays_cache.csv", "georelays_cache_v2.csv"])
    func legacyCacheWipeRemovesOnlyTheExactCacheFiles(filename: String) throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("bitchat", isDirectory: true)
        let arti = directory.appendingPathComponent("arti/state/synthetic-state")
        let neighbor = directory.appendingPathComponent("georelays_cache_unrelated.csv")
        try FileManager.default.createDirectory(at: arti.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sentinel = Data("Synthetic neighboring state must survive".utf8)
        try sentinel.write(to: arti)
        try sentinel.write(to: neighbor)
        for name in ["georelays_cache.csv", "georelays_cache_v2.csv"] {
            try Data("Synthetic legacy CSV, deliberately invalid".utf8)
                .write(to: directory.appendingPathComponent(name))
        }
        let store = RetiredGeographyStore(defaults: GeographyMemoryDefaults(), applicationSupportURL: root)

        #expect(store.wipe())

        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path))
        #expect(try Data(contentsOf: arti) == sentinel)
        #expect(try Data(contentsOf: neighbor) == sentinel)
    }

    @Test
    func absentLegacyCacheDirectoryRemainsAbsent() {
        let root = temporaryRoot()
        let store = RetiredGeographyStore(defaults: GeographyMemoryDefaults(), applicationSupportURL: root)

        #expect(store.wipe())

        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test(arguments: [false, true])
    func preferenceFailureReportsFalseAndStillAttemptsEveryIndependentCleanup(refuseRemoval: Bool) {
        let storage = GeographyMemoryDefaults(values: seededPreferences())
        storage.refuseRemoval = refuseRemoval
        storage.flushSucceeds = refuseRemoval
        let files = GeographyErasureFiles()
        let store = RetiredGeographyStore(defaults: storage, applicationSupportURL: temporaryRoot(), fileManager: files)

        #expect(!store.wipe())

        #expect(storage.operations.filter { if case .remove = $0 { return true }; return false }
            == Self.legacyKeys.map { .remove($0) })
        #expect(storage.operations.filter { if case .object = $0 { return true }; return false }
            == Self.legacyKeys.map { .object($0) })
        #expect(files.removalAttempts == ["georelays_cache.csv", "georelays_cache_v2.csv"])
        #expect(storage.writes.isEmpty)
    }

    @Test(arguments: ["unlink", "acknowledgedButPresent", "unknownAbsence"])
    func cacheFailureReportsFalseAndDoesNotSkipPreferencesOrOtherCache(failure: String) {
        let storage = GeographyMemoryDefaults(values: seededPreferences())
        let files = GeographyErasureFiles()
        files.failure = GeographyErasureFiles.Failure(rawValue: failure)
        let store = RetiredGeographyStore(defaults: storage, applicationSupportURL: temporaryRoot(), fileManager: files)

        #expect(!store.wipe())

        #expect(files.removalAttempts == ["georelays_cache.csv", "georelays_cache_v2.csv"])
        #expect(Self.legacyKeys.allSatisfy { storage.values[$0] == nil })
        #expect(storage.values["synthetic.unrelated.preference"] as? String == "preserved")
        files.failure = nil
        #expect(store.wipe(), "A subsequent verified cleanup can complete")
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func seededPreferences() -> [String: Any] {
        var result = Dictionary(uniqueKeysWithValues: Self.legacyKeys.map {
            ($0, Data("Synthetic retired preference bytes".utf8) as Any)
        })
        result["locationChannel.bookmarkNamesSchemaVersion"] = 1
        result["locationNotes.enabled"] = true
        result["georelay.lastFetchAt"] = Date(timeIntervalSince1970: 1_700_000_000)
        result["synthetic.unrelated.preference"] = "preserved"
        return result
    }
}

private final class GeographyMemoryDefaults: UserDefaults, @unchecked Sendable {
    enum Operation: Equatable {
        case data(String), integer(String), object(String), remove(String), synchronize
    }
    private(set) var values: [String: Any]
    private(set) var operations: [Operation] = []
    private(set) var writes: [String] = []
    var refuseRemoval = false
    var flushSucceeds = true
    var payloadReads: [Operation] {
        operations.filter { if case .data = $0 { return true }; if case .integer = $0 { return true }; return false }
    }

    init(values: [String: Any] = [:]) {
        self.values = values
        super.init(suiteName: "GeographicLegacyErasureTests-\(UUID().uuidString)")!
    }
    override func data(forKey key: String) -> Data? { operations.append(.data(key)); return values[key] as? Data }
    override func integer(forKey key: String) -> Int { operations.append(.integer(key)); return values[key] as? Int ?? 0 }
    override func object(forKey key: String) -> Any? { operations.append(.object(key)); return values[key] }
    override func set(_ value: Any?, forKey key: String) { writes.append(key); values[key] = value }
    override func set(_ value: Int, forKey key: String) { writes.append(key); values[key] = value }
    override func removeObject(forKey key: String) {
        operations.append(.remove(key))
        if !refuseRemoval { values.removeValue(forKey: key) }
    }
    override func synchronize() -> Bool { operations.append(.synchronize); return flushSucceeds }
}

private final class GeographyErasureFiles: FileManager, @unchecked Sendable {
    enum Failure: String { case unlink, acknowledgedButPresent, unknownAbsence }
    var failure: Failure?
    private(set) var removalAttempts: [String] = []

    override func removeItem(at URL: URL) throws {
        removalAttempts.append(URL.lastPathComponent)
        if URL.lastPathComponent == "georelays_cache.csv", failure == .unlink {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if path.hasSuffix("/georelays_cache.csv") {
            if failure == .acknowledgedButPresent { return [.type: FileAttributeType.typeRegular] }
            if failure == .unknownAbsence { throw CocoaError(.fileReadNoPermission) }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
