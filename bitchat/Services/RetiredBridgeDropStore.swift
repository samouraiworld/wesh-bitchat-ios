import Foundation

/// Erases the legacy record without loading or recreating bridge courier state.
final class RetiredBridgeDropStore {
    static let shared = RetiredBridgeDropStore()
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
            ))?.appendingPathComponent("courier", isDirectory: true).appendingPathComponent("bridge-drop-dedup.json")
        } else {
            self.fileURL = nil
        }
    }

    @discardableResult
    func wipe() -> Bool {
        PanicFileRemoval.remove(fileURL, required: persistenceRequired, fileManager: wipeFileManager)
    }
}
