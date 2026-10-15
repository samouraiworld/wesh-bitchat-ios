import Foundation
import Darwin

enum SharedContentKind: String, Codable, Sendable, Equatable {
    case text
    case url
}

/// The single, bounded payload handed from the share extension to the app.
///
/// The app-group store intentionally contains at most one envelope. A newer
/// share replaces an older one, which prevents unbounded shared-container
/// growth while still surviving suspension and a later app launch.
struct SharedContentPayload: Codable, Sendable, Equatable, Identifiable {
    static let currentVersion = 1
    static let maxContentBytes = 16_000
    static let maxTitleBytes = 512
    static let maxEnvelopeBytes = 24_000
    static let retentionSeconds: TimeInterval = 24 * 60 * 60
    static let allowedFutureSkewSeconds: TimeInterval = 5 * 60

    let version: Int
    let id: UUID
    let kind: SharedContentKind
    let content: String
    let title: String?
    let createdAt: Date

    init(
        version: Int = Self.currentVersion,
        id: UUID = UUID(),
        kind: SharedContentKind,
        content: String,
        title: String? = nil,
        createdAt: Date = Date()
    ) {
        self.version = version
        self.id = id
        self.kind = kind
        self.content = content
        self.title = title
        self.createdAt = createdAt
    }

    static func text(_ content: String, createdAt: Date = Date()) -> SharedContentPayload {
        SharedContentPayload(kind: .text, content: content, createdAt: createdAt)
    }

    var composerText: String { content }

    var preview: String {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard normalized.count > 240 else { return normalized }
        return String(normalized.prefix(240)) + "…"
    }

    func validate(now: Date = Date()) throws {
        guard version == Self.currentVersion else {
            throw SharedContentHandoffError.unsupportedVersion
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SharedContentHandoffError.emptyContent
        }
        guard content.utf8.count <= Self.maxContentBytes else {
            throw SharedContentHandoffError.contentTooLarge
        }
        if let title {
            guard title.utf8.count <= Self.maxTitleBytes else {
                throw SharedContentHandoffError.titleTooLarge
            }
            guard !Self.containsDisallowedControl(in: title, allowsTextLayout: false) else {
                throw SharedContentHandoffError.invalidCharacters
            }
        }

        let age = now.timeIntervalSince(createdAt)
        guard age >= -Self.allowedFutureSkewSeconds,
              age <= Self.retentionSeconds else {
            throw SharedContentHandoffError.expired
        }

        switch kind {
        case .text:
            guard !Self.containsDisallowedControl(in: content, allowsTextLayout: true) else {
                throw SharedContentHandoffError.invalidCharacters
            }
        case .url:
            guard !Self.containsDisallowedControl(in: content, allowsTextLayout: false),
                  let components = URLComponents(string: content),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  components.host?.isEmpty == false else {
                throw SharedContentHandoffError.unsupportedURL
            }
        }
    }

    private static func containsDisallowedControl(
        in value: String,
        allowsTextLayout: Bool
    ) -> Bool {
        value.unicodeScalars.contains { scalar in
            guard CharacterSet.controlCharacters.contains(scalar) else { return false }
            if allowsTextLayout, scalar == "\n" || scalar == "\r" || scalar == "\t" {
                return false
            }
            return true
        }
    }
}

enum SharedContentHandoffError: Error, Equatable {
    case unsupportedVersion
    case emptyContent
    case contentTooLarge
    case titleTooLarge
    case invalidCharacters
    case expired
    case unsupportedURL
    case envelopeTooLarge
    case encodingFailed
    case storageUnavailable
}

/// Durable, single-item app-group storage used by both the extension and app.
final class SharedContentStore {
    static let storageKey = "sharedContentEnvelopeV1"

    private static let legacyKeys = [
        "sharedContent",
        "sharedContentType",
        "sharedContentDate"
    ]

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lockURL: URL?
    private let lockTimeout: TimeInterval
    private let monotonicNow: () -> TimeInterval
    private let pauseBeforeLockRetry: () -> Void

    #if DEBUG
    /// Exercises an extension writer arriving after validation, before deletion.
    var beforeRemovalForTesting: (() -> Void)?
    #endif

    init(defaults: UserDefaults, lockURL: URL? = nil,
         lockTimeout: TimeInterval = 0.05,
         monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pauseBeforeLockRetry: @escaping () -> Void = { Thread.sleep(forTimeInterval: 0.001) }) {
        self.defaults = defaults
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
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

    /// Replaces any older pending share with a validated, bounded envelope.
    func stage(_ payload: SharedContentPayload, now: Date = Date()) throws {
        try payload.validate(now: now)
        guard let encoded = try? encoder.encode(payload) else {
            throw SharedContentHandoffError.encodingFailed
        }
        guard encoded.count <= SharedContentPayload.maxEnvelopeBytes else {
            throw SharedContentHandoffError.envelopeTooLarge
        }

        try withInterprocessLock {
            defaults.set(encoded, forKey: Self.storageKey)
            clearLegacyKeys()
        }
    }

    /// Reads the pending share without consuming it. Invalid and expired data
    /// is removed immediately so malformed app-group state cannot linger.
    func pending(now: Date = Date()) -> SharedContentPayload? {
        (try? withInterprocessLock { pendingUnlocked(now: now) }) ?? nil
    }

    private func pendingUnlocked(now: Date) -> SharedContentPayload? {
        clearLegacyKeys()

        guard let encoded = defaults.data(forKey: Self.storageKey) else { return nil }
        guard encoded.count <= SharedContentPayload.maxEnvelopeBytes,
              let payload = try? decoder.decode(SharedContentPayload.self, from: encoded) else {
            removeEnvelopeUnlocked()
            return nil
        }

        do {
            try payload.validate(now: now)
            return payload
        } catch {
            removeEnvelopeUnlocked()
            return nil
        }
    }

    /// Consumes only the envelope the user actually reviewed. If a newer share
    /// already replaced it, the newer content remains pending.
    func consume(id: UUID, now: Date = Date(), expected: SharedContentPayload? = nil,
                 accepting: (SharedContentPayload) -> Bool = { _ in true }) -> SharedContentPayload? {
        (try? withInterprocessLock {
            guard let payload = pendingUnlocked(now: now), payload.id == id,
                  expected == nil || expected == payload, accepting(payload) else { return nil as SharedContentPayload? }
            removeEnvelopeUnlocked()
            return payload
        }) ?? nil
    }

    /// Explicit cancellation has the same identity guard as consumption so it
    /// can never discard a newer share that arrived while a prompt was open.
    func discard(id: UUID) {
        try? withInterprocessLock {
            guard let encoded = defaults.data(forKey: Self.storageKey),
                  encoded.count <= SharedContentPayload.maxEnvelopeBytes,
                  let payload = try? decoder.decode(SharedContentPayload.self, from: encoded),
                  payload.id == id else {
                return
            }
            removeEnvelopeUnlocked()
        }
    }

    func discardAll() {
        try? withInterprocessLock {
            removeEnvelopeUnlocked()
            clearLegacyKeys()
        }
    }

    private func removeEnvelopeUnlocked() {
        #if DEBUG
        beforeRemovalForTesting?()
        #endif
        defaults.removeObject(forKey: Self.storageKey)
    }

    /// Every app/extension operation uses the same app-group BSD file lock.
    /// Synchronize preferences inside the critical section, not after releasing it.
    private func withInterprocessLock<T>(_ body: () throws -> T) throws -> T {
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
            guard defaults.synchronize() else { throw SharedContentHandoffError.storageUnavailable }
            return result
        } catch {
            // A failed flush must not consume a review or replace its content.
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
