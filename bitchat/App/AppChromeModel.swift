import BitFoundation
import Combine
import CoreBluetooth
import Foundation

@MainActor
final class AppChromeModel: ObservableObject {
    @Published private(set) var hasUnreadPrivateMessages = false
    @Published var nickname: String
    @Published var showingFingerprintFor: PeerID?
    @Published var isAppInfoPresented = false
    /// When the sheet is opened for "notes left here" (empty mesh timeline),
    /// it should land on the geo tab instead of the channel-derived default.
    @Published var showBluetoothAlert = false
    @Published var bluetoothAlertMessage = ""
    @Published var bluetoothState: CBManagerState = .unknown
    @Published private(set) var noiseIdentityAvailability: NoiseIdentityAvailability = .available
    @Published private(set) var isRecoveringNoiseIdentity = false
    @Published private(set) var noiseIdentityRetryFailed = false
    /// Tor bootstrap has stalled (network likely blocks it); drives the
    /// connectivity banner. Mirrored from `ChatViewModel.torBlocked`.
    @Published private(set) var torBlocked = false
    /// Triple-tapping the logo asks first; the dialog lives on the header.
    @Published var showPanicConfirmation = false
    /// Mirrors `ChatViewModel.panicRecoveryBlocked` for the chrome: a wipe
    /// that did not commit must be visible, not just logged — the person who
    /// triggered it needs to know data may remain on the device.
    @Published private(set) var panicWipeBlocked = false

    private let chatViewModel: ChatViewModel
    private let onPanicWipe: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(
        chatViewModel: ChatViewModel,
        privateInboxModel: PrivateInboxModel,
        onPanicWipe: @escaping () -> Void = {}
    ) {
        self.chatViewModel = chatViewModel
        self.onPanicWipe = onPanicWipe
        self.nickname = chatViewModel.nickname
        self.noiseIdentityAvailability = chatViewModel.noiseIdentityAvailability

        bind(privateInboxModel: privateInboxModel)
    }

    var shouldSuppressScreenshotNotification: Bool {
        isAppInfoPresented
    }

    func retryNoiseIdentityRecovery() {
        chatViewModel.retryNoiseIdentityRecovery()
    }

    func setNickname(_ nickname: String) {
        self.nickname = nickname
        if chatViewModel.nickname != nickname {
            chatViewModel.nickname = nickname
        }
    }

    func validateAndSaveNickname() {
        chatViewModel.validateAndSaveNickname()
        if nickname != chatViewModel.nickname {
            nickname = chatViewModel.nickname
        }
    }

    func showFingerprint(for peerID: PeerID) {
        showingFingerprintFor = peerID
    }

    func clearFingerprint() {
        showingFingerprintFor = nil
    }

    func presentAppInfo() {
        isAppInfoPresented = true
    }

    /// Entry point for the header triple-tap: confirm before destroying.
    /// The Settings-pane button has always confirmed; the gesture now goes
    /// through the same dialog so a mis-tap can't wipe the device.
    func requestPanicWipe() {
        showPanicConfirmation = true
    }

    @discardableResult
    func panicClearAllData() -> Bool {
        showPanicConfirmation = false
        // A wipe invalidates everything on screen, and its outcome must be
        // visible: the success message and the failed-wipe banner both live
        // on the root timeline, so a sheet left up (the App Info danger-zone
        // path keeps its sheet presented) would hide the one signal that says
        // whether the wipe worked.
        isAppInfoPresented = false
        showingFingerprintFor = nil

        onPanicWipe()
        // Wesh: Bluetooth stays off until the welcome and its terms are accepted again, so the new
        // identity announces nothing before (`AppRuntime.welcomeFinished`).
        return chatViewModel.panicClearAllData(restartMesh: !WeshMode.isActive)
    }

    private func bind(privateInboxModel: PrivateInboxModel) {
        privateInboxModel.$unreadPeerIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] unreadPeerIDs in
                self?.hasUnreadPrivateMessages = !unreadPeerIDs.isEmpty
            }
            .store(in: &cancellables)

        chatViewModel.$nickname
            .receive(on: DispatchQueue.main)
            .sink { [weak self] nickname in
                guard let self, self.nickname != nickname else { return }
                self.nickname = nickname
            }
            .store(in: &cancellables)

        chatViewModel.$showBluetoothAlert
            .receive(on: DispatchQueue.main)
            .assign(to: &$showBluetoothAlert)

        chatViewModel.$bluetoothAlertMessage
            .receive(on: DispatchQueue.main)
            .assign(to: &$bluetoothAlertMessage)

        chatViewModel.$bluetoothState
            .receive(on: DispatchQueue.main)
            .assign(to: &$bluetoothState)

        chatViewModel.$noiseIdentityAvailability
            .receive(on: DispatchQueue.main)
            .assign(to: &$noiseIdentityAvailability)
        chatViewModel.$isRecoveringNoiseIdentity
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRecoveringNoiseIdentity)
        chatViewModel.$noiseIdentityRetryFailed
            .receive(on: DispatchQueue.main)
            .assign(to: &$noiseIdentityRetryFailed)

        chatViewModel.$torBlocked
            .receive(on: DispatchQueue.main)
            .assign(to: &$torBlocked)

        chatViewModel.$panicRecoveryBlocked
            .receive(on: DispatchQueue.main)
            .assign(to: &$panicWipeBlocked)

        hasUnreadPrivateMessages = !privateInboxModel.unreadPeerIDs.isEmpty
    }
}
