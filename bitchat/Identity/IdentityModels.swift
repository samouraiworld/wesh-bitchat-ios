//
// IdentityModels.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

///
/// # IdentityModels
///
/// Defines BitChat's innovative three-layer identity model that balances
/// privacy, security, and usability in a decentralized mesh network.
///
/// ## Overview
/// BitChat's identity system separates concerns across three distinct layers:
/// 1. **Network Identity**: the 8-byte peer ID seen on air
/// 2. **Cryptographic Identity**: Long-term Noise static keys for security
/// 3. **Social Identity**: assigned names and trust relationships
///
/// The layers are separate concerns, but they are not independent: the network
/// identity is *derived* from the cryptographic one, so it does not provide
/// unlinkability. Rotating peer IDs would be a change to this model, not a
/// description of it — see the note below.
///
/// ## Three-Layer Architecture
///
/// ### Layer 1: Network Identity
/// - 8-byte peer ID = first 8 bytes of the Noise static key fingerprint
/// - **Not ephemeral and not rotating.** It is stable across sessions and
///   reboots, and changes only when the underlying identity is replaced by a
///   panic wipe. A passive observer can use it to track a device.
/// - Changes don't affect cryptographic relationships
/// - Includes handshake state tracking
///
/// ### Layer 2: Cryptographic Identity
/// - Based on Noise Protocol static key pairs
/// - Fingerprint derived from SHA256 of public key
/// - Enables end-to-end encryption and authentication
/// - The root of the peer ID above, and never rotated on a schedule
///
/// ### Layer 3: Social Identity
/// - User-assigned names (petnames) for contacts
/// - Trust levels from unknown to verified
/// - Favorite/blocked status
/// - Personal notes and metadata
///
/// ## Privacy Design
/// The model is designed with privacy-first principles:
/// - No mandatory persistent storage
/// - Optional identity caching with explicit consent
/// - Social mappings stored locally only
///
/// It does **not** currently prevent long-term tracking by a passive radio
/// observer: the peer ID is stable (Layer 1) and signed announcements carry the
/// static keys and nickname in cleartext.
///
/// ## Trust Model
/// Four levels of trust:
/// 1. **Unknown**: New or unverified peers
/// 2. **Casual**: Basic interaction history
/// 3. **Trusted**: User has explicitly trusted
/// 4. **Verified**: Cryptographic verification completed
///
/// ## Identity Resolution
/// When a peer's ID changes (a panic wipe on their side, or a future rotation):
/// 1. Cryptographic handshake reveals their fingerprint
/// 2. System looks up social identity by fingerprint
/// 3. UI seamlessly maintains existing relationships
/// 4. Historical messages remain properly attributed
///
/// ## Conflict Resolution
/// Handles edge cases like:
/// - Multiple peers claiming same nickname
/// - Nickname changes and conflicts
/// - Identity replacement during active chats
/// - Network partitions and rejoins
///
/// ## Usage Example
/// ```swift
/// // When peer connects with new ID
/// let ephemeral = EphemeralIdentity(peerID: "abc123", ...)
/// // After handshake
/// let crypto = CryptographicIdentity(fingerprint: "sha256...", ...)
/// // User assigns name
/// let social = SocialIdentity(localPetname: "Alice", ...)
/// ```
///

import Foundation
import BitFoundation

// MARK: - Three-Layer Identity Model

/// Represents the network layer of identity — the peer ID seen on air, plus the
/// handshake state tracked against it.
///
/// Named "ephemeral" for historical reasons; the peer ID is in fact stable,
/// being derived from the Noise static key fingerprint. It does not rotate and
/// does not prevent tracking.
struct EphemeralIdentity {
    var handshakeState: HandshakeState
}

enum HandshakeState {
    case none
    case initiated
    case inProgress
    case completed(fingerprint: String)
}

/// Represents the cryptographic layer of identity - the stable Noise Protocol static key pair.
/// This identity outlives any change to a peer's network ID and enables secure communication.
/// The fingerprint serves as the permanent identifier for a peer's cryptographic identity, and
/// its first 8 bytes are the peer ID broadcast on the mesh.
struct CryptographicIdentity: Codable {
    let fingerprint: String     // SHA256 of public key
    let publicKey: Data         // Noise static public key
    // Optional Ed25519 signing public key (used to authenticate public messages)
    var signingPublicKey: Data? = nil
    let firstSeen: Date
}

