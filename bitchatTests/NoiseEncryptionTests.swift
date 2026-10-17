// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
import BitFoundation
import CryptoKit
import Foundation
import Testing
@testable import bitchat

struct NoiseEncryptionTests {
    @Test func generatesNewIdentityWhenBothItemsAreMissing() throws {
        let storage = MockKeychain()
        let service = NoiseEncryptionService(keychain: storage)
        let noise = try #require(service.getStaticPublicKeyData())
        let signing = try #require(service.getSigningPublicKeyData())
        #expect(noise.count == 32 && signing.count == 32)
        #expect(service.isIdentityAvailable)
        #expect(storage.identitySaveCount == 3)
        let restored = NoiseEncryptionService(keychain: storage)
        #expect(restored.getStaticPublicKeyData() == noise)
        #expect(restored.getSigningPublicKeyData() == signing)
        #expect(storage.identitySaveCount == 3)
    }

    @Test func loadsExistingIdentityWithoutRewriting() throws {
        let storage = MockKeychain()
        let noise = Curve25519.KeyAgreement.PrivateKey()
        let signing = Curve25519.Signing.PrivateKey()
        _ = storage.saveIdentityKey(noise.rawRepresentation, forKey: "noiseStaticKey")
        _ = storage.saveIdentityKey(signing.rawRepresentation, forKey: "ed25519SigningKey")
        let service = NoiseEncryptionService(keychain: storage)
        #expect(service.getStaticPublicKeyData() == noise.publicKey.rawRepresentation)
        #expect(service.getSigningPublicKeyData() == signing.publicKey.rawRepresentation)
        #expect(storage.identitySaveCount == 0)
        #expect(service.retryIdentityPersistence())
        #expect(storage.identitySaveCount == 0)
        let data = Data("persisted pair".utf8)
        let signature = try #require(service.signData(data))
        #expect(signing.publicKey.isValidSignature(signature, for: data))
    }

    @Test func allReadFailuresPreserveIdentityAndRecoverWithoutReplacement() throws {
        let failures: [KeychainReadResult] = [.accessDenied, .deviceLocked, .authenticationFailed, .otherError(-50)]
        for failure in failures {
            for key in ["noiseStaticKey", "ed25519SigningKey"] {
                let storage = MockKeychain()
                let original = NoiseEncryptionService(keychain: storage)
                let noise = original.getStaticPublicKeyData()
                let signing = original.getSigningPublicKeyData()
                storage.identityReadFault = { name, _ in name == key ? failure : nil }
                let service = NoiseEncryptionService(keychain: storage)
                #expect(!service.isIdentityAvailable)
                #expect(service.getStaticPublicKeyData() == nil)
                #expect(service.getSigningPublicKeyData() == nil)
                #expect(service.getIdentityFingerprint() == nil)
                #expect(service.staticIdentityPublicKey == nil)
                #expect(service.signingPublicKey == nil)
                #expect(storage.identitySaveCount == 3)
                storage.identityReadFault = nil
                #expect(service.retryIdentityPersistence())
                #expect(service.getStaticPublicKeyData() == noise)
                #expect(service.getSigningPublicKeyData() == signing)
                #expect(storage.identitySaveCount == 3)
                #expect(storage.identityDeleteCount == 1)
            }
        }
    }

    @Test func unreadableMissingPairDoesNotWriteEitherHalf() {
        for key in ["noiseStaticKey", "ed25519SigningKey"] {
            let storage = MockKeychain()
            storage.identityReadFault = { name, _ in name == key ? .deviceLocked : nil }
            let service = NoiseEncryptionService(keychain: storage)
            #expect(!service.isIdentityAvailable)
            #expect(storage.identitySaveCount == 0)
            storage.identityReadFault = nil
            #expect(service.retryIdentityPersistence())
            #expect(storage.identitySaveCount == 3)
        }
    }

    @Test func malformedStoredDataIsPreservedWithoutReplacingEitherKey() {
        for key in ["noiseStaticKey", "ed25519SigningKey"] {
            let storage = MockKeychain()
            _ = NoiseEncryptionService(keychain: storage)
            _ = storage.saveIdentityKey(Data([1, 2, 3]), forKey: key)
            let service = NoiseEncryptionService(keychain: storage)
            #expect(!service.isIdentityAvailable)
            #expect(!service.retryIdentityPersistence())
            #expect(storage.getIdentityKey(forKey: key) == Data([1, 2, 3]))
            #expect(storage.identitySaveCount == 3)
            #expect(storage.identityDeleteCount == 1)
        }
    }

