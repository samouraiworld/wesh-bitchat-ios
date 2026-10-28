import BitFoundation
import Combine
import Foundation
import SwiftUI
import Tor
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
final class AppRuntime: ObservableObject {
    let chatViewModel: ChatViewModel
    let events = AppEventStream()
    /// Single source of truth for conversation message state and selection
    /// (docs/CONVERSATION-STORE-DESIGN.md). Owned here; the feature models
    /// and `ChatViewModel` observe and mutate it through its intent API.
    let conversations: ConversationStore
    let publicChatModel: PublicChatModel
    let privateInboxModel: PrivateInboxModel
    let privateConversationModel: PrivateConversationModel
    let verificationModel: VerificationModel
    let conversationUIModel: ConversationUIModel
    let peerListModel: PeerListModel
    let appChromeModel: AppChromeModel
    let composerDrafts = ComposerDraftStore.repository

    private var cancellables = Set<AnyCancellable>()
    private var started = false
    var hasStarted: Bool { started }
    private var weshInternetStarted = false
    private var lastNostrRelayConnectedState = false

    #if os(iOS)
    private var didHandleInitialActive = false
    private var didEnterBackground = false
    #endif

    init(
        keychain: KeychainManagerProtocol = KeychainManager.makeDefault(),
        idBridge: NostrIdentityBridge = NostrIdentityBridge(),
        sharedContentStore: SharedContentStore? = nil
    ) {
        let conversations = ConversationStore()
        let peerIdentityStore = PeerIdentityStore()
        self.conversations = conversations
        var persistentWipes = PanicPersistentStoreWipes()
        persistentWipes.sharedContent = {
            if let sharedContentStore { return sharedContentStore.discardAll() }
            if TestEnvironment.isRunningTests { return true }
            #if os(iOS)
            guard UIApplication.shared.isProtectedDataAvailable else { return false }
            #endif
            // Resolve the suite and App Group container for every attempt. A
            // transiently unavailable container at launch must not poison the
            // same-process Retry button forever.
            guard let sharedDefaults = UserDefaults(suiteName: BitchatApp.groupID) else {
                return false
            }
            return SharedContentStore(
                defaults: sharedDefaults,
                readbackDefaults: { UserDefaults(suiteName: BitchatApp.groupID) }
            ).discardAll()
        }
        self.chatViewModel = ChatViewModel(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: SecureIdentityStateManager(keychain),
            conversations: conversations,
            peerIdentityStore: peerIdentityStore,
            panicPersistentStoreWipes: persistentWipes
        )
        self.publicChatModel = PublicChatModel(conversations: conversations)
        self.privateInboxModel = PrivateInboxModel(conversations: conversations)
        self.privateConversationModel = PrivateConversationModel(
            chatViewModel: self.chatViewModel,
            conversations: conversations,
            peerIdentityStore: peerIdentityStore
        )
        self.verificationModel = VerificationModel(
            chatViewModel: self.chatViewModel,
            privateConversationModel: self.privateConversationModel,
            peerIdentityStore: peerIdentityStore
        )
        self.conversationUIModel = ConversationUIModel(chatViewModel: self.chatViewModel)
        self.peerListModel = PeerListModel(
            chatViewModel: self.chatViewModel,
            conversations: conversations,
            peerIdentityStore: peerIdentityStore
        )
        self.appChromeModel = AppChromeModel(
            chatViewModel: self.chatViewModel,
            privateInboxModel: self.privateInboxModel
        )
        configureComposerDrafts()
        bindRuntimeObservers()
        NotificationDelegate.shared.runtime = self
    }

    /// The welcome's Bluetooth step: the system prompt appears now, not at launch.
    func allowBluetoothPrompt() {
        (chatViewModel.meshService as? BLEService)?.allowBluetoothPrompt()
    }

    /// The welcome ended with the terms accepted: the notification prompt, then the Internet mode
    /// (still off unless the person had turned it on).
    func welcomeFinished() {
        NotificationService.shared.requestAuthorization()
        guard WeshMode.isActive, chatViewModel.networkActivationAllowed else { return }
        // The key my QR shows from now on, Internet on or off.
        chatViewModel.ensureWeshNostrIdentity(welcomeDone: true)
        // After a wipe the mesh stayed stopped through the welcome (`AppChromeModel.panicClearAllData`),
        // also when the runtime never started because a wipe had to be resumed by hand.
        chatViewModel.meshService.startServices()
        guard started else { return }
        NetworkActivationService.shared.setUserInternetEnabled(WeshInternetSettings.isEnabled())
        startWeshInternet()
    }

    private func startWeshInternet() {
        guard !weshInternetStarted else { return }
        weshInternetStarted = true
        WeshInternetMode.shared.start()
        // Queued private messages to QR contacts leave as soon as Internet is On.
        WeshInternetRoute.flushWhenOn(WeshInternetMode.shared.$state) { [weak self] in
            self?.chatViewModel.messageRouter.flushAllOutbox()
        }
        .store(in: &cancellables)
    }

