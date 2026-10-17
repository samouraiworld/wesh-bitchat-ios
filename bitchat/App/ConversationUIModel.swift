import BitFoundation
import Combine
import SwiftUI

@MainActor
final class ConversationUIModel: ObservableObject {
    @Published private(set) var showAutocomplete = false
    @Published private(set) var autocompleteSuggestions: [String] = []
    @Published private(set) var selectedAutocompleteIndex = 0
    @Published private(set) var currentNickname: String
    @Published private(set) var isBatchingPublic = false
    @Published private(set) var canSendMediaInCurrentContext = true
    @Published private(set) var legacyPrivateMediaConsentRequest: LegacyPrivateMediaConsentRequest?

    private let chatViewModel: ChatViewModel
    private let privateConversationModel: PrivateConversationModel
    private let conversations: ConversationStore
    private var activeChannel: ChannelID
    private var cancellables = Set<AnyCancellable>()

    init(
        chatViewModel: ChatViewModel,
        privateConversationModel: PrivateConversationModel,
        conversations: ConversationStore
    ) {
        self.chatViewModel = chatViewModel
        self.privateConversationModel = privateConversationModel
        self.conversations = conversations
        self.activeChannel = conversations.activeChannel
        self.currentNickname = chatViewModel.nickname
        self.isBatchingPublic = chatViewModel.isBatchingPublic
        self.showAutocomplete = chatViewModel.showAutocomplete
        self.autocompleteSuggestions = chatViewModel.autocompleteSuggestions
        self.selectedAutocompleteIndex = chatViewModel.selectedAutocompleteIndex
        self.canSendMediaInCurrentContext = chatViewModel.canSendMediaInCurrentContext

        bind()
    }

    func sendMessage(_ message: String) {
        chatViewModel.sendMessage(message)
    }

    func block(peerID: PeerID?, displayName: String?) {
        guard let displayName else { return }

        if let peerID, peerID.isGeoChat,
           let full = chatViewModel.fullNostrHex(forSenderPeerID: peerID) {
            chatViewModel.blockGeohashUser(pubkeyHexLowercased: full, displayName: displayName)
        } else if let peerID, !peerID.isGeoDM, !peerID.isGeoChat {
            // Mesh: block the peer's stable Noise identity resolved from the
            // tapped peerID rather than re-resolving a display-name string.
            chatViewModel.blockMeshPeer(peerID: peerID, displayName: displayName)
        } else {
            chatViewModel.sendMessage("/block \(displayName)")
        }
    }

    private func bind() {
        chatViewModel.$nickname
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentNickname)

        chatViewModel.$showAutocomplete
            .receive(on: DispatchQueue.main)
            .assign(to: &$showAutocomplete)

        chatViewModel.$autocompleteSuggestions
            .receive(on: DispatchQueue.main)
            .assign(to: &$autocompleteSuggestions)

        chatViewModel.$selectedAutocompleteIndex
            .receive(on: DispatchQueue.main)
            .assign(to: &$selectedAutocompleteIndex)

        chatViewModel.$isBatchingPublic
            .receive(on: DispatchQueue.main)
            .assign(to: &$isBatchingPublic)

        chatViewModel.$legacyPrivateMediaConsentRequest
            .receive(on: DispatchQueue.main)
            .assign(to: &$legacyPrivateMediaConsentRequest)

        conversations.$activeChannel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] channel in
                self?.activeChannel = channel
                self?.refreshComputedState()
            }
            .store(in: &cancellables)

        privateConversationModel.$selectedPeerID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshComputedState()
            }
            .store(in: &cancellables)
    }

    private func refreshComputedState() {
        if let selectedPeerID = privateConversationModel.selectedPeerID {
            canSendMediaInCurrentContext = !(selectedPeerID.isGeoDM || selectedPeerID.isGeoChat)
            return
        }

        switch activeChannel {
        case .mesh:
            canSendMediaInCurrentContext = true
        case .location:
            canSendMediaInCurrentContext = false
        }
    }
}
