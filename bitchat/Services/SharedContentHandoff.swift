import BitLogger
import Foundation
import Darwin

private enum SharedContentHandoffError: String, Error {
    case groupUnavailable = "group_unavailable"
    case lockOpen = "lock_open"
    case lockTimeout = "lock_timeout"
    case retainedKeys = "retained_keys"
}

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
    private let readbackDefaults: () -> UserDefaults?

    init(defaults: UserDefaults, lockURL: URL? = nil,
         lockTimeout: TimeInterval = 0.05,
         monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pauseBeforeLockRetry: @escaping () -> Void = { Thread.sleep(forTimeInterval: 0.001) },
         readbackDefaults: (() -> UserDefaults?)? = nil) {
        self.defaults = defaults
        self.lockTimeout = lockTimeout
        self.monotonicNow = monotonicNow
        self.pauseBeforeLockRetry = pauseBeforeLockRetry
        self.readbackDefaults = readbackDefaults ?? { defaults }
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
        guard lockURL != nil else {
            logFailure(.groupUnavailable)
            return false
        }
        // The share extension is retired from the product. If a fresh view of
        // its four legacy keys is already empty, there is no writer to race and
        // no persistence work to perform. In particular, a no-op must not be
        // rejected because deprecated synchronize() returns false.
        if legacyKeysAreConfirmedAbsent() { return true }

        do {
            return try withInterprocessLock {
                // Best-effort compatibility pull for a mailbox written by an
                // older extension. Its Bool is not an erasure result.
                _ = defaults.synchronize()
                defaults.removeObject(forKey: Self.storageKey)
                clearLegacyKeys()
                // When data was present, a failed post-delete flush cannot be
                // treated as proof of erasure: CFPreferences instances share
                // an in-process cache and may all read nil while the plist on
                // disk still contains the retired payload.
                guard defaults.synchronize() else {
                    throw SharedContentHandoffError.retainedKeys
                }
                guard legacyKeysAreConfirmedAbsent() else {
                    throw SharedContentHandoffError.retainedKeys
                }
                return true
            }
        } catch {
            if let failure = error as? SharedContentHandoffError {
                logFailure(failure)
            } else {
                SecureLogger.error(
                    "Retired shared-content erase failed: unexpected",
                    category: .security
                )
            }
            return false
        }
    }

    /// Legacy erasure uses the same BSD file lock as earlier extension writers.
    /// Synchronize preferences inside the critical section, not after releasing it.
    private func withInterprocessLock<T>(_ body: () throws -> T) throws -> T {
        guard let lockURL else { throw SharedContentHandoffError.groupUnavailable }
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SharedContentHandoffError.lockOpen }
        defer { Darwin.close(descriptor) }
        // A suspended extension must not leave the app waiting indefinitely.
        // Retry only within a 50ms monotonic budget in production; no unlocked fallback.
        let deadline = monotonicNow() + max(0, lockTimeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR,
                  monotonicNow() < deadline else { throw SharedContentHandoffError.lockTimeout }
            pauseBeforeLockRetry()
        }
        defer { flock(descriptor, LOCK_UN) }
        let keys = [Self.storageKey] + Self.legacyKeys
        let snapshot = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })
        do {
            return try body()
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

    private func legacyKeysAreConfirmedAbsent() -> Bool {
        let keys = [Self.storageKey] + Self.legacyKeys
        guard keys.allSatisfy({ defaults.object(forKey: $0) == nil }),
              let freshDefaults = readbackDefaults() else {
            return false
        }
        return keys.allSatisfy { freshDefaults.object(forKey: $0) == nil }
    }

    private func logFailure(_ failure: SharedContentHandoffError) {
        SecureLogger.error(
            "Retired shared-content erase failed: \(failure.rawValue)",
            category: .security
        )
    }
}
