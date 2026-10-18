//
// ChatNostrCoordinatorContextTests.swift
// bitchatTests
//
// Exercises the account mailbox and encrypted inbound pipeline through
// `ChatNostrCoordinator` with an injected `ChatNostrContext`, independently
// of `ChatViewModel` and live relay or platform services.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

// MARK: - Mock Context

/// Lightweight stand-in for `ChatNostrContext` (and, via protocol
/// inheritance, the component contexts) proving that the Nostr stack is
/// testable without a `ChatViewModel`.
@MainActor
private final class MockChatNostrContext: ChatNostrContext {
    var activeChannel: ChannelID = .mesh
    var selectedPrivateChatPeer: PeerID?
    var nostrIdentity: NostrIdentity?
    var nostrKeyMapping: [PeerID: String] = [:]
    var accountSubscriptions: [(filter: NostrFilter, id: String)] = []
    var accountHandlers: [(NostrEvent) -> Void] = []
    var handledPrivateMessages: [(payload: NoisePayload, senderPubkey: String, convKey: PeerID, timestamp: Date)] = []
    var handledDelivered: [(senderPubkey: String, convKey: PeerID)] = []
    var handledReadReceipts: [(senderPubkey: String, convKey: PeerID)] = []
    var nostrDeliveryAcks: [(messageID: String, recipientHex: String)] = []
    var nostrReadReceipts: [(messageID: String, recipientHex: String)] = []
    var recordedNostrEventIDs: [String] = []
    private var processedEventIDs: Set<String> = []
    var admitsSender: (PeerID) -> Bool = { _ in true }
    var qrResolver: ((String) -> Data?)?
    var resolvesNostrSendersFromQRContacts: Bool { qrResolver != nil }

    func currentNostrIdentity() -> NostrIdentity? { nostrIdentity }
    func subscribeAccountMailbox(filter: NostrFilter, id: String, handler: @escaping (NostrEvent) -> Void) {
        accountSubscriptions.append((filter, id))
        accountHandlers.append(handler)
    }
    func registerNostrKeyMapping(_ pubkey: String, for peerID: PeerID) { nostrKeyMapping[peerID] = pubkey }
    func handlePrivateMessage(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID,
                              id: NostrIdentity, messageTimestamp: Date) {
        handledPrivateMessages.append((payload, senderPubkey, convKey, messageTimestamp))
    }
    func handleDelivered(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID) {
        handledDelivered.append((senderPubkey, convKey))
    }
    func handleReadReceipt(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID) {
        handledReadReceipts.append((senderPubkey, convKey))
    }
    func admitsPrivateSender(_ peerID: PeerID) -> Bool { admitsSender(peerID) }
    func qrContactNoiseKey(forNostrPubkey pubkey: String) -> Data? { qrResolver?(pubkey) }
    func hasProcessedNostrEvent(_ eventID: String) -> Bool { processedEventIDs.contains(eventID) }
    func recordProcessedNostrEvent(_ eventID: String) {
        processedEventIDs.insert(eventID)
        recordedNostrEventIDs.append(eventID)
    }
    func allFavoriteRelationships() -> [FavoritesPersistenceService.FavoriteRelationship] { [] }
    func favoriteRelationship(forNoiseKey noiseKey: Data) -> FavoritesPersistenceService.FavoriteRelationship? { nil }
    func routeFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {}
    func sendNostrIdentityDeliveryAck(for messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        nostrDeliveryAcks.append((messageID, recipientHex))
    }
    func sendNostrIdentityReadReceipt(_ messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        nostrReadReceipts.append((messageID, recipientHex))
    }
}

@MainActor
private func drainMainQueue() async {
    for _ in 0..<5 {
        await Task.yield()
    }
}

// MARK: - Coordinator Tests Against Mock Context

/// Covers account subscription ownership, encrypted private messages and
/// acknowledgements, QR-bound sender admission, deduplication, and read-ACK
/// decisions with synthetic identities and injected context effects.
struct ChatNostrCoordinatorContextTests {

