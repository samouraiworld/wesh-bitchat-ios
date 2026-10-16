//
// NoiseEncryptionService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

///
/// # NoiseEncryptionService
///
/// High-level encryption service that manages Noise Protocol sessions for secure
/// peer-to-peer communication in BitChat. Acts as the bridge between the transport
/// layer (BLEService) and the cryptographic layer (NoiseProtocol).
///
/// ## Overview
/// This service provides a simplified API for establishing and managing encrypted
/// channels between peers. It handles:
/// - Static identity key management
/// - Session lifecycle (creation, maintenance, teardown)
/// - Message encryption/decryption
/// - Peer authentication and fingerprint tracking
/// - Automatic rekeying for forward secrecy
///
/// ## Architecture
/// The service operates at multiple levels:
/// 1. **Identity Management**: Persistent Curve25519 keys stored in Keychain
/// 2. **Session Management**: Per-peer Noise sessions with state tracking
/// 3. **Message Processing**: Encryption/decryption with proper framing
/// 4. **Security Features**: Rate limiting, fingerprint verification
///
/// ## Key Features
///
/// ### Identity Keys
/// - Static Curve25519 key pair for Noise XX pattern
/// - Ed25519 signing key pair for additional authentication
/// - Keys persisted securely in iOS/macOS Keychain
/// - Fingerprints derived from SHA256 of public keys
///
/// ### Session Management
/// - Lazy session creation (on-demand when sending messages)
/// - Automatic session recovery after disconnections
/// - Configurable rekey intervals for forward secrecy
/// - Graceful handling of simultaneous handshakes
///
/// ### Security Properties
/// - Forward secrecy via ephemeral keys in handshakes
/// - Mutual authentication via static key exchange
/// - Protection against replay attacks
/// - Rate limiting to prevent DoS attacks
///
/// ## Encryption Flow
/// ```
/// 1. Message arrives for encryption
/// 2. Check if session exists for peer
/// 3. If not, initiate Noise handshake
/// 4. Once established, encrypt message
/// 5. Add message type header for protocol handling
/// 6. Return encrypted payload for transmission
/// ```
///
/// ## Integration Points
/// - **BLEService**: Calls this service for all private messages
/// - **ChatViewModel**: Monitors encryption status for UI indicators
/// - **KeychainManager**: Secure storage for identity keys
///
/// ## Thread Safety
/// - Concurrent read access via reader-writer queue
/// - Session operations protected by per-peer queues
/// - Atomic updates for critical state changes
///
/// ## Error Handling
/// - Graceful fallback for encryption failures
/// - Clear error messages for debugging
/// - Automatic retry with exponential backoff
/// - User notification for critical failures
///
/// ## Performance Considerations
/// - Sessions cached in memory for fast access
/// - Minimal allocations in hot paths
/// - Efficient binary message format
/// - Background queue for CPU-intensive operations
///

import BitLogger
import BitFoundation
import Foundation
import CryptoKit

// MARK: - Encryption Status

/// Represents the current encryption status of a peer connection.
/// Used for UI indicators and decision-making about message handling.
enum EncryptionStatus: Equatable {
    case none                // Failed or incompatible
    case noHandshake        // No handshake attempted yet
    case noiseHandshaking   // Currently establishing
    case noiseSecured       // Established but not verified
    case noiseVerified      // Established and verified

    var icon: String? {  // Made optional to hide icon when no handshake
        switch self {
        case .none:
            return "lock.slash"  // Failed handshake
        case .noHandshake:
            return nil  // No icon when no handshake attempted
        case .noiseHandshaking:
            return "lock.rotation"
        case .noiseSecured:
            return "lock.fill"  // Changed from "lock" to "lock.fill" for filled lock
        case .noiseVerified:
            return "checkmark.seal.fill"  // Verified badge
        }
    }
    
    var description: String {
        switch self {
        case .none:
            return String(localized: "encryption.status.failed", comment: "Status text when encryption failed")
        case .noHandshake:
            return String(localized: "encryption.status.not_encrypted", comment: "Status text when no encryption handshake happened")
        case .noiseHandshaking:
            return String(localized: "encryption.status.establishing", comment: "Status text when encryption is being established")
        case .noiseSecured:
            return String(localized: "encryption.status.secured", comment: "Status text when encryption is secured but not verified")
        case .noiseVerified:
            return String(localized: "encryption.status.verified", comment: "Status text when encryption is verified")
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .none:
            return String(localized: "encryption.accessibility.failed", comment: "Accessibility text when encryption failed")
        case .noHandshake:
            return String(localized: "encryption.accessibility.not_encrypted", comment: "Accessibility text when encryption is not established")
        case .noiseHandshaking:
            return String(localized: "encryption.accessibility.establishing", comment: "Accessibility text when encryption is being established")
        case .noiseSecured:
            return String(localized: "encryption.accessibility.secured", comment: "Accessibility text when encryption is secured")
        case .noiseVerified:
            return String(localized: "encryption.accessibility.verified", comment: "Accessibility text when encryption is verified")
        }
    }
}

/// Storage status for the local Noise identity. This never contains key data.
enum NoiseIdentityAvailability: Equatable {
    case available
    case storageUnavailable
    case persistenceUnconfirmed
    case recoveryRequired
    case invalidated
}

// MARK: - Noise Encryption Service

/// Manages end-to-end encryption for BitChat using the Noise Protocol Framework.
/// Provides a high-level API for establishing secure channels between peers,
/// handling all cryptographic operations transparently.
/// - Important: This service maintains the device's cryptographic identity
final class NoiseEncryptionService {
    /// Keys and their manager are published together, only after confirmed storage.
    /// A missing context is unavailable; no temporary identity is constructed.
    private struct IdentityContext {
        let noiseKey: Curve25519.KeyAgreement.PrivateKey
        let signingKey: Curve25519.Signing.PrivateKey
        let sessionManager: NoiseSessionManager
    }
    private struct PendingIdentity {
        let noiseKey: Curve25519.KeyAgreement.PrivateKey
        let signingKey: Curve25519.Signing.PrivateKey

