// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
import BitFoundation
import CryptoKit
import Foundation
import Testing
@testable import bitchat

@Suite("Noise identity journal", .serialized)
struct NoiseIdentityJournalTests {
    private let journalKey = "noiseIdentityPending.v1"
    private let noiseKey = "noiseStaticKey"
    private let signingKey = "ed25519SigningKey"

    private func journal(noise: Data, signing: Data) -> Data {
        var data = Data("WESHNOIS".utf8)
        data.append(1)
        data.append(noise)
        data.append(signing)
        return data
    }

    @Test func journalIsConfirmedBeforeEitherLegacyWriteAndThenCleanedUp() throws {
        let storage = MockKeychain()
        var savedJournal: Data?
        var writeOrder: [String] = []
        storage.identitySaveFault = { key, data, _ in
            writeOrder.append(key)
            if key == journalKey { savedJournal = data }
            if key == noiseKey || key == signingKey {
                #expect(storage.getIdentityKey(forKey: journalKey) == savedJournal)
                #expect(savedJournal?.count == 73)
            }
            return nil
        }
        let service = NoiseEncryptionService(keychain: storage)
        let saved = try #require(savedJournal)
        #expect(writeOrder == [journalKey, noiseKey, signingKey])
        #expect(saved.prefix(8) == Data("WESHNOIS".utf8))
        #expect(saved[8] == 1)
        #expect(Data(saved[9..<41]) == storage.getIdentityKey(forKey: noiseKey))
        #expect(Data(saved[41..<73]) == storage.getIdentityKey(forKey: signingKey))
        #expect(service.identityAvailability == .available)
        #expect(storage.getIdentityKey(forKey: journalKey) == nil)
        #expect(storage.identityDeleteCount == 1)
    }

    /// A Keychain call parked in one store must not stall identity setup on an
    /// unrelated store. The lock used to be process-wide: one test holding it
    /// while it waited for its own task starved Swift's cooperative pool in
    /// parallel CI runs, and nothing could release it.
    @Test func identitySetupOnOneStoreNeverWaitsForAnotherStore() async throws {
        let parked = MockKeychain()
        let gate = ParkedKeychainCall()
        parked.identitySaveFault = { key, _, _ in
            if key == journalKey { gate.park() }
            return nil
        }
        let holder = Thread { _ = NoiseEncryptionService(keychain: parked); gate.finish() }
        holder.start()
        defer { gate.release() }
        #expect(await TestHelpers.waitUntil({ gate.isParked }, timeout: TestConstants.longTimeout))

        let unrelated = ParkedKeychainCall()
        let other = Thread {
            _ = NoiseEncryptionService(keychain: MockKeychain())
            unrelated.finish()
        }
        other.start()
        #expect(await TestHelpers.waitUntil({ unrelated.isFinished }, timeout: TestConstants.longTimeout))

        gate.release()
        #expect(await TestHelpers.waitUntil({ gate.isFinished }, timeout: TestConstants.longTimeout))
    }

    @Test func unconfirmedJournalNeverWritesLegacyAndRetriesTheExactRAMCandidate() throws {
        for fault: KeychainSaveResult in [.accessDenied, .success] {
            let storage = MockKeychain()
            var attempts: [Data] = []
            storage.identitySaveFault = { key, data, _ in
                guard key == journalKey else { return nil }
                attempts.append(data)
                return fault // .success deliberately does not store anything.
            }
            let service = NoiseEncryptionService(keychain: storage)
            #expect(service.identityAvailability == .persistenceUnconfirmed)
            #expect(service.getStaticPublicKeyData() == nil)
            #expect(storage.getIdentityKey(forKey: noiseKey) == nil)
            #expect(storage.getIdentityKey(forKey: signingKey) == nil)
            #expect(storage.identitySaveCount == 1)
            let candidate = try #require(attempts.first)
            storage.identitySaveFault = { key, data, _ in
                if key == journalKey { attempts.append(data) }
                return nil
            }
            #expect(service.retryIdentityPersistence())
            #expect(attempts.count == 2)
            #expect(attempts[1] == candidate)
            #expect(storage.getIdentityKey(forKey: noiseKey) == Data(candidate[9..<41]))
            #expect(storage.getIdentityKey(forKey: signingKey) == Data(candidate[41..<73]))
        }
    }

