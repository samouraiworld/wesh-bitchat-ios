import BitFoundation
import BitLogger
import Foundation
import Tor

/// The narrow surface `GeohashSubscriptionManager` needs from its owner.
///
/// Split out of `ChatNostrContext`: member names are shared with the sibling
/// component contexts so `ChatViewModel` provides a single witness for each.
@MainActor
protocol GeohashSubscriptionContext: AnyObject {
    // MARK: Channel & subscription state
    var activeChannel: ChannelID { get set }
    var currentGeohash: String? { get set }
    var geoSubscriptionID: String? { get }
    var geoDmSubscriptionID: String? { get }
    func setGeoChatSubscriptionID(_ id: String?)
    func setGeoDmSubscriptionID(_ id: String?)
    /// Geohash sampling subscriptions: subscription ID -> geohash.
    var geoSamplingSubs: [String: String] { get }
    func addGeoSamplingSub(_ subID: String, forGeohash geohash: String)
    func removeGeoSamplingSub(_ subID: String)
    /// Clears all sampling subscriptions and returns the removed subscription IDs
    /// so the caller can unsubscribe them from the relay manager.
    func clearGeoSamplingSubs() -> [String]

    // MARK: Public timeline & pipeline
    var messages: [BitchatMessage] { get }
    /// Commits any batched-but-unflushed public messages to the store so a
    /// channel switch never strands them in the pipeline buffer.
    func flushPublicMessagePipeline()
    func refreshVisibleMessages(from channel: ChannelID?)
    func addPublicSystemMessage(_ content: String)
    func drainPendingGeohashSystemMessages() -> [String]

    // MARK: Nostr identity & dedup
    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity
    func recordProcessedNostrEvent(_ eventID: String)
    func clearProcessedNostrEvents()
    /// Records the Nostr pubkey behind a (possibly virtual) peer ID.
    func registerNostrKeyMapping(_ pubkey: String, for peerID: PeerID)

    // MARK: Geo participants & presence
    var teleportedGeoCount: Int { get }
    func startGeoParticipantRefreshTimer()
    func stopGeoParticipantRefreshTimer()
    func setActiveParticipantGeohash(_ geohash: String?)
    func recordGeoParticipant(pubkeyHex: String)
    func markGeoTeleported(_ pubkeyHexLowercased: String)
    func clearGeoTeleported(_ pubkeyHexLowercased: String)
    func clearTeleportedGeo()
    func clearGeoNicknames()

    // MARK: Location channels
    var isTeleported: Bool { get }
    /// True when regional channels are known and the geohash is not one of them.
    func isGeohashOutsideRegionalChannels(_ geohash: String) -> Bool
}

extension ChatViewModel: GeohashSubscriptionContext {
    // `activeChannel`, `currentGeohash`, the subscription-ID accessors, the
    // identity members, and the timeline members already have witnesses on
    // `ChatViewModel`. The members below flatten nested service accesses into
    // intent-named calls.

    func flushPublicMessagePipeline() {
        publicMessagePipeline.flushIfNeeded()
    }

    func clearProcessedNostrEvents() {
        deduplicationService.clearNostrCaches()
    }

    func startGeoParticipantRefreshTimer() {
        participantTracker.startRefreshTimer()
    }

    func stopGeoParticipantRefreshTimer() {
        participantTracker.stopRefreshTimer()
    }

    func setActiveParticipantGeohash(_ geohash: String?) {
        participantTracker.setActiveGeohash(geohash)
    }

    func clearGeoTeleported(_ pubkeyHexLowercased: String) {
        locationPresenceStore.clearTeleported(pubkeyHexLowercased)
    }

    func clearTeleportedGeo() {
        locationPresenceStore.clearTeleportedGeo()
    }

    func clearGeoNicknames() {
        locationPresenceStore.clearGeoNicknames()
    }

    var isTeleported: Bool {
        locationManager.teleported
    }

    func isGeohashOutsideRegionalChannels(_ geohash: String) -> Bool {
        let channels = locationManager.availableChannels
        return !channels.isEmpty && !channels.contains { $0.geohash == geohash }
    }
}

struct GeohashSubscriptionDependencies {
    var torIsReady: @MainActor () -> Bool = { TorManager.shared.isReady }
    var subscribe: @MainActor (NostrFilter, String, @escaping (NostrEvent) -> Void) -> Void = { filter, id, handler in
        NostrRelayManager.shared.subscribe(filter: filter, id: id, handler: handler)
    }
    var unsubscribe: @MainActor (String) -> Void = { NostrRelayManager.shared.unsubscribe(id: $0) }
}

/// Owns subscription IDs and relay lifecycle for geohash channels, geohash
/// DMs and background geohash sampling. Geographic inbound events are
/// forwarded to `NostrInboundPipeline` / `GeoPresenceTracker`.
final class GeohashSubscriptionManager {
    private weak var context: (any GeohashSubscriptionContext)?
    private let inbound: NostrInboundPipeline
    private let presence: GeoPresenceTracker
    private let dependencies: GeohashSubscriptionDependencies
    private var retiredForPanic = false

