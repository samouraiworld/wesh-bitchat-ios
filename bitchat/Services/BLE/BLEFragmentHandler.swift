import BitFoundation
import BitLogger
import Foundation

/// Narrow environment for `BLEFragmentHandler`.
///
/// All queue hops (the message-queue entry hop and the collections barrier
/// around the assembly buffer) live on the `BLEService` side — the entry hop
/// in `BLEService.handleFragment`, the barrier inside the supplied closures —
/// keeping the handler queue-agnostic and synchronously testable.
struct BLEFragmentHandlerEnvironment {
    /// Local peer identity at the time the fragment is handled.
    let localPeerID: () -> PeerID
    /// Tracks broadcast fragments for gossip sync.
    let trackPacketSeen: (BitchatPacket) -> Void
    /// Appends the fragment to the assembly buffer (collections barrier write).
    let appendFragment: (BLEFragmentHeader) -> BLEFragmentAssemblyBuffer.AppendResult
    /// Rechecks freshness and the live sync window. RSR packets use the
    /// actual ingress responder; ordinary packets use their original author.
    let isAcceptedIngressPayload: (_ packet: BitchatPacket, _ validationPeerID: PeerID) -> Bool
    /// Re-enters the receive pipeline with the reassembled packet (TTL already zeroed).
    let processReassembledPacket: (_ packet: BitchatPacket, _ from: PeerID) -> Void
}

/// Orchestrates inbound fragments: self-fragment suppression, gossip tracking,
/// assembly-buffer appends, and reassembled-packet validation and re-injection
/// into the receive pipeline.
final class BLEFragmentHandler {
    private let environment: BLEFragmentHandlerEnvironment

    init(environment: BLEFragmentHandlerEnvironment) {
        self.environment = environment
    }

    func handle(_ packet: BitchatPacket, from peerID: PeerID) {
        let env = environment
        guard let header = BLEFragmentHeader(packet: packet) else { return }

        // Sync replay legitimately hands us our own fragments back (the RSR
        // ttl=0 restore path): after a relaunch the fragment store starts
        // empty, so our sync filter doesn't cover them and peers re-offer
        // them. Record them as seen — the next round's filter then covers
        // them and the redelivery stops — but skip assembly: we authored
        // the original, there is nothing to reassemble.
        if PeerID(hexData: packet.senderID) == env.localPeerID() {
            if header.isBroadcastFragment {
                env.trackPacketSeen(packet)
            }
            return
        }

        if header.isBroadcastFragment {
            env.trackPacketSeen(packet)
        }

        let assemblyResult = env.appendFragment(header)

        logFragmentAssemblyResult(assemblyResult)

        guard case let .complete(completedHeader, reassembled, _) = assemblyResult else { return }

        // Decode the original packet bytes we reassembled, so flags/compression are preserved
        if var originalPacket = BinaryProtocol.decode(reassembled) {

            // Reassembled packet validation. Both platforms' fragmenters copy
            // the inner type into every fragment, and the assembly was sized
            // for that claim, so a packet of any other type is forged.
            let innerSender = PeerID(hexData: originalPacket.senderID)
            let fragmentSender = withUnsafeBytes(of: completedHeader.key.sender.bigEndian) { Data($0) }
            if originalPacket.senderID != fragmentSender {
                // Both fragmenters preserve the original author. The ingress
                // responder may differ during sync, but the fragment author
                // must not wrap a packet claiming someone else's identity.
                SecureLogger.warning(
                    "🚫 Reassembled packet id=\(completedHeader.idLogString) has a different sender than its fragments",
                    category: .security
                )
            } else if originalPacket.type != completedHeader.originalType {
                SecureLogger.warning(
                    "🚫 Reassembled packet id=\(completedHeader.idLogString) is type \(originalPacket.type), fragments claimed \(completedHeader.originalType)",
                    category: .security
                )
            } else if !Self.recipientsAgree(
                inner: originalPacket.recipientID,
                fragments: packet.recipientID,
                localPeerID: env.localPeerID()
            ) {
                // Relay and retired-type decisions are taken on the fragments,
                // so an inner packet addressed elsewhere than they are is
                // forged. One mismatch is legitimate: iOS addresses the
                // fragments of a sync response to the requester while the
                // inner packet stays a broadcast.
                SecureLogger.warning(
                    "🚫 Reassembled packet id=\(completedHeader.idLogString) is addressed differently from its fragments",
                    category: .security
                )
            } else if BLERetiredFragmentPolicy.isRetired(reassembled: originalPacket) {
                SecureLogger.debug("🚫 Reassembled packet id=\(completedHeader.idLogString) is a retired type \(originalPacket.type)", category: .session)
            } else if originalPacket.isRSR && !packet.isRSR {
                // A solicited replay may waive the inner packet's past-age
                // limit only when it arrived as a solicited fragment too.
                SecureLogger.warning("🚫 Reassembled RSR packet arrived inside a non-RSR fragment", category: .security)
            } else if !env.isAcceptedIngressPayload(originalPacket, originalPacket.isRSR ? peerID : innerSender) {
                // Cleanup below
            } else {
                SecureLogger.debug("✅ Reassembled packet id=\(completedHeader.idLogString) type=\(originalPacket.type) bytes=\(reassembled.count)", category: .session)
                originalPacket.ttl = 0
                env.processReassembledPacket(originalPacket, peerID)
            }
        } else {
            SecureLogger.error("❌ Failed to decode reassembled packet (type=\(completedHeader.originalType), total=\(completedHeader.total))", category: .session)
        }
    }

    /// Absent and all-0xFF recipients both mean broadcast. Fragments for us
    /// may carry a broadcast (a sync response; reinjected with TTL 0, so it
    /// is never relayed). Any other difference is refused.
    private static func recipientsAgree(inner: Data?, fragments: Data?, localPeerID: PeerID) -> Bool {
        let innerBroadcast = BLEPacketFreshnessPolicy.isBroadcastRecipient(inner)
        let fragmentsBroadcast = BLEPacketFreshnessPolicy.isBroadcastRecipient(fragments)
        switch (innerBroadcast, fragmentsBroadcast) {
        case (true, true):
            return true
        case (false, false):
            return inner == fragments
        case (true, false):
            return fragments == Data(hexString: localPeerID.id)
        case (false, true):
            return false
        }
    }

    private func logFragmentAssemblyResult(_ result: BLEFragmentAssemblyBuffer.AppendResult) {
        func logStartedIfNeeded(header: BLEFragmentHeader, started: Bool) {
            if started {
                SecureLogger.debug("📦 Started fragment assembly id=\(header.idLogString) total=\(header.total)", category: .session)
            }
        }

        switch result {
        case let .stored(header, started):
            logStartedIfNeeded(header: header, started: started)
            SecureLogger.debug("📦 Fragment \(header.index + 1)/\(header.total) (len=\(header.fragmentData.count)) for id=\(header.idLogString)", category: .session)

        case let .complete(header, _, started):
            logStartedIfNeeded(header: header, started: started)
            SecureLogger.debug("📦 Fragment \(header.index + 1)/\(header.total) (len=\(header.fragmentData.count)) for id=\(header.idLogString)", category: .session)

        case let .oversized(header, projectedSize, limit, started):
            logStartedIfNeeded(header: header, started: started)
            SecureLogger.warning(
                "🚫 Fragment assembly exceeds size limit (\(projectedSize) bytes > \(limit)), evicting. Type=\(header.originalType) Index=\(header.index)/\(header.total)",
                category: .security
            )
        }
    }
}
