//
// ChatViewModel.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

///
/// # ChatViewModel
///
/// The central business logic and state management component for BitChat.
/// Coordinates between the UI layer and the networking/encryption services.
///
/// ## Overview
/// ChatViewModel implements the MVVM pattern, serving as the binding layer between
/// SwiftUI views and the underlying BitChat services. It manages:
/// - Message state and delivery
/// - Peer connections and presence
/// - Private chat sessions
/// - Command processing
/// - UI state like autocomplete and notifications
///
/// ## Architecture
/// The ViewModel acts as:
/// - **BitchatDelegate**: Receives messages and events from BLEService
/// - **State Manager**: Maintains all UI-relevant state with @Published properties
/// - **Command Processor**: Handles IRC-style commands (/msg, /who, etc.)
/// - **Message Router**: Directs messages to appropriate chats (public/private)
///
/// ## Key Features
///
/// ### Message Management
/// - Efficient message handling with duplicate detection
/// - Maintains separate public and private message queues
/// - Limits message history to prevent memory issues (1337 messages)
/// - Tracks delivery and read receipts
///
/// ### Privacy Features
/// - Ephemeral by design - no persistent message storage
/// - Supports verified fingerprints for secure communication
/// - Blocks messages from blocked users
/// - Emergency wipe capability (triple-tap)
///
/// ### User Experience
/// - Smart autocomplete for mentions and commands
/// - Unread message indicators
/// - Connection status tracking
/// - Favorite peers management
///
/// ## Command System
/// Supports IRC-style commands:
/// - `/nick <name>`: Change nickname
/// - `/msg <user> <message>`: Send private message
/// - `/who`: List connected peers
/// - `/slap <user>`: Fun interaction
/// - `/clear`: Clear message history
/// - `/help`: Show available commands
///
/// ## Performance Optimizations
/// - SwiftUI automatically optimizes UI updates
/// - Caches expensive computations (encryption status)
/// - Debounces autocomplete suggestions
/// - Efficient peer list management
///
/// ## Thread Safety
/// - All @Published properties trigger UI updates on main thread
/// - Background operations use proper queue management
/// - Atomic operations for critical state updates
///
/// ## Usage Example
/// ```swift
/// let viewModel = ChatViewModel()
/// viewModel.nickname = "Alice"
/// viewModel.startServices()
/// viewModel.sendMessage("Hello, mesh network!")
/// ```
///

import BitLogger
import BitFoundation
import Foundation
import SwiftUI
import Combine
import CommonCrypto
import CoreBluetooth
#if os(iOS)
import UIKit
#endif
import UniformTypeIdentifiers

struct PanicNetworkLifecycle {
    /// Returns false when network state survived (e.g. the Arti directory),
    /// so the panic transaction does not commit.
    let stop: @MainActor () -> Bool
    let restart: @MainActor () -> Void
    let closeInstalledNostrRoots: @MainActor (NostrOutboundPanicBinding) -> NostrOutboundOwner.RootCloseOutcome

    static let noop = PanicNetworkLifecycle(
        stop: { true }, restart: {},
        closeInstalledNostrRoots: { _ in .unconfirmed(.participantMissing) }
    )

    static var live: PanicNetworkLifecycle {
        PanicNetworkLifecycle(
            stop: {
                NetworkActivationService.shared.stopForPanic()
                return WeshMode.isActive ? WeshInternetMode.shared.wipeForPanic() : true
            },
            restart: {
                NetworkActivationService.shared.start()
            },
            closeInstalledNostrRoots: { binding in closeCapturedNostrOutboundRootsAndRequestSourceDetachment(binding) }
        )
    }
}

/// Manages the application state and business logic for BitChat.
/// Acts as the primary coordinator between UI components and backend services,
/// implementing the BitchatDelegate protocol to handle network events.
final class ChatViewModel: ObservableObject, BitchatDelegate, SynchronousMessageTransportEventDelegate, CommandContextProvider, MessageFormattingContext {
    // Use MessageFormattingEngine.Patterns for regex matching (shared, precompiled)
    typealias Patterns = MessageFormattingEngine.Patterns

    var publicRateLimiter = MessageRateLimiter(
        senderCapacity: TransportConfig.uiSenderRateBucketCapacity,
        senderRefillPerSec: TransportConfig.uiSenderRateBucketRefillPerSec,
        contentCapacity: TransportConfig.uiContentRateBucketCapacity,
        contentRefillPerSec: TransportConfig.uiContentRateBucketRefillPerSec
    )

    // MARK: - Published Properties

    /// Read-only derived view of the ACTIVE public channel's conversation in
    /// the single-writer `ConversationStore`. SwiftUI renders through
    /// `PublicChatModel` (which observes the `Conversation` object directly);
    /// this view serves the coordinators/commands that need "the visible
    /// timeline" plus tests. Hot enough that the array is cached and
    /// invalidated from the store's `changes` subject (filtered to the
    /// active conversation) and on channel switches. `objectWillChange`
    /// fires on every store change via the sink in `init`.
    @MainActor
    var messages: [BitchatMessage] {
        if let cached = visibleMessagesCache { return cached }
        // Read-only lookup (never creates the conversation): this getter
        // runs during SwiftUI renders, where mutating the store's
        // `@Published` collections would publish mid-view-update.
        let current = conversations.conversationsByID[ConversationID(channelID: activeChannel)]?.messages ?? []
        visibleMessagesCache = current
        return current
    }
    private var visibleMessagesCache: [BitchatMessage]?
    @Published var currentColorScheme: ColorScheme = .light
    @Published var currentTheme: AppTheme = .matrix
    @Published var isConnected = false
    @Published private(set) var panicRecoveryBlocked = false
    @Published private(set) var startupRetirementBlocked = false
    @Published private(set) var weshPanicGeneration: UInt64 = 0
    /// An unconfirmed erase keeps Bluetooth and Internet off until a wipe is
    /// confirmed, at the latest when the next launch replays it.
    @Published private(set) var panicNetworkFenced = false
    var networkActivationAllowed: Bool { !panicRecoveryBlocked && !panicNetworkFenced }
    @Published var nickname: String = "" {
        didSet {
            // Canonicalize whenever nickname is set: trim whitespace
            // (whitespace-only becomes "") and apply Unicode NFC so accented
            // names match regardless of how they were typed.
            let cleaned = (nickname.trimmedOrNilIfEmpty ?? "").normalizedNickname
            if cleaned != nickname {
                nickname = cleaned
                return
            }
            // Update mesh service nickname if it's initialized
            if !isPanicResetting, !meshService.myPeerID.isEmpty {
                meshService.setNickname(nickname)
            }
        }
    }

    // MARK: - Service Delegates

    let commandProcessor: CommandProcessor
    let messageRouter: MessageRouter
    let privateChatManager: PrivateChatManager
    let unifiedPeerService: UnifiedPeerService
    let autocompleteService: AutocompleteService
    let deduplicationService: MessageDeduplicationService  // internal for test access
    private lazy var outgoingCoordinator = ChatOutgoingCoordinator(context: self)
    private lazy var lifecycleCoordinator = ChatLifecycleCoordinator(context: self)
    private lazy var transportEventCoordinator = ChatTransportEventCoordinator(context: self)
    private lazy var peerListCoordinator = ChatPeerListCoordinator(context: self)
    private lazy var messageFormatter = ChatMessageFormatter(viewModel: self)
    lazy var peerIdentityCoordinator = ChatPeerIdentityCoordinator(context: self)
    lazy var deliveryCoordinator = ChatDeliveryCoordinator(context: self)
    lazy var composerCoordinator = ChatComposerCoordinator(context: self)
    lazy var publicConversationCoordinator = ChatPublicConversationCoordinator(context: self)
    lazy var privateConversationCoordinator = ChatPrivateConversationCoordinator(context: self)
    lazy var nostrCoordinator = ChatNostrCoordinator(context: self)
    let weshPrivatePolicyEnabled: Bool
    /// Wesh Internet mode is On (Tor ready, a pinned relay connected). Injectable for tests.
    var weshInternetIsOn: @MainActor () -> Bool = { WeshInternetMode.shared.state == .on }
    /// Noise key hex + npub pairs already sent `[FAVORITED]:npub` in this process.
    var weshAnnouncedInternetKeys: Set<String> = []
    lazy var verificationCoordinator = ChatVerificationCoordinator(context: self, weshMode: weshPrivatePolicyEnabled)
    lazy var vouchCoordinator = ChatVouchCoordinator(context: self)

    // Computed properties for compatibility
    @MainActor
    var connectedPeers: Set<PeerID> { unifiedPeerService.connectedPeerIDs }
    @Published var allPeers: [BitchatPeer] = []

    /// Read-only derived view of all direct conversations in the
    /// `ConversationStore`, keyed by routing peer ID. Serves the coordinator
    /// reads that genuinely need the whole dictionary (migration scans,
    /// unread resolution); simple per-peer reads go through
    /// `privateMessages(for:)` instead. All mutations go through the
    /// private-chat intent ops below. Rebuilt per access —
    /// O(#conversations) thanks to COW message arrays; measured equal to a
    /// change-invalidated cache on `pipeline.privateIngest`, so the simpler
    /// form wins.
    @MainActor
    var privateChats: [PeerID: [BitchatMessage]] {
        conversations.directMessagesByRoutingPeerID()
    }
    @MainActor
    var selectedPrivateChatPeer: PeerID? {
        get { privateChatManager.selectedPeer }
        set {
            if let peerID = newValue {
                privateChatManager.startChat(with: peerID)
            } else {
                privateChatManager.endChat()
            }
        }
    }
    /// Read-only derived view of the store's unread direct conversations.
    /// Mutate via `markPrivateChatUnread(_:)` / `markPrivateChatRead(_:)`.
    @MainActor
    var unreadPrivateMessages: Set<PeerID> {
        conversations.unreadDirectRoutingPeerIDs()
    }

