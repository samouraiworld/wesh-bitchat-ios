import Foundation
import Darwin

private enum SharedContentHandoffError: Error { case storageUnavailable }

/// Erases handoffs left by older versions. No import, decoding, or staging API.
final class SharedContentStore {
    static let storageKey = "sharedContentEnvelopeV1"

    private static let legacyKeys = [
        "sharedContent",
        "sharedContentType",
        "sharedContentDate"
    ]

    private let defaults: UserDefaults
    private let lockURL: URL?
    private let lockTimeout: TimeInterval
    private let monotonicNow: () -> TimeInterval
    private let pauseBeforeLockRetry: () -> Void

    init(defaults: UserDefaults, lockURL: URL? = nil,
         lockTimeout: TimeInterval = 0.05,
         monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pauseBeforeLockRetry: @escaping () -> Void = { Thread.sleep(forTimeInterval: 0.001) }) {
        self.defaults = defaults
        self.lockTimeout = lockTimeout
        self.monotonicNow = monotonicNow
        self.pauseBeforeLockRetry = pauseBeforeLockRetry
        if let lockURL {
            self.lockURL = lockURL
        } else if let groupID = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String,
                  let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            self.lockURL = container.appendingPathComponent(".wesh-share-handoff.lock")
        } else {
            self.lockURL = nil
        }
    }

    @discardableResult
    func discardAll() -> Bool {
        do {
            return try withInterprocessLock(verifyCommit: {
                ([Self.storageKey] + Self.legacyKeys).allSatisfy { self.defaults.object(forKey: $0) == nil }
            }) {
                defaults.removeObject(forKey: Self.storageKey)
                clearLegacyKeys()
                return true
            }
        } catch { return false }
    }

    /// Legacy erasure uses the same BSD file lock as earlier extension writers.
    /// Synchronize preferences inside the critical section, not after releasing it.
    private func withInterprocessLock<T>(verifyCommit: () -> Bool = { true }, _ body: () throws -> T) throws -> T {
        guard let lockURL else { throw SharedContentHandoffError.storageUnavailable }
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SharedContentHandoffError.storageUnavailable }
        defer { Darwin.close(descriptor) }
        // A suspended extension must not leave the app waiting indefinitely.
        // Retry only within a 50ms monotonic budget in production; no unlocked fallback.
        let deadline = monotonicNow() + max(0, lockTimeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR,
                  monotonicNow() < deadline else { throw SharedContentHandoffError.storageUnavailable }
            pauseBeforeLockRetry()
        }
        defer { flock(descriptor, LOCK_UN) }
        guard defaults.synchronize() else { throw SharedContentHandoffError.storageUnavailable }
        let keys = [Self.storageKey] + Self.legacyKeys
        let snapshot = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })
        do {
            let result = try body()
            guard defaults.synchronize(), verifyCommit() else { throw SharedContentHandoffError.storageUnavailable }
            return result
        } catch {
            // A failed flush must preserve the data for a checked erase retry.
            // Restore while holding the same interprocess lock, then retry flush.
            for key in keys {
                if let value = snapshot[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            _ = defaults.synchronize()
            throw error
        }
    }

    private func clearLegacyKeys() {
        for key in Self.legacyKeys {
            defaults.removeObject(forKey: key)
        }
    }
}
