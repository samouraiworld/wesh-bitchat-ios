import BitLogger
import BitFoundation
import Foundation

/// Trust and identity lookups the router needs to pick couriers. Backed by
/// the favorites store in production; injectable for tests.
struct CourierDirectory {
    /// Noise static key for a peer we can address while they're offline.
    var noiseKey: (PeerID) -> Data?
    /// Whether a peer (by Noise static key) is a mutual favorite — the
    /// preferred courier tier. Verified non-favorites are the fallback tier,
    /// read off the transport snapshot.
    var isTrustedCourier: (Data) -> Bool

    @MainActor
    static func favoritesBacked() -> CourierDirectory {
        CourierDirectory(
            noiseKey: { peerID in
                // Offline favorites are addressed by the full 64-hex
                // noise-key ID, which carries the key itself; the favorites
                // lookup only resolves short 16-hex IDs.
                peerID.noiseKey
                    ?? FavoritesPersistenceService.shared.getFavoriteStatus(forPeerID: peerID)?.peerNoisePublicKey
            },
            isTrustedCourier: { noiseKey in
                FavoritesPersistenceService.shared.isMutualFavorite(noiseKey)
            }
        )
    }
}

/// Routes messages using available transports (Mesh, Nostr, etc.)
@MainActor
final class MessageRouter {
    typealias QueuedMessage = MessageOutboxStore.QueuedMessage

    /// Optional application policy; upstream consumers retain their original behavior.
    /// An authorized first send returns the authenticated recipient key. Every retry must
    /// retain that key, even if a short BLE address is reused by another verified person.
    var privateSendPolicy: ((PeerID, Data?) -> Data?)?

    /// Read receipts, delivery acks and favorite markers disclose presence and
    /// reading. Under a policy they need the same admission as a private message.
    func admitsControlMessage(to peerID: PeerID) -> Bool {
        guard let privateSendPolicy else { return true }
        return privateSendPolicy(peerID, nil) != nil
    }

    private func authorized(_ message: QueuedMessage, for recipient: PeerID) -> Bool {
        guard let privateSendPolicy else { return true }
        guard let pinnedKey = message.recipientNoiseKey else { return false }
        return privateSendPolicy(recipient, pinnedKey) == pinnedKey
    }

    private struct PeerMessageKey: Hashable {
        let peerID: PeerID
        let messageID: String
    }

    private let transports: [Transport]
    private let now: () -> Date
    private let courierDirectory: CourierDirectory
    private let outboxStore: MessageOutboxStore?
    private let metrics: StoreAndForwardMetrics?

    /// Invoked whenever a retained private message is dropped without a
    /// delivery ack (attempt cap, TTL expiry, or per-peer overflow eviction)
    /// so the UI can surface the failure instead of leaving the message in a
    /// stale "sending/sent" state forever. Not invoked for a message written over a Bluetooth
    /// session (`afterBluetoothWrite`): that write stands and the message keeps « Envoyé ».
    var onMessageDropped: ((_ messageID: String, _ peerID: PeerID) -> Void)?

    /// Invoked when a message with no reachable transport was handed to at
    /// least one courier (a connected peer who will physically carry the
    /// sealed envelope). Delivery stays best-effort: the outbox retains the
    /// message until an ack arrives.
    var onMessageCarried: ((_ messageID: String, _ peerID: PeerID) -> Void)?

    /// Invoked when a relay accepted an Internet publication of a message the
    /// outbox still holds (« Envoyé »). Bluetooth sends are marked by the
    /// caller at hand-off; an Internet hand-off alone proves nothing.
    var onMessageSent: ((_ messageID: String, _ peerID: PeerID) -> Void)?

    /// Invoked as a private message is handed to a transport, with that transport's kind:
    /// the message's « Bluetooth » / « Internet » label follows its last attempt.
    var onMessageAttempted: ((_ messageID: String, _ peerID: PeerID, _ transport: MessageTransport) -> Void)?