    /// Open the most relevant private chat when tapping the toolbar unread icon.
    /// Prefers the most recently active unread conversation, otherwise the most recent PM.
    @MainActor
    func openMostRelevantPrivateChat() {
        peerIdentityCoordinator.openMostRelevantPrivateChat()
    }

    //
    var peerIDToPublicKeyFingerprint: [PeerID: String] {
        get { peerIdentityStore.peerFingerprintsByPeerID }
        set { peerIdentityStore.replaceFingerprintMappings(newValue) }
    }
    var selectedPrivateChatFingerprint: String? {
        get { peerIdentityStore.selectedPrivateChatFingerprint }
        set { peerIdentityStore.setSelectedPrivateChatFingerprint(newValue) }
    }

    // Resolve short mesh ID (16-hex) from a full Noise public key hex (64-hex)
    @MainActor
    func getShortIDForNoiseKey(_ fullNoiseKeyHex: PeerID) -> PeerID {
        guard fullNoiseKeyHex.id.count == 64 else { return fullNoiseKeyHex }
        // Check known peers for a noise key match
        if let match = allPeers.first(where: { PeerID(hexData: $0.noisePublicKey) == fullNoiseKeyHex }) {
            return match.peerID
        }
        // Also search cache mapping
        if let shortPeerID = peerIdentityStore.shortPeerID(forStablePeerID: fullNoiseKeyHex) {
            return shortPeerID
        }
        return fullNoiseKeyHex
    }

    @MainActor
    func cacheStablePeerID(_ stablePeerID: PeerID, for shortPeerID: PeerID) {
        peerIdentityStore.setStablePeerID(stablePeerID, forShortID: shortPeerID)
    }

    @MainActor
    func cachedStablePeerID(for shortPeerID: PeerID) -> PeerID? {
        peerIdentityStore.stablePeerID(forShortID: shortPeerID)
    }

    var hasTrackedPrivateChatSelection: Bool {
        selectedPrivateChatFingerprint != nil
    }

    var peerIndex: [PeerID: BitchatPeer] = [:]

    // MARK: - Autocomplete Properties

    @Published var autocompleteSuggestions: [String] = []
    @Published var showAutocomplete: Bool = false
    @Published var autocompleteRange: NSRange? = nil
    @Published var selectedAutocompleteIndex: Int = 0

    // MARK: - Services and Storage

    let meshService: Transport
    let idBridge: NostrIdentityBridge
    let identityManager: SecureIdentityStateManagerProtocol
    /// Single source of truth for conversation message state and selection
    /// (docs/CONVERSATION-STORE-DESIGN.md). Owned by `AppRuntime` and passed
    /// through.
    let conversations: ConversationStore
    let peerIdentityStore: PeerIdentityStore

    var nostrRelayManager: NostrRelayManager?
    private let userDefaults = UserDefaults.standard
    let keychain: KeychainManagerProtocol
    private let panicRecoveryOperations: PanicRecoveryOperations
    private let panicNetworkLifecycle: PanicNetworkLifecycle
    private let nostrOutboundPanicBinding: NostrOutboundPanicBinding
    private let panicPersistentStoreWipes: PanicPersistentStoreWipes
    let weshMeetingNote: WeshMeetingNoteStore
    private var isPanicResetting = false
    private(set) var bootstrapConfigured = false
    private var nicknameStore: LocalNicknameStore {
        LocalNicknameStore(keychain: keychain, defaults: userDefaults)
    }
    private var provisionalNickname: String?
    #if os(iOS)
    private var nicknameProtectedDataObserver: AnyCancellable?
    #endif
    // Historical channel values remain decodable; the live UI selects mesh.
    var activeChannel: ChannelID {
        get { conversations.activeChannel }
        set {
            guard conversations.activeChannel != newValue else { return }
            conversations.setActiveChannel(newValue)
            visibleMessagesCache = nil
            objectWillChange.send()
        }
    }
    // Show Tor status once per app launch
    // Track whether a Tor restart is pending so we only announce
    // "tor restarted" after an actual restart, not the first launch.
    // Announce a stalled bootstrap once per attempt, not once per poll.
    // Live "tor is blocked" state for the connectivity banner. The system
    // message above only reaches geohash timelines; this is the chrome-level
    // signal that stays up until tor actually gets through.
    @Published var torBlocked: Bool = false
    // Ensure we set up DM subscription only once per app session
    var nostrHandlersSetup: Bool = false

    // MARK: - Caches

    // MARK: - Social Features (Delegated to PeerStateManager)

    @MainActor
    var blockedUsers: Set<String> { unifiedPeerService.blockedUsers }

    // MARK: - Encryption and Security

    var verifiedFingerprints: Set<String> {
        get { peerIdentityStore.verifiedFingerprints }
        set { peerIdentityStore.setVerifiedFingerprints(newValue) }
    }  // Set of verified fingerprints

    // Bluetooth state management
    @Published var showBluetoothAlert = false
    @Published var bluetoothAlertMessage = ""
    @Published var bluetoothState: CBManagerState = .unknown
    @Published private(set) var noiseIdentityAvailability: NoiseIdentityAvailability = .available
    @Published private(set) var isRecoveringNoiseIdentity = false
    @Published private(set) var noiseIdentityRetryFailed = false

