//
// ChatNostrCoordinatorContextTests.swift
// bitchatTests
//
// Exercises the `ChatNostrCoordinator` facade and its components
// (`NostrInboundPipeline`, `GeohashSubscriptionManager`, `GeoPresenceTracker`)
// against a mock `ChatNostrContext` — proving the stack works without a
// `ChatViewModel`, following the `ChatDeliveryCoordinatorContextTests` /
// `ChatPrivateConversationCoordinatorContextTests` exemplars.
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
    // Channel & subscription state
    var activeChannel: ChannelID = .mesh
    var currentGeohash: String?
    var geoSubscriptionID: String?
    var geoDmSubscriptionID: String?
    var geoSamplingSubs: [String: String] = [:]
    var lastGeoNotificationAt: [String: Date] = [:]
    private(set) var accountSubscriptions: [(filter: NostrFilter, id: String)] = []
    private(set) var accountHandlers: [(NostrEvent) -> Void] = []

    func subscribeAccountMailbox(filter: NostrFilter, id: String, handler: @escaping (NostrEvent) -> Void) {
        accountSubscriptions.append((filter, id))
        accountHandlers.append(handler)
    }

    func setGeoChatSubscriptionID(_ id: String?) { geoSubscriptionID = id }
    func setGeoDmSubscriptionID(_ id: String?) { geoDmSubscriptionID = id }
    func addGeoSamplingSub(_ subID: String, forGeohash geohash: String) { geoSamplingSubs[subID] = geohash }
    func removeGeoSamplingSub(_ subID: String) { geoSamplingSubs.removeValue(forKey: subID) }

    func clearGeoSamplingSubs() -> [String] {
        defer { geoSamplingSubs.removeAll() }
        return Array(geoSamplingSubs.keys)
    }

    // Public timeline & pipeline
    var messages: [BitchatMessage] = []
    private(set) var pipelineFlushCount = 0
    private(set) var refreshedChannels: [ChannelID?] = []
    private(set) var publicSystemMessages: [String] = []
    var pendingGeohashSystemMessages: [String] = []
    private(set) var appendedGeohashMessages: [(message: BitchatMessage, geohash: String)] = []

    func flushPublicMessagePipeline() { pipelineFlushCount += 1 }
    func refreshVisibleMessages(from channel: ChannelID?) { refreshedChannels.append(channel) }
    func addPublicSystemMessage(_ content: String) { publicSystemMessages.append(content) }

    func drainPendingGeohashSystemMessages() -> [String] {
        defer { pendingGeohashSystemMessages.removeAll() }
        return pendingGeohashSystemMessages
    }

    func appendGeohashMessageIfAbsent(_ message: BitchatMessage, toGeohash geohash: String) -> Bool {
        guard !appendedGeohashMessages.contains(where: { $0.message.id == message.id && $0.geohash == geohash }) else {
            return false
        }
        appendedGeohashMessages.append((message, geohash))
        return true
    }

    // Inbound public messages
    private(set) var handledPublicMessages: [BitchatMessage] = []
    private(set) var publicDeliveryChannels: [ChannelID] = []
    private(set) var mentionCheckedMessageIDs: [String] = []
    private(set) var hapticMessageIDs: [String] = []

    func handlePublicMessage(_ message: BitchatMessage, powBits: Int) {
        handledPublicMessages.append(message)
        publicDeliveryChannels.append(activeChannel)
    }
    func checkForMentions(_ message: BitchatMessage) { mentionCheckedMessageIDs.append(message.id) }
    func sendHapticFeedback(for message: BitchatMessage) { hapticMessageIDs.append(message.id) }
    func parseMentions(from content: String) -> [String] { [] }

    // Inbound private (geohash DM) payloads
    var selectedPrivateChatPeer: PeerID?
    var nostrKeyMapping: [PeerID: String] = [:]
    func registerNostrKeyMapping(_ pubkey: String, for peerID: PeerID) { nostrKeyMapping[peerID] = pubkey }
    private(set) var handledPrivateMessages: [(payload: NoisePayload, senderPubkey: String, convKey: PeerID, timestamp: Date)] = []
    private(set) var handledDelivered: [(senderPubkey: String, convKey: PeerID)] = []
    private(set) var handledReadReceipts: [(senderPubkey: String, convKey: PeerID)] = []
    private(set) var startedPrivateChats: [PeerID] = []

    func handlePrivateMessage(
        _ payload: NoisePayload,
        senderPubkey: String,
        convKey: PeerID,
        id: NostrIdentity,
        messageTimestamp: Date
    ) {
        handledPrivateMessages.append((payload, senderPubkey, convKey, messageTimestamp))
    }

    func handleDelivered(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID) {
        handledDelivered.append((senderPubkey, convKey))
    }

    func handleReadReceipt(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID) {
        handledReadReceipts.append((senderPubkey, convKey))
    }

    func startPrivateChat(with peerID: PeerID) { startedPrivateChats.append(peerID) }

    // Nostr identity & blocking
    var geohashIdentities: [String: NostrIdentity] = [:]
    var nostrIdentity: NostrIdentity?
    var blockedNostrPubkeys: Set<String> = []
    var admitsSender: (PeerID) -> Bool = { _ in true }
    func admitsPrivateSender(_ peerID: PeerID) -> Bool { admitsSender(peerID) }
    var qrResolver: ((String) -> Data?)?
    var resolvesNostrSendersFromQRContacts: Bool { qrResolver != nil }
    func qrContactNoiseKey(forNostrPubkey pubkey: String) -> Data? { qrResolver?(pubkey) }
    var displayNamesByPubkey: [String: String] = [:]

    private struct NoIdentity: Error {}

    private(set) var geographicDerivations: [String] = []
    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity {
        geographicDerivations.append(geohash)
        guard let identity = geohashIdentities[geohash] else { throw NoIdentity() }
        return identity
    }

    func currentNostrIdentity() -> NostrIdentity? { nostrIdentity }

    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool {
        blockedNostrPubkeys.contains(pubkeyHexLowercased.lowercased())
    }

    func displayNameForNostrPubkey(_ pubkeyHex: String) -> String {
        displayNamesByPubkey[pubkeyHex] ?? "anon"
    }

    // Event dedup
    private(set) var recordedNostrEventIDs: [String] = []
    private var processedNostrEventIDs: Set<String> = []
    private(set) var clearProcessedNostrEventsCount = 0

    private(set) var eventLookupCount = 0
    func hasProcessedNostrEvent(_ eventID: String) -> Bool {
        eventLookupCount += 1
        return processedNostrEventIDs.contains(eventID)
    }

    func recordProcessedNostrEvent(_ eventID: String) {
        processedNostrEventIDs.insert(eventID)
        recordedNostrEventIDs.append(eventID)
    }

    func clearProcessedNostrEvents() {
        processedNostrEventIDs.removeAll()
        clearProcessedNostrEventsCount += 1
    }

    // Geo participants & presence
    var geoNicknames: [String: String] = [:]
    private(set) var teleportedKeys: Set<String> = []
    var teleportedGeoCount: Int { teleportedKeys.count }
    private(set) var refreshTimerStartCount = 0
    private(set) var refreshTimerStopCount = 0
    private(set) var activeParticipantGeohashes: [String?] = []
    private(set) var recordedParticipants: [String] = []
    private(set) var recordedSampledParticipants: [(pubkeyHex: String, geohash: String)] = []
    private(set) var clearTeleportedGeoCount = 0
    private(set) var clearGeoNicknamesCount = 0
    var visiblePeople: [GeoPerson] = []

    func startGeoParticipantRefreshTimer() { refreshTimerStartCount += 1 }
    func stopGeoParticipantRefreshTimer() { refreshTimerStopCount += 1 }
    func setActiveParticipantGeohash(_ geohash: String?) { activeParticipantGeohashes.append(geohash) }
    func recordGeoParticipant(pubkeyHex: String) { recordedParticipants.append(pubkeyHex) }

    func recordGeoParticipant(pubkeyHex: String, geohash: String) {
        recordedSampledParticipants.append((pubkeyHex, geohash))
    }

    func geoParticipantCount(for geohash: String) -> Int {
        recordedSampledParticipants.filter { $0.geohash == geohash }.count
    }

    func setGeoNickname(_ nickname: String, forPubkey pubkeyHex: String) { geoNicknames[pubkeyHex.lowercased()] = nickname }
    func markGeoTeleported(_ pubkeyHexLowercased: String) { teleportedKeys.insert(pubkeyHexLowercased) }
    func clearGeoTeleported(_ pubkeyHexLowercased: String) { teleportedKeys.remove(pubkeyHexLowercased) }

    func clearTeleportedGeo() {
        teleportedKeys.removeAll()
        clearTeleportedGeoCount += 1
    }

    func clearGeoNicknames() {
        geoNicknames.removeAll()
        clearGeoNicknamesCount += 1
    }

    func visibleGeohashPeople() -> [GeoPerson] { visiblePeople }

    // Location channels
    var isTeleported = false
    var regionalGeohashes: Set<String> = []

    func isGeohashOutsideRegionalChannels(_ geohash: String) -> Bool {
        !regionalGeohashes.isEmpty && !regionalGeohashes.contains(geohash)
    }

    // Routing & acknowledgements
    private(set) var routedFavoriteNotifications: [(peerID: PeerID, isFavorite: Bool)] = []
    private(set) var nostrDeliveryAcks: [(messageID: String, recipientHex: String)] = []
    private(set) var nostrReadReceipts: [(messageID: String, recipientHex: String)] = []

    func routeFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        routedFavoriteNotifications.append((peerID, isFavorite))
    }

    func sendNostrIdentityDeliveryAck(for messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        nostrDeliveryAcks.append((messageID, recipientHex))
    }

    func sendNostrIdentityReadReceipt(_ messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        nostrReadReceipts.append((messageID, recipientHex))
    }

    // Favorites & notifications
    var favoriteRelationshipsByNoiseKey: [Data: FavoritesPersistenceService.FavoriteRelationship] = [:]
    private(set) var geohashActivityNotifications: [(geohash: String, bodyPreview: String)] = []

    func favoriteRelationship(forNoiseKey noiseKey: Data) -> FavoritesPersistenceService.FavoriteRelationship? {
        favoriteRelationshipsByNoiseKey[noiseKey]
    }

    func allFavoriteRelationships() -> [FavoritesPersistenceService.FavoriteRelationship] {
        Array(favoriteRelationshipsByNoiseKey.values)
    }

    func notifyGeohashActivity(geohash: String, bodyPreview: String) {
        geohashActivityNotifications.append((geohash, bodyPreview))
    }
}

