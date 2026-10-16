import BitFoundation
import BitLogger
import Foundation
import Security

/// The narrow surface `ChatVerificationCoordinator` needs from its owner.
///
/// Follows the `ChatDeliveryContext` exemplar: the coordinator depends on the
/// minimal context it actually uses instead of holding an `unowned` back-ref
/// to the whole `ChatViewModel`. This keeps the coordinator independently
/// testable (see `ChatVerificationCoordinatorContextTests`) and makes its true
/// dependencies explicit.
@MainActor
protocol ChatVerificationContext: AnyObject {
    // MARK: Fingerprints & verification state
    var isIdentityStateAvailable: Bool { get }
    var hasPendingIdentityStateChanges: Bool { get }
    func getFingerprint(for peerID: PeerID) -> String?
    /// The UI-facing verified-fingerprint set (peer identity store backed).
    var verifiedFingerprints: Set<String> { get set }
    /// The persisted verified-fingerprint set from the identity manager.
    func persistedVerifiedFingerprints() -> Set<String>
    /// Persists the verified flag in the identity manager.
    func setIdentityVerified(fingerprint: String, verified: Bool)
    /// Updates the UI-facing verified flag in the peer identity store.
    func setStoredVerified(_ fingerprint: String, verified: Bool)
    func isVerifiedFingerprint(_ fingerprint: String) -> Bool
    func saveIdentityState()
    /// After a fingerprint becomes verified, run a transitive-vouch pass over
    /// currently connected peers (so verifying a peer you're already connected
    /// to sends vouches immediately, and the new identity propagates onward).
    func vouchToConnectedVerifiedPeers()

    // MARK: Encryption status
    func setEncryptionStatus(_ status: EncryptionStatus?, for peerID: PeerID)
    func updateEncryptionStatus(for peerID: PeerID)
    func invalidateEncryptionCache(for peerID: PeerID?)
    /// Signals that verification state changed so observers refresh (e.g. `objectWillChange.send()`).
    func notifyUIChanged()

    // MARK: Peers
    var unifiedPeers: [BitchatPeer] { get }
    var unifiedFavorites: [BitchatPeer] { get }
    /// The peer's current entry in the unified peer service, if known.
    func unifiedPeer(for peerID: PeerID) -> BitchatPeer?
    func unifiedFingerprint(for peerID: PeerID) -> String?
    func resolveNickname(for peerID: PeerID) -> String
    func cachedStablePeerID(for shortPeerID: PeerID) -> PeerID?
    func cacheStablePeerID(_ stablePeerID: PeerID, for shortPeerID: PeerID)

    // MARK: Noise sessions & verification transport
    /// Installs the Noise service's session callbacks (single registration point).
    func installNoiseSessionCallbacks(
        onPeerAuthenticated: @escaping (PeerID, String) -> Void,
        onHandshakeRequired: @escaping (PeerID) -> Void
    )
    /// Resolves the peer's Noise static key from the active Noise session, if any.
    func noiseSessionPublicKeyData(for peerID: PeerID) -> Data?
    /// Our own Noise static public key.
    func noiseStaticPublicKeyData() -> Data
    /// Every npub this device holds a key for, read-only (never creates a
    /// key); nil when it cannot be computed. A contact's QR may not claim one.
    var locallyOwnedNpubs: Set<String>? { get }
    func hasEstablishedNoiseSession(with peerID: PeerID) -> Bool
    func triggerHandshake(with peerID: PeerID)
    func privateMediaPeerDidAuthenticate(_ peerID: PeerID)
    /// Retries only private messages previously transmitted through a secure
    /// session and still pending an ack. Both ephemeral and stable aliases
    /// are supplied because either can own the outbox entry.
    func retrySecurePrivateMessagesAfterAuthentication(for peerIDAliases: [PeerID])
    func sendVerifyChallenge(to peerID: PeerID, noiseKeyHex: String, nonceA: Data)
    func sendVerifyResponse(to peerID: PeerID, noiseKeyHex: String, nonceA: Data)

