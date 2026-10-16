import Foundation
import Testing
import BitFoundation
@testable import bitchat

@Suite("Nostr identity persistence")
struct NostrIdentityBridgeTests {
    // Synthetic fixture only; no device location is read.
    private let service = "chat.bitchat.nostr"
    private let identityKey = "nostr-current-identity"
    private let seedKey = "nostr-device-seed"

    @Test("Unreadable current identity is preserved and retried without replacement")
    func currentIdentityReadFailuresPreserveIdentity() throws {
        for failure: KeychainReadResult in [.deviceLocked, .accessDenied, .authenticationFailed, .otherError(-36)] {
            let keychain = NostrPersistenceKeychain()
            let original = try NostrIdentity.generate()
            let originalData = try JSONEncoder().encode(original)
            keychain.backing.save(key: identityKey, data: originalData, service: service, accessible: nil)
            let bridge = NostrIdentityBridge(keychain: keychain)
            keychain.readFailure = failure

            #expect(throws: NostrIdentityBridge.StorageError.self) { try bridge.getCurrentNostrIdentity() }
            #expect(keychain.saveCount == 0)
            #expect(keychain.backing.load(key: identityKey, service: service) == originalData)

            keychain.readFailure = nil
            #expect(try bridge.getCurrentNostrIdentity()?.npub == original.npub)
            #expect(keychain.saveCount == 0)
        }
    }

    @Test("Read-only accessor never creates key material")
    func storedIdentityIsReadOnly() throws {
        let keychain = NostrPersistenceKeychain()
        let bridge = NostrIdentityBridge(keychain: keychain)
        #expect(try bridge.storedNostrIdentity() == nil)
        #expect(keychain.saveCount == 0)
        #expect(keychain.backing.load(key: identityKey, service: service) == nil)

        let created = try #require(try bridge.getCurrentNostrIdentity())
        #expect(try bridge.storedNostrIdentity()?.npub == created.npub)

        keychain.readFailure = .deviceLocked
        #expect(throws: NostrIdentityBridge.StorageError.self) { try bridge.storedNostrIdentity() }
    }

    @Test("Wesh messaging paths read the key only while Internet mode is on and never create one")
    func weshMessagingIdentityNeverCreatesKey() throws {
        let keychain = NostrPersistenceKeychain()
        let bridge = NostrIdentityBridge(keychain: keychain)
        #expect(bridge.messagingIdentity(weshActive: true, internetEnabled: false) == nil)
        #expect(bridge.messagingIdentity(weshActive: true, internetEnabled: true) == nil)
        #expect(keychain.saveCount == 0)
        #expect(keychain.backing.load(key: identityKey, service: service) == nil)

        let stored = try #require(try bridge.getCurrentNostrIdentity())
        #expect(bridge.messagingIdentity(weshActive: true, internetEnabled: false) == nil)
        #expect(bridge.messagingIdentity(weshActive: true, internetEnabled: true)?.npub == stored.npub)

        keychain.readFailure = .deviceLocked
        #expect(bridge.messagingIdentity(weshActive: true, internetEnabled: true) == nil)
    }

    @Test("Outside Wesh the upstream get-or-create behaviour is kept")
    func upstreamMessagingIdentityCreatesKey() throws {
        let keychain = NostrPersistenceKeychain()
        let bridge = NostrIdentityBridge(keychain: keychain)
        let created = try #require(bridge.messagingIdentity(weshActive: false, internetEnabled: false))
        #expect(try bridge.storedNostrIdentity()?.npub == created.npub)
    }

