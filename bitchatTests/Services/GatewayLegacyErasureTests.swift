import Foundation
import BitFoundation
import Testing
@testable import bitchat

struct GatewayLegacyErasureTests {
    @Test
    func legacyWipeRemovesOnlyBridgeRecordAndNeverRecreatesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("courier/bridge-drop-dedup.json")
        let ordinary = root.appendingPathComponent("courier/envelopes.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacyBytes = Data("Synthetic retired record, deliberately invalid JSON".utf8)
        let ordinaryBytes = Data("Synthetic ordinary courier neighbor".utf8)
        try legacyBytes.write(to: legacy)
        try ordinaryBytes.write(to: ordinary)
        let store = RetiredBridgeDropStore(fileURL: legacy)

        #expect(try Data(contentsOf: legacy) == legacyBytes)
        #expect(store.wipe())
        #expect(store.wipe())
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try Data(contentsOf: ordinary) == ordinaryBytes)
    }

    @Test
    func absentLegacyDirectoryRemainsAbsent() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = RetiredBridgeDropStore(fileURL: root.appendingPathComponent("courier/bridge-drop-dedup.json"))
        #expect(store.wipe())
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test
    func refusedLegacyRemovalCannotReportSuccessfulPanicWipe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("courier/bridge-drop-dedup.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("Synthetic retained legacy record".utf8)
        try bytes.write(to: legacy)
        let store = RetiredBridgeDropStore(fileURL: legacy, wipeFileManager: RefusingGatewayFileManager())

        #expect(!store.wipe())
        #expect(try Data(contentsOf: legacy) == bytes)
    }

    @Test
    func ordinaryCourierFilesStillLoadWithTheRetiredBridgeCooldownField() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("courier/envelopes.json")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Data(repeating: 0xB0, count: 32)
        let envelope = CourierEnvelope(recipientTag: CourierEnvelope.recipientTag(
            noiseStaticKey: key, epochDay: CourierEnvelope.epochDay(for: now)),
            expiry: UInt64(now.addingTimeInterval(3600).timeIntervalSince1970 * 1000),
            ciphertext: Data(repeating: 0xA5, count: 96))
        let writer = CourierStore(fileURL: file, now: { now })
        #expect(writer.deposit(envelope, from: Data(repeating: 0xC3, count: 32)))
        // A successful deposit persists synchronously; append the retired
        // optional JSON field to the synthetic legacy file.
        var records = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        try #require(records.count == 1)
        records[0]["lastBridgePublishAt"] = now.timeIntervalSinceReferenceDate
        try JSONSerialization.data(withJSONObject: records).write(to: file)

        let reader = CourierStore(fileURL: file, now: { now })
        #expect(reader.takeEnvelopes(for: key) == [envelope])
    }
}

private final class RefusingGatewayFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at url: URL) throws { throw CocoaError(.fileWriteNoPermission) }
}
