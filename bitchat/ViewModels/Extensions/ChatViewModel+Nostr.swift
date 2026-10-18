//
// ChatViewModel+Nostr.swift
// bitchat
//
// Geohash and Nostr logic for ChatViewModel
//

import BitFoundation
import Foundation

extension ChatViewModel {

    @MainActor
    func setupNostrMessageHandling() {
        nostrCoordinator.accountMailbox.setupNostrMessageHandling()
    }

    @MainActor
    func findNoiseKey(for nostrPubkey: String) -> Data? {
        nostrCoordinator.inbound.findNoiseKey(for: nostrPubkey)
    }

    @MainActor
    func sendFavoriteNotificationViaNostr(noisePublicKey: Data, isFavorite: Bool) {
        nostrCoordinator.sendFavoriteNotificationViaNostr(noisePublicKey: noisePublicKey, isFavorite: isFavorite)
    }

    @MainActor
    func fullNostrHex(forSenderPeerID senderID: PeerID) -> String? {
        nostrCoordinator.fullNostrHex(forSenderPeerID: senderID)
    }

}