    @Test func unavailableOrMismatchedJournalReadbackCannotStartLegacyWrites() throws {
        for fault: KeychainReadResult in [.deviceLocked, .itemNotFound, .success(Data([1]))] {
            let storage = MockKeychain()
            var journalReads = 0
            storage.identityReadFault = { key, _ in
                guard key == journalKey else { return nil }
                journalReads += 1
                return journalReads >= 2 ? fault : nil
            }
            var interrupted: NoiseEncryptionService? = NoiseEncryptionService(keychain: storage)
            #expect(interrupted?.identityAvailability == .persistenceUnconfirmed)
            #expect(storage.identitySaveCount == 1)
            #expect(storage.getIdentityKey(forKey: noiseKey) == nil)
            let persisted = try #require(storage.getIdentityKey(forKey: journalKey))
            interrupted = nil
            storage.identityReadFault = nil
            let restarted = NoiseEncryptionService(keychain: storage)
            #expect(restarted.identityAvailability == .available)
            #expect(storage.getIdentityKey(forKey: noiseKey) == Data(persisted[9..<41]))
            #expect(storage.getIdentityKey(forKey: signingKey) == Data(persisted[41..<73]))
            #expect(storage.identitySaveCount == 3)
        }
    }

    @Test func restartAfterJournalBeforeFirstLegacyWriteUsesOnlyTheDurablePair() throws {
        let storage = MockKeychain()
        storage.identitySaveFault = { key, _, _ in key == noiseKey ? .accessDenied : nil }
        var interrupted: NoiseEncryptionService? = NoiseEncryptionService(keychain: storage)
        #expect(interrupted?.identityAvailability == .persistenceUnconfirmed)
        let persisted = try #require(storage.getIdentityKey(forKey: journalKey))
        #expect(storage.getIdentityKey(forKey: noiseKey) == nil)
        #expect(storage.getIdentityKey(forKey: signingKey) == nil)
        interrupted = nil
        storage.identitySaveFault = nil
        let restarted = NoiseEncryptionService(keychain: storage)
        #expect(restarted.identityAvailability == .available)
        #expect(storage.getIdentityKey(forKey: noiseKey) == Data(persisted[9..<41]))
        #expect(storage.getIdentityKey(forKey: signingKey) == Data(persisted[41..<73]))
    }

    @Test func restartAfterBothLegacyWritesNeedsNoRewritesAndCleansMatchingJournal() throws {
        let storage = MockKeychain()
        var legacyWritesCompleted = false
        storage.identitySaveFault = { key, _, _ in
            if key == signingKey { legacyWritesCompleted = true }
            return nil
        }
        storage.identityReadFault = { key, _ in
            legacyWritesCompleted && key == noiseKey ? .deviceLocked : nil
        }
        var interrupted: NoiseEncryptionService? = NoiseEncryptionService(keychain: storage)
        #expect(interrupted?.identityAvailability == .persistenceUnconfirmed)
        let noise = try #require(storage.getIdentityKey(forKey: noiseKey))
        let signing = try #require(storage.getIdentityKey(forKey: signingKey))
        #expect(storage.getIdentityKey(forKey: journalKey) != nil)
        interrupted = nil
        storage.identityReadFault = nil
        storage.identitySaveFault = nil
        let restarted = NoiseEncryptionService(keychain: storage)
        #expect(restarted.identityAvailability == .available)
        #expect(storage.identitySaveCount == 3)
        #expect(storage.getIdentityKey(forKey: noiseKey) == noise)
        #expect(storage.getIdentityKey(forKey: signingKey) == signing)
        #expect(storage.getIdentityKey(forKey: journalKey) == nil)
    }

    @Test func cleanupFailureKeepsMatchingJournalWithoutBlockingConfirmedIdentity() throws {
        let storage = MockKeychain()
        storage.identityDeleteFault = { key, _ in key == journalKey ? false : nil }
        let original = NoiseEncryptionService(keychain: storage)
        let persisted = try #require(storage.getIdentityKey(forKey: journalKey))
        #expect(original.identityAvailability == .available)
        let restarted = NoiseEncryptionService(keychain: storage)
        #expect(restarted.identityAvailability == .available)
        #expect(restarted.getStaticPublicKeyData() == original.getStaticPublicKeyData())
        #expect(restarted.getSigningPublicKeyData() == original.getSigningPublicKeyData())
        #expect(storage.identitySaveCount == 3)
        #expect(storage.getIdentityKey(forKey: journalKey) == persisted)
        storage.identityDeleteFault = nil
        let afterRetry = NoiseEncryptionService(keychain: storage)
        #expect(afterRetry.identityAvailability == .available)
        #expect(storage.getIdentityKey(forKey: journalKey) == nil)
        #expect(storage.identitySaveCount == 3)
    }

