//
// LocalFileProtectionTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

/// Every file the app writes stays on this device: none of it may reach an
/// iCloud or computer backup.
@Suite("Local data stays out of backups")
struct LocalFileProtectionTests {
    private final class Root {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-file-protection-\(UUID().uuidString)", isDirectory: true)
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Helper

    @Test func writeExcludesTheFileAndKeepsItExcludedAcrossAtomicRewrites() throws {
        let root = Root()
        let url = root.url.appendingPathComponent("nested/record.json")
        try LocalFileProtection.write(Data("one".utf8), to: url, level: .complete)
        #expect(LocalFileProtection.isExcludedFromBackup(url))
        // An atomic rewrite replaces the file, which drops its attributes.
        try LocalFileProtection.write(Data("two".utf8), to: url, level: .untilFirstUnlock)
        #expect(LocalFileProtection.isExcludedFromBackup(url))
        #expect(try Data(contentsOf: url) == Data("two".utf8))
    }

    @Test func createdDirectoriesAreExcludedSoProgressiveWritesInsideAreToo() throws {
        let root = Root()
        let directory = root.url.appendingPathComponent("files/voicenotes/outgoing", isDirectory: true)
        try LocalFileProtection.createDirectory(directory)
        #expect(LocalFileProtection.isExcludedFromBackup(directory))
    }

    @Test func aFileWrittenWithoutTheHelperIsReportedAsBackedUp() throws {
        let root = Root()
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        let url = root.url.appendingPathComponent("plain.json")
        try Data("x".utf8).write(to: url)
        #expect(!LocalFileProtection.isExcludedFromBackup(url))
    }

    // MARK: Stores

    @Test func gossipArchiveOfPublicMessagesIsExcluded() throws {
        let root = Root()
        let url = root.url.appendingPathComponent("sync/public-messages.json")
        GossipMessageArchive(fileURL: url).save([Data([1, 2, 3])])
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(LocalFileProtection.isExcludedFromBackup(url))
    }

    @Test func processedNostrEventsAreExcluded() throws {
        let root = Root()
        let url = root.url.appendingPathComponent("nostr/processed-events.json")
        let store = NostrProcessedEventStore(fileURL: url)
        store.append([String(repeating: "a", count: 64)], cap: 10)
        _ = store.load() // drains the store's IO queue
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(LocalFileProtection.isExcludedFromBackup(url))
    }

    @Test func privateOutboxIsExcluded() throws {
        let root = Root()
        let url = root.url.appendingPathComponent("outbox/outbox.enc")
        MessageOutboxStore(keychain: MockKeychain(), fileURL: url).save([
            PeerID(str: "0102030405060708"): [MessageOutboxStore.QueuedMessage(
                content: "Rendez-vous synthétique", nickname: "Peer", messageID: "m1", timestamp: Date()
            )]
        ])
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(LocalFileProtection.isExcludedFromBackup(url))
    }

    @Test func panicRecoveryMarkerIsExcluded() throws {
        let root = Root()
        try PanicRecoveryFileStore(baseDirectory: root.url).markPanicRecoveryPending()
        let marker = try #require(try FileManager.default.contentsOfDirectory(at: root.url, includingPropertiesForKeys: nil)
            .first { !$0.hasDirectoryPath })
        #expect(LocalFileProtection.isExcludedFromBackup(marker))
    }

    @Test func sealedQRContactsAndMeetingNoteFilesAreExcluded() throws {
        let root = Root()
        let url = root.url.appendingPathComponent("wesh-private/qr-contacts-v1.enc")
        try WeshSealedStore(keychain: MockKeychain(), fileURL: url, keyName: "qr.test", context: "qr.test")
            .save(Data("contact".utf8))
        #expect(LocalFileProtection.isExcludedFromBackup(url))
    }
}