/// Represents the social layer of identity - user-assigned names and trust relationships.
/// This layer provides human-friendly identification and relationship management.
/// All data in this layer is local-only and never transmitted over the network.
struct SocialIdentity: Codable {
    let fingerprint: String
    var localPetname: String?   // User's name for this peer
    var claimedNickname: String // What peer calls themselves
    var trustLevel: TrustLevel
    var isFavorite: Bool
    var isBlocked: Bool
    var notes: String?
}

/// Trust ladder: unknown → casual → trusted → verified.
///
/// Persistence compatibility: `TrustLevel` is stored by its *String* raw
/// value ("unknown", "casual", …), not by ordinal position, so every case
/// keeps the exact raw value it was written with.
enum TrustLevel: String, Codable {
    case unknown
    case casual
    // Retired vouch tier: never written, kept so a stored raw value still decodes.
    case vouched
    case trusted
    case verified
}

// MARK: - Identity Cache

/// Persistent storage for identity mappings and relationships.
/// Provides efficient lookup between fingerprints, nicknames, and social identities.
/// Storage is optional and controlled by user privacy settings.
struct IdentityCache: Codable {
    // Fingerprint -> Social mapping
    var socialIdentities: [String: SocialIdentity] = [:]

    // Nickname -> [Fingerprints] reverse index
    // Multiple fingerprints can claim same nickname
    var nicknameIndex: [String: Set<String>] = [:]

    // Verified fingerprints (cryptographic proof)
    var verifiedFingerprints: Set<String> = []

    // Last interaction timestamps (privacy: optional)
    var lastInteractions: [String: Date] = [:]

    // Blocked Nostr pubkeys (lowercased hex) for geohash chats
    var blockedNostrPubkeys: Set<String> = []

    // Noise-fingerprint -> Ed25519 announcement key, learned only from the
    // authenticated peer-state payload. This prevents a self-signed announce
    // containing a copied public Noise key from replacing a previously bound
    // public-message signing identity. Optional for old cache compatibility.
    var authenticatedSigningKeysByFingerprint: [String: Data]? = nil

    // Fingerprint -> Cryptographic identity (noise + pinned signing key).
    // Persisting the signing-key pin is security-critical: it must survive
    // app restarts so an attacker cannot replay a known peer's
    // noiseKey/peerID with their own signing key and be treated as first
    // contact (TOFU downgrade).
    var cryptographicIdentities: [String: CryptographicIdentity] = [:]

    // Schema version for future migrations
    var version: Int = 1

    init() {}

    // Custom decoding so caches written by older builds (missing newer keys
    // such as `cryptographicIdentities`) still load instead of being
    // discarded. Every field uses decodeIfPresent so a missing key falls back
    // to its default rather than throwing. Retired keys (the vouch data) are
    // not decoded, so they are dropped on load and never re-encoded.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        socialIdentities = try container.decodeIfPresent([String: SocialIdentity].self, forKey: .socialIdentities) ?? [:]
        nicknameIndex = try container.decodeIfPresent([String: Set<String>].self, forKey: .nicknameIndex) ?? [:]
        verifiedFingerprints = try container.decodeIfPresent(Set<String>.self, forKey: .verifiedFingerprints) ?? []
        lastInteractions = try container.decodeIfPresent([String: Date].self, forKey: .lastInteractions) ?? [:]
        blockedNostrPubkeys = try container.decodeIfPresent(Set<String>.self, forKey: .blockedNostrPubkeys) ?? []
        authenticatedSigningKeysByFingerprint = try container.decodeIfPresent([String: Data].self, forKey: .authenticatedSigningKeysByFingerprint)
        cryptographicIdentities = try container.decodeIfPresent([String: CryptographicIdentity].self, forKey: .cryptographicIdentities) ?? [:]
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }

    /// Keys written by builds that exchanged vouches: received vouches, the
    /// per-contact vouch send times, and the verification times that ordered
    /// outgoing vouches. Only their presence is read, never their contents.
    private enum RetiredVouchKeys: String, CodingKey, CaseIterable {
        case vouchesByVouchee
        case vouchBatchSentAt
        case verifiedAt
    }

    private struct RetiredVouchProbe: Decodable {
        let isPresent: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: RetiredVouchKeys.self)
            isPresent = RetiredVouchKeys.allCases.contains { container.contains($0) }
        }
    }

    /// True when encoded cache JSON still carries retired vouch data, so the
    /// loader can rewrite the cache without it.
    static func containsRetiredVouchData(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(RetiredVouchProbe.self, from: data))?.isPresent ?? false
    }
}

//

// MARK: - Migration Support
//