        // Fixed layout: magic (8), schema version (1), Noise private key (32),
        // signing private key (32). No trailing, optional or unknown fields.
        private static let magic = Data("WESHNOIS".utf8)
        private static let version: UInt8 = 1
        var journalData: Data {
            var data = Self.magic
            data.append(Self.version)
            data.append(noiseKey.rawRepresentation)
            data.append(signingKey.rawRepresentation)
            return data
        }
        static func decodeJournal(_ data: Data) -> PendingIdentity? {
            guard data.count == 73 else { return nil }
            let bytes = Array(data) // Normalize indices of any Data slice.
            guard Data(bytes.prefix(8)) == magic, bytes[8] == version,
                  let noise = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(bytes[9..<41])),
                  let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: Data(bytes[41..<73])) else {
                return nil
            }
            return PendingIdentity(noiseKey: noise, signingKey: signing)
        }
    }
    private static let pendingIdentityKey = "noiseIdentityPending.v1"
    private let identityLock = NSLock()
    /// Serializes legacy two-item initialization per backing store. Every
    /// `KeychainManager` reaches the same system Keychain and shares one lock;
    /// any other store (in-memory test or preview keychains) gets its own, so
    /// a slow call on one store never stalls identity setup on another.
    private let persistenceLock: NSLock
    private static let systemKeychainPersistenceLock = NSLock()
    private static let storeLocksGuard = NSLock()
    private static let storeLocks = NSMapTable<AnyObject, NSLock>.weakToStrongObjects()

    private static func persistenceLock(for keychain: KeychainManagerProtocol) -> NSLock {
        if keychain is KeychainManager { return systemKeychainPersistenceLock }
        let store = keychain as AnyObject
        storeLocksGuard.lock()
        defer { storeLocksGuard.unlock() }
        if let lock = storeLocks.object(forKey: store) { return lock }
        let lock = NSLock()
        storeLocks.setObject(lock, forKey: store)
        return lock
    }
    private var context: IdentityContext?
    private var pendingIdentity: PendingIdentity?
    private var identityInvalidated = false
    private var availability: NoiseIdentityAvailability = .storageUnavailable
    private let managerFactory: (Curve25519.KeyAgreement.PrivateKey) -> NoiseSessionManager

    private var identityContext: IdentityContext? {
        identityLock.lock()
        defer { identityLock.unlock() }
        return context
    }
    var isIdentityAvailable: Bool { identityContext != nil }
    var identityAvailability: NoiseIdentityAvailability {
        identityLock.lock()
        defer { identityLock.unlock() }
        return availability
    }
    var staticIdentityPublicKey: Curve25519.KeyAgreement.PublicKey? {
        identityContext?.noiseKey.publicKey
    }
    var signingPublicKey: Curve25519.Signing.PublicKey? {
        identityContext?.signingKey.publicKey
    }
    private func requireIdentity() throws -> IdentityContext {
        guard let identity = identityContext else {
            throw NoiseEncryptionError.identityUnavailable
        }
        return identity
    }

    // Peer fingerprints (SHA256 hash of static public key)
    private var peerFingerprints: [PeerID: String] = [:]
    private var fingerprintToPeerID: [String: PeerID] = [:]
    // Thread safety
    private let serviceQueue = DispatchQueue(label: "chat.bitchat.noise.service", attributes: .concurrent)
    
    // Security components
    private let rateLimiter = NoiseRateLimiter()
    private let keychain: KeychainManagerProtocol

    // One-time prekeys for forward-secret courier sealing (lazy generation
    // inside the store; the batch is minted on first bundle build).
    private let localPrekeys: LocalPrekeyStore
    
    // Session maintenance
    private var rekeyTimer: Timer?
    private let rekeyCheckInterval: TimeInterval = 60.0 // Check every minute
    
    // Callbacks
    private var onPeerAuthenticatedHandlers: [((PeerID, String) -> Void)] = [] // Array of handlers for peer authentication
    private var onPeerAuthenticatedWithGenerationHandlers: [((PeerID, String, UUID) -> Void)] = []
    var onHandshakeRequired: ((PeerID) -> Void)? // peerID needs handshake
    /// Automatic rekey prepared XX message 1. The transport must claim the
    /// exact attempt at its actual BLE handoff; a crossed inbound initiation
    /// can invalidate the token before that point.
    var onRekeyHandshakeReady:
        ((_ peerID: PeerID, _ initiation: NoiseHandshakeInitiation) -> Void)?
    var onHandshakeRecoveryRequired:
        ((_ request: NoiseHandshakeRecoveryRequest) -> Void)?
    /// An unauthenticated reconnect attempt failed or timed out and the
    /// receive-only rollback session became the active transport again.
    /// Transport queues may only be drained for this exact restored
    /// generation when the reason is terminal; a restore that owns a pending
    /// convergence retry must keep them parked until the retry concludes.
    var onSessionRestoredWithGeneration:
        ((_ peerID: PeerID, _ generation: UUID, _ reason: NoiseSessionRestoreReason) -> Void)?
    
    // Add a handler for peer authentication
    func addOnPeerAuthenticatedHandler(_ handler: @escaping (PeerID, String) -> Void) {
        serviceQueue.sync(flags: .barrier) {
            onPeerAuthenticatedHandlers.append(handler)
        }
    }
    
    // Legacy support - setting this will add to the handlers array
    var onPeerAuthenticated: ((PeerID, String) -> Void)? {
        get { nil } // Always return nil for backward compatibility
        set {
            if let handler = newValue {
                addOnPeerAuthenticatedHandler(handler)
            }
        }
    }

    /// Generation-aware authentication notifications are used by protocols
    /// whose state must be bound to one exact Noise transport session.
    var onPeerAuthenticatedWithGeneration: ((PeerID, String, UUID) -> Void)? {
        get { nil }
        set {
            guard let handler = newValue else { return }
            serviceQueue.sync(flags: .barrier) {
                onPeerAuthenticatedWithGenerationHandlers.append(handler)
            }
        }
    }
    
    init(
        keychain: KeychainManagerProtocol,
        ordinaryHandshakeTimeout: TimeInterval =
            NoiseSecurityConstants.ordinaryHandshakeTimeout,
        ordinaryResponderHandshakeTimeout: TimeInterval =
            NoiseSecurityConstants.ordinaryResponderHandshakeTimeout,
        recentInitiatorCompletionGracePeriod: TimeInterval =
            NoiseSecurityConstants.recentInitiatorCompletionGracePeriod,
        ordinaryReconnectRollbackCooldown: TimeInterval =
            NoiseSecurityConstants.ordinaryReconnectRollbackCooldown
    ) {
        self.keychain = keychain
        self.persistenceLock = Self.persistenceLock(for: keychain)
        self.localPrekeys = LocalPrekeyStore(keychain: keychain)

        self.managerFactory = { staticKey in
            NoiseSessionManager(
                localStaticKey: staticKey,
                keychain: keychain,
                ordinaryHandshakeTimeout: ordinaryHandshakeTimeout,
                ordinaryResponderHandshakeTimeout: ordinaryResponderHandshakeTimeout,
                recentInitiatorCompletionGracePeriod: recentInitiatorCompletionGracePeriod,
                ordinaryReconnectRollbackCooldown: ordinaryReconnectRollbackCooldown
            )
        }
        retryIdentityPersistence()
        startRekeyTimer()
    }

    /// Retry protected storage without rotating a usable identity. Fresh pairs
    /// are journaled and read back before either legacy item is written, so a
    /// later process can complete the exact pair. Legacy orphans without that
    /// journal remain preserved for explicit recovery.
    @discardableResult
    func retryIdentityPersistence() -> Bool {
        identityLock.lock()
        defer { identityLock.unlock() }
        guard !identityInvalidated else { return false }
        if context != nil { return true }
        persistenceLock.lock()
        defer { persistenceLock.unlock() }

        var noiseResult = keychain.getIdentityKeyWithResult(forKey: "noiseStaticKey")
        var signingResult = keychain.getIdentityKeyWithResult(forKey: "ed25519SigningKey")
        let journalResult = keychain.getIdentityKeyWithResult(forKey: Self.pendingIdentityKey)
        guard !Self.isReadFailure(noiseResult), !Self.isReadFailure(signingResult),
              !Self.isReadFailure(journalResult) else {
            availability = .storageUnavailable
            return false
        }

        let loaded: PendingIdentity
        let hasJournal: Bool
        switch journalResult {
        case .success(let journal):
            guard let journalIdentity = PendingIdentity.decodeJournal(journal) else {
                availability = .recoveryRequired
                return false
            }
            // An unconfirmed RAM candidate never authorizes replacing a
            // divergent journal. A new instance can inspect the durable state.
            if let pendingIdentity, pendingIdentity.journalData != journal {
                availability = .recoveryRequired
                return false
            }
            loaded = journalIdentity
            hasJournal = true
        case .itemNotFound:
            switch (noiseResult, signingResult) {
            case (.success(let noiseData), .success(let signingData)):
                guard let noise = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: noiseData),
                      let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: signingData) else {
                    availability = .recoveryRequired
                    return false
                }
                loaded = PendingIdentity(noiseKey: noise, signingKey: signing)
                hasJournal = false
            case (.itemNotFound, .itemNotFound):
                let fresh = pendingIdentity ?? PendingIdentity(
                    noiseKey: Curve25519.KeyAgreement.PrivateKey(),
                    signingKey: Curve25519.Signing.PrivateKey()
                )
                pendingIdentity = fresh
                // No legacy writes or public context before exact journal
                // readback, including on a nominal success without storage.
                guard case .success = keychain.saveIdentityKeyWithResult(
                    fresh.journalData, forKey: Self.pendingIdentityKey
                ), case .success(let storedJournal) = keychain.getIdentityKeyWithResult(forKey: Self.pendingIdentityKey),
                      storedJournal == fresh.journalData else {
                    availability = .persistenceUnconfirmed
                    return false
                }
                loaded = fresh
                hasJournal = true
                // Recheck both compatibility items after journal persistence;
                // neither may have changed to a divergent or unreadable value.
                noiseResult = keychain.getIdentityKeyWithResult(forKey: "noiseStaticKey")
                signingResult = keychain.getIdentityKeyWithResult(forKey: "ed25519SigningKey")
            default:
                availability = .recoveryRequired
                return false
            }
        default:
            availability = .storageUnavailable
            return false
        }

        guard !Self.isReadFailure(noiseResult), !Self.isReadFailure(signingResult) else {
            availability = .storageUnavailable
            return false
        }
        guard Self.matchesOrMissing(noiseResult, expected: loaded.noiseKey.rawRepresentation),
              Self.matchesOrMissing(signingResult, expected: loaded.signingKey.rawRepresentation) else {
            availability = .recoveryRequired
            return false
        }
        if let pendingIdentity,
           pendingIdentity.noiseKey.rawRepresentation != loaded.noiseKey.rawRepresentation
            || pendingIdentity.signingKey.rawRepresentation != loaded.signingKey.rawRepresentation {
            availability = .recoveryRequired
            return false
        }
        pendingIdentity = loaded
        if case .itemNotFound = noiseResult {
            guard hasJournal, case .success = keychain.saveIdentityKeyWithResult(
                loaded.noiseKey.rawRepresentation, forKey: "noiseStaticKey"
            ) else {
                availability = .persistenceUnconfirmed
                return false
            }
        }
        if case .itemNotFound = signingResult {
            guard hasJournal, case .success = keychain.saveIdentityKeyWithResult(
                loaded.signingKey.rawRepresentation, forKey: "ed25519SigningKey"
            ) else {
                availability = .persistenceUnconfirmed
                return false
            }
        }
        // Verify both exact values, even after a nominally successful write.
        guard case .success(let noiseReadback) = keychain.getIdentityKeyWithResult(forKey: "noiseStaticKey"),
              noiseReadback == loaded.noiseKey.rawRepresentation,
              case .success(let signingReadback) = keychain.getIdentityKeyWithResult(forKey: "ed25519SigningKey"),
              signingReadback == loaded.signingKey.rawRepresentation else {
            availability = .persistenceUnconfirmed
            return false
        }
        // Both compatibility values are now durable and exact. Cleanup failure
        // may leave a matching journal for next launch; it never grants a write
        // over divergent data or prevents use of the confirmed legacy pair.
        if hasJournal { _ = keychain.deleteIdentityKey(forKey: Self.pendingIdentityKey) }

        let manager = managerFactory(loaded.noiseKey)
        manager.onSessionEstablished = { [weak self, weak manager] peerID, key, generation in
            guard let self, let manager,
                  self.identityContext?.sessionManager === manager else { return }
            self.handleSessionEstablished(peerID: peerID, remoteStaticKey: key, sessionGeneration: generation)
        }
        manager.onSessionRestored = { [weak self, weak manager] peerID, generation, reason in
            guard let self, let manager,
                  self.identityContext?.sessionManager === manager else { return }
            self.onSessionRestoredWithGeneration?(peerID, generation, reason)
        }
        manager.onHandshakeRecoveryRequired = { [weak self, weak manager] request in
            guard let self, let manager,
                  self.identityContext?.sessionManager === manager else { return }
            self.onHandshakeRecoveryRequired?(request)
        }
        context = IdentityContext(noiseKey: loaded.noiseKey, signingKey: loaded.signingKey, sessionManager: manager)
        pendingIdentity = nil
        availability = .available
        return true
    }

    private static func isReadFailure(_ result: KeychainReadResult) -> Bool {
        switch result {
        case .success, .itemNotFound: return false
        default: return true
        }
    }

    private static func matchesOrMissing(_ result: KeychainReadResult, expected: Data) -> Bool {
        switch result {
        case .itemNotFound: return true
        case .success(let data): return data == expected
        default: return false
        }
    }

    // MARK: - Public Interface
    
    /// Get our static public key for sharing
    func getStaticPublicKeyData() -> Data? {
        return staticIdentityPublicKey?.rawRepresentation
    }
    
    /// Get our signing public key for sharing
    func getSigningPublicKeyData() -> Data? {
        return signingPublicKey?.rawRepresentation
    }
    
    /// Get our identity fingerprint
    func getIdentityFingerprint() -> String? {
        staticIdentityPublicKey?.rawRepresentation.sha256Fingerprint()
    }
    
    /// Get peer's public key data
    func getPeerPublicKeyData(_ peerID: PeerID) -> Data? {
        return identityContext?.sessionManager.getRemoteStaticKey(for: peerID)?.rawRepresentation
    }

    // MARK: - Courier Envelopes (one-way Noise X)

    /// Domain separation for courier envelopes so X-pattern transcripts can
    /// never be confused with interactive XX handshakes.
    private static let courierPrologue = Data("bitchat-courier-v1".utf8)

    /// Encrypt a payload to a peer's known static key without an interactive
    /// handshake (Noise X pattern). Used for store-and-forward envelopes
    /// carried by couriers while the recipient is offline.
    /// - Warning: One-way messages have no forward secrecy: a later compromise
    ///   of the recipient's static key exposes envelopes captured in transit.
    ///   Use established sessions whenever the peer is reachable.
    func sealCourierPayload(_ payload: Data, recipientStaticKey: Data) throws -> Data {
        let staticIdentityKey = try requireIdentity().noiseKey
        let remoteKey = try NoiseHandshakeState.validatePublicKey(recipientStaticKey)
        let handshake = NoiseHandshakeState(
            role: .initiator,
            pattern: .X,
            keychain: keychain,
            localStaticKey: staticIdentityKey,
            remoteStaticKey: remoteKey,
            prologue: Self.courierPrologue
        )
        return try handshake.writeMessage(payload: payload)
    }

    /// Decrypt a courier envelope addressed to our static key. Returns the
    /// payload and the sender's authenticated static public key (the `ss`
    /// DH in the X pattern binds the sender's identity to the ciphertext).
    func openCourierPayload(_ envelopeCiphertext: Data) throws -> (payload: Data, senderStaticKey: Data) {
        let staticIdentityKey = try requireIdentity().noiseKey
        let handshake = NoiseHandshakeState(
            role: .responder,
            pattern: .X,
            keychain: keychain,
            localStaticKey: staticIdentityKey,
            prologue: Self.courierPrologue
        )
        let payload = try handshake.readMessage(envelopeCiphertext)
        guard let senderKey = handshake.getRemoteStaticPublicKey() else {
            throw NoiseError.missingKeys
        }
        return (payload: payload, senderStaticKey: senderKey.rawRepresentation)
    }

    // MARK: - One-Time Prekey Envelopes (forward-secret Noise X)

    /// Domain separation for prekey-sealed envelopes: distinct from both the
    /// interactive XX transcripts and static-sealed courier envelopes, and
    /// bound to the specific prekey ID so a ciphertext cannot be replayed
    /// against a different prekey.
    private static let prekeyProloguePrefix = Data("bitchat-prekey-v1".utf8)

    private static func prekeyPrologue(for prekeyID: UInt32) -> Data {
        var prologue = prekeyProloguePrefix
        var big = prekeyID.bigEndian
        withUnsafeBytes(of: &big) { prologue.append(contentsOf: $0) }
        return prologue
    }

    /// Encrypt a payload to one of the recipient's gossiped one-time prekeys
    /// (Noise X where the responder static is the prekey, not the identity
    /// key). Unlike `sealCourierPayload`, this is forward secret: once the
    /// recipient consumes the prekey and its grace window lapses, the private
    /// key is deleted and captured ciphertext becomes undecryptable even if
    /// the recipient's identity key is later compromised. The initiator's
    /// static still rides inside (encrypted), so the recipient authenticates
    /// the sender exactly as with static-sealed envelopes.
    func sealPrekeyPayload(_ payload: Data, recipientPrekey: PrekeyBundle.Prekey) throws -> Data {
        let staticIdentityKey = try requireIdentity().noiseKey
        let remoteKey = try NoiseHandshakeState.validatePublicKey(recipientPrekey.publicKey)
        let handshake = NoiseHandshakeState(
            role: .initiator,
            pattern: .X,
            keychain: keychain,
            localStaticKey: staticIdentityKey,
            remoteStaticKey: remoteKey,
            prologue: Self.prekeyPrologue(for: recipientPrekey.id)
        )
        return try handshake.writeMessage(payload: payload)
    }

    /// Decrypt an envelope sealed to one of our one-time prekeys. On success
    /// the prekey is marked consumed (its private key survives a 48h grace
    /// window for spray-and-wait redeliveries, then is deleted for good).
    /// Returns the payload, the sender's authenticated static key (same
    /// contract as `openCourierPayload`), and whether this open actually
    /// retired the prekey — false for a redelivery of already-consumed mail —
    /// so the caller can re-gossip the shrunken bundle only when it changed.
    func openPrekeyPayload(_ envelopeCiphertext: Data, prekeyID: UInt32) throws -> (payload: Data, senderStaticKey: Data, consumedPrekey: Bool) {
        _ = try requireIdentity()
        guard let prekeyPrivate = localPrekeys.privateKey(for: prekeyID) else {
            throw NoiseEncryptionError.unknownPrekey
        }
        let handshake = NoiseHandshakeState(
            role: .responder,
            pattern: .X,
            keychain: keychain,
            localStaticKey: prekeyPrivate,
            prologue: Self.prekeyPrologue(for: prekeyID)
        )
        let payload = try handshake.readMessage(envelopeCiphertext)
        guard let senderKey = handshake.getRemoteStaticPublicKey() else {
            throw NoiseError.missingKeys
        }
        let consumedPrekey = localPrekeys.markConsumed(prekeyID)
        return (payload: payload, senderStaticKey: senderKey.rawRepresentation, consumedPrekey: consumedPrekey)
    }

    /// Current signed prekey bundle for gossip, minting the initial batch on
    /// first use. Nil only when signing fails.
    func currentPrekeyBundle() -> PrekeyBundle? {
        guard let identity = identityContext else { return nil }
        let (prekeys, generatedAt) = localPrekeys.currentBundlePrekeys()
        guard !prekeys.isEmpty else { return nil }
        let unsigned = PrekeyBundle(
            noiseStaticPublicKey: identity.noiseKey.publicKey.rawRepresentation,
            prekeys: prekeys,
            generatedAt: generatedAt,
            signature: Data(count: PrekeyBundle.signatureLength)
        )
        guard let signature = signData(unsigned.signableBytes()) else { return nil }
        return PrekeyBundle(
            noiseStaticPublicKey: unsigned.noiseStaticPublicKey,
            prekeys: prekeys,
            generatedAt: generatedAt,
            signature: signature
        )
    }

    /// Verify a peer's bundle signature against their announce-bound Ed25519
    /// signing key.
    func verifyPrekeyBundleSignature(_ bundle: PrekeyBundle, signingPublicKey: Data) -> Bool {
        verifySignature(bundle.signature, for: bundle.signableBytes(), publicKey: signingPublicKey)
    }

    /// Prune dead prekeys and top the batch back up when consumption runs it
    /// low. Returns true when the published bundle changed and should be
    /// re-gossiped.
    @discardableResult
    func replenishPrekeysIfNeeded() -> Bool {
        guard isIdentityAvailable else { return false }
        return localPrekeys.replenishIfNeeded()
    }

    /// Clear persistent identity (for panic mode)
    @discardableResult
    func clearPersistentIdentity() -> Bool {
        identityLock.lock()
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        let previous = context
        context = nil
        pendingIdentity = nil
        identityInvalidated = true
        availability = .invalidated
        identityLock.unlock()
        previous?.sessionManager.removeAllSessions()
        // Clear from keychain
        // Attempt every deletion even if one fails. A surviving journal must
        // not authorize resurrecting this invalidated instance after panic.
        let deletedJournal = keychain.deleteIdentityKey(forKey: Self.pendingIdentityKey)
        let deletedStatic = keychain.deleteIdentityKey(forKey: "noiseStaticKey")
        let deletedSigning = keychain.deleteIdentityKey(forKey: "ed25519SigningKey")
        let deletedIdentity = deletedJournal && deletedStatic && deletedSigning
        SecureLogger.logKeyOperation(.delete, keyType: "identity keys", success: deletedIdentity)
        // One-time prekey privates go with the identity they were bound to.
        localPrekeys.wipe()
        SecureLogger.warning(
            deletedIdentity
                ? "Panic mode activated - identity cleared"
                : "Panic mode activated - identity unavailable; persistent cleanup incomplete",
            category: .security
        )
        // Stop rekey timer
        stopRekeyTimer()
        return deletedIdentity
    }
    
    /// Sign data with our Ed25519 signing key
    func signData(_ data: Data) -> Data? {
        guard let signingKey = identityContext?.signingKey else { return nil }
        do {
            let signature = try signingKey.signature(for: data)
            return signature
        } catch {
            SecureLogger.error(error, context: "Failed to sign data")
            return nil
        }
    }
    
    /// Verify signature with a peer's Ed25519 public key
    func verifySignature(_ signature: Data, for data: Data, publicKey: Data) -> Bool {
        do {
            let signingPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
            return signingPublicKey.isValidSignature(signature, for: data)
        } catch {
            SecureLogger.error(error, context: "Failed to verify signature")
            return false
        }
    }

    // MARK: - Announce Signature Helpers

    /// Build the canonical announce binding message bytes and sign with our Ed25519 key
    /// - Parameters:
    ///   - peerID: 8-byte routing ID (as in packet header)
    ///   - noiseKey: 32-byte Curve25519.KeyAgreement public key
    ///   - ed25519Key: 32-byte Ed25519 public key (self)
    ///   - nickname: UTF-8 nickname (<=255 bytes)
    ///   - timestampMs: UInt64 milliseconds since epoch
    /// - Returns: Ed25519 signature over the canonical bytes, or nil on failure
    func buildAnnounceSignature(peerID: Data, noiseKey: Data, ed25519Key: Data, nickname: String, timestampMs: UInt64) -> Data? {
        let message = canonicalAnnounceBytes(peerID: peerID, noiseKey: noiseKey, ed25519Key: ed25519Key, nickname: nickname, timestampMs: timestampMs)
        return signData(message)
    }

    /// Verify an announce signature
    func verifyAnnounceSignature(signature: Data, peerID: Data, noiseKey: Data, ed25519Key: Data, nickname: String, timestampMs: UInt64, publicKey: Data) -> Bool {
        let message = canonicalAnnounceBytes(peerID: peerID, noiseKey: noiseKey, ed25519Key: ed25519Key, nickname: nickname, timestampMs: timestampMs)
        return verifySignature(signature, for: message, publicKey: publicKey)
    }

    /// Build canonical bytes for announce signing.
    private func canonicalAnnounceBytes(peerID: Data, noiseKey: Data, ed25519Key: Data, nickname: String, timestampMs: UInt64) -> Data {
        var out = Data()
        // context
        let context = Data("bitchat-announce-v1".utf8)
        out.append(UInt8(min(context.count, 255)))
        out.append(context.prefix(255))
        // peerID (expect 8 bytes; pad/truncate to 8 for canonicalization)
        let peerID8 = peerID.prefix(8)
        out.append(peerID8)
        if peerID8.count < 8 { out.append(Data(repeating: 0, count: 8 - peerID8.count)) }
        // noise static key (expect 32)
        let noise32 = noiseKey.prefix(32)
        out.append(noise32)
        if noise32.count < 32 { out.append(Data(repeating: 0, count: 32 - noise32.count)) }
        // ed25519 public key (expect 32)
        let ed32 = ed25519Key.prefix(32)
        out.append(ed32)
        if ed32.count < 32 { out.append(Data(repeating: 0, count: 32 - ed32.count)) }
        // nickname length + bytes
        let nickData = Data(nickname.utf8)
        out.append(UInt8(min(nickData.count, 255)))
        out.append(nickData.prefix(255))
        // timestamp
        var ts = timestampMs.bigEndian
        withUnsafeBytes(of: &ts) { raw in out.append(contentsOf: raw) }
        return out
    }
    
    // MARK: - Packet Signing/Verification
    
    /// Sign a BitchatPacket using the noise private key
    func signPacket(_ packet: BitchatPacket) -> BitchatPacket? {
        // Create canonical packet bytes for signing
        guard let packetData = packet.toBinaryDataForSigning() else {
            return nil
        }

        // Sign with the noise private key (converted to Ed25519 for signing)
        guard let signature = signData(packetData) else {
            return nil
        }
        
        // Return new packet with signature
        var signedPacket = packet
        signedPacket.signature = signature
        return signedPacket
    }
    
    /// Verify a BitchatPacket signature using the provided public key
    func verifyPacketSignature(_ packet: BitchatPacket, publicKey: Data) -> Bool {
        guard let signature = packet.signature else {
            return false
        }
        
        // Create canonical packet bytes for verification (without signature)
        
        guard let packetData = packet.toBinaryDataForSigning() else {
            return false
        }
        
        // For noise public keys, we need to derive the Ed25519 key for verification
        // This assumes the noise key can be used for Ed25519 signing
        return verifySignature(signature, for: packetData, publicKey: publicKey)
    }

    
    // MARK: - Handshake Management
    
    /// Initiate a Noise handshake with a peer
    func initiateHandshake(with peerID: PeerID) throws -> Data {
        let sessionManager = try requireIdentity().sessionManager
        
        // Validate peer ID
        guard peerID.isValid else {
            SecureLogger.warning(.authenticationFailed(peerID: peerID.id))
            throw NoiseSecurityError.invalidPeerID
        }
        
        // Check rate limit
        guard rateLimiter.allowHandshake(from: peerID) else {
            SecureLogger.warning(.authenticationFailed(peerID: "Rate limited: \(peerID)"))
            throw NoiseSecurityError.rateLimitExceeded
        }
        
        SecureLogger.info(.handshakeStarted(peerID: peerID.id))
        
        // Return raw handshake data without wrapper
        // The Noise protocol handles its own message format
        let handshakeData = try sessionManager.initiateHandshake(with: peerID)
        return handshakeData
    }

    /// Atomically admits and prepares one initial ordinary handshake. Returns
    /// nil when another discovery callback already created a session.
    func initiateHandshakeIfNeeded(
        with peerID: PeerID,
        retryOnTimeout: Bool = false
    ) throws -> NoiseHandshakeInitiation? {
        let sessionManager = try requireIdentity().sessionManager
        guard peerID.isValid else {
            SecureLogger.warning(.authenticationFailed(peerID: peerID.id))
            throw NoiseSecurityError.invalidPeerID
        }

        guard let initiation = try sessionManager.initiateHandshakeIfAbsent(
            with: peerID,
            notifyOnTimeout: retryOnTimeout,
            authorize: { [rateLimiter] in
                guard rateLimiter.allowHandshake(from: peerID) else {
                    SecureLogger.warning(
                        .authenticationFailed(peerID: "Rate limited: \(peerID)")
                    )
                    throw NoiseSecurityError.rateLimitExceeded
                }
            }
        ) else {
            return nil
        }
        SecureLogger.info(.handshakeStarted(peerID: peerID.id))
        return initiation
    }

    /// Atomically prepares an ordinary reconnect for a peer whose cached
    /// transport belongs to an earlier physical link. Failed authorization or
    /// handshake setup preserves the established session.
    func initiateReconnectHandshake(
        with peerID: PeerID,
        retryOnTimeout: Bool = false
    ) throws -> NoiseHandshakeInitiation {
        let sessionManager = try requireIdentity().sessionManager
        guard peerID.isValid else {
            SecureLogger.warning(.authenticationFailed(peerID: peerID.id))
            throw NoiseSecurityError.invalidPeerID
        }

        return try sessionManager.initiateReconnectHandshake(
            with: peerID,
            notifyOnTimeout: retryOnTimeout,
            authorize: { [rateLimiter] in
                guard rateLimiter.allowHandshake(from: peerID) else {
                    SecureLogger.warning(
                        .authenticationFailed(peerID: "Rate limited: \(peerID)")
                    )
                    throw NoiseSecurityError.rateLimitExceeded
                }
            }
        )
    }

    func prepareHandshakeRecovery(
        _ request: NoiseHandshakeRecoveryRequest
    ) throws -> NoiseHandshakeRecoveryPreparation? {
        let sessionManager = try requireIdentity().sessionManager
        return try sessionManager.prepareHandshakeRecovery(
            request,
            authorizeAttempt: { [rateLimiter] in
                guard rateLimiter.allowHandshake(from: request.peerID) else {
                    SecureLogger.warning(
                        .authenticationFailed(
                            peerID: "Rate limited: \(request.peerID)"
                        )
                    )
                    throw NoiseSecurityError.rateLimitExceeded
                }
            }
        )
    }

    func cancelHandshakeRecovery(_ request: NoiseHandshakeRecoveryRequest) {
        identityContext?.sessionManager.cancelHandshakeRecovery(request)
    }

    func claimHandshakeInitiation(
        _ initiation: NoiseHandshakeInitiation,
        for peerID: PeerID
    ) -> Data? {
        identityContext?.sessionManager.claimHandshakeInitiation(initiation, for: peerID)
    }
    
    /// Process an incoming handshake message
    func processHandshakeMessage(from peerID: PeerID, message: Data) throws -> Data? {
        try processHandshakeMessageWithResult(
            from: peerID,
            message: message
        ).response
    }

    /// Process an incoming handshake message and report whether the exact
    /// session that consumed it completed authenticated establishment.
    func processHandshakeMessageWithResult(
        from peerID: PeerID,
        message: Data
    ) throws -> NoiseHandshakeProcessingResult {
        let sessionManager = try requireIdentity().sessionManager
        
        // Validate peer ID
        guard peerID.isValid else {
            SecureLogger.warning(.authenticationFailed(peerID: peerID.id))
            throw NoiseSecurityError.invalidPeerID
        }
        
        // Validate message size
        guard NoiseSecurityValidator.validateHandshakeMessageSize(message) else {
            SecureLogger.warning(.handshakeFailed(peerID: peerID.id, error: "Message too large"))
            throw NoiseSecurityError.messageTooLarge
        }
        
        // Check rate limit
        guard rateLimiter.allowHandshake(from: peerID) else {
            SecureLogger.warning(.authenticationFailed(peerID: "Rate limited: \(peerID)"))
            throw NoiseSecurityError.rateLimitExceeded
        }
        
        // For handshakes, we process the raw data directly without NoiseMessage wrapper
        // The Noise protocol handles its own message format
        let result = try sessionManager.handleIncomingHandshakeWithResult(
            from: peerID,
            message: message
        )
        
        
        // Return raw response without wrapper
        return result
    }
    
    /// Check if we have an established session with a peer
    func hasEstablishedSession(with peerID: PeerID) -> Bool {
        return identityContext?.sessionManager.getSession(for: peerID)?.isEstablished() ?? false
    }
    
    /// Check if we have a session (established or handshaking) with a peer
    func hasSession(with peerID: PeerID) -> Bool {
        return identityContext?.sessionManager.getSession(for: peerID) != nil
    }

    /// True while an inbound ordinary XX responder is waiting for message 3.
    /// A small amount of immediately-following ciphertext may arrive first
    /// over BLE and must be retried only after responder promotion.
    func isAwaitingResponderHandshakeCompletion(with peerID: PeerID) -> Bool {
        identityContext?.sessionManager.isAwaitingResponderHandshakeCompletion(for: peerID) ?? false
    }
    
    // MARK: - Encryption/Decryption
    
    /// Encrypt data for a specific peer
    func encrypt(_ data: Data, for peerID: PeerID) throws -> Data {
        let sessionManager = try requireIdentity().sessionManager
        // Validate message size
        guard NoiseSecurityValidator.validateMessageSize(data) else {
            throw NoiseSecurityError.messageTooLarge
        }
        
        // Check rate limit
        guard rateLimiter.allowMessage(from: peerID) else {
            throw NoiseSecurityError.rateLimitExceeded
        }
        
        // Check if we have an established session
        guard hasEstablishedSession(with: peerID) else {
            // Signal that handshake is needed
            onHandshakeRequired?(peerID)
            throw NoiseEncryptionError.handshakeRequired
        }
        
        return try sessionManager.encrypt(data, for: peerID)
    }

    /// Encrypts a finalized private-media packet. Ordinary Noise application
    /// messages retain the 64 KiB ceiling; this purpose-specific path permits
    /// the bounded `BitchatFilePacket` envelope and refuses every other typed
    /// payload so the larger allocation budget cannot become a generic bypass.
    func encryptPrivateFilePayload(
        _ data: Data,
        for peerID: PeerID,
        sessionGeneration: UUID? = nil
    ) throws -> Data {
        let sessionManager = try requireIdentity().sessionManager
        guard NoisePayloadType.isPrivateFile(rawValue: data.first),
              NoiseSecurityValidator.validatePrivateFileMessageSize(data) else {
            throw NoiseSecurityError.messageTooLarge
        }

        guard rateLimiter.allowMessage(from: peerID) else {
            throw NoiseSecurityError.rateLimitExceeded
        }

        guard hasEstablishedSession(with: peerID) else {
            onHandshakeRequired?(peerID)
            throw NoiseEncryptionError.handshakeRequired
        }

        // `maxPrivateFilePlaintextSize` already subtracts the cipher's fixed
        // nonce/tag overhead, so the result is bounded without a second copy.
        if let sessionGeneration {
            return try sessionManager.encrypt(
                data,
                for: peerID,
                expectedSessionGeneration: sessionGeneration
            )
        }
        return try sessionManager.encrypt(data, for: peerID)
    }

    /// Decrypt data from a specific peer
    func decrypt(_ data: Data, from peerID: PeerID) throws -> Data {
        try decryptWithSessionGeneration(data, from: peerID).plaintext
    }

    func decryptWithSessionGeneration(
        _ data: Data,
        from peerID: PeerID,
        establishedGenerationIsReady: (UUID) -> Bool = { _ in true }
    ) throws -> (plaintext: Data, sessionGeneration: UUID) {
        let sessionManager = try requireIdentity().sessionManager
        // Standard transport ciphertext has 20 bytes of nonce/tag overhead.
        // A larger ciphertext is admitted only up to the framed-file ceiling;
        // after authenticated decryption it must prove it is `.privateFile`.
        let isStandardCiphertext = NoiseSecurityValidator.validateCiphertextSize(data)
        let isAdmittedCiphertext = isStandardCiphertext
            || NoiseSecurityValidator.validatePrivateFileCiphertextSize(data)

        // A quarantined transport is deliberately unavailable for outbound
        // state, but remains receive-only until the responder proves identity
        // or the bounded rollback restores it.
        guard sessionManager.hasReceiveSession(for: peerID) else {
            throw NoiseEncryptionError.sessionNotEstablished
        }
        
        let result = try sessionManager.decryptWithSessionGeneration(
            data,
            from: peerID,
            establishedGenerationIsReady:
                establishedGenerationIsReady,
            authorizeDecrypt: { [rateLimiter] in
                guard isAdmittedCiphertext else {
                    throw NoiseSecurityError.messageTooLarge
                }
                guard rateLimiter.allowMessage(from: peerID) else {
                    throw NoiseSecurityError.rateLimitExceeded
                }
            }
        )
        if !isStandardCiphertext {
            guard NoisePayloadType.isPrivateFile(rawValue: result.plaintext.first),
                  NoiseSecurityValidator.validatePrivateFileMessageSize(result.plaintext) else {
                throw NoiseSecurityError.messageTooLarge
            }
        }
        return result
    }
    
    // MARK: - Peer Management
    
    /// Get fingerprint for a peer
    func getPeerFingerprint(_ peerID: PeerID) -> String? {
        return serviceQueue.sync {
            return peerFingerprints[peerID]
        }
    }

    func sessionGeneration(for peerID: PeerID) -> UUID? {
        identityContext?.sessionManager.sessionGeneration(for: peerID)
    }

    /// Runs `body` while holding a read lease on the exact session generation.
    /// Session insertion, replacement, and removal use the same manager
    /// barrier, so they cannot interleave with an authenticated-state commit.
    func withCurrentSessionGeneration<Result>(
        for peerID: PeerID,
        expected: UUID,
        _ body: () -> Result
    ) -> Result? {
        identityContext?.sessionManager.withCurrentSessionGeneration(
            for: peerID,
            expected: expected,
            body
        )
    }

    func clearEphemeralStateForPanic() {
        identityContext?.sessionManager.removeAllSessions()
        serviceQueue.sync(flags: .barrier) {
            peerFingerprints.removeAll()
            fingerprintToPeerID.removeAll()
        }
        rateLimiter.resetAll()
    }

    /// Clear session for a specific peer (e.g., on decryption failure to allow re-handshake)
    func clearSession(for peerID: PeerID) {
        identityContext?.sessionManager.removeSession(for: peerID)
        serviceQueue.sync(flags: .barrier) {
            if let fingerprint = peerFingerprints.removeValue(forKey: peerID) {
                fingerprintToPeerID.removeValue(forKey: fingerprint)
            }
        }
        SecureLogger.debug("🔓 Cleared Noise session for \(peerID)", category: .session)
    }
    
    // MARK: - Private Helpers
    
    private func handleSessionEstablished(
        peerID: PeerID,
        remoteStaticKey: Curve25519.KeyAgreement.PublicKey,
        sessionGeneration: UUID
    ) {
        // Calculate fingerprint
        let fingerprint = remoteStaticKey.rawRepresentation.sha256Fingerprint()
        
        // Registering handlers is synchronous, and this barrier snapshots them
        // with the fingerprint update. Invoke the snapshot outside the queue:
        // parallel Swift Testing workers must not block behind queued callback
        // registration or allow a handler to re-enter serviceQueue.
        let handlers: (
            generationAware: [(PeerID, String, UUID) -> Void],
            legacy: [(PeerID, String) -> Void]
        ) = serviceQueue.sync(flags: .barrier) {
            peerFingerprints[peerID] = fingerprint
            fingerprintToPeerID[fingerprint] = peerID
            return (onPeerAuthenticatedWithGenerationHandlers, onPeerAuthenticatedHandlers)
        }
        
        // Log security event
        SecureLogger.info(.handshakeCompleted(peerID: peerID.id))
        
        // Notify all handlers about authentication.
        handlers.generationAware.forEach { handler in
            handler(peerID, fingerprint, sessionGeneration)
        }
        handlers.legacy.forEach { handler in
            handler(peerID, fingerprint)
        }
    }
        
    // MARK: - Session Maintenance
    
    private func startRekeyTimer() {
        rekeyTimer = Timer.scheduledTimer(withTimeInterval: rekeyCheckInterval, repeats: true) { [weak self] _ in
            self?.checkSessionsForRekey()
        }
    }
    
    private func stopRekeyTimer() {
        rekeyTimer?.invalidate()
        rekeyTimer = nil
    }
    
    private func checkSessionsForRekey() {
        let sessionsNeedingRekey = identityContext?.sessionManager.getSessionsNeedingRekey() ?? []
        
        for (peerID, needsRekey) in sessionsNeedingRekey where needsRekey {
            do {
                try initiateAutomaticRekey(for: peerID)
            } catch {
                SecureLogger.error(error, context: "Failed to initiate rekey for peer: \(peerID)", category: .session)
            }
        }
    }

    private func initiateAutomaticRekey(for peerID: PeerID) throws {
        let sessionManager = try requireIdentity().sessionManager
        let initiation = try sessionManager.initiateRekey(for: peerID)
        SecureLogger.debug("Key rotation initiated for peer: \(peerID)", category: .security)
        onRekeyHandshakeReady?(peerID, initiation)
        onHandshakeRequired?(peerID)
    }

    #if DEBUG
    func _test_initiateAutomaticRekey(for peerID: PeerID) throws {
        try initiateAutomaticRekey(for: peerID)
    }

    func _test_fireSuppressedInitiationRecovery(for peerID: PeerID) {
        identityContext?.sessionManager._test_fireSuppressedInitiationRecovery(for: peerID)
    }
    #endif
    
    deinit {
        stopRekeyTimer()
    }
}

