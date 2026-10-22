import BitFoundation
import Combine
import Foundation

struct FingerprintPresentationState: Equatable {
    let peerNickname: String
    let theirFingerprint: String?
    let myFingerprint: String
}

enum VerificationScanOutcome: Equatable {
    case requested(String)
    case notFound
    case invalid
}

@MainActor
final class VerificationModel: ObservableObject {
    @Published private(set) var currentNickname: String
    @Published private(set) var selectedPeerID: PeerID?

    private let chatViewModel: ChatViewModel
    private let peerIdentityStore: PeerIdentityStore
    private var cancellables = Set<AnyCancellable>()

    init(
        chatViewModel: ChatViewModel,
        privateConversationModel: PrivateConversationModel,
        peerIdentityStore: PeerIdentityStore? = nil
    ) {
        self.chatViewModel = chatViewModel
        self.peerIdentityStore = peerIdentityStore ?? chatViewModel.peerIdentityStore
        self.currentNickname = chatViewModel.nickname
        self.selectedPeerID = privateConversationModel.selectedPeerID

        bind(privateConversationModel: privateConversationModel)
    }

    func myQRString() -> String {
        guard WeshMode.isActive else {
            let npub = try? chatViewModel.idBridge.getCurrentNostrIdentity()?.npub
            return VerificationService.shared.buildMyQRString(nickname: currentNickname, npub: npub) ?? ""
        }
        // Read-only: showing a QR never creates Nostr key material.
        let bridge = chatViewModel.idBridge
        guard let identity = WeshQRNpub.identityForMyQR(
            panicFenced: !chatViewModel.networkActivationAllowed,
            storedIdentity: { try? bridge.storedNostrIdentity() }
        ) else {
            return VerificationService.shared.buildMyQRString(nickname: currentNickname, npub: nil) ?? ""
        }
        return VerificationService.shared.buildMyQRString(
            nickname: currentNickname, npub: identity.npub,
            npubSigner: { WeshQRNpub.signProof(canonicalBytes: $0, identity: identity) }
        ) ?? ""
    }

    func verifyScannedPayload(_ payload: String) -> VerificationScanOutcome {
        guard let qr = VerificationService.shared.verifyScannedQR(payload) else {
            return .invalid
        }

        guard chatViewModel.beginQRVerification(with: qr) else {
            return .notFound
        }

        return .requested(qr.nickname)
    }

    func verifyFingerprint(for peerID: PeerID) {
        chatViewModel.verifyFingerprint(for: peerID)
    }

    func unverifyFingerprint(for peerID: PeerID) {
        chatViewModel.unverifyFingerprint(for: peerID)
    }

    func isVerified(peerID: PeerID) -> Bool {
        guard let fingerprint = chatViewModel.getFingerprint(for: peerID) else { return false }
        return peerIdentityStore.isVerified(fingerprint)
    }

    func fingerprintPresentation(for peerID: PeerID) -> FingerprintPresentationState {
        let statusPeerID = chatViewModel.getShortIDForNoiseKey(peerID)
        let theirFingerprint = chatViewModel.getFingerprint(for: statusPeerID)
        let peerNickname = resolveDisplayName(for: peerID, statusPeerID: statusPeerID)

        return FingerprintPresentationState(
            peerNickname: peerNickname,
            theirFingerprint: theirFingerprint,
            myFingerprint: chatViewModel.getMyFingerprint()
        )
    }

    private func bind(privateConversationModel: PrivateConversationModel) {
        chatViewModel.$nickname
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentNickname)

        privateConversationModel.$selectedPeerID
            .receive(on: DispatchQueue.main)
            .assign(to: &$selectedPeerID)

        peerIdentityStore.$encryptionStatuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        peerIdentityStore.$verifiedFingerprints
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        chatViewModel.$allPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    private func resolveDisplayName(for peerID: PeerID, statusPeerID: PeerID) -> String {
        // Prefer an explicit local alias even when a live peer row exists —
        // peer.displayName already does this once UnifiedPeerService rebuilds,
        // but read social identity directly so the fingerprint sheet header
        // updates before that rebuild lands.
        if let fingerprint = chatViewModel.getFingerprint(for: statusPeerID),
           let pet = chatViewModel.identityManager.getSocialIdentity(for: fingerprint)?.localPetname,
           !pet.isEmpty {
            return pet
        }
        if let peer = chatViewModel.getPeer(byID: statusPeerID) {
            return peer.displayName
        }
        if let name = chatViewModel.meshService.peerNickname(peerID: statusPeerID) {
            return name
        }
        if let data = peerID.noiseKey {
            if let favorite = FavoritesPersistenceService.shared.getFavoriteStatus(for: data),
               !favorite.peerNickname.isEmpty {
                return favorite.peerNickname
            }
            let fingerprint = data.sha256Fingerprint()
            if let social = chatViewModel.identityManager.getSocialIdentity(for: fingerprint) {
                if !social.claimedNickname.isEmpty {
                    return social.claimedNickname
                }
            }
        }

        return String(localized: "common.unknown", comment: "Label for an unknown peer")
    }
}
