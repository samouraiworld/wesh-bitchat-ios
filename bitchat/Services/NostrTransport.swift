import BitLogger
import BitFoundation
import Foundation
import Combine

// Minimal Nostr transport conforming to Transport for offline sending
final class NostrTransport: Transport, RelayConfirmedTransport, @unchecked Sendable {
    struct Dependencies {
        let notificationCenter: NotificationCenter
        let loadFavorites: @MainActor () -> [Data: FavoritesPersistenceService.FavoriteRelationship]
        let favoriteStatusForNoiseKey: @MainActor (Data) -> FavoritesPersistenceService.FavoriteRelationship?
        let favoriteStatusForPeerID: @MainActor (PeerID) -> FavoritesPersistenceService.FavoriteRelationship?
        let currentIdentity: @MainActor () throws -> NostrIdentity?
        let registerPendingGiftWrap: @MainActor (String) -> Void
        let sendEvent: @MainActor (NostrEvent) -> Void
        /// Publishes a private message and reports the relays' answer
        /// (`NostrRelayManager.sendEventImmediately`): « Envoyé » needs a relay `OK`.
        let publishEvent: @MainActor (NostrEvent, @escaping @MainActor (NostrPublishOutcome) -> Void) -> Void
        /// Emits whether a relay that carries private messages is up
        /// (fail-closed behind Tor). A connected geohash/custom relay alone
        /// doesn't count: DM sends target the default relay set and would
        /// still queue.
        let relayConnectivity: @MainActor () -> AnyPublisher<Bool, Never>
        /// Paces outbound acks. Defaults to an isolated pacer so tests don't
        /// serialize behind each other; `live` passes the process-wide one.
        let ackPacer: AckPacer
        /// Wesh: npub per QR contact (full Noise-key peer ID), from the signed
        /// QR only. When set, favorites are never read. Nil outside Wesh.
        let weshRecipients: (@MainActor () -> AnyPublisher<[PeerID: String], Never>)?
        /// Wesh: Internet mode is On (Tor ready, a pinned relay connected).
        /// Anything else fails closed: the router keeps the message queued.
        let weshOnline: (@MainActor () -> AnyPublisher<Bool, Never>)?
        /// Wesh: a blocked contact's Noise key is never sent anything, whatever the map says.
        let weshIsBlocked: (@MainActor (Data) -> Bool)?

        init(
            notificationCenter: NotificationCenter,
            loadFavorites: @escaping @MainActor () -> [Data: FavoritesPersistenceService.FavoriteRelationship],
            favoriteStatusForNoiseKey: @escaping @MainActor (Data) -> FavoritesPersistenceService.FavoriteRelationship?,
            favoriteStatusForPeerID: @escaping @MainActor (PeerID) -> FavoritesPersistenceService.FavoriteRelationship?,
            currentIdentity: @escaping @MainActor () throws -> NostrIdentity?,
            registerPendingGiftWrap: @escaping @MainActor (String) -> Void,
            sendEvent: @escaping @MainActor (NostrEvent) -> Void,
            publishEvent: @escaping @MainActor (NostrEvent, @escaping @MainActor (NostrPublishOutcome) -> Void) -> Void,
            scheduleAfter: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void,
            relayConnectivity: @escaping @MainActor () -> AnyPublisher<Bool, Never>,
            ackPacer: AckPacer? = nil,
            weshRecipients: (@MainActor () -> AnyPublisher<[PeerID: String], Never>)? = nil,
            weshOnline: (@MainActor () -> AnyPublisher<Bool, Never>)? = nil,
            weshIsBlocked: (@MainActor (Data) -> Bool)? = nil
        ) {
            self.notificationCenter = notificationCenter
            self.loadFavorites = loadFavorites
            self.favoriteStatusForNoiseKey = favoriteStatusForNoiseKey
            self.favoriteStatusForPeerID = favoriteStatusForPeerID
            self.currentIdentity = currentIdentity
            self.registerPendingGiftWrap = registerPendingGiftWrap
            self.sendEvent = sendEvent
            self.publishEvent = publishEvent
            self.relayConnectivity = relayConnectivity
            // Default pacer drives its throttle through the same injected
            // scheduler, so tests that step scheduleAfter manually keep
            // control of the ack cadence.
            self.ackPacer = ackPacer ?? AckPacer(scheduleAfter: scheduleAfter)
            self.weshRecipients = weshRecipients
            self.weshOnline = weshOnline
            self.weshIsBlocked = weshIsBlocked
        }

