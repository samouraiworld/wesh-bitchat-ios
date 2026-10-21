import Foundation
import Testing
@testable import bitchat

/// Wesh has no media, but a build from before its removal may have left
/// images, voice notes and files under `Application Support/files`. Panic
/// still deletes them, and fails closed when it cannot.
struct PanicRecoveryFileStoreTests {
    private final class Root {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("panic-legacy-media-\(UUID().uuidString)", isDirectory: true)
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    /// Refuses every deletion, like a protected or permission-denied tree.
    private final class RefusingFileManager: FileManager {
        override func removeItem(at URL: URL) throws {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private enum MarkerFailure: Error { case unavailable }

    /// The trees an older build wrote: received and sent media, plus the
    /// private-media receipt ledger.
    private func seedLegacyMedia(in root: URL) throws -> [URL] {
        let files = [
            "files/images/incoming/photo.jpg",
            "files/images/outgoing/img_1.jpg",
            "files/voicenotes/incoming/voice_1.m4a",
            "files/voicenotes/outgoing/voice_2.m4a",
            "files/files/incoming/doc.pdf",
            "files/.private-media-receipts/media-00112233445566778899aabbccddeeff.json"
        ].map { root.appendingPathComponent($0) }
        for url in files {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("old".utf8).write(to: url)
        }
        return files
    }

    @Test func wipeRemovesTheWholeLegacyMediaTreeAndRecreatesNothing() throws {
        let root = Root()
        let seeded = try seedLegacyMedia(in: root.url)
        let store = PanicRecoveryFileStore(baseDirectory: root.url)

        try store.wipeLegacyMedia()

        #expect(seeded.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("files").path))
        // Nothing to delete is success too.
        try store.wipeLegacyMedia()
    }

    @Test func wipeFailsClosedWhenTheTreeCannotBeRemoved() throws {
        let root = Root()
        let seeded = try seedLegacyMedia(in: root.url)
        let store = PanicRecoveryFileStore(fileManager: RefusingFileManager(), baseDirectory: root.url)

        #expect(throws: (any Error).self) { try store.wipeLegacyMedia(hasDurablePendingMarker: true) }
        #expect(throws: (any Error).self) { try store.removeLegacyMedia() }
        #expect(seeded.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        // The whole panic transaction then keeps its recovery marker.
        let suite = "wesh.panic.legacy-media.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let operations = PanicRecoveryOperations.live(fileStore: store, defaults: defaults, wipeDrafts: {})
        let intent = operations.begin()
        #expect(throws: (any Error).self) { try operations.wipeMedia(intent) }
        #expect(try operations.isPending())
    }

    @Test func wipeAttemptsDeletionWhenMarkerPersistenceFails() throws {
        let root = Root()
        let seeded = try seedLegacyMedia(in: root.url)
        let store = PanicRecoveryFileStore(
            baseDirectory: root.url,
            panicMarkerWriter: { _, _ in throw MarkerFailure.unavailable }
        )

        // With no durable marker anywhere the wipe reports failure, but only
        // after it has deleted the media.
        #expect(throws: (any Error).self) { try store.wipeLegacyMedia(hasDurablePendingMarker: false) }
        #expect(seeded.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })

        // The external marker alone lets the same wipe commit.
        _ = try seedLegacyMedia(in: root.url)
        try store.wipeLegacyMedia(hasDurablePendingMarker: true)
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("files").path))
    }

    @Test func recoveryMarkerPersistsUntilExplicitCommit() throws {
        let root = Root()
        let store = PanicRecoveryFileStore(baseDirectory: root.url)

        try store.markPanicRecoveryPending()
        #expect(try store.isPanicRecoveryPending())
        try store.wipeLegacyMedia(hasDurablePendingMarker: true)
        #expect(try store.isPanicRecoveryPending())

        try store.completePanicRecovery()
        #expect(try !store.isPanicRecoveryPending())
    }
}
