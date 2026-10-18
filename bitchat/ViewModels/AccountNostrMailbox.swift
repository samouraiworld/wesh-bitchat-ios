import BitLogger
import Foundation

/// Account inbox ownership must survive retirement of geographic channels.
@MainActor
protocol AccountNostrMailboxContext: AnyObject {
    func currentNostrIdentity() -> NostrIdentity?
    func subscribeAccountMailbox(filter: NostrFilter, id: String, handler: @escaping (NostrEvent) -> Void)
}

extension ChatViewModel: AccountNostrMailboxContext {
    func subscribeAccountMailbox(filter: NostrFilter, id: String, handler: @escaping (NostrEvent) -> Void) {
        nostrRelayManager?.subscribe(filter: filter, id: id, handler: handler)
    }
}

/// Owns the account gift-wrap subscription and forwards verified relay events
/// to the existing inbox pipeline, including its admission, dedup and wipe guards.
final class AccountNostrMailbox {
    private weak var context: (any AccountNostrMailboxContext)?
    private let inbound: NostrInboundPipeline

    init(context: any AccountNostrMailboxContext, inbound: NostrInboundPipeline) {
        self.context = context
        self.inbound = inbound
    }

    @MainActor
    func setupNostrMessageHandling() {
        guard let context else { return }
        guard let currentIdentity = context.currentNostrIdentity() else {
            SecureLogger.warning("⚠️ No Nostr identity available for message handling", category: .session)
            return
        }

        SecureLogger.debug(
            "🔑 Setting up Nostr subscription for pubkey: \(currentIdentity.publicKeyHex.prefix(16))...",
            category: .session
        )

        let filter = NostrFilter.giftWrapsFor(
            pubkey: currentIdentity.publicKeyHex,
            since: Date().addingTimeInterval(-TransportConfig.nostrDMSubscribeLookbackSeconds)
        )

        context.subscribeAccountMailbox(filter: filter, id: "chat-messages") { [weak self] event in
            Task { @MainActor [weak self] in
                self?.inbound.handleNostrMessage(event)
            }
        }
    }
}
