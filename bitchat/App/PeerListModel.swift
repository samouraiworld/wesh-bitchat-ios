import BitFoundation
import Combine
import SwiftUI

struct MeshPeerRow: Identifiable, Equatable {
    let peerID: PeerID
    let displayName: String
    let isMe: Bool
    let hasUnread: Bool
    let isBlocked: Bool
    let isFavorite: Bool
    let isConnected: Bool
    let isReachable: Bool
    let showsVerifiedBadgeWhenOffline: Bool

    var id: String { peerID.id }
}

/// A direct conversation whose person is NOT in any roster above it. Without
/// this section, a DM from a passerby became unreachable the moment they went
/// offline: the roster filters to connected/reachable/mutual-favorite, the
/// header envelope only exists while unread, and /msg can't resolve offline
/// strangers — the thread was still in memory with no row anywhere in the UI.
struct RecentChatRow: Identifiable, Equatable {
    let peerID: PeerID
    let displayName: String
    let hasUnread: Bool
    let lastActivity: Date

    var id: String { peerID.id }
}

@MainActor
final class PeerListModel: ObservableObject {
    @Published private(set) var allPeers: [BitchatPeer] = []
    @Published private(set) var meshRows: [MeshPeerRow] = []
    @Published private(set) var recentChatRows: [RecentChatRow] = []
    @Published private(set) var reachableMeshPeerCount = 0
    @Published private(set) var connectedMeshPeerCount = 0
    @Published private(set) var renderID = ""

    private let chatViewModel: ChatViewModel
    private let conversations: ConversationStore
    private let peerIdentityStore: PeerIdentityStore
    private var cancellables = Set<AnyCancellable>()

    init(
        chatViewModel: ChatViewModel,
        conversations: ConversationStore,
        peerIdentityStore: PeerIdentityStore? = nil
    ) {
        self.chatViewModel = chatViewModel
        self.conversations = conversations
        self.peerIdentityStore = peerIdentityStore ?? chatViewModel.peerIdentityStore
        self.allPeers = chatViewModel.allPeers

        bind()
        refresh()
    }

    private func bind() {
        chatViewModel.$allPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                self?.allPeers = peers
                self?.refresh()
            }
            .store(in: &cancellables)

