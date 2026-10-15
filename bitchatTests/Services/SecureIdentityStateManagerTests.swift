import Foundation
import XCTest
import CryptoKit
import BitFoundation
@testable import bitchat

final class SecureIdentityStateManagerTests: XCTestCase {
    func test_getBlockedFingerprints_preservesOfflineIdentitiesAcrossReloadAndExactUnblock() {
        let keychain = MockKeychain()
        let manager = SecureIdentityStateManager(keychain)
        let fingerprintA = Data(repeating: 0xA7, count: 32).sha256Fingerprint()
        let fingerprintB = Data(repeating: 0xB8, count: 32).sha256Fingerprint()
        let favoriteFingerprint = Data(repeating: 0xC9, count: 32).sha256Fingerprint()
        XCTAssertTrue(manager.getBlockedFingerprints().isEmpty)

        // No crypto or ephemeral peer entries: both offline people share a
        // display name, but their durable block records remain independent.
        for fingerprint in [fingerprintA, fingerprintB] {
            manager.updateSocialIdentity(SocialIdentity(fingerprint: fingerprint, localPetname: nil, claimedNickname: "Alex", trustLevel: .verified, isFavorite: false, isBlocked: true, notes: nil))
        }
        manager.setFavorite(favoriteFingerprint, isFavorite: true)
        manager.setNostrBlocked(String(repeating: "dd", count: 32), isBlocked: true)
        manager.forceSave()

        let reloaded = SecureIdentityStateManager(keychain)
        XCTAssertEqual(reloaded.getBlockedFingerprints(), Set([fingerprintA, fingerprintB]))
        reloaded.setBlocked(fingerprintA, isBlocked: false)
        XCTAssertEqual(reloaded.getBlockedFingerprints(), Set([fingerprintB]))
        XCTAssertEqual(reloaded.getSocialIdentity(for: fingerprintA)?.trustLevel, .verified)
        XCTAssertEqual(reloaded.getSocialIdentity(for: fingerprintB)?.claimedNickname, "Alex")
        reloaded.forceSave()

        let reloadedAgain = SecureIdentityStateManager(keychain)
        XCTAssertEqual(reloadedAgain.getBlockedFingerprints(), Set([fingerprintB]))
        XCTAssertFalse(reloadedAgain.isBlocked(fingerprint: fingerprintA))
        XCTAssertTrue(reloadedAgain.isFavorite(fingerprint: favoriteFingerprint))
    }

