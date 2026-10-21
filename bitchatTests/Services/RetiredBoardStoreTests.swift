import Foundation
import Testing
@testable import bitchat

struct RetiredBoardStoreTests {
    @Test
    func eraserNeverLoadsOrRecreatesLegacyBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = root.appendingPathComponent("board/posts.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("Synthetic legacy data, deliberately invalid JSON".utf8)
        try bytes.write(to: file)
        let eraser = RetiredBoardStore(fileURL: file)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(eraser.wipe())
        #expect(eraser.wipe())
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test
    func absentLegacyDirectoryRemainsAbsent() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let eraser = RetiredBoardStore(fileURL: root.appendingPathComponent("board/posts.json"))
        #expect(eraser.wipe())
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
