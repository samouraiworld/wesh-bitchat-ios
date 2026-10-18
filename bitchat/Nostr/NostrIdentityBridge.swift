import BitFoundation
import Foundation

/// Bridge between Noise and Nostr identities
final class NostrIdentityBridge {
    enum StorageError: Error {
        case unavailable
        case invalidStoredIdentity
        case persistenceNotConfirmed
        /// A device seed exists, so per-geohash/bridge identities exist that
        /// cannot be enumerated.
        case derivedIdentitiesNotEnumerable
    }

    private let keychainService = "chat.bitchat.nostr"
    private let currentIdentityKey = "nostr-current-identity"
    private let deviceSeedKey = "nostr-device-seed"

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

    /// The identity BitChat messaging paths (favorite notices, Nostr DMs and
    /// acks) may use. In Wesh: read-only, and only while Internet mode is on,
    /// so no key exists outside the opt-in and none is revealed while it is
    /// off. Outside Wesh: upstream get-or-create.
    func messagingIdentity(weshActive: Bool = WeshModeFlag.isActive,
                           internetEnabled: Bool = WeshInternetSettings.isEnabled()) -> NostrIdentity? {
        guard weshActive else { return try? getCurrentNostrIdentity() }
        guard internetEnabled else { return nil }
        return try? storedNostrIdentity()
    }

    /// Every npub this device holds a key for, read-only and computed from
    /// durable material only. Derived geohash/bridge identities come from the
    /// device seed for any cell string, so they cannot be listed: when a seed
    /// is stored this throws instead of guessing. There is no retained
    /// pre-rotation key store on iOS (panic deletes them all). Throws when
    /// storage cannot answer, so callers fail closed.
    func locallyOwnedNpubs() throws -> Set<String> {
        switch keychain.loadWithResult(key: deviceSeedKey, service: keychainService) {
        case .itemNotFound:
            break
        case .success:
            throw StorageError.derivedIdentitiesNotEnumerable
        case .accessDenied, .deviceLocked, .authenticationFailed, .otherError:
            throw StorageError.unavailable
        }
        return Set([try storedNostrIdentity()?.npub].compactMap { $0 })
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

}