        @MainActor
        static func live(idBridge: NostrIdentityBridge,
                         isBlocked: (@MainActor (Data) -> Bool)? = nil) -> Dependencies {
            var weshRecipients: (@MainActor () -> AnyPublisher<[PeerID: String], Never>)?
            var weshOnline: (@MainActor () -> AnyPublisher<Bool, Never>)?
            var weshIsBlocked: (@MainActor (Data) -> Bool)?
            if WeshMode.isActive {
                weshRecipients = {
                    WeshQRTrust.shared.$contacts
                        .map { WeshInternetRoute.recipients(contacts: $0, blockedFingerprints: []) }
                        .eraseToAnyPublisher()
                }
                weshOnline = { WeshInternetMode.shared.$state.map { $0 == .on }.eraseToAnyPublisher() }
                // Fail closed: without a block check, nothing is resolved in Wesh.
                weshIsBlocked = isBlocked ?? { _ in true }
            }
            return Dependencies(
                notificationCenter: .default,
                loadFavorites: { FavoritesPersistenceService.shared.favorites },
                favoriteStatusForNoiseKey: { FavoritesPersistenceService.shared.getFavoriteStatus(for: $0) },
                favoriteStatusForPeerID: { FavoritesPersistenceService.shared.getFavoriteStatus(forPeerID: $0) },
                currentIdentity: { idBridge.messagingIdentity() },
                registerPendingGiftWrap: { NostrRelayManager.registerPendingGiftWrap(id: $0) },
                sendEvent: { NostrRelayManager.shared.sendEvent($0) },
                publishEvent: { event, completion in
                    NostrRelayManager.shared.sendEventImmediately(event) { outcome in
                        Task { @MainActor in completion(outcome) }
                    }
                },
                scheduleAfter: { delay, action in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
                },
                relayConnectivity: { NostrRelayManager.shared.$isDMRelayConnected.eraseToAnyPublisher() },
                ackPacer: NostrTransport.sharedAckPacer,
                weshRecipients: weshRecipients,
                weshOnline: weshOnline,
                weshIsBlocked: weshIsBlocked
            )
        }
    }

    // BLE short peer ID embedded in favorites (recipient-addressed) envelopes.
    // Explicit-identity envelopes never carry it (see NostrEmbeddedBitChat).
    var senderPeerID = PeerID(str: "")

    // Throttle outbound acks — READ receipts and DELIVERED acks, direct and
    // explicit-identity — to avoid relay rate limits. Reconnect redelivery produces a
    // burst of acks at once: 8 DELIVERED in under a second tripped damus's
    // "noting too much" during July 2026 device testing.
    private enum QueuedAck {
        case readDirect(ReadReceipt, PeerID)
        case deliveredDirect(messageID: String, peerID: PeerID)
        case deliveredNostrIdentity(messageID: String, recipientHex: String, identity: NostrIdentity)
        case readNostrIdentity(messageID: String, recipientHex: String, identity: NostrIdentity)
    }

    /// Ack pacing shared across transport instances. Explicit-identity acks are sent
    /// through short-lived transports created per ack
    /// (`makePrivateNostrTransport()`), so a per-instance queue would only
    /// ever hold one item and never pace a burst (flagged in upstream review on
    /// #1398). Production wires `sharedAckPacer` via `Dependencies.live`;
    /// tests get an isolated instance per `Dependencies` by default.
    /// @unchecked Sendable: all mutable state (`pending`, `isSending`) is
    /// confined to the serial `queue`; the class is only touched via
    /// `enqueue` and the scheduler callback, both of which hop onto it.
    final class AckPacer: @unchecked Sendable {
        typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