    private func performDeliveryUpdate(_ update: @escaping @MainActor (ChatDeliveryCoordinator) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                update(deliveryCoordinator)
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            update(self.deliveryCoordinator)
        }
    }
    // MARK: - Message Delivery Tracking

    var cancellables = Set<AnyCancellable>()

    // MARK: - Public message batching (UI perf)
    let publicMessagePipeline: PublicMessagePipeline
    // Single-writer: mutate only via `setPublicBatching(_:)` below.
    @Published private(set) var isBatchingPublic: Bool = false

    // Backing store for `sentReadReceipts` persistence. `.standard` in
    // production; injectable so tests can use a scratch suite that does not
    // leak state between runs.
    let readReceiptsDefaults: UserDefaults

    /// Default read-receipt persistence store. Production uses `.standard`.
    /// Under test, every instance gets its own scratch suite: a per-process
    /// shared suite let one test's persisted receipts leak into another
    /// test's freshly constructed view model (surfaced as an order-dependent
    /// CI flake on a duplicated message ID), and tests never pollute
    /// `.standard`.
    static func defaultReadReceiptsDefaults() -> UserDefaults {
        guard TestEnvironment.isRunningTests else { return .standard }
        let suiteName = "chat.bitchat.tests.readReceipts.\(UUID().uuidString)"
        guard let scratch = UserDefaults(suiteName: suiteName) else { return .standard }
        scratch.removePersistentDomain(forName: suiteName)
        return scratch
    }

    // Track sent read receipts to avoid duplicates (persisted across launches)
    // Note: Persistence happens automatically in didSet, no lifecycle observers needed
    var sentReadReceipts: Set<String> = [] {  // messageID set
        didSet {
            // Only persist if there are changes
            guard oldValue != sentReadReceipts else { return }

            // Persist whenever it changes (no manual synchronize/verify re-read)
            if let data = try? JSONEncoder().encode(Array(sentReadReceipts)) {
                readReceiptsDefaults.set(data, forKey: "sentReadReceipts")
            } else {
                SecureLogger.error("❌ Failed to encode read receipts for persistence", category: .session)
            }
        }
    }

    // Track which Nostr DMs we've already sent a delivery ACK for (by messageID)
    // Single-writer: mutate only via `markNostrDeliveryAckSent(_:)` below.
    private(set) var sentNostrDeliveryAcks: Set<String> = []

    // Track app startup phase to prevent marking old messages as unread
    var isStartupPhase = true

    // ConversationStore field audit bookkeeping (see auditConversationStore()):
    // runs on the read-receipt cleanup cadence, heartbeat sampled first +
    // every `TransportConfig.conversationStoreAuditLogInterval`th audit.
    private var storeAuditCount = 0
    private var storeAuditLastAppendCount = 0
    // Announce Tor initial readiness once per launch to avoid duplicates

    // Track Nostr pubkey mappings for unknown senders
    // Single-writer: mutate only via `registerNostrKeyMapping` / `removeNostrKeyMappings` below.
    private(set) var nostrKeyMapping: [PeerID: String] = [:]  // senderPeerID -> nostrPubkey

    // MARK: - Single-Writer Intent Operations
    // Owner-side mutation paths for state the coordinator contexts may read
    // but not write directly. Each op is the sole way to mutate its backing
    // state, so check-then-mutate races between coordinators cannot occur.

    /// Records the Nostr pubkey behind a (possibly virtual) peer ID.
    @MainActor
    func registerNostrKeyMapping(_ pubkey: String, for peerID: PeerID) {
        nostrKeyMapping[peerID] = pubkey
    }

    /// Drops every key mapping that resolves to the given (lowercased) Nostr pubkey.
    @MainActor
    func removeNostrKeyMappings(matchingPubkeyHexLowercased hex: String) {
        for (key, value) in nostrKeyMapping where value.lowercased() == hex {
            nostrKeyMapping.removeValue(forKey: key)
        }
    }

    /// Records that a read receipt is being sent for `messageID`.
    /// Returns `false` when one was already recorded — the caller must skip sending.
    @MainActor
    @discardableResult
    func markReadReceiptSent(_ messageID: String) -> Bool {
        sentReadReceipts.insert(messageID).inserted
    }

    /// Records that a Nostr DM delivery ACK is being sent for `messageID`.
    /// Returns `false` when one was already recorded — the caller must skip sending.
    @MainActor
    @discardableResult
    func markNostrDeliveryAckSent(_ messageID: String) -> Bool {
        sentNostrDeliveryAcks.insert(messageID).inserted
    }

    /// Forgets that read receipts were sent for `ids` so READ acks can be
    /// re-sent after the peer reconnects.
    @MainActor
    func unmarkReadReceiptsSent(_ ids: [String]) {
        sentReadReceipts.subtract(ids)
    }

    /// Marks read receipts as sent for own messages already delivered/read in
    /// `peerID`'s chat, syncing the chat manager's tracking with the persisted
    /// set. (Wraps the manager's `inout` sync so the raw set never leaks.)
    @MainActor
    func syncReadReceiptsForSentMessages(for peerID: PeerID) {
        privateChatManager.syncReadReceiptsForSentMessages(
            peerID: peerID,
            nickname: nickname,
            externalReceipts: &sentReadReceipts
        )
    }

    /// Drops every recorded read receipt whose message ID is no longer valid.
    /// Returns the number of receipts removed.
    @MainActor
    func pruneSentReadReceipts(keeping validMessageIDs: Set<String>) -> Int {
        let oldCount = sentReadReceipts.count
        sentReadReceipts = sentReadReceipts.intersection(validMessageIDs)
        return oldCount - sentReadReceipts.count
    }

    /// Publishes the public-timeline batching state (UI animation suppression).
    @MainActor
    func setPublicBatching(_ isBatching: Bool) {
        isBatchingPublic = isBatching
    }

    /// Moves the open private chat to `newPeerID` when the current selection is
    /// one of the peer IDs being migrated away (side-effectful: re-targets the
    /// private chat session — fingerprint refresh, read receipts).
    ///
    /// Note: when this runs after a store `migrateConversation`, the store has
    /// already handed the selection itself off to `newPeerID` (and the manager
    /// mirrors it), so a selection that reads `newPeerID` is also re-targeted
    /// to run the session side effects. Selections on unrelated peers are
    /// untouched.
    @MainActor
    func handOffSelectedPrivateChat(from oldPeerIDs: [PeerID], to newPeerID: PeerID) {
        guard oldPeerIDs.contains(where: { selectedPrivateChatPeer == $0 })
                || selectedPrivateChatPeer == newPeerID else { return }
        selectedPrivateChatPeer = newPeerID
    }

    // MARK: - Private Conversation Store Intents
    // The sole mutation paths for private (direct) message state. Each op
    // forwards to the single-writer `ConversationStore`
    // (docs/CONVERSATION-STORE-DESIGN.md); the read-only `privateChats` /
    // `unreadPrivateMessages` views above are derived from the same store.

    /// Appends a private message in timestamp order. Returns `false` when a
    /// message with the same ID is already in that chat (O(1) dedup via the
    /// conversation's ID index).
    @MainActor
    @discardableResult
    func appendPrivateMessage(_ message: BitchatMessage, to peerID: PeerID) -> Bool {
        conversations.append(message, to: .directPeer(peerID))
    }

    /// Replace-or-append a private message by ID (mirrored
    /// copies); an existing message keeps its timeline position.
    @MainActor
    func upsertPrivateMessage(_ message: BitchatMessage, in peerID: PeerID) {
        conversations.upsertByID(message, in: .directPeer(peerID))
    }

    /// Applies a delivery status to a private message by ID. Returns `false`
    /// when the message is unknown or the update would downgrade the status
    /// (read beats delivered beats sent).
    @MainActor
    @discardableResult
    func setPrivateDeliveryStatus(_ status: DeliveryStatus, forMessageID messageID: String, peerID: PeerID) -> Bool {
        conversations.setDeliveryStatus(status, forMessageID: messageID, in: .directPeer(peerID))
    }

    /// Flags the peer's chat as unread (store unread state).
    @MainActor
    func markPrivateChatUnread(_ peerID: PeerID) {
        conversations.markUnread(.directPeer(peerID))
    }

    /// Clears the peer's unread flag (store unread state only; read-receipt
    /// sending stays in `PrivateChatManager.markAsRead`).
    @MainActor
    func markPrivateChatRead(_ peerID: PeerID) {
        conversations.markRead(.directPeer(peerID))
    }

    /// Empties the peer's chat but keeps the conversation alive (`/clear`).
    @MainActor
    func clearPrivateChat(_ peerID: PeerID) {
        conversations.clear(.directPeer(peerID))
    }

    /// Removes the peer's chat entirely, including unread state.
    @MainActor
    func removePrivateChat(_ peerID: PeerID) {
        conversations.removeConversation(.directPeer(peerID))
    }

    /// Moves all messages from `oldPeerID`'s chat into `newPeerID`'s chat
    /// (ephemeral↔stable peer-ID handoff): dedups by ID, preserves order,
    /// carries unread state, removes the old chat.
    @MainActor
    func migratePrivateChat(from oldPeerID: PeerID, to newPeerID: PeerID) {
        conversations.migrateConversation(from: .directPeer(oldPeerID), to: .directPeer(newPeerID))
    }

    /// A single private chat's timeline, read straight from the store —
    /// an O(1) lookup that skips the `privateChats` dictionary build. The
    /// context protocols' simple per-peer reads dispatch here.
    @MainActor
    func privateMessages(for peerID: PeerID) -> [BitchatMessage] {
        conversations.conversationsByID[.directPeer(peerID)]?.messages ?? []
    }

    /// `true` when any private chat contains a message with `messageID`
    /// (O(1) per conversation via the store's ID indexes).
    @MainActor
    func privateChatsContainMessage(withID messageID: String) -> Bool {
        conversations.directConversationsContainMessage(withID: messageID)
    }

    /// `true` when `peerID`'s chat contains a message with `messageID`.
    @MainActor
    func privateChat(_ peerID: PeerID, containsMessageWithID messageID: String) -> Bool {
        conversations.conversationsByID[.directPeer(peerID)]?.containsMessage(withID: messageID) ?? false
    }

    // MARK: - Public Conversation Store Intents
    // The sole mutation paths for public (mesh/geohash) message state,
    // mirroring the private intents above. The store's per-conversation cap
    // and timestamp-ordered insert replace `PublicTimelineStore`'s trim and
    // the pipeline's late-insert positioning; the read-only `messages` shim
    // above is derived from the same store.

    /// Appends a public message in timestamp order. Returns `false` when a
    /// message with the same ID is already in that conversation (O(1) dedup
    /// via the conversation's ID index).
    @MainActor
    @discardableResult
    func appendPublicMessage(_ message: BitchatMessage, to conversationID: ConversationID) -> Bool {
        conversations.append(message, to: conversationID)
    }

    /// A public (mesh/geohash) channel's full timeline.
    @MainActor
    func publicMessages(for channel: ChannelID) -> [BitchatMessage] {
        conversations.conversation(for: ConversationID(channelID: channel)).messages
    }

    /// `true` when the conversation contains a message with `messageID`.
    @MainActor
    func publicConversationContainsMessage(withID messageID: String, in conversationID: ConversationID) -> Bool {
        conversations.conversationsByID[conversationID]?.containsMessage(withID: messageID) ?? false
    }

    /// Replaces an unauthenticated bridge alias with a later authenticated
    /// radio row. In addition to both storage layers, clear the content-window
    /// marker written by an already-flushed alias or it would suppress the
    /// genuine row during the next public-message batch.
    @MainActor
    func removeBridgeInjectedPublicMessage(withID messageID: String) {
        publicMessagePipeline.removeMessage(withID: messageID)
        guard let removed = conversations.removePublicMessage(withID: messageID) else { return }
        deduplicationService.forgetContent(removed.content, ifRecordedAt: removed.timestamp)
    }

    /// Empties a public conversation's timeline (`/clear`).
    @MainActor
    func clearPublicConversation(_ conversationID: ConversationID) {
        conversations.clear(conversationID)
    }

    func purgeArchivedPublicMessages() {
        (meshService as? MeshPublicArchiving)?.purgeAllArchivedPublicMessages()
    }

    // MARK: - Initialization

    @MainActor
    convenience init(
        keychain: KeychainManagerProtocol,
        idBridge: NostrIdentityBridge,
        identityManager: SecureIdentityStateManagerProtocol,
        conversations: ConversationStore? = nil,
        peerIdentityStore: PeerIdentityStore? = nil,
        panicPersistentStoreWipes: PanicPersistentStoreWipes? = nil
    ) {
        let persistentWipes = panicPersistentStoreWipes ?? PanicPersistentStoreWipes()
        let livePanicRecoveryOperations = PanicRecoveryOperations.live()
        let startupDecision = PanicStartupDecision.preflight(
            checkPending: livePanicRecoveryOperations.isPending,
            wipeSightings: persistentWipes.sightings,
            wipeGeography: persistentWipes.geography,
            wipeSharedContent: persistentWipes.sharedContent,
            wipeBoard: persistentWipes.board,
            wipeBridge: persistentWipes.bridge,
            wipeGroups: persistentWipes.legacyGroups,
            wipeMedia: persistentWipes.legacyMedia,
            wipeLegacyGroupKeys: persistentWipes.legacyGroupKeys
        )
        // Preserve the preflight decision used to defer CoreBluetooth. A
        // transiently successful second read must not skip recovery and leave
        // the service permanently suspended without running the wipe.
        let panicRecoveryOperations = PanicRecoveryOperations(
            isPending: {
                if startupDecision.replayPanic {
                    return true
                }
                return try livePanicRecoveryOperations.isPending()
            },
            begin: livePanicRecoveryOperations.begin,
            wipeMedia: livePanicRecoveryOperations.wipeMedia,
            complete: livePanicRecoveryOperations.complete
        )
        let meshService = BLEService(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: identityManager,
            startSuspendedForPanicRecovery: startupDecision.suspendTransport,
            deferBluetoothPrompt: WeshMode.isActive && !WeshWelcome.isDone()
        )
        meshService.sfMetrics = .shared
        self.init(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: identityManager,
            transport: meshService,
            conversations: conversations,
            peerIdentityStore: peerIdentityStore ?? PeerIdentityStore(),
            outboxStore: MessageOutboxStore(keychain: keychain),
            sfMetrics: .shared,
            panicRecoveryOperations: panicRecoveryOperations,
            panicNetworkLifecycle: .live,
            weshPrivatePolicyEnabled: WeshMode.isActive,
            panicPersistentStoreWipes: persistentWipes,
            startupRetirementBlocked: startupDecision.blockOrdinaryAdmission
        )
    }

    /// Testable initializer that accepts a Transport dependency.
    /// Use this initializer for unit testing with MockTransport.
    @MainActor
    init(
        keychain: KeychainManagerProtocol,
        idBridge: NostrIdentityBridge,
        identityManager: SecureIdentityStateManagerProtocol,
        transport: Transport,
        conversations: ConversationStore? = nil,
        peerIdentityStore: PeerIdentityStore? = nil,
        readReceiptsDefaults: UserDefaults? = nil,
        outboxStore: MessageOutboxStore? = nil,
        sfMetrics: StoreAndForwardMetrics? = nil,
        panicMediaWipe: (() throws -> Void)? = nil,
        panicRecoveryOperations: PanicRecoveryOperations? = nil,
        panicNetworkLifecycle: PanicNetworkLifecycle = .noop,
        weshPrivatePolicyEnabled: Bool = false,
        weshMeetingNote: WeshMeetingNoteStore? = nil,
        panicPersistentStoreWipes: PanicPersistentStoreWipes? = nil,
        startupRetirementBlocked: Bool = false
    ) {
        self.weshPrivatePolicyEnabled = weshPrivatePolicyEnabled
        let conversations = conversations ?? ConversationStore()
        let peerIdentityStore = peerIdentityStore ?? PeerIdentityStore()
        let services = ChatViewModelServiceBundle(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: identityManager,
            meshService: transport,
            outboxStore: outboxStore,
            sfMetrics: sfMetrics
        )

        self.keychain = keychain
        self.panicRecoveryOperations = panicRecoveryOperations
            ?? .ephemeral(wipeMedia: panicMediaWipe ?? {})
        self.panicNetworkLifecycle = panicNetworkLifecycle
        self.nostrOutboundPanicBinding = services.nostrOutboundPanicBinding
        self.panicPersistentStoreWipes = panicPersistentStoreWipes ?? PanicPersistentStoreWipes()
        self.weshMeetingNote = weshMeetingNote
            ?? (TestEnvironment.isRunningTests
                ? WeshMeetingNoteStore()
                : WeshMeetingNoteStore(storage: .liveMeetingNote(), legacyDefaults: .standard, saveDelay: 0.4))
        self.idBridge = idBridge
        self.identityManager = identityManager
        self.conversations = conversations
        self.peerIdentityStore = peerIdentityStore
        self.meshService = transport
        self.noiseIdentityAvailability = (transport as? MeshIdentityRecovering)?.noiseIdentityAvailability ?? .available
        self.commandProcessor = services.commandProcessor
        self.messageRouter = services.messageRouter
        self.privateChatManager = services.privateChatManager
        self.unifiedPeerService = services.unifiedPeerService
        self.autocompleteService = services.autocompleteService
        self.deduplicationService = services.deduplicationService
        self.publicMessagePipeline = services.publicMessagePipeline
        let readReceiptsDefaults = readReceiptsDefaults ?? Self.defaultReadReceiptsDefaults()
        self.readReceiptsDefaults = readReceiptsDefaults
        self.sentReadReceipts = ChatViewModelBootstrapper.loadPersistedReadReceipts(userDefaults: readReceiptsDefaults)

        // Republish on every store change so SwiftUI observers of the
        // view model refresh. This replaces the UI-update role of the old
        // `PrivateChatManager.@Published` dictionaries and the old
        // `@Published var messages`. Changes touching the ACTIVE public
        // conversation also invalidate the derived `messages` cache before
        // observers re-read it.
        conversations.changes
            .sink { [weak self] change in
                guard let self else { return }
                if self.changeAffectsActivePublicConversation(change) {
                    self.visibleMessagesCache = nil
                }
                self.objectWillChange.send()
            }
            .store(in: &cancellables)

        if weshPrivatePolicyEnabled {
            messageRouter.privateSendPolicy = { [weak self] recipient, pinnedKey in
                guard let self else { return nil }
                // Receipts and acks address the live short mesh ID; admit it
                // only as the authenticated session key it resolves to now.
                let target = recipient.noiseKey != nil ? recipient
                    : self.noiseSessionPublicKeyData(for: recipient).map { PeerID(hexData: $0) } ?? recipient
                if self.canSendWeshPrivate(to: target),
                   let actualKey = self.noiseSessionPublicKeyData(for: self.getShortIDForNoiseKey(target)) {
                    return pinnedKey == nil || pinnedKey == actualKey ? actualKey : nil
                }
                // Internet route: no session to read the key from, so the enrolled key itself.
                if let enrolledKey = target.noiseKey, self.canSendWeshInternet(to: target),
                   pinnedKey == nil || pinnedKey == enrolledKey {
                    return enrolledKey
                }
                return nil
            }
        }

        let recoveryRequired: Bool
        do {
            recoveryRequired = try self.panicRecoveryOperations.isPending()
        } catch {
            // Failure to read the latch cannot fail open. Re-run the complete
            // transaction; anything still unconfirmed stays pending for the
            // next launch.
            recoveryRequired = true
            SecureLogger.error(
                "Could not read panic-recovery state; retrying the full wipe before startup: \(error)",
                category: .security
            )
        }

        if recoveryRequired {
            SecureLogger.warning(
                "Pending panic recovery detected; wiping before runtime services start",
                category: .security
            )
            _ = panicClearAllData(restartServices: false)
        }

        if !recoveryRequired && startupRetirementBlocked {
            self.startupRetirementBlocked = true
            panicRecoveryBlocked = true
        }

        if networkActivationAllowed {
            configureBootstrapIfNeeded()
        }
    }

    @MainActor
    func configureBootstrapIfNeeded() {
        guard networkActivationAllowed, !bootstrapConfigured else { return }
        bootstrapConfigured = true
        ChatViewModelBootstrapper(viewModel: self).configure()
    }

    // MARK: - Deinitialization

    deinit {
        // No need to force UserDefaults synchronization
    }

    // MARK: - Nickname Management

    func loadNickname() {
        provisionalNickname = nil
        switch nicknameStore.load() {
        case .stored(let savedNickname):
            nickname = savedNickname.trimmed
        case .absent:
            nickname = "anon\(Int.random(in: 1000...9999))"
            saveNickname()
        case .unavailable:
            // Keychain locked (background launch before first unlock): use a
            // stand-in that is never saved, and read again after unlock.
            nickname = "anon\(Int.random(in: 1000...9999))"
            provisionalNickname = nickname
            observeProtectedDataForNickname()
        }
    }

    /// True while the name is the stand-in chosen with a locked Keychain and
    /// the user has not typed another one.
    var isNicknameProvisional: Bool {
        provisionalNickname != nil && provisionalNickname == nickname
    }

    func reloadProvisionalNickname() {
        guard isNicknameProvisional else { return }
        switch nicknameStore.load() {
        case .stored(let savedNickname):
            provisionalNickname = nil
            nickname = savedNickname.trimmed
            meshService.sendBroadcastAnnounce()
        case .absent:
            provisionalNickname = nil
            saveNickname()
        case .unavailable:
            break
        }
    }

    private func observeProtectedDataForNickname() {
        #if os(iOS)
        guard nicknameProtectedDataObserver == nil else { return }
        nicknameProtectedDataObserver = NotificationCenter.default
            .publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadProvisionalNickname() }
        #endif
    }

    func saveNickname() {
        if let provisional = provisionalNickname {
            // Saving on focus loss must not make the stand-in permanent.
            guard nickname != provisional else { return }
            provisionalNickname = nil
        }
        nicknameStore.save(nickname)

        // Send announce with new nickname to all peers
        meshService.sendBroadcastAnnounce()
    }

    func validateAndSaveNickname() {
        nickname = nickname.trimmedOrNilIfEmpty ?? "anon\(Int.random(in: 1000...9999))"
        saveNickname()
    }

    // MARK: - Blocked Users Management (Delegated to PeerStateManager)

    /// Check if a peer has unread messages, including messages stored under stable Noise keys and temporary Nostr peer IDs
    @MainActor
    func hasUnreadMessages(for peerID: PeerID) -> Bool {
        peerIdentityCoordinator.hasUnreadMessages(for: peerID)
    }

    @MainActor
    func toggleFavorite(peerID: PeerID) {
        peerIdentityCoordinator.toggleFavorite(peerID: peerID)
    }

    // MARK: - Public Key and Identity Management

    @MainActor
    func isPeerBlocked(_ peerID: PeerID) -> Bool {
        peerIdentityCoordinator.isPeerBlocked(peerID)
    }

    // Helper method to update selectedPrivateChatPeer if fingerprint matches
    @MainActor
    func updatePrivateChatPeerIfNeeded() {
        peerIdentityCoordinator.updatePrivateChatPeerIfNeeded()
    }

    // MARK: - Message Sending

    /// Sends a message through the BitChat network.
    /// - Parameter content: The message content to send
    /// - Note: Automatically handles command processing if content starts with '/'
    ///         Routes to private chat if one is selected, otherwise broadcasts
    @MainActor
    func sendMessage(_ content: String) {
        if weshPrivatePolicyEnabled {
            if selectedPrivateChatPeer != nil {
                guard let fingerprint = selectedPrivateChatFingerprint,
                      let contact = WeshQRTrust.shared.contacts.first(where: { Data(hexString: $0.noiseKeyHex)?.sha256Fingerprint() == fingerprint }),
                      canSendWeshMessage(to: contact.peerID) else { return }
                sendPrivateMessage(content, to: contact.peerID)
            } else {
                _ = sendWeshText(content, to: nil)
            }
            return
        }
        outgoingCoordinator.sendMessage(content)
    }

    /// Explicit text API: preserves the current send pipeline while preventing a slash command
    /// from changing the recipient after the composer checked its QR authorization.
    @MainActor
    @discardableResult
    func sendWeshText(_ content: String, to peerID: PeerID?) -> Bool {
        guard content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              content.utf8.count <= WeshTextLimits.maximumUTF8Bytes else { return false }
        if let peerID {
            guard canSendWeshMessage(to: peerID) else { return false }
            startPrivateChat(with: peerID)
            // Route to the checked full Noise-key identity, never mutable global selection.
            sendPrivateMessage(content, to: peerID)
            return true
        } else {
            guard canSendWeshPublic,
                  UserDefaults.standard.bool(forKey: "wesh.publicDisclosureAccepted.v1") else { return false }
            endPrivateChat()
            activeChannel = .mesh
        }
        outgoingCoordinator.sendMessage(content, allowCommands: false)
        return true
    }

    /// Storage recovery never submits a message or clears a composer draft.
    @MainActor
    func retryNoiseIdentityRecovery() {
        guard !isRecoveringNoiseIdentity else { return }
        guard !panicRecoveryBlocked, let recovery = meshService as? MeshIdentityRecovering else {
            noiseIdentityRetryFailed = true
            return
        }
        isRecoveringNoiseIdentity = true
        noiseIdentityRetryFailed = false
        recovery.retryNoiseIdentityRecovery { [weak self, weak recovery] reportedSuccess in
            guard let self else { return }
            self.isRecoveringNoiseIdentity = false
            let latest = recovery?.noiseIdentityAvailability ?? .storageUnavailable
            self.noiseIdentityAvailability = latest
            self.noiseIdentityRetryFailed = !reportedSuccess || latest != .available || self.panicRecoveryBlocked
        }
    }

    /// Radio availability only; it does not promise a peer or a recipient receipt.
    var canSendWeshPublic: Bool {
        !panicRecoveryBlocked
            && !isRecoveringNoiseIdentity
            && noiseIdentityAvailability == .available
            && (meshService as? MeshIdentityRecovering)?.isNoiseIdentityTrafficAllowed != false
            && bluetoothState == .poweredOn
            && meshService.noiseStaticPublicKeyData().count == 32
            && meshService.noiseSigningPublicKeyData().count == 32
    }

    /// Composer drafts are cleared only after the explicit route accepts the send.
    @discardableResult
    func sendWeshDraft(_ draft: inout String, to peerID: PeerID?) -> Bool {
        guard sendWeshText(draft, to: peerID) else { return false }
        draft = ""
        return true
    }

    func weshQRProgress(for noiseKey: Data, attemptNonce: Data) -> ChatVerificationCoordinator.QRProgress {
        verificationCoordinator.qrProgress(for: noiseKey, attemptNonce: attemptNonce)
    }

    func weshQRAttemptNonce(for noiseKey: Data) -> Data? {
        verificationCoordinator.qrAttemptNonce(for: noiseKey)
    }

    func weshScannedMyCode(noiseKey: Data, since: Date) -> Bool {
        verificationCoordinator.scannedMyCode(noiseKey: noiseKey, since: since)
    }

    @discardableResult
    func removeWeshContact(for noiseKey: Data) -> Bool {
        verificationCoordinator.cancelQRVerification(for: noiseKey)
        return WeshQRTrust.shared.remove(sessionKey: noiseKey)
    }

    /// False when the wipe was not confirmed; the list stays empty in RAM and
    /// the wipe is retried on the next load.
    @discardableResult
    func removeAllWeshContacts() -> Bool {
        verificationCoordinator.cancelAllQRVerifications()
        return WeshQRTrust.shared.clear()
    }

    /// Sends a 👋 to the mesh channel regardless of the active channel.
    @MainActor
    func sendMeshWave() {
        // Notification actions can run without opening the public composer.
        // In Wesh they must respect the same first-send disclosure and radio gate.
        if weshPrivatePolicyEnabled {
            guard canSendWeshPublic,
                  UserDefaults.standard.bool(forKey: "wesh.publicDisclosureAccepted.v1") else { return }
        }
        outgoingCoordinator.sendMeshWave()
    }

    // MARK: - Sender attribution

    @MainActor
    func isSelfSender(peerID: PeerID?) -> Bool {
        peerID == meshService.myPeerID
    }

    // MARK: - Public helpers

    // Mesh (Noise identity) block helpers. Unlike the `/block <nickname>`
    // command, these resolve and persist the block by the peer's stable
    // fingerprint (derived from `peerID`), so the exact tapped peer is
    // (un)blocked — unambiguous across nickname collisions and functional for
    // offline peers that can no longer be resolved through the mesh service.
    @MainActor
    func blockMeshPeer(peerID: PeerID, displayName: String) {
        setMeshPeerBlocked(peerID, blocked: true, displayName: displayName)
    }

    @MainActor
    private func setMeshPeerBlocked(_ peerID: PeerID, blocked: Bool, displayName: String) {
        guard unifiedPeerService.setBlocked(peerID, blocked: blocked) != nil else {
            addCommandOutput(
                String(
                    format: String(
                        localized: blocked ? "system.mesh.block_failed" : "system.mesh.unblock_failed",
                        comment: "System message shown when a mesh peer cannot be blocked or unblocked"
                    ),
                    locale: .current,
                    displayName
                )
            )
            return
        }
        addCommandOutput(
            String(
                format: String(
                    localized: blocked ? "system.mesh.blocked" : "system.mesh.unblocked",
                    comment: "System message shown when a mesh peer is blocked or unblocked"
                ),
                locale: .current,
                displayName
            )
        )
    }

    func displayNameForNostrPubkey(_ pubkeyHex: String) -> String {
        publicConversationCoordinator.displayNameForNostrPubkey(pubkeyHex)
    }

    /// Add a local system message to a private chat (no network send)
    @MainActor
    func addLocalPrivateSystemMessage(_ content: String, to peerID: PeerID) {
        let systemMessage = BitchatMessage(
            sender: "system",
            content: content,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: meshService.peerNickname(peerID: peerID),
            senderPeerID: meshService.myPeerID
        )
        appendPrivateMessage(systemMessage, to: peerID)
        objectWillChange.send()
    }

    // MARK: - Bluetooth State Management

    /// Updates the Bluetooth state and shows appropriate alerts
    /// - Parameter state: The current Bluetooth manager state
    @MainActor
    func updateBluetoothState(_ state: CBManagerState) {
        bluetoothState = state
        let alertUpdate = ChatBluetoothAlertPolicy.update(for: state)
        showBluetoothAlert = alertUpdate.isPresented
        if let message = alertUpdate.message {
            bluetoothAlertMessage = message
        }
    }

    // MARK: - Private Chat Management

    /// Initiates a private chat session with a peer.
    /// - Parameter peerID: The peer's ID to start chatting with
    /// - Note: Switches the UI to private chat mode and loads message history
    @MainActor
    func startPrivateChat(with peerID: PeerID) {
        peerIdentityCoordinator.startPrivateChat(with: peerID)
    }

    @MainActor
    func endPrivateChat() {
        peerIdentityCoordinator.endPrivateChat()
    }

    @MainActor
    @objc func handlePeerStatusUpdate(_: Notification) {
        peerIdentityCoordinator.handlePeerStatusUpdate()
    }

    @objc func handleFavoriteStatusChanged(_ notification: Notification) {
        peerIdentityCoordinator.handleFavoriteStatusChanged(notification)
    }

    // MARK: - App Lifecycle

    @MainActor
    func handleDidBecomeActive() {
        lifecycleCoordinator.handleDidBecomeActive()
    }

    @MainActor
    func handleScreenshotCaptured() {
        lifecycleCoordinator.handleScreenshotCaptured()
    }

    /// Save identity state without stopping services (for backgrounding)
    func saveIdentityState() {
        lifecycleCoordinator.saveIdentityState()
    }

    @objc func applicationWillTerminate() {
        lifecycleCoordinator.applicationWillTerminate()
    }

    @MainActor
    func markPrivateMessagesAsRead(from peerID: PeerID) {
        lifecycleCoordinator.markPrivateMessagesAsRead(from: peerID)
    }

    @MainActor
    func getPeerIDForNickname(_ nickname: String) -> PeerID? {
        peerIdentityCoordinator.getPeerIDForNickname(nickname)
    }

    // MARK: - Emergency Functions

    /// Retries only legacy metadata deletion. A newly pending panic still
    /// requires the existing explicit recovery action before admission reopens.
    @MainActor
    @discardableResult
    func retryStartupRetirement() -> Bool {
        guard startupRetirementBlocked else { return false }
        let decision = PanicStartupDecision.retry(
            checkPending: panicRecoveryOperations.isPending,
            wipeSightings: panicPersistentStoreWipes.sightings,
            wipeGeography: panicPersistentStoreWipes.geography,
            wipeSharedContent: panicPersistentStoreWipes.sharedContent,
            wipeBoard: panicPersistentStoreWipes.board,
            wipeBridge: panicPersistentStoreWipes.bridge,
            wipeGroups: panicPersistentStoreWipes.legacyGroups,
            wipeMedia: panicPersistentStoreWipes.legacyMedia,
            wipeLegacyGroupKeys: panicPersistentStoreWipes.legacyGroupKeys
        )
        if decision.replayPanic {
            startupRetirementBlocked = false
            return false
        }
        guard !decision.blockOrdinaryAdmission else { return false }
        startupRetirementBlocked = false
        panicRecoveryBlocked = false
        if let panicTransport = meshService as? PanicResettingTransport {
            panicTransport.completePanicReset(restartServices: false)
        }
        configureBootstrapIfNeeded()
        return true
    }

    // PANIC: Emergency data clearing for activist safety
    @MainActor
    @discardableResult
    /// `restartMesh: false` keeps Bluetooth stopped after the wipe (Wesh: until the welcome ends),
    /// while the rest of the network lifecycle restarts as usual.
    func panicClearAllData(restartServices: Bool = true, restartMesh: Bool = true) -> Bool {
        startupRetirementBlocked = false
        panicRecoveryBlocked = true
        _ = panicNetworkLifecycle.closeInstalledNostrRoots(nostrOutboundPanicBinding)
        weshPanicGeneration &+= 1
        // A new npub after the wipe must be announced again; nothing from before is reused.
        weshAnnouncedInternetKeys.removeAll()
        isPanicResetting = true
        defer { isPanicResetting = false }
        weshMeetingNote.suspendForPanic()

        // Stop internet and location-presence work before clearing identity or
        // state. These services cancel their subscriptions and delayed tasks,
        // so old callbacks cannot reconnect during the transaction.
        let networkWipeCompleted = panicNetworkLifecycle.stop()

        // Establish both independent durable intents before erasing anything.
        // `wipeMedia` will still attempt deletion if neither write succeeds.
        let recoveryIntent = panicRecoveryOperations.begin()

        // Fence UI/load callbacks and drain old draft IO before deleting keys.
        // The utility queue never synchronously waits on Main.
        ComposerDraftStore.suspendForPanic()

        // Quiesce the mesh before clearing stores. Identity replacement below
        // deliberately stays stopped until media deletion and marker commit.
        if let panicTransport = meshService as? PanicResettingTransport {
            panicTransport.suspendForPanicReset()
        } else {
            meshService.emergencyDisconnectAll()
        }

        // Clear all messages (public timelines and private chats live in the
        // single-writer ConversationStore; the derived `messages` view and
        // the legacy mirror empty with it)
        conversations.clearAll()
        WeshInboundRequests.shared.clear()

        // Delete all keychain data (including Noise and Nostr keys)
        let keychainWipeCompleted = keychain.deleteAllKeychainData()
        if !keychainWipeCompleted {
            SecureLogger.error(
                "Panic keychain cleanup incomplete; recovery remains pending",
                category: .security
            )
        }

        // Clear UserDefaults identity data
        userDefaults.removeObject(forKey: "bitchat.noiseIdentityKey")
        userDefaults.removeObject(forKey: "bitchat.messageRetentionKey")

        // Delete legacy geographic state without loading it or creating a
        // location manager; any unconfirmed erase keeps the intent pending.
        let geographyWipeCompleted = panicPersistentStoreWipes.geography()

        // Reset nickname to anonymous; the previous one must be gone from
        // the Keychain and from the legacy UserDefaults key.
        provisionalNickname = nil
        nickname = "anon\(Int.random(in: 1000...9999))"
        let nicknameWipeCompleted = nicknameStore.replaceForPanic(with: nickname)

        // Clear favorites and peer mappings
        // Clear through SecureIdentityStateManager instead of directly
        identityManager.clearAllIdentityData()
        // The reset path offered for an unreadable cache relies on this: the
        // wipe commits only once an empty cache is confirmed writable again.
        let identityCacheWipeCompleted = identityManager.isPersistenceAvailable
        peerIdentityStore.clearAll()
        // A scan pending from before the wipe must not complete under the new
        // identity and re-enroll the contact that was just erased.
        verificationCoordinator.cancelAllQRVerifications()
        let qrContactsWipeCompleted = panicPersistentStoreWipes.qrContacts()
        // The welcome and its terms come back after a wipe, like on a new phone.
        for key in ["wesh.publicDisclosureAccepted.v1", "wesh.publicMuted", "wesh.appearance.v1", WeshWelcome.key] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let meetingNoteWipeCompleted = weshMeetingNote.wipeForPanic()
        panicPersistentStoreWipes.notifications()
        panicPersistentStoreWipes.pasteboard()
        publicRateLimiter.reset()

        // Clear persistent favorites from keychain
        FavoritesPersistenceService.shared.clearAllFavorites()

        // Drop courier mail carried for third parties (memory and disk),
        // our own queued outbox, the carried public history, and the
        // counters describing all of it
        let courierWipeCompleted = panicPersistentStoreWipes.courier()
        let bridgeWipeCompleted = panicPersistentStoreWipes.bridge()
        let outboxWipeCompleted = messageRouter.wipeOutbox()
        let publicArchiveWipeCompleted = panicPersistentStoreWipes.publicArchive()
        StoreAndForwardMetrics.shared.reset()

        // Retired encounter metadata must be verifiably absent.
        let sightingsWipeCompleted = panicPersistentStoreWipes.sightings()
        MeshEchoSettings.reset()
        NotificationPrivacySettings.reset()
        // A hand-added relay names an operator someone chose to route through,
        // which is the kind of trace a wipe should not leave behind.
        NostrRelaySettings.reset()

        // Drop group rosters an earlier build may have stored; their keys go
        // with the keychain wipe above.
        let groupWipeCompleted = panicPersistentStoreWipes.legacyGroups()
        // Drop cached peers' prekey bundles (who we could write to is
        // metadata too). Our own prekey privates are keychain-backed and go
        // with deleteAllKeychainData above plus the identity reset below.
        let prekeysWipeCompleted = panicPersistentStoreWipes.prekeys()
        // Erase signed posts left on disk by builds that supported Board.
        let boardWipeCompleted = panicPersistentStoreWipes.board()

        // Erase handoffs left by earlier share extensions through the checked
        // persistent-store transaction, including direct or startup recovery.
        let sharedContentWipeCompleted = panicPersistentStoreWipes.sharedContent()

        // Identity manager has cleared persisted identity data above

        // Clear autocomplete state
        autocompleteSuggestions.removeAll()
        showAutocomplete = false
        autocompleteRange = nil
        selectedAutocompleteIndex = 0

        // Clear selected private chat
        selectedPrivateChatPeer = nil

        // Clear live location/geohash session state. Persisted location state
        // was wiped above, but the running view model can still be scoped to a
        // geohash channel and hold subscriptions tied to the old Nostr identity.
        activeChannel = .mesh
        nostrKeyMapping.removeAll()

        // Clear read receipt tracking
        sentReadReceipts.removeAll()
        deduplicationService.clearAll()

        // IMPORTANT: Clear Nostr-related state
        // Drop relay subscriptions, handlers, pending sends, and replay state.
        // Geohash DM handlers can capture pre-wipe Nostr identities, so a plain
        // disconnect is not enough here.
        NostrRelayManager.shared.resetForPanicWipe()
        // Clearing relay handlers stops NEW events, but a detached gift-wrap
        // decrypt spawned just before the wipe still holds a pre-wipe key and
        // ciphertext; bump the pipeline's wipe generation so its result is
        // dropped at the main-actor delivery hop instead of landing here.
        nostrCoordinator.inbound.invalidateInFlightDecrypts()
        nostrRelayManager = nil

        // Clear Nostr identity associations
        idBridge.clearAllAssociations()

        // Replace the BLE identity while keeping the radio stopped. It may
        // reopen only after the durable panic transaction commits.
        if let panicTransport = meshService as? PanicResettingTransport {
            panicTransport.resetIdentityForPanic(
                currentNickname: nickname,
                restartServices: false
            )
        } else {
            meshService.setNickname(nickname)
        }

        // The wipe must finish before this security action returns. A detached
        // task could otherwise lose a race with a new capture or app exit and
        // leave pre-panic media behind.
        var panicCompleted = false
        var draftsWiped = false
        do {
            try panicRecoveryOperations.wipeMedia(recoveryIntent)
            draftsWiped = true
            panicCompleted = try panicRecoveryOperations.completeIfConfirmed(
                existingStoreResults: [
                    networkWipeCompleted, keychainWipeCompleted, identityCacheWipeCompleted, nicknameWipeCompleted,
                    meetingNoteWipeCompleted, qrContactsWipeCompleted, courierWipeCompleted,
                    bridgeWipeCompleted, outboxWipeCompleted, publicArchiveWipeCompleted,
                    groupWipeCompleted, prekeysWipeCompleted, boardWipeCompleted, geographyWipeCompleted, sharedContentWipeCompleted
                ],
                legacySightingsConfirmed: sightingsWipeCompleted
            )
            if panicCompleted {
                SecureLogger.info(
                    "🗑️ Deleted all media files during panic clear",
                    category: .session
                )
            }
        } catch {
            SecureLogger.error("Panic media or marker step failed: \(error)", category: .security)
        }
        // Never a dead end: the app restarts fresh either way. An unconfirmed
        // store keeps the durable intent, so the next launch erases again
        // before anything starts; until then nothing goes on the network.
        if !panicCompleted {
            SecureLogger.error("Panic erase left pending until the next launch; network stays off", category: .security)
        }
        panicRecoveryBlocked = false
        panicNetworkFenced = !panicCompleted

        // BCH-01-013: Clear iOS app switcher snapshots. Keep tests away from
        // the host user's real cache tree just as the default media wipe does.
        #if os(iOS)
        if !TestEnvironment.isRunningTests {
            Self.clearAppSwitcherSnapshots()
        }
        #endif

        if let panicTransport = meshService as? PanicResettingTransport {
            // Startup recovery reopens admission but leaves actual service
            // start to the bootstrapper immediately after this method.
            panicTransport.completePanicReset(
                restartServices: restartServices && restartMesh && panicCompleted
            )
        }

        // A store whose wipe is unconfirmed stays closed so nothing old reloads.
        if draftsWiped {
            ComposerDraftStore.completePanic(
                success: true, noiseKey: meshService.noiseStaticPublicKeyData()
            )
        }
        if meetingNoteWipeCompleted {
            weshMeetingNote.completePanic()
        }

        if restartServices && panicCompleted {
            // All persistent state and media are gone. Bring each service back
            // only now, under the new identity — a panic-resetting transport
            // owns its own restart sequencing above.
            if !(meshService is PanicResettingTransport) && restartMesh {
                meshService.startServices()
            }

            if !TestEnvironment.isRunningTests {
                nostrRelayManager = NostrRelayManager.shared
                setupNostrMessageHandling()
            }
            panicNetworkLifecycle.restart()
        }

        // In a duress scenario "did it work?" must not be a guess — the
        // natural response to uncertainty is to trigger the wipe again.
        // The caller reports an unconfirmed erase from the return value.
        if panicCompleted {
            addMeshOnlySystemMessage(
                String(localized: "system.panic.completed", defaultValue: "all data wiped — new identity created", comment: "System message confirming a successful panic wipe")
            )
        }

        return panicCompleted
    }

    /// BCH-01-013: Clear iOS app switcher snapshots during panic mode
    /// iOS stores preview screenshots in Library/Caches/Snapshots/<bundle_id>/
    /// These could reveal sensitive information visible in the app at the time
    #if os(iOS)
    private nonisolated static func clearAppSwitcherSnapshots() {
        do {
            let cacheDir = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let snapshotsDir = cacheDir.appendingPathComponent("Snapshots", isDirectory: true)

            // Clear all snapshots (iOS stores them in subdirectories by bundle ID and scene)
            if FileManager.default.fileExists(atPath: snapshotsDir.path) {
                let contents = try FileManager.default.contentsOfDirectory(at: snapshotsDir, includingPropertiesForKeys: nil)
                for item in contents {
                    try FileManager.default.removeItem(at: item)
                }
                SecureLogger.info("🗑️ Cleared app switcher snapshots during panic clear", category: .session)
            }
        } catch {
            SecureLogger.error("Failed to clear app switcher snapshots: \(error)", category: .session)
        }
    }
    #endif

    // MARK: - Autocomplete

    func updateAutocomplete(for text: String, cursorPosition: Int) {
        composerCoordinator.updateAutocomplete(for: text, cursorPosition: cursorPosition)
    }

    func completeNickname(_ nickname: String, in text: inout String) -> Int {
        composerCoordinator.completeNickname(nickname, in: &text)
    }

    // MARK: - Message Formatting

    @MainActor
    func formatMessageAsText(_ message: BitchatMessage, colorScheme: ColorScheme, theme: AppTheme? = nil) -> AttributedString {
        messageFormatter.formatMessageAsText(message, colorScheme: colorScheme, theme: theme ?? currentTheme)
    }

    @MainActor
    func formatMessageHeader(_ message: BitchatMessage, colorScheme: ColorScheme, theme: AppTheme? = nil) -> AttributedString {
        messageFormatter.formatMessageHeader(message, colorScheme: colorScheme, theme: theme ?? currentTheme)
    }

    // MARK: - Noise Protocol Support

    @MainActor
    func updateEncryptionStatusForPeers() {
        peerIdentityCoordinator.updateEncryptionStatusForPeers()
    }

    @MainActor
    func updateEncryptionStatus(for peerID: PeerID) {
        peerIdentityCoordinator.updateEncryptionStatus(for: peerID)
    }

    @MainActor
    func getEncryptionStatus(for peerID: PeerID) -> EncryptionStatus {
        peerIdentityCoordinator.getEncryptionStatus(for: peerID)
    }

    // Clear caches when data changes
    @MainActor
    func invalidateEncryptionCache(for peerID: PeerID? = nil) {
        peerIdentityCoordinator.invalidateEncryptionCache(for: peerID)
    }

    // MARK: - Message Handling

    /// Invalidates the derived `messages` cache and notifies observers.
    /// (Formerly pulled the channel's timeline into a stored `messages`
    /// array; `messages` is now derived from the `ConversationStore`, so
    /// only the invalidation remains.)
    @MainActor
    func refreshVisibleMessages() {
        visibleMessagesCache = nil
        objectWillChange.send()
    }

    /// `true` when a store change touches the active public conversation
    /// (so the derived `messages` cache must be invalidated).
    @MainActor
    private func changeAffectsActivePublicConversation(_ change: ConversationChange) -> Bool {
        let activeID = ConversationID(channelID: activeChannel)
        switch change {
        case .appended(let id, _),
             .updated(let id, _),
             .statusChanged(let id, _, _),
             .messageRemoved(let id, _),
             .cleared(let id),
             .removed(let id),
             .unreadChanged(let id, _):
            return id == activeID
        case .migrated(let source, let destination):
            return source == activeID || destination == activeID
        }
    }

    @MainActor
    private func peerColor(for message: BitchatMessage, isDark: Bool) -> Color {
        messageFormatter.senderColor(for: message, isDark: isDark)
    }

    // MARK: - MessageFormattingContext Protocol

    @MainActor
    func isSelfMessage(_ message: BitchatMessage) -> Bool {
        messageFormatter.isSelfMessage(message)
    }

    @MainActor
    func senderColor(for message: BitchatMessage, isDark: Bool) -> Color {
        peerColor(for: message, isDark: isDark)
    }

    @MainActor
    func peerURL(for peerID: PeerID) -> URL? {
        messageFormatter.peerURL(for: peerID)
    }

    // Clear the current public channel's timeline (visible + persistent buffer)
    @MainActor
    func clearCurrentPublicTimeline() {
        publicConversationCoordinator.clearCurrentPublicTimeline()
    }

    // MARK: - Peer Lookup Helpers

    func getPeer(byID peerID: PeerID) -> BitchatPeer? {
        return peerIndex[peerID]
    }

    @MainActor
    func getFingerprint(for peerID: PeerID) -> String? {
        peerIdentityCoordinator.getFingerprint(for: peerID)
    }

    /// Helper to resolve nickname for a peer ID through various sources
    @MainActor
    func resolveNickname(for peerID: PeerID) -> String {
        peerIdentityCoordinator.resolveNickname(for: peerID)
    }

    @MainActor
    func getMyFingerprint() -> String {
        peerIdentityCoordinator.getMyFingerprint()
    }

    @MainActor
    func verifyFingerprint(for peerID: PeerID) {
        verificationCoordinator.verifyFingerprint(for: peerID)
    }

    @MainActor
    func unverifyFingerprint(for peerID: PeerID) {
        verificationCoordinator.unverifyFingerprint(for: peerID)
    }

    @MainActor
    func loadVerifiedFingerprints() {
        verificationCoordinator.loadVerifiedFingerprints()
    }

    func setupNoiseCallbacks() {
        verificationCoordinator.setupNoiseCallbacks()
        vouchCoordinator.setupNoiseCallbacks()
    }

    // MARK: - BitchatDelegate Methods

    // MARK: - Command Handling

    /// Processes IRC-style commands starting with '/'.
    /// - Parameter command: The full command string including the leading slash
    /// - Note: Supports commands like /msg, /who, /slap, /clear, /help
    @MainActor
    func handleCommand(_ command: String) {
        let result = commandProcessor.process(command)

        switch result {
        case .success(let message):
            if let msg = message {
                addCommandOutput(msg)
            }
        case .error(let message):
            addCommandOutput(message)
        case .handled:
            // Command was handled, no message needed
            break
        }
    }

    /// Command output belongs in the conversation where the user typed the
    /// command; the public timeline is invisible while a DM is open. The DM
    /// selection is read *after* processing so commands that switch chats
    /// (`/msg`) print into the conversation they just opened.
    @MainActor
    private func addCommandOutput(_ content: String) {
        if let peerID = selectedPrivateChatPeer {
            addLocalPrivateSystemMessage(content, to: peerID)
        } else {
            addSystemMessage(content)
        }
    }

    /// Origin conversation for deferred command output, captured when the
    /// command is issued (before any async work starts).
    @MainActor
    func currentCommandDestination() -> CommandOutputDestination {
        if let peerID = selectedPrivateChatPeer {
            return .privateChat(peerID)
        }
        // Deferring commands (/ping) are rejected in geohash channels, so a
        // non-DM origin is always the #mesh timeline.
        return .meshTimeline
    }

    /// Routes deferred command output (async /ping results) into the
    /// conversation captured at issue time, immune to chat switches in the
    /// meantime. A DM result lands in the origin chat's history even if that
    /// chat is no longer selected (or was cleared — it then reappears as the
    /// first message when the chat is reopened).
    @MainActor
    func addCommandOutput(_ content: String, to destination: CommandOutputDestination) {
        switch destination {
        case .privateChat(let peerID):
            addLocalPrivateSystemMessage(content, to: peerID)
        case .meshTimeline:
            publicConversationCoordinator.addMeshOnlySystemMessage(content)
        }
    }

    // MARK: - Message Reception

    @MainActor
    func didReceiveTransportEvent(_ event: TransportEvent) {
        switch event {
        case .messageReceived(let message):
            _ = didReceiveTransportMessageSynchronously(message)

        case let .publicMessageReceived(
            peerID,
            nickname,
            content,
            timestamp,
            messageID
        ):
            transportEventCoordinator.didReceivePublicMessageSynchronously(
                from: peerID,
                nickname: nickname,
                content: content,
                timestamp: timestamp,
                messageID: messageID
            )

        case let .noisePayloadReceived(peerID, type, payload, timestamp):
            transportEventCoordinator.didReceiveNoisePayloadSynchronously(
                from: peerID,
                type: type,
                payload: payload,
                timestamp: timestamp
            )

        case .peerConnected(let peerID):
            transportEventCoordinator.didConnectToPeerSynchronously(peerID)

        case .peerDisconnected(let peerID):
            transportEventCoordinator.didDisconnectFromPeerSynchronously(peerID)

        case .peerListUpdated(let peers):
            peerListCoordinator.didUpdatePeerListSynchronously(peers)
            // A peer-list update follows every verified announce, which is
            // where a peer's `.vouch` capability actually arrives.
            vouchCoordinator.peersUpdated(peers)

        case .peerSnapshotsUpdated:
            break

        case let .messageDeliveryStatusUpdated(messageID, status):
            deliveryCoordinator.didUpdateMessageDeliveryStatus(
                messageID,
                status: status
            )

        case .bluetoothStateUpdated(let state):
            updateBluetoothState(state)
        case .noiseIdentityAvailabilityUpdated(let availability):
            noiseIdentityAvailability = availability
            if availability == .available { noiseIdentityRetryFailed = false }
        }
    }

    @MainActor
    func didReceiveTransportMessageSynchronously(_ message: BitchatMessage) -> Bool {
        transportEventCoordinator.didReceiveMessageSynchronously(message)
    }

    func didReceiveMessage(_ message: BitchatMessage) {
        transportEventCoordinator.didReceiveMessage(message)
    }

    // Low-level BLE events
    func didReceiveNoisePayload(from peerID: PeerID, type: NoisePayloadType, payload: Data, timestamp: Date) {
        transportEventCoordinator.didReceiveNoisePayload(
            from: peerID,
            type: type,
            payload: payload,
            timestamp: timestamp
        )
    }

    func didReceivePublicMessage(from peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?) {
        transportEventCoordinator.didReceivePublicMessage(
            from: peerID,
            nickname: nickname,
            content: content,
            timestamp: timestamp,
            messageID: messageID
        )
    }

    // MARK: - QR Verification API
    @MainActor
    func beginQRVerification(with qr: VerificationService.VerificationQR) -> Bool {
        verificationCoordinator.beginQRVerification(with: qr)
    }

    // Mention parsing moved from BLE – use the existing non-optional helper below
    // MARK: - Bluetooth State Monitoring

    func didUpdateBluetoothState(_ state: CBManagerState) {
        Task { @MainActor in
            updateBluetoothState(state)
        }
    }

    // MARK: - Peer Connection Events

    func didConnectToPeer(_ peerID: PeerID) {
        transportEventCoordinator.didConnectToPeer(peerID)
    }

    func didDisconnectFromPeer(_ peerID: PeerID) {
        transportEventCoordinator.didDisconnectFromPeer(peerID)
    }

    func didUpdatePeerList(_ peers: [PeerID]) {
        peerListCoordinator.didUpdatePeerList(peers)
        // A peer-list update follows every verified announce, which is where a
        // peer's `.vouch` capability actually arrives — retry vouching now that
        // capabilities may finally be known (closes the auth-time capability race).
        Task { @MainActor [weak self] in
            self?.vouchCoordinator.peersUpdated(peers)
        }
    }

    @MainActor
    func cleanupOldReadReceipts() {
        deliveryCoordinator.cleanupOldReadReceipts()
        auditConversationStore()
    }

    /// Periodic on-device verification of the `ConversationStore`'s
    /// correctness invariants, piggybacked on the read-receipt cleanup
    /// cadence (peer-list updates) so no extra timer exists. Loud on
    /// violation (one error line each), near-silent when healthy (sampled
    /// heartbeat: first + every Nth audit). The audit is O(total messages)
    /// and allocation-free while healthy — measured ~0.5 ms at 5k messages
    /// (see `PerformanceBaselineTests.testConversationStoreAudit`), cheap
    /// relative to its cadence, so it always runs.
    @MainActor
    private func auditConversationStore() {
        storeAuditCount += 1
        let violations = conversations.auditInvariants()
        guard violations.isEmpty else {
            for violation in violations {
                SecureLogger.error("🚨 ConversationStore invariant violated: \(violation)", category: .session)
            }
            return
        }
        let appendCount = conversations.appendCount
        if storeAuditCount == 1 || storeAuditCount.isMultiple(of: TransportConfig.conversationStoreAuditLogInterval) {
            SecureLogger.debug(
                "Store audit OK: \(conversations.conversationsByID.count) conversations, \(conversations.totalMessageCount) messages, map=\(conversations.messageIDMapCount), appends since last audit=\(appendCount - storeAuditLastAppendCount)",
                category: .session
            )
        }
        storeAuditLastAppendCount = appendCount
    }

    func parseMentions(from content: String) -> [String] {
        composerCoordinator.parseMentions(from: content)
    }

    func isFavorite(fingerprint: String) -> Bool {
        return identityManager.isFavorite(fingerprint: fingerprint)
    }

    // MARK: - Delivery Tracking

    func didReceiveReadReceipt(_ receipt: ReadReceipt) {
        performDeliveryUpdate { coordinator in
            coordinator.didReceiveReadReceipt(receipt)
        }
    }

    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        performDeliveryUpdate { coordinator in
            coordinator.didUpdateMessageDeliveryStatus(messageID, status: status)
        }
    }

    // MARK: - Helper for System Messages
    func addSystemMessage(_ content: String, timestamp: Date = Date()) {
        publicConversationCoordinator.addSystemMessage(content, timestamp: timestamp)
    }

    /// Add a system message to the mesh timeline only (never geohash).
    /// If mesh is currently active, also append to the visible `messages`.
    @MainActor
    func addMeshOnlySystemMessage(_ content: String) {
        publicConversationCoordinator.addMeshOnlySystemMessage(content)
    }

    /// Public helper to add a system message to the public chat timeline.
    /// Also persists the message into the active channel's backing store so it survives timeline rebinds.
    @MainActor
    func addPublicSystemMessage(_ content: String) {
        publicConversationCoordinator.addPublicSystemMessage(content)
    }

    // Send a public message without adding a local user echo.
    // Used for emotes where we want a local system-style confirmation instead.
    @MainActor
    func sendPublicRaw(_ content: String) {
        publicConversationCoordinator.sendPublicRaw(content)
    }

    // Send a normal public message (with local echo) to the active channel.
    // CommandContextProvider hook for commands that post real messages
    // (`/pay`); only called when no private chat is selected.
    @MainActor
    func sendPublicMessage(_ content: String) {
        sendMessage(content)
    }

    /// Handle incoming public message
    @MainActor
    func handlePublicMessage(_ message: BitchatMessage) {
        publicConversationCoordinator.handlePublicMessage(message)
    }

    /// Handle an incoming public Nostr message with its validated NIP-13
    /// difficulty; sufficient PoW relaxes the per-sender rate limit.

    /// Check for mentions and send notifications
    func checkForMentions(_ message: BitchatMessage) {
        publicConversationCoordinator.checkForMentions(message)
    }

    /// Send haptic feedback for special messages (iOS only)
    func sendHapticFeedback(for message: BitchatMessage) {
        publicConversationCoordinator.sendHapticFeedback(for: message)
    }
}

// End of ChatViewModel class
