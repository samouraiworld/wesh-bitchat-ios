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

    // MARK: Content dedup
    func normalizedContentKey(_ content: String) -> String
    func recordContentKey(_ key: String, timestamp: Date)

    // MARK: Outbound routing
    /// Stamps "now" as the channel's last public activity (background nudges).
    /// (Single mutation path for the owner's `lastPublicActivityAt`; this
    /// coordinator never reads it.)
    func sendMeshMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date)
    // MARK: Geohash identity (shared with the other contexts)
}

extension ChatViewModel: ChatOutgoingContext {}

@MainActor
final class ChatOutgoingCoordinator {
    private unowned let context: any ChatOutgoingContext
    private let publicContentAllowed: (String) -> Bool

    init(context: any ChatOutgoingContext, publicContentAllowed: @escaping (String) -> Bool = { _ in true }) {
        self.context = context
        self.publicContentAllowed = publicContentAllowed
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
        guard publicContentAllowed(originalContent) else { return }
        let message = BitchatMessage(
            sender: context.nickname,
            content: trimmed,
            timestamp: Date(),
            isRelay: false,
            senderPeerID: context.myPeerID,
            mentions: mentions.isEmpty ? nil : mentions
        )

        appendLocalEcho(message, to: .mesh)
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