    /// Keeps retained private messages from remaining in a stale sending state
    /// for the rest of a long session. The returned task also permits a caller
    /// to cancel maintenance when it owns a shorter router lifetime.
    @discardableResult
    func startOutboxMaintenance(
        interval: TimeInterval = 120,
        sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) -> Task<Void, Never> {
        outboxMaintenanceTask?.cancel()
        let task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await sleep(UInt64(interval * 1_000_000_000)) }
                catch { return }
                guard !Task.isCancelled, let self else { return }
                self.cleanupExpiredMessages()
            }
        }
        outboxMaintenanceTask = task
        return task
    }

    private var outboxMaintenanceTask: Task<Void, Never>?

    deinit { outboxMaintenanceTask?.cancel() }

    private var outbox: [PeerID: [QueuedMessage]] = [:]
    /// Peer/message pairs whose latest router-owned transmission used an
    /// already-established secure session and still await an ack. Peer scope
    /// is required because message IDs are not globally unique across direct
    /// conversations. This deliberately excludes messages handed to BLE while
    /// a handshake is pending: BLE owns those sends and drains its queue after
    /// authentication, so retrying them here would duplicate every normal
    /// first-handshake DM.
    private var secureTransmissions = Set<PeerMessageKey>()

    // Outbox limits to prevent unbounded memory growth
    private static let maxMessagesPerPeer = 100
    private static let messageTTLSeconds: TimeInterval = 24 * 60 * 60 // 24 hours
    // Bound actual sends that never receive an ack, whether they used weak
    // reachability or an apparently secure session that keeps being replaced.
    // Connected pre-handshake sends are transport-owned and do not burn this
    // cap because BLE queues/drains them itself.
    private static let maxSendAttempts = 8
    // Internet resends are not capped by count (see `Transport.unackedSendsAreBounded`) but
    // backed off per message: the first retry 30 s after the send, then 1, 2, 4, 8, 16 min,
    // then every 30 min until an ack or the 24h TTL. A scheduled wake drives each retry; a
    // flush (a flapping peer, a restored outbox) cannot publish earlier. Relays reconnecting or
    // Internet turning On allow one early retry per message, only once its last publication is
    // 5 min old, without moving the message down or up the ladder. Whatever the cause, a message
    // is published at most 60 times; past that it waits for the TTL, then fails.
    private static let internetFirstRetryDelay: TimeInterval = 30
    private static let internetMaxRetryDelay: TimeInterval = 30 * 60
    private static let internetMinPublishGap: TimeInterval = 5 * 60
    private static let internetMaxPublications = 60
    private struct InternetResend {
        var sends: Int
        /// Every publication, backoff steps and early retries alike (a re-wrap is one of them).
        var publications: Int
        var nextAttemptAt: Date
        var lastPublishedAt: Date
        /// The last publication was an early retry on a fresh connection.
        var lastPublishWasEarly = false
        /// Only the latest scheduled wake for the message acts; older ones are stale.
        var wakeToken: UInt64 = 0
        /// The early retry waiting for its 5 min gap, if any.
        var earlyWakeToken: UInt64?
    }
    /// By message ID, for messages still in the outbox (an erase clears it with the outbox).
    private var internetResends: [String: InternetResend] = [:]
    /// Rule 4: a Bluetooth message still without an ack this long after its last hand-off is
    /// resent over Internet once, under the same ID (receivers deduplicate), then follows the
    /// Internet backoff. Without an Internet route at that moment the Bluetooth write stands.
    private static let bluetoothAckWindow: TimeInterval = 20
    /// The wake of each message's latest Bluetooth hand-off; older wakes are stale.
    private var bluetoothAckWakes: [PeerMessageKey: UInt64] = [:]
    private var lastWakeToken: UInt64 = 0
    private let scheduleAfter: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    // Redundant couriers improve delivery odds; receivers dedup by message ID.
    private static let maxCouriersPerMessage = 3

    init(
        transports: [Transport],
        now: @escaping () -> Date = Date.init,
        courierDirectory: CourierDirectory? = nil,
        outboxStore: MessageOutboxStore? = nil,
        metrics: StoreAndForwardMetrics? = nil,
        scheduleAfter: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Task { @MainActor in action() }
            }
        }
    ) {
        self.transports = transports
        self.now = now
        self.courierDirectory = courierDirectory ?? .favoritesBacked()
        self.outboxStore = outboxStore
        self.metrics = metrics
        self.scheduleAfter = scheduleAfter
        self.outbox = outboxStore?.load() ?? [:]
        outboxStore?.setRecoveryHandler { [weak self] recovered in
            self?.mergeRecoveredOutbox(recovered)
        }
        for case let transport as RelayConfirmedTransport in transports {
            transport.onPrivateMessageAccepted = { [weak self] messageID, peerID in
                self?.internetSendAccepted(messageID, for: peerID)
            }
            transport.onInternetAvailable = { [weak self] in
                self?.internetBecameAvailable()
            }
        }

        // Observe favorites changes to learn Nostr mapping and flush queued messages
        NotificationCenter.default.addObserver(
            forName: .favoriteStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            if let data = note.userInfo?["peerPublicKey"] as? Data {
                let peerID = PeerID(publicKey: data)
                Task { @MainActor in
                    self.flushOutbox(for: peerID)
                }
            }
            // Handle key updates
            if let newKey = note.userInfo?["peerPublicKey"] as? Data,
               note.userInfo?["isKeyUpdate"] is Bool {
                let peerID = PeerID(publicKey: newKey)
                Task { @MainActor in
                    self.flushOutbox(for: peerID)
                }
            }
        }
    }

    // MARK: - Transport Selection

    private func reachableTransport(for peerID: PeerID) -> Transport? {
        transports.first { $0.isPeerReachable(peerID) }
    }

    private func connectedTransport(for peerID: PeerID) -> Transport? {
        transports.first { $0.isPeerConnected(peerID) }
    }

    // MARK: - Message Sending

    func sendPrivate(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        let pinnedKey = privateSendPolicy?(peerID, nil)
        guard privateSendPolicy == nil || pinnedKey != nil else { return }
        let message = QueuedMessage(
            content: content,
            nickname: recipientNickname,
            messageID: messageID,
            timestamp: now(),
            sendAttempts: 1,
            recipientNoiseKey: pinnedKey
        )

        if let transport = connectedTransport(for: peerID), transport.canDeliverSecurely(to: peerID) {
            // Even an established Noise session can be stale after the peer
            // restarts or replaces its app. Persist before handing the packet
            // to the transport so a fast ack cannot race ahead of retention,
            // then keep the copy until a delivery/read ack clears it. A
            // replacement handshake will retry this same message ID, which
            // receivers deduplicate.
            enqueue(message, for: peerID)
            secureTransmissions.insert(PeerMessageKey(peerID: peerID, messageID: messageID))
            SecureLogger.debug("Routing PM via \(type(of: transport)) (connected) to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            send(content, via: transport, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
            return
        }

        if let transport = connectedTransport(for: peerID) {
            // "Connected" without an established secure session is forgeable:
            // link bindings heal on signature-verified "direct" announces, but
            // directness rides on the unsigned TTL, so a replayed announce can
            // bind an absent peer's ID to the replayer's link — where the send
            // stalls on a handshake the replayer can never complete. Send now
            // (a genuine link finishes the handshake and delivers), but retain
            // a copy and hand a sealed copy to couriers so nothing is silently
            // lost; receivers dedup resends by message ID.
            //
            // Deliberate metadata tradeoff: every pre-handshake first DM to a
            // connected peer hands nearby verified peers a sealed copy, so
            // they learn a DM to this recipient exists (never its content —
            // the envelope is opaque). Accepted for delivery robustness; the
            // deposit is cleared on ack. Don't "optimize" the courier call
            // away.
            SecureLogger.debug("Routing PM via \(type(of: transport)) (connected, no secure session) to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            enqueue(message, for: peerID)
            secureTransmissions.remove(PeerMessageKey(peerID: peerID, messageID: messageID))
            send(content, via: transport, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
            attemptCourierDeposit(messageID: messageID, for: peerID)
            return
        }

        if let transport = reachableTransport(for: peerID) {
            // Reachability without a connection is a freshness heuristic (e.g.
            // the mesh retention window), so the send can silently go nowhere.
            // Send now, but retain a copy until a delivery/read ack clears it;
            // receivers dedup resends by message ID.
            SecureLogger.debug("Routing PM via \(type(of: transport)) (reachable) to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            enqueue(message, for: peerID)
            send(content, via: transport, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
            if !transport.unackedSendsAreBounded { scheduleInternetRetry(messageID, for: peerID) }
            // "Reachable" without prompt delivery means the send cannot be
            // published now (Nostr with relays down; it is retried on the
            // backoff): also hand a sealed copy to
            // any connected couriers rather than waiting for internet that
            // may never come. Double delivery is harmless — receivers dedup
            // by message ID, and delivered/read acks never downgrade.
            if !transport.canDeliverPromptly(to: peerID) {
                attemptCourierDeposit(messageID: messageID, for: peerID)
            }
        } else {
            var unsent = message
            unsent.sendAttempts = 0
            enqueue(unsent, for: peerID)
            SecureLogger.debug("Queued PM for \(peerID.id.prefix(8))… (no reachable transport) id=\(messageID.prefix(8))… queue=\(outbox[peerID]?.count ?? 0)", category: .session)
            attemptCourierDeposit(messageID: messageID, for: peerID)
        }
    }

    // MARK: - Couriers

    /// Last resort when no transport can deliver promptly — the peer is
    /// unreachable, or only reachable through a send queue waiting on
    /// internet: seal the message to their known static key and hand it to
    /// connected couriers who may physically encounter them. Mutual favorites
    /// are preferred; signature-verified strangers fill remaining slots so a
    /// crowd without favorites can still carry mail (envelopes are opaque
    /// either way). The queued copy stays retained, so direct delivery still
    /// wins if the peer reappears first (receivers dedup by message ID).
    private func attemptCourierDeposit(messageID: String, for peerID: PeerID) {
        guard let recipientKey = courierDirectory.noiseKey(peerID),
              let entry = queuedMessage(messageID, for: peerID), authorized(entry, for: peerID),
              privateSendPolicy == nil || entry.recipientNoiseKey == recipientKey else { return }
        let remainingSlots = Self.maxCouriersPerMessage - entry.depositedCourierKeys.count
        guard remainingSlots > 0 else { return }

        for transport in transports {
            guard let courierTransport = transport as? MeshCourierTransporting else { continue }
            let couriers = eligibleCouriers(
                on: transport,
                recipientKey: recipientKey,
                excluding: entry.depositedCourierKeys,
                limit: remainingSlots
            )
            guard !couriers.isEmpty else { continue }
            if courierTransport.sendCourierMessage(entry.content, messageID: messageID, recipientNoiseKey: recipientKey, via: couriers.map(\.peerID)) {
                SecureLogger.debug("📦 PM \(messageID.prefix(8))… handed to \(couriers.count) courier(s) for \(peerID.id.prefix(8))…", category: .session)
                recordCourierDeposit(messageID: messageID, for: peerID, courierKeys: couriers.map(\.noiseKey))
                onMessageCarried?(messageID, peerID)
                return
            }
        }
    }

    /// A courier candidate just connected: hand them any queued mail they are
    /// not already carrying. This is what turns couriering from "a favorite
    /// happened to be around at send time" into eventual spread — deposits
    /// retry as eligible peers appear, until each message rides with
    /// `maxCouriersPerMessage` distinct couriers or expires.
    func courierBecameAvailable(_ peerID: PeerID) {
        for transport in transports {
            guard let courierTransport = transport as? MeshCourierTransporting else { continue }
            guard transport.isPeerConnected(peerID),
                  let snapshot = transport.currentPeerSnapshots().first(where: { $0.peerID == peerID && $0.isConnected }),
                  let courierKey = snapshot.noisePublicKey,
                  courierDirectory.isTrustedCourier(courierKey) || snapshot.isVerified else { continue }

            let currentDate = now()
            for (recipient, queue) in outbox {
                // Mail *to* this peer flushes directly on connect.
                guard recipient != peerID,
                      let recipientKey = courierDirectory.noiseKey(recipient),
                      recipientKey != courierKey else { continue }
                for message in queue {
                    guard authorized(message, for: recipient), privateSendPolicy == nil || message.recipientNoiseKey == recipientKey else { continue }
                    guard message.depositedCourierKeys.count < Self.maxCouriersPerMessage,
                          !message.depositedCourierKeys.contains(courierKey),
                          currentDate.timeIntervalSince(message.timestamp) <= Self.messageTTLSeconds else { continue }
                    if courierTransport.sendCourierMessage(message.content, messageID: message.messageID, recipientNoiseKey: recipientKey, via: [peerID]) {
                        SecureLogger.debug("📦 Deposit retry: PM \(message.messageID.prefix(8))… handed to \(peerID.id.prefix(8))… for \(recipient.id.prefix(8))…", category: .session)
                        recordCourierDeposit(messageID: message.messageID, for: recipient, courierKeys: [courierKey])
                        onMessageCarried?(message.messageID, recipient)
                    }
                }
            }
            return
        }
    }

    private struct CourierCandidate {
        let peerID: PeerID
        let noiseKey: Data
    }

    private func eligibleCouriers(
        on transport: Transport,
        recipientKey: Data,
        excluding excludedKeys: Set<Data>,
        limit: Int
    ) -> [CourierCandidate] {
        guard limit > 0 else { return [] }
        let candidates = transport.currentPeerSnapshots().compactMap { snapshot -> (CourierCandidate, isFavorite: Bool)? in
            guard snapshot.isConnected,
                  let key = snapshot.noisePublicKey,
                  key != recipientKey,
                  !excludedKeys.contains(key) else { return nil }
            let isFavorite = courierDirectory.isTrustedCourier(key)
            guard isFavorite || snapshot.isVerified else { return nil }
            return (CourierCandidate(peerID: snapshot.peerID, noiseKey: key), isFavorite)
        }
        return candidates
            .sorted { $0.isFavorite && !$1.isFavorite }
            .prefix(limit)
            .map(\.0)
    }

    private func queuedMessage(_ messageID: String, for peerID: PeerID) -> QueuedMessage? {
        outbox[peerID]?.first { $0.messageID == messageID }
    }

    private func recordCourierDeposit(messageID: String, for peerID: PeerID, courierKeys: [Data]) {
        metrics?.record(.courierDeposited)
        guard var queue = outbox[peerID],
              let index = queue.firstIndex(where: { $0.messageID == messageID }) else { return }
        queue[index].depositedCourierKeys.formUnion(courierKeys)
        outbox[peerID] = queue
        persistOutbox()
    }

    // MARK: - Outbox Management

    /// A locally trusted delivery transition confirms receipt; stop retaining
    /// every copy of the message. Authenticated remote receipts must use the
    /// peer-bound overload below instead.
    func markDelivered(_ messageID: String) {
        clearRetainedMessage(messageID)
    }

    /// Stops retaining a message only for the authenticated conversation
    /// aliases that produced the accepted receipt. A peer that learns another
    /// conversation's message ID cannot use it to clear that conversation's
    /// retry state.
    func markDelivered(_ messageID: String, from peerIDs: Set<PeerID>) {
        guard !peerIDs.isEmpty else { return }
        _ = markDelivered(messageID, for: Array(peerIDs))
    }

    private func clearRetainedMessage(_ messageID: String) {
        var cleared = false
        for (peerID, queue) in outbox {
            let filtered = queue.filter { $0.messageID != messageID }
            guard filtered.count != queue.count else { continue }
            outbox[peerID] = filtered.isEmpty ? nil : filtered
            cleared = true
        }
        let matchingSecureTransmissions = secureTransmissions.filter {
            $0.messageID == messageID
        }
        secureTransmissions.subtract(matchingSecureTransmissions)
        // The durable snapshot may still be hidden by protected data. Record
        // the ack even when this cold-load view cannot find the message, then
        // persist the current view so the store retains a removal tombstone.
        outboxStore?.recordRemoval(messageID: messageID)
        if cleared {
            metrics?.record(.outboxDelivered)
        }
        persistOutbox()
    }

    /// A delivery or read ack authenticated to one account confirms receipt
    /// only for that account's transport aliases. A colliding message ID
    /// queued for another peer must remain retained.
    @discardableResult
    func markDelivered(_ messageID: String, for peerAliases: [PeerID]) -> Bool {
        let peerIDs = Set(peerAliases)
        guard !peerIDs.isEmpty else { return false }

        var cleared = false
        for peerID in peerIDs {
            guard let queue = outbox[peerID] else { continue }
            let filtered = queue.filter { $0.messageID != messageID }
            guard filtered.count != queue.count else { continue }
            outbox[peerID] = filtered.isEmpty ? nil : filtered
            cleared = true
        }
        for peerID in peerIDs {
            secureTransmissions.remove(PeerMessageKey(peerID: peerID, messageID: messageID))
        }
        // Preserve the scoped ack even when protected data hides the durable
        // queue during a cold launch.
        outboxStore?.recordRemoval(messageID: messageID, for: peerIDs)
        if cleared {
            metrics?.record(.outboxDelivered)
        }
        persistOutbox()
        return cleared
    }

    private func enqueue(_ message: QueuedMessage, for peerID: PeerID) {
        var message = message
        var queue = outbox[peerID] ?? []
        // Re-sending an already-queued ID replaces the entry (keeps attempt
        // count fresh) but must not forget which couriers already carry it,
        // or the replacement re-burns the same courier slots.
        if let existing = queue.firstIndex(where: { $0.messageID == message.messageID }) {
            message.depositedCourierKeys.formUnion(queue[existing].depositedCourierKeys)
            message.afterBluetoothWrite = message.afterBluetoothWrite || queue[existing].afterBluetoothWrite
            queue.remove(at: existing)
        }
        queue.append(message)

        // Enforce per-peer size limit with FIFO eviction
        if queue.count > Self.maxMessagesPerPeer {
            let evicted = queue.removeFirst()
            SecureLogger.warning("📤 Outbox overflow for \(peerID.id.prefix(8))… - evicted oldest message: \(evicted.messageID.prefix(8))…", category: .session)
            dropMessage(evicted, for: peerID)
        }
        outbox[peerID] = queue
        metrics?.record(.outboxQueued)
        persistOutbox()
    }

    @discardableResult
    private func removeQueuedMessage(_ messageID: String, for peerID: PeerID) -> Bool {
        guard let queue = outbox[peerID],
              let index = queue.firstIndex(where: { $0.messageID == messageID }) else {
            return false
        }
        var updated = queue
        updated.remove(at: index)
        outbox[peerID] = updated.isEmpty ? nil : updated
        return true
    }

    /// Records an Internet publication and schedules the message's next retry, unless that was
    /// its last allowed publication.
    private func scheduleInternetRetry(_ messageID: String, for peerID: PeerID) {
        let previous = internetResends[messageID]
        let sends = (previous?.sends ?? 0) + 1
        let publications = (previous?.publications ?? 0) + 1
        let delay = Self.internetRetryDelay(afterSends: sends)
        let now = now()
        internetResends[messageID] = InternetResend(
            sends: sends,
            publications: publications,
            nextAttemptAt: now.addingTimeInterval(delay),
            lastPublishedAt: now
        )
        if publications < Self.internetMaxPublications {
            armInternetRetry(messageID, for: peerID, after: delay)
        } else {
            SecureLogger.warning("📤 PM id=\(messageID.prefix(8))… reached \(publications) Internet publications; waiting for its TTL", category: .session)
        }
    }

    /// Records an early retry: the backoff stays where it was. Its next step keeps its time,
    /// only pushed to 30 s after this publication if it was due sooner (the pending wake
    /// re-arms itself if it now fires too soon).
    private func recordEarlyInternetSend(_ messageID: String) {
        guard var resend = internetResends[messageID] else { return }
        let now = now()
        resend.publications += 1
        resend.lastPublishedAt = now
        resend.lastPublishWasEarly = true
        resend.earlyWakeToken = nil
        resend.nextAttemptAt = max(resend.nextAttemptAt, now.addingTimeInterval(Self.internetFirstRetryDelay))
        internetResends[messageID] = resend
    }

    private func reachedInternetPublicationCap(_ resend: InternetResend) -> Bool {
        resend.publications >= Self.internetMaxPublications
    }

    /// Relays reconnected or Internet turned On. Each pending message gets one early retry,
    /// at once if its last publication is 5 min old, else when it is. Skipped when the backoff
    /// is due no later anyway, when one is already waiting, when the message just went out
    /// early, or when it reached its publication cap: a flapping link publishes a message at
    /// most once per 5 min.
    private func internetBecameAvailable() {
        let now = now()
        for (peerID, queue) in outbox {
            for message in queue {
                guard let resend = internetResends[message.messageID] else {
                    // Never published over Internet: an ordinary flush sends it now.
                    if transports.contains(where: { !$0.unackedSendsAreBounded && $0.isPeerReachable(peerID) }) {
                        flushOutbox(for: peerID, onlyMessageID: message.messageID)
                    }
                    continue
                }
                let gapEnd = resend.lastPublishedAt.addingTimeInterval(Self.internetMinPublishGap)
                guard !reachedInternetPublicationCap(resend),
                      resend.earlyWakeToken == nil,
                      !(resend.lastPublishWasEarly && now < gapEnd) else { continue }
                let earliest = max(now, gapEnd)
                guard earliest < resend.nextAttemptAt else { continue }
                if earliest <= now {
                    flushOutbox(for: peerID, onlyMessageID: message.messageID, earlyRetry: true)
                } else {
                    armEarlyInternetRetry(message.messageID, for: peerID, after: earliest.timeIntervalSince(now))
                }
            }
        }
    }

    private func armEarlyInternetRetry(_ messageID: String, for peerID: PeerID, after delay: TimeInterval) {
        lastWakeToken &+= 1
        let token = lastWakeToken
        internetResends[messageID]?.earlyWakeToken = token
        scheduleAfter(delay) { [weak self] in
            self?.earlyInternetRetryDue(messageID, for: peerID, token: token)
        }
    }

    private func earlyInternetRetryDue(_ messageID: String, for peerID: PeerID, token: UInt64) {
        // Acked, dropped or erased since, or a publication made it moot.
        guard let resend = internetResends[messageID], resend.earlyWakeToken == token,
              queuedMessage(messageID, for: peerID) != nil else { return }
        let remaining = resend.lastPublishedAt
            .addingTimeInterval(Self.internetMinPublishGap)
            .timeIntervalSince(now())
        guard remaining <= 0 else {
            armEarlyInternetRetry(messageID, for: peerID, after: remaining)
            return
        }
        internetResends[messageID]?.earlyWakeToken = nil
        flushOutbox(for: peerID, onlyMessageID: messageID, earlyRetry: true)
    }

    /// 30 s after the first send, doubling after each later one, capped at 30 min.
    private static func internetRetryDelay(afterSends sends: Int) -> TimeInterval {
        let doublings = Double(min(max(sends - 1, 0), 16))
        return min(internetFirstRetryDelay * pow(2, doublings), internetMaxRetryDelay)
    }

    private func armInternetRetry(_ messageID: String, for peerID: PeerID, after delay: TimeInterval) {
        lastWakeToken &+= 1
        let token = lastWakeToken
        internetResends[messageID]?.wakeToken = token
        scheduleAfter(delay) { [weak self] in
            self?.internetRetryDue(messageID, for: peerID, token: token)
        }
    }

    private func internetRetryDue(_ messageID: String, for peerID: PeerID, token: UInt64) {
        // Acked, dropped or erased since, superseded by a later send's wake, or capped since.
        guard let resend = internetResends[messageID], resend.wakeToken == token,
              !reachedInternetPublicationCap(resend),
              queuedMessage(messageID, for: peerID) != nil else { return }
        let remaining = resend.nextAttemptAt.timeIntervalSince(now())
        guard remaining <= 0 else {
            // Woke before the wall clock reached the deadline: wait the rest.
            armInternetRetry(messageID, for: peerID, after: remaining)
            return
        }
        flushOutbox(for: peerID, onlyMessageID: messageID)
        // Not published (Internet off, or it went over Bluetooth): look again after the same
        // delay, so retries never depend on some other flush happening.
        if let unsent = internetResends[messageID], unsent.wakeToken == token,
           queuedMessage(messageID, for: peerID) != nil {
            armInternetRetry(messageID, for: peerID, after: Self.internetRetryDelay(afterSends: unsent.sends))
        }
    }

    /// A relay accepted a publication. A late `OK` for a message already acked, dropped or
    /// erased changes nothing.
    private func internetSendAccepted(_ messageID: String, for peerID: PeerID) {
        guard queuedMessage(messageID, for: peerID) != nil else { return }
        onMessageSent?(messageID, peerID)
    }

    /// Internet retry state and the transports' per-message state (signed gift wraps) only
    /// live as long as the message is in the outbox: ack, drop, TTL or erase forgets them.
    private func forgetInternetStateOutsideOutbox() {
        let relayConfirmed = transports.compactMap { $0 as? RelayConfirmedTransport }
        guard !internetResends.isEmpty || !relayConfirmed.isEmpty else { return }
        let queued = Set(outbox.values.flatMap { $0.map(\.messageID) })
        internetResends = internetResends.filter { queued.contains($0.key) }
        relayConfirmed.forEach { $0.retainPendingPrivateMessages(queued) }
    }

    @discardableResult
    private func incrementSendAttemptsIfQueued(_ messageID: String, for peerID: PeerID) -> Bool {
        guard var queue = outbox[peerID],
              let index = queue.firstIndex(where: { $0.messageID == messageID }) else {
            // A synchronous delivery/read ack may have cleared the retained
            // copy while `sendPrivateMessage` was on the stack. Never
            // resurrect it from the flush snapshot.
            return false
        }
        queue[index].sendAttempts += 1
        outbox[peerID] = queue
        return true
    }

    private func dropMessage(_ message: QueuedMessage, for peerID: PeerID) {
        secureTransmissions.remove(PeerMessageKey(peerID: peerID, messageID: message.messageID))
        metrics?.record(.outboxDropped)
        // Its Bluetooth write stands (lead decision 22/10): it keeps « Envoyé ».
        if message.afterBluetoothWrite {
            SecureLogger.debug("📤 Dropped unacked PM id=\(message.messageID.prefix(8))… after its Bluetooth write; no failure shown", category: .session)
            return
        }
        onMessageDropped?(message.messageID, peerID)
    }

    private func persistOutbox() {
        outboxStore?.save(outbox)
        forgetInternetStateOutsideOutbox()
    }

    /// A cold BLE restoration can launch before protected files are readable.
    /// The store initially returns an empty snapshot in that case, then calls
    /// back after first unlock. Merge by message ID instead of replacing work
    /// accepted during the locked wake, persist the union, and immediately
    /// resume normal delivery attempts.
    private func mergeRecoveredOutbox(_ recovered: MessageOutboxStore.Snapshot) {
        for (peerID, recoveredQueue) in recovered {
            var queue = outbox[peerID] ?? []
            for var recoveredMessage in recoveredQueue {
                if let index = queue.firstIndex(where: { $0.messageID == recoveredMessage.messageID }) {
                    recoveredMessage.sendAttempts = max(recoveredMessage.sendAttempts, queue[index].sendAttempts)
                    recoveredMessage.depositedCourierKeys.formUnion(queue[index].depositedCourierKeys)
                    recoveredMessage.afterBluetoothWrite = recoveredMessage.afterBluetoothWrite || queue[index].afterBluetoothWrite
                    queue[index] = recoveredMessage
                } else {
                    queue.append(recoveredMessage)
                }
            }
            queue.sort { $0.timestamp < $1.timestamp }
            if queue.count > Self.maxMessagesPerPeer {
                let overflow = queue.count - Self.maxMessagesPerPeer
                for dropped in queue.prefix(overflow) {
                    dropMessage(dropped, for: peerID)
                }
                queue.removeFirst(overflow)
            }
            outbox[peerID] = queue
        }
        persistOutbox()
        flushAllOutbox()
    }

    /// Panic wipe: forget queued mail on disk and in memory.
    @discardableResult
    func wipeOutbox() -> Bool {
        outbox.removeAll()
        secureTransmissions.removeAll()
        internetResends.removeAll()
        bluetoothAckWakes.removeAll()
        forgetInternetStateOutsideOutbox()
        return outboxStore?.wipe() ?? true
    }

    /// Returns true only when the receipt was handed to a reachable transport.
    /// A false result means it was dropped (no route) and must NOT be recorded
    /// as sent, or the sender's message would stay unread forever — the receipt
    /// is retried on the next read scan (chat open / foreground / reconnect).
    @discardableResult
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) -> Bool {
        // A media placeholder stands for a file never received: it is never
        // reported read. Done, so nothing retries it.
        if UnsupportedPrivateMedia.isPlaceholderID(receipt.originalMessageID) { return true }
        // Denied receipts stay unsent, like an unroutable one.
        guard admitsControlMessage(to: peerID) else { return false }
        if let transport = reachableTransport(for: peerID) {
            SecureLogger.debug("Routing READ ack via \(type(of: transport)) to \(peerID.id.prefix(8))… id=\(receipt.originalMessageID.prefix(8))…", category: .session)
            transport.sendReadReceipt(receipt, to: peerID)
            return true
        } else if !transports.isEmpty {
            SecureLogger.debug("No reachable transport for READ ack to \(peerID.id.prefix(8))… — leaving unsent for retry", category: .session)
        }
        return false
    }

    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        guard admitsControlMessage(to: peerID) else { return }
        if let transport = connectedTransport(for: peerID) {
            transport.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
        } else if let transport = reachableTransport(for: peerID) {
            transport.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
        }
    }

    /// Retries only messages that the router previously transmitted through
    /// an already-established secure session and that still await an ack.
    ///
    /// A peer restart can leave that local session looking usable until the
    /// replacement handshake arrives; the first ciphertext is then
    /// undecryptable remotely. Normal pre-handshake sends are intentionally
    /// absent from `secureTransmissions` because BLE already queues
    /// and drains them when authentication completes.
    func retrySecurePrivateMessagesAfterAuthentication(for peerIDAliases: [PeerID]) {
        typealias Candidate = (
            peerID: PeerID,
            message: QueuedMessage,
            aliasOrder: Int,
            queueOrder: Int
        )

        var visitedPeerIDs = Set<PeerID>()
        var retriedMessageIDs = Set<String>()
        var outboxChanged = false
        let currentDate = now()
        var candidates: [Candidate] = []

        for (aliasOrder, peerID) in peerIDAliases.enumerated() {
            guard visitedPeerIDs.insert(peerID).inserted else { continue }
            guard let queued = outbox[peerID], !queued.isEmpty,
                  let transport = connectedTransport(for: peerID),
                  transport.canDeliverSecurely(to: peerID) else {
                continue
            }

            for (queueOrder, message) in queued.enumerated() {
                let key = PeerMessageKey(peerID: peerID, messageID: message.messageID)
                guard secureTransmissions.contains(key) else { continue }
                candidates.append((
                    peerID: peerID,
                    message: message,
                    aliasOrder: aliasOrder,
                    queueOrder: queueOrder
                ))
            }
        }

        // Conversation migration can leave retained messages split across the
        // ephemeral and stable outbox keys. Merge both queues into one
        // chronological stream so callback alias order cannot send newer mail
        // ahead of older mail.
        candidates.sort { lhs, rhs in
            if lhs.message.timestamp != rhs.message.timestamp {
                return lhs.message.timestamp < rhs.message.timestamp
            }
            if lhs.aliasOrder != rhs.aliasOrder {
                return lhs.aliasOrder < rhs.aliasOrder
            }
            if lhs.queueOrder != rhs.queueOrder {
                return lhs.queueOrder < rhs.queueOrder
            }
            return lhs.message.messageID < rhs.message.messageID
        }

        for candidate in candidates {
            let peerID = candidate.peerID
            let message = candidate.message
            guard authorized(message, for: peerID) else { continue }
            let key = PeerMessageKey(peerID: peerID, messageID: message.messageID)
            guard retriedMessageIDs.insert(message.messageID).inserted,
                  secureTransmissions.contains(key),
                  queuedMessage(message.messageID, for: peerID) != nil,
                  let transport = connectedTransport(for: peerID),
                  transport.canDeliverSecurely(to: peerID) else {
                continue
            }

            if currentDate.timeIntervalSince(message.timestamp) > Self.messageTTLSeconds {
                if removeQueuedMessage(message.messageID, for: peerID) {
                    dropMessage(message, for: peerID)
                    outboxChanged = true
                }
                continue
            }

            guard message.sendAttempts < Self.maxSendAttempts else {
                SecureLogger.warning(
                    "📤 Dropping unacked PM for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))… after \(message.sendAttempts) secure attempts",
                    category: .session
                )
                if removeQueuedMessage(message.messageID, for: peerID) {
                    dropMessage(message, for: peerID)
                    outboxChanged = true
                }
                continue
            }

            SecureLogger.debug(
                "Auth retry -> \(type(of: transport)) for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))…",
                category: .session
            )
            send(
                message.content,
                via: transport,
                to: peerID,
                recipientNickname: message.nickname,
                messageID: message.messageID
            )
            metrics?.record(.outboxResent)
            outboxChanged = incrementSendAttemptsIfQueued(message.messageID, for: peerID) || outboxChanged
        }

        if outboxChanged {
            persistOutbox()
        }
    }

    /// Every private send goes through here so the label follows the last attempt. Reported
    /// before the hand-off: a synchronous ack then has the last word.
    private func send(
        _ content: String,
        via transport: Transport,
        to peerID: PeerID,
        recipientNickname: String,
        messageID: String
    ) {
        onMessageAttempted?(messageID, peerID, transport.messageTransport)
        transport.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
        if transport.messageTransport == .bluetooth, queuedMessage(messageID, for: peerID) != nil {
            armBluetoothAckWindow(messageID, for: peerID)
        }
    }

    private func armBluetoothAckWindow(_ messageID: String, for peerID: PeerID) {
        lastWakeToken &+= 1
        let token = lastWakeToken
        let key = PeerMessageKey(peerID: peerID, messageID: messageID)
        bluetoothAckWakes[key] = token
        scheduleAfter(Self.bluetoothAckWindow) { [weak self] in
            self?.bluetoothAckWindowEnded(key, token: token)
        }
    }

    private func bluetoothAckWindowEnded(_ key: PeerMessageKey, token: UInt64) {
        guard bluetoothAckWakes[key] == token else { return }
        bluetoothAckWakes[key] = nil
        let peerID = key.peerID
        // Acked, dropped or erased since.
        guard let message = queuedMessage(key.messageID, for: peerID) else { return }
        // Sent over an established session: the Bluetooth write stands, whatever follows.
        if secureTransmissions.contains(key), !message.afterBluetoothWrite,
           var queue = outbox[peerID], let index = queue.firstIndex(where: { $0.messageID == key.messageID }) {
            queue[index].afterBluetoothWrite = true
            outbox[peerID] = queue
            persistOutbox()
        }
        // No longer admitted (never over Internet then); past its TTL; or already on the
        // Internet backoff, which retries it on its own.
        guard authorized(message, for: peerID),
              internetResends[key.messageID] == nil,
              now().timeIntervalSince(message.timestamp) <= Self.messageTTLSeconds,
              let internet = transports.first(where: { $0.messageTransport == .internet && $0.isPeerReachable(peerID) })
        else { return }
        SecureLogger.debug("Bluetooth ack window ended -> \(type(of: internet)) for \(peerID.id.prefix(8))… id=\(key.messageID.prefix(8))…", category: .session)
        send(message.content, via: internet, to: peerID, recipientNickname: message.nickname, messageID: key.messageID)
        metrics?.record(.outboxResent)
        if queuedMessage(key.messageID, for: peerID) != nil {
            scheduleInternetRetry(key.messageID, for: peerID)
        }
    }

    func flushOutbox(for peerID: PeerID) {
        flushOutbox(for: peerID, onlyMessageID: nil)
    }

    /// `onlyMessageID`: a scheduled Internet retry resends its own message, not the whole queue.
    /// `earlyRetry`: an Internet resend may go before its backoff step, 5 min after the last one.
    private func flushOutbox(for peerID: PeerID, onlyMessageID: String?, earlyRetry: Bool = false) {
        guard let queued = outbox[peerID], !queued.isEmpty else { return }
        SecureLogger.debug("Flushing outbox for \(peerID.id.prefix(8))… count=\(queued.count)", category: .session)

        let now = now()
        var outboxChanged = false

        for message in queued {
            if let onlyMessageID, message.messageID != onlyMessageID { continue }
            guard authorized(message, for: peerID) else { continue }
            // A synchronous ack from an earlier send in this flush may have
            // removed an entry from the live outbox. The snapshot is only an
            // iteration order; never use it to recreate removed messages.
            guard queuedMessage(message.messageID, for: peerID) != nil else { continue }

            // Skip expired messages (TTL exceeded)
            if now.timeIntervalSince(message.timestamp) > Self.messageTTLSeconds {
                SecureLogger.debug("⏰ Expired queued message for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))… (age: \(Int(now.timeIntervalSince(message.timestamp)))s)", category: .session)
                if removeQueuedMessage(message.messageID, for: peerID) {
                    dropMessage(message, for: peerID)
                    outboxChanged = true
                }
                continue
            }

            if let transport = connectedTransport(for: peerID), transport.canDeliverSecurely(to: peerID) {
                // A secure session is meaningful enough to retry, but not
                // proof that this particular ciphertext reached the peer: the
                // remote app may have restarted while our old session still
                // looked established. Retain until an ack, while bounding
                // actual secure transmissions for peers that never ack.
                guard message.sendAttempts < Self.maxSendAttempts else {
                    SecureLogger.warning("📤 Dropping unacked PM for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))… after \(message.sendAttempts) attempts", category: .session)
                    if removeQueuedMessage(message.messageID, for: peerID) {
                        dropMessage(message, for: peerID)
                        outboxChanged = true
                    }
                    continue
                }
                SecureLogger.debug("Outbox -> \(type(of: transport)) (connected) for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))…", category: .session)
                secureTransmissions.insert(
                    PeerMessageKey(peerID: peerID, messageID: message.messageID)
                )
                send(message.content, via: transport, to: peerID, recipientNickname: message.nickname, messageID: message.messageID)
                metrics?.record(.outboxResent)
                outboxChanged = incrementSendAttemptsIfQueued(message.messageID, for: peerID) || outboxChanged
            } else if let transport = connectedTransport(for: peerID) {
                // "Connected" without a secure session — possibly a stolen
                // binding from a replayed announce: send (a genuine link
                // finishes the handshake and delivers) but keep retaining
                // until an ack clears it. These flushes do NOT count toward
                // the attempt-cap drop: the message was transmitted over a
                // live link, so a peer whose handshake stalls across
                // reconnect flapping must not burn through the cap and lose
                // the store-and-forward copy this retention exists to
                // preserve. Retention stays bounded by the 24h outbox TTL
                // and the per-peer FIFO cap.
                SecureLogger.debug("Outbox -> \(type(of: transport)) (connected, no secure session) for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))…", category: .session)
                secureTransmissions.remove(
                    PeerMessageKey(peerID: peerID, messageID: message.messageID)
                )
                send(message.content, via: transport, to: peerID, recipientNickname: message.nickname, messageID: message.messageID)
                metrics?.record(.outboxResent)
            } else if let transport = reachableTransport(for: peerID) {
                // Reachability without a connection is a freshness heuristic,
                // so the send can silently go nowhere: send but keep retaining
                // until an ack clears it, bounded by attempt count for peers
                // that never ack (Internet: by the 24h TTL only, see
                // `Transport.unackedSendsAreBounded`).
                guard !transport.unackedSendsAreBounded || message.sendAttempts < Self.maxSendAttempts else {
                    SecureLogger.warning("📤 Dropping unacked PM for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))… after \(message.sendAttempts) attempts", category: .session)
                    if removeQueuedMessage(message.messageID, for: peerID) {
                        dropMessage(message, for: peerID)
                        outboxChanged = true
                    }
                    continue
                }
                if !transport.unackedSendsAreBounded,
                   let resend = internetResends[message.messageID] {
                    // Past the cap the message only waits for its TTL.
                    if reachedInternetPublicationCap(resend) { continue }
                    let notBefore = earlyRetry
                        ? resend.lastPublishedAt.addingTimeInterval(Self.internetMinPublishGap)
                        : resend.nextAttemptAt
                    if now < notBefore { continue }
                }
                SecureLogger.debug("Outbox -> \(type(of: transport)) (reachable) for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))…", category: .session)
                send(message.content, via: transport, to: peerID, recipientNickname: message.nickname, messageID: message.messageID)
                metrics?.record(.outboxResent)
                if transport.unackedSendsAreBounded {
                    outboxChanged = incrementSendAttemptsIfQueued(message.messageID, for: peerID) || outboxChanged
                } else if queuedMessage(message.messageID, for: peerID) != nil {
                    if earlyRetry && internetResends[message.messageID] != nil {
                        recordEarlyInternetSend(message.messageID)
                    } else {
                        scheduleInternetRetry(message.messageID, for: peerID)
                    }
                }
            }
        }

        if outboxChanged {
            persistOutbox()
        }
    }

    func flushAllOutbox() {
        for key in Array(outbox.keys) { flushOutbox(for: key) }
    }

    /// Periodically clean up expired messages from all outboxes
    func cleanupExpiredMessages() {
        let now = now()
        var droppedAny = false
        for peerID in Array(outbox.keys) {
            var expiredMessages: [QueuedMessage] = []
            outbox[peerID]?.removeAll { message in
                guard now.timeIntervalSince(message.timestamp) > Self.messageTTLSeconds else { return false }
                expiredMessages.append(message)
                return true
            }
            if outbox[peerID]?.isEmpty == true {
                outbox.removeValue(forKey: peerID)
            }
            for message in expiredMessages {
                SecureLogger.debug("⏰ Expired queued message for \(peerID.id.prefix(8))… id=\(message.messageID.prefix(8))…", category: .session)
                dropMessage(message, for: peerID)
                droppedAny = true
            }
        }
        if droppedAny {
            persistOutbox()
        }
    }
}