    @Test("Owned npubs come from durable material and fail closed otherwise")
    func locallyOwnedNpubsFailClosed() throws {
        let keychain = NostrPersistenceKeychain()
        let bridge = NostrIdentityBridge(keychain: keychain)
        #expect(try bridge.locallyOwnedNpubs().isEmpty)
        #expect(keychain.saveCount == 0)

        let current = try #require(try bridge.getCurrentNostrIdentity())
        #expect(try bridge.locallyOwnedNpubs() == [current.npub])

        keychain.readFailure = .deviceLocked
        #expect(throws: NostrIdentityBridge.StorageError.self) { try bridge.locallyOwnedNpubs() }
        keychain.readFailure = nil

        // A device seed means derived identities exist that cannot be listed,
        // even on a fresh bridge whose in-memory cache is empty.
        _ = try bridge.deriveIdentity(forGeohash: "u09tu")
        #expect(throws: NostrIdentityBridge.StorageError.derivedIdentitiesNotEnumerable) {
            try NostrIdentityBridge(keychain: keychain).locallyOwnedNpubs()
        }
    }

    @Test("Unreadable seed is preserved and does not cache a replacement")
    func seedReadFailuresPreserveIdentity() throws {
        for failure: KeychainReadResult in [.deviceLocked, .accessDenied, .authenticationFailed, .otherError(-36)] {
            let keychain = NostrPersistenceKeychain()
            let seed = Data(repeating: 0x39, count: 32)
            keychain.backing.save(key: seedKey, data: seed, service: service, accessible: nil)
            let bridge = NostrIdentityBridge(keychain: keychain)
            keychain.readFailure = failure

            #expect(throws: NostrIdentityBridge.StorageError.self) { try bridge.deriveIdentity(forGeohash: "00000") }
            #expect(keychain.saveCount == 0)
            #expect(keychain.backing.load(key: seedKey, service: service) == seed)

            keychain.readFailure = nil
            let expected = try NostrIdentityBridge(keychain: keychain.backing).deriveIdentity(forGeohash: "00000")
            #expect(try bridge.deriveIdentity(forGeohash: "00000").npub == expected.npub)
            #expect(keychain.saveCount == 0)
        }
    }

    @Test("Malformed stored identity and seed are retained for explicit recovery")
    func malformedIdentityIsNotReplaced() throws {
        let keychain = NostrPersistenceKeychain()
        let malformed = Data([0x01, 0x02])
        for key in [identityKey, seedKey] {
            keychain.backing.save(key: key, data: malformed, service: service, accessible: nil)
        }
        let bridge = NostrIdentityBridge(keychain: keychain)

        #expect(throws: NostrIdentityBridge.StorageError.self) { try bridge.getCurrentNostrIdentity() }
        #expect(throws: NostrIdentityBridge.StorageError.self) { try bridge.deriveIdentity(forGeohash: "00000") }
        #expect(keychain.saveCount == 0)
        for key in [identityKey, seedKey] {
            #expect(keychain.backing.load(key: key, service: service) == malformed)
        }
    }

    @Test("New current identity is returned only after a confirmed save")
    func failedCurrentIdentitySaveIsNotExposed() throws {
        let keychain = NostrPersistenceKeychain()
        keychain.dropSaves = true
        let bridge = NostrIdentityBridge(keychain: keychain)

        #expect(throws: NostrIdentityBridge.StorageError.self) { try bridge.getCurrentNostrIdentity() }
        #expect(keychain.backing.load(key: identityKey, service: service) == nil)

        keychain.dropSaves = false
        let identity = try #require(try bridge.getCurrentNostrIdentity())
        #expect(try NostrIdentityBridge(keychain: keychain).getCurrentNostrIdentity()?.npub == identity.npub)
        #expect(keychain.saveCount == 2)
    }

    @Test("Failed seed save cannot poison the in-memory identity cache")
    func failedSeedSaveIsNotCached() throws {
        let keychain = NostrPersistenceKeychain()
        keychain.dropSaves = true
        let bridge = NostrIdentityBridge(keychain: keychain)

        #expect(throws: NostrIdentityBridge.StorageError.self) { try bridge.deriveIdentity(forGeohash: "00000") }
        #expect(keychain.backing.load(key: seedKey, service: service) == nil)

        let seed = Data(repeating: 0x72, count: 32)
        keychain.backing.save(key: seedKey, data: seed, service: service, accessible: nil)
        let expected = try NostrIdentityBridge(keychain: keychain.backing).deriveIdentity(forGeohash: "00000")
        #expect(try bridge.deriveIdentity(forGeohash: "00000").npub == expected.npub)
        #expect(keychain.saveCount == 1)
    }

    @Test("Unavailable readback does not expose a newly saved identity or seed")
    func unavailableReadbackFailsClosedAndCanRetry() throws {
        for useSeed in [false, true] {
            let keychain = NostrPersistenceKeychain()
            keychain.failReadback = true
            let bridge = NostrIdentityBridge(keychain: keychain)
            #expect(throws: NostrIdentityBridge.StorageError.self) {
                if useSeed { _ = try bridge.deriveIdentity(forGeohash: "00000") }
                else { _ = try bridge.getCurrentNostrIdentity() }
            }

            keychain.failReadback = false
            if useSeed {
                let expected = try NostrIdentityBridge(keychain: keychain.backing).deriveIdentity(forGeohash: "00000")
                #expect(try bridge.deriveIdentity(forGeohash: "00000").npub == expected.npub)
            } else {
                let expected = try NostrIdentityBridge(keychain: keychain.backing).getCurrentNostrIdentity()
                #expect(try bridge.getCurrentNostrIdentity()?.npub == expected?.npub)
            }
            #expect(keychain.saveCount == 1)
        }
    }

    @Test("A first-run seed persists and keeps derived identities stable across instances")
    func firstRunSeedIsDurable() throws {
        let keychain = NostrPersistenceKeychain()
        let bridge = NostrIdentityBridge(keychain: keychain)
        let identity = try bridge.deriveIdentity(forGeohash: "00000")
        #expect(keychain.backing.load(key: seedKey, service: service)?.count == 32)
        #expect(try NostrIdentityBridge(keychain: keychain).deriveIdentity(forGeohash: "00000").npub == identity.npub)
        #expect(keychain.saveCount == 1)
    }
}

