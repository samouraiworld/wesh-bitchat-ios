//
// SecureIdentityStateManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

///
/// # SecureIdentityStateManager
///
/// Manages the persistent storage and retrieval of identity mappings with
/// encryption at rest. This singleton service maintains the relationship between
/// ephemeral peer IDs, cryptographic fingerprints, and social identities.
///
/// ## Overview
/// The SecureIdentityStateManager provides a secure, privacy-preserving way to
/// maintain identity relationships across app launches. It implements:
/// - Encrypted storage of identity mappings
/// - In-memory caching for performance
/// - Thread-safe access patterns
/// - Automatic debounced persistence
///
/// ## Architecture
/// The manager operates at three levels:
/// 1. **In-Memory State**: Fast access to active identities
/// 2. **Encrypted Cache**: Persistent storage in Keychain
/// 3. **Privacy Controls**: User-configurable persistence settings
///
/// ## Security Features
///
/// ### Encryption at Rest
/// - Identity cache encrypted with AES-GCM
/// - Unique 256-bit encryption key per device
/// - Key stored separately in Keychain
/// - No plaintext identity data on disk
///
/// ### Privacy by Design
/// - Persistence is optional (user-controlled)
/// - Minimal data retention
/// - No cloud sync or backup
/// - Automatic cleanup of stale entries
///
/// ### Thread Safety
/// - Concurrent read access via GCD barriers
/// - Write operations serialized
/// - Atomic state updates
/// - No data races or corruption
///
/// ## Data Model
/// Manages three types of identity data:
/// 1. **Ephemeral Sessions**: Current peer connections
/// 2. **Cryptographic Identities**: Public keys and fingerprints
/// 3. **Social Identities**: User-assigned names and trust
///
/// ## Persistence Strategy
/// - Changes batched and debounced (2-second window)
/// - Automatic save on app termination
/// - Crash-resistant with atomic writes
/// - Migration support for schema changes
///
/// ## Usage Patterns
/// ```swift
/// // Register a new peer identity
/// manager.registerPeerIdentity(peerID, publicKey, fingerprint)
/// 
/// // Update social identity
/// manager.updateSocialIdentity(fingerprint, nickname, trustLevel)
/// 
/// // Query identity
/// let identity = manager.resolvePeerIdentity(peerID)
/// ```
///
/// ## Performance Optimizations
/// - In-memory cache eliminates Keychain roundtrips
/// - Debounced saves reduce I/O operations
/// - Efficient data structures for lookups
/// - Background queue for expensive operations
///
/// ## Privacy Considerations
/// - Users can disable all persistence
/// - Identity cache can be wiped instantly
/// - No analytics or telemetry
/// - Ephemeral mode for high-risk users
///
/// ## Future Enhancements
/// - Selective identity export
/// - Cross-device identity sync (optional)
/// - Identity attestation support
/// - Advanced conflict resolution
///

import BitLogger
import BitFoundation
import Foundation
import CryptoKit

protocol SecureIdentityStateManagerProtocol {
    // MARK: Secure Loading/Saving
    var isPersistenceAvailable: Bool { get }
    var hasPendingPersistenceChanges: Bool { get }
    func forceSave()
    
    // MARK: Social Identity Management
    func getSocialIdentity(for fingerprint: String) -> SocialIdentity?
    
    // MARK: Cryptographic Identities
    func upsertCryptographicIdentity(fingerprint: String, noisePublicKey: Data, signingPublicKey: Data?, claimedNickname: String?)
    func getCryptoIdentitiesByPeerIDPrefix(_ peerID: PeerID) -> [CryptographicIdentity]
    func updateSocialIdentity(_ identity: SocialIdentity)
    
    // MARK: Favorites Management
    func isFavorite(fingerprint: String) -> Bool
    
    // MARK: Blocked Users Management
    func isBlocked(fingerprint: String) -> Bool
    func setBlocked(_ fingerprint: String, isBlocked: Bool)
    func getBlockedFingerprints() -> Set<String>
    
    // MARK: Geohash (Nostr) Blocking
    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool
    func setNostrBlocked(_ pubkeyHexLowercased: String, isBlocked: Bool)
    func getBlockedNostrPubkeys() -> Set<String>
    
    // MARK: Ephemeral Session Management
    func registerEphemeralSession(peerID: PeerID, handshakeState: HandshakeState)