        private let queue = DispatchQueue(label: "chat.bitchat.nostr-ack-pacer")
        private var pending: [() -> Void] = []
        private var isSending = false
        private let interval: TimeInterval = TransportConfig.nostrReadAckInterval
        private let scheduleAfter: Scheduler

        init(scheduleAfter: @escaping Scheduler = { delay, action in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: action)
        }) {
            self.scheduleAfter = scheduleAfter
        }

        func enqueue(_ send: @escaping () -> Void) {
            queue.async {
                self.pending.append(send)
                self.processNext()
            }
        }

        private var epoch: UInt64 = 0

        /// Bumped by the emergency erase. Sends and acks captured before it are dropped when
        /// they run, so nothing reserved under the pre-erase identity leaves afterwards. Shared
        /// in production like the pacer; isolated per `Dependencies` in tests.
        var eraseEpoch: UInt64 { queue.sync { epoch } }

        /// Erase: drops every ack still waiting for its turn and fences every send captured
        /// before this point. The send already handed to the relay manager is not recalled.
        func discardWorkBeforeErase() {
            queue.sync {
                epoch &+= 1
                pending.removeAll()
            }
        }

        /// Must be called on `queue`.
        private func processNext() {
            guard !isSending, !pending.isEmpty else { return }
            isSending = true
            let send = pending.removeFirst()
            send()
            scheduleAfter(interval) { [weak self] in
                guard let self else { return }
                self.queue.async {
                    self.isSending = false
                    self.processNext()
                }
            }
        }
    }
    static let sharedAckPacer = AckPacer()
    private let dependencies: Dependencies

    /// A signed gift wrap kept so a retry republishes the same event (same id): relays answer
    /// `duplicate` and the recipient sees one message. Memory only, never written to disk.
    private struct PendingWrap {
        let event: NostrEvent
        let recipientHex: String
        let senderPubkey: String
        /// Erase epoch the wrap was signed under; an erase makes it unusable.
        let epoch: UInt64
    }

    /// By message ID, for messages the router still holds (`retainPendingPrivateMessages`).
    /// Dropped after a relay refusal so the next retry signs a new wrap.
    @MainActor private var pendingWraps: [String: PendingWrap] = [:]
    @MainActor var onPrivateMessageAccepted: ((_ messageID: String, _ peerID: PeerID) -> Void)?
    @MainActor var onInternetAvailable: (() -> Void)?
    private var favoriteStatusObserver: NSObjectProtocol?

    // Reachability Cache (thread-safe)
    private var reachablePeers: Set<PeerID> = []
    // Mirror of the relay manager's connection state, cached here because
    // canDeliverPromptly is called synchronously off the main actor.
    private var relaysConnected = false
    private var relayConnectivityCancellable: AnyCancellable?
    /// Wesh: nil outside Wesh. Guarded by `queue`.
    private var weshNpubs: [PeerID: String]?
    private var weshIsOnline = false
    private var weshCancellables: Set<AnyCancellable> = []
    private let queue = DispatchQueue(label: "nostr.transport.state", attributes: .concurrent)

    @MainActor
    init(
        keychain _: KeychainManagerProtocol,
        idBridge: NostrIdentityBridge,
        dependencies: Dependencies? = nil
    ) {
        self.dependencies = dependencies ?? .live(idBridge: idBridge)

        if let weshRecipients = self.dependencies.weshRecipients {
            // Wesh: QR contacts only; favorites are never consulted.
            queue.sync(flags: .barrier) { self.weshNpubs = [:] }
            weshRecipients()
                .sink { [weak self] recipients in
                    guard let self else { return }
                    self.queue.async(flags: .barrier) { self.weshNpubs = recipients }
                }
                .store(in: &weshCancellables)
            self.dependencies.weshOnline?()
                .sink { [weak self] online in
                    guard let self else { return }
                    self.queue.async(flags: .barrier) {
                        let cameOn = online && !self.weshIsOnline
                        self.weshIsOnline = online
                        if cameOn { self.announceInternetAvailable() }
                    }
                }
                .store(in: &weshCancellables)
            relayConnectivityCancellable = self.dependencies.relayConnectivity()
                .sink { [weak self] connected in
                    guard let self else { return }
                    self.queue.async(flags: .barrier) { self.noteRelaysConnected(connected) }
                }
            return
        }

        setupObservers()

        // Synchronously warm the cache to avoid startup race
        let favorites = self.dependencies.loadFavorites()
        let reachable = favorites.values
            .filter { $0.peerNostrPublicKey != nil }
            .map { PeerID(publicKey: $0.peerNoisePublicKey) }

        queue.sync(flags: .barrier) {
            self.reachablePeers = Set(reachable)
        }

        relayConnectivityCancellable = self.dependencies.relayConnectivity()
            .sink { [weak self] connected in
                guard let self else { return }
                self.queue.async(flags: .barrier) { self.noteRelaysConnected(connected) }
            }
    }

    /// Must be called on `queue` (barrier). A relay coming back is a chance to retry early.
    private func noteRelaysConnected(_ connected: Bool) {
        let reconnected = connected && !relaysConnected
        relaysConnected = connected
        if reconnected { announceInternetAvailable() }
    }

    /// Called after the new state is stored, so the router's retry already sees it.
    private func announceInternetAvailable() {
        Task { @MainActor [weak self] in self?.onInternetAvailable?() }
    }

    deinit {
        if let favoriteStatusObserver {
            dependencies.notificationCenter.removeObserver(favoriteStatusObserver)
        }
    }

    @MainActor
    private func setupObservers() {
        favoriteStatusObserver = dependencies.notificationCenter.addObserver(
            forName: .favoriteStatusChanged,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.refreshReachablePeers()
        }
    }

    private func refreshReachablePeers() {
        Task { @MainActor in
            let favorites = dependencies.loadFavorites()
            let reachable = favorites.values
                .filter { $0.peerNostrPublicKey != nil }
                .map { PeerID(publicKey: $0.peerNoisePublicKey) }

            self.queue.async(flags: .barrier) { [weak self] in
                self?.reachablePeers = Set(reachable)
            }
        }
    }

    // MARK: - Transport Protocol Conformance

    weak var delegate: BitchatDelegate?
    weak var eventDelegate: TransportEventDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?

    func currentPeerSnapshots() -> [TransportPeerSnapshot] { [] }

    var myPeerID: PeerID { senderPeerID }
    var myNickname: String { "" }
    func setNickname(_ nickname: String) { /* not used for Nostr */ }

    func startServices() { /* no-op */ }
    func stopServices() { /* no-op */ }
    func emergencyDisconnectAll() { /* no-op */ }

    func isPeerConnected(_ peerID: PeerID) -> Bool { false }

    var unackedSendsAreBounded: Bool { false }

    var messageTransport: MessageTransport { .internet }
    
    func isPeerReachable(_ peerID: PeerID) -> Bool {
        // Callers address peers by either the short 16-hex ID or the full
        // 64-hex noise key (offline favorites), so compare in short form.
        let short = peerID.toShort()
        return queue.sync {
            if let weshNpubs {
                return weshIsOnline && Self.weshNpub(for: peerID, short: short, in: weshNpubs) != nil
            }
            if reachablePeers.contains(peerID) { return true }
            return reachablePeers.contains(where: { $0.toShort() == short })
        }
    }

    func canDeliverPromptly(to peerID: PeerID) -> Bool {
        // A known npub makes a peer "reachable", but with no relay
        // connection a send is not published until a later retry. Answering honestly
        // here lets the router hand a sealed copy to a courier in parallel
        // instead of waiting for internet that may never come.
        isPeerReachable(peerID) && queue.sync { relaysConnected }
    }

    func canDeliverSecurely(to peerID: PeerID) -> Bool {
        // Nostr has no link bindings to forge; a known recipient key plus a
        // connected relay is the strongest delivery signal it has. The router
        // already retains + couriers for Nostr sends, so keep that behavior.
        canDeliverPromptly(to: peerID)
    }

    func peerNickname(peerID: PeerID) -> String? { nil }
    func getPeerNicknames() -> [PeerID: String] { [:] }

    func getFingerprint(for peerID: PeerID) -> String? { nil }
    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState { .none }
    func triggerHandshake(with peerID: PeerID) { /* no-op */ }

    // Nostr does not use Noise sessions here; the inert Transport defaults
    // for the noise* identity hooks apply.

    // Public broadcast not supported over Nostr here
    func sendMessage(_ content: String, mentions: [String]) { /* no-op */ }

    func sendPrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        let epoch = dependencies.ackPacer.eraseEpoch
        Task { @MainActor in
            guard epoch == dependencies.ackPacer.eraseEpoch else { return }
            guard let recipientNpub = resolveRecipientNpub(for: peerID),
                  let recipientHex = npubToHex(recipientNpub),
                  let senderIdentity = try? dependencies.currentIdentity() else { return }
            guard let event = privateMessageWrap(
                content: content,
                to: peerID,
                recipientHex: recipientHex,
                senderIdentity: senderIdentity,
                messageID: messageID,
                epoch: epoch
            ) else { return }
            dependencies.publishEvent(event) { outcome in
                guard epoch == self.dependencies.ackPacer.eraseEpoch else { return }
                switch outcome {
                case .accepted:
                    self.onPrivateMessageAccepted?(messageID, peerID)
                case .rejected:
                    // Refused: the next retry signs a new wrap. Only this one is forgotten,
                    // in case a newer wrap replaced it meanwhile.
                    if self.pendingWraps[messageID]?.event.id == event.id {
                        self.pendingWraps.removeValue(forKey: messageID)
                    }
                case .unconfirmed:
                    // No answer is not a refusal: the retry republishes this same event.
                    break
                }
            }
        }
    }

    /// The cached wrap for a retry, or a newly signed one.
    @MainActor
    private func privateMessageWrap(
        content: String,
        to peerID: PeerID,
        recipientHex: String,
        senderIdentity: NostrIdentity,
        messageID: String,
        epoch: UInt64
    ) -> NostrEvent? {
        if let cached = pendingWraps[messageID],
           cached.epoch == epoch,
           cached.recipientHex == recipientHex,
           cached.senderPubkey == senderIdentity.publicKeyHex {
            SecureLogger.debug("NostrTransport: republishing PM id=\(messageID.prefix(8))…", category: .session)
            return cached.event
        }
        SecureLogger.debug("NostrTransport: preparing PM id=\(messageID.prefix(8))…", category: .session)
        guard let embedded = NostrEmbeddedBitChat.encodePMForNostr(content: content, messageID: messageID, recipientPeerID: peerID, senderPeerID: senderPeerID) else {
            SecureLogger.error("NostrTransport: failed to embed PM packet", category: .session)
            return nil
        }
        guard let event = try? NostrProtocol.createPrivateMessage(content: embedded, recipientPubkey: recipientHex, senderIdentity: senderIdentity) else {
            SecureLogger.error("NostrTransport: failed to build Nostr event", category: .session)
            return nil
        }
        pendingWraps[messageID] = PendingWrap(
            event: event,
            recipientHex: recipientHex,
            senderPubkey: senderIdentity.publicKeyHex,
            epoch: epoch
        )
        return event
    }

    @MainActor
    func retainPendingPrivateMessages(_ messageIDs: Set<String>) {
        guard !pendingWraps.isEmpty else { return }
        pendingWraps = pendingWraps.filter { messageIDs.contains($0.key) }
    }

    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        enqueueAck(.readDirect(receipt, peerID))
    }

    /// Enqueue an ack for paced sending. Captures self strongly on purpose:
    /// Explicit-identity acks ride throwaway transport instances that must stay alive
    /// until their ack leaves the queue.
    private func enqueueAck(_ ack: QueuedAck) {
        let epoch = dependencies.ackPacer.eraseEpoch
        dependencies.ackPacer.enqueue { self.sendAckItem(ack, epoch: epoch) }
    }

    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        // Wesh sends `[FAVORITED]:npub` only over a Noise session, never over a relay.
        if queue.sync(execute: { weshNpubs != nil }) { return }
        let epoch = dependencies.ackPacer.eraseEpoch
        Task { @MainActor in
            guard epoch == dependencies.ackPacer.eraseEpoch else { return }
            guard let recipientNpub = resolveRecipientNpub(for: peerID),
                  let recipientHex = npubToHex(recipientNpub),
                  let senderIdentity = try? dependencies.currentIdentity() else { return }
            let content = isFavorite ? "[FAVORITED]:\(senderIdentity.npub)" : "[UNFAVORITED]:\(senderIdentity.npub)"
            SecureLogger.debug("NostrTransport: preparing FAVORITE(\(isFavorite)) to \(recipientNpub.prefix(16))…", category: .session)
            guard let embedded = NostrEmbeddedBitChat.encodePMForNostr(content: content, messageID: UUID().uuidString, recipientPeerID: peerID, senderPeerID: senderPeerID) else {
                SecureLogger.error("NostrTransport: failed to embed favorite notification", category: .session)
                return
            }
            sendWrappedMessage(content: embedded, recipientHex: recipientHex, senderIdentity: senderIdentity)
        }
    }

    func sendBroadcastAnnounce() { /* no-op for Nostr */ }
    func sendDeliveryAck(for messageID: String, to peerID: PeerID) {
        enqueueAck(.deliveredDirect(messageID: messageID, peerID: peerID))
    }
}