    @Test func malformedJournalIsPreservedEvenBesideAValidLegacyPair() {
        let noise = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        let signing = Curve25519.Signing.PrivateKey().rawRepresentation
        let valid = journal(noise: noise, signing: signing)
        var wrongVersion = valid; wrongVersion[8] = 2
        var wrongMagic = valid; wrongMagic[0] ^= 0xFF
        for invalid in [Data(), Data(valid.dropLast()), valid + Data([0]), wrongVersion, wrongMagic] {
            let storage = MockKeychain()
            _ = storage.saveIdentityKey(noise, forKey: noiseKey)
            _ = storage.saveIdentityKey(signing, forKey: signingKey)
            _ = storage.saveIdentityKey(invalid, forKey: journalKey)
            let service = NoiseEncryptionService(keychain: storage)
            #expect(service.identityAvailability == .recoveryRequired)
            #expect(!service.retryIdentityPersistence())
            #expect(storage.identitySaveCount == 0)
            #expect(storage.identityDeleteCount == 0)
            #expect(storage.getIdentityKey(forKey: journalKey) == invalid)
            #expect(storage.getIdentityKey(forKey: noiseKey) == noise)
            #expect(storage.getIdentityKey(forKey: signingKey) == signing)
        }
    }

    @Test func divergentOrMalformedLegacyValueNeverOverwritesOrDeletesJournal() {
        let noise = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        let signing = Curve25519.Signing.PrivateKey().rawRepresentation
        let persisted = journal(noise: noise, signing: signing)
        for key in [noiseKey, signingKey] {
            for divergent in [Data([1]), Curve25519.KeyAgreement.PrivateKey().rawRepresentation] {
                let storage = MockKeychain()
                _ = storage.saveIdentityKey(persisted, forKey: journalKey)
                _ = storage.saveIdentityKey(divergent, forKey: key)
                let service = NoiseEncryptionService(keychain: storage)
                #expect(service.identityAvailability == .recoveryRequired)
                #expect(!service.retryIdentityPersistence())
                #expect(storage.identitySaveCount == 0)
                #expect(storage.identityDeleteCount == 0)
                #expect(storage.getIdentityKey(forKey: journalKey) == persisted)
                #expect(storage.getIdentityKey(forKey: key) == divergent)
            }
        }
    }

    @Test func journalReadFailurePreservesValidLegacyPairAndRecoversWithoutWrites() {
        let noise = Curve25519.KeyAgreement.PrivateKey()
        let signing = Curve25519.Signing.PrivateKey()
        for fault: KeychainReadResult in [.deviceLocked, .authenticationFailed, .accessDenied, .otherError(-50)] {
            let storage = MockKeychain()
            _ = storage.saveIdentityKey(noise.rawRepresentation, forKey: noiseKey)
            _ = storage.saveIdentityKey(signing.rawRepresentation, forKey: signingKey)
            storage.identityReadFault = { key, _ in key == journalKey ? fault : nil }
            let service = NoiseEncryptionService(keychain: storage)
            #expect(service.identityAvailability == .storageUnavailable)
            #expect(storage.identitySaveCount == 0)
            #expect(storage.identityDeleteCount == 0)
            storage.identityReadFault = nil
            #expect(service.retryIdentityPersistence())
            #expect(service.getStaticPublicKeyData() == noise.publicKey.rawRepresentation)
            #expect(service.getSigningPublicKeyData() == signing.publicKey.rawRepresentation)
            #expect(storage.identitySaveCount == 0)
            #expect(storage.identityDeleteCount == 0)
        }
    }