    func panicEraseAction(report: @escaping (Bool) -> Void = { _ in }) -> () -> Bool {
        makePanicEraseAction(
            erase: { self.appChromeModel.panicClearAllData() },
            report: report,
            needsBootstrap: { !self.chatViewModel.bootstrapConfigured },
            bootstrap: { self.chatViewModel.configureBootstrapIfNeeded() },
            needsRuntimeStart: { !self.hasStarted },
            startRuntime: { self.start() }
        )
    }

    func retryStartupRetirement() {
        guard chatViewModel.retryStartupRetirement() else { return }
        start()
    }

    @discardableResult
    func retryPendingPanicRecovery() -> Bool {
        let completed = chatViewModel.retryPendingPanicRecovery(
            restartMesh: !WeshMode.isActive
        )
        guard completed else { return false }
        chatViewModel.configureBootstrapIfNeeded()
        start()
        return true
    }

    func start() {
        guard chatViewModel.networkActivationAllowed else { return }
        guard !started else { return }

        started = true
        NotificationDelegate.shared.runtime = self
        VerificationService.shared.configure(with: chatViewModel.meshService)
        // Phones whose welcome ended before the key was made at onboarding get it now.
        if WeshMode.isActive { chatViewModel.ensureWeshNostrIdentity() }
        #if DEBUG
        // Simulator M4 only: print my identity or seed a QR contact from the launch environment.
        if WeshMode.isActive { chatViewModel.applyWeshDebugHooks() }
        #endif

        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            // Warms the QR cache through the same read-only npub rule as the sheet.
            await MainActor.run { _ = self.verificationModel.myQRString() }
        }

        #if os(macOS)
        // No scene phases and no background relaunch on macOS: a started app
        // is in the foreground. iOS reports it from `handleScenePhaseChange`.
        TorManager.shared.setAppForeground(true)
        #endif
        NetworkActivationService.shared.start()
        if WeshMode.isActive {
            // Until the welcome and its terms are accepted (again, after an update), nothing goes online.
            if WeshWelcome.isDone() { startWeshInternet() } else { WeshInternetMode.shared.clearArtiWhileOff() }
        }
        performBackupMaintenance()

        record(.launched)
        record(.startupCompleted)
    }

    /// Preserves backup exclusion for existing files. Checked legacy-media deletion
    /// runs in the preflight before transport admission, independently of this sweep.
    /// This best-effort task is skipped under tests, which share the host's file tree.
    private func performBackupMaintenance() {
        guard !TestEnvironment.isRunningTests else { return }
        Task.detached(priority: .utility) {
            #if os(iOS)
            LocalFileProtection.excludeApplicationSupportFromBackup()
            #endif
        }
    }

    func handleOpenURL(_ url: URL) {
        record(.openedURL(url.absoluteString))

        // The retired share route has no import action. Identity QR payloads
        // are still parsed in-app, independently of OS URL registration.
    }

    func handleDidBecomeActiveNotification() {
        guard chatViewModel.networkActivationAllowed else { return }
        chatViewModel.handleDidBecomeActive()
        configureComposerDrafts()
        composerDrafts.retry()
    }

    #if os(macOS)
    func handleMacDidBecomeActiveNotification() {
        guard chatViewModel.networkActivationAllowed else { return }
        record(.scenePhaseChanged(.active))
        chatViewModel.handleDidBecomeActive()
    }
    #endif

    #if os(iOS)
    func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            composerDrafts.flush()
            record(.scenePhaseChanged(.background))
            // Before Tor goes dormant, so the drop reads as Paused, not a fault.
            WeshInternetMode.shared.appDidEnterBackground()
            TorManager.shared.setAppForeground(false)
            TorManager.shared.goDormantOnBackground()
            NostrRelayManager.shared.disconnect()
            didEnterBackground = true

        case .active:
            guard chatViewModel.networkActivationAllowed else { return }
            record(.scenePhaseChanged(.active))
            // A wipe leaves the mesh stopped until the welcome ends.
            if WeshWelcome.meshMayStart() { chatViewModel.meshService.startServices() }
            TorManager.shared.setAppForeground(true)
            WeshInternetMode.shared.appWillEnterForeground()
            let shouldRefreshNostrConnections = didHandleInitialActive && didEnterBackground

            if didHandleInitialActive && didEnterBackground {
                if TorManager.shared.isAutoStartAllowed() && !TorManager.shared.isReady {
                    TorManager.shared.ensureRunningOnForeground()
                }
            } else {
                didHandleInitialActive = true
            }

            didEnterBackground = false

            if shouldRefreshNostrConnections && TorManager.shared.isAutoStartAllowed() {
                Task.detached {
                    let _ = await TorManager.shared.awaitReady(timeout: 60)
                    await MainActor.run {
                        TorURLSession.shared.rebuild()
                        NostrRelayManager.shared.resetAllConnections()
                    }
                }
            }

            chatViewModel.handleDidBecomeActive()
            configureComposerDrafts()
            composerDrafts.retry()

        case .inactive:
            record(.scenePhaseChanged(.inactive))

        @unknown default:
            break
        }
    }
    #endif

    func applicationWillTerminate() {
        composerDrafts.flush()
        record(.terminationRequested)
        chatViewModel.applicationWillTerminate()
    }

    func handleNotificationResponse(
        identifier: String,
        actionIdentifier: String = UNNotificationDefaultActionIdentifier,
        userInfo: [AnyHashable: Any]
    ) {
        guard chatViewModel.networkActivationAllowed else { return }
        if actionIdentifier == NotificationService.waveActionID {
            chatViewModel.sendMeshWave()
            return
        }

        if identifier.hasPrefix("private-"), let peerID = PeerID(str: userInfo["peerID"] as? String) {
            record(.notificationOpened(peerID: peerID))
            chatViewModel.startPrivateChat(with: peerID)
        }
    }

    func presentationOptions(
        forNotificationIdentifier identifier: String,
        userInfo: [AnyHashable: Any]
    ) async -> UNNotificationPresentationOptions {
        if identifier.hasPrefix("private-"), let peerID = PeerID(str: userInfo["peerID"] as? String) {
            if conversations.selectedPrivatePeerID == peerID {
                return []
            }
            return [.banner, .sound]
        }

        return [.banner, .sound]
    }
}