// MARK: - Explicit Nostr Identity Helpers

extension NostrTransport {

    // MARK: Explicit-identity ACK helpers
    func sendDeliveryAckForNostrIdentity(for messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        enqueueAck(.deliveredNostrIdentity(messageID: messageID, recipientHex: recipientHex, identity: identity))
    }

    func sendReadReceiptForNostrIdentity(_ messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        enqueueAck(.readNostrIdentity(messageID: messageID, recipientHex: recipientHex, identity: identity))
    }

    // MARK: Private messages using the supplied Nostr identity
    func sendPrivateMessageForNostrIdentity(content: String, toRecipientHex recipientHex: String, from identity: NostrIdentity, messageID: String) {
        let epoch = dependencies.ackPacer.eraseEpoch
        Task { @MainActor in
            guard epoch == dependencies.ackPacer.eraseEpoch else { return }
            guard !recipientHex.isEmpty else { return }
            SecureLogger.debug("GeoDM: send PM mid=\(messageID.prefix(8))…", category: .session)
            guard let embedded = NostrEmbeddedBitChat.encodePMForNostrNoRecipient(content: content, messageID: messageID) else {
                SecureLogger.error("NostrTransport: failed to embed geohash PM packet", category: .session)
                return
            }
            sendWrappedMessage(content: embedded, recipientHex: recipientHex, senderIdentity: identity, registerPending: true)
        }
    }
}

