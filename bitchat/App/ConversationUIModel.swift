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

    private let chatViewModel: ChatViewModel
    private var cancellables = Set<AnyCancellable>()

    init(chatViewModel: ChatViewModel) {
        self.chatViewModel = chatViewModel
        self.currentNickname = chatViewModel.nickname
        self.isBatchingPublic = chatViewModel.isBatchingPublic
        self.showAutocomplete = chatViewModel.showAutocomplete
        self.autocompleteSuggestions = chatViewModel.autocompleteSuggestions
        self.selectedAutocompleteIndex = chatViewModel.selectedAutocompleteIndex

        bind()
    }

    func setCurrentColorScheme(_ colorScheme: ColorScheme) {
        chatViewModel.currentColorScheme = colorScheme
    }

    func setCurrentTheme(_ theme: AppTheme) {
        chatViewModel.currentTheme = theme
    }

    func sendMessage(_ message: String) {
        chatViewModel.sendMessage(message)
    }

    /// Resends a failed private message through the normal send path,
    /// removing the failed original so the re-submission replaces it
    /// instead of stacking a duplicate under the red bubble.
    func resendFailedPrivateMessage(_ message: BitchatMessage) {
        chatViewModel.removePrivateMessage(withID: message.id)
        chatViewModel.sendMessage(message.content)
    }

    func clearCurrentConversation() {
        chatViewModel.sendMessage("/clear")
    }

    func sendHug(to sender: String) {
        chatViewModel.sendMessage("/hug @\(sender)")
    }

    func sendSlap(to sender: String) {
        chatViewModel.sendMessage("/slap @\(sender)")
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

    /// Mesh counterpart of `block(peerID:displayName:)`. Resolves the unblock by
    /// the tapped peer's stable identity so the exact row is unblocked — this
    /// also works for offline peers, which the `/unblock <displayName>` command
    /// cannot resolve.
    func unblock(peerID: PeerID, displayName: String) {
        chatViewModel.unblockMeshPeer(peerID: peerID, displayName: displayName)
    }

    func getFingerprint(for peerID: PeerID) -> String? {
        chatViewModel.getFingerprint(for: peerID)
    }

    func updateAutocomplete(for text: String, cursorPosition: Int) {
        chatViewModel.updateAutocomplete(for: text, cursorPosition: cursorPosition)
    }

    func completeNickname(_ nickname: String, in text: inout String) -> Int {
        chatViewModel.completeNickname(nickname, in: &text)
    }

    /// Accept the currently highlighted mention suggestion, if any.
    func completeSelectedSuggestion(in text: inout String) -> Bool {
        guard showAutocomplete,
              autocompleteSuggestions.indices.contains(selectedAutocompleteIndex)
        else { return false }
        _ = completeNickname(autocompleteSuggestions[selectedAutocompleteIndex], in: &text)
        return true
    }

    /// Dismiss the mention suggestion panel without inserting (Escape).
    func dismissAutocomplete() {
        guard showAutocomplete else { return }
        chatViewModel.showAutocomplete = false
        chatViewModel.autocompleteSuggestions = []
        chatViewModel.autocompleteRange = nil
        chatViewModel.selectedAutocompleteIndex = 0
    }

    func moveAutocompleteSelection(by delta: Int) {
        guard showAutocomplete, !autocompleteSuggestions.isEmpty else { return }
        let count = min(4, autocompleteSuggestions.count)
        let next = (selectedAutocompleteIndex + delta + count) % count
        chatViewModel.selectedAutocompleteIndex = next
    }

    func formatMessage(_ message: BitchatMessage, colorScheme: ColorScheme, theme: AppTheme? = nil) -> AttributedString {
        chatViewModel.formatMessageAsText(message, colorScheme: colorScheme, theme: theme)
    }

    func formatMessageHeader(_ message: BitchatMessage, colorScheme: ColorScheme, theme: AppTheme? = nil) -> AttributedString {
        chatViewModel.formatMessageHeader(message, colorScheme: colorScheme, theme: theme)
    }

    func isSelfSender(peerID: PeerID?, displayName: String?) -> Bool {
        chatViewModel.isSelfSender(peerID: peerID, displayName: displayName)
    }

    func isSentByCurrentUser(_ message: BitchatMessage) -> Bool {
        message.sender == currentNickname || message.sender.hasPrefix(currentNickname + "#")
    }

    /// Whether a private-message row should show the filled verification seal
    /// next to the sender name (#1439). Scoped to DMs only — public timelines
    /// have different trust semantics and stay undressed.
    func showsVerifiedSeal(for message: BitchatMessage) -> Bool {
        guard message.isPrivate,
              message.sender != "system",
              !isSentByCurrentUser(message),
              let peerID = message.senderPeerID else { return false }
        guard let fingerprint = chatViewModel.getFingerprint(for: peerID) else { return false }
        return chatViewModel.peerIdentityStore.isVerified(fingerprint)
    }

    func senderDisplayName(for peerID: PeerID, fallbackMessages: [BitchatMessage]) -> String? {
        if peerID.isGeoDM || peerID.isGeoChat {
            return chatViewModel.geohashDisplayName(for: peerID)
        }
        if let nickname = chatViewModel.meshService.peerNickname(peerID: peerID) {
            return nickname
        }
        return fallbackMessages.last(where: { $0.senderPeerID == peerID && $0.sender != "system" })?.sender
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

        // Verify/unverify while a DM is open must repaint existing rows —
        // showsVerifiedSeal is computed per render, so forward the store change.
        chatViewModel.peerIdentityStore.$verifiedFingerprints
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
}