private extension AppRuntime {
    private func configureComposerDrafts() {
        guard chatViewModel.networkActivationAllowed else { return }
        ComposerDraftStore.configurePersistence(keychain: chatViewModel.keychain,
            noiseKey: chatViewModel.meshService.noiseStaticPublicKeyData())
    }

    func bindRuntimeObservers() {
        // A cleanup retried on its own (after first unlock) starts what the launch could not;
        // `start` still checks that the network is allowed.
        chatViewModel.$startupRetirementBlocked
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.start() }
            .store(in: &cancellables)
        chatViewModel.$noiseIdentityAvailability
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.configureComposerDrafts() }
            .store(in: &cancellables)
        NostrRelayManager.shared.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                self?.handleNostrRelayConnectionChanged(isConnected)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TorWillRestart)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.chatViewModel.networkActivationAllowed == true
                else { return }
                self?.record(.torLifecycleChanged(.willRestart))
                self?.chatViewModel.handleTorWillRestart()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TorDidBecomeReady)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.chatViewModel.networkActivationAllowed == true
                else { return }
                self?.record(.torLifecycleChanged(.didBecomeReady))
                self?.chatViewModel.handleTorDidBecomeReady()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TorWillStart)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.chatViewModel.networkActivationAllowed == true
                else { return }
                self?.record(.torLifecycleChanged(.willStart))
                self?.chatViewModel.handleTorWillStart()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TorBootstrapDidStall)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.chatViewModel.networkActivationAllowed == true
                else { return }
                self?.record(.torLifecycleChanged(.bootstrapDidStall))
                self?.chatViewModel.handleTorBootstrapDidStall()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .TorUserPreferenceChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard self?.chatViewModel.networkActivationAllowed == true
                else { return }
                self?.record(.torLifecycleChanged(.preferenceChanged))
                self?.chatViewModel.handleTorPreferenceChanged(notification)
            }
            .store(in: &cancellables)

        #if os(iOS)
        NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleScreenshotCaptured()
            }
            .store(in: &cancellables)
        #endif
    }

    func handleNostrRelayConnectionChanged(_ isConnected: Bool) {
        record(.nostrRelayConnectionChanged(isConnected))

        let becameConnected = isConnected && !lastNostrRelayConnectedState
        lastNostrRelayConnectedState = isConnected

        guard chatViewModel.networkActivationAllowed,
              started,
              becameConnected else { return }

        if !chatViewModel.nostrHandlersSetup {
            chatViewModel.setupNostrMessageHandling()
            chatViewModel.nostrHandlersSetup = true
        }

    }

    func handleScreenshotCaptured() {

        switch Self.resolveScreenshotResponse(
            isAppInfoPresented: appChromeModel.isAppInfoPresented,
            noticeEnabled: WeshScreenshotNotice.isEnabled()
        ) {
        case .ignore:
            break
        case .forwardToChat:
            chatViewModel.handleScreenshotCaptured()
        }
    }

    func record(_ event: AppEvent) {
        Task {
            await events.emit(event)
        }
    }
}

// MARK: - Screenshot routing

extension AppRuntime {
    enum ScreenshotCaptureResponse: Equatable {
        case ignore
        case forwardToChat
    }

    /// With the notice turned off in Discretion, a screenshot stays on this phone.
    nonisolated static func resolveScreenshotResponse(isAppInfoPresented: Bool,
                                                      noticeEnabled: Bool) -> ScreenshotCaptureResponse {
        isAppInfoPresented || !noticeEnabled ? .ignore : .forwardToChat
    }
}
