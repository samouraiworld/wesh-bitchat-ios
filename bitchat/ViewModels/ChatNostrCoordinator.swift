import BitFoundation
import BitLogger
import Foundation

/// Account mailbox, private acknowledgements, and favorite notification context.
@MainActor
protocol ChatNostrContext: NostrInboundPipelineContext, AccountNostrMailboxContext {
    var selectedPrivateChatPeer: PeerID? { get }

    // MARK: Routing & acknowledgements (shared with `ChatPrivateConversationContext`)
    func routeFavoriteNotification(to peerID: PeerID, isFavorite: Bool)
    func sendNostrIdentityDeliveryAck(for messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity)
    func sendNostrIdentityReadReceipt(_ messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity)

    // MARK: Favorites (shared with the other contexts)
    /// The persisted favorite relationship for the peer's Noise static key, if any.
    func favoriteRelationship(forNoiseKey noiseKey: Data) -> FavoritesPersistenceService.FavoriteRelationship?
}

extension ChatViewModel: ChatNostrContext {}

/// Owns the account mailbox and inbound pipeline independently of public mesh.
final class ChatNostrCoordinator {
    private weak var context: (any ChatNostrContext)?
    let inbound: NostrInboundPipeline
    let accountMailbox: AccountNostrMailbox

    init(context: any ChatNostrContext) {
        self.context = context
        let inbound = NostrInboundPipeline(context: context)
        self.inbound = inbound
        self.accountMailbox = AccountNostrMailbox(context: context, inbound: inbound)
    }

    @MainActor
    func sendDeliveryAckViaNostrEmbedded(
        _ message: BitchatMessage,
        wasReadBefore: Bool,
        senderPubkey: String,
        key: Data?
    ) {
        guard let context else { return }
        if key != nil {
            if let identity = context.currentNostrIdentity() {
                context.sendNostrIdentityDeliveryAck(for: message.id, toRecipientHex: senderPubkey, from: identity)
            }
        } else if let identity = context.currentNostrIdentity() {
            context.sendNostrIdentityDeliveryAck(for: message.id, toRecipientHex: senderPubkey, from: identity)
            SecureLogger.debug(
                "Sent DELIVERED ack directly to Nostr pub=\(senderPubkey.prefix(8))… for mid=\(message.id.prefix(8))…",
                category: .session
            )
        }

        if !wasReadBefore && context.selectedPrivateChatPeer == message.senderPeerID {
            if key != nil {
                if let identity = context.currentNostrIdentity() {
                    context.sendNostrIdentityReadReceipt(message.id, toRecipientHex: senderPubkey, from: identity)
                }
            } else if let identity = context.currentNostrIdentity() {
                context.sendNostrIdentityReadReceipt(message.id, toRecipientHex: senderPubkey, from: identity)
                SecureLogger.debug(
                    "Viewing chat; sent READ ack directly to Nostr pub=\(senderPubkey.prefix(8))… for mid=\(message.id.prefix(8))…",
                    category: .session
                )
            }
        }
    }

    @MainActor
    func sendFavoriteNotificationViaNostr(noisePublicKey: Data, isFavorite: Bool) {
        guard let context else { return }
        guard let relationship = context.favoriteRelationship(forNoiseKey: noisePublicKey),
              relationship.peerNostrPublicKey != nil else {
            SecureLogger.warning("⚠️ Cannot send favorite notification - no Nostr key for peer", category: .session)
            return
        }

        let peerID = PeerID(hexData: noisePublicKey)
        context.routeFavoriteNotification(to: peerID, isFavorite: isFavorite)
    }
}
