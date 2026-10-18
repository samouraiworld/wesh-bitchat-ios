import BitFoundation
import BitLogger
import Foundation

/// The narrow surface `ChatOutgoingCoordinator` needs from its owner.
///
/// Follows the `ChatDeliveryContext` exemplar: the coordinator depends on the
/// minimal context it actually uses instead of holding an `unowned` back-ref
/// to the whole `ChatViewModel`. This keeps the coordinator independently
/// testable (see `ChatOutgoingCoordinatorContextTests`) and makes its true
/// dependencies explicit.
@MainActor
protocol ChatOutgoingContext: AnyObject {
    // MARK: Identity & channel state
    var nickname: String { get }
    var myPeerID: PeerID { get }
    var activeChannel: ChannelID { get }
    var selectedPrivateChatPeer: PeerID? { get }
    var isTeleported: Bool { get }

    // MARK: Commands & private messages
    func handleCommand(_ command: String)
    func updatePrivateChatPeerIfNeeded()
    func sendPrivateMessage(_ content: String, to peerID: PeerID)

    // MARK: Public timeline (local echo)
    func parseMentions(from content: String) -> [String]
    /// Appends a public message via the single-writer store intent
    /// (immediate: the local echo must render without batching).
    @discardableResult
    func appendPublicMessage(_ message: BitchatMessage, to conversationID: ConversationID) -> Bool
    func addSystemMessage(_ content: String)

    // MARK: Content dedup
    func normalizedContentKey(_ content: String) -> String
    func recordContentKey(_ key: String, timestamp: Date)

    // MARK: Outbound routing
    /// Stamps "now" as the channel's last public activity (background nudges).
    /// (Single mutation path for the owner's `lastPublicActivityAt`; this
    /// coordinator never reads it.)
    func recordPublicActivity(forChannelKey key: String)
    func sendMeshMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date)
    func sendGeohash(context: ChatViewModel.GeoOutgoingContext)
    // MARK: Geohash identity (shared with the other contexts)
    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity
}

extension ChatViewModel: ChatOutgoingContext {
    // `nickname`, `myPeerID`, `activeChannel`, `selectedPrivateChatPeer`,
    // `isTeleported`, `handleCommand(_:)`, `updatePrivateChatPeerIfNeeded()`,
    // `sendPrivateMessage(_:to:)`, `parseMentions(from:)`,
    // `appendPublicMessage(_:to:)`, `addSystemMessage(_:)`,
    // `normalizedContentKey(_:)`, `recordContentKey(_:timestamp:)`,
    // `sendMeshMessage(_:mentions:messageID:timestamp:)`,
    // `sendGeohash(context:)`, and `deriveNostrIdentity(forGeohash:)` are
    // shared requirements with the other contexts or satisfied by existing
    // `ChatViewModel` members. The single-writer intent op below lives next to
    // its backing state's owner.

    func recordPublicActivity(forChannelKey key: String) {
        lastPublicActivityAt[key] = Date()
    }
}

@MainActor
final class ChatOutgoingCoordinator {
    private unowned let context: any ChatOutgoingContext

    /// In-flight NIP-13 mining for the most recent geohash send. A newer send
    /// (or leaving the channel) cancels it, which only expedites the mining —
    /// the message still goes out at the difficulty already reached.
    /// (Read access is internal so tests can await the send's completion.)
    private(set) var geohashMiningTask: Task<Void, Never>?

    init(context: any ChatOutgoingContext) {
        self.context = context
    }

    /// Finish any in-flight geohash PoW mining early (the pending message
    /// still sends, at whatever committed difficulty it reached).
    func expeditePendingGeohashMining() {
        geohashMiningTask?.cancel()
    }

    func sendMessage(_ content: String, allowCommands: Bool = true) {
        guard let trimmed = content.trimmedOrNilIfEmpty else { return }

        if allowCommands && content.hasPrefix("/") {
            Task { @MainActor [weak context = self.context] in
                context?.handleCommand(content)
            }
            return
        }

        if context.selectedPrivateChatPeer != nil {
            context.updatePrivateChatPeerIfNeeded()

            if let selectedPeer = context.selectedPrivateChatPeer {
                context.sendPrivateMessage(content, to: selectedPeer)
            }
            return
        }

        let mentions = context.parseMentions(from: content)

        switch context.activeChannel {
        case .mesh:
            sendMeshPublicMessage(originalContent: content, trimmed: trimmed, mentions: mentions)
        case .location:
            return // Retired geographic destinations never fall back to public mesh.
        }
    }

    /// Broadcasts a wave on the mesh channel regardless of the active channel —
    /// used by the "bitchatters nearby" notification quick action, which always
    /// refers to mesh peers.
    func sendMeshWave() {
        sendMeshPublicMessage(originalContent: "👋", trimmed: "👋", mentions: [])
    }
}

private extension ChatOutgoingCoordinator {
    func sendMeshPublicMessage(originalContent: String, trimmed: String, mentions: [String]) {
        let message = BitchatMessage(
            sender: context.nickname,
            content: trimmed,
            timestamp: Date(),
            isRelay: false,
            senderPeerID: context.myPeerID,
            mentions: mentions.isEmpty ? nil : mentions
        )

        appendLocalEcho(message, to: .mesh)
        context.recordPublicActivity(forChannelKey: "mesh")
        context.sendMeshMessage(
            originalContent,
            mentions: mentions,
            messageID: message.id,
            timestamp: message.timestamp
        )
    }

    func appendLocalEcho(_ message: BitchatMessage, to conversationID: ConversationID) {
        context.appendPublicMessage(message, to: conversationID)

        let contentKey = context.normalizedContentKey(message.content)
        context.recordContentKey(contentKey, timestamp: message.timestamp)
    }
}
