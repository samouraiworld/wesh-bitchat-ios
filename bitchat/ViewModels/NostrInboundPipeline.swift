import BitFoundation
import BitLogger
import Foundation

/// The narrow surface `NostrInboundPipeline` needs from its owner.
///
/// Split out of `ChatNostrContext`: member names are shared with the sibling
/// component contexts so `ChatViewModel` provides a single witness for each.
@MainActor
protocol NostrInboundPipelineContext: AnyObject {

    // MARK: Event dedup
    func hasProcessedNostrEvent(_ eventID: String) -> Bool
    func recordProcessedNostrEvent(_ eventID: String)

    // MARK: Nostr identity & blocking
    func currentNostrIdentity() -> NostrIdentity?

    // MARK: Favorites bridge
    /// All favorite relationships, used to bridge a Nostr pubkey back to a
    /// Noise key on the inbound DM path.
    func allFavoriteRelationships() -> [FavoritesPersistenceService.FavoriteRelationship]

    // MARK: Presence & key mapping
    /// Records the Nostr pubkey behind a (possibly virtual) peer ID.
    func registerNostrKeyMapping(_ pubkey: String, for peerID: PeerID)

    // MARK: Inbound private (DM) payloads
    func handlePrivateMessage(
        _ payload: NoisePayload,
        senderPubkey: String,
        convKey: PeerID,
        id: NostrIdentity,
        messageTimestamp: Date
    )
    func handleDelivered(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID)
    func handleReadReceipt(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID)
    /// False when this sender may not reach the device privately (Wesh: not a
    /// QR-verified contact). Checked once, before any payload is dispatched.
    func admitsPrivateSender(_ peerID: PeerID) -> Bool
    /// Wesh: account DMs resolve their sender only through the npub bound by a
    /// QR contact's signed QR, never through favorites.
    var resolvesNostrSendersFromQRContacts: Bool { get }
    /// The Noise key of the unblocked QR contact bound to this sender key; nil drops it.
    func qrContactNoiseKey(forNostrPubkey pubkey: String) -> Data?
}

extension NostrInboundPipelineContext {
    func admitsPrivateSender(_ peerID: PeerID) -> Bool { true }
    var resolvesNostrSendersFromQRContacts: Bool { false }
    func qrContactNoiseKey(forNostrPubkey pubkey: String) -> Data? { nil }
}

extension ChatViewModel: NostrInboundPipelineContext {
    // `currentGeohash`, the identity/blocking members, key mapping, and the
    // inbound message handlers already have witnesses on `ChatViewModel`.
    // The members below flatten nested service accesses into intent-named calls.

    func hasProcessedNostrEvent(_ eventID: String) -> Bool {
        deduplicationService.hasProcessedNostrEvent(eventID)
    }

    func allFavoriteRelationships() -> [FavoritesPersistenceService.FavoriteRelationship] {
        Array(FavoritesPersistenceService.shared.favorites.values)
    }

    func recordProcessedNostrEvent(_ eventID: String) {
        deduplicationService.recordNostrEvent(eventID)
    }

    var resolvesNostrSendersFromQRContacts: Bool { weshPrivatePolicyEnabled }

    func qrContactNoiseKey(forNostrPubkey pubkey: String) -> Data? {
        WeshInternetRoute.senderNoiseKey(forNostrPubkey: pubkey, contacts: WeshQRTrust.shared.contacts,
                                         blockedFingerprints: identityManager.getBlockedFingerprints())
    }

}

/// The inbound Nostr hot path: verified relay events in, chat messages /
/// Noise payloads out. Pure transformation plus dedup — no relay lifecycle.
///
/// Every event arriving here already had its Schnorr signature verified
/// exactly once, off the main actor, by `NostrRelayManager`'s serial inbound
/// pipeline (which records events into its own dedup cache only AFTER
/// verification, so forged copies can't suppress genuine events). This
/// pipeline therefore never re-verifies; it keeps its own event-ID dedup
/// (cheap main-actor lookups) and moves NIP-17 gift-wrap decryption — two
/// ECDH+ChaCha layers — off the main actor with an atomic main-actor
/// check-and-record.
final class NostrInboundPipeline {
    private weak var context: (any NostrInboundPipelineContext)?