/// Geographic events are retired independently from the account mailbox.
/// All identities, cells and context state here are synthetic and in memory.
@MainActor
struct GeographicInboundRetirementTests {
    @Test(arguments: [false, true])
    func aQueuedGeographicEventCannotEnterTheCurrentPublicTimeline(useSubscribePath: Bool) async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        let channelA = ChannelID.location(GeohashChannel(level: .city, geohash: "00000"))
        let channelB = ChannelID.location(GeohashChannel(level: .city, geohash: "zzzzz"))
        context.activeChannel = channelA
        context.currentGeohash = "00000"
        let sender = try NostrIdentity.generate()
        let event = try NostrEvent(pubkey: sender.publicKeyHex, createdAt: Date(), kind: .ephemeralEvent,
            tags: [["g", "00000"]], content: "Synthetic retired geographic event")
            .sign(with: sender.schnorrSigningKey())
        try #require(event.isValidSignature())

        // Both calls are synchronous on this actor. The old public delivery
        // task cannot run between intake in A and selection of B below.
        if useSubscribePath { coordinator.inbound.subscribeNostrEvent(event) }
        else { coordinator.inbound.handleNostrEvent(event) }
        context.activeChannel = channelB
        context.currentGeohash = "zzzzz"

        // The real account subscription callback remains functional while the
        // queued geographic event is drained. Three decryptions and their actor
        // deliveries provide positive progress through the surviving inbox.
        let recipient = try NostrIdentity.generate()
        context.nostrIdentity = recipient
        coordinator.accountMailbox.setupNostrMessageHandling()
        let handler = try #require(context.accountHandlers.first)
        let contents = [
            try #require(NostrEmbeddedBitChat.encodePMForNostrNoRecipient(content: "Synthetic account message", messageID: "geo-retirement-pm")),
            try #require(NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .delivered, messageID: "geo-retirement-delivered")),
            try #require(NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .readReceipt, messageID: "geo-retirement-read"))
        ]
        for content in contents {
            handler(try NostrProtocol.createPrivateMessage(content: content,
                recipientPubkey: recipient.publicKeyHex, senderIdentity: sender))
        }
        try #require(await TestHelpers.waitUntil({
            context.handledPrivateMessages.count == 1 && context.handledDelivered.count == 1 &&
                context.handledReadReceipts.count == 1
        }, timeout: TestConstants.settleTimeout))

        #expect(context.handledPublicMessages.isEmpty,
            "A queued retired event must not be delivered after the active channel changes")
        #expect(context.publicDeliveryChannels.isEmpty)
        #expect(context.handledPrivateMessages.first?.senderPubkey == sender.publicKeyHex)
        #expect(context.handledDelivered.first?.senderPubkey == sender.publicKeyHex)
        #expect(context.handledReadReceipts.first?.senderPubkey == sender.publicKeyHex)
    }

    @Test
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
        #expect(context.handledPublicMessages.isEmpty)
    }
}