    // MARK: Cleanup
    func clearAllIdentityData()
    func removeEphemeralSession(peerID: PeerID)
    
    // MARK: Verification
    func setVerified(fingerprint: String, verified: Bool)
    func isVerified(fingerprint: String) -> Bool
    func getVerifiedFingerprints() -> Set<String>

    // MARK: Vouching (transitive verification)
    @discardableResult
    func recordVouch(voucheeFingerprint: String, voucherFingerprint: String, timestamp: Date) -> Bool
    func validVouchers(for fingerprint: String) -> [VouchRecord]
    func isVouched(fingerprint: String) -> Bool
    func lastVouchBatchSent(to fingerprint: String) -> Date?
    func markVouchBatchSent(to fingerprint: String, at date: Date)
    func signingPublicKey(forFingerprint fingerprint: String) -> Data?
    func mostRecentlyVerifiedFingerprints(limit: Int, excluding fingerprint: String) -> [String]

    // MARK: Noise-authenticated announcement identity
    func bindAuthenticatedSigningPublicKey(_ signingPublicKey: Data, fingerprint: String)
    func authenticatedSigningPublicKey(forFingerprint fingerprint: String) -> Data?

    // MARK: Private-media downgrade protection
    func markPrivateMediaCapable(fingerprint: String)
    func hasObservedPrivateMediaCapability(fingerprint: String) -> Bool
}

extension SecureIdentityStateManagerProtocol {
    var isPersistenceAvailable: Bool { true }
    var hasPendingPersistenceChanges: Bool { false }
}

/// Singleton manager for secure identity state persistence and retrieval.
/// Provides thread-safe access to identity mappings with encryption at rest.
/// All identity data is stored encrypted in the device Keychain for security.
final class SecureIdentityStateManager: SecureIdentityStateManagerProtocol {
    private let keychain: KeychainManagerProtocol
    private let cacheKey = "bitchat.identityCache.v2"
    private let encryptionKeyName = "identityCacheEncryptionKey"
    
    // In-memory state
    private var ephemeralSessions: [PeerID: EphemeralIdentity] = [:]
    // Cryptographic identities (including pinned signing keys) live inside
    // `cache` so they persist across app restarts; see IdentityCache.
    private var cache: IdentityCache = IdentityCache()
    
    // Thread safety
    private let queue = DispatchQueue(label: "bitchat.identity.state", attributes: .concurrent)
    private let queueSpecificKey = DispatchSpecificKey<UInt8>()
    
    // All persistence state is serialized on `queue`. Failed writes stay dirty
    // for forceSave(); each mutation persists inline under its barrier.
    private var pendingSave = false
    private var encryptionKey: SymmetricKey?
    private var cacheIsLoaded = false

    /// False while the persisted key/cache cannot be read or decoded. Persistent
    /// mutations are refused until forceSave() successfully retries the load.
    /// Getters cannot represent unavailable data in the legacy protocol; callers
    /// that need to distinguish it from an empty cache can inspect this state.
    var isPersistenceAvailable: Bool {
        queue.sync { cacheIsLoaded }
    }

    /// A loaded RAM snapshot includes changes whose write/readback failed.
    /// Callers must not announce durable success until this becomes false.
    var hasPendingPersistenceChanges: Bool {
        queue.sync { pendingSave }
    }

    init(_ keychain: KeychainManagerProtocol) {
        self.keychain = keychain
        queue.setSpecific(key: queueSpecificKey, value: 1)
        loadIdentityCache()
    }

    deinit {
        // Do NOT dispatch onto `queue` here. `deinit` can run on any thread
        // (including one draining `queue`), and the object is being
        // deallocated: a `queue.sync` risks a re-entrant same-queue wait
        // (deadlock) and a `queue.async` schedules work that resurrects `self`
        // and may not drain before process exit.
        //
        // Retry only an unconfirmed inline save as a queue-free best effort.
        // A failed final retry cannot promise durability after process exit.
        // This is a direct read of
        // in-hand state — safe because a deallocating object has no other
        // live references, so nothing can be mutating `cache` concurrently.
        if pendingSave {
            pendingSave = false
            persist(snapshot: cache)
        }
    }
    
    // MARK: - Secure Loading/Saving
    
