#if DEBUG
import Foundation
import BitFoundation

/// Debug builds only. Enrolls a QR contact with an npub without a camera or Bluetooth, so a
/// simulator can exchange Internet messages with an emulator or another simulator (M4). It
/// stands for a scanned QR whose npub proof verified, and goes through the same enrollment
/// checks (valid npub, not mine, not another contact's). Release builds do not contain this file.
///
/// Launch environment (`SIMCTL_CHILD_` prefix with `xcrun simctl launch --console`):
/// - `WESH_DEBUG_IDENTITY=1` prints my Noise key and npub; nothing is created or sent.
/// - `WESH_DEBUG_SEED_CONTACT=<noise key hex>,<npub>[,<nickname>]` enrolls that contact.
enum WeshDebugContactSeed {
    struct Request {
        let noiseKeyHex: String
        let npub: String
        let nickname: String
    }

    static let identityVariable = "WESH_DEBUG_IDENTITY"
    static let seedVariable = "WESH_DEBUG_SEED_CONTACT"

    static func request(from environment: [String: String]) -> Request? {
        guard let value = environment[seedVariable] else { return nil }
        let parts = value.split(separator: ",", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }
        return Request(noiseKeyHex: parts[0].lowercased(), npub: parts[1], nickname: parts.count == 3 ? parts[2] : "Contact")
    }

    /// In the order of a verified QR scan with a valid npub proof: the fingerprint is marked
    /// verified (`markVerified` returns whether that was saved), then the contact is recorded.
    /// False, with nothing marked or recorded, when a scanned QR would not bind it.
    @MainActor
    static func seed(_ request: Request, into trust: WeshQRTrust, ownedNpubs: Set<String>?,
                     markVerified: (String) -> Bool) -> Bool {
        trust.reloadIfNeeded()
        guard trust.storageState == .available,
              let key = Data(hexString: request.noiseKeyHex), key.count == 32 else { return false }
        // No proof to verify here: the unproven rules decide (valid, not mine, not another
        // contact's), and the binding is then recorded as proven.
        let outcome = WeshQRNpub.enrollment(npub: request.npub, npubSigHex: nil, canonicalBytes: Data(),
                                            noiseKeyHex: request.noiseKeyHex, ownedNpubs: ownedNpubs,
                                            contacts: trust.contacts)
        guard case .bound(let npub, _, let unbinding) = outcome, npub == request.npub, unbinding.isEmpty,
              markVerified(key.sha256Fingerprint()) else { return false }
        return trust.enroll(sessionKey: key, nickname: request.nickname,
                            outcome: .bound(npub: npub, proven: true, unbinding: []))
    }
}

extension ChatViewModel {
    /// Debug builds only, once at startup: see `WeshDebugContactSeed`.
    @MainActor
    func applyWeshDebugHooks(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard weshPrivatePolicyEnabled else { return }
        if environment[WeshDebugContactSeed.identityVariable] == "1" {
            let npub = idBridge.messagingIdentity(weshActive: true, internetEnabled: true)?.npub ?? "none"
            print("WESH_DEBUG_IDENTITY noise=\(meshService.noiseStaticPublicKeyData().hexEncodedString()) npub=\(npub)")
        }
        guard let request = WeshDebugContactSeed.request(from: environment) else { return }
        // Same identity-store conditions as the real enrollment (ChatVerificationCoordinator).
        let enrolled = WeshDebugContactSeed.seed(request, into: .shared, ownedNpubs: try? idBridge.locallyOwnedNpubs()) { fingerprint in
            guard identityManager.isPersistenceAvailable, !identityManager.hasPendingPersistenceChanges else { return false }
            identityManager.setVerified(fingerprint: fingerprint, verified: true)
            identityManager.forceSave()
            guard identityManager.isPersistenceAvailable, !identityManager.hasPendingPersistenceChanges else { return false }
            peerIdentityStore.setVerified(fingerprint, verified: true)
            return true
        }
        print("WESH_DEBUG_SEED_CONTACT \(enrolled ? "enrolled" : "refused")")
    }
}
#endif
