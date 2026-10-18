import Foundation

/// Deletes legacy geographic state without decoding it, creating directories
/// or constructing any of the retired location services.
final class RetiredGeographyStore {
    static let shared = RetiredGeographyStore()
    private static let preferenceKeys = [
        "locationChannel.selected", "locationChannel.teleportedSet",
        "locationChannel.bookmarks", "locationChannel.bookmarkNames",
        "locationChannel.bookmarkNamesSchemaVersion", "locationNotes.enabled",
        "georelay.lastFetchAt"
    ]
    private let defaults: UserDefaults
    private let applicationSupportURL: URL?
    private let filesRequired: Bool
    private let fileManager: FileManager

    init(defaults: UserDefaults = .standard, applicationSupportURL: URL? = nil, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
        filesRequired = applicationSupportURL != nil || !TestEnvironment.isRunningTests
        if let applicationSupportURL {
            self.applicationSupportURL = applicationSupportURL
        } else if filesRequired {
            self.applicationSupportURL = try? fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false
            )
        } else {
            self.applicationSupportURL = nil
        }
    }

    @discardableResult
    func wipe() -> Bool {
        for key in Self.preferenceKeys { defaults.removeObject(forKey: key) }
        let preferencesFlushed = defaults.synchronize()
        let preferencesAbsent = Self.preferenceKeys.map { defaults.object(forKey: $0) == nil }.allSatisfy { $0 }
        guard let applicationSupportURL else {
            return preferencesFlushed && preferencesAbsent && !filesRequired
        }
        // This parent also contains Arti state. Remove only the two historical
        // CSV files, attempting both even if another part of the wipe failed.
        let directory = applicationSupportURL.appendingPathComponent("bitchat", isDirectory: true)
        let oldCacheRemoved = PanicFileRemoval.remove(directory.appendingPathComponent("georelays_cache.csv"),
            required: true, fileManager: fileManager)
        let currentCacheRemoved = PanicFileRemoval.remove(directory.appendingPathComponent("georelays_cache_v2.csv"),
            required: true, fileManager: fileManager)
        return preferencesFlushed && preferencesAbsent && oldCacheRemoved && currentCacheRemoved
    }
}
