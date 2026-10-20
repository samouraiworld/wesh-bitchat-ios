import BitFoundation
import BitLogger
import Combine
import Foundation

struct ChatViewModelServiceBundle {
    let commandProcessor: CommandProcessor
    let messageRouter: MessageRouter
    let privateChatManager: PrivateChatManager
    let unifiedPeerService: UnifiedPeerService
    let autocompleteService: AutocompleteService
    let deduplicationService: MessageDeduplicationService
    let publicMessagePipeline: PublicMessagePipeline
    let nostrOutboundPanicBinding: NostrOutboundPanicBinding

    @MainActor
    init(
        keychain: KeychainManagerProtocol,
        idBridge: NostrIdentityBridge,
        identityManager: SecureIdentityStateManagerProtocol,
        meshService: Transport,
        outboxStore: MessageOutboxStore? = nil,
        sfMetrics: StoreAndForwardMetrics? = nil,
        nostrDependencies: NostrTransport.Dependencies? = nil
    ) {
        let commandProcessor = CommandProcessor(identityManager: identityManager)
        let privateChatManager = PrivateChatManager(meshService: meshService)
        let unifiedPeerService = UnifiedPeerService(
            meshService: meshService,
            idBridge: idBridge,
            identityManager: identityManager
        )
        let nostrTransport = NostrTransport(
            keychain: keychain, idBridge: idBridge,
            dependencies: nostrDependencies ?? .live(idBridge: idBridge, isBlocked: { identityManager.isBlocked(fingerprint: $0.sha256Fingerprint()) })
        )
        nostrTransport.senderPeerID = meshService.myPeerID
        let nostrOutboundPanicBinding = nostrTransport.captureOutboundPanicBinding()
        let messageRouter = MessageRouter(
            transports: [meshService, nostrTransport],
            outboxStore: outboxStore,
            metrics: sfMetrics
        )

        self.commandProcessor = commandProcessor
        self.messageRouter = messageRouter
        self.privateChatManager = privateChatManager
        self.unifiedPeerService = unifiedPeerService
        self.autocompleteService = AutocompleteService()
        // Persist processed gift-wrap event IDs: NIP-59 randomizes their
        // timestamps, so the 24h-lookback DM subscriptions redeliver the same
        // events on every launch and only a cross-launch record stops the
        // reprocessing (re-sent DELIVERED bursts, phantom-ack noise).
        self.deduplicationService = MessageDeduplicationService(nostrEventStore: NostrProcessedEventStore())
        self.publicMessagePipeline = PublicMessagePipeline()
        self.nostrOutboundPanicBinding = nostrOutboundPanicBinding
    }
}

@MainActor
final class ChatViewModelBootstrapper {
    private unowned let viewModel: ChatViewModel

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    static func loadPersistedReadReceipts(userDefaults: UserDefaults = .standard) -> Set<String> {
        guard let data = userDefaults.data(forKey: "sentReadReceipts"),
              let receipts = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(receipts)
    }

    func configure() {
        wireServiceGraph()
        bindFeatureObjectChanges()
        loadPersistedViewState()
        configureTransport()
        startRuntimeServices()
        bindPeerService()
        configureNoiseCallbacks()
        viewModel.messageRouter.startOutboxMaintenance()
        requestNotifications()
        registerObservers()
    }
}

