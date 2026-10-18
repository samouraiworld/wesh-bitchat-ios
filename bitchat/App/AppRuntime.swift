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
    let locationChannelsModel: LocationChannelsModel
    let peerListModel: PeerListModel
    let appChromeModel: AppChromeModel
    let boardAlertsModel: BoardAlertsModel
    let composerDrafts = ComposerDraftStore.repository

    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var weshInternetStarted = false
    private var lastNostrRelayConnectedState = false
    private var didHandleInitialNostrConnection = false

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
        let locationPresenceStore = LocationPresenceStore()
        let locationManager = LocationChannelManager.shared
        self.conversations = conversations
        let resolvedSharedContentStore: SharedContentStore?
        if let sharedContentStore {
            resolvedSharedContentStore = sharedContentStore
        } else if !TestEnvironment.isRunningTests,
                  let sharedDefaults = UserDefaults(suiteName: BitchatApp.groupID) {
            resolvedSharedContentStore = SharedContentStore(defaults: sharedDefaults)
        } else {
            resolvedSharedContentStore = nil
        }
        var persistentWipes = PanicPersistentStoreWipes()
        persistentWipes.sharedContent = {
            guard let resolvedSharedContentStore else { return TestEnvironment.isRunningTests }
            return resolvedSharedContentStore.discardAll()
        }
        self.chatViewModel = ChatViewModel(
            keychain: keychain,
            idBridge: idBridge,
            identityManager: SecureIdentityStateManager(keychain),
            conversations: conversations,
            peerIdentityStore: peerIdentityStore,
            locationPresenceStore: locationPresenceStore,
            locationManager: locationManager,
            panicPersistentStoreWipes: persistentWipes
        )
        self.publicChatModel = PublicChatModel(conversations: conversations)
        self.privateInboxModel = PrivateInboxModel(conversations: conversations)
        self.locationChannelsModel = LocationChannelsModel(manager: locationManager)
        self.privateConversationModel = PrivateConversationModel(
            chatViewModel: self.chatViewModel,
            conversations: conversations,
            locationChannelsModel: self.locationChannelsModel,
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
            locationChannelsModel: self.locationChannelsModel,
            peerIdentityStore: peerIdentityStore,
            locationPresenceStore: locationPresenceStore
        )
        self.appChromeModel = AppChromeModel(
            chatViewModel: self.chatViewModel,
            privateInboxModel: self.privateInboxModel
        )
        let chatViewModel = self.chatViewModel
        self.boardAlertsModel = BoardAlertsModel(
            arrivals: BoardStore.shared.postArrivals.eraseToAnyPublisher(),
            wipes: BoardStore.shared.didWipe.eraseToAnyPublisher(),
            dependencies: BoardAlertsModel.Dependencies(
                isOwnPost: { post in
                    let key = chatViewModel.meshService.noiseSigningPublicKeyData()
                    return !key.isEmpty && key == post.authorSigningKey
                },
                emitSystemLine: { content, geohash in
                    if geohash.isEmpty {
                        chatViewModel.addMeshOnlySystemMessage(content)
                    } else {
                        chatViewModel.addGeohashSystemMessage(content, geohash: geohash)
                    }
                }
            )
        )
        // Wesh Internet mode talks to its pinned relays only: no geo relay directory.
        if !WeshMode.isActive && chatViewModel.networkActivationAllowed && NetworkActivationService.shared.userInternetEnabled {
            GeoRelayDirectory.shared.prefetchIfNeeded()
        }
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

    func start() {
        guard chatViewModel.networkActivationAllowed else { return }
        guard !started else { return }

        started = true
        NotificationDelegate.shared.runtime = self
        VerificationService.shared.configure(with: chatViewModel.meshService)
        announceInitialTorStatusIfNeeded()

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
        } else if NetworkActivationService.shared.userInternetEnabled {
            GeohashPresenceService.shared.start()
        }
        performMediaMaintenance()

        record(.launched)
        record(.startupCompleted)
    }

    /// Wesh has no media: deletes the media an older build may have stored,
    /// after excluding from backups the files older builds left there.
    /// Detached because `AppRuntime` is main-actor; best-effort, nothing at
    /// launch depends on the result. Skipped under tests, whose process
    /// shares the developer's real Application Support tree.
    private func performMediaMaintenance() {
        guard !TestEnvironment.isRunningTests else { return }
        Task.detached(priority: .utility) {
            #if os(iOS)
            LocalFileProtection.excludeApplicationSupportFromBackup()
            #endif
            try? PanicRecoveryFileStore().removeLegacyMedia()
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
            chatViewModel.endGeohashSampling()
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

        if identifier.hasPrefix("geo-activity-"),
           let deepLink = userInfo["deeplink"] as? String,
           let geohash = deepLink.components(separatedBy: "/").last,
           case .location(let channel) = locationChannelsModel.selectedChannel,
           channel.geohash == geohash {
            return []
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

        let isInitialConnection = !didHandleInitialNostrConnection
        didHandleInitialNostrConnection = true

        if !chatViewModel.nostrHandlersSetup {
            chatViewModel.setupNostrMessageHandling()
            chatViewModel.nostrHandlersSetup = true
        }

        guard !isInitialConnection else { return }

        chatViewModel.resubscribeCurrentGeohash()
        chatViewModel.geoChannelCoordinator?.refreshSampling()
    }

    func announceInitialTorStatusIfNeeded() {
        if TorManager.shared.torEnforced &&
            !chatViewModel.torStatusAnnounced &&
            TorManager.shared.isAutoStartAllowed() {
            chatViewModel.torStatusAnnounced = true
            chatViewModel.addGeohashOnlySystemMessage(
                String(localized: "system.tor.starting", comment: "System message when Tor is starting")
            )
        } else if !TorManager.shared.torEnforced && !chatViewModel.torStatusAnnounced {
            chatViewModel.torStatusAnnounced = true
            chatViewModel.addGeohashOnlySystemMessage(
                String(localized: "system.tor.dev_bypass", comment: "System message when Tor bypass is enabled in development")
            )
        }
    }

    func handleScreenshotCaptured() {
        let isLocationChannelActive: Bool = {
            if case .location = chatViewModel.activeChannel { return true }
            return false
        }()

        switch Self.resolveScreenshotResponse(
            isLocationChannelsSheetPresented: appChromeModel.isLocationChannelsSheetPresented,
            isAppInfoPresented: appChromeModel.isAppInfoPresented,
            hasPrivateChatOpen: chatViewModel.selectedPrivateChatPeer != nil,
            isLocationChannelActive: isLocationChannelActive
        ) {
        case .warnLocally:
            appChromeModel.triggerScreenshotPrivacyWarning()
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
    /// What a screenshot triggers. Nothing on this table sends anything to
    /// a public channel (see `ChatLifecycleCoordinator.handleScreenshotCaptured`).
    enum ScreenshotCaptureResponse: Equatable {
        /// Show the local location-privacy alert; nothing is sent anywhere.
        case warnLocally
        /// Do nothing. App Info holds no conversation or location content.
        case ignore
        /// Hand to the chat layer: a DM notice goes to the peer when a
        /// secure session exists; public timelines stay silent. Mesh
        /// deliberately gets no local alert either — a mesh screenshot
        /// reveals no place and triggers no send, so there is nothing to
        /// warn about, and alerting on every screenshot would train people
        /// to dismiss the one alert that matters (the location one).
        case forwardToChat
    }

    /// Pure decision table so the screenshot routing is testable without a
    /// runtime.
    nonisolated static func resolveScreenshotResponse(
        isLocationChannelsSheetPresented: Bool,
        isAppInfoPresented: Bool,
        hasPrivateChatOpen: Bool,
        isLocationChannelActive: Bool
    ) -> ScreenshotCaptureResponse {
        if isLocationChannelsSheetPresented { return .warnLocally }
        if isAppInfoPresented { return .ignore }
        // A geohash timeline screenshot still reveals a place — warn the
        // person taking it, locally, with the same alert the channel sheet
        // uses.
        if !hasPrivateChatOpen, isLocationChannelActive { return .warnLocally }
        return .forwardToChat
    }
}