    // MARK: Notifications (shared with `ChatNostrContext`)
    /// Posts a generic local user notification.
    func postLocalNotification(title: String, body: String, identifier: String)
}

extension ChatViewModel: ChatVerificationContext {
    // `getFingerprint(for:)`, `verifiedFingerprints`, `saveIdentityState()`,
    // `updateEncryptionStatus(for:)`, `invalidateEncryptionCache(for:)`,
    // `notifyUIChanged()`, `unifiedPeer(for:)`, `unifiedFingerprint(for:)`,
    // `isVerifiedFingerprint(_:)`, `setEncryptionStatus(_:for:)`,
    // `resolveNickname(for:)`, `cachedStablePeerID(for:)`,
    // `cacheStablePeerID(_:for:)`, `noiseSessionPublicKeyData(for:)`,
    // `hasEstablishedNoiseSession(with:)`, and `triggerHandshake(with:)` are
    // shared requirements with the other contexts or satisfied by existing
    // `ChatViewModel` members. The members below flatten nested service
    // accesses into intent-named calls.

    var isIdentityStateAvailable: Bool { identityManager.isPersistenceAvailable }
    var hasPendingIdentityStateChanges: Bool { identityManager.hasPendingPersistenceChanges }

    func persistedVerifiedFingerprints() -> Set<String> {
        identityManager.getVerifiedFingerprints()
    }

    func setIdentityVerified(fingerprint: String, verified: Bool) {
        identityManager.setVerified(fingerprint: fingerprint, verified: verified)
    }

    func setStoredVerified(_ fingerprint: String, verified: Bool) {
        peerIdentityStore.setVerified(fingerprint, verified: verified)
    }

    func vouchToConnectedVerifiedPeers() {
        vouchCoordinator.vouchToConnectedVerifiedPeers()
    }

    var unifiedPeers: [BitchatPeer] {
        unifiedPeerService.peers
    }

    var unifiedFavorites: [BitchatPeer] {
        unifiedPeerService.favorites
    }

    func installNoiseSessionCallbacks(
        onPeerAuthenticated: @escaping (PeerID, String) -> Void,
        onHandshakeRequired: @escaping (PeerID) -> Void
    ) {
        meshService.installNoiseSessionCallbacks(
            onPeerAuthenticated: onPeerAuthenticated,
            onHandshakeRequired: onHandshakeRequired
        )
    }

    func noiseStaticPublicKeyData() -> Data {
        meshService.noiseStaticPublicKeyData()
    }

    var locallyOwnedNpubs: Set<String>? { try? idBridge.locallyOwnedNpubs() }

    func privateMediaPeerDidAuthenticate(_ peerID: PeerID) {
        mediaTransferCoordinator.peerDidAuthenticate(peerID.toShort())
    }

    func retrySecurePrivateMessagesAfterAuthentication(for peerIDAliases: [PeerID]) {
        messageRouter.retrySecurePrivateMessagesAfterAuthentication(for: peerIDAliases)
    }

    /// QR verification rides the mesh's Noise sessions only.
    private var verifyTransport: MeshVerifying? { meshService as? MeshVerifying }