    @Test func partialLegacyPairStaysUnavailableUntilOriginalMissingKeyIsRestored() {
        for missing in ["noiseStaticKey", "ed25519SigningKey"] {
            let storage = MockKeychain()
            let original = NoiseEncryptionService(keychain: storage)
            let missingData = storage.getIdentityKey(forKey: missing)!
            _ = storage.deleteIdentityKey(forKey: missing)
            let service = NoiseEncryptionService(keychain: storage)
            #expect(!service.isIdentityAvailable)
            #expect(service.identityAvailability == .recoveryRequired)
            #expect(!service.retryIdentityPersistence())
            #expect(storage.identitySaveCount == 3)
            _ = storage.saveIdentityKey(missingData, forKey: missing)
            #expect(service.retryIdentityPersistence())
            #expect(service.getStaticPublicKeyData() == original.getStaticPublicKeyData())
            #expect(service.getSigningPublicKeyData() == original.getSigningPublicKeyData())
        }
    }

    @Test func failedFirstSaveDoesNotExposeOrUsePendingKeys() throws {
        let storage = MockKeychain()
        storage.simulatedSaveError = .accessDenied
        let service = NoiseEncryptionService(keychain: storage)
        #expect(!service.isIdentityAvailable)
        #expect(service.getStaticPublicKeyData() == nil)
        #expect(service.getSigningPublicKeyData() == nil)
        #expect(service.signData(Data([1])) == nil)
        #expect(service.currentPrekeyBundle() == nil)
        #expect(!service.replenishPrekeysIfNeeded())
        #expect(throws: NoiseEncryptionError.identityUnavailable) {
            try service.initiateHandshake(with: PeerID(str: "0102030405060708"))
        }
        #expect(throws: NoiseEncryptionError.identityUnavailable) {
            try service.encrypt(Data([1]), for: PeerID(str: "0102030405060708"))
        }
        #expect(throws: NoiseEncryptionError.identityUnavailable) {
            try service.openCourierPayload(Data())
        }
        #expect(throws: NoiseEncryptionError.identityUnavailable) {
            try service.sealCourierPayload(Data([1]), recipientStaticKey: Data(repeating: 1, count: 32))
        }
        #expect(throws: NoiseEncryptionError.identityUnavailable) {
            try service.openPrekeyPayload(Data(), prekeyID: 1)
        }
        let peer = PeerID(str: "0102030405060708")
        #expect(!service.hasSession(with: peer))
        #expect(!service.hasEstablishedSession(with: peer))
        #expect(service.sessionGeneration(for: peer) == nil)
        #expect(throws: NoiseEncryptionError.identityUnavailable) {
            try service.initiateHandshakeIfNeeded(with: peer)
        }
        #expect(throws: NoiseEncryptionError.identityUnavailable) {
            try service.initiateReconnectHandshake(with: peer)
        }
        #expect(throws: NoiseEncryptionError.identityUnavailable) {
            try service.processHandshakeMessage(from: peer, message: Data())
        }
        #expect(throws: NoiseEncryptionError.identityUnavailable) {
            try service.decrypt(Data(), from: peer)
        }
        #expect(throws: NoiseEncryptionError.identityUnavailable) {
            try service.sealPrekeyPayload(Data(), recipientPrekey: PrekeyBundle.Prekey(id: 1, publicKey: Data(repeating: 1, count: 32)))
        }
        storage.simulatedSaveError = nil
        #expect(service.retryIdentityPersistence())
        #expect(service.isIdentityAvailable)
    }

    @Test func failedSecondSaveRetriesExactPendingPairWithoutRewritingFirst() throws {
        let storage = MockKeychain()
        var attemptedSigning: Data?
        storage.identitySaveFault = { key, data, _ in
            if key == "ed25519SigningKey" { attemptedSigning = data; return .accessDenied }
            return nil
        }
        let service = NoiseEncryptionService(keychain: storage)
        let persistedNoise = try #require(storage.getIdentityKey(forKey: "noiseStaticKey"))
        #expect(service.getStaticPublicKeyData() == nil)
        #expect(storage.identitySaveCount == 3)
        storage.identitySaveFault = nil
        #expect(service.retryIdentityPersistence())
        #expect(storage.identitySaveCount == 4)
        #expect(storage.getIdentityKey(forKey: "noiseStaticKey") == persistedNoise)
        #expect(storage.getIdentityKey(forKey: "ed25519SigningKey") == attemptedSigning)
    }

    @Test func processRestartAfterPartialCreationCompletesExactJournaledPair() throws {
        let storage = MockKeychain()
        storage.identitySaveFault = { key, _, _ in key == "ed25519SigningKey" ? .accessDenied : nil }
        var interrupted: NoiseEncryptionService? = NoiseEncryptionService(keychain: storage)
        #expect(interrupted?.isIdentityAvailable == false)
        let journal = try #require(storage.getIdentityKey(forKey: "noiseIdentityPending.v1"))
        let originalNoise = try #require(storage.getIdentityKey(forKey: "noiseStaticKey"))
        let expectedSigning = Data(journal[41..<73])
        interrupted = nil
        storage.identitySaveFault = nil
        let restarted = NoiseEncryptionService(keychain: storage)
        #expect(restarted.isIdentityAvailable)
        #expect(restarted.retryIdentityPersistence())
        #expect(storage.identitySaveCount == 4)
        #expect(storage.getIdentityKey(forKey: "noiseStaticKey") == originalNoise)
        #expect(storage.getIdentityKey(forKey: "ed25519SigningKey") == expectedSigning)
        #expect(storage.getIdentityKey(forKey: "noiseIdentityPending.v1") == nil)
    }

    @Test func saveSuccessRequiresExactReadbackOfBothKeys() {
        for key in ["noiseStaticKey", "ed25519SigningKey"] {
            for readbackFailure: KeychainReadResult in [.deviceLocked, .success(Data(repeating: 7, count: 32)), .itemNotFound] {
                let storage = MockKeychain()
                var readsForKey = 0
                storage.identityReadFault = { name, _ in
                    guard name == key else { return nil }
                    readsForKey += 1
                    return readsForKey >= 3 ? readbackFailure : nil
                }
                let service = NoiseEncryptionService(keychain: storage)
                #expect(!service.isIdentityAvailable)
                #expect(service.signData(Data([1])) == nil)
                #expect(storage.identitySaveCount == 3)
                storage.identityReadFault = nil
                #expect(service.retryIdentityPersistence())
                #expect(storage.identitySaveCount == 3)
            }
        }
    }

    @Test func nominalWriteWithoutStorageDoesNotBecomeAnIdentity() {
        let storage = MockKeychain()
        storage.identitySaveFault = { _, _, _ in .success }
        let service = NoiseEncryptionService(keychain: storage)
        #expect(!service.isIdentityAvailable)
        #expect(service.getIdentityFingerprint() == nil)
        storage.identitySaveFault = nil
        #expect(service.retryIdentityPersistence())
        #expect(service.isIdentityAvailable)
    }

    @Test func pendingPairNeverOverwritesDivergentStoredDataOrReadError() throws {
        let storage = MockKeychain()
        storage.simulatedSaveError = .accessDenied
        let service = NoiseEncryptionService(keychain: storage)
        storage.simulatedSaveError = nil
        let other = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        _ = storage.saveIdentityKey(other, forKey: "noiseStaticKey")
        #expect(!service.retryIdentityPersistence())
        #expect(storage.identitySaveCount == 1)
        #expect(storage.getIdentityKey(forKey: "noiseStaticKey") == other)
        _ = storage.deleteIdentityKey(forKey: "noiseStaticKey")
        storage.identityReadFault = { name, _ in name == "ed25519SigningKey" ? .deviceLocked : nil }
        #expect(!service.retryIdentityPersistence())
        #expect(storage.identitySaveCount == 1)
        storage.identityReadFault = nil
        #expect(service.retryIdentityPersistence())
        #expect(storage.identitySaveCount == 4)
    }

    @Test func duplicateSaveCannotPublishUnconfirmedGeneratedKeys() {
        let storage = MockKeychain()
        storage.simulatedSaveError = .duplicateItem
        let service = NoiseEncryptionService(keychain: storage)
        #expect(!service.isIdentityAvailable)
        #expect(service.getStaticPublicKeyData() == nil)
        #expect(service.getSigningPublicKeyData() == nil)
        #expect(storage.identitySaveCount == 1)
    }

    @Test func readyContextDoesNotRotateOnRetryOrTransientStorageFailure() {
        let storage = MockKeychain()
        let service = NoiseEncryptionService(keychain: storage)
        let original = service.getIdentityFingerprint()
        storage.simulatedReadError = .deviceLocked
        #expect(service.retryIdentityPersistence())
        #expect(service.isIdentityAvailable)
        #expect(service.getIdentityFingerprint() == original)
        #expect(service.signData(Data([1])) != nil)
        #expect(storage.identitySaveCount == 3)
    }

    @Test func panicInvalidatesMemoryAndForbidsResurrectionOnSameInstance() {
        let storage = MockKeychain()
        let service = NoiseEncryptionService(keychain: storage)
        service.clearPersistentIdentity()
        #expect(!service.isIdentityAvailable)
        #expect(service.getStaticPublicKeyData() == nil)
        #expect(service.signData(Data([1])) == nil)
        #expect(!service.retryIdentityPersistence())
        #expect(storage.identitySaveCount == 3)
        #expect(storage.identityDeleteCount == 5)
    }

    @Test func concurrentFirstUseInstancesReuseOnePersistedPair() {
        let storage = MockKeychain()
        let results = NoiseIdentityResults()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let service = NoiseEncryptionService(keychain: storage)
            results.append(service.getIdentityFingerprint())
        }
        #expect(results.values.count == 8)
        #expect(results.values.allSatisfy { $0 != nil })
        #expect(Set(results.values).count == 1)
        #expect(storage.identitySaveCount == 3)
    }
}

private final class NoiseIdentityResults: @unchecked Sendable {
    private let lock = NSLock()
    private var fingerprints: [String?] = []
    func append(_ value: String?) { lock.lock(); defer { lock.unlock() }; fingerprints.append(value) }
    var values: [String?] { lock.lock(); defer { lock.unlock() }; return fingerprints }
}