    func test_upsertCryptographicIdentity_withoutClaimedNicknameDoesNotCreateSocialIdentity() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "aa", count: 32)
        let peerID = PeerID(str: String(fingerprint.prefix(16)))

        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: Data(repeating: 0x11, count: 32),
            signingPublicKey: Data(repeating: 0x22, count: 32),
            claimedNickname: nil
        )

        let inserted = await waitUntil {
            manager.getCryptoIdentitiesByPeerIDPrefix(peerID).count == 1
        }
        XCTAssertTrue(inserted)
        XCTAssertNil(manager.getSocialIdentity(for: fingerprint))
    }

    func test_upsertCryptographicIdentity_updatesExistingKeyAndPreservesSigningKey() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "ab", count: 32)
        let peerID = PeerID(str: String(fingerprint.prefix(16)))
        let originalNoiseKey = Data(repeating: 0x11, count: 32)
        let updatedNoiseKey = Data(repeating: 0x33, count: 32)
        let signingKey = Data(repeating: 0x22, count: 32)

        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: originalNoiseKey,
            signingPublicKey: signingKey,
            claimedNickname: nil
        )
        _ = await waitUntil {
            manager.getCryptoIdentitiesByPeerIDPrefix(peerID).first?.publicKey == originalNoiseKey
        }

        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: updatedNoiseKey,
            signingPublicKey: nil,
            claimedNickname: nil
        )

        let updated = await waitUntil {
            guard let identity = manager.getCryptoIdentitiesByPeerIDPrefix(peerID).first else { return false }
            return identity.publicKey == updatedNoiseKey && identity.signingPublicKey == signingKey
        }
        XCTAssertTrue(updated)
    }

    func test_upsertCryptographicIdentity_tracksByPeerIDPrefixAndClaimedNickname() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let noisePublicKey = Data(repeating: 0x11, count: 32)
        let signingPublicKey = Data(repeating: 0x22, count: 32)
        let fingerprint = noisePublicKey.sha256Fingerprint()

        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: noisePublicKey,
            signingPublicKey: signingPublicKey,
            claimedNickname: "Alice"
        )

        let socialIdentityLoaded = await waitUntil {
            manager.getSocialIdentity(for: fingerprint)?.claimedNickname == "Alice"
        }
        XCTAssertTrue(socialIdentityLoaded)
        let matches = manager.getCryptoIdentitiesByPeerIDPrefix(PeerID(publicKey: noisePublicKey))
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.fingerprint, fingerprint)
        XCTAssertEqual(matches.first?.publicKey, noisePublicKey)
        XCTAssertEqual(matches.first?.signingPublicKey, signingPublicKey)
    }

    func test_upsertCryptographicIdentity_refusesToReplacePinnedSigningKey() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let noisePublicKey = Data(repeating: 0x11, count: 32)
        let fingerprint = noisePublicKey.sha256Fingerprint()
        let peerID = PeerID(publicKey: noisePublicKey)
        let victimSigningKey = Data(repeating: 0x22, count: 32)
        let attackerSigningKey = Data(repeating: 0x66, count: 32)

        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: noisePublicKey,
            signingPublicKey: victimSigningKey,
            claimedNickname: "victim"
        )
        let pinned = await waitUntil {
            manager.getCryptoIdentitiesByPeerIDPrefix(peerID).first?.signingPublicKey == victimSigningKey
        }
        XCTAssertTrue(pinned)

        // Attacker upsert with a different signing key must be refused in
        // full — signing key AND claimed nickname stay the victim's.
        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: noisePublicKey,
            signingPublicKey: attackerSigningKey,
            claimedNickname: "attacker"
        )

        // Synchronous reads fence the manager's pending barrier writes.
        XCTAssertEqual(
            manager.getCryptoIdentitiesByPeerIDPrefix(peerID).first?.signingPublicKey,
            victimSigningKey
        )
        XCTAssertEqual(manager.getSocialIdentity(for: fingerprint)?.claimedNickname, "victim")

        // The legitimate peer (same signing key) can still update.
        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: noisePublicKey,
            signingPublicKey: victimSigningKey,
            claimedNickname: "victim-renamed"
        )
        let renamed = await waitUntil {
            manager.getSocialIdentity(for: fingerprint)?.claimedNickname == "victim-renamed"
        }
        XCTAssertTrue(renamed)
        XCTAssertEqual(
            manager.getCryptoIdentitiesByPeerIDPrefix(peerID).first?.signingPublicKey,
            victimSigningKey
        )
    }

    func test_cryptographicIdentity_persistsAcrossReinitAndKeepsSigningKeyPin() async {
        let keychain = MockKeychain()
        let manager = SecureIdentityStateManager(keychain)
        let noisePublicKey = Data(repeating: 0x13, count: 32)
        let fingerprint = noisePublicKey.sha256Fingerprint()
        let peerID = PeerID(publicKey: noisePublicKey)
        let victimSigningKey = Data(repeating: 0x24, count: 32)
        let attackerSigningKey = Data(repeating: 0x77, count: 32)

        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: noisePublicKey,
            signingPublicKey: victimSigningKey,
            claimedNickname: "victim"
        )
        let pinned = await waitUntil {
            manager.getCryptoIdentitiesByPeerIDPrefix(peerID).first?.signingPublicKey == victimSigningKey
        }
        XCTAssertTrue(pinned)
        manager.forceSave()

        // Simulated app restart: the pin must survive and still refuse a
        // different signing key.
        let reloaded = SecureIdentityStateManager(keychain)
        XCTAssertEqual(
            reloaded.getCryptoIdentitiesByPeerIDPrefix(peerID).first?.signingPublicKey,
            victimSigningKey
        )

        reloaded.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: noisePublicKey,
            signingPublicKey: attackerSigningKey,
            claimedNickname: "attacker"
        )
        XCTAssertEqual(
            reloaded.getCryptoIdentitiesByPeerIDPrefix(peerID).first?.signingPublicKey,
            victimSigningKey
        )
        XCTAssertEqual(reloaded.getSocialIdentity(for: fingerprint)?.claimedNickname, "victim")
    }

    func test_setBlocked_clearsFavoriteState() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "ab", count: 32)

        manager.setFavorite(fingerprint, isFavorite: true)
        let favoriteSet = await waitUntil { manager.isFavorite(fingerprint: fingerprint) }
        XCTAssertTrue(favoriteSet)

        manager.setBlocked(fingerprint, isBlocked: true)
        let blockedSet = await waitUntil { manager.isBlocked(fingerprint: fingerprint) }
        XCTAssertTrue(blockedSet)

        XCTAssertFalse(manager.isFavorite(fingerprint: fingerprint))
        XCTAssertEqual(manager.getSocialIdentity(for: fingerprint)?.claimedNickname, "Unknown")
    }

    func test_isBlocked_unknownFingerprintReturnsFalse() {
        let manager = SecureIdentityStateManager(MockKeychain())

        XCTAssertFalse(manager.isBlocked(fingerprint: String(repeating: "ff", count: 32)))
    }

    func test_setVerified_updatesTrustLevelAndVerifiedSet() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "cd", count: 32)

        manager.setFavorite(fingerprint, isFavorite: false)
        _ = await waitUntil { manager.getSocialIdentity(for: fingerprint) != nil }
        manager.setVerified(fingerprint: fingerprint, verified: true)

        let verifiedSet = await waitUntil { manager.isVerified(fingerprint: fingerprint) }
        XCTAssertTrue(verifiedSet)
        XCTAssertTrue(manager.getVerifiedFingerprints().contains(fingerprint))
        XCTAssertEqual(manager.getSocialIdentity(for: fingerprint)?.trustLevel, .verified)
    }

    func test_forceSave_persistsFavoriteStateAcrossReinit() async {
        let keychain = MockKeychain()
        let manager = SecureIdentityStateManager(keychain)
        let fingerprint = String(repeating: "ef", count: 32)

        manager.setFavorite(fingerprint, isFavorite: true)
        let favoriteSet = await waitUntil { manager.isFavorite(fingerprint: fingerprint) }
        XCTAssertTrue(favoriteSet)
        manager.forceSave()

        let reloaded = SecureIdentityStateManager(keychain)
        XCTAssertTrue(reloaded.isFavorite(fingerprint: fingerprint))
    }

    func test_updateSocialIdentity_reindexesClaimedNickname() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "34", count: 32)

        manager.updateSocialIdentity(
            SocialIdentity(
                fingerprint: fingerprint,
                localPetname: nil,
                claimedNickname: "Alice",
                trustLevel: .unknown,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            )
        )
        let initialIndexed = await waitUntil {
            manager.debugNicknameIndex["Alice"]?.contains(fingerprint) == true
        }
        XCTAssertTrue(initialIndexed)

        manager.updateSocialIdentity(
            SocialIdentity(
                fingerprint: fingerprint,
                localPetname: "Friend",
                claimedNickname: "Bob",
                trustLevel: .trusted,
                isFavorite: true,
                isBlocked: false,
                notes: "updated"
            )
        )

        let reindexed = await waitUntil {
            manager.debugNicknameIndex["Alice"]?.contains(fingerprint) != true &&
            manager.debugNicknameIndex["Bob"]?.contains(fingerprint) == true
        }
        XCTAssertTrue(reindexed)
        XCTAssertEqual(manager.getSocialIdentity(for: fingerprint)?.claimedNickname, "Bob")
    }

    func test_upsertCryptographicIdentity_sameClaimedNicknamePreservesExistingSocialIdentity() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "35", count: 32)

        manager.updateSocialIdentity(
            SocialIdentity(
                fingerprint: fingerprint,
                localPetname: "Pal",
                claimedNickname: "Alice",
                trustLevel: .trusted,
                isFavorite: true,
                isBlocked: false,
                notes: "keep me"
            )
        )
        _ = await waitUntil { manager.getSocialIdentity(for: fingerprint) != nil }

        manager.upsertCryptographicIdentity(
            fingerprint: fingerprint,
            noisePublicKey: Data(repeating: 0x11, count: 32),
            signingPublicKey: Data(repeating: 0x22, count: 32),
            claimedNickname: "Alice"
        )

        let inserted = await waitUntil {
            manager.getCryptoIdentitiesByPeerIDPrefix(PeerID(str: String(fingerprint.prefix(16)))).count == 1
        }
        XCTAssertTrue(inserted)
        XCTAssertEqual(manager.getSocialIdentity(for: fingerprint)?.localPetname, "Pal")
        XCTAssertEqual(manager.getSocialIdentity(for: fingerprint)?.notes, "keep me")
        XCTAssertTrue(manager.getSocialIdentity(for: fingerprint)?.isFavorite == true)
    }

    func test_getFavorites_returnsOnlyFavoritedFingerprints() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let favoriteOne = String(repeating: "45", count: 32)
        let favoriteTwo = String(repeating: "56", count: 32)
        let other = String(repeating: "67", count: 32)

        manager.setFavorite(favoriteOne, isFavorite: true)
        manager.setFavorite(favoriteTwo, isFavorite: true)
        manager.setFavorite(other, isFavorite: false)

        let favoritesLoaded = await waitUntil {
            manager.getFavorites() == Set([favoriteOne, favoriteTwo])
        }
        XCTAssertTrue(favoritesLoaded)
    }

    func test_setFavorite_existingIdentityCanBeClearedWithoutChangingNickname() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "68", count: 32)

        manager.updateSocialIdentity(
            SocialIdentity(
                fingerprint: fingerprint,
                localPetname: nil,
                claimedNickname: "Alice",
                trustLevel: .trusted,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            )
        )
        _ = await waitUntil { manager.getSocialIdentity(for: fingerprint) != nil }

        manager.setFavorite(fingerprint, isFavorite: true)
        _ = await waitUntil { manager.isFavorite(fingerprint: fingerprint) }

        manager.setFavorite(fingerprint, isFavorite: false)
        let cleared = await waitUntil {
            !manager.isFavorite(fingerprint: fingerprint) &&
            manager.getSocialIdentity(for: fingerprint)?.claimedNickname == "Alice" &&
            manager.getSocialIdentity(for: fingerprint)?.trustLevel == .trusted
        }
        XCTAssertTrue(cleared)
    }

    func test_setBlocked_createsIdentityAndCanLaterUnblock() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "78", count: 32)

        manager.setBlocked(fingerprint, isBlocked: true)
        let blocked = await waitUntil {
            manager.isBlocked(fingerprint: fingerprint)
        }
        XCTAssertTrue(blocked)
        XCTAssertEqual(manager.getSocialIdentity(for: fingerprint)?.claimedNickname, "Unknown")

        manager.setBlocked(fingerprint, isBlocked: false)
        let unblocked = await waitUntil {
            !manager.isBlocked(fingerprint: fingerprint)
        }
        XCTAssertTrue(unblocked)
    }

    func test_setVerified_false_downgradesTrustLevelToCasual() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "89", count: 32)

        manager.updateSocialIdentity(
            SocialIdentity(
                fingerprint: fingerprint,
                localPetname: nil,
                claimedNickname: "Verifier",
                trustLevel: .trusted,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            )
        )
        _ = await waitUntil { manager.getSocialIdentity(for: fingerprint) != nil }

        manager.setVerified(fingerprint: fingerprint, verified: true)
        _ = await waitUntil { manager.isVerified(fingerprint: fingerprint) }

        manager.setVerified(fingerprint: fingerprint, verified: false)
        let downgraded = await waitUntil {
            !manager.isVerified(fingerprint: fingerprint) &&
            manager.getSocialIdentity(for: fingerprint)?.trustLevel == .casual
        }
        XCTAssertTrue(downgraded)
    }

    func test_ephemeralSessionLifecycle_tracksHandshakeProgressAndLastInteraction() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let peerID = PeerID(str: "1234567890abcdef")
        let fingerprint = String(repeating: "90", count: 32)

        manager.registerEphemeralSession(peerID: peerID, handshakeState: .initiated)
        let registered = await waitUntil {
            if case .initiated? = manager.debugEphemeralSession(for: peerID)?.handshakeState {
                return true
            }
            return false
        }
        XCTAssertTrue(registered)

        manager.updateHandshakeState(peerID: peerID, state: .inProgress)
        let progressed = await waitUntil {
            if case .inProgress? = manager.debugEphemeralSession(for: peerID)?.handshakeState {
                return true
            }
            return false
        }
        XCTAssertTrue(progressed)

        manager.updateHandshakeState(peerID: peerID, state: .completed(fingerprint: fingerprint))
        let completed = await waitUntil {
            if case .completed(let completedFingerprint)? = manager.debugEphemeralSession(for: peerID)?.handshakeState {
                return completedFingerprint == fingerprint && manager.debugLastInteraction(for: fingerprint) != nil
            }
            return false
        }
        XCTAssertTrue(completed)

        manager.removeEphemeralSession(peerID: peerID)
        let removed = await waitUntil {
            manager.debugEphemeralSession(for: peerID) == nil
        }
        XCTAssertTrue(removed)
    }

    func test_setNostrBlocked_normalizesToLowercaseAndPersists() async {
        let keychain = MockKeychain()
        let manager = SecureIdentityStateManager(keychain)
        let pubkey = "ABCDEF1234"

        manager.setNostrBlocked(pubkey, isBlocked: true)
        let nostrBlocked = await waitUntil {
            manager.isNostrBlocked(pubkeyHexLowercased: pubkey.lowercased())
        }
        XCTAssertTrue(nostrBlocked)
        manager.forceSave()

        let reloaded = SecureIdentityStateManager(keychain)
        XCTAssertEqual(reloaded.getBlockedNostrPubkeys(), Set([pubkey.lowercased()]))
        XCTAssertTrue(reloaded.isNostrBlocked(pubkeyHexLowercased: pubkey))
    }

    func test_setNostrBlocked_falseRemovesExistingKey() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let pubkey = "ABCDEF1234"

        manager.setNostrBlocked(pubkey, isBlocked: true)
        _ = await waitUntil { manager.isNostrBlocked(pubkeyHexLowercased: pubkey) }

        manager.setNostrBlocked(pubkey, isBlocked: false)
        let cleared = await waitUntil {
            !manager.isNostrBlocked(pubkeyHexLowercased: pubkey) &&
            manager.getBlockedNostrPubkeys().isEmpty
        }
        XCTAssertTrue(cleared)
    }

    func test_corruptPersistedCache_preservesStoredBlobAndBlocksWrites() {
        let keychain = MockKeychain()
        _ = keychain.saveIdentityKey(Data(repeating: 0x01, count: 32), forKey: "identityCacheEncryptionKey")
        _ = keychain.saveIdentityKey(Data([0xFF, 0x00, 0xAA]), forKey: "bitchat.identityCache.v2")

        let manager = SecureIdentityStateManager(keychain)

        XCTAssertTrue(manager.getFavorites().isEmpty)
        XCTAssertTrue(manager.getVerifiedFingerprints().isEmpty)
        XCTAssertTrue(manager.getBlockedNostrPubkeys().isEmpty)
        XCTAssertFalse(manager.isPersistenceAvailable)
        manager.setFavorite("new-peer", isFavorite: true)
        manager.forceSave()
        XCTAssertFalse(manager.isFavorite(fingerprint: "new-peer"))
        XCTAssertEqual(keychain.getIdentityKey(forKey: "bitchat.identityCache.v2"), Data([0xFF, 0x00, 0xAA]))
    }

    func test_clearAllIdentityData_removesCachedState() async {
        let manager = SecureIdentityStateManager(MockKeychain())
        let fingerprint = String(repeating: "12", count: 32)

        manager.setFavorite(fingerprint, isFavorite: true)
        manager.setVerified(fingerprint: fingerprint, verified: true)
        manager.setNostrBlocked("ABCD", isBlocked: true)
        let primed = await waitUntil {
            manager.isFavorite(fingerprint: fingerprint) &&
            manager.isVerified(fingerprint: fingerprint)
        }
        XCTAssertTrue(primed)

        manager.clearAllIdentityData()
        let cleared = await waitUntil {
            !manager.isFavorite(fingerprint: fingerprint) &&
            !manager.isVerified(fingerprint: fingerprint) &&
            manager.getBlockedNostrPubkeys().isEmpty
        }
        XCTAssertTrue(cleared)
    }

    func test_privateMediaCapabilityPinPersistsMonotonicallyAndPanicClearRemovesIt() async {
        let keychain = MockKeychain()
        let fingerprint = Data(repeating: 0x42, count: 32).sha256Fingerprint()
        let manager = SecureIdentityStateManager(keychain)

        XCTAssertFalse(manager.hasObservedPrivateMediaCapability(fingerprint: fingerprint))
        manager.markPrivateMediaCapable(fingerprint: fingerprint)
        XCTAssertTrue(
            manager.hasObservedPrivateMediaCapability(fingerprint: fingerprint),
            "pin insertion must be synchronously visible to the next downgrade decision"
        )

        // Re-marking is idempotent, and the encrypted cache carries the pin
        // across launches.
        manager.markPrivateMediaCapable(fingerprint: fingerprint)
        manager.forceSave()
        let reloaded = SecureIdentityStateManager(keychain)
        XCTAssertTrue(reloaded.hasObservedPrivateMediaCapability(fingerprint: fingerprint))

        // ChatViewModel's panic path calls this same wipe after deleting
        // keychain data; the in-memory pin must disappear immediately too.
        reloaded.clearAllIdentityData()
        let cleared = await waitUntil {
            !reloaded.hasObservedPrivateMediaCapability(fingerprint: fingerprint)
        }
        XCTAssertTrue(cleared)
    }

    func test_noiseAuthenticatedSigningKeyBindingPersistsAndPanicClearRemovesIt() async {
        let keychain = MockKeychain()
        let fingerprint = Data(repeating: 0x31, count: 32).sha256Fingerprint()
        let firstKey = Data(repeating: 0x41, count: 32)
        let rotatedKey = Data(repeating: 0x42, count: 32)
        let manager = SecureIdentityStateManager(keychain)

        manager.bindAuthenticatedSigningPublicKey(firstKey, fingerprint: fingerprint)
        XCTAssertEqual(manager.authenticatedSigningPublicKey(forFingerprint: fingerprint), firstKey)
        // A later authenticated Noise session may legitimately rotate the
        // announcement signing key.
        manager.bindAuthenticatedSigningPublicKey(rotatedKey, fingerprint: fingerprint)
        XCTAssertEqual(manager.authenticatedSigningPublicKey(forFingerprint: fingerprint), rotatedKey)

        manager.forceSave()
        let reloaded = SecureIdentityStateManager(keychain)
        XCTAssertEqual(reloaded.authenticatedSigningPublicKey(forFingerprint: fingerprint), rotatedKey)

        reloaded.clearAllIdentityData()
        let cleared = await waitUntil {
            reloaded.authenticatedSigningPublicKey(forFingerprint: fingerprint) == nil
        }
        XCTAssertTrue(cleared)
    }

    func test_forceSave_withFailingCacheWriteDoesNotPersistCache() async {
        let keychain = FailingCacheSaveKeychain()
        let manager = SecureIdentityStateManager(keychain)
        let fingerprint = String(repeating: "de", count: 32)

        manager.setFavorite(fingerprint, isFavorite: true)
        let primed = await waitUntil { manager.isFavorite(fingerprint: fingerprint) }
        XCTAssertTrue(primed)

        manager.forceSave()

        let reloaded = SecureIdentityStateManager(keychain)
        XCTAssertFalse(reloaded.isFavorite(fingerprint: fingerprint))
    }

    func test_cacheReadFailures_preserveStoredStateAndRequireExplicitRetry() {
        for failure: KeychainReadResult in [.deviceLocked, .authenticationFailed, .accessDenied, .otherError(-1)] {
            let keychain = IdentityCacheFaultKeychain()
            let original = SecureIdentityStateManager(keychain)
            original.setFavorite("favorite", isFavorite: true)
            original.setBlocked("blocked", isBlocked: true)
            original.upsertCryptographicIdentity(fingerprint: "pinned", noisePublicKey: Data(repeating: 1, count: 32), signingPublicKey: Data(repeating: 2, count: 32))
            let stored = keychain.backing.getIdentityKey(forKey: keychain.cacheKey)
            let savesBeforeFailure = keychain.cacheSaveCount
            keychain.cacheReadError = failure

            var unavailable: SecureIdentityStateManager? = SecureIdentityStateManager(keychain)
            XCTAssertFalse(unavailable!.isPersistenceAvailable)
            unavailable!.setFavorite("replacement", isFavorite: true)
            unavailable!.upsertCryptographicIdentity(fingerprint: "pinned", noisePublicKey: Data(repeating: 1, count: 32), signingPublicKey: Data(repeating: 3, count: 32))
            unavailable!.forceSave()
            XCTAssertFalse(unavailable!.isFavorite(fingerprint: "replacement"))
            XCTAssertEqual(keychain.cacheSaveCount, savesBeforeFailure)
            XCTAssertEqual(keychain.backing.getIdentityKey(forKey: keychain.cacheKey), stored)

            keychain.cacheReadError = nil
            unavailable!.forceSave()
            XCTAssertTrue(unavailable!.isPersistenceAvailable)
            XCTAssertTrue(unavailable!.isFavorite(fingerprint: "favorite"))
            XCTAssertTrue(unavailable!.isBlocked(fingerprint: "blocked"))
            XCTAssertEqual(unavailable!.signingPublicKey(forFingerprint: "pinned"), Data(repeating: 2, count: 32))
            XCTAssertEqual(keychain.cacheSaveCount, savesBeforeFailure, "retry only loads; it never writes an empty replacement")
            unavailable!.setFavorite("after-retry", isFavorite: true)
            unavailable = nil
            let reloaded = SecureIdentityStateManager(keychain)
            XCTAssertTrue(reloaded.isFavorite(fingerprint: "favorite"))
            XCTAssertTrue(reloaded.isFavorite(fingerprint: "after-retry"))
        }
    }

    func test_malformedOrUndecryptableCache_isPreservedWithoutWritesOrDeletion() throws {
        let key = Data(repeating: 0x52, count: 32)
        let invalidJSON = try XCTUnwrap(AES.GCM.seal(Data("not JSON".utf8), using: SymmetricKey(data: key)).combined)
        let invalidSchema = try XCTUnwrap(AES.GCM.seal(Data(#"{"socialIdentities":123}"#.utf8), using: SymmetricKey(data: key)).combined)
        let wrongKey = try XCTUnwrap(AES.GCM.seal(Data("{}".utf8), using: SymmetricKey(data: Data(repeating: 0x53, count: 32))).combined)
        for blob in [Data([0xFF, 0x00]), invalidJSON, invalidSchema, wrongKey] {
            let keychain = IdentityCacheFaultKeychain()
            _ = keychain.backing.saveIdentityKey(key, forKey: keychain.encryptionKeyName)
            _ = keychain.backing.saveIdentityKey(blob, forKey: keychain.cacheKey)
            var manager: SecureIdentityStateManager? = SecureIdentityStateManager(keychain)
            XCTAssertFalse(manager!.isPersistenceAvailable)
            manager!.setBlocked("new", isBlocked: true)
            manager!.forceSave()
            manager = nil
            XCTAssertEqual(keychain.backing.getIdentityKey(forKey: keychain.cacheKey), blob)
            XCTAssertEqual(keychain.cacheSaveCount, 0)
            XCTAssertEqual(keychain.cacheDeleteCount, 0)
        }
    }

    func test_keyReadFailureAndMalformedKey_doNotReplaceKeysAndRecoverOnExplicitRetry() {
        for keyFailure: KeychainReadResult in [.deviceLocked, .authenticationFailed, .accessDenied, .otherError(-2), .success(Data([1]))] {
            let keychain = IdentityCacheFaultKeychain()
            let original = SecureIdentityStateManager(keychain)
            original.setFavorite("durable", isFavorite: true)
            let storedKey = keychain.backing.getIdentityKey(forKey: keychain.encryptionKeyName)
            let storedCache = keychain.backing.getIdentityKey(forKey: keychain.cacheKey)
            let keySaveCount = keychain.keySaveCount
            keychain.keyReadError = keyFailure
            let manager = SecureIdentityStateManager(keychain)
            XCTAssertFalse(manager.isPersistenceAvailable)
            manager.setFavorite("replacement", isFavorite: true)
            manager.forceSave()
            XCTAssertEqual(keychain.keySaveCount, keySaveCount)
            XCTAssertEqual(keychain.backing.getIdentityKey(forKey: keychain.encryptionKeyName), storedKey)
            XCTAssertEqual(keychain.backing.getIdentityKey(forKey: keychain.cacheKey), storedCache)
            keychain.keyReadError = nil
            manager.forceSave()
            XCTAssertTrue(manager.isPersistenceAvailable)
            XCTAssertTrue(manager.isFavorite(fingerprint: "durable"))
        }
    }

    func test_missingKeyWithExistingOrUnreadableCache_neverGeneratesReplacementKey() {
        for cacheRead: KeychainReadResult in [.success(Data([1, 2, 3])), .deviceLocked, .authenticationFailed, .accessDenied, .otherError(-3)] {
            let keychain = IdentityCacheFaultKeychain()
            let orphanedBlob = Data([1, 2, 3])
            _ = keychain.backing.saveIdentityKey(orphanedBlob, forKey: keychain.cacheKey)
            keychain.cacheReadError = cacheRead
            let manager = SecureIdentityStateManager(keychain)
            XCTAssertFalse(manager.isPersistenceAvailable)
            XCTAssertTrue(manager.isBlocked(fingerprint: "unknown"))
            XCTAssertTrue(manager.isNostrBlocked(pubkeyHexLowercased: "unknown"))
            manager.setFavorite("new", isFavorite: true)
            manager.forceSave()
            XCTAssertEqual(keychain.keySaveCount, 0)
            XCTAssertEqual(keychain.cacheSaveCount, 0)
            XCTAssertEqual(keychain.cacheDeleteCount, 0)
            XCTAssertEqual(keychain.backing.getIdentityKey(forKey: keychain.cacheKey), orphanedBlob)
            XCTAssertNil(keychain.backing.getIdentityKey(forKey: keychain.encryptionKeyName))
        }
    }

    func test_failedFirstUseKeySave_doesNotPersistOrAcceptCacheUntilRetry() {
        let keychain = IdentityCacheFaultKeychain()
        keychain.keySaveFails = true
        let manager = SecureIdentityStateManager(keychain)
        XCTAssertFalse(manager.isPersistenceAvailable)
        manager.setFavorite("refused", isFavorite: true)
        XCTAssertEqual(keychain.cacheSaveCount, 0)
        keychain.keySaveFails = false
        manager.forceSave()
        XCTAssertTrue(manager.isPersistenceAvailable)
        XCTAssertFalse(manager.isFavorite(fingerprint: "refused"))
        manager.setFavorite("accepted", isFavorite: true)
        XCTAssertTrue(SecureIdentityStateManager(keychain).isFavorite(fingerprint: "accepted"))
    }

    func test_unavailableFirstUseKeyReadback_doesNotPersistCacheAndReusesStoredKeyOnRetry() {
        let keychain = IdentityCacheFaultKeychain()
        keychain.keyReadbackFails = true
        let manager = SecureIdentityStateManager(keychain)
        XCTAssertFalse(manager.isPersistenceAvailable)
        manager.setFavorite("refused", isFavorite: true)
        let storedKey = keychain.backing.getIdentityKey(forKey: keychain.encryptionKeyName)
        XCTAssertNotNil(storedKey)
        XCTAssertEqual(keychain.cacheSaveCount, 0)
        keychain.keyReadbackFails = false
        manager.forceSave()
        XCTAssertTrue(manager.isPersistenceAvailable)
        XCTAssertEqual(keychain.keySaveCount, 1)
        XCTAssertEqual(keychain.backing.getIdentityKey(forKey: keychain.encryptionKeyName), storedKey)
    }

    func test_failedCacheWrite_retainsPendingSnapshotForForceSaveRetry() {
        let keychain = IdentityCacheFaultKeychain()
        let manager = SecureIdentityStateManager(keychain)
        manager.setFavorite("original", isFavorite: true)
        let stored = keychain.backing.getIdentityKey(forKey: keychain.cacheKey)
        keychain.cacheSaveFails = true
        manager.setFavorite("pending", isFavorite: true)
        XCTAssertTrue(manager.hasPendingPersistenceChanges)
        XCTAssertTrue(manager.isFavorite(fingerprint: "pending"))
        XCTAssertEqual(keychain.backing.getIdentityKey(forKey: keychain.cacheKey), stored)
        manager.forceSave()
        XCTAssertTrue(manager.hasPendingPersistenceChanges)
        keychain.cacheSaveFails = false
        manager.forceSave()
        XCTAssertFalse(manager.hasPendingPersistenceChanges)
        let reloaded = SecureIdentityStateManager(keychain)
        XCTAssertTrue(reloaded.isFavorite(fingerprint: "original"))
        XCTAssertTrue(reloaded.isFavorite(fingerprint: "pending"))
    }

    func test_failedVerificationWrite_doesNotExposeTrustUntilExplicitRetryConfirmsStorage() {
        let keychain = IdentityCacheFaultKeychain()
        let manager = SecureIdentityStateManager(keychain)
        manager.setFavorite("verified-peer", isFavorite: true)
        keychain.cacheSaveFails = true
        manager.setVerified(fingerprint: "verified-peer", verified: true)
        XCTAssertTrue(manager.hasPendingPersistenceChanges)
        XCTAssertFalse(manager.isVerified(fingerprint: "verified-peer"))
        XCTAssertTrue(manager.getVerifiedFingerprints().isEmpty)
        XCTAssertTrue(manager.mostRecentlyVerifiedFingerprints(limit: 5, excluding: "other").isEmpty)
        XCTAssertEqual(manager.getSocialIdentity(for: "verified-peer")?.trustLevel, .unknown)
        XCTAssertEqual(manager.effectiveTrustLevel(for: "verified-peer"), .unknown)
        XCTAssertTrue(manager.isBlocked(fingerprint: "any-peer"))
        keychain.cacheSaveFails = false
        manager.forceSave()
        XCTAssertFalse(manager.hasPendingPersistenceChanges)
        XCTAssertTrue(manager.isVerified(fingerprint: "verified-peer"))
        XCTAssertEqual(manager.getVerifiedFingerprints(), ["verified-peer"])
        XCTAssertEqual(manager.getSocialIdentity(for: "verified-peer")?.trustLevel, .verified)
        XCTAssertEqual(manager.effectiveTrustLevel(for: "verified-peer"), .verified)
    }

    func test_unconfirmedCacheReadback_keepsPendingChangesForRetry() {
        for readback: KeychainReadResult in [.deviceLocked, .success(Data([0xFF]))] {
            let keychain = IdentityCacheFaultKeychain()
            let manager = SecureIdentityStateManager(keychain)
            keychain.cacheReadError = readback
            manager.setFavorite("pending", isFavorite: true)
            XCTAssertTrue(manager.hasPendingPersistenceChanges)
            keychain.cacheReadError = nil
            manager.forceSave()
            XCTAssertFalse(manager.hasPendingPersistenceChanges)
            XCTAssertTrue(SecureIdentityStateManager(keychain).isFavorite(fingerprint: "pending"))
        }
    }

    func test_explicitClearAfterUnreadableCache_allowsFreshStateWithoutResurrectingData() {
        let keychain = IdentityCacheFaultKeychain()
        let original = SecureIdentityStateManager(keychain)
        original.setFavorite("old", isFavorite: true)
        keychain.cacheReadError = .deviceLocked
        let manager = SecureIdentityStateManager(keychain)
        XCTAssertFalse(manager.isPersistenceAvailable)
        manager.clearAllIdentityData()
        keychain.cacheReadError = nil
        manager.forceSave()
        XCTAssertTrue(manager.isPersistenceAvailable)
        XCTAssertFalse(manager.isFavorite(fingerprint: "old"))
        manager.setFavorite("new", isFavorite: true)
        let reloaded = SecureIdentityStateManager(keychain)
        XCTAssertFalse(reloaded.isFavorite(fingerprint: "old"))
        XCTAssertTrue(reloaded.isFavorite(fingerprint: "new"))
    }

    func test_clearAfterFullKeychainWipe_revalidatesDurableEncryptionKeyBeforeNewWrites() {
        let keychain = IdentityCacheFaultKeychain()
        let manager = SecureIdentityStateManager(keychain)
        manager.setFavorite("old", isFavorite: true)
        let originalKey = keychain.backing.getIdentityKey(forKey: keychain.encryptionKeyName)
        XCTAssertTrue(keychain.deleteAllKeychainData())
        manager.clearAllIdentityData()
        XCTAssertTrue(manager.isPersistenceAvailable)
        let newKey = keychain.backing.getIdentityKey(forKey: keychain.encryptionKeyName)
        XCTAssertNotNil(newKey)
        XCTAssertNotEqual(newKey, originalKey)
        manager.setFavorite("new", isFavorite: true)
        XCTAssertFalse(manager.hasPendingPersistenceChanges)
        let reloaded = SecureIdentityStateManager(keychain)
        XCTAssertTrue(reloaded.isPersistenceAvailable)
        XCTAssertFalse(reloaded.isFavorite(fingerprint: "old"))
        XCTAssertTrue(reloaded.isFavorite(fingerprint: "new"))
    }

    private func waitUntil(
        timeout: TimeInterval = TestConstants.settleTimeout,
        condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

private final class FailingCacheSaveKeychain: KeychainManagerProtocol {
    private var storage: [String: Data] = [:]
    private var serviceStorage: [String: [String: Data]] = [:]

    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
        if key == "bitchat.identityCache.v2" {
            return false
        }
        storage[key] = keyData
        return true
    }

    func getIdentityKey(forKey key: String) -> Data? {
        storage[key]
    }

    func deleteIdentityKey(forKey key: String) -> Bool {
        storage.removeValue(forKey: key)
        return true
    }

    func deleteAllKeychainData() -> Bool {
        storage.removeAll()
        serviceStorage.removeAll()
        return true
    }

    func secureClear(_ data: inout Data) {
        data = Data()
    }

    func secureClear(_ string: inout String) {
        string = ""
    }

    func verifyIdentityKeyExists() -> Bool {
        storage["identity_noiseStaticKey"] != nil
    }

    func getIdentityKeyWithResult(forKey key: String) -> KeychainReadResult {
        if let data = storage[key] {
            return .success(data)
        }
        return .itemNotFound
    }

    func saveIdentityKeyWithResult(_ keyData: Data, forKey key: String) -> KeychainSaveResult {
        if saveIdentityKey(keyData, forKey: key) {
            return .success
        }
        return .otherError(OSStatus(-1))
    }

    func save(key: String, data: Data, service: String, accessible: CFString?) {
        if serviceStorage[service] == nil {
            serviceStorage[service] = [:]
        }
        serviceStorage[service]?[key] = data
    }

    func load(key: String, service: String) -> Data? {
        serviceStorage[service]?[key]
    }

    func delete(key: String, service: String) {
        serviceStorage[service]?.removeValue(forKey: key)
    }

    func deleteAll(service: String) {
        serviceStorage.removeValue(forKey: service)
    }
}

/// Isolated, per-item faults; this fixture never accesses the real Keychain.
private final class IdentityCacheFaultKeychain: KeychainManagerProtocol {
    let backing = MockKeychain()
    let cacheKey = "bitchat.identityCache.v2"
    let encryptionKeyName = "identityCacheEncryptionKey"
    var cacheReadError: KeychainReadResult?
    var keyReadError: KeychainReadResult?
    var cacheSaveFails = false
    var keySaveFails = false
    var keyReadbackFails = false
    private(set) var cacheSaveCount = 0
    private(set) var keySaveCount = 0
    private(set) var cacheDeleteCount = 0

    func getIdentityKeyWithResult(forKey key: String) -> KeychainReadResult {
        if key == cacheKey, let cacheReadError { return cacheReadError }
        if key == encryptionKeyName {
            if let keyReadError { return keyReadError }
            if keyReadbackFails && keySaveCount > 0 { return .deviceLocked }
        }
        return backing.getIdentityKeyWithResult(forKey: key)
    }
    func saveIdentityKeyWithResult(_ data: Data, forKey key: String) -> KeychainSaveResult {
        if key == cacheKey {
            cacheSaveCount += 1
            if cacheSaveFails { return .accessDenied }
        }
        if key == encryptionKeyName {
            keySaveCount += 1
            if keySaveFails { return .accessDenied }
        }
        return backing.saveIdentityKeyWithResult(data, forKey: key)
    }
    func saveIdentityKey(_ data: Data, forKey key: String) -> Bool {
        if case .success = saveIdentityKeyWithResult(data, forKey: key) { return true }
        return false
    }
    func getIdentityKey(forKey key: String) -> Data? {
        if case .success(let data) = getIdentityKeyWithResult(forKey: key) { return data }
        return nil
    }
    func deleteIdentityKey(forKey key: String) -> Bool {
        if key == cacheKey { cacheDeleteCount += 1 }
        return backing.deleteIdentityKey(forKey: key)
    }
    func deleteAllKeychainData() -> Bool { backing.deleteAllKeychainData() }
    func secureClear(_ data: inout Data) { backing.secureClear(&data) }
    func secureClear(_ string: inout String) { backing.secureClear(&string) }
    func verifyIdentityKeyExists() -> Bool { backing.verifyIdentityKeyExists() }
    func save(key: String, data: Data, service: String, accessible: CFString?) { backing.save(key: key, data: data, service: service, accessible: accessible) }
    func load(key: String, service: String) -> Data? { backing.load(key: key, service: service) }
    func delete(key: String, service: String) { backing.delete(key: key, service: service) }
    func deleteAll(service: String) { backing.deleteAll(service: service) }
}