        chatViewModel.$nickname
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        conversations.$unreadConversations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        // Direct-conversation changes reorder or create recent-chat rows.
        // Filtered to `.direct` so public-timeline traffic (every mesh or
        // geohash message emits a change) doesn't rebuild the sheet.
        conversations.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard case .direct = Self.changedConversationID(change) else { return }
                self?.refresh()
            }
            .store(in: &cancellables)

        peerIdentityStore.$encryptionStatuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        peerIdentityStore.$verifiedFingerprints
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Notification.Name("peerStatusUpdated"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

    }

    private func refresh() {
        let myPeerID = chatViewModel.meshService.myPeerID
        let meshRows = allPeers.map { peer in
            let isMe = peer.peerID == myPeerID
            let fingerprint = isMe ? nil : chatViewModel.getFingerprint(for: peer.peerID)
            let isVerifiedFingerprint = fingerprint.map { peerIdentityStore.isVerified($0) } ?? false
            let verifiedBadge = !peer.isConnected && isVerifiedFingerprint

            return MeshPeerRow(
                peerID: peer.peerID,
                displayName: isMe ? chatViewModel.nickname : peer.displayName,
                isMe: isMe,
                hasUnread: chatViewModel.hasUnreadMessages(for: peer.peerID),
                isBlocked: !isMe && chatViewModel.isPeerBlocked(peer.peerID),
                isFavorite: peer.favoriteStatus?.isFavorite ?? false,
                isConnected: peer.isConnected,
                isReachable: peer.isReachable,
                showsVerifiedBadgeWhenOffline: verifiedBadge
            )
        }

        let meshCounts = meshRows.reduce(into: (reachable: 0, connected: 0)) { counts, row in
            guard !row.isMe else { return }
            if row.isConnected {
                counts.connected += 1
                counts.reachable += 1
            } else if row.isReachable {
                counts.reachable += 1
            }
        }

        let recentChatRows = buildRecentChatRows(meshRows: meshRows)

        self.meshRows = meshRows
        reachableMeshPeerCount = meshCounts.reachable
        connectedMeshPeerCount = meshCounts.connected
        self.recentChatRows = recentChatRows
        renderID = (
            meshRows.map {
                "\($0.id)-\($0.displayName)-\($0.isConnected)-\($0.isReachable)-\($0.hasUnread)-\($0.isFavorite)-\($0.isBlocked)"
            } +
            recentChatRows.map {
                "chat:\($0.id)-\($0.displayName)-\($0.hasUnread)"
            }
        ).joined(separator: "|")
    }

    /// Direct conversations with people absent from the rosters above:
    /// the offline passerby DM, the geoDM from a channel since left. Rows
    /// mirrored under both an ephemeral and a stable peer ID collapse to
    /// one row per identity (newest activity wins), matching how the
    /// private-chat coordinators consolidate on open.
    private func buildRecentChatRows(
        meshRows: [MeshPeerRow]
    ) -> [RecentChatRow] {
        // A conversation can be keyed by the stable Noise peer ID while the
        // roster lists the ephemeral one — compare fingerprints too.
        var visibleIdentities = Set<String>()
        for row in meshRows {
            visibleIdentities.insert(row.peerID.id)
            if let fingerprint = chatViewModel.getFingerprint(for: row.peerID) {
                visibleIdentities.insert(fingerprint)
            }
        }
        // Someone visible in the geohash section must not also get a chat
        // row: their GeoDM conversation is keyed by the nostr_ form of the
        // same pubkey the roster lists.

        struct Candidate {
            let peerID: PeerID
            let lastActivity: Date
        }
        var bestByIdentity: [String: Candidate] = [:]

        for (id, conversation) in conversations.conversationsByID {
            guard case .direct(let handle) = id else { continue }
            let peerID = handle.routingPeerID
            // Blocked people get no row.
            guard let lastMessage = conversation.messages.last else { continue }
            guard !chatViewModel.isPeerBlocked(peerID) else { continue }

            let fingerprint = chatViewModel.getFingerprint(for: peerID)
            if visibleIdentities.contains(peerID.id) { continue }
            if let fingerprint, visibleIdentities.contains(fingerprint) { continue }

            let identityKey = fingerprint ?? peerID.id
            if let existing = bestByIdentity[identityKey],
               existing.lastActivity >= lastMessage.timestamp {
                continue
            }
            bestByIdentity[identityKey] = Candidate(peerID: peerID, lastActivity: lastMessage.timestamp)
        }

        return bestByIdentity.values
            .sorted { $0.lastActivity > $1.lastActivity }
            .map { candidate in
                RecentChatRow(
                    peerID: candidate.peerID,
                    displayName: displayName(for: candidate.peerID),
                    hasUnread: chatViewModel.hasUnreadMessages(for: candidate.peerID),
                    lastActivity: candidate.lastActivity
                )
            }
    }

    /// GeoDM conversations resolve through the Nostr mapping —
    /// `resolveNickname` only consults mesh identity sources and would
    /// render a `nostr_…` key as an opaque `anonnost` fallback.
    private func displayName(for peerID: PeerID) -> String {
        if peerID.isGeoDM {
            return peerID.bare
        }
        return chatViewModel.resolveNickname(for: peerID)
    }

    private static func changedConversationID(_ change: ConversationChange) -> ConversationID {
        switch change {
        case .appended(let id, _),
             .updated(let id, _),
             .statusChanged(let id, _, _),
             .messageRemoved(let id, _),
             .cleared(let id),
             .removed(let id),
             .unreadChanged(let id, _):
            return id
        case .migrated(_, let to):
            return to
        }
    }

}