    /// Monotonic panic-wipe generation for this pipeline. A panic wipe clears
    /// relay handlers so no NEW events flow, but a detached decrypt task
    /// spawned just BEFORE the wipe — which strongly captures a pre-wipe Nostr
    /// private key and ciphertext — survives it. Spawn sites capture this
    /// value; the task compares it at its main-actor hops and drops its result
    /// (no delivery; the captured identity and plaintext die with the task)
    /// if `invalidateInFlightDecrypts()` bumped it in between.
    @MainActor private(set) var wipeGeneration: UInt64 = 0

    /// Called from `ChatViewModel.panicClearAllData()` so plaintext decrypted
    /// with pre-wipe keys can never land in post-wipe state.
    @MainActor
    func invalidateInFlightDecrypts() {
        wipeGeneration &+= 1
    }

    init(context: any NostrInboundPipelineContext) {
        self.context = context
    }

    @MainActor
    func handleNostrMessage(_ giftWrap: NostrEvent) {
        guard let context else { return }
        // Cheap dedup pre-check only; processNostrMessage does the
        // authoritative check-and-record before the off-main NIP-17 unwrap.
        // The outer signature was already verified (exactly once, off the
        // main actor) by NostrRelayManager, and only verified events are
        // recorded, so a forged-signature copy can never poison the dedup
        // set and suppress the genuine event.
        if context.hasProcessedNostrEvent(giftWrap.id) { return }

        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.processNostrMessage(giftWrap)
        }
    }

    func processNostrMessage(_ giftWrap: NostrEvent) async {
        guard let context else { return }
        // Authoritative check-and-record, atomic on the main actor so two
        // concurrent detached tasks can't both process the same event.
        let alreadyProcessed: Bool = await MainActor.run {
            if context.hasProcessedNostrEvent(giftWrap.id) { return true }
            context.recordProcessedNostrEvent(giftWrap.id)
            return false
        }
        if alreadyProcessed { return }
        // Fetch the identity and the wipe generation in ONE main-actor hop:
        // the generation then vouches for exactly this identity. A wipe after
        // this point bumps the generation and the delivery hop below drops
        // the decrypted result at the main-actor delivery hop.
        let (currentIdentity, wipeGeneration): (NostrIdentity?, UInt64) = await MainActor.run {
            (context.currentNostrIdentity(), self.wipeGeneration)
        }
        guard let currentIdentity else { return }

        do {
            let (content, senderPubkey, rumorTimestamp) = try NostrProtocol.decryptPrivateMessage(
                giftWrap: giftWrap,
                recipientIdentity: currentIdentity
            )

            guard Self.isPlausibleRumorTimestamp(rumorTimestamp) else {
                SecureLogger.warning("Dropping Nostr DM with implausible rumor timestamp id=\(giftWrap.id.prefix(8))…", category: .session)
                return
            }

            if content.hasPrefix("verify:") {
                return
            }

            if content.hasPrefix("bitchat1:") {
                let packet: BitchatPacket? = await MainActor.run {
                    Self.decodeEmbeddedBitChatPacket(from: content)
                }
                guard let packet else {
                    SecureLogger.error("Failed to decode embedded BitChat packet from Nostr DM", category: .session)
                    return
                }

                let actualSenderNoiseKey: Data? = await MainActor.run {
                    self.findNoiseKey(for: senderPubkey)
                }
                let targetPeerID = PeerID(str: actualSenderNoiseKey?.hexEncodedString()) ?? PeerID(nostr_: senderPubkey)

                if packet.type == MessageType.noiseEncrypted.rawValue,
                   let payload = NoisePayload.decode(packet.payload) {
                    let messageTimestamp = Date(timeIntervalSince1970: TimeInterval(rumorTimestamp))
                    await MainActor.run {
                        // Drop pre-wipe plaintext if a panic wipe landed
                        // during the off-main decrypt (see above).
                        guard self.wipeGeneration == wipeGeneration else { return }
                        // One admission check covers every payload type, current and future.
                        guard context.admitsPrivateSender(targetPeerID) else { return }
                        context.registerNostrKeyMapping(senderPubkey, for: targetPeerID)

                        switch payload.type {
                        case .privateMessage:
                            context.handlePrivateMessage(
                                payload,
                                senderPubkey: senderPubkey,
                                convKey: targetPeerID,
                                id: currentIdentity,
                                messageTimestamp: messageTimestamp
                            )
                        case .delivered:
                            context.handleDelivered(payload, senderPubkey: senderPubkey, convKey: targetPeerID)
                        case .readReceipt:
                            context.handleReadReceipt(payload, senderPubkey: senderPubkey, convKey: targetPeerID)
                        // Group state travels only over mesh Noise sessions
                        // in v1; group traffic over Nostr is ignored.
                        // Live voice is mesh-only: latency and relay cost make it
                        // meaningless over Nostr.
                        case .verifyChallenge, .verifyResponse, .groupInvite, .groupKeyUpdate, .vouch, .voiceFrame, .privateFile, .authenticatedPeerState:
                            break
                        }
                    }
                }
            } else {
                SecureLogger.debug("Ignoring non-embedded Nostr DM content", category: .session)
            }
        } catch {
            SecureLogger.error("Failed to decrypt Nostr message: \(error)", category: .session)
        }
    }

    /// Resolves the Noise static key behind a Nostr pubkey via the favorites
    /// store. Lives here because the inbound DM path needs it per message.
    @MainActor
    func findNoiseKey(for nostrPubkey: String) -> Data? {
        guard let context else { return nil }
        if context.resolvesNostrSendersFromQRContacts {
            return context.qrContactNoiseKey(forNostrPubkey: nostrPubkey)
        }
        let favorites = context.allFavoriteRelationships()
        var npubToMatch = nostrPubkey

        if !nostrPubkey.hasPrefix("npub") {
            if let pubkeyData = Data(hexString: nostrPubkey),
               let encoded = try? Bech32.encode(hrp: "npub", data: pubkeyData) {
                npubToMatch = encoded
            } else {
                SecureLogger.warning(
                    "⚠️ Invalid hex public key format or encoding failed: \(nostrPubkey.prefix(16))...",
                    category: .session
                )
            }
        }

        for relationship in favorites {
            if let storedNostrKey = relationship.peerNostrPublicKey {
                if storedNostrKey == npubToMatch {
                    return relationship.peerNoisePublicKey
                }
                if !storedNostrKey.hasPrefix("npub") && storedNostrKey == nostrPubkey {
                    SecureLogger.debug("✅ Found Noise key for Nostr sender (hex match)", category: .session)
                    return relationship.peerNoisePublicKey
                }
            }
        }

        SecureLogger.debug(
            "⚠️ No matching Noise key found for Nostr pubkey: \(nostrPubkey.prefix(16))... (tried npub: \(npubToMatch.prefix(16))...)",
            category: .session
        )
        return nil
    }
}