/// Remaining public sampling entrypoints and the private geographic owner
/// are exercised without shared network, activity or platform location adapters.
@MainActor
struct GeographicCallbackRetirementTests {
    @Test(arguments: [NostrProtocol.EventKind.ephemeralEvent, .geohashPresence])
    func legacySamplingCannotAttributeARecordedPresence(kind: NostrProtocol.EventKind) throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        let sender = try NostrIdentity.generate()
        let event = try NostrEvent(pubkey: sender.publicKeyHex, createdAt: Date(), kind: kind,
            tags: [["g", "00000"]], content: "").sign(with: sender.schnorrSigningKey())
        try #require(event.isValidSignature())
        // Empty content guarantees the baseline returns before shared chat
        // activity or application-state adapters, while exposing attribution.
        coordinator.presence.subscribeNostrEvent(event, gh: "00000")
        #expect(context.recordedSampledParticipants.isEmpty)
        #expect(context.geographicDerivations.isEmpty)
    }

    @Test
    func legacyCooldownCannotStoreNotifyOrStampGeography() async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        let sender = try NostrIdentity.generate()
        let event = try NostrProtocol.createEphemeralGeohashEvent(content: "Synthetic retired sample",
            geohash: "00000", senderIdentity: sender, nickname: "Synthetic")
        coordinator.presence.cooldownPerGeohash("00000", content: event.content, event: event)
        await mainQueueFence()
        #expect(context.appendedGeohashMessages.isEmpty)
        #expect(context.geohashActivityNotifications.isEmpty)
        #expect(context.lastGeoNotificationAt.isEmpty)
    }

    @Test
    func legacyTeleportCallbackCannotAttributeAPeer() async {
        let context = MockChatNostrContext()
        let tracker = GeoPresenceTracker(context: context)
        tracker.scheduleMarkPeerTeleported(String(repeating: "ab", count: 32), logged: false)
        await mainQueueFence()
        #expect(context.teleportedKeys.isEmpty)
    }

    @Test
    func retiredPrivateGeographicOwnerCannotDeriveOnStaleSelectionOrReconnect() {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        // No identity exists: baseline derivation records then throws before
        // any live network adapter. Account mailbox subscription is injected.
        coordinator.subscriptions.retireForPanic()
        let channel = GeohashChannel(level: .city, geohash: "00000")
        coordinator.subscriptions.switchLocationChannel(to: .location(channel))
        coordinator.subscriptions.resubscribeCurrentGeohash()
        coordinator.subscriptions.subscribeToGeoChat(channel)
        #expect(context.geographicDerivations.isEmpty)
        #expect(context.activeChannel == .mesh)
        context.nostrIdentity = try? NostrIdentity.generate()
        coordinator.accountMailbox.setupNostrMessageHandling()
        #expect(context.accountSubscriptions.count == 1)
    }

    @Test(arguments: [false, true])
    func queuedPrivateGeographicCallbackHonorsOwnerRetirement(retire: Bool) async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        let recipient = try NostrIdentity.generate()
        let sender = try NostrIdentity.generate()
        context.geohashIdentities["00000"] = recipient
        var capturedHandler: ((NostrEvent) -> Void)?
        let dependencies = GeohashSubscriptionDependencies(torIsReady: { false },
            subscribe: { _, _, handler in capturedHandler = handler }, unsubscribe: { _ in })
        let owner = GeohashSubscriptionManager(context: context, inbound: coordinator.inbound,
            presence: coordinator.presence, dependencies: dependencies)
        owner.subscribeToGeoChat(GeohashChannel(level: .city, geohash: "00000"))
        let handler = try #require(capturedHandler)
        let gift = try NostrProtocol.createPrivateMessage(content: "Synthetic already processed private message",
            recipientPubkey: recipient.publicKeyHex, senderIdentity: sender)
        // The dedup positive prevents detached decrypt work: the observable
        // is entry into the real pipeline's synchronous precheck itself.
        context.recordProcessedNostrEvent(gift.id)
        let before = context.eventLookupCount
        if retire { owner.retireForPanic(); coordinator.inbound.invalidateInFlightDecrypts() }
        handler(gift)
        await mainQueueFence()
        #expect(context.eventLookupCount == before + (retire ? 0 : 1))
        #expect(context.handledPrivateMessages.isEmpty)
        context.nostrIdentity = recipient
        coordinator.accountMailbox.setupNostrMessageHandling()
        #expect(context.accountSubscriptions.count == 1)
    }

    private func mainQueueFence() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