    /// Called during init or under the queue's exclusive barrier. Unknown or
    /// malformed storage is preserved for recovery, never treated as first use.
    private func loadIdentityCache() {
        if encryptionKey == nil {
            switch keychain.getIdentityKeyWithResult(forKey: encryptionKeyName) {
            case .success(let data):
                guard data.count == 32 else {
                    SecureLogger.warning("Invalid identity cache encryption key; persistence unavailable", category: .security)
                    return
                }
                encryptionKey = SymmetricKey(data: data)
            case .itemNotFound:
                // A cache without its key is a partial/lost state, not first
                // use. An unreadable cache cannot establish first use either.
                guard case .itemNotFound = keychain.getIdentityKeyWithResult(forKey: cacheKey) else {
                    SecureLogger.warning("Identity cache key missing without confirmed empty storage; preserving cache", category: .security)
                    return
                }
                let newKey = SymmetricKey(size: .bits256)
                let data = newKey.withUnsafeBytes { Data($0) }
                guard case .success = keychain.saveIdentityKeyWithResult(data, forKey: encryptionKeyName),
                      case .success(let stored) = keychain.getIdentityKeyWithResult(forKey: encryptionKeyName),
                      stored == data else {
                    SecureLogger.warning("Identity cache encryption key not confirmed in storage; persistence unavailable", category: .security)
                    return
                }
                encryptionKey = newKey
            case .deviceLocked, .authenticationFailed, .accessDenied, .otherError:
                SecureLogger.warning("Identity cache encryption key unavailable; persistence deferred", category: .security)
                return
            }
        }
        guard let encryptionKey else { return }

        switch keychain.getIdentityKeyWithResult(forKey: cacheKey) {
        case .itemNotFound:
            cache = IdentityCache()
            cacheIsLoaded = true
        case .success(let encryptedData):
            do {
                let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
                let decryptedData = try AES.GCM.open(sealedBox, using: encryptionKey)
                let loaded = try JSONDecoder().decode(IdentityCache.self, from: decryptedData)
                cache = loaded
                cacheIsLoaded = true
            } catch {
                SecureLogger.warning("Unreadable identity cache preserved; persistence unavailable", category: .security)
            }
        case .deviceLocked, .authenticationFailed, .accessDenied, .otherError:
            SecureLogger.warning("Identity cache unavailable; persistence deferred", category: .security)
        }
    }

    private func saveIdentityCache() {
        pendingSave = true
        pendingSave = !persist(snapshot: cache)
    }

    /// Call only with a consistent snapshot under the barrier, or during deinit.
    /// The legacy Keychain writer is not transactional; retain the RAM snapshot
    /// until a successful write and exact readback so lifecycle flushes can retry.
    @discardableResult
    private func persist(snapshot: IdentityCache) -> Bool {
        guard cacheIsLoaded, let encryptionKey else { return false }
        do {
            let data = try JSONEncoder().encode(snapshot)
            let sealedBox = try AES.GCM.seal(data, using: encryptionKey)
            guard let encryptedData = sealedBox.combined,
                  case .success = keychain.saveIdentityKeyWithResult(encryptedData, forKey: cacheKey),
                  case .success(let stored) = keychain.getIdentityKeyWithResult(forKey: cacheKey),
                  stored == encryptedData else {
                SecureLogger.warning("Identity cache write not confirmed; retaining pending changes for retry", category: .security)
                return false
            }
            return true
        } catch {
            SecureLogger.error(error, context: "Failed to save identity cache", category: .security)
            return false
        }
    }

    /// Retries an unavailable initial load, or an unconfirmed write. Mutations
    /// refused while loading was unavailable must be requested again after load.
    func forceSave() {
        queue.sync(flags: .barrier) {
            guard self.cacheIsLoaded else {
                self.loadIdentityCache()
                return
            }
            guard self.pendingSave else { return }
            self.pendingSave = !self.persist(snapshot: self.cache)
        }
    }

    // MARK: - Social Identity Management
    
    func getSocialIdentity(for fingerprint: String) -> SocialIdentity? {
        queue.sync {
            guard cacheIsLoaded else { return nil }
            var identity = cache.socialIdentities[fingerprint]
            if pendingSave { identity?.trustLevel = .unknown }
            return identity
        }
    }

    // MARK: - Cryptographic Identities