private extension ChatViewModelBootstrapper {
    func wireServiceGraph() {
        viewModel.privateChatManager.conversationStore = viewModel.conversations
        viewModel.privateChatManager.messageRouter = viewModel.messageRouter
        viewModel.privateChatManager.unifiedPeerService = viewModel.unifiedPeerService
        viewModel.unifiedPeerService.messageRouter = viewModel.messageRouter
        // Surface silent outbox drops (attempt cap, TTL expiry, overflow
        // eviction) as a visible failure. The store's no-downgrade rule does
        // not cover `.failed` over confirmed receipts, so guard here: a drop
        // of an already-delivered/read message (e.g. a stale retained copy)
        // must not downgrade its status.
        viewModel.messageRouter.onMessageDropped = { [weak viewModel] messageID, peerID in
            guard let viewModel else { return }
            switch viewModel.conversations.deliveryStatus(forMessageID: messageID) {
            case .delivered, .read:
                // Field proof of the no-downgrade guard: the drop arrived
                // after a confirmed receipt, so the `.failed` write is
                // deliberately skipped.
                SecureLogger.warning(
                    "📤 Router dropped message \(messageID.prefix(8))… for \(peerID.id.prefix(8))… → .failed skipped (already delivered/read)",
                    category: .session
                )
            default:
                SecureLogger.warning(
                    "📤 Router dropped message \(messageID.prefix(8))… for \(peerID.id.prefix(8))… → marked failed",
                    category: .session
                )
                viewModel.conversations.setDeliveryStatus(
                    .failed(reason: String(localized: "content.delivery.reason.not_delivered", comment: "Failure reason shown when the router gave up delivering a message")),
                    forMessageID: messageID
                )
            }
        }
        // A message with no reachable transport that was handed to a courier
        // shows a distinct "carried" state instead of sitting in "sending"
        // forever. Never downgrade a confirmed receipt: the courier copy can
        // race direct delivery when the peer reappears.
        viewModel.messageRouter.onMessageCarried = { [weak viewModel] messageID, peerID in
            guard let viewModel else { return }
            switch viewModel.conversations.deliveryStatus(forMessageID: messageID) {
            case .delivered, .read:
                break
            default:
                SecureLogger.debug(
                    "📦 Message \(messageID.prefix(8))… for \(peerID.id.prefix(8))… handed to courier → marked carried",
                    category: .session
                )
                viewModel.conversations.setDeliveryStatus(.carried, forMessageID: messageID)
            }
        }
        viewModel.commandProcessor.contextProvider = viewModel
        viewModel.commandProcessor.meshService = viewModel.meshService
    }

    func bindFeatureObjectChanges() {
        viewModel.privateChatManager.objectWillChange
            .sink { [weak viewModel] _ in
                viewModel?.objectWillChange.send()
            }
            .store(in: &viewModel.cancellables)

        // Private message state flows through the single-writer
        // `ConversationStore` intents and its `changes` subject; selection
        // is owned by the store too (`PrivateChatManager.selectedPeer` is a
        // read-only mirror), so no selection bridge is needed here.
    }

    func loadPersistedViewState() {
        viewModel.loadNickname()
        viewModel.loadVerifiedFingerprints()
    }

    func configureTransport() {
        viewModel.meshService.delegate = viewModel
        viewModel.meshService.eventDelegate = viewModel

        DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiStartupInitialDelaySeconds) { [weak viewModel] in
            guard let viewModel else { return }
            _ = viewModel.getMyFingerprint()
        }

