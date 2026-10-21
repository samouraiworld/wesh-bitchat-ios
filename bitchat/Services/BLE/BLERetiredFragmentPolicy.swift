import BitFoundation
import Foundation

/// Packets of a type Wesh retired (BitChat groups, live voice, files) also
/// travel as fragments.
///
/// Rejecting only the reassembled packet is not enough: every fragment would
/// still be stored for gossip sync and relayed. These fragments stop at
/// dispatch instead. A file fragment for another peer is relayed as before
/// (a file between two other phones still crosses this node) but never
/// assembled here.
enum BLERetiredFragmentPolicy {
    enum Disposition: Equatable {
        /// Not a retired type: assemble and relay as usual.
        case process
        /// A file between two other peers: relay, never assemble.
        case relayOnly
        /// Neither assembled, gossip-stored nor relayed.
        case refuse
    }

    static func disposition(for packet: BitchatPacket, localPeerIDData: Data) -> Disposition {
        guard packet.type == MessageType.fragment.rawValue,
              let header = BLEFragmentHeader(packet: packet) else { return .process }
        switch MessageType(rawValue: header.originalType) {
        case .groupMessage, .voiceFrame:
            return .refuse
        case .fileTransfer:
            guard !header.isBroadcastFragment,
                  let recipient = packet.recipientID,
                  recipient != localPeerIDData else { return .refuse }
            return .relayOnly
        default:
            return .process
        }
    }

    /// A reassembled packet of a retired type is never handled here, even
    /// when its fragments claimed another type.
    static func isRetired(reassembled packet: BitchatPacket) -> Bool {
        switch MessageType(rawValue: packet.type) {
        case .groupMessage, .voiceFrame, .fileTransfer:
            return true
        default:
            return false
        }
    }
}
