import Foundation

/// Erases the legacy file without loading, accepting or recreating Board data.
final class RetiredBoardStore {
    static let shared = RetiredBoardStore()
    private let fileURL: URL?
    private let persistenceRequired: Bool
    private let wipeFileManager: FileManager

    init(fileURL: URL? = nil, wipeFileManager: FileManager = .default) {
        persistenceRequired = fileURL != nil || !TestEnvironment.isRunningTests
        self.wipeFileManager = wipeFileManager
        if let fileURL {
            self.fileURL = fileURL
        } else if persistenceRequired {
            self.fileURL = (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
            ))?.appendingPathComponent("board", isDirectory: true).appendingPathComponent("posts.json")
        } else {
            self.fileURL = nil
        }
    }

    @discardableResult
    func wipe() -> Bool {
        PanicFileRemoval.remove(fileURL, required: persistenceRequired, fileManager: wipeFileManager)
    }
}