    @Test func aDivergentJournalDoesNotReplaceAnUnconfirmedRAMCandidate() {
        let storage = MockKeychain()
        storage.simulatedSaveError = .accessDenied
        let service = NoiseEncryptionService(keychain: storage)
        #expect(service.identityAvailability == .persistenceUnconfirmed)
        storage.simulatedSaveError = nil
        let other = journal(noise: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
                            signing: Curve25519.Signing.PrivateKey().rawRepresentation)
        _ = storage.saveIdentityKey(other, forKey: journalKey)
        #expect(!service.retryIdentityPersistence())
        #expect(service.identityAvailability == .recoveryRequired)
        #expect(storage.identitySaveCount == 1)
        #expect(storage.getIdentityKey(forKey: journalKey) == other)
        #expect(storage.getIdentityKey(forKey: noiseKey) == nil)
        #expect(storage.getIdentityKey(forKey: signingKey) == nil)
    }

    @Test func changesBetweenJournalPersistenceAndLegacyWritesNeverAuthorizeReplacement() {
        for key in [noiseKey, signingKey] {
            for failRead in [false, true] {
                let storage = MockKeychain()
                let divergent = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
                storage.identitySaveFault = { name, _, _ in
                    guard name == journalKey else { return nil }
                    if failRead {
                        storage.identityReadFault = { name, _ in name == key ? .deviceLocked : nil }
                    } else {
                        _ = storage.saveIdentityKey(divergent, forKey: key)
                    }
                    return nil
                }
                let service = NoiseEncryptionService(keychain: storage)
                #expect(service.identityAvailability == (failRead ? .storageUnavailable : .recoveryRequired))
                #expect(storage.identitySaveCount == 1)
                #expect(storage.getIdentityKey(forKey: journalKey) != nil)
                #expect(storage.getIdentityKey(forKey: key) == (failRead ? nil : divergent))
                #expect(storage.getIdentityKey(forKey: key == noiseKey ? signingKey : noiseKey) == nil)
                #expect(storage.identityDeleteCount == 0)
            }
        }
    }

    @Test func validJournalDataSliceUsesNormalizedIndices() {
        let noise = Curve25519.KeyAgreement.PrivateKey()
        let signing = Curve25519.Signing.PrivateKey()
        let storage = MockKeychain()
        let sliced = (Data([0xFF]) + journal(noise: noise.rawRepresentation, signing: signing.rawRepresentation)).dropFirst()
        _ = storage.saveIdentityKey(sliced, forKey: journalKey)
        let service = NoiseEncryptionService(keychain: storage)
        #expect(service.identityAvailability == .available)
        #expect(service.getStaticPublicKeyData() == noise.publicKey.rawRepresentation)
        #expect(service.getSigningPublicKeyData() == signing.publicKey.rawRepresentation)
    }

    @Test func panicAttemptsAllDeletionsAndNeverResurrectsTheInvalidatedInstance() {
        for failingKey in [journalKey, noiseKey, signingKey] {
            let storage = MockKeychain()
            storage.identityDeleteFault = { key, _ in key == journalKey ? false : nil }
            let service = NoiseEncryptionService(keychain: storage)
            #expect(service.isIdentityAvailable)
            let deletesBefore = storage.identityDeleteCount
            var deletedKeys: [String] = []
            storage.identityDeleteFault = { key, _ in
                deletedKeys.append(key)
                return key == failingKey ? false : nil
            }
            #expect(!service.clearPersistentIdentity())
            #expect(service.identityAvailability == .invalidated)
            #expect(!service.retryIdentityPersistence())
            #expect(service.getStaticPublicKeyData() == nil)
            #expect(service.signData(Data([1])) == nil)
            #expect(deletedKeys.contains(journalKey))
            #expect(deletedKeys.contains(noiseKey))
            #expect(deletedKeys.contains(signingKey))
            #expect(storage.identityDeleteCount - deletesBefore == 4)
            storage.identityDeleteFault = nil
            #expect(!service.retryIdentityPersistence())
        }
    }
}

/// Parks a Keychain call on a plain thread until released; never used from
/// the Swift cooperative pool, which must not be blocked indefinitely.
private final class ParkedKeychainCall: @unchecked Sendable {
    private let condition = NSCondition()
    private var parked = false
    private var released = false
    private var finished = false

    var isParked: Bool { condition.lock(); defer { condition.unlock() }; return parked }
    var isFinished: Bool { condition.lock(); defer { condition.unlock() }; return finished }

    func park() {
        condition.lock(); defer { condition.unlock() }
        parked = true
        condition.broadcast()
        while !released { condition.wait() }
    }

    func release() {
        condition.lock(); defer { condition.unlock() }
        released = true
        condition.broadcast()
    }

    func finish() {
        condition.lock(); defer { condition.unlock() }
        finished = true
    }
}