    func sendVerifyChallenge(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {
        verifyTransport?.sendVerifyChallenge(to: peerID, noiseKeyHex: noiseKeyHex, nonceA: nonceA)
    }

    func sendVerifyResponse(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {
        verifyTransport?.sendVerifyResponse(to: peerID, noiseKeyHex: noiseKeyHex, nonceA: nonceA)
    }

    func postLocalNotification(title: String, body: String, identifier: String) {
        NotificationService.shared.sendLocalNotification(title: title, body: body, identifier: identifier)
    }
}

extension ChatVerificationContext {
    var isIdentityStateAvailable: Bool { true }
    var hasPendingIdentityStateChanges: Bool { false }
    func privateMediaPeerDidAuthenticate(_ peerID: PeerID) {}
}

@MainActor
final class ChatVerificationCoordinator {
    enum QRProgress: Equatable {
        case pending, verified, expired, unavailable, notSaved
    }
    struct PendingVerification {
        let scannedQRBytes: Data
        let noiseKeyHex: String
        let signKeyHex: String
        let nickname: String
        let npub: String?
        let npubSigHex: String?
        let nonceA: Data
        let createdAt: Date
        var sent: Bool
        /// The signed response arrived but the sealed contact write failed.
        var saveFailed = false
    }

    private unowned let context: any ChatVerificationContext
    private let weshMode: Bool
    private let qrTrust: WeshQRTrust
    private let now: () -> Date
    private var pendingQRVerifications: [PeerID: PendingVerification] = [:]
    private var completedQRNonces: [String: Data] = [:]
    private var lastVerifyNonceByPeer: [PeerID: Data] = [:]
    private var lastInboundVerifyChallengeAt: [String: Date] = [:]
    private var lastMutualToastAt: [String: Date] = [:]

    init(context: any ChatVerificationContext, weshMode: Bool = false, qrTrust: WeshQRTrust? = nil,
         now: @escaping () -> Date = Date.init) {
        self.now = now
        self.weshMode = weshMode
        self.qrTrust = qrTrust ?? .shared
        self.context = context
    }

    /// Progress belongs to this scan's challenge, never a previous enrollment.
    func qrProgress(for noiseKey: Data, attemptNonce: Data? = nil) -> QRProgress {
        guard context.isIdentityStateAvailable else { return .unavailable }
        guard noiseKey.count == 32 else { return .unavailable }
        let hex = noiseKey.hexEncodedString().lowercased()
        if let pending = pendingQRVerifications.values.first(where: {
            $0.noiseKeyHex.lowercased() == noiseKey.hexEncodedString().lowercased()
        }) {
            guard attemptNonce == nil || attemptNonce == pending.nonceA else { return .unavailable }
            if pending.saveFailed { return .notSaved }
            return (0...60).contains(now().timeIntervalSince(pending.createdAt)) ? .pending : .expired
        }
        guard !context.hasPendingIdentityStateChanges,
              let completedNonce = completedQRNonces[hex],
              attemptNonce == nil || attemptNonce == completedNonce,
              context.isVerifiedFingerprint(noiseKey.sha256Fingerprint()),
              !weshMode || qrTrust.fingerprints.contains(noiseKey.sha256Fingerprint()) else { return .unavailable }
        return .verified
    }

    func qrAttemptNonce(for noiseKey: Data) -> Data? {
        guard noiseKey.count == 32 else { return nil }
        let hex = noiseKey.hexEncodedString().lowercased()
        return pendingQRVerifications.values.first(where: { $0.noiseKeyHex.lowercased() == hex })?.nonceA
            ?? completedQRNonces[hex]
    }

    /// A removed contact cannot be re-enrolled by a response to an older scan.
    func cancelQRVerification(for noiseKey: Data) {
        guard noiseKey.count == 32 else { return }
        let hex = noiseKey.hexEncodedString().lowercased()
        completedQRNonces.removeValue(forKey: hex)
        for peer in pendingQRVerifications.filter({ $0.value.noiseKeyHex.lowercased() == hex }).keys {
            pendingQRVerifications.removeValue(forKey: peer)
        }
    }

    func cancelAllQRVerifications() {
        pendingQRVerifications.removeAll()
        completedQRNonces.removeAll()
    }

    func verifyFingerprint(for peerID: PeerID) {
        guard context.isIdentityStateAvailable else { return }
        guard let fingerprint = context.getFingerprint(for: peerID) else { return }

        context.setIdentityVerified(fingerprint: fingerprint, verified: true)
        context.saveIdentityState()
        guard context.isIdentityStateAvailable,
              !context.hasPendingIdentityStateChanges else { return }
        context.setStoredVerified(fingerprint, verified: true)
        context.updateEncryptionStatus(for: peerID)
        // Verifying a peer is a vouch trigger: push attestations to my other
        // connected verified peers (and to this one if already connected).
        if !weshMode { context.vouchToConnectedVerifiedPeers() }
    }

    func unverifyFingerprint(for peerID: PeerID) {
        guard context.isIdentityStateAvailable else { return }
        guard let fingerprint = context.getFingerprint(for: peerID) else { return }
        context.setIdentityVerified(fingerprint: fingerprint, verified: false)
        context.saveIdentityState()
        // Revocation is effective locally even when the durable write must retry.
        context.setStoredVerified(fingerprint, verified: false)
        context.updateEncryptionStatus(for: peerID)
    }

    func loadVerifiedFingerprints() {
        context.verifiedFingerprints = context.persistedVerifiedFingerprints()
        let sample = Array(context.verifiedFingerprints.prefix(TransportConfig.uiFingerprintSampleCount))
            .map { $0.prefix(8) }
            .joined(separator: ", ")
        SecureLogger.info("🔐 Verified loaded: \(context.verifiedFingerprints.count) [\(sample)]", category: .security)

        let offlineFavorites = context.unifiedFavorites.filter { !$0.isConnected }
        for favorite in offlineFavorites {
            let fingerprint = context.unifiedFingerprint(for: favorite.peerID)
            let isVerified = fingerprint.flatMap { context.isVerifiedFingerprint($0) } ?? false
            let shortFingerprint = fingerprint?.prefix(8) ?? "nil"
            SecureLogger.info(
                "⭐️ Favorite offline: \(favorite.nickname) fp=\(shortFingerprint) verified=\(isVerified)",
                category: .security
            )
        }

        context.invalidateEncryptionCache(for: nil)
        context.notifyUIChanged()
    }

    func setupNoiseCallbacks() {
        context.installNoiseSessionCallbacks(
            onPeerAuthenticated: { [weak self] peerID, fingerprint in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }

                    SecureLogger.debug("🔐 Authenticated: \(peerID)", category: .security)
                    self.context.privateMediaPeerDidAuthenticate(peerID)

                    if self.context.isVerifiedFingerprint(fingerprint) {
                        self.context.setEncryptionStatus(.noiseVerified, for: peerID)
                    } else {
                        self.context.setEncryptionStatus(.noiseSecured, for: peerID)
                    }

                    self.context.invalidateEncryptionCache(for: peerID)

                    var authenticatedStablePeerID: PeerID?
                    if let keyData = self.context.noiseSessionPublicKeyData(for: peerID) {
                        let stablePeerID = PeerID(hexData: keyData)
                        authenticatedStablePeerID = stablePeerID
                        if self.context.cachedStablePeerID(for: peerID) != stablePeerID {
                            // The freshly authenticated Noise key outranks a
                            // stale announce-derived alias.
                            self.context.cacheStablePeerID(stablePeerID, for: peerID)
                        }
                        SecureLogger.debug(
                            "🗺️ Mapped short peerID to Noise key for header continuity: \(peerID) -> \(stablePeerID.id.prefix(8))…",
                            category: .session
                        )
                    }

                    // A locally established session may have belonged to the
                    // peer's previous app process. The first ciphertext sent
                    // into that stale session is retained by MessageRouter;
                    // retry it now that this newly authenticated/replacement
                    // session can actually decrypt it.
                    var peerIDAliases = [peerID]
                    if let stablePeerID = authenticatedStablePeerID
                        ?? self.context.cachedStablePeerID(for: peerID),
                       stablePeerID != peerID {
                        // Conversations can migrate from the ephemeral BLE ID
                        // to the authenticated Noise-key ID. Retry both aliases
                        // because either may own the retained outbox entry.
                        peerIDAliases.append(stablePeerID)
                    }
                    self.context.retrySecurePrivateMessagesAfterAuthentication(for: peerIDAliases)

                    if var pending = self.pendingQRVerifications[peerID], pending.sent == false {
                        guard (0...60).contains(self.now().timeIntervalSince(pending.createdAt)) else {
                            self.pendingQRVerifications.removeValue(forKey: peerID)
                            return
                        }
                        guard self.context.noiseSessionPublicKeyData(for: peerID)?.hexEncodedString().lowercased() == pending.noiseKeyHex.lowercased() else {
                            self.pendingQRVerifications.removeValue(forKey: peerID)
                            return
                        }
                        self.context.sendVerifyChallenge(
                            to: peerID,
                            noiseKeyHex: pending.noiseKeyHex,
                            nonceA: pending.nonceA
                        )
                        pending.sent = true
                        self.pendingQRVerifications[peerID] = pending
                        SecureLogger.debug("📤 Sent deferred verify challenge to \(peerID) after handshake", category: .security)
                    }
                }
            },
            onHandshakeRequired: { [weak self] peerID in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.context.setEncryptionStatus(.noiseHandshaking, for: peerID)
                    self.context.invalidateEncryptionCache(for: peerID)
                }
            }
        )
    }

    func beginQRVerification(with qr: VerificationService.VerificationQR) -> Bool {
        guard context.isIdentityStateAvailable,
              context.noiseStaticPublicKeyData().count == 32 else { return false }
        let targetNoise = qr.noiseKeyHex.lowercased()
        guard let peer = context.unifiedPeers.first(where: {
            $0.noisePublicKey.hexEncodedString().lowercased() == targetNoise
        }) else {
            return false
        }

        let peerID = peer.peerID
        if let pending = pendingQRVerifications[peerID], !pending.saveFailed,
           pending.scannedQRBytes == qr.canonicalBytes(), pending.npubSigHex == qr.npubSigHex,
           (0...60).contains(now().timeIntervalSince(pending.createdAt)) { return true }
        // Retain the established contact separately; replace only scan progress.
        if let noiseKey = Data(hexString: targetNoise) { cancelQRVerification(for: noiseKey) }

        var nonce = Data(count: 16)
        let status = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { return false }
        var pending = PendingVerification(
            scannedQRBytes: qr.canonicalBytes(),
            noiseKeyHex: qr.noiseKeyHex,
            signKeyHex: qr.signKeyHex,
            nickname: qr.nickname,
            npub: qr.npub,
            npubSigHex: qr.npubSigHex,
            nonceA: nonce,
            createdAt: now(),
            sent: false
        )
        pendingQRVerifications[peerID] = pending

        if context.hasEstablishedNoiseSession(with: peerID) {
            guard context.noiseSessionPublicKeyData(for: peerID)?.hexEncodedString().lowercased() == targetNoise else {
                pendingQRVerifications.removeValue(forKey: peerID)
                return false
            }
            context.sendVerifyChallenge(to: peerID, noiseKeyHex: qr.noiseKeyHex, nonceA: nonce)
            pending.sent = true
            pendingQRVerifications[peerID] = pending
        } else {
            context.triggerHandshake(with: peerID)
        }

        return true
    }

    func handleVerifyChallengePayload(from peerID: PeerID, payload: Data) {
        guard context.noiseStaticPublicKeyData().count == 32,
              let challenge = VerificationService.shared.parseVerifyChallenge(payload) else { return }

        let myNoiseHex = context.noiseStaticPublicKeyData()
            .hexEncodedString()
            .lowercased()
        guard challenge.noiseKeyHex.lowercased() == myNoiseHex else { return }
        guard lastVerifyNonceByPeer[peerID] != challenge.nonceA else { return }

        lastVerifyNonceByPeer[peerID] = challenge.nonceA

        if let fingerprint = context.getFingerprint(for: peerID) {
            lastInboundVerifyChallengeAt[fingerprint] = Date()

            if context.isVerifiedFingerprint(fingerprint) {
                maybeSendMutualVerificationNotification(
                    fingerprint: fingerprint,
                    peerID: peerID,
                    title: "Mutual verification",
                    bodyName: context.unifiedPeer(for: peerID)?.nickname
                        ?? context.resolveNickname(for: peerID),
                    notificationPrefix: "verify-mutual"
                )
            }
        }

        context.sendVerifyResponse(
            to: peerID,
            noiseKeyHex: challenge.noiseKeyHex,
            nonceA: challenge.nonceA
        )
    }

    func handleVerifyResponsePayload(from peerID: PeerID, payload: Data) {
        guard context.isIdentityStateAvailable else { return }
        guard let response = VerificationService.shared.parseVerifyResponse(payload),
              let pending = pendingQRVerifications[peerID],
              response.noiseKeyHex.lowercased() == pending.noiseKeyHex.lowercased(),
              response.nonceA == pending.nonceA else { return }

        guard (0...60).contains(now().timeIntervalSince(pending.createdAt)) else {
            pendingQRVerifications.removeValue(forKey: peerID)
            return
        }
        let isValid = VerificationService.shared.verifyResponseSignature(
            noiseKeyHex: response.noiseKeyHex,
            nonceA: response.nonceA,
            signature: response.signature,
            signerPublicKeyHex: pending.signKeyHex
        )
        guard isValid else { return }

        guard let sessionKey = context.noiseSessionPublicKeyData(for: peerID),
              sessionKey.count == 32, sessionKey.hexEncodedString().lowercased() == pending.noiseKeyHex.lowercased(),
              let fingerprint = context.getFingerprint(for: peerID), fingerprint == sessionKey.sha256Fingerprint() else { return }
        let shortFingerprint = fingerprint.prefix(8)
        SecureLogger.info("🔐 Marking verified fingerprint: \(shortFingerprint)", category: .security)
        context.setIdentityVerified(fingerprint: fingerprint, verified: true)
        context.saveIdentityState()
        guard context.isIdentityStateAvailable,
              !context.hasPendingIdentityStateChanges else { return }
        if weshMode {
            // The Noise challenge just proved the QR signer holds this session.
            let outcome = WeshQRNpub.enrollment(npub: pending.npub, npubSigHex: pending.npubSigHex,
                                                canonicalBytes: pending.scannedQRBytes, noiseKeyHex: pending.noiseKeyHex,
                                                ownedNpubs: context.locallyOwnedNpubs, contacts: qrTrust.contacts)
            // Success is announced only once the contact is confirmed on disk;
            // otherwise this attempt stays open and reports the failure.
            guard qrTrust.enroll(sessionKey: sessionKey, nickname: pending.nickname, outcome: outcome) else {
                var failed = pending
                failed.saveFailed = true
                pendingQRVerifications[peerID] = failed
                return
            }
        }
        pendingQRVerifications.removeValue(forKey: peerID)
        completedQRNonces[pending.noiseKeyHex.lowercased()] = pending.nonceA
        context.setStoredVerified(fingerprint, verified: true)

        let peerName = context.unifiedPeer(for: peerID)?.nickname
            ?? context.resolveNickname(for: peerID)
        context.postLocalNotification(
            title: String(localized: "notification.verified.title", defaultValue: "Contact verified", comment: "Notification title after a contact QR verification succeeds"),
            body: String(
                format: String(localized: "notification.verified.body", defaultValue: "You verified %@", comment: "Notification body after a QR verification; placeholder is the contact nickname"),
                locale: .current, peerName
            ),
            identifier: "verify-success-\(peerID)-\(UUID().uuidString)"
        )

        if let challengeTime = lastInboundVerifyChallengeAt[fingerprint],
           Date().timeIntervalSince(challengeTime) < 600 {
            maybeSendMutualVerificationNotification(
                fingerprint: fingerprint,
                peerID: peerID,
                title: "Mutual verification",
                bodyName: peerName,
                notificationPrefix: "verify-mutual"
            )
        }

        context.updateEncryptionStatus(for: peerID)
        // QR verification just completed — same vouch trigger as manual verify.
        if !weshMode { context.vouchToConnectedVerifiedPeers() }
    }
}

private extension ChatVerificationCoordinator {
    func maybeSendMutualVerificationNotification(
        fingerprint: String,
        peerID: PeerID,
        title: String,
        bodyName: String,
        notificationPrefix: String
    ) {
        guard !weshMode else { return }
        let now = Date()
        let lastToast = lastMutualToastAt[fingerprint] ?? .distantPast
        guard now.timeIntervalSince(lastToast) > 60 else { return }

        lastMutualToastAt[fingerprint] = now
        context.postLocalNotification(
            title: title,
            body: "You and \(bodyName) verified each other",
            identifier: "\(notificationPrefix)-\(peerID)-\(UUID().uuidString)"
        )
    }
}