        viewModel.meshService.setNickname(viewModel.nickname)
    }

    func startRuntimeServices() {
        // Checked after any wipe resumed at launch, which brings the welcome back.
        if WeshWelcome.meshMayStart() { viewModel.meshService.startServices() }

        viewModel.publicMessagePipeline.delegate = viewModel.publicConversationCoordinator

        loadArchivedEchoes()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak viewModel] in
            guard let viewModel,
                  let radio = viewModel.meshService as? BluetoothStateReporting else { return }
            viewModel.updateBluetoothState(radio.getCurrentBluetoothState())
        }

        viewModel.nostrRelayManager = NostrRelayManager.shared
        viewModel.messageRouter.flushAllOutbox()

        Task { @MainActor [weak viewModel] in
            guard let viewModel else { return }
            try? await Task.sleep(
                nanoseconds: UInt64(TransportConfig.uiStartupPhaseDurationSeconds * 1_000_000_000)
            )
            viewModel.isStartupPhase = false
        }
    }

    /// Surfaces the carried store-and-forward window (up to 6h of public
    /// mesh messages, persisted across restarts) as dimmed "heard here
    /// earlier" rows, so the mesh timeline opens with the place's memory
    /// instead of a void. The archive restore runs async on the sync queue
    /// right after transport start, so give it a beat before asking.
    private func loadArchivedEchoes() {
        DispatchQueue.main.asyncAfter(deadline: .now() + TransportConfig.uiArchivedEchoLoadDelaySeconds) { [weak viewModel] in
            guard let viewModel,
                  let archive = viewModel.meshService as? MeshPublicArchiving else { return }
            archive.collectArchivedPublicMessages { [weak viewModel] allArchived in
                guard let viewModel else { return }
                // A previous /clear dismissed everything heard up to its
                // watermark; only newer archive entries come back. Blocking a
                // peer purges their carried messages from the archive at
                // block time (when the fingerprint↔peerID mapping is known);
                // the filter here is defense-in-depth for entries that slip
                // past the purge (e.g. re-synced from a nearby peer), and it
                // only resolves connected peers or favorites.
                let clearedThrough = MeshEchoSettings.clearedThrough ?? .distantPast
                let archived = allArchived.filter {
                    $0.timestamp > clearedThrough && !viewModel.isPeerBlocked($0.senderPeerID)
                }
                guard !archived.isEmpty else { return }
                // Seed only an untouched timeline: with live rows already
                // present (or after /clear) splicing history back in would
                // be wrong.
                guard viewModel.conversations.conversationsByID[.mesh]?.messages.isEmpty != false else { return }

                for item in archived {
                    let echo = BitchatMessage(
                        id: BitchatMessage.archivedEchoIDPrefix + item.packetIdHex,
                        sender: item.senderNickname,
                        content: item.content,
                        timestamp: item.timestamp,
                        isRelay: false,
                        senderPeerID: item.senderPeerID
                    )
                    viewModel.publicConversationCoordinator.registerArchivedEcho(
                        senderPeerID: item.senderPeerID,
                        timestamp: item.timestamp,
                        content: item.content
                    )
                    _ = viewModel.appendPublicMessage(echo, to: .mesh)
                }

                if let firstTimestamp = archived.map(\.timestamp).min() {
                    // Echo-prefixed ID so the divider joins the tinted,
                    // dimmed echo block in the timeline.
                    let divider = BitchatMessage(
                        id: BitchatMessage.archivedEchoIDPrefix + "divider",
                        sender: "system",
                        content: String(localized: "content.echoes.divider", comment: "System line shown above dimmed archived messages replayed on the mesh timeline at launch"),
                        timestamp: firstTimestamp.addingTimeInterval(-1),
                        isRelay: false
                    )
                    _ = viewModel.appendPublicMessage(divider, to: .mesh)
                }
            }
        }
    }

    func bindPeerService() {
        viewModel.unifiedPeerService.$peers
            .receive(on: DispatchQueue.main)
            .sink { [weak viewModel] peers in
                Task { @MainActor [weak viewModel] in
                    guard let viewModel else { return }

                    viewModel.allPeers = peers

                    var uniquePeers: [PeerID: BitchatPeer] = [:]
                    for peer in peers {
                        if uniquePeers[peer.peerID] == nil {
                            uniquePeers[peer.peerID] = peer
                        } else {
                            SecureLogger.warning(
                                "⚠️ Duplicate peer ID detected: \(peer.peerID) (\(peer.displayName))",
                                category: .session
                            )
                        }
                    }
                    viewModel.peerIndex = uniquePeers

                    if viewModel.hasTrackedPrivateChatSelection {
                        viewModel.updatePrivateChatPeerIfNeeded()
                    }
                }
            }
            .store(in: &viewModel.cancellables)
    }

    func configureNoiseCallbacks() {
        viewModel.setupNoiseCallbacks()
    }

    func requestNotifications() {
        // In Wesh the prompt waits for the end of the welcome (`AppRuntime.welcomeFinished`).
        guard !WeshMode.isActive || WeshWelcome.isDone() else { return }
        NotificationService.shared.requestAuthorization()
    }

    func registerObservers() {
        NotificationCenter.default.addObserver(
            viewModel,
            selector: #selector(ChatViewModel.handleFavoriteStatusChanged(_:)),
            name: .favoriteStatusChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            viewModel,
            selector: #selector(ChatViewModel.handlePeerStatusUpdate(_:)),
            name: Notification.Name("peerStatusUpdated"),
            object: nil
        )
    }
}