    @Test @MainActor
    func accountMailboxStillRequiresTheQRContactBoundToTheSenderForEveryPayload() async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        let recipient = try NostrIdentity.generate()
        let trusted = try NostrIdentity.generate()
        let stranger = try NostrIdentity.generate()
        let key = Data(repeating: 0xA1, count: 32)
        context.nostrIdentity = recipient
        context.qrResolver = { $0 == trusted.publicKeyHex ? key : nil }
        context.admitsSender = { $0.noiseKey == key }
        let contents = [
            try #require(NostrEmbeddedBitChat.encodePMForNostrNoRecipient(content: "Synthetic QR-only message", messageID: "qr-only-pm")),
            try #require(NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .delivered, messageID: "qr-only-delivered")),
            try #require(NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .readReceipt, messageID: "qr-only-read"))
        ]
        for content in contents {
            await coordinator.inbound.processNostrMessage(try NostrProtocol.createPrivateMessage(
                content: content, recipientPubkey: recipient.publicKeyHex, senderIdentity: stranger))
        }
        #expect(context.handledPrivateMessages.isEmpty)
        #expect(context.handledDelivered.isEmpty)
        #expect(context.handledReadReceipts.isEmpty)
        #expect(context.nostrKeyMapping.isEmpty)

        for content in contents {
            await coordinator.inbound.processNostrMessage(try NostrProtocol.createPrivateMessage(
                content: content, recipientPubkey: recipient.publicKeyHex, senderIdentity: trusted))
        }
        #expect(context.handledPrivateMessages.map(\.convKey) == [PeerID(hexData: key)])
        #expect(context.handledDelivered.map(\.convKey) == [PeerID(hexData: key)])
        #expect(context.handledReadReceipts.map(\.convKey) == [PeerID(hexData: key)])
    }

    @Test @MainActor
    func accountMailboxRequiresIdentityAndKeepsTheGiftWrapFilter() throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        coordinator.accountMailbox.setupNostrMessageHandling()
        #expect(context.accountSubscriptions.isEmpty)

        let identity = try NostrIdentity.generate()
        context.nostrIdentity = identity
        let earliest = Int(Date().addingTimeInterval(-TransportConfig.nostrDMSubscribeLookbackSeconds).timeIntervalSince1970)
        coordinator.accountMailbox.setupNostrMessageHandling()
        let latest = Int(Date().addingTimeInterval(-TransportConfig.nostrDMSubscribeLookbackSeconds).timeIntervalSince1970)
        #expect(context.accountSubscriptions.count == 1)
        let subscription = try #require(context.accountSubscriptions.first)
        #expect(subscription.id == "chat-messages")
        #expect(subscription.filter.kinds == [1059])
        let since = try #require(subscription.filter.since)
        #expect((earliest...latest).contains(since))
        let encoded = try JSONEncoder().encode(subscription.filter)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["#p"] as? [String] == [identity.publicKeyHex])
    }

    @Test @MainActor
    func accountMailboxCallbackPreservesPrivateMessagesAndBothAcknowledgements() async throws {
        let context = MockChatNostrContext()
        context.nostrIdentity = try NostrIdentity.generate()
        let recipient = try #require(context.nostrIdentity)
        let sender = try NostrIdentity.generate()
        let coordinator = ChatNostrCoordinator(context: context)
        coordinator.accountMailbox.setupNostrMessageHandling()
        let handler = try #require(context.accountHandlers.first)
        let contents = [
            try #require(NostrEmbeddedBitChat.encodePMForNostrNoRecipient(content: "Synthetic inbox message", messageID: "mailbox-pm")),
            try #require(NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .delivered, messageID: "mailbox-delivered")),
            try #require(NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .readReceipt, messageID: "mailbox-read"))
        ]
        for content in contents {
            handler(try NostrProtocol.createPrivateMessage(
                content: content, recipientPubkey: recipient.publicKeyHex, senderIdentity: sender
            ))
        }
        let routed = await TestHelpers.waitUntil({
            context.handledPrivateMessages.count == 1 && context.handledDelivered.count == 1 &&
                context.handledReadReceipts.count == 1
        }, timeout: TestConstants.settleTimeout)
        #expect(routed)
        #expect(context.activeChannel == .mesh)
        #expect(context.handledPrivateMessages.first?.senderPubkey == sender.publicKeyHex)
        #expect(context.handledDelivered.first?.senderPubkey == sender.publicKeyHex)
        #expect(context.handledReadReceipts.first?.senderPubkey == sender.publicKeyHex)
        let payload = try #require(context.handledPrivateMessages.first?.payload)
        let message = try #require(PrivateMessagePacket.decode(from: payload.data))
        #expect(message.messageID == "mailbox-pm")
        #expect(message.content == "Synthetic inbox message")
    }

    @Test @MainActor
    func accountMailboxDoesNotRetainItsContext() throws {
        var context: MockChatNostrContext? = MockChatNostrContext()
        weak var weakContext = context
        let coordinator = ChatNostrCoordinator(context: try #require(context))
        context = nil
        #expect(weakContext == nil)
        coordinator.accountMailbox.setupNostrMessageHandling()
    }

    @Test @MainActor
    func aRetainedRelayHandlerDoesNotKeepTheAccountMailboxAlive() throws {
        let context = MockChatNostrContext()
        context.nostrIdentity = try NostrIdentity.generate()
        var coordinator: ChatNostrCoordinator? = ChatNostrCoordinator(context: context)
        weak var mailbox = coordinator?.accountMailbox
        coordinator?.accountMailbox.setupNostrMessageHandling()
        #expect(context.accountHandlers.count == 1)
        coordinator = nil
        #expect(mailbox == nil)
    }

    // NOTE: Inbound Schnorr signature verification (and the forged-copy
    // dedup-poisoning invariant) is enforced once, off the main actor, at the
    // relay boundary — see NostrRelayManagerTests
    // `test_receiveEvent_invalidSignatureDoesNotPoisonDuplicateCache` and
    // `test_receiveGiftWrap_tamperedSignatureIsDroppedAndDoesNotPoisonDedup`.
    // The inbound pipeline only ever sees verified events.

    @Test @MainActor
    func accountMessagesFromANonAdmittedSenderReachNoHandler() async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        let recipient = try NostrIdentity.generate()
        let sender = try NostrIdentity.generate()
        context.nostrIdentity = recipient
        context.admitsSender = { _ in false }
        func wrap(_ content: String) throws -> NostrEvent {
            try NostrProtocol.createPrivateMessage(content: content, recipientPubkey: recipient.publicKeyHex, senderIdentity: sender)
        }
        let contents = [
            try #require(NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .delivered, messageID: "mine-1")),
            try #require(NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .readReceipt, messageID: "mine-1")),
            try #require(NostrEmbeddedBitChat.encodePMForNostrNoRecipient(content: "Salut ?", messageID: "pm-1"))
        ]
        for content in contents {
            await coordinator.inbound.processNostrMessage(try wrap(content))
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        await drainMainQueue()

        #expect(context.handledDelivered.isEmpty)
        #expect(context.handledReadReceipts.isEmpty)
        #expect(context.handledPrivateMessages.isEmpty)
        #expect(context.nostrKeyMapping.isEmpty)

        context.admitsSender = { _ in true }
        await coordinator.inbound.processNostrMessage(try wrap(contents[0]))
        #expect(context.handledDelivered.count == 1)
    }

    @Test @MainActor
    func weshInboundReachesHandlersOnlyFromTheUnblockedQRContactBoundToTheSender() async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        let recipient = try NostrIdentity.generate()
        context.nostrIdentity = recipient
        let alice = try NostrIdentity.generate(), bob = try NostrIdentity.generate()
        let mallory = try NostrIdentity.generate(), stranger = try NostrIdentity.generate()
        let aliceKey = Data(repeating: 0xa1, count: 32), bobKey = Data(repeating: 0xb0, count: 32)
        let malloryKey = Data(repeating: 0x3a, count: 32)
        let contacts = [
            WeshQRTrust.Contact(noiseKeyHex: aliceKey.hexEncodedString(), nickname: "Alice", npub: alice.npub, npubProven: true),
            WeshQRTrust.Contact(noiseKeyHex: bobKey.hexEncodedString(), nickname: "Bob", npub: bob.npub, npubConflict: true),
            WeshQRTrust.Contact(noiseKeyHex: malloryKey.hexEncodedString(), nickname: "Mallory", npub: mallory.npub)
        ]
        context.qrResolver = { WeshInternetRoute.senderNoiseKey(forNostrPubkey: $0, contacts: contacts,
                                                                blockedFingerprints: [malloryKey.sha256Fingerprint()]) }
        // Wesh admission: only a full Noise-key peer (a QR contact) is admitted.
        context.admitsSender = { $0.noiseKey != nil }
        let pm = try #require(NostrEmbeddedBitChat.encodePMForNostrNoRecipient(content: "Salut", messageID: "pm-qr"))
        for sender in [stranger, bob, mallory] {
            await coordinator.inbound.processNostrMessage(
                try NostrProtocol.createPrivateMessage(content: pm, recipientPubkey: recipient.publicKeyHex, senderIdentity: sender))
        }
        await drainMainQueue()
        #expect(context.handledPrivateMessages.isEmpty)
        #expect(context.handledDelivered.isEmpty)
        #expect(context.nostrKeyMapping.isEmpty)

        await coordinator.inbound.processNostrMessage(
            try NostrProtocol.createPrivateMessage(content: pm, recipientPubkey: recipient.publicKeyHex, senderIdentity: alice))
        await drainMainQueue()
        #expect(context.handledPrivateMessages.map(\.convKey) == [PeerID(hexData: aliceKey)])
    }

    @Test @MainActor
    func processNostrMessage_duplicateDeliveryProcessesOnce() async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)

        let recipient = try NostrIdentity.generate()
        let sender = try NostrIdentity.generate()
        context.nostrIdentity = recipient
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: "verify:noop",
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        // Fan-in of the same (already verified) gift wrap from several relays
        // records and processes exactly once.
        await coordinator.inbound.processNostrMessage(giftWrap)
        #expect(context.recordedNostrEventIDs == [giftWrap.id])

        await coordinator.inbound.processNostrMessage(giftWrap)
        #expect(context.recordedNostrEventIDs == [giftWrap.id])
    }

    @Test @MainActor
    func sendDeliveryAckViaNostrEmbedded_sendsReadReceiptOnlyWhenViewingUnread() async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        context.nostrIdentity = try NostrIdentity.generate()
        let senderPubkey = "feedface00112233"
        let convKey = PeerID(nostr_: senderPubkey)

        let message = BitchatMessage(
            id: "mid-1",
            sender: "alice#1234",
            content: "hi",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "me",
            senderPeerID: convKey
        )

        // Not viewing the chat: delivery ack only.
        coordinator.sendDeliveryAckViaNostrEmbedded(message, wasReadBefore: false, senderPubkey: senderPubkey, key: nil)
        #expect(context.nostrDeliveryAcks.map(\.messageID) == ["mid-1"])
        #expect(context.nostrDeliveryAcks.first?.recipientHex == senderPubkey)
        #expect(context.nostrReadReceipts.isEmpty)

        // Viewing the chat: delivery ack plus read receipt.
        context.selectedPrivateChatPeer = convKey
        coordinator.sendDeliveryAckViaNostrEmbedded(message, wasReadBefore: false, senderPubkey: senderPubkey, key: Data([0x01]))
        #expect(context.nostrDeliveryAcks.count == 2)
        #expect(context.nostrReadReceipts.map(\.messageID) == ["mid-1"])

        // Already read: no further read receipt.
        coordinator.sendDeliveryAckViaNostrEmbedded(message, wasReadBefore: true, senderPubkey: senderPubkey, key: nil)
        #expect(context.nostrDeliveryAcks.count == 3)
        #expect(context.nostrReadReceipts.count == 1)
    }

}