    /// Insert or update a cryptographic identity and optionally persist its signing key and claimed nickname.
    ///
    /// TOFU signing-key pinning: once a signing key has been persisted for a
    /// fingerprint, an update carrying a *different* signing key is refused in
    /// full (including the claimed-nickname update) and security-logged. This
    /// mirrors `BLEPeerRegistry.upsertVerifiedAnnounce` — without it, an
    /// attacker replaying a victim's noiseKey/peerID with their own signing
    /// key could overwrite the victim's persisted identity while the victim is
    /// offline or after an app restart. The refusal is permanent: there is
    /// currently no targeted in-app way to reset the pin (`setVerified` does
    /// not touch it). Recovering from a legitimate signing re-key requires the
    /// peer to establish a new noise identity (new peerID) or the local user
    /// to wipe all identity data (`clearAllIdentityData`, e.g. panic wipe).
    /// - Parameters:
    ///   - fingerprint: SHA-256 hex of the Noise static public key
    ///   - noisePublicKey: Noise static public key data
    ///   - signingPublicKey: Optional Ed25519 signing public key for authenticating public messages
    ///   - claimedNickname: Optional latest claimed nickname to persist into social identity
    func upsertCryptographicIdentity(fingerprint: String, noisePublicKey: Data, signingPublicKey: Data?, claimedNickname: String? = nil) {
        queue.sync(flags: .barrier) {
            guard self.cacheIsLoaded else { return }
            let now = Date()
            if var existing = self.cache.cryptographicIdentities[fingerprint] {
                if let pinnedSigningKey = existing.signingPublicKey,
                   let announcedSigningKey = signingPublicKey,
                   pinnedSigningKey != announcedSigningKey {
                    SecureLogger.warning("🚨 Refusing to replace pinned signing key for \(fingerprint.prefix(8))… (possible impersonation attempt)", category: .security)
                    return
                }
                // Update keys if changed
                if existing.publicKey != noisePublicKey {
                    existing = CryptographicIdentity(
                        fingerprint: fingerprint,
                        publicKey: noisePublicKey,
                        signingPublicKey: signingPublicKey ?? existing.signingPublicKey,
                        firstSeen: existing.firstSeen
                    )
                    self.cache.cryptographicIdentities[fingerprint] = existing
                } else {
                    // Update signing key
                    existing.signingPublicKey = signingPublicKey ?? existing.signingPublicKey
                    self.cache.cryptographicIdentities[fingerprint] = existing
                }
                // Persist updated state (already assigned in branches above)
            } else {
                // New entry
                let entry = CryptographicIdentity(
                    fingerprint: fingerprint,
                    publicKey: noisePublicKey,
                    signingPublicKey: signingPublicKey,
                    firstSeen: now
                )
                self.cache.cryptographicIdentities[fingerprint] = entry
            }

            // Optionally persist claimed nickname into social identity
            if let claimed = claimedNickname {
                var identity = self.cache.socialIdentities[fingerprint] ?? SocialIdentity(
                    fingerprint: fingerprint,
                    localPetname: nil,
                    claimedNickname: claimed,
                    trustLevel: .unknown,
                    isFavorite: false,
                    isBlocked: false,
                    notes: nil
                )
                // Update claimed nickname if changed
                if identity.claimedNickname != claimed {
                    identity.claimedNickname = claimed
                    self.cache.socialIdentities[fingerprint] = identity
                } else if self.cache.socialIdentities[fingerprint] == nil {
                    self.cache.socialIdentities[fingerprint] = identity
                }
            }

            self.saveIdentityCache()
        }
    }

    /// Find cryptographic identities whose fingerprint prefix matches a peerID (16-hex) short ID
    func getCryptoIdentitiesByPeerIDPrefix(_ peerID: PeerID) -> [CryptographicIdentity] {
        queue.sync {
            // Defensive: ensure hex and correct length
            guard peerID.isShort else { return [] }
            return cache.cryptographicIdentities.values.filter { $0.fingerprint.hasPrefix(peerID.id) }
        }
    }

    // MARK: - Private-media downgrade protection

