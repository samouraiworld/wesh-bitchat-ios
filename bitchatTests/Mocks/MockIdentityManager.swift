//
// MockIdentityManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import BitFoundation
@testable import bitchat

final class MockIdentityManager: SecureIdentityStateManagerProtocol {
    private var blockedFingerprints: Set<String> = []
    private var blockedNostrPubkeys: Set<String> = []
    private var socialIdentities: [String: SocialIdentity] = [:]
    private var authenticatedSigningKeys: [String: Data] = [:]

    init(_: KeychainManagerProtocol) {}
    
    func forceSave() {}
    
    func getSocialIdentity(for fingerprint: String) -> SocialIdentity? {
        socialIdentities[fingerprint]
    }
    
    func upsertCryptographicIdentity(fingerprint: String, noisePublicKey: Data, signingPublicKey: Data?, claimedNickname: String?) {}
    
    func getCryptoIdentitiesByPeerIDPrefix(_ peerID: PeerID) -> [CryptographicIdentity] {
        []
    }
    
    func updateSocialIdentity(_ identity: SocialIdentity) {
        socialIdentities[identity.fingerprint] = identity
        if identity.isBlocked {
            blockedFingerprints.insert(identity.fingerprint)
        } else {
            blockedFingerprints.remove(identity.fingerprint)
        }
    }
    
    func isFavorite(fingerprint: String) -> Bool {
        false
    }
    
    func isBlocked(fingerprint: String) -> Bool {
        blockedFingerprints.contains(fingerprint) || socialIdentities[fingerprint]?.isBlocked == true
    }

    func getBlockedFingerprints() -> Set<String> {
        blockedFingerprints.union(socialIdentities.values.filter(\.isBlocked).map(\.fingerprint))
    }
    
    func setBlocked(_ fingerprint: String, isBlocked: Bool) {
        if var identity = socialIdentities[fingerprint] {
            identity.isBlocked = isBlocked
            socialIdentities[fingerprint] = identity
        } else {
            let identity = SocialIdentity(
                fingerprint: fingerprint,
                localPetname: nil,
                claimedNickname: "",
                trustLevel: .unknown,
                isFavorite: false,
                isBlocked: isBlocked,
                notes: nil
            )
            socialIdentities[fingerprint] = identity
        }
        if isBlocked {
            blockedFingerprints.insert(fingerprint)
        } else {
            blockedFingerprints.remove(fingerprint)
        }
    }
    
    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool {
        blockedNostrPubkeys.contains(pubkeyHexLowercased)
    }
    
    func setNostrBlocked(_ pubkeyHexLowercased: String, isBlocked: Bool) {
        if isBlocked {
            blockedNostrPubkeys.insert(pubkeyHexLowercased)
        } else {
            blockedNostrPubkeys.remove(pubkeyHexLowercased)
        }
    }
    
    
    func registerEphemeralSession(peerID: PeerID, handshakeState: HandshakeState) {}

    func clearAllIdentityData() {
        authenticatedSigningKeys.removeAll()
    }
    
    func removeEphemeralSession(peerID: PeerID) {}
    
    func setVerified(fingerprint: String, verified: Bool) {}

    func isVerified(fingerprint: String) -> Bool {
        true
    }

    func getVerifiedFingerprints() -> Set<String> {
        Set()
    }

    func bindAuthenticatedSigningPublicKey(_ signingPublicKey: Data, fingerprint: String) {
        authenticatedSigningKeys[fingerprint] = signingPublicKey
    }

    func authenticatedSigningPublicKey(forFingerprint fingerprint: String) -> Data? {
        authenticatedSigningKeys[fingerprint]
    }
}
