// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

import Foundation

/// The single write path for files the app keeps on disk. Each file gets an
/// explicit protection class and is excluded from iCloud and computer
/// backups, so nothing written locally leaves the device that way.
enum LocalFileProtection {
    enum Level {
        /// Unreadable while the device is locked.
        case complete
        /// Readable after the first unlock, for work done in the background.
        case untilFirstUnlock
    }

    /// Directories are created protected until first unlock so background
    /// work can still list them; each file states its own class.
    static var directoryAttributes: [FileAttributeKey: Any]? {
        #if os(iOS)
        return [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        return nil
        #endif
    }

    static func writingOptions(_ level: Level) -> Data.WritingOptions {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        switch level {
        case .complete: options.insert(.completeFileProtection)
        case .untilFirstUnlock: options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        }
        #endif
        return options
    }

    /// Creates the parent directory, writes atomically with `level`, then
    /// excludes the file from backup.
    static func write(_ data: Data, to url: URL, level: Level, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: directoryAttributes
        )
        try write(data, to: url, options: writingOptions(level))
    }

    /// For stores with an injectable writer. An atomic write replaces the
    /// file and its attributes, so the exclusion is set after every write.
    static func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try data.write(to: url, options: options)
        try excludeFromBackup(url)
    }

    /// Creates an app-owned directory excluded from backup; files that are
    /// written into it progressively (recordings, live captures) inherit it.
    @discardableResult
    static func createDirectory(_ url: URL, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: directoryAttributes)
        try excludeFromBackup(url)
        return url
    }

    static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try target.setResourceValues(values)
    }

    static func isExcludedFromBackup(_ url: URL) -> Bool {
        // A fresh URL so no cached resource value is returned.
        let fresh = URL(fileURLWithPath: url.path)
        return (try? fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }

    #if os(iOS)
    /// Launch sweep for files written before every writer went through this
    /// type, and for anything a library writes: Application Support is the
    /// app's own container directory on iOS, so it is excluded whole.
    static func excludeApplicationSupportFromBackup(fileManager: FileManager = .default) {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              fileManager.fileExists(atPath: base.path) else { return }
        try? excludeFromBackup(base)
        let children = (try? fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        for child in children {
            try? excludeFromBackup(child)
        }
    }
    #endif
}
