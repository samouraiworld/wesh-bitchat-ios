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
}

extension ChatViewModel {
    @MainActor
    func canSendWeshPrivate(to peerID: PeerID) -> Bool {
        let shortID = getShortIDForNoiseKey(peerID)
        guard !isPeerBlocked(shortID) else { return false }
        let sessionKey = noiseSessionPublicKeyData(for: shortID)
        guard let sessionKey, getFingerprint(for: shortID) == sessionKey.sha256Fingerprint() else { return false }
        return WeshQRTrust.canSend(sessionKey: sessionKey, qrFingerprints: WeshQRTrust.shared.fingerprints,
                                  locallyVerified: peerIdentityStore.isVerified(sessionKey.sha256Fingerprint()), requestedKey: peerID.noiseKey)
    }

}