// MARK: - Private Helpers

extension NostrTransport {
    /// Converts npub bech32 string to hex pubkey
    @MainActor
    private func npubToHex(_ npub: String) -> String? {
        do {
            let (hrp, data) = try Bech32.decode(npub)
            guard hrp == "npub" else { return nil }
            return data.hexEncodedString()
        } catch {
            SecureLogger.error("NostrTransport: failed to decode npub -> hex: \(error)", category: .session)
            return nil
        }
    }

    /// Creates and sends a gift-wrapped private message event
    @MainActor
    private func sendWrappedMessage(content: String, recipientHex: String, senderIdentity: NostrIdentity, registerPending: Bool = false) {
        guard let event = try? NostrProtocol.createPrivateMessage(content: content, recipientPubkey: recipientHex, senderIdentity: senderIdentity) else {
            SecureLogger.error("NostrTransport: failed to build Nostr event", category: .session)
            return
        }
        if registerPending {
            dependencies.registerPendingGiftWrap(event.id)
        }
        dependencies.sendEvent(event)
    }


    /// Sends a single ack item (invoked by the pacer, one per interval)
    private func sendAckItem(_ item: QueuedAck, epoch: UInt64) {
        Task { @MainActor in
            guard epoch == dependencies.ackPacer.eraseEpoch else { return }
            switch item {
            case .readDirect(let receipt, let peerID):
                guard let recipientNpub = resolveRecipientNpub(for: peerID),
                      let recipientHex = npubToHex(recipientNpub),
                      let senderIdentity = try? dependencies.currentIdentity() else { return }
                SecureLogger.debug("NostrTransport: preparing READ ack id=\(receipt.originalMessageID.prefix(8))…", category: .session)
                guard let ack = NostrEmbeddedBitChat.encodeAckForNostr(type: .readReceipt, messageID: receipt.originalMessageID, recipientPeerID: peerID, senderPeerID: senderPeerID) else {
                    SecureLogger.error("NostrTransport: failed to embed READ ack", category: .session)
                    return
                }
                sendWrappedMessage(content: ack, recipientHex: recipientHex, senderIdentity: senderIdentity)

            case .deliveredDirect(let messageID, let peerID):
                guard let recipientNpub = resolveRecipientNpub(for: peerID),
                      let recipientHex = npubToHex(recipientNpub),
                      let senderIdentity = try? dependencies.currentIdentity() else { return }
                SecureLogger.debug("NostrTransport: preparing DELIVERED ack id=\(messageID.prefix(8))…", category: .session)
                guard let ack = NostrEmbeddedBitChat.encodeAckForNostr(type: .delivered, messageID: messageID, recipientPeerID: peerID, senderPeerID: senderPeerID) else {
                    SecureLogger.error("NostrTransport: failed to embed DELIVERED ack", category: .session)
                    return
                }
                sendWrappedMessage(content: ack, recipientHex: recipientHex, senderIdentity: senderIdentity)

            case .deliveredNostrIdentity(let messageID, let recipientHex, let identity):
                SecureLogger.debug("GeoDM: send DELIVERED mid=\(messageID.prefix(8))…", category: .session)
                guard let embedded = NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .delivered, messageID: messageID) else { return }
                sendWrappedMessage(content: embedded, recipientHex: recipientHex, senderIdentity: identity, registerPending: true)

            case .readNostrIdentity(let messageID, let recipientHex, let identity):
                SecureLogger.debug("GeoDM: send READ mid=\(messageID.prefix(8))…", category: .session)
                guard let embedded = NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .readReceipt, messageID: messageID) else { return }
                sendWrappedMessage(content: embedded, recipientHex: recipientHex, senderIdentity: identity, registerPending: true)
            }
        }
    }

    /// Wesh lookup by full Noise-key peer ID, or by its short form.
    private static func weshNpub(for peerID: PeerID, short: PeerID, in npubs: [PeerID: String]) -> String? {
        weshEntry(for: peerID, short: short, in: npubs)?.npub
    }

    private static func weshEntry(for peerID: PeerID, short: PeerID, in npubs: [PeerID: String]) -> (peer: PeerID, npub: String)? {
        if let npub = npubs[peerID] { return (peerID, npub) }
        return npubs.first(where: { $0.key.toShort() == short }).map { ($0.key, $0.value) }
    }

    @MainActor
    private func resolveRecipientNpub(for peerID: PeerID) -> String? {
        if let weshNpubs = queue.sync(execute: { weshNpubs }) {
            // Fail closed: nothing leaves while Internet mode is not On.
            guard queue.sync(execute: { weshIsOnline }),
                  let entry = Self.weshEntry(for: peerID, short: peerID.toShort(), in: weshNpubs),
                  let key = entry.peer.noiseKey,
                  dependencies.weshIsBlocked?(key) == false else { return nil }
            return entry.npub
        }
        if let noiseKey = Data(hexString: peerID.id),
           let fav = dependencies.favoriteStatusForNoiseKey(noiseKey),
           let npub = fav.peerNostrPublicKey {
            return npub
        }
        if peerID.id.count == 16,
           let fav = dependencies.favoriteStatusForPeerID(peerID),
           let npub = fav.peerNostrPublicKey {
            return npub
        }
        return nil
    }
}
