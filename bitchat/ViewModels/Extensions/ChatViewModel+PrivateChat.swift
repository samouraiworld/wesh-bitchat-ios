//
// ChatViewModel+PrivateChat.swift
// bitchat
//
// Private chat logic for ChatViewModel
//

import BitFoundation
import BitLogger
import Foundation
import SwiftUI

extension ChatViewModel {

    @MainActor
    func sendPrivateMessage(_ content: String, to peerID: PeerID) {
        if weshPrivatePolicyEnabled && (peerID.noiseKey == nil || !canSendWeshMessage(to: peerID)) { return }
        privateConversationCoordinator.sendPrivateMessage(content, to: peerID)
    }

    @MainActor
    func handlePrivateMessage(
        _ payload: NoisePayload,
        senderPubkey: String,
        convKey: PeerID,
        id: NostrIdentity,
        messageTimestamp: Date
    ) {
        privateConversationCoordinator.handlePrivateMessage(
            payload,
            senderPubkey: senderPubkey,
            convKey: convKey,
            id: id,
            messageTimestamp: messageTimestamp
        )
    }

    @MainActor
    func handleDelivered(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID) {
        privateConversationCoordinator.handleDelivered(payload, senderPubkey: senderPubkey, convKey: convKey)
    }

    @MainActor
    func handleReadReceipt(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID) {
        privateConversationCoordinator.handleReadReceipt(payload, senderPubkey: senderPubkey, convKey: convKey)
    }

    @MainActor
    func handlePrivateMessage(_ message: BitchatMessage) {
        privateConversationCoordinator.handlePrivateMessage(message)
    }

    @MainActor
    func processActionMessage(_ message: BitchatMessage) -> BitchatMessage {
        privateConversationCoordinator.processActionMessage(message)
    }

    @MainActor
    func migratePrivateChatsIfNeeded(for peerID: PeerID, senderNickname: String) {
        privateConversationCoordinator.migratePrivateChatsIfNeeded(for: peerID, senderNickname: senderNickname)
    }

    @MainActor
    func isMessageBlocked(_ message: BitchatMessage) -> Bool {
        privateConversationCoordinator.isMessageBlocked(message)
    }
}