// MARK: - Helpers

/// Let the inner `Task { @MainActor in ... }` hops the coordinator schedules
/// run to completion.
@MainActor
private func drainMainQueue() async {
    for _ in 0..<5 {
        await Task.yield()
    }
}

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `ChatNostrCoordinator` against `MockChatNostrContext` with no
/// `ChatViewModel`. Scoped to the inbound event pipeline (dedup, presence,
/// public-message ingest), gift-wrap DM ingest, key mapping, channel-switch
/// teardown, embedded ack flows, and — now that favorites and notifications
/// are injected through the context — the favorite-notification ingest and
/// the sampled-geohash notification cooldown. Flows that hit live singletons
/// (`NostrRelayManager.shared` subscriptions, `TorManager`) remain covered by
/// the full view-model tests.
struct ChatNostrCoordinatorContextTests {

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

    @Test @MainActor
    func handleNostrEvent_refusesPublicMessageAndReplayBeforeAnyAttribution() async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        let sender = try NostrIdentity.generate()
        let event = try NostrProtocol.createEphemeralGeohashEvent(content: "Synthetic retired message",
            geohash: "00000", senderIdentity: sender, nickname: "Synthetic")
        try #require(event.isValidSignature())
        coordinator.inbound.handleNostrEvent(event)
        coordinator.inbound.handleNostrEvent(event)
        await drainMainQueue()
        #expect(context.recordedNostrEventIDs.isEmpty)
        #expect(context.geoNicknames.isEmpty)
        #expect(context.recordedParticipants.isEmpty)
        #expect(context.nostrKeyMapping.isEmpty)
        #expect(context.handledPublicMessages.isEmpty)
        #expect(context.mentionCheckedMessageIDs.isEmpty)
        #expect(context.hapticMessageIDs.isEmpty)
    }

    @Test @MainActor
    func handleNostrEvent_refusesEmptyTeleportPresence() async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        let sender = try NostrIdentity.generate()
        let event = try NostrProtocol.createEphemeralGeohashEvent(content: "", geohash: "00000",
            senderIdentity: sender, teleported: true)
        coordinator.inbound.handleNostrEvent(event)
        await drainMainQueue()
        #expect(context.teleportedKeys.isEmpty)
        #expect(context.recordedParticipants.isEmpty)
        #expect(context.handledPublicMessages.isEmpty)
    }

    @Test @MainActor
    func handleNostrEvent_refusesBlockedGeographicSenderWithoutRecordingIt() async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        let sender = try NostrIdentity.generate()
        let event = try NostrProtocol.createEphemeralGeohashEvent(content: "Synthetic blocked message",
            geohash: "00000", senderIdentity: sender)
        context.blockedNostrPubkeys.insert(event.pubkey.lowercased())
        coordinator.inbound.handleNostrEvent(event)
        await drainMainQueue()
        #expect(context.recordedNostrEventIDs.isEmpty)
        #expect(context.recordedParticipants.isEmpty)
        #expect(context.handledPublicMessages.isEmpty)
    }

    @Test @MainActor
    func handleGiftWrap_routesEmbeddedPrivateMessageAndDeduplicates() async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)

        let recipient = try NostrIdentity.generate()
        let sender = try NostrIdentity.generate()
        let embedded = try #require(NostrEmbeddedBitChat.encodePMForNostrNoRecipient(
            content: "psst",
            messageID: "gm-1"
        ))
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: embedded,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        coordinator.inbound.handleGiftWrap(giftWrap, id: recipient)

        // The NIP-17 unwrap runs off the main actor; wait for the hop back.
        let convKey = PeerID(nostr_: sender.publicKeyHex)
        let routed = await TestHelpers.waitUntil({ context.handledPrivateMessages.count == 1 }, timeout: TestConstants.settleTimeout)
        #expect(routed)
        #expect(context.recordedNostrEventIDs == [giftWrap.id])
        #expect(context.nostrKeyMapping[convKey] == sender.publicKeyHex)
        #expect(context.handledPrivateMessages.first?.senderPubkey == sender.publicKeyHex)
        #expect(context.handledPrivateMessages.first?.convKey == convKey)

        // The embedded Noise payload survives the round trip intact.
        let payload = try #require(context.handledPrivateMessages.first?.payload)
        #expect(payload.type == .privateMessage)
        let pm = try #require(PrivateMessagePacket.decode(from: payload.data))
        #expect(pm.messageID == "gm-1")
        #expect(pm.content == "psst")

        // The same gift wrap is dropped on replay.
        coordinator.inbound.handleGiftWrap(giftWrap, id: recipient)
        await drainMainQueue()
        #expect(context.recordedNostrEventIDs == [giftWrap.id])
        #expect(context.handledPrivateMessages.count == 1)
    }

    @Test @MainActor
    func handleGiftWrap_panicWipeAfterSpawnDropsDecryptedResult() async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)

        let recipient = try NostrIdentity.generate()
        let sender = try NostrIdentity.generate()
        let embedded = try #require(NostrEmbeddedBitChat.encodePMForNostrNoRecipient(
            content: "pre-wipe secret",
            messageID: "gm-wipe-1"
        ))
        let giftWrap = try NostrProtocol.createPrivateMessage(
            content: embedded,
            recipientPubkey: recipient.publicKeyHex,
            senderIdentity: sender
        )

        // Spawn the detached decrypt (it strongly captures the pre-wipe
        // identity), then panic-wipe in the SAME main-actor turn — guaranteed
        // to land before the task's first main-actor hop.
        coordinator.inbound.handleGiftWrap(giftWrap, id: recipient)
        coordinator.inbound.invalidateInFlightDecrypts()

        // Give the detached task ample time to have delivered if the wipe
        // guard were broken.
        try? await Task.sleep(nanoseconds: 200_000_000)
        await drainMainQueue()

        #expect(context.handledPrivateMessages.isEmpty)
        #expect(context.recordedNostrEventIDs.isEmpty)

        // The pipeline itself stays usable: a gift wrap spawned AFTER the
        // wipe (new generation) still decrypts and delivers.
        coordinator.inbound.handleGiftWrap(giftWrap, id: recipient)
        let delivered = await TestHelpers.waitUntil({ context.handledPrivateMessages.count == 1 }, timeout: TestConstants.settleTimeout)
        #expect(delivered)
    }

    // NOTE: Inbound Schnorr signature verification (and the forged-copy
    // dedup-poisoning invariant) is enforced once, off the main actor, at the
    // relay boundary — see NostrRelayManagerTests
    // `test_receiveEvent_invalidSignatureDoesNotPoisonDuplicateCache` and
    // `test_receiveGiftWrap_tamperedSignatureIsDroppedAndDoesNotPoisonDedup`.
    // The inbound pipeline only ever sees verified events.

    @Test @MainActor
    func directMessagesFromANonAdmittedSenderReachNoHandlerOnEitherPath() async throws {
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
            coordinator.inbound.handleGiftWrap(try wrap(content), id: recipient)
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
    func switchLocationChannel_toMesh_tearsDownGeohashState() async {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        context.activeChannel = .mesh
        context.currentGeohash = "u4pruyd"
        context.geoNicknames = ["abcd": "alice"]

        coordinator.subscriptions.switchLocationChannel(to: .mesh)

        #expect(context.pipelineFlushCount == 1)
        #expect(context.activeChannel == .mesh)
        #expect(context.clearProcessedNostrEventsCount == 1)
        #expect(context.refreshedChannels == [.mesh])
        #expect(context.refreshTimerStopCount == 1)
        #expect(context.clearTeleportedGeoCount == 1)
        // Cleared once in the mesh branch, once in the shared teardown.
        #expect(context.activeParticipantGeohashes == [nil, nil])
        #expect(context.currentGeohash == nil)
        #expect(context.geoSubscriptionID == nil)
        #expect(context.geoDmSubscriptionID == nil)
        #expect(context.clearGeoNicknamesCount == 1)
        #expect(context.geoNicknames.isEmpty)
        // Mesh never starts a geohash subscription or refresh timer.
        #expect(context.refreshTimerStartCount == 0)
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

    @Test @MainActor
    func geohashDMKeyMappingHelpers_resolveAndStartChats() async {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        let hex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
        let convKey = PeerID(nostr_: hex)
        context.displayNamesByPubkey[hex] = "bob#eeff"

        coordinator.startGeohashDM(withPubkeyHex: hex)
        #expect(context.nostrKeyMapping[convKey] == hex)
        #expect(context.startedPrivateChats == [convKey])

        #expect(coordinator.fullNostrHex(forSenderPeerID: convKey) == hex)
        #expect(coordinator.geohashDisplayName(for: convKey) == "bob#eeff")

        // Unmapped conversation keys fall back to the bare peer ID.
        let unknown = PeerID(nostr_: "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100")
        #expect(coordinator.geohashDisplayName(for: unknown) == unknown.bare)

        // Display-name lookup prefers visible people, then nicknames.
        context.visiblePeople = [GeoPerson(id: "aa11", displayName: "carol#aa11", lastSeen: Date())]
        context.geoNicknames = ["bb22": "dave"]
        #expect(coordinator.nostrPubkeyForDisplayName("carol#aa11") == "aa11")
        #expect(coordinator.nostrPubkeyForDisplayName("dave") == "bb22")
        #expect(coordinator.nostrPubkeyForDisplayName("nobody") == nil)
    }
}

// MARK: - GeoPresenceTracker Tests

/// Focused tests for seams the coordinator split made independently
/// testable: the sampling-event LRU dedup and the per-geohash notification
/// cooldown. The cooldown tests stop short of the live notification center by
/// pre-seeding the timeline append as a duplicate.
struct GeoPresenceTrackerTests {

    @Test @MainActor
    func samplingEventDedup_evictsOldestBeyondLRUCap() {
        let context = MockChatNostrContext()
        let tracker = GeoPresenceTracker(context: context)
        let cap = TransportConfig.geoSamplingEventLRUCap

        // Empty IDs are never deduplicated.
        #expect(tracker.shouldProcessGeoSamplingEvent(""))
        #expect(tracker.shouldProcessGeoSamplingEvent(""))

        // First sight passes; a replay is rejected.
        #expect(tracker.shouldProcessGeoSamplingEvent("ev-0"))
        #expect(!tracker.shouldProcessGeoSamplingEvent("ev-0"))

        // Fill one past the cap: the oldest entry is evicted and accepted
        // again, while a still-resident entry stays deduplicated.
        for i in 1...cap {
            #expect(tracker.shouldProcessGeoSamplingEvent("ev-\(i)"))
        }
        #expect(tracker.shouldProcessGeoSamplingEvent("ev-0"))
        #expect(!tracker.shouldProcessGeoSamplingEvent("ev-\(cap)"))

        // Clearing resets the dedup entirely.
        tracker.clearGeoSamplingEventDedup()
        #expect(tracker.shouldProcessGeoSamplingEvent("ev-\(cap)"))
    }

    @Test @MainActor
    func notificationCooldown_skipsWithinWindow() async throws {
        let context = MockChatNostrContext()
        let tracker = GeoPresenceTracker(context: context)
        let sender = try NostrIdentity.generate()
        let event = try NostrProtocol.createEphemeralGeohashEvent(
            content: "sampled activity",
            geohash: "9q8yy",
            senderIdentity: sender,
            nickname: "alice"
        )

        // Within the cooldown window nothing is appended or re-stamped.
        let recent = Date()
        context.lastGeoNotificationAt["9q8yy"] = recent
        tracker.cooldownPerGeohash("9q8yy", content: "sampled activity", event: event)
        await drainMainQueue()
        #expect(context.appendedGeohashMessages.isEmpty)
        #expect(context.lastGeoNotificationAt["9q8yy"] == recent)
    }

    @Test @MainActor
    func notificationCooldown_retirementDoesNotRestampEvenAnExpiredWindow() async throws {
        let context = MockChatNostrContext()
        let tracker = GeoPresenceTracker(context: context)
        let sender = try NostrIdentity.generate()
        let event = try NostrProtocol.createEphemeralGeohashEvent(
            content: "sampled activity",
            geohash: "9q8yy",
            senderIdentity: sender,
            nickname: "alice"
        )

        // Pre-seed the same event ID so the timeline append reports a
        // duplicate and the flow never reaches the live notification center.
        let placeholder = BitchatMessage(
            id: event.id,
            sender: "seed",
            content: "seed",
            timestamp: Date(),
            isRelay: false
        )
        #expect(context.appendGeohashMessageIfAbsent(placeholder, toGeohash: "9q8yy"))

        // An elapsed historical cooldown cannot revive sampled publication.
        let stale = Date().addingTimeInterval(-TransportConfig.uiGeoNotifyCooldownSeconds - 1)
        context.lastGeoNotificationAt["9q8yy"] = stale
        tracker.cooldownPerGeohash("9q8yy", content: "sampled activity", event: event)
        await drainMainQueue()

        let stamped = try #require(context.lastGeoNotificationAt["9q8yy"])
        #expect(stamped == stale)
        #expect(context.appendedGeohashMessages.count == 1)
    }

    @Test @MainActor
    func geoPresence_retirementRefusesSampledNotificationsForEveryPreviewSize() async throws {
        let context = MockChatNostrContext()
        let coordinator = ChatNostrCoordinator(context: context)
        let sender = try NostrIdentity.generate()
        for content in ["Synthetic sample", String(repeating: "x", count: TransportConfig.uiGeoNotifySnippetMaxLen + 20)] {
            let event = try NostrProtocol.createEphemeralGeohashEvent(content: content,
                geohash: "00000", senderIdentity: sender, nickname: "Synthetic")
            coordinator.presence.cooldownPerGeohash("00000", content: content, event: event)
        }
        await drainMainQueue()
        #expect(context.geohashActivityNotifications.isEmpty)
        #expect(context.appendedGeohashMessages.isEmpty)
        #expect(context.lastGeoNotificationAt.isEmpty)
    }
}