/// Isolated storage only. Deliberately makes legacy `load` mask read errors,
/// matching production, so regressions cannot pass by bypassing loadWithResult.
private final class NostrPersistenceKeychain: KeychainManagerProtocol {
    let backing = MockKeychain()
    var readFailure: KeychainReadResult?
    var dropSaves = false
    var failReadback = false
    private(set) var saveCount = 0

    func saveIdentityKey(_ data: Data, forKey key: String) -> Bool { backing.saveIdentityKey(data, forKey: key) }
    func getIdentityKey(forKey key: String) -> Data? { backing.getIdentityKey(forKey: key) }
    func deleteIdentityKey(forKey key: String) -> Bool { backing.deleteIdentityKey(forKey: key) }
    func deleteAllKeychainData() -> Bool { backing.deleteAllKeychainData() }
    func secureClear(_ data: inout Data) { backing.secureClear(&data) }
    // periphery:ignore - protocol conformance of the test double
    func secureClear(_ string: inout String) { backing.secureClear(&string) }
    func verifyIdentityKeyExists() -> Bool { backing.verifyIdentityKeyExists() }
    func getIdentityKeyWithResult(forKey key: String) -> KeychainReadResult { backing.getIdentityKeyWithResult(forKey: key) }
    func saveIdentityKeyWithResult(_ data: Data, forKey key: String) -> KeychainSaveResult { backing.saveIdentityKeyWithResult(data, forKey: key) }
    func save(key: String, data: Data, service: String, accessible: CFString?) {
        saveCount += 1
        if !dropSaves { backing.save(key: key, data: data, service: service, accessible: accessible) }
    }
    func load(key: String, service: String) -> Data? {
        guard case .success(let data) = loadWithResult(key: key, service: service) else { return nil }
        return data
    }
    func loadWithResult(key: String, service: String) -> KeychainReadResult {
        if let readFailure { return readFailure }
        if failReadback && saveCount > 0 { return .deviceLocked }
        return backing.loadWithResult(key: key, service: service)
    }
    func delete(key: String, service: String) { backing.delete(key: key, service: service) }
    func deleteAll(service: String) { backing.deleteAll(service: service) }
}
