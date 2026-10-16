import BitFoundation
import Foundation
import CryptoKit

/// Bridge between Noise and Nostr identities
final class NostrIdentityBridge {
    enum StorageError: Error {
        case unavailable
        case invalidStoredIdentity
        case persistenceNotConfirmed
    }

    private let keychainService = "chat.bitchat.nostr"
    private let currentIdentityKey = "nostr-current-identity"
    private let deviceSeedKey = "nostr-device-seed"
    // In-memory cache to avoid transient keychain access issues
    private var deviceSeedCache: Data?
    // Cache derived identities to avoid repeated crypto during view rendering
    private var derivedIdentityCache: [String: NostrIdentity] = [:]
    private let cacheLock = NSLock()

    private let keychain: KeychainManagerProtocol

    init(keychain: KeychainManagerProtocol = KeychainManager.makeDefault()) {
        self.keychain = keychain
    }
    
    /// Get or create the current Nostr identity
    func getCurrentNostrIdentity() throws -> NostrIdentity? {
        // Check if we already have a Nostr identity
        switch keychain.loadWithResult(key: currentIdentityKey, service: keychainService) {
        case .success(let existingData):
            guard let identity = try? JSONDecoder().decode(NostrIdentity.self, from: existingData) else {
                throw StorageError.invalidStoredIdentity
            }
            return identity
        case .itemNotFound:
            break
        case .accessDenied, .deviceLocked, .authenticationFailed, .otherError:
            throw StorageError.unavailable
        }
        
        // Generate new Nostr identity
        let nostrIdentity = try NostrIdentity.generate()
        
        // Store it
        let data = try JSONEncoder().encode(nostrIdentity)
        try saveAndConfirm(data, forKey: currentIdentityKey, accessible: nil)
        
        return nostrIdentity
    }
    
    /// The stored Nostr identity, read-only: nil when none is stored, and it
    /// never creates one. Throws when storage cannot answer (e.g. locked).
    /// UI and verification paths must use this, not `getCurrentNostrIdentity()`.
    func storedNostrIdentity() throws -> NostrIdentity? {
        switch keychain.loadWithResult(key: currentIdentityKey, service: keychainService) {
        case .success(let existingData):
            guard let identity = try? JSONDecoder().decode(NostrIdentity.self, from: existingData) else {
                throw StorageError.invalidStoredIdentity
            }
            return identity
        case .itemNotFound:
            return nil
        case .accessDenied, .deviceLocked, .authenticationFailed, .otherError:
            throw StorageError.unavailable
        }
    }

    /// Every npub this device holds a key for, read-only: the current
    /// identity plus derived geohash/bridge identities in use. There is no
    /// retained pre-rotation key store on iOS (panic deletes them all).
    /// Throws when storage cannot answer, so callers fail closed.
    func locallyOwnedNpubs() throws -> Set<String> {
        var owned = Set<String>()
        if let current = try storedNostrIdentity() { owned.insert(current.npub) }
        cacheLock.lock()
        owned.formUnion(derivedIdentityCache.values.map(\.npub))
        cacheLock.unlock()
        return owned
    }

    /// Get Nostr public key associated with a Noise public key
    func getNostrPublicKey(for noisePublicKey: Data) -> String? {
        let key = "nostr-noise-\(noisePublicKey.base64EncodedString())"
        guard let data = keychain.load(key: key, service: keychainService),
              let pubkey = String(data: data, encoding: .utf8) else {
            return nil
        }
        return pubkey
    }
    
    /// Clear all Nostr identity associations and current identity
    func clearAllAssociations() {
        // Must go through the injected keychain, not raw SecItem calls:
        // under test that keychain is in-memory, and a direct delete here
        // would wipe the developer's real Nostr identity on every test run.
        keychain.deleteAll(service: keychainService)

        deviceSeedCache = nil
        // Also drop the in-memory derived per-geohash identities. These hold the
        // actual secp256k1 private keys; if left cached, post-panic geohash
        // messages would still be signed with pre-panic keys (linkable across the
        // wipe) until the app is force-quit.
        cacheLock.lock()
        derivedIdentityCache.removeAll()
        cacheLock.unlock()
    }

    // MARK: - Per-Geohash Identities (Location Channels)

    /// Returns a stable device seed used to derive unlinkable per-geohash identities.
    /// Stored only on device keychain.
    private func getOrCreateDeviceSeed() throws -> Data {
        if let cached = deviceSeedCache { return cached }
        switch keychain.loadWithResult(key: deviceSeedKey, service: keychainService) {
        case .success(let existing):
            guard existing.count == 32 else { throw StorageError.invalidStoredIdentity }
            deviceSeedCache = existing
            return existing
        case .itemNotFound:
            break
        case .accessDenied, .deviceLocked, .authenticationFailed, .otherError:
            throw StorageError.unavailable
        }
        // CryptoKit key generation cannot fail, unlike SecRandomCopyBytes —
        // a discarded failure here would persist an all-zero identity seed.
        let seed = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        // Ensure availability after first unlock to prevent unintended rotation when locked
        try saveAndConfirm(seed, forKey: deviceSeedKey, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        deviceSeedCache = seed
        return seed
    }

    /// The legacy custom-service save has no result. Do not expose a new
    /// identity until its exact bytes can be read back from persistent storage.
    private func saveAndConfirm(_ data: Data, forKey key: String, accessible: CFString?) throws {
        keychain.save(key: key, data: data, service: keychainService, accessible: accessible)
        guard case .success(let stored) = keychain.loadWithResult(key: key, service: keychainService),
              stored == data else {
            throw StorageError.persistenceNotConfirmed
        }
    }

    /// Derive a deterministic, unlinkable Nostr identity for a mesh-bridge
    /// rendezvous cell. Distinct HMAC label keeps it unlinkable from the
    /// geohash-chat identity for the same cell string.
    func deriveIdentity(forBridgeRendezvous cell: String) throws -> NostrIdentity {
        try deriveIdentity(forGeohash: "bridge|" + cell)
    }

    /// Derive a deterministic, unlinkable Nostr identity for a given geohash.
    /// Uses HMAC-SHA256(deviceSeed, geohash) as private key material, with fallback rehashing
    /// if the candidate is not a valid secp256k1 private key.
    func deriveIdentity(forGeohash geohash: String) throws -> NostrIdentity {
        // Check cache first to avoid repeated crypto + keychain I/O during view rendering
        cacheLock.lock()
        if let cached = derivedIdentityCache[geohash] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let seed = try getOrCreateDeviceSeed()
        guard let msg = geohash.data(using: .utf8) else {
            throw NSError(domain: "NostrIdentity", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid geohash string"])
        }

        func candidateKey(iteration: UInt32) -> Data {
            var input = Data(msg)
            var iterBE = iteration.bigEndian
            withUnsafeBytes(of: &iterBE) { bytes in
                input.append(contentsOf: bytes)
            }
            let code = HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: seed))
            return Data(code)
        }

        // Try a few iterations to ensure a valid key can be formed
        for i in 0..<10 {
            let keyData = candidateKey(iteration: UInt32(i))
            if let identity = try? NostrIdentity(privateKeyData: keyData) {
                // Cache the result
                cacheLock.lock()
                derivedIdentityCache[geohash] = identity
                cacheLock.unlock()
                return identity
            }
        }
        // As a final fallback, hash the seed+msg and try again
        let fallback = (seed + msg).sha256Hash()
        let identity = try NostrIdentity(privateKeyData: fallback)

        // Cache the result
        cacheLock.lock()
        derivedIdentityCache[geohash] = identity
        cacheLock.unlock()

        return identity
    }
}
