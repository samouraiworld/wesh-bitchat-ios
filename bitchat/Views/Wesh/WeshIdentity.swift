import BitFoundation
import Combine
import Foundation

@MainActor
enum WeshMode {
    static var isActive = false
}

/// QR enrollment is separate from upstream manual verification and transitive vouches.
@MainActor
final class WeshQRTrust: ObservableObject {
    static let shared = WeshQRTrust()
    struct Contact: Codable, Identifiable {
        let noiseKeyHex: String
        let nickname: String
        var id: String { noiseKeyHex }
        var peerID: PeerID { PeerID(hexData: Data(hexString: noiseKeyHex) ?? Data()) }
    }
    @Published private(set) var contacts: [Contact]
    @Published private(set) var fingerprints: Set<String>
    private let defaults: UserDefaults
    private let key = "wesh.qrVerifiedFingerprints.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fingerprints = Set(defaults.stringArray(forKey: key) ?? [])
        contacts = (defaults.data(forKey: "wesh.qrContacts.v1").flatMap { try? JSONDecoder().decode([Contact].self, from: $0) }) ?? []
    }

    func record(sessionKey: Data, nickname: String = "Contact") {
        guard sessionKey.count == 32 else { return }
        fingerprints.insert(sessionKey.sha256Fingerprint())
        let hex = sessionKey.hexEncodedString()
        contacts.removeAll { $0.noiseKeyHex == hex }
        contacts.append(Contact(noiseKeyHex: hex, nickname: nickname))
        persist()
    }

    /// Revokes only this identity's enrollment; history and drafts belong to
    /// their own stores and must not be cleared by a contact-list action.
    @discardableResult
    func remove(sessionKey: Data) -> Bool {
        guard sessionKey.count == 32 else { return false }
        let hex = sessionKey.hexEncodedString()
        let fingerprint = sessionKey.sha256Fingerprint()
        guard contacts.contains(where: { $0.noiseKeyHex == hex }) || fingerprints.contains(fingerprint) else { return false }
        contacts.removeAll { $0.noiseKeyHex == hex }
        fingerprints.remove(fingerprint)
        persist()
        return true
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(contacts), forKey: "wesh.qrContacts.v1")
        defaults.set(Array(fingerprints), forKey: key)
    }

    func clear() {
        contacts = []
        defaults.removeObject(forKey: "wesh.qrContacts.v1")
        fingerprints = []
        defaults.removeObject(forKey: key)
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
        guard meshService.noiseStaticPublicKeyData().count == 32,
              meshService.noiseSigningPublicKeyData().count == 32 else { return false }
        guard identityManager.isPersistenceAvailable,
              !identityManager.hasPendingPersistenceChanges else { return false }
        if let pinned = peerID.noiseKey, identityManager.isBlocked(fingerprint: pinned.sha256Fingerprint()) { return false }
        let shortID = getShortIDForNoiseKey(peerID)
        guard !isPeerBlocked(shortID) else { return false }
        let sessionKey = noiseSessionPublicKeyData(for: shortID)
        guard let sessionKey, getFingerprint(for: shortID) == sessionKey.sha256Fingerprint() else { return false }
        return WeshQRTrust.canSend(sessionKey: sessionKey, qrFingerprints: WeshQRTrust.shared.fingerprints,
                                  locallyVerified: peerIdentityStore.isVerified(sessionKey.sha256Fingerprint()), requestedKey: peerID.noiseKey)
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