    init(context: any GeohashSubscriptionContext, inbound: NostrInboundPipeline, presence: GeoPresenceTracker,
         dependencies: GeohashSubscriptionDependencies = GeohashSubscriptionDependencies()) {
        self.context = context
        self.inbound = inbound
        self.presence = presence
        self.dependencies = dependencies
    }

    @MainActor
    func resubscribeCurrentGeohash() {
        guard !retiredForPanic else { return }
        guard let context else { return }
        if let subID = context.geoSubscriptionID {
            dependencies.unsubscribe(subID)
            context.setGeoChatSubscriptionID(nil)
        }
        context.stopGeoParticipantRefreshTimer()
        // Private derived-identity mailboxes remain a separate retirement
        // boundary; this method can no longer create a public subscription.
        if case .location(let channel) = context.activeChannel { subscribeToGeoChat(channel) }
    }

    @MainActor
    func switchLocationChannel(to channel: ChannelID) {
        guard !retiredForPanic else { return }
        guard let context else { return }
        context.flushPublicMessagePipeline()
        context.activeChannel = channel

        context.clearProcessedNostrEvents()
        switch channel {
        case .mesh:
            context.refreshVisibleMessages(from: .mesh)
            let emptyMesh = context.messages.filter { $0.content.trimmed.isEmpty }.count
            if emptyMesh > 0 {
                SecureLogger.debug("RenderGuard: mesh timeline contains \(emptyMesh) empty messages", category: .session)
            }
            context.stopGeoParticipantRefreshTimer()
            context.setActiveParticipantGeohash(nil)
            context.clearTeleportedGeo()

        case .location:
            context.refreshVisibleMessages(from: channel)
        }

        if case .location = channel {
            for content in context.drainPendingGeohashSystemMessages() {
                context.addPublicSystemMessage(content)
            }
        }

        if let sub = context.geoSubscriptionID {
            dependencies.unsubscribe(sub)
            context.setGeoChatSubscriptionID(nil)
        }
        if let dmSub = context.geoDmSubscriptionID {
            dependencies.unsubscribe(dmSub)
            context.setGeoDmSubscriptionID(nil)
        }
        context.currentGeohash = nil
        context.setActiveParticipantGeohash(nil)
        context.clearGeoNicknames()

        guard case .location(let channel) = channel else { return }
        context.currentGeohash = channel.geohash
        context.setActiveParticipantGeohash(channel.geohash)

        if let identity = try? context.deriveNostrIdentity(forGeohash: channel.geohash) {
            context.recordGeoParticipant(pubkeyHex: identity.publicKeyHex)
            let key = identity.publicKeyHex.lowercased()
            if context.isTeleported && context.isGeohashOutsideRegionalChannels(channel.geohash) {
                context.markGeoTeleported(key)
                SecureLogger.info(
                    "GeoTeleport: channel switch mark self teleported key=\(key.prefix(8))… total=\(context.teleportedGeoCount)",
                    category: .session
                )
            } else {
                context.clearGeoTeleported(key)
            }
        }

        subscribeToGeoChat(channel)
    }

    @MainActor
    func subscribeToGeoChat(_ channel: GeohashChannel) {
        guard !retiredForPanic else { return }
        guard let context else { return }
        guard let identity = try? context.deriveNostrIdentity(forGeohash: channel.geohash) else { return }

        let dmSub = "geo-dm-\(channel.geohash)"
        context.setGeoDmSubscriptionID(dmSub)
        if dependencies.torIsReady() {
            SecureLogger.debug("GeoDM: subscribing DMs pub=\(identity.publicKeyHex.prefix(8))… sub=\(dmSub)", category: .session)
        }
        let dmFilter = NostrFilter.giftWrapsFor(
            pubkey: identity.publicKeyHex,
            since: Date().addingTimeInterval(-TransportConfig.nostrDMSubscribeLookbackSeconds)
        )
        dependencies.subscribe(dmFilter, dmSub) { [weak self] giftWrap in
            Task { @MainActor [weak self] in
                guard let self, !self.retiredForPanic else { return }
                self.inbound.handleGiftWrap(giftWrap, id: identity)
            }
        }
    }

    @MainActor
    func retireForPanic() {
        retiredForPanic = true
        guard let context else { return }
        if let sub = context.geoSubscriptionID { dependencies.unsubscribe(sub) }
        if let sub = context.geoDmSubscriptionID { dependencies.unsubscribe(sub) }
        context.setGeoChatSubscriptionID(nil)
        context.setGeoDmSubscriptionID(nil)
        context.stopGeoParticipantRefreshTimer()
        endGeohashSampling()
        // The separately owned account mailbox keeps its subscription and callbacks.
    }

    @MainActor
    func sendGeohash(context geoContext: ChatViewModel.GeoOutgoingContext) {
        // Public geographic sends are retired, including delayed sends made
        // under a previous selection. Never redirect their content to mesh.
    }

    @MainActor
    func beginGeohashSampling(for geohashes: [String]) {
        endGeohashSampling()
    }

    @MainActor
    func subscribe(_ gh: String) {
        // Geographic public sampling no longer opens relay subscriptions.
    }

    @MainActor
    func endGeohashSampling() {
        guard let context else { return }
        for subID in context.clearGeoSamplingSubs() {
            dependencies.unsubscribe(subID)
        }
        presence.clearGeoSamplingEventDedup()
    }

}