extension NostrInboundPipeline {
    /// Client-side mirror of the relay-side `since` filter on DM
    /// subscriptions: a relay that ignores `since` — or replays archived
    /// events — must not inject stale or future-dated DMs. The inner rumor
    /// timestamp is the sender's true send time (only the outer gift wrap
    /// is randomized per NIP-17), so the plausible window is the
    /// subscription lookback plus tolerated clock skew on both ends.
    /// Internal (not private) so tests can pin the window directly.
    static func isPlausibleRumorTimestamp(_ ts: Int, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince1970 - TimeInterval(ts)
        return age >= -TransportConfig.nostrDMMaxClockSkewSeconds
            && age <= TransportConfig.nostrDMSubscribeLookbackSeconds
                + TransportConfig.nostrDMMaxClockSkewSeconds
    }
}

private extension NostrInboundPipeline {
    @MainActor
    static func decodeEmbeddedBitChatPacket(from content: String) -> BitchatPacket? {
        guard content.hasPrefix("bitchat1:") else { return nil }
        let encoded = String(content.dropFirst("bitchat1:".count))
        let maxBytes = FileTransferLimits.maxFramedFileBytes
        let maxEncoded = ((maxBytes + 2) / 3) * 4
        guard encoded.count <= maxEncoded else { return nil }
        guard let packetData = Base64URLCoding.decode(encoded),
              packetData.count <= maxBytes
        else {
            return nil
        }
        return BitchatPacket.from(packetData)
    }
}
