//
// ChatOutgoingCoordinatorContextTests.swift
// bitchatTests
//
// Exercises `ChatOutgoingCoordinator` against a mock `ChatOutgoingContext` —
// proving the coordinator works without a `ChatViewModel`, following the
// `ChatDeliveryCoordinatorContextTests` exemplar.
//
// Scope note: the geohash path builds and signs a real Nostr event via
// `NostrProtocol.createEphemeralGeohashEvent` (pure crypto, no shared state);
// everything else flows through the mock context.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

// MARK: - Mock Context

/// Lightweight stand-in for `ChatOutgoingContext` proving that
/// `ChatOutgoingCoordinator` is testable without a `ChatViewModel`.
@MainActor
private final class MockChatOutgoingContext: ChatOutgoingContext {
    // Identity & channel state
    var nickname = "me"
    var myPeerID = PeerID(str: "0011223344556677")
    var activeChannel: ChannelID = .mesh
    var selectedPrivateChatPeer: PeerID?

    // Commands & private messages
    var selectedPeerAfterUpdate: PeerID??
    private(set) var handledCommands: [String] = []
    private(set) var updatePrivateChatPeerIfNeededCount = 0
    private(set) var sentPrivateMessages: [(content: String, peerID: PeerID)] = []

    func handleCommand(_ command: String) { handledCommands.append(command) }

    func updatePrivateChatPeerIfNeeded() {
        updatePrivateChatPeerIfNeededCount += 1
        if let selectedPeerAfterUpdate {
            selectedPrivateChatPeer = selectedPeerAfterUpdate
        }
    }

    func sendPrivateMessage(_ content: String, to peerID: PeerID) {
        sentPrivateMessages.append((content, peerID))
    }

    // Public timeline (local echo)
    private(set) var appendedPublicMessages: [(message: BitchatMessage, conversationID: ConversationID)] = []
    private(set) var systemMessages: [String] = []

    func parseMentions(from content: String) -> [String] {
        content.contains("@bob") ? ["bob"] : []
    }

    @discardableResult
    func appendPublicMessage(_ message: BitchatMessage, to conversationID: ConversationID) -> Bool {
        appendedPublicMessages.append((message, conversationID))
        return true
    }

    // Content dedup
    private(set) var recordedContentKeys: [(key: String, timestamp: Date)] = []

    func normalizedContentKey(_ content: String) -> String { "key:\(content)" }
    func recordContentKey(_ key: String, timestamp: Date) {
        recordedContentKeys.append((key, timestamp))
    }

    // Outbound routing
    private(set) var sentMeshMessages: [(content: String, mentions: [String], messageID: String, timestamp: Date)] = []

    func sendMeshMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date) {
        sentMeshMessages.append((content, mentions, messageID, timestamp))
    }

}

@MainActor
struct GeographicOutgoingRetirementTests {
    @Test
    func aRetiredGeographicSelectionCannotPublishOrFallBackToPublicMesh() async throws {
        let context = MockChatOutgoingContext()
        context.activeChannel = .location(GeohashChannel(level: .city, geohash: "00000"))
        let coordinator = ChatOutgoingCoordinator(context: context)

        coordinator.sendMessage("Synthetic retired geographic send")

        #expect(context.sentMeshMessages.isEmpty)
        #expect(context.appendedPublicMessages.isEmpty)
    }

    @Test
    func localPublicMeshStillPublishesAndKeepsItsLocalEcho() {
        let context = MockChatOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context)

        coordinator.sendMessage("Synthetic ordinary mesh control")

        #expect(context.sentMeshMessages.count == 1)
        #expect(context.appendedPublicMessages.map(\.conversationID) == [.mesh])
    }
}

// MARK: - Helpers

@MainActor
struct WeshPublicOutgoingContentFilterTests {
    @Test func rejectedPublicTextHasNoEchoNoDedupMutationAndNoTransportSend() {
        let context = MockChatOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context, publicContentAllowed: WeshPublicContentPolicy.allows)
        coordinator.sendMessage("I will kill you", allowCommands: false)
        #expect(context.sentMeshMessages.isEmpty)
        #expect(context.appendedPublicMessages.isEmpty)
        #expect(context.recordedContentKeys.isEmpty)
    }

    @Test func privateTextIsNeverPassedToThePublicEvaluator() {
        let context = MockChatOutgoingContext()
        let peer = PeerID(str: "aabbccddeeff0011")
        context.selectedPrivateChatPeer = peer
        var evaluations = 0
        let coordinator = ChatOutgoingCoordinator(context: context, publicContentAllowed: { _ in evaluations += 1; return false })
        coordinator.sendMessage("I will kill you", allowCommands: false)
        #expect(evaluations == 0)
        #expect(context.sentPrivateMessages.first?.content == "I will kill you")
        #expect(context.sentPrivateMessages.first?.peerID == peer)
        #expect(context.sentMeshMessages.isEmpty)
    }

    @Test func acceptedPublicTextKeepsItsOriginalWireBytes() {
        let context = MockChatOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context, publicContentAllowed: WeshPublicContentPolicy.allows)
        let text = "  Bonjour 👋 e\u{0301}  "
        coordinator.sendMessage(text, allowCommands: false)
        #expect(context.sentMeshMessages.first?.content == text)
    }
}

