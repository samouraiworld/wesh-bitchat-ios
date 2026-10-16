import BitFoundation
import Combine
import Foundation

@MainActor
enum WeshMode {
    static var isActive = false
}

/// Common Wesh text admission bound; draft storage may retain longer text.
enum WeshTextLimits {
    static let maximumUTF8Bytes = 2000
}

/// QR enrollment is separate from upstream manual verification and transitive vouches.
/// Contacts are sealed on this device only. An unreadable record is preserved
/// and reported, never replaced by an empty list.
@MainActor
final class WeshQRTrust: ObservableObject {
    static let shared = TestEnvironment.isRunningTests
        ? WeshQRTrust()
        : WeshQRTrust(storage: .liveQRContacts(), legacyDefaults: .standard)
    struct Contact: Codable, Identifiable, Equatable {
        let noiseKeyHex: String
        let nickname: String
        var id: String { noiseKeyHex }
        var peerID: PeerID { PeerID(hexData: Data(hexString: noiseKeyHex) ?? Data()) }
    }
    enum StorageState: Equatable { case available, unavailable, recoveryRequired }
    private struct Snapshot: Codable, Equatable {
        var contacts: [Contact] = []
        var fingerprints: [String] = []
    }
    static let legacyContactsKey = "wesh.qrContacts.v1"
    static let legacyFingerprintsKey = "wesh.qrVerifiedFingerprints.v1"

    @Published private(set) var contacts: [Contact] = []
    @Published private(set) var fingerprints: Set<String> = []
    @Published private(set) var storageState: StorageState = .available
    private let storage: WeshSealedStore?
    private let legacyDefaults: UserDefaults?

    /// Nil storage is a RAM-only instance (tests, previews).
    init(storage: WeshSealedStore? = nil, legacyDefaults: UserDefaults? = nil) {
        self.storage = storage
        self.legacyDefaults = legacyDefaults
        load()
    }

    /// Retries a load deferred by a locked device or Keychain failure.
    func reloadIfNeeded() {
        if storageState != .available { load() }
    }

    @discardableResult
    func record(sessionKey: Data, nickname: String = "Contact") -> Bool {
        guard sessionKey.count == 32 else { return false }
        reloadIfNeeded()
        let hex = sessionKey.hexEncodedString()
        var next = snapshot
        next.contacts.removeAll { $0.noiseKeyHex == hex }
        next.contacts.append(Contact(noiseKeyHex: hex, nickname: nickname))
        let fingerprint = sessionKey.sha256Fingerprint()
        if !next.fingerprints.contains(fingerprint) { next.fingerprints.append(fingerprint) }
        return commit(next)
    }

    /// Revokes only this identity's enrollment; history and drafts belong to
    /// their own stores and must not be cleared by a contact-list action.
    @discardableResult
    func remove(sessionKey: Data) -> Bool {
        guard sessionKey.count == 32 else { return false }
        reloadIfNeeded()
        let hex = sessionKey.hexEncodedString()
        let fingerprint = sessionKey.sha256Fingerprint()
        guard contacts.contains(where: { $0.noiseKeyHex == hex }) || fingerprints.contains(fingerprint) else { return false }
        var next = snapshot
        next.contacts.removeAll { $0.noiseKeyHex == hex }
        next.fingerprints.removeAll { $0 == fingerprint }
        return commit(next)
    }

    /// Clears RAM first, then confirms the sealed file, its key and any legacy
    /// plaintext copy are gone.
    @discardableResult
    func clear() -> Bool {
        contacts = []
        fingerprints = []
        var erased = true
        if let storage {
            do { try storage.wipe() } catch { erased = false }
        }
        erased = removeLegacy() && erased
        storageState = erased ? .available : .unavailable
        return erased
    }

    private var snapshot: Snapshot {
        Snapshot(contacts: contacts, fingerprints: fingerprints.sorted())
    }

    /// Changes RAM only after a confirmed write, so a failure never shows a
    /// contact that will not survive a restart.
    private func commit(_ next: Snapshot) -> Bool {
        guard storageState == .available else { return false }
        if let storage {
            do {
                try storage.save(JSONEncoder().encode(next))
            } catch WeshSealedStore.Failure.recoveryRequired {
                storageState = .recoveryRequired
                return false
            } catch { return false }
        }
        apply(next)
        return true
    }

    private func apply(_ value: Snapshot) {
        contacts = value.contacts
        fingerprints = Set(value.fingerprints)
    }