    func markPrivateMediaCapable(fingerprint: String) {
        guard !fingerprint.isEmpty else { return }
        let insertAndPersist = {
            guard self.cacheIsLoaded else { return }
            var pinned = self.cache.privateMediaCapableFingerprints ?? []
            guard pinned.insert(fingerprint).inserted else { return }
            self.cache.privateMediaCapableFingerprints = pinned
            self.saveIdentityCache()
        }
        // Downgrade decisions can run immediately after an authenticated
        // announce. Make the pin visible before returning; merely enqueueing a
        // barrier leaves a cross-queue window where a replay can look legacy.
        // The queue-specific fast path prevents self-deadlock if a future
        // identity-state mutation records the capability from inside `queue`.
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            insertAndPersist()
        } else {
            queue.sync(flags: .barrier, execute: insertAndPersist)
        }
    }

    func hasObservedPrivateMediaCapability(fingerprint: String) -> Bool {
        guard !fingerprint.isEmpty else { return false }
        return queue.sync {
            cache.privateMediaCapableFingerprints?.contains(fingerprint) == true
        }
    }

    // MARK: - Noise-authenticated announcement identity

    func bindAuthenticatedSigningPublicKey(_ signingPublicKey: Data, fingerprint: String) {
        guard signingPublicKey.count == AuthenticatedPeerStatePacket.signingPublicKeyLength,
              !fingerprint.isEmpty else { return }
        let bindAndPersist = {
            guard self.cacheIsLoaded else { return }
            var bindings = self.cache.authenticatedSigningKeysByFingerprint ?? [:]
            let bindingChanged = bindings[fingerprint] != signingPublicKey
            bindings[fingerprint] = signingPublicKey
            self.cache.authenticatedSigningKeysByFingerprint = bindings
            if var cryptoIdentity = self.cache.cryptographicIdentities[fingerprint] {
                cryptoIdentity.signingPublicKey = signingPublicKey
                self.cache.cryptographicIdentities[fingerprint] = cryptoIdentity
            }
            guard bindingChanged else { return }
            self.saveIdentityCache()
        }
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            bindAndPersist()
        } else {
            queue.sync(flags: .barrier, execute: bindAndPersist)
        }
    }

    func authenticatedSigningPublicKey(forFingerprint fingerprint: String) -> Data? {
        guard !fingerprint.isEmpty else { return nil }
        return queue.sync {
            cache.authenticatedSigningKeysByFingerprint?[fingerprint]
        }
    }
    
    func updateSocialIdentity(_ identity: SocialIdentity) {
        queue.sync(flags: .barrier) {
            guard self.cacheIsLoaded else { return }
            let previousClaimedNickname = self.cache.socialIdentities[identity.fingerprint]?.claimedNickname
            self.cache.socialIdentities[identity.fingerprint] = identity
            
            // Update nickname index
            if let previousClaimedNickname,
               previousClaimedNickname != identity.claimedNickname {
                self.cache.nicknameIndex[previousClaimedNickname]?.remove(identity.fingerprint)
                if self.cache.nicknameIndex[previousClaimedNickname]?.isEmpty == true {
                    self.cache.nicknameIndex.removeValue(forKey: previousClaimedNickname)
                }
            }
            
            // Add new nickname to index
            if self.cache.nicknameIndex[identity.claimedNickname] == nil {
                self.cache.nicknameIndex[identity.claimedNickname] = Set<String>()
            }
            self.cache.nicknameIndex[identity.claimedNickname]?.insert(identity.fingerprint)
            
            // Save to keychain
            self.saveIdentityCache()
        }
    }
    
    // MARK: - Favorites Management
    
    func getFavorites() -> Set<String> {
        queue.sync {
            let favorites = cache.socialIdentities.values
                .filter { $0.isFavorite }
                .map { $0.fingerprint }
            return Set(favorites)
        }
    }
    
    func setFavorite(_ fingerprint: String, isFavorite: Bool) {
        queue.sync(flags: .barrier) {
            guard self.cacheIsLoaded else { return }
            if var identity = self.cache.socialIdentities[fingerprint] {
                identity.isFavorite = isFavorite
                self.cache.socialIdentities[fingerprint] = identity
            } else {
                // Create new social identity for this fingerprint
                let newIdentity = SocialIdentity(
                    fingerprint: fingerprint,
                    localPetname: nil,
                    claimedNickname: "Unknown",
                    trustLevel: .unknown,
                    isFavorite: isFavorite,
                    isBlocked: false,
                    notes: nil
                )
                self.cache.socialIdentities[fingerprint] = newIdentity
            }
            self.saveIdentityCache()
        }
    }
    
    func isFavorite(fingerprint: String) -> Bool {
        queue.sync {
            return cache.socialIdentities[fingerprint]?.isFavorite ?? false
        }
    }
    
    // MARK: - Blocked Users Management
    
    func isBlocked(fingerprint: String) -> Bool {
        queue.sync {
            guard cacheIsLoaded, !pendingSave else { return true }
            return cache.socialIdentities[fingerprint]?.isBlocked ?? false
        }
    }

    /// Includes blocked identities without a current mesh or favorite entry.
    func getBlockedFingerprints() -> Set<String> {
        queue.sync {
            Set(cache.socialIdentities.values.filter(\.isBlocked).map(\.fingerprint))
        }
    }
    
    func setBlocked(_ fingerprint: String, isBlocked: Bool) {
        queue.sync(flags: .barrier) {
            guard self.cacheIsLoaded else { return }
            if var identity = self.cache.socialIdentities[fingerprint] {
                identity.isBlocked = isBlocked
                if isBlocked {
                    identity.isFavorite = false  // Can't be both favorite and blocked
                }
                self.cache.socialIdentities[fingerprint] = identity
            } else {
                // Create new social identity for this fingerprint
                let newIdentity = SocialIdentity(
                    fingerprint: fingerprint,
                    localPetname: nil,
                    claimedNickname: "Unknown",
                    trustLevel: .unknown,
                    isFavorite: false,
                    isBlocked: isBlocked,
                    notes: nil
                )
                self.cache.socialIdentities[fingerprint] = newIdentity
            }
            self.saveIdentityCache()
        }
    }

    // MARK: - Geohash (Nostr) Blocking
    
    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool {
        queue.sync {
            guard cacheIsLoaded, !pendingSave else { return true }
            return cache.blockedNostrPubkeys.contains(pubkeyHexLowercased.lowercased())
        }
    }
    
    func setNostrBlocked(_ pubkeyHexLowercased: String, isBlocked: Bool) {
        let key = pubkeyHexLowercased.lowercased()
        queue.sync(flags: .barrier) {
            guard self.cacheIsLoaded else { return }
            if isBlocked {
                self.cache.blockedNostrPubkeys.insert(key)
            } else {
                self.cache.blockedNostrPubkeys.remove(key)
            }
            self.saveIdentityCache()
        }
    }
    
    func getBlockedNostrPubkeys() -> Set<String> {
        queue.sync { cache.blockedNostrPubkeys }
    }
    
    // MARK: - Ephemeral Session Management
    
    func registerEphemeralSession(peerID: PeerID, handshakeState: HandshakeState = .none) {
        queue.async(flags: .barrier) {
            self.ephemeralSessions[peerID] = EphemeralIdentity(handshakeState: handshakeState)
        }
    }
    
    func updateHandshakeState(peerID: PeerID, state: HandshakeState) {
        queue.sync(flags: .barrier) {
            self.ephemeralSessions[peerID]?.handshakeState = state
            
            // If handshake completed, update last interaction
            if self.cacheIsLoaded, case .completed(let fingerprint) = state {
                self.cache.lastInteractions[fingerprint] = Date()
                self.saveIdentityCache()
            }
        }
    }
    
    // MARK: - Cleanup
    
    func clearAllIdentityData() {
        SecureLogger.warning("Clearing all identity data", category: .security)
        
        queue.sync(flags: .barrier) {
            self.cache = IdentityCache()
            self.ephemeralSessions.removeAll()

            // Delete from keychain
            let deleted = self.keychain.deleteIdentityKey(forKey: self.cacheKey)
            self.pendingSave = false
            self.cacheIsLoaded = false
            // Panic may already have deleted the persisted encryption key.
            // Revalidate it before allowing any new cache write; never reuse
            // an in-memory key whose durable copy may no longer exist.
            self.encryptionKey = nil
            if deleted { self.loadIdentityCache() }
            SecureLogger.logKeyOperation(.delete, keyType: "identity cache", success: deleted)
        }
    }
    
    func removeEphemeralSession(peerID: PeerID) {
        queue.sync(flags: .barrier) {
            _ = self.ephemeralSessions.removeValue(forKey: peerID)
        }
    }
    
    // MARK: - Verification
    
    func setVerified(fingerprint: String, verified: Bool) {
        queue.sync(flags: .barrier) {
            guard self.cacheIsLoaded else { return }
            if verified {
                self.cache.verifiedFingerprints.insert(fingerprint)
                var verifiedAt = self.cache.verifiedAt ?? [:]
                verifiedAt[fingerprint] = Date()
                self.cache.verifiedAt = verifiedAt
            } else {
                self.cache.verifiedFingerprints.remove(fingerprint)
                self.cache.verifiedAt?.removeValue(forKey: fingerprint)
            }

            // Update trust level if social identity exists
            if var identity = self.cache.socialIdentities[fingerprint] {
                identity.trustLevel = verified ? .verified : .casual
                self.cache.socialIdentities[fingerprint] = identity
            }

            self.saveIdentityCache()
        }
    }
    
    func isVerified(fingerprint: String) -> Bool {
        queue.sync {
            guard cacheIsLoaded, !pendingSave else { return false }
            return cache.verifiedFingerprints.contains(fingerprint)
        }
    }
    
    func getVerifiedFingerprints() -> Set<String> {
        queue.sync {
            guard cacheIsLoaded, !pendingSave else { return [] }
            return cache.verifiedFingerprints
        }
    }

    // MARK: - Vouching (transitive verification)

    /// Maximum vouchers retained per vouchee (most recent kept).
    static let maxVouchersPerVouchee = 8

    /// Records an accepted vouch, enforcing every accept-policy gate that can
    /// be evaluated against stored state (signature verification is the
    /// caller's job — it needs the sender's announce-bound signing key):
    /// - the voucher must be a fingerprint *I* verified
    /// - self-vouches are ignored
    /// - vouches for peers I already verified are ignored (nothing to add)
    /// - attestations outside the validity window are ignored
    /// - at most `maxVouchersPerVouchee` vouchers are kept per vouchee
    ///
    /// Returns true when the vouch was stored (or refreshed).
    @discardableResult
    func recordVouch(voucheeFingerprint: String, voucherFingerprint: String, timestamp: Date) -> Bool {
        recordVouch(
            voucheeFingerprint: voucheeFingerprint,
            voucherFingerprint: voucherFingerprint,
            timestamp: timestamp,
            now: Date()
        )
    }

    @discardableResult
    func recordVouch(voucheeFingerprint: String, voucherFingerprint: String, timestamp: Date, now: Date) -> Bool {
        queue.sync(flags: .barrier) {
            guard self.cacheIsLoaded else { return false }
            guard voucheeFingerprint != voucherFingerprint,
                  self.cache.verifiedFingerprints.contains(voucherFingerprint),
                  !self.cache.verifiedFingerprints.contains(voucheeFingerprint) else {
                return false
            }
            let age = now.timeIntervalSince(timestamp)
            guard age <= VouchAttestation.maxAge, age >= -VouchAttestation.maxClockSkew else {
                return false
            }

            var records = self.cache.vouchesByVouchee?[voucheeFingerprint] ?? []
            if let index = records.firstIndex(where: { $0.voucherFingerprint == voucherFingerprint }) {
                let newest = max(records[index].timestamp, timestamp)
                records[index] = VouchRecord(voucherFingerprint: voucherFingerprint, timestamp: newest)
            } else {
                records.append(VouchRecord(voucherFingerprint: voucherFingerprint, timestamp: timestamp))
            }
            // Keep the most recent vouchers up to the cap.
            records.sort { $0.timestamp > $1.timestamp }
            let capped = Array(records.prefix(Self.maxVouchersPerVouchee))
            guard capped.contains(where: { $0.voucherFingerprint == voucherFingerprint }) else {
                return false // Full of fresher vouches; nothing changed.
            }

            var vouches = self.cache.vouchesByVouchee ?? [:]
            vouches[voucheeFingerprint] = capped
            self.cache.vouchesByVouchee = vouches
            self.saveIdentityCache()
            return true
        }
    }

    /// The vouches that currently count for `fingerprint`. Validity is
    /// recomputed here rather than maintained by cascade deletes: a record
    /// only counts while its voucher is still verified-by-me and its
    /// timestamp is within the expiry window.
    func validVouchers(for fingerprint: String) -> [VouchRecord] {
        validVouchers(for: fingerprint, now: Date())
    }

    func validVouchers(for fingerprint: String, now: Date) -> [VouchRecord] {
        queue.sync {
            self.validVouchersLocked(for: fingerprint, now: now)
        }
    }

    /// Requires `queue`.
    private func validVouchersLocked(for fingerprint: String, now: Date) -> [VouchRecord] {
        guard cacheIsLoaded, !pendingSave else { return [] }
        guard let records = cache.vouchesByVouchee?[fingerprint] else { return [] }
        return records.filter { record in
            record.voucherFingerprint != fingerprint
                && cache.verifiedFingerprints.contains(record.voucherFingerprint)
                && now.timeIntervalSince(record.timestamp) <= VouchAttestation.maxAge
        }
    }

    /// True when the peer has at least one valid vouch and no explicit
    /// verification of ours.
    func isVouched(fingerprint: String) -> Bool {
        isVouched(fingerprint: fingerprint, now: Date())
    }

    func isVouched(fingerprint: String, now: Date) -> Bool {
        queue.sync {
            guard !self.cache.verifiedFingerprints.contains(fingerprint) else { return false }
            return !self.validVouchersLocked(for: fingerprint, now: now).isEmpty
        }
    }

    /// The trust level to display: explicit verification wins, then the
    /// persisted level, with `vouched` layered in (derived, never persisted)
    /// between `casual` and `trusted`.
    func effectiveTrustLevel(for fingerprint: String) -> TrustLevel {
        effectiveTrustLevel(for: fingerprint, now: Date())
    }

    func effectiveTrustLevel(for fingerprint: String, now: Date) -> TrustLevel {
        queue.sync {
            guard self.cacheIsLoaded, !self.pendingSave else { return .unknown }
            if self.cache.verifiedFingerprints.contains(fingerprint) { return .verified }
            let stored = self.cache.socialIdentities[fingerprint]?.trustLevel ?? .unknown
            let vouched = !self.validVouchersLocked(for: fingerprint, now: now).isEmpty
            switch stored {
            case .verified, .trusted:
                return stored
            case .vouched, .casual, .unknown:
                if vouched { return .vouched }
                // `.vouched` should never be persisted; degrade defensively.
                return stored == .vouched ? .casual : stored
            }
        }
    }

    func lastVouchBatchSent(to fingerprint: String) -> Date? {
        queue.sync { cache.vouchBatchSentAt?[fingerprint] }
    }

    func markVouchBatchSent(to fingerprint: String, at date: Date) {
        queue.async(flags: .barrier) {
            guard self.cacheIsLoaded else { return }
            var sentAt = self.cache.vouchBatchSentAt ?? [:]
            sentAt[fingerprint] = date
            self.cache.vouchBatchSentAt = sentAt
            self.saveIdentityCache()
        }
    }

    /// The peer's announce-bound Ed25519 signing key, if seen this session.
    func signingPublicKey(forFingerprint fingerprint: String) -> Data? {
        queue.sync { cache.cryptographicIdentities[fingerprint]?.signingPublicKey }
    }

    /// Verified fingerprints ordered most recently verified first (entries
    /// without a recorded verification time sort last), excluding the given
    /// fingerprint. Feeds the outgoing vouch batch.
    func mostRecentlyVerifiedFingerprints(limit: Int, excluding fingerprint: String) -> [String] {
        queue.sync {
            guard self.cacheIsLoaded, !self.pendingSave else { return [] }
            let verifiedAt = cache.verifiedAt ?? [:]
            let ordered = cache.verifiedFingerprints
                .filter { $0 != fingerprint }
                .sorted {
                    (verifiedAt[$0] ?? .distantPast, $0) > (verifiedAt[$1] ?? .distantPast, $1)
                }
            return Array(ordered.prefix(limit))
        }
    }

    var debugNicknameIndex: [String: Set<String>] {
        queue.sync { cache.nicknameIndex }
    }

    func debugEphemeralSession(for peerID: PeerID) -> EphemeralIdentity? {
        queue.sync { ephemeralSessions[peerID] }
    }

    func debugLastInteraction(for fingerprint: String) -> Date? {
        queue.sync { cache.lastInteractions[fingerprint] }
    }
}