/// Lets the coordinator's internal `Task { @MainActor … }` hops run.
@MainActor
private func drainMainActorTasks() async {
    for _ in 0..<10 { await Task.yield() }
}

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `ChatOutgoingCoordinator` against `MockChatOutgoingContext` with
/// no `ChatViewModel`.
struct ChatOutgoingCoordinatorContextTests {

    @Test @MainActor
    func weshTextDoesNotInterpretSlashCommandsOrSwitchRecipients() async {
        let context = MockChatOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context)
        coordinator.sendMessage("/msg someone secret", allowCommands: false)
        await drainMainActorTasks()
        #expect(context.handledCommands.isEmpty)
        #expect(context.sentPrivateMessages.isEmpty)
        #expect(context.sentMeshMessages.first?.content == "/msg someone secret")
        #expect(context.appendedPublicMessages.first?.conversationID == .mesh)
    }

    @Test @MainActor
    func sendMessage_routesSlashCommandsAndDropsEmptyContent() async {
        let context = MockChatOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context)

        coordinator.sendMessage("   ")
        coordinator.sendMessage("/who all")
        await drainMainActorTasks()

        #expect(context.handledCommands == ["/who all"])
        #expect(context.appendedPublicMessages.isEmpty)
        #expect(context.sentMeshMessages.isEmpty)
    }

    @Test @MainActor
    func sendMessage_inPrivateChat_reResolvesPeerBeforeSending() async {
        let context = MockChatOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context)
        let shortPeer = PeerID(str: "1111111111111111")
        let stablePeer = PeerID(str: String(repeating: "ab", count: 32))

        // The selected peer is refreshed (short → stable) before sending.
        context.selectedPrivateChatPeer = shortPeer
        context.selectedPeerAfterUpdate = stablePeer
        coordinator.sendMessage("hi there")
        #expect(context.updatePrivateChatPeerIfNeededCount == 1)
        #expect(context.sentPrivateMessages.map(\.peerID) == [stablePeer])
        #expect(context.sentPrivateMessages.map(\.content) == ["hi there"])

        // If the refresh clears the selection, nothing is sent.
        context.selectedPeerAfterUpdate = PeerID??.some(nil)
        coordinator.sendMessage("dropped")
        await drainMainActorTasks()
        #expect(context.sentPrivateMessages.count == 1)
        #expect(context.appendedPublicMessages.isEmpty)
    }

    @Test @MainActor
    func sendMessage_onMesh_appendsLocalEchoRecordsActivityAndSends() async {
        let context = MockChatOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context)

        coordinator.sendMessage("  hello @bob  ")
        await drainMainActorTasks()

        // Local echo uses the trimmed content, own nickname/peer ID, mentions.
        #expect(context.appendedPublicMessages.count == 1)
        let echo = context.appendedPublicMessages[0]
        #expect(echo.message.content == "hello @bob")
        #expect(echo.message.sender == "me")
        #expect(echo.message.senderPeerID == context.myPeerID)
        #expect(echo.message.mentions == ["bob"])
        #expect(echo.conversationID == .mesh)
        #expect(context.recordedContentKeys.map(\.key) == ["key:hello @bob"])

        // The mesh send carries the original (untrimmed) content and reuses
        // the echo's message ID and timestamp; activity is stamped for "mesh".
        #expect(context.sentMeshMessages.count == 1)
        let sent = context.sentMeshMessages[0]
        #expect(sent.content == "  hello @bob  ")
        #expect(sent.mentions == ["bob"])
        #expect(sent.messageID == echo.message.id)
        #expect(sent.timestamp == echo.message.timestamp)
    }

    @Test @MainActor
    func sendMessage_onRetiredLocationChannel_neverEchoesOrSendsEvenWhenIdentityFails() async {
        let context = MockChatOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context)
        context.activeChannel = .location(GeohashChannel(level: .city, geohash: "00000"))
        coordinator.sendMessage("Synthetic retired geographic send")
        coordinator.sendMessage("Synthetic identity failure control")
        await drainMainActorTasks()
        #expect(context.systemMessages.isEmpty)
        #expect(context.appendedPublicMessages.isEmpty)
        #expect(context.sentMeshMessages.isEmpty)
    }

    @Test @MainActor
    func sendMessage_onRetiredLocationChannel_refusesRapidSendsWithoutMining() async {
        let context = MockChatOutgoingContext()
        let coordinator = ChatOutgoingCoordinator(context: context)
        context.activeChannel = .location(GeohashChannel(level: .city, geohash: "00000"))
        coordinator.sendMessage("first " + String(repeating: "x", count: 4000))
        coordinator.sendMessage("second")
        #expect(context.appendedPublicMessages.isEmpty)
        #expect(context.sentMeshMessages.isEmpty)
    }
}