// MARK: - Protocol Message Types for Noise

/// Message types for the Noise encryption protocol layer.
/// These types wrap the underlying BitChat protocol messages with encryption metadata.
enum NoiseMessageType: UInt8 {
    case handshakeInitiation = 0x10
    case handshakeResponse = 0x11
    case handshakeFinal = 0x12
    case encryptedMessage = 0x13
    case sessionRenegotiation = 0x14
}

// MARK: - Noise Message Wrapper

/// Container for encrypted messages in the Noise protocol.
/// Provides versioning and type information for proper message handling.
/// The actual message content is encrypted in the payload field.
struct NoiseMessage: Codable {
    let type: UInt8
    let sessionID: String  // Random ID for this handshake session
    let payload: Data
    
    init(type: NoiseMessageType, sessionID: String, payload: Data) {
        self.type = type.rawValue
        self.sessionID = sessionID
        self.payload = payload
    }
    
    func encode() -> Data? {
        do {
            let encoded = try JSONEncoder().encode(self)
            return encoded
        } catch {
            return nil
        }
    }
    
    static func decode(from data: Data) -> NoiseMessage? {
        return try? JSONDecoder().decode(NoiseMessage.self, from: data)
    }
    
    static func decodeWithError(from data: Data) -> NoiseMessage? {
        do {
            let decoded = try JSONDecoder().decode(NoiseMessage.self, from: data)
            return decoded
        } catch {
            return nil
        }
    }
    
    // MARK: - Binary Encoding
    
    func toBinaryData() -> Data {
        var data = Data()
        data.appendUInt8(type)
        data.appendUUID(sessionID)
        data.appendData(payload)
        return data
    }
    
    static func fromBinaryData(_ data: Data) -> NoiseMessage? {
        // Create defensive copy
        let dataCopy = Data(data)
        
        var offset = 0
        
        guard let type = dataCopy.readUInt8(at: &offset),
              let sessionID = dataCopy.readUUID(at: &offset),
              let payload = dataCopy.readData(at: &offset) else { return nil }
        
        guard let messageType = NoiseMessageType(rawValue: type) else { return nil }
        
        return NoiseMessage(type: messageType, sessionID: sessionID, payload: payload)
    }
}

// MARK: - Errors

enum NoiseEncryptionError: Error, Equatable {
    case identityUnavailable
    case handshakeRequired
    case sessionNotEstablished
    /// Manager keys are established or restored, but BLE has not installed
    /// generation-bound transport state. No receive nonce was consumed.
    case transportGenerationNotReady
    /// Envelope references a prekey ID we don't hold (never ours, already
    /// deleted after its grace window, or wiped in a panic).
    case unknownPrekey
}