    private func load() {
        guard let storage else {
            storageState = .available
            return
        }
        do {
            if let data = try storage.load() {
                guard let value = try? JSONDecoder().decode(Snapshot.self, from: data) else {
                    throw WeshSealedStore.Failure.recoveryRequired
                }
                apply(value)
                _ = removeLegacy()
            } else if let legacy = try legacySnapshot() {
                // One-time migration: delete plaintext only after a confirmed sealed write.
                try storage.save(JSONEncoder().encode(legacy))
                apply(legacy)
                _ = removeLegacy()
            } else {
                apply(Snapshot())
            }
            storageState = .available
        } catch WeshSealedStore.Failure.recoveryRequired {
            apply(Snapshot())
            storageState = .recoveryRequired
        } catch {
            // Locked device or unconfirmed write: retryable, nothing replaced.
            apply(Snapshot())
            storageState = .unavailable
        }
    }

    private func legacySnapshot() throws -> Snapshot? {
        guard let legacyDefaults else { return nil }
        let data = legacyDefaults.object(forKey: Self.legacyContactsKey)
        let prints = legacyDefaults.object(forKey: Self.legacyFingerprintsKey)
        guard data != nil || prints != nil else { return nil }
        var value = Snapshot()
        if let data {
            guard let data = data as? Data,
                  let decoded = try? JSONDecoder().decode([Contact].self, from: data) else {
                throw WeshSealedStore.Failure.recoveryRequired
            }
            value.contacts = decoded
        }
        if let prints {
            guard let prints = prints as? [String] else { throw WeshSealedStore.Failure.recoveryRequired }
            value.fingerprints = prints
        }
        return value
    }

    private func removeLegacy() -> Bool {
        guard let legacyDefaults else { return true }
        legacyDefaults.removeObject(forKey: Self.legacyContactsKey)
        legacyDefaults.removeObject(forKey: Self.legacyFingerprintsKey)
        return legacyDefaults.object(forKey: Self.legacyContactsKey) == nil
            && legacyDefaults.object(forKey: Self.legacyFingerprintsKey) == nil
    }

    static func canSend(sessionKey: Data?, qrFingerprints: Set<String>, locallyVerified: Bool, requestedKey: Data? = nil) -> Bool {
        guard locallyVerified, let sessionKey, sessionKey.count == 32 else { return false }
        if let requestedKey, requestedKey != sessionKey { return false }
        return qrFingerprints.contains(sessionKey.sha256Fingerprint())
    }

    /// Preparing a draft may happen offline, but must still target a full,
    /// currently enrolled identity. This never grants permission to transmit.
    static func canPrepareDraft(to peerID: PeerID, contacts: [Contact],
                                qrFingerprints: Set<String>, blockedFingerprints: Set<String>) -> Bool {
        guard let key = peerID.noiseKey, key.count == 32,
              contacts.contains(where: { $0.peerID == peerID }) else { return false }
        let fingerprint = key.sha256Fingerprint()
        return qrFingerprints.contains(fingerprint) && !blockedFingerprints.contains(fingerprint)
    }
}

extension ChatViewModel {
    @MainActor
    func canImportWeshSharedContent(to peerID: PeerID) -> Bool {
        guard identityManager.isPersistenceAvailable,
              !identityManager.hasPendingPersistenceChanges else { return false }
        return WeshQRTrust.canPrepareDraft(to: peerID, contacts: WeshQRTrust.shared.contacts,
                                   qrFingerprints: WeshQRTrust.shared.fingerprints,
                                   blockedFingerprints: identityManager.getBlockedFingerprints())
    }

    @MainActor
    func canSendWeshPrivate(to peerID: PeerID) -> Bool {
        // Transport availability is shared; public disclosure is checked only
        // by the public send API, not by this private identity gate.
        guard canSendWeshPublic,
              let requestedKey = peerID.noiseKey, requestedKey.count == 32 else { return false }
        guard identityManager.isPersistenceAvailable,
              !identityManager.hasPendingPersistenceChanges else { return false }
        if identityManager.isBlocked(fingerprint: requestedKey.sha256Fingerprint()) { return false }
        let shortID = getShortIDForNoiseKey(peerID)
        guard !isPeerBlocked(shortID) else { return false }
        let sessionKey = noiseSessionPublicKeyData(for: shortID)
        guard let sessionKey, getFingerprint(for: shortID) == sessionKey.sha256Fingerprint() else { return false }
        return WeshQRTrust.canSend(sessionKey: sessionKey, qrFingerprints: WeshQRTrust.shared.fingerprints,
                                  locallyVerified: peerIdentityStore.isVerified(sessionKey.sha256Fingerprint()), requestedKey: requestedKey)
    }

    @MainActor @discardableResult
    func unblockWeshIdentity(_ fingerprint: String) -> Bool {
        unifiedPeerService.unblock(fingerprint: fingerprint)
    }

}

/// A historical routing alias cannot identify the author after reassignment.
enum WeshMessageActions {
    static func blockIdentity(messageSender: PeerID?, pinnedConversation: PeerID?) -> PeerID? {
        let candidate = pinnedConversation ?? messageSender
        guard let candidate, let key = candidate.noiseKey, key.count == 32 else { return nil }
        return candidate
    }
}

enum WeshBuildInfo {
    static var displayVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
}
