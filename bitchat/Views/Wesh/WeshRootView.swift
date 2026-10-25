import BitFoundation
import CoreBluetooth
import Combine
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// One owner for the note. An editor event belongs to the generation in which
/// its Binding was created, including events delivered after a wipe/restart.
/// The note is sealed on this device; an unreadable record is kept, not replaced.
@MainActor
final class WeshMeetingNoteStore: ObservableObject {
    struct Content: Equatable, Codable {
        var title = ""
        var place = ""
        var note = ""
        var date = Date().timeIntervalSince1970
    }

    @Published private(set) var content: Content
    @Published private(set) var generation: UInt64 = 0
    @Published private(set) var isSuspended = false
    @Published private(set) var storageState: WeshQRTrust.StorageState = .available
    /// False after an accepted edit whose sealed write was not confirmed.
    @Published private(set) var isSaveConfirmed = true
    private let storage: WeshSealedStore?
    private let legacyDefaults: UserDefaults?
    private let erasePersisted: @MainActor () -> Bool
    /// Keystrokes are coalesced into one sealed write after this pause.
    private let saveDelay: TimeInterval
    private var pendingSave: Task<Void, Never>?
    static let legacyKeys = ["wesh.meeting.title", "wesh.meeting.place", "wesh.meeting.note", "wesh.meeting.date"]

    /// Nil storage is a RAM-only instance. Tests inject synthetic storage and
    /// never construct an owner backed by the host's real files.
    init(storage: WeshSealedStore? = nil, legacyDefaults: UserDefaults? = nil,
         erasePersisted: (@MainActor () -> Bool)? = nil, saveDelay: TimeInterval = 0) {
        self.storage = storage
        self.legacyDefaults = legacyDefaults
        self.saveDelay = saveDelay
        content = Content()
        self.erasePersisted = erasePersisted ?? { Self.erase(storage: storage, legacyDefaults: legacyDefaults) }
        load()
    }

    /// The pending-wipe marker is written first and removed last, so a failed
    /// erase is retried by the next load instead of the note coming back.
    private static func erase(storage: WeshSealedStore?, legacyDefaults: UserDefaults?) -> Bool {
        var erased = true
        var marked = true
        if let storage {
            // Mark first (Keychain, else a sentinel file), then always destroy.
            let keychainMarked = storage.writeIntent(pendingWipeMarker)
            let sentinelMarked = storage.markWipePending()
            marked = keychainMarked || sentinelMarked
            do { try storage.wipe() } catch { erased = false }
        }
        if let legacyDefaults {
            legacyKeys.forEach { legacyDefaults.removeObject(forKey: $0) }
            erased = erased && legacyKeys.allSatisfy { legacyDefaults.object(forKey: $0) == nil }
        }
        if erased, let storage { erased = storage.writeIntent(nil) && storage.clearWipeSentinel() }
        return erased && marked
    }
    private static let pendingWipeMarker = Data("wipe".utf8)

    var isEditable: Bool { !isSuspended && storageState == .available }

    func reloadIfNeeded() {
        if erasePending { retryPendingErase(); return }
        guard !isSuspended, storageState != .available else { return }
        load()
    }

    /// A marker found at load time means the note was ordered deleted. The
    /// retry uses the panic lifecycle: old editor bindings are invalidated
    /// first, and editing resumes only after a confirmed erase.
    private var erasePending = false

    private func retryPendingErase() {
        erasePending = true
        if !isSuspended { suspendForPanic() }
        guard wipeForPanic() else {
            storageState = .unavailable
            return
        }
        erasePending = false
        completePanic()
    }

    @discardableResult
    func edit(_ field: WritableKeyPath<Content, String>, value: String, generation expected: UInt64) -> Bool {
        guard isEditable, expected == generation else { return false }
        switch field {
        case \Content.title, \Content.place, \Content.note: break
        default: return false
        }
        content[keyPath: field] = value
        persist()
        return true
    }

    @discardableResult
    func editDate(_ value: TimeInterval, generation expected: UInt64) -> Bool {
        guard isEditable, expected == generation, value.isFinite else { return false }
        content.date = value
        persist()
        return true
    }

    /// Writes a delayed edit now, e.g. before the app leaves the foreground.
    func flushPendingSave() {
        guard let pending = pendingSave else { return }
        pending.cancel()
        pendingSave = nil
        write()
    }

    private func persist() {
        guard storage != nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        guard saveDelay > 0 else { write(); return }
        let delay = UInt64(saveDelay * 1_000_000_000)
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.flushPendingSave()
        }
    }

    private func write() {
        guard let storage, !isSuspended else { return }
        do {
            try storage.save(JSONEncoder().encode(content))
            isSaveConfirmed = true
        } catch WeshSealedStore.Failure.recoveryRequired {
            isSaveConfirmed = false
            storageState = .recoveryRequired
        } catch { isSaveConfirmed = false }
    }

    private func load() {
        guard let storage else { return }
        do {
            if try storage.readIntent() != nil || storage.isWipePending() {
                // A note ordered deleted is never shown again; retry the erase.
                retryPendingErase()
                return
            }
            if let data = try storage.load() {
                guard let value = try? JSONDecoder().decode(Content.self, from: data) else {
                    throw WeshSealedStore.Failure.recoveryRequired
                }
                content = value
            } else if let legacy = legacyContent() {
                // One-time migration: delete plaintext only after a confirmed sealed write.
                try storage.save(JSONEncoder().encode(legacy))
                content = legacy
            } else {
                content = Content()
            }
            if let legacyDefaults { Self.legacyKeys.forEach { legacyDefaults.removeObject(forKey: $0) } }
            storageState = .available
        } catch WeshSealedStore.Failure.recoveryRequired {
            content = Content()
            storageState = .recoveryRequired
        } catch {
            // Locked device or unconfirmed write: retryable, nothing replaced.
            content = Content()
            storageState = .unavailable
        }
    }

    private func legacyContent() -> Content? {
        guard let legacyDefaults,
              Self.legacyKeys.contains(where: { legacyDefaults.object(forKey: $0) != nil }) else { return nil }
        return Content(
            title: legacyDefaults.string(forKey: Self.legacyKeys[0]) ?? "",
            place: legacyDefaults.string(forKey: Self.legacyKeys[1]) ?? "",
            note: legacyDefaults.string(forKey: Self.legacyKeys[2]) ?? "",
            date: legacyDefaults.object(forKey: Self.legacyKeys[3]) as? Double ?? Date().timeIntervalSince1970
        )
    }

    func suspendForPanic() {
        // Nothing typed before the wipe may be written after it.
        pendingSave?.cancel()
        pendingSave = nil
        generation &+= 1
        isSuspended = true
        content = Content()
    }

    func wipeForPanic() -> Bool {
        guard isSuspended else { return false }
        guard erasePersisted() else { return false }
        storageState = .available
        isSaveConfirmed = true
        erasePending = false
        return true
    }

    func completePanic() {
        // Events created while the editor was disabled are stale too.
        generation &+= 1
        isSuspended = false
    }

    @discardableResult
    func clear(generation expected: UInt64) -> Bool {
        guard !isSuspended, expected == generation else { return false }
        suspendForPanic()
        guard wipeForPanic() else {
            // Stay suspended; the next foreground retries the erase.
            erasePending = true
            storageState = .unavailable
            return false
        }
        completePanic()
        return true
    }
}

/// User-facing recovery copy; no action here can erase or replace identity data.
struct WeshNoiseIdentityNotice: Equatable {
    let title: String
    let message: String
    let allowsRetry: Bool

    init?(_ availability: NoiseIdentityAvailability, bundle: Bundle = PaveCopy.bundle, locale: Locale = .current) {
        switch availability {
        case .available:
            return nil
        case .storageUnavailable:
            title = PaveCopy.text("pave.identity.unavailable.title", bundle: bundle, locale: locale)
            message = PaveCopy.text("pave.identity.unavailable.message", bundle: bundle, locale: locale)
            allowsRetry = true
        case .persistenceUnconfirmed:
            title = PaveCopy.text("pave.identity.pending.title", bundle: bundle, locale: locale)
            message = PaveCopy.text("pave.identity.pending.message", bundle: bundle, locale: locale)
            allowsRetry = true
        case .recoveryRequired:
            title = PaveCopy.text("pave.identity.recovery.title", bundle: bundle, locale: locale)
            message = PaveCopy.text("pave.identity.recovery.message", bundle: bundle, locale: locale)
            allowsRetry = true
        case .invalidated:
            title = PaveCopy.text("pave.identity.suspended.title", bundle: bundle, locale: locale)
            message = PaveCopy.text("pave.identity.suspended.message", bundle: bundle, locale: locale)
            allowsRetry = false
        }
    }
}

/// Copy shared by the real erase confirmation and composer rejection paths.
enum WeshFeedbackCopy {
    static func eraseOutcome(_ completed: Bool, bundle: Bundle = PaveCopy.bundle, locale: Locale = .current) -> String {
        if completed {
            return PaveCopy.text("pave.localErase.confirmed", bundle: bundle, locale: locale)
        }
        return PaveCopy.text("pave.localErase.failed", bundle: bundle, locale: locale)
    }

    static func eraseWarning(bundle: Bundle = PaveCopy.bundle, locale: Locale = .current) -> String {
        PaveCopy.text("pave.localErase.warning", bundle: bundle, locale: locale)
    }

    static func composerTooLong(bundle: Bundle = PaveCopy.bundle, locale: Locale = .current) -> String {
        PaveCopy.text("pave.composer.tooLong", bundle: bundle, locale: locale)
    }

    static func composerChanged(bundle: Bundle = PaveCopy.bundle, locale: Locale = .current) -> String {
        PaveCopy.text("pave.composer.changed", bundle: bundle, locale: locale)
    }
}

private struct WeshNoiseIdentityRecoveryPanel: View {
    @EnvironmentObject private var chrome: AppChromeModel
    @Environment(\.weshTheme) private var theme
    var body: some View {
        if let notice = WeshNoiseIdentityNotice(chrome.noiseIdentityAvailability) {
            VStack(alignment: .leading, spacing: 8) {
                Label(notice.title, systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.headline).accessibilityAddTraits(.isHeader)
                Text(notice.message).font(.subheadline).foregroundStyle(theme.secondary)
                if notice.allowsRetry {
                    Button(chrome.isRecoveringNoiseIdentity ? PaveCopy.text("pave.wesh.recovery.running") : PaveCopy.text("pave.delivery.retry")) {
                        chrome.retryNoiseIdentityRecovery()
                    }.frame(minHeight: 44).disabled(chrome.isRecoveringNoiseIdentity)
                        .accessibilityHint(PaveCopy.text("pave.wesh.recovery.retryHint"))
                }
                if chrome.noiseIdentityRetryFailed {
                    Text(PaveCopy.text("pave.wesh.recovery.failed"))
                        .font(.footnote).foregroundStyle(theme.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct WeshRootView: View {
    let runtime: AppRuntime
    @ObservedObject private var viewModel: ChatViewModel
    @EnvironmentObject private var chrome: AppChromeModel
    @State private var panicFeedback = ""
    @AppStorage("wesh.appearance.v1") private var appearance: WeshAppearance = .night
    @AppStorage(WeshWelcome.key) private var welcomed = false
    @State private var selectedTab = 0
    @State private var keyboardVisible = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    private var theme: WeshTheme { WeshTheme(appearance: appearance) }

    init(runtime: AppRuntime) {
        self.runtime = runtime
        _viewModel = ObservedObject(wrappedValue: runtime.chatViewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            switch WeshRootScreen(
                panicRecoveryBlocked: viewModel.panicRecoveryBlocked,
                panicNetworkFenced: viewModel.panicNetworkFenced,
                welcomed: welcomed
            ) {
            case .eraseRecovery:
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(PaveCopy.text("pave.cleanup.title"), systemImage: "exclamationmark.triangle")
                            .font(.headline).accessibilityAddTraits(.isHeader)
                        Text(viewModel.panicNetworkFenced
                             ? WeshFeedbackCopy.eraseOutcome(false)
                             : PaveCopy.text("pave.cleanup.body"))
                        if let code = viewModel.panicNetworkFenced
                            ? viewModel.panicEraseDiagnosticCode
                            : viewModel.startupRetirementDiagnosticCode {
                            Text(verbatim: "Diagnostic \(code)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Button(PaveCopy.text("pave.action.retry")) {
                            if viewModel.panicNetworkFenced {
                                _ = runtime.retryPendingPanicRecovery()
                            } else {
                                runtime.retryStartupRetirement()
                            }
                        }
                            .frame(minHeight: 44)
                        if !viewModel.panicNetworkFenced {
                            Button(PaveCopy.text("pave.wesh.erase.confirmAction"), role: .destructive) {
                                chrome.requestPanicWipe()
                            }
                            .frame(minHeight: 44)
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
            case .welcome:
                // Nickname and terms, then Bluetooth: the system prompt waits for that step. Read from
                // the view model: the chrome copy follows it a run-loop later and could still hold the
                // nickname from before an erase.
                PaveOnboardingFlow(nickname: WeshWelcome.keptNickname(viewModel.nickname),
                                   onRequestBluetooth: { runtime.allowBluetoothPrompt() }, onFinish: { nickname in
                    chrome.setNickname(nickname)
                    chrome.validateAndSaveNickname()
                    welcomed = true
                    runtime.welcomeFinished()
                })
                // An erase while the welcome is up rebuilds it too, so its typed nickname goes.
                .id(viewModel.weshPanicGeneration)
            case .tabs:
                if viewModel.panicNetworkFenced {
                    // Also after a launch whose replayed erase failed again: say why nothing connects.
                    VStack(alignment: .leading, spacing: 8) {
                        Text(WeshFeedbackCopy.eraseOutcome(false)).font(.subheadline)
                        Button(PaveCopy.text("pave.action.retry")) { chrome.requestPanicWipe() }
                            .frame(minHeight: 44)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                } else if !panicFeedback.isEmpty {
                    Text(panicFeedback).font(.subheadline).padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                TabView(selection: $selectedTab) {
                    NavigationStack { WeshInbox(runtime: runtime) }
                        .tabItem { Label(PaveCopy.text("pave.wesh.tab.chats"), systemImage: "bubble.left.and.bubble.right") }
                        .tag(0).weshHiddenTabBar()
                    NavigationStack { WeshSettings(runtime: runtime) }
                        .tabItem { Label(PaveCopy.text("pave.settings.title"), systemImage: "gearshape") }
                        .tag(1).weshHiddenTabBar()
                }
                .id(viewModel.weshPanicGeneration)
                if !keyboardVisible { VStack(spacing: 0) {
                    Rectangle().fill(theme.line).frame(height: 0.5)
                    HStack(spacing: 0) {
                        tab(PaveCopy.text("pave.wesh.tab.chats"), symbol: "bubble.left.and.bubble.right", index: 0)
                        tab(PaveCopy.text("pave.settings.title"), symbol: "gearshape", index: 1)
                    }.padding(.top, 8).padding(.bottom, 4)
                }.background(theme.canvas.ignoresSafeArea(edges: .bottom)) }
            }
        }
        .overlay { if WeshPrivacyCover.covers(scenePhase) { WeshPrivacyCoverView() } }
        .environment(\.weshTheme, theme)
        .environment(\.paveTheme, PaveTheme(appearance.paveTheme))
        .environment(\.colorScheme, theme.scheme)
        .tint(theme.accent)
        .preferredColorScheme(theme.scheme)
        .background(theme.canvas.ignoresSafeArea())
        .onChange(of: scenePhase) { phase in
            // Sealed stores stay closed until first unlock; retry once visible.
            guard phase == .active else {
                viewModel.weshMeetingNote.flushPendingSave()
                return
            }
            WeshQRTrust.shared.reloadIfNeeded()
            viewModel.weshMeetingNote.reloadIfNeeded()
        }
        .alert(PaveCopy.text("pave.wesh.erase.confirmTitle"), isPresented: $chrome.showPanicConfirmation) {
            Button(PaveCopy.text("pave.action.cancel"), role: .cancel) {}
            Button(PaveCopy.text("pave.wesh.erase.confirmAction"), role: .destructive) {
                _ = runtime.panicEraseAction(report: { completed in
                    selectedTab = 1
                    panicFeedback = WeshFeedbackCopy.eraseOutcome(completed)
                })()
            }
        } message: {
            Text(WeshFeedbackCopy.eraseWarning())
        }
        .onReceive(NotificationCenter.default.publisher(for: WeshPlatform.keyboardWillShow)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: WeshPlatform.keyboardWillHide)) { _ in keyboardVisible = false }
    }

    private func tab(_ title: String, symbol: String, index: Int) -> some View {
        Button { selectedTab = index } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: selectedTab == index ? .semibold : .regular))
                    .accessibilityHidden(true)
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(title).font(.caption.weight(selectedTab == index ? .semibold : .regular))
                }
            }.frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
                .foregroundStyle(selectedTab == index ? theme.accent : theme.secondary)
        }.buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityAddTraits(selectedTab == index ? .isSelected : [])
    }
}

private struct WeshInbox: View {
    let runtime: AppRuntime
    @EnvironmentObject private var inbox: PrivateInboxModel
    @EnvironmentObject private var chrome: AppChromeModel
    @Environment(\.weshTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var trust = WeshQRTrust.shared
    @State private var addingContact = false
    @State private var openedContact: WeshQRTrust.Contact?
    /// Pushed only once the sheet is gone: a push during its dismissal is dropped.
    @State private var chatAfterExchange: WeshQRTrust.Contact?
    @State private var storageCheck = 0
    @State private var connexion = false
    @EnvironmentObject private var peers: PeerListModel
    @ObservedObject private var internetMode = WeshInternetMode.shared

    private var internetStatus: PaveInternetStatus { internetMode.internetStatus }

    private var storageNotice: WeshContactStorageNotice? {
        let _ = storageCheck
        let identity = runtime.chatViewModel.identityManager
        return WeshContactStorageNotice(identityAvailable: identity.isPersistenceAvailable,
                                        identityRequiresRecovery: identity.persistenceRequiresRecovery,
                                        contactsState: trust.storageState)
    }

    private var contacts: [WeshQRTrust.Contact] {
        let _ = peers.renderID
        return trust.contacts.filter { row in
            guard let key = row.peerID.noiseKey else { return false }
            return !runtime.chatViewModel.identityManager.isBlocked(fingerprint: key.sha256Fingerprint())
        }
    }

    var body: some View {
        List {
            if chrome.noiseIdentityAvailability != .available {
                Section { WeshNoiseIdentityRecoveryPanel() }
                    .listRowBackground(theme.canvas)
            }
            if let storageNotice {
                Section {
                    WeshContactStorageRecoveryPanel(notice: storageNotice) {
                        runtime.chatViewModel.identityManager.forceSave()
                        trust.reloadIfNeeded()
                        storageCheck += 1
                    }
                }.listRowBackground(theme.canvas)
            }
            Section {
                PaveReachCard(phonesInReach: peers.reachableMeshPeerCount, bluetoothOn: chrome.bluetoothState == .poweredOn)
                    .listRowInsets(EdgeInsets(top: PaveSpace.s2, leading: PaveSpace.s4, bottom: PaveSpace.s2, trailing: PaveSpace.s4))
                    .listRowSeparator(.hidden)
                // Only once Internet mode is on: off, the reach card already says it is Bluetooth only.
                if internetStatus.showsHomePill {
                    PaveStatusPill(status: internetStatus) {
                        if internetStatus.offersRetry { internetMode.retryInternet() } else { connexion = true }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowInsets(EdgeInsets(top: PaveSpace.s1, leading: PaveSpace.s4, bottom: PaveSpace.s2, trailing: PaveSpace.s4))
                    .listRowSeparator(.hidden)
                }
            }
            .listRowBackground(theme.canvas)
            Section {
                NavigationLink {
                    WeshConversation(runtime: runtime, peerID: nil, title: PaveCopy.text("pave.wesh.public.title"))
                } label: {
                    // Pavé Fluo: the public room is a full yellow card that says PUBLIC first.
                    VStack(alignment: .leading, spacing: PaveSpace.s1) {
                        HStack(spacing: PaveSpace.s2) {
                            Image(systemName: "megaphone.fill").accessibilityHidden(true)
                            Text(PaveCopy.text("pave.wesh.public.title"))
                                .font(PaveDisplayStyle.displaySmall.font)
                                .textCase(.uppercase)
                                .accessibilityLabel(Text(PaveCopy.text("pave.wesh.public.title")))
                            Spacer(minLength: 0)
                        }
                        Text(PaveCopy.text("pave.wesh.public.subtitle"))
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(theme.onPublic)
                    .padding(PaveSpace.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.publicFill, in: RoundedRectangle(cornerRadius: PaveRadius.control))
                }
                .listRowInsets(EdgeInsets(top: PaveSpace.s1, leading: PaveSpace.s4, bottom: PaveSpace.s1, trailing: PaveSpace.s4))
            } header: { WeshSectionLabel(text: PaveCopy.text("pave.wesh.inbox.nearby")) } footer: {
                Label(bluetoothSummary(chrome.bluetoothState), systemImage: "antenna.radiowaves.left.and.right")
                    .font(.footnote).foregroundStyle(theme.secondary).padding(.top, 8)
                if chrome.bluetoothState == .unauthorized {
                    Button(PaveCopy.text("pave.wesh.bluetooth.allow"), action: openWeshSystemSettings).frame(minHeight: 44)
                }
            }
            .listRowBackground(theme.canvas).listRowSeparatorTint(theme.line)

            Section {
                if contacts.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(PaveCopy.text("pave.wesh.inbox.emptyTitle"))
                            .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        Text(PaveCopy.text("pave.wesh.inbox.emptyBody"))
                            .font(.body).foregroundStyle(theme.secondary)
                        Button { addingContact = true } label: {
                            Label(PaveCopy.text("pave.wesh.action.addContact"), systemImage: "qrcode.viewfinder")
                        }.buttonStyle(WeshPrimaryButtonStyle())
                    }.padding(.vertical, 24)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(contacts) { row in
                        let hasUnread = inbox.unreadPeerIDs.contains(row.peerID) || inbox.unreadPeerIDs.contains(runtime.chatViewModel.getShortIDForNoiseKey(row.peerID))
                        NavigationLink {
                            WeshConversation(runtime: runtime, peerID: row.peerID, title: PaveDisplayName.safe(row.nickname))
                        } label: {
                            HStack(spacing: 16) {
                                if !dynamicTypeSize.isAccessibilitySize { WeshAvatar(symbol: "person") }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(PaveDisplayName.safe(row.displayName)).font(.headline)
                                    PaveFingerprintText(fingerprint: PaveFingerprint.short(row.peerID.noiseKey))
                                    if let badge = PaveContactInternetBadge(
                                        contact: row, internet: internetStatus,
                                        routable: runtime.chatViewModel.isWeshInternetContact(row.peerID)) {
                                        PaveInternetBadge(badge: badge)
                                    }
                                    Text(inbox.messages(for: row.peerID).last.map { WeshIncomingMediaPolicy.displayText($0.content) } ?? PaveCopy.text("pave.wesh.inbox.verified"))
                                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                        .font(.subheadline).foregroundStyle(theme.secondary)
                                    if dynamicTypeSize.isAccessibilitySize && hasUnread {
                                        Text(PaveCopy.text("pave.wesh.inbox.unread")).font(.subheadline).foregroundStyle(theme.accent)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
                                if !dynamicTypeSize.isAccessibilitySize && hasUnread {
                                    Image(systemName: "circle.fill").font(.caption2).foregroundStyle(theme.accent).accessibilityLabel(PaveCopy.text("pave.wesh.inbox.unread"))
                                }
                            }.padding(.vertical, theme.isDark ? 12 : 6)
                        }
                    }
                }
            } header: { WeshSectionLabel(text: PaveCopy.text("pave.wesh.inbox.private")) }
            .listRowBackground(theme.canvas).listRowSeparatorTint(theme.line)
            WeshRequestsSection(runtime: runtime)
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .navigationTitle("Wesh")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { addingContact = true } label: {
                    Label(PaveCopy.text("pave.wesh.action.addContact"), systemImage: "plus").frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .sheet(isPresented: $addingContact, onDismiss: {
            openedContact = chatAfterExchange
            chatAfterExchange = nil
        }) {
            WeshContactSheet(runtime: runtime, onOpenChat: { chatAfterExchange = $0 })
        }
        .sheet(isPresented: $connexion) { WeshConnectionSettings() }
        .navigationDestination(isPresented: Binding(get: { openedContact != nil },
                                                    set: { if !$0 { openedContact = nil } })) {
            if let contact = openedContact {
                WeshConversation(runtime: runtime, peerID: contact.peerID, title: PaveDisplayName.safe(contact.nickname))
            }
        }
        .weshCanvas(title: "Wesh")
    }
}

private struct WeshAvatar: View {
    let symbol: String
    @Environment(\.weshTheme) private var theme
    var body: some View {
        Image(systemName: symbol).font(.system(size: 24, weight: .medium)).foregroundStyle(theme.accent)
            .frame(width: 48, height: 48)
            .overlay(RoundedRectangle(cornerRadius: theme.isDark ? 24 : 14).strokeBorder(theme.line, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

enum WeshDraftStoragePresentation {
    static func message(_ status: ComposerDraftStatus, hasText: Bool) -> String? {
        switch status {
        case .sessionOnly: return hasText ? PaveCopy.text("pave.wesh.draft.sessionOnly") : nil
        case .waitingForIdentity: return PaveCopy.text("pave.wesh.draft.identityUnavailable")
        case .loading: return PaveCopy.text("pave.wesh.draft.loading")
        case .dirty, .saving: return PaveCopy.text("pave.wesh.draft.saving")
        case .durable: return hasText ? PaveCopy.text("pave.wesh.draft.durable") : nil
        case .suspended: return PaveCopy.text("pave.wesh.draft.suspended")
        case .unavailable(.tooLarge): return PaveCopy.text("pave.wesh.draft.tooLarge")
        case .unavailable(.capacityReached): return PaveCopy.text("pave.wesh.draft.capacity")
        case .unavailable(.recoveryRequired), .unavailable(.ownerMismatch):
            return PaveCopy.text("pave.wesh.draft.recovery")
        case .unavailable: return PaveCopy.text("pave.wesh.draft.unavailable")
        }
    }
    static func canRetry(_ status: ComposerDraftStatus) -> Bool {
        if case .unavailable = status { return true }
        return false
    }
}

/// One-shot focus intents belong to the current presentation and editor revision.
/// Editing feedback never requests focus or dismisses the keyboard.
struct WeshComposerFeedbackState: Sendable {
    enum FocusTarget: Equatable, Sendable { case feedback }
    struct FocusRequest: Equatable, Sendable {
        // periphery:ignore - read only via the synthesized Equatable
        let revision: UInt64
        let target: FocusTarget
    }

    private(set) var message = ""
    private(set) var isEditingRejection = false
    private(set) var revision: UInt64 = 0
    private(set) var pendingFocus: FocusRequest?
    private(set) var isPresented = false
    private var keyboardVisible = false

    var readyFocus: FocusRequest? {
        guard isPresented, let pendingFocus,
              !keyboardVisible else { return nil }
        return pendingFocus
    }

    mutating func appear() {
        isPresented = true
        invalidateFocus()
    }

    mutating func disappear() {
        isPresented = false
        keyboardVisible = false
        invalidateFocus()
    }

    mutating func edited(rejection: String?) {
        invalidateFocus()
        message = rejection ?? ""
        isEditingRejection = rejection != nil
    }

    mutating func showAction(_ message: String) {
        display(message, target: .feedback)
    }

    mutating func keyboardWillShow() { keyboardVisible = true }
    mutating func keyboardDidHide() { keyboardVisible = false }

    mutating func composerBecameFocused() {
        if pendingFocus?.target == .feedback { invalidateFocus() }
    }

    mutating func consume(_ request: FocusRequest) -> FocusTarget? {
        guard readyFocus == request else { return nil }
        pendingFocus = nil
        return request.target
    }

    private mutating func display(_ message: String, target: FocusTarget?) {
        invalidateFocus()
        self.message = message
        isEditingRejection = false
        if isPresented, let target {
            pendingFocus = FocusRequest(revision: revision, target: target)
        }
    }

    private mutating func invalidateFocus() {
        revision &+= 1
        pendingFocus = nil
    }
}

private struct WeshConversation: View {
    let runtime: AppRuntime
    let peerID: PeerID?
    let title: String
    @ObservedObject private var composerDrafts: ComposerDraftRepository
    @State private var draftGeneration: UInt64 = 0
    @State private var composerFeedback = WeshComposerFeedbackState()
    @AccessibilityFocusState(for: .voiceOver) private var composerFeedbackFocused: Bool
    @EnvironmentObject private var publicChat: PublicChatModel
    @EnvironmentObject private var inbox: PrivateInboxModel
    @EnvironmentObject private var privateChat: PrivateConversationModel
    // periphery:ignore - observed so the view re-renders on verification updates
    @EnvironmentObject private var verification: VerificationModel
    @ObservedObject private var trust = WeshQRTrust.shared
    @State private var draft = ""
    @State private var publicWarning = false
    @State private var information = false
    @Environment(\.weshTheme) private var theme
    @State private var contactSheet = false
    /// Captured when presented, so a failed removal keeps the page and its message.
    @State private var contactDetails: WeshQRTrust.Contact?
    @State private var blockTarget: PeerID?
    @State private var blockName = ""
    @State private var reportTarget: PeerID?
    @State private var reportName = ""
    @State private var reportMessage: BitchatMessage?
    @State private var reportDone = false
    @State private var showingParticipants = false
    @AppStorage("wesh.publicMuted") private var publicMuted = false
    @EnvironmentObject private var actions: ConversationUIModel
    @AppStorage("wesh.publicDisclosureAccepted.v1") private var publicAccepted = false
    @EnvironmentObject private var chrome: AppChromeModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool

    @EnvironmentObject private var peers: PeerListModel

    init(runtime: AppRuntime, peerID: PeerID?, title: String) {
        self.runtime = runtime
        self.peerID = peerID
        self.title = title
        _composerDrafts = ObservedObject(wrappedValue: runtime.composerDrafts)
    }

    private var isPrivate: Bool { peerID != nil }
    /// An alias changes local chrome only. The original QR title remains the
    /// input to moderation and sharing; sends still target the pinned key.
    private var displayedTitle: String {
        guard let peerID, let current = trust.contacts.first(where: { $0.peerID == peerID }) else { return title }
        return PaveDisplayName.safe(current.displayName)
    }
    private var draftKey: ComposerDraftStore.Key {
        .from(peerID: peerID, fingerprint: peerID?.noiseKey?.sha256Fingerprint(), channel: .mesh)
    }
    private var draftBinding: Binding<String> {
        Binding(get: { draft }, set: { value in
            if composerDrafts.admitDisplayedText(value, for: draftKey, generation: draftGeneration) {
                draft = value
                composerFeedback.edited(rejection: nil)
            } else {
                composerFeedback.edited(rejection: PaveCopy.text("pave.wesh.draft.editRejected"))
            }
            composerFeedbackFocused = false
        })
    }
    private var draftStatus: ComposerDraftStatus {
        composerDrafts.status(for: draftKey, displayedText: draft)
    }
    /// Each read waits on the identity manager queue: evaluate it once per body.
    private var sendAvailable: Bool {
        let _ = peers.renderID
        return peerID.map { runtime.chatViewModel.canSendWeshMessage(to: $0) } ?? runtime.chatViewModel.canSendWeshPublic
    }
    private var messages: [BitchatMessage] {
        if let peerID {
            let stableMessages = inbox.messages(for: peerID)
            if !stableMessages.isEmpty { return stableMessages.filter(\.isPrivate) }
            // A mutable selection must never put another person's history under this title.
            if let selected = privateChat.selectedPeerID, let pinned = peerID.noiseKey,
               runtime.chatViewModel.noiseSessionPublicKeyData(for: runtime.chatViewModel.getShortIDForNoiseKey(selected)) == pinned {
                return inbox.messages(for: selected).filter(\.isPrivate)
            }
            return []
        }
        guard publicChat.activeChannel == .mesh else { return [] }
        return publicChat.messages.filter {
            !$0.isPrivate && !$0.isBridged && runtime.chatViewModel.allowsWeshPublicContent($0.content)
        }
    }

    var body: some View {
        let displayedMessages = messages
        let canSend = sendAvailable
        let knownKeys: [Data] = isPrivate ? [] : runtime.chatViewModel.unifiedPeerService.peers.map(\.noisePublicKey)
        VStack(spacing: 0) {
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Label(isPrivate ? (canSend ? PaveCopy.text("pave.wesh.inbox.verified") : PaveCopy.text("pave.wesh.conversation.verifyOrConnect")) : PaveCopy.text("pave.wesh.conversation.publicRelay"),
                                          systemImage: isPrivate ? "lock" : "antenna.radiowaves.left.and.right")
                                        .font(.subheadline.weight(.medium))
                                    if !isPrivate {
                                        Text(PaveCopy.text("pave.wesh.conversation.visible"))
                                            .font(.footnote).foregroundStyle(theme.secondary)
                                        Text(PaveCopy.text("pave.publicFilter.status"))
                                            .font(.footnote).foregroundStyle(theme.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                Button { information = true } label: {
                                    Image(systemName: "info.circle").frame(width: 44, height: 44)
                                }.accessibilityLabel(isPrivate ? PaveCopy.text("pave.wesh.conversation.privateAbout") : PaveCopy.text("pave.wesh.conversation.publicAbout"))
                            }
                            if isPrivate && !canSend {
                                Button(PaveCopy.text("pave.wesh.contact.verify")) { contactSheet = true }.frame(minHeight: 44)
                            }
                        }.padding(.bottom, 16)
                        if displayedMessages.isEmpty {
                            VStack(spacing: 16) {
                                Image(systemName: isPrivate ? "bubble.left.and.bubble.right" : "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 40, weight: .light)).foregroundStyle(theme.accent).accessibilityHidden(true)
                                Text(isPrivate ? PaveCopy.text("pave.wesh.conversation.privateEmpty") : (canSend ? PaveCopy.text("pave.wesh.conversation.publicEmpty") : PaveCopy.text("pave.wesh.conversation.roomReady")))
                                    .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                                Text(isPrivate ? PaveCopy.text("pave.wesh.conversation.privateEmptyBody") : (canSend ? PaveCopy.text("pave.wesh.conversation.publicEmptyBody") : PaveCopy.text("pave.wesh.conversation.prepare")))
                                    .font(.body).foregroundStyle(theme.secondary)
                            }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 64)
                        }
                        ForEach(Array(displayedMessages.enumerated()), id: \.element.id) { index, message in
                            if WeshTimeline.startsDay(at: message.timestamp, after: index > 0 ? displayedMessages[index - 1].timestamp : nil) {
                                WeshDayDivider(date: message.timestamp)
                            }
                            WeshMessageBubble(message: message,
                                own: runtime.chatViewModel.isSelfSender(peerID: message.senderPeerID),
                                privateChat: isPrivate).id(message.id)
                                .accessibilityAction(named: PaveCopy.text("pave.wesh.action.copyMessage")) { WeshPlatform.copy(message.content) }
                                .contextMenu {
                                    Button { WeshPlatform.copy(message.content) } label: {
                                        Label(PaveCopy.text("pave.wesh.action.copy"), systemImage: "doc.on.doc")
                                    }
                                    moderationActions(for: message, knownKeys: knownKeys)
                                }
                        }
                    }.padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: displayedMessages.count) { _ in
                    if let id = displayedMessages.last?.id {
                        if reduceMotion { scroll.scrollTo(id, anchor: .bottom) }
                        else { withAnimation { scroll.scrollTo(id, anchor: .bottom) } }
                    }
                }
            }
        }
        .weshCanvas(title: displayedTitle, appCopy: peerID == nil)
        .navigationTitle(displayedTitle).weshInlineTitle()
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if chrome.noiseIdentityAvailability != .available {
                    WeshNoiseIdentityRecoveryPanel()
                    Text(PaveCopy.text("pave.wesh.draft.kept")).font(.footnote).foregroundStyle(theme.secondary)
                } else if !canSend {
                    Text(isPrivate ? PaveCopy.text("pave.wesh.draft.privateKept") : bluetoothSummary(chrome.bluetoothState))
                        .font(.footnote).foregroundStyle(theme.secondary)
                    if !isPrivate && chrome.bluetoothState == .unauthorized {
                        Button(PaveCopy.text("pave.wesh.bluetooth.allow"), action: openWeshSystemSettings).frame(minHeight: 44)
                    }
                }
                if let message = WeshDraftStoragePresentation.message(draftStatus, hasText: !draft.isEmpty) {
                    Text(message).font(.footnote).foregroundStyle(theme.secondary)
                    if WeshDraftStoragePresentation.canRetry(draftStatus) {
                        Button(PaveCopy.text("pave.wesh.draft.retry")) {
                            composerDrafts.save(draft, for: draftKey, generation: draftGeneration)
                            composerDrafts.retry()
                        }.frame(minHeight: 44)
                    }
                }
                if !composerFeedback.message.isEmpty {
                    Text(composerFeedback.message).font(.body).foregroundStyle(theme.secondary)
                        .id(composerFeedback.revision)
                        .accessibilityFocused($composerFeedbackFocused)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    TextField(isPrivate ? PaveCopy.text("pave.wesh.composer.private") : PaveCopy.text("pave.wesh.composer.public"), text: draftBinding,
                              prompt: Text(isPrivate ? PaveCopy.text("pave.wesh.composer.private") : PaveCopy.text("pave.wesh.composer.public")).foregroundColor(theme.secondary), axis: .vertical)
                        .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 3 : 6))
                        .focused($composerFocused)
                        .padding(14)
                        .overlay(RoundedRectangle(cornerRadius: theme.radius).strokeBorder(theme.line, lineWidth: 1))
                        .accessibilityLabel(isPrivate ? PaveCopy.text("pave.wesh.composer.private") : PaveCopy.text("pave.wesh.composer.public"))
                        .accessibilityHint(composerFeedback.isEditingRejection ? composerFeedback.message : "")
                    Button {
                        if !isPrivate && !publicAccepted { publicWarning = true } else { send() }
                    } label: {
                        Image(systemName: "arrow.up").font(.body.weight(.semibold))
                            .frame(width: 48, height: 48)
                            .foregroundStyle(canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? theme.onAccent : theme.secondary)
                            .background(canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AnyShapeStyle(theme.metalFill) : AnyShapeStyle(theme.canvas), in: Circle())
                            .overlay(Circle().strokeBorder(theme.line, lineWidth: canSend ? 0 : 1))
                    }
                    .accessibilityLabel(isPrivate ? PaveCopy.text("pave.wesh.composer.sendPrivate") : PaveCopy.text("pave.wesh.composer.sendPublic"))
                    .disabled(!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(16).background(theme.canvas)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let peerID, let contact = trust.contacts.first(where: { $0.peerID == peerID }) {
                        Button { contactDetails = contact } label: { Label(PaveCopy.text("pave.wesh.contact.view"), systemImage: "person.crop.circle") }
                    }
                    Button { information = true } label: { Label(PaveCopy.text("pave.settings.about"), systemImage: "info.circle") }
                    if !isPrivate {
                        Button { showingParticipants = true } label: { Label(PaveCopy.text("pave.wesh.participants.title"), systemImage: "person.2") }
                        Button { publicMuted.toggle() } label: {
                            Label(publicMuted ? PaveCopy.text("pave.wesh.mentions.unmute") : PaveCopy.text("pave.wesh.mentions.mute"), systemImage: publicMuted ? "bell.slash" : "bell")
                        }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .accessibilityLabel(PaveCopy.text("pave.wesh.conversation.actions"))
            }
        }
        .alert(PaveCopy.text("pave.wesh.public.confirmTitle"), isPresented: $publicWarning) {
            Button(PaveCopy.text("pave.action.cancel"), role: .cancel) {}
            Button(PaveCopy.text("pave.wesh.composer.sendPublic")) { publicAccepted = true; send() }
        } message: { Text(PaveCopy.text("pave.wesh.public.confirmBody")) }
        .sheet(isPresented: $contactSheet) { WeshContactSheet(runtime: runtime) }
        .alert(PaveCopy.text("pave.wesh.block.personTitle"), isPresented: Binding(get: { blockTarget != nil }, set: { if !$0 { blockTarget = nil } })) {
            Button(PaveCopy.text("pave.action.cancel"), role: .cancel) { blockTarget = nil }
            Button(PaveCopy.text("pave.wesh.action.block"), role: .destructive) {
                if let target = blockTarget { actions.block(peerID: target, displayName: blockName) }
                blockTarget = nil
            }
            .accessibilityLabel(PaveCopy.text("pave.action.block", weshIdentitySummary(blockName, fingerprint: blockTarget?.noiseKey?.sha256Fingerprint())))
        } message: { Text(PaveCopy.text("pave.wesh.block.body")) }
        .modifier(WeshReportAlerts(target: $reportTarget, name: reportName, message: reportMessage, done: $reportDone) { target, name in
            runtime.chatViewModel.reportWeshPublicAuthor(target, displayName: name)
        })
        .sheet(isPresented: $showingParticipants) { NavigationStack { WeshNearbyPeople(runtime: runtime) }.weshSheetBackground() }
        .sheet(item: $contactDetails) { contact in
            NavigationStack { WeshContactDetails(runtime: runtime, contact: contact, inSheet: true).id(contact.id) }.weshSheetBackground()
        }
        .sheet(isPresented: $information) {
            WeshInformationSheet(isPrivate: isPrivate)
        }
        .onAppear {
            composerFeedback.appear()
            draftGeneration = composerDrafts.currentGeneration
            draft = composerDrafts.load(draftKey)
            if let peerID { privateChat.startConversation(with: peerID) }
            else { privateChat.endConversation(); runtime.chatViewModel.activeChannel = .mesh }
        }
        .onDisappear {
            composerFeedback.disappear()
            composerFeedbackFocused = false
            composerDrafts.flush()
        }
        .onChange(of: composerFocused) { focused in
            if focused { composerFeedback.composerBecameFocused() }
        }
        .onChange(of: composerFeedback.readyFocus) { request in
            guard let request else { return }
            // Render the inline result before one guarded focus handoff.
            DispatchQueue.main.async {
                guard let target = composerFeedback.consume(request) else { return }
                switch target {
                case .feedback: composerFeedbackFocused = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WeshPlatform.keyboardWillShow)) { _ in
            composerFeedback.keyboardWillShow()
        }
        .onReceive(NotificationCenter.default.publisher(for: WeshPlatform.keyboardDidHide)) { _ in
            composerFeedback.keyboardDidHide()
        }
        .onReceive(composerDrafts.changes) { change in
            if change.reset, change.generation == composerDrafts.currentGeneration,
               draftGeneration != change.generation {
                composerFeedback.edited(rejection: nil)
                composerFeedbackFocused = false
                draft = ""; draftGeneration = change.generation
            } else if let restored = composerDrafts.restoredText(for: draftKey, from: change) {
                composerFeedback.edited(rejection: nil)
                composerFeedbackFocused = false
                draft = restored; draftGeneration = change.generation
            }
        }
    }

    /// The author a message action may target: the pinned private identity,
    /// or a public sender whose short ID derives exactly from a known key.
    private func moderationTarget(for message: BitchatMessage, knownKeys: [Data]) -> PeerID? {
        guard !WeshMessageActions.isLocalSystem(message),
              !runtime.chatViewModel.isSelfSender(peerID: message.senderPeerID) else { return nil }
        if let pinned = WeshMessageActions.blockIdentity(messageSender: message.senderPeerID, pinnedConversation: peerID) {
            return pinned
        }
        return isPrivate ? nil : WeshMessageActions.publicAuthor(of: message.senderPeerID, knownNoiseKeys: knownKeys)
    }

    @ViewBuilder
    private func moderationActions(for message: BitchatMessage, knownKeys: [Data]) -> some View {
        if let identity = moderationTarget(for: message, knownKeys: knownKeys) {
            let name = WeshDisplayName.blockTarget(sender: message.sender, privateTitle: title, isPrivate: isPrivate)
            let summary: String = weshIdentitySummary(name, fingerprint: identity.noiseKey?.sha256Fingerprint())
            if !isPrivate {
                Button(PaveCopy.text("pave.wesh.action.report"), role: .destructive) {
                    reportTarget = identity
                    reportName = name
                    reportMessage = message
                }
                .accessibilityLabel(PaveCopy.text("pave.wesh.action.reportName", summary))
                .accessibilityHint(PaveCopy.text("pave.wesh.report.hint"))
            }
            Button(PaveCopy.text("pave.wesh.block.onPhone"), role: .destructive) {
                blockTarget = identity
                blockName = name
            }
            .accessibilityLabel(PaveCopy.text("pave.action.block", summary))
            .accessibilityHint(PaveCopy.text("pave.wesh.block.hint"))
        }
    }

    private func send() {
        guard draft.utf8.count <= WeshTextLimits.maximumUTF8Bytes else {
            showComposerFeedback(WeshFeedbackCopy.composerTooLong())
            return
        }
        guard let snapshot = composerDrafts.submission(for: draftKey, displayedText: draft, generation: draftGeneration) else {
            showComposerFeedback(WeshFeedbackCopy.composerChanged())
            return
        }
        if peerID == nil, !runtime.chatViewModel.allowsWeshPublicContent(draft) {
            // Keep the exact text and keyboard focus so the user can edit it.
            composerFeedback.showAction(PaveCopy.text("pave.publicFilter.rejected"))
            return
        }
        if runtime.chatViewModel.sendWeshDraft(&draft, to: peerID) {
            if !composerDrafts.clearIfUnchanged(snapshot) { draft = composerDrafts.load(draftKey) }
            composerFocused = false
        }
    }

    private func showComposerFeedback(_ message: String) {
        composerFeedbackFocused = false
        composerFeedback.showAction(message)
        composerFocused = false
    }
}

enum WeshTimeline {
    static func startsDay(at date: Date, after previous: Date?, calendar: Calendar = .current) -> Bool {
        guard let previous else { return true }
        return !calendar.isDate(date, inSameDayAs: previous)
    }
}

private struct WeshDayDivider: View {
    let date: Date
    @Environment(\.weshTheme) private var theme
    var body: some View {
        Group {
            if Calendar.current.isDateInToday(date) { Text(PaveCopy.text("pave.wesh.date.today")) }
            else if Calendar.current.isDateInYesterday(date) { Text(PaveCopy.text("pave.wesh.date.yesterday")) }
            else { Text(date, format: .dateTime.day().month(.wide).year()) }
        }.font(.caption.weight(.medium)).foregroundStyle(theme.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

struct WeshMessageBubble: View {
    let message: BitchatMessage
    let own: Bool
    let privateChat: Bool
    /// Copied when the bubble is built. `BitchatMessage` is a class that acks update in place, and
    /// SwiftUI compares it by identity: without these values an open chat kept showing the state
    /// and label the message had when it was sent.
    let status: DeliveryStatus
    let transport: MessageTransport?
    @Environment(\.weshTheme) private var theme

    init(message: BitchatMessage, own: Bool, privateChat: Bool) {
        self.message = message
        self.own = own
        self.privateChat = privateChat
        status = message.deliveryStatus
        transport = message.transport
    }

    private var filled: Bool { own && !theme.isDark }
    private var isSystem: Bool { WeshMessageActions.isLocalSystem(message) }
    @ViewBuilder private var metadata: some View {
        Text(message.timestamp, style: .time)
        if own, privateChat { Text(WeshDelivery.label(status, transport: isSystem ? nil : transport)) }
        else if own { Text(WeshDelivery.publicLabel(status)) }
        else if privateChat, !isSystem, let transport { Text(WeshDelivery.transportLabel(transport)) }
    }
    var body: some View {
        HStack {
            if own { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 6) {
                if !own && (!privateChat || isSystem) { Text(isSystem ? PaveCopy.text("pave.bubble.system") : PaveDisplayName.safe(message.sender)).font(.caption.weight(.semibold)).foregroundStyle(filled ? theme.onAccent : theme.secondary) }
                // No system text selection: it would copy to the synced, non-expiring pasteboard.
                Text(WeshIncomingMediaPolicy.displayText(message.content)).font(.body)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) { metadata }
                    VStack(alignment: .leading, spacing: 4) { metadata }
                }.font(.caption).foregroundStyle(filled ? theme.onAccent : theme.secondary)
            }.padding(14)
                .foregroundStyle(filled ? theme.onAccent : theme.ink)
                .background(filled ? theme.accent : theme.canvas, in: RoundedRectangle(cornerRadius: theme.messageRadius))
                .overlay(RoundedRectangle(cornerRadius: theme.messageRadius).strokeBorder(theme.line, lineWidth: filled ? 0 : 1))
            if !own { Spacer(minLength: 32) }
        }
    }
}

enum WeshDelivery {
    /// The public room has no receipts: En attente, Envoyé or Échec, as on Android.
    static func publicLabel(_ status: DeliveryStatus, bundle: Bundle = PaveCopy.bundle, locale: Locale = .current) -> String {
        switch status {
        case .notSentYet, .sending: return PaveCopy.text("pave.wesh.delivery.waiting", bundle: bundle, locale: locale)
        case .failed: return PaveCopy.text("pave.wesh.delivery.failed", bundle: bundle, locale: locale)
        default: return PaveCopy.text("pave.wesh.delivery.sent", bundle: bundle, locale: locale)
        }
    }

    /// « Bluetooth » / « Internet »: how the private message last travelled.
    static func transportLabel(_ transport: MessageTransport, bundle: Bundle = PaveCopy.bundle, locale: Locale = .current) -> String {
        switch transport {
        case .bluetooth: return PaveCopy.text("pave.wesh.transport.bluetooth", bundle: bundle, locale: locale)
        case .internet: return PaveCopy.text("pave.wesh.transport.internet", bundle: bundle, locale: locale)
        }
    }

    /// A private message's state in the spec's words (§3): En attente, Envoyé, Distribué, Lu, Échec.
    /// A courier hand-off is « Envoyé ». With a transport, « Envoyé · Internet », as on Android.
    static func label(_ status: DeliveryStatus, transport: MessageTransport? = nil,
                      bundle: Bundle = PaveCopy.bundle, locale: Locale = .current) -> String {
        let word: String
        switch status {
        case .notSentYet, .sending: word = PaveCopy.text("pave.wesh.delivery.waiting", bundle: bundle, locale: locale)
        case .sent, .carried, .partiallyDelivered: word = PaveCopy.text("pave.wesh.delivery.sent", bundle: bundle, locale: locale)
        case .delivered: word = PaveCopy.text("pave.wesh.delivery.delivered", bundle: bundle, locale: locale)
        case .read: word = PaveCopy.text("pave.wesh.delivery.read", bundle: bundle, locale: locale)
        case .failed: word = PaveCopy.text("pave.wesh.delivery.failed", bundle: bundle, locale: locale)
        }
        guard let transport else { return word }
        return PaveCopy.text("pave.wesh.delivery.withTransport", bundle: bundle, locale: locale,
                             word, transportLabel(transport, bundle: bundle, locale: locale))
    }
}

/// Échanger: my code and the scanner on one screen, both checks, then the chat.
struct WeshContactSheet: View {
    let runtime: AppRuntime
    /// « Ouvrir la discussion »: the sheet closes, then the caller opens this contact's chat.
    var onOpenChat: ((WeshQRTrust.Contact) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var verification: VerificationModel
    @EnvironmentObject private var chrome: AppChromeModel
    @ObservedObject private var trust = WeshQRTrust.shared
    /// Their check counts only from now: an older scan of my code is another meeting.
    @State private var openedAt = Date()
    @State private var myNoiseKey: Data?
    @State private var notice: PaveExchangeNotice?
    @State private var scannedKey: Data?
    @State private var scannedAttemptNonce: Data?
    @State private var scannedName = ""
    @State private var lastScan: (value: String, at: Date)?
    @State private var progress: ChatVerificationCoordinator.QRProgress = .unavailable
    @State private var theyScannedMe = false
    private let progressRefresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if chrome.noiseIdentityAvailability != .available {
                VStack(alignment: .trailing, spacing: 0) {
                    Button(PaveCopy.text("pave.action.close")) { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.horizontal, 16)
                    ScrollView { WeshNoiseIdentityRecoveryPanel().padding(16) }
                }
            } else {
                PaveExchangeScreen(
                    nickname: chrome.nickname,
                    myNoiseKey: myNoiseKey,
                    makePayload: { verification.myQRString() },
                    contactName: scannedKey == nil ? nil : scannedName,
                    contactNoiseKey: progress == .verified ? scannedKey : nil,
                    progress: PaveExchangeProgress(theyScannedMe: theyScannedMe, iScannedThem: progress == .verified),
                    onScan: scan,
                    notice: notice,
                    onPaste: { scan($0, pasted: true) },
                    onComplete: openChat,
                    onClose: { dismiss() })
            }
        }
        .onAppear {
            openedAt = Date()
            myNoiseKey = runtime.chatViewModel.meshService.noiseStaticPublicKeyData()
        }
        .onReceive(progressRefresh) { _ in refreshProgress() }
        .onChange(of: trust.fingerprints) { _ in refreshProgress() }
    }

    private func openChat() {
        if let contact = scannedKey.flatMap({ key in trust.contacts.first { $0.peerID.noiseKey == key } }) {
            onOpenChat?(contact)
        }
        dismiss()
    }

    private func scan(_ value: String) { scan(value, pasted: false) }

    private func scan(_ raw: String, pasted: Bool) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The camera reports the same code on every frame: one attempt per code, and none once verified.
        guard progress != .verified else { return }
        if !pasted, let lastScan, lastScan.value == value,
           progress == .pending || Date().timeIntervalSince(lastScan.at) < 5 { return }
        lastScan = (value, Date())
        scannedKey = nil
        scannedAttemptNonce = nil
        scannedName = ""
        progress = .unavailable
        theyScannedMe = false
        guard chrome.noiseIdentityAvailability == .available else {
            notice = PaveExchangeNotice(WeshNoiseIdentityNotice(chrome.noiseIdentityAvailability)?.message ?? PaveCopy.text("pave.scanResult.identityUnavailable"))
            return
        }
        guard runtime.chatViewModel.identityManager.isPersistenceAvailable else {
            notice = PaveExchangeNotice(PaveCopy.text("pave.scanResult.contactsUnavailable"))
            return
        }
        let own = URL(string: verification.myQRString()).flatMap(VerificationService.VerificationQR.fromURL)
        if let scannedURL = URL(string: value),
           let parsed = VerificationService.VerificationQR.fromURL(scannedURL),
           let own, parsed.noiseKeyHex == own.noiseKeyHex,
           VerificationService.shared.verifyScannedQR(value) != nil {
            notice = PaveExchangeNotice(PaveCopy.text("pave.scanResult.ownCode"))
            return
        }
        switch verification.verifyScannedPayload(value) {
        case .invalid: notice = PaveExchangeNotice(PaveCopy.text("pave.scanResult.invalid"))
        case .notFound: notice = PaveExchangeNotice(PaveCopy.text("pave.scanResult.notFound"))
        case .requested(let name):
            scannedName = name
            if let url = URL(string: value), let parsed = VerificationService.VerificationQR.fromURL(url) {
                scannedKey = Data(hexString: parsed.noiseKeyHex)
                if let scannedKey { scannedAttemptNonce = runtime.chatViewModel.weshQRAttemptNonce(for: scannedKey) }
            }
            notice = PaveExchangeNotice(PaveCopy.text("pave.scanResult.pending", PaveDisplayName.safe(name)))
            refreshProgress()
        }
    }

    private func refreshProgress() {
        // Only for the exchange in flight: a key whose challenge this scan opened.
        guard let scannedKey, let scannedAttemptNonce else { return }
        theyScannedMe = runtime.chatViewModel.weshScannedMyCode(noiseKey: scannedKey, since: openedAt)
        let updated = runtime.chatViewModel.weshQRProgress(for: scannedKey, attemptNonce: scannedAttemptNonce)
        guard updated != progress else { return }
        progress = updated
        switch updated {
        case .verified:
            notice = theyScannedMe ? nil : PaveExchangeNotice(PaveCopy.text("pave.scanResult.verifiedWaiting"))
        case .notSaved:
            notice = PaveExchangeNotice(String(localized: "wesh.verify.contact_not_saved", comment: "Shown after a QR scan when the verified contact could not be saved on this phone"))
        case .expired, .unavailable:
            notice = PaveExchangeNotice(PaveCopy.text("pave.scanResult.noConfirmation"))
        case .pending:
            break
        }
    }
}

private struct WeshInformationSheet: View {
    let isPrivate: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.weshTheme) private var theme
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: isPrivate ? "lock" : "antenna.radiowaves.left.and.right")
                        .font(.largeTitle).foregroundStyle(theme.accent).accessibilityHidden(true)
                    Text(isPrivate ? PaveCopy.text("pave.wesh.info.privateTitle") : PaveCopy.text("pave.wesh.info.publicTitle"))
                        .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text(isPrivate ? PaveCopy.text("pave.wesh.info.privateTrust") : PaveCopy.text("pave.wesh.info.publicTrust"))
                    Text(isPrivate ? PaveCopy.text("pave.wesh.info.privateScope") : PaveCopy.text("pave.wesh.info.publicScope"))
                        .foregroundStyle(theme.secondary)
                    Text(isPrivate ? PaveCopy.text("pave.wesh.info.privateReceipt") : PaveCopy.text("pave.wesh.info.publicMute"))
                        .font(.subheadline).foregroundStyle(theme.secondary)
                    if !isPrivate {
                        Text(PaveCopy.text("pave.publicFilter.help"))
                            .font(.subheadline).foregroundStyle(theme.secondary)
                    }
                }.padding(theme.contentInset)
            }
            .navigationTitle(isPrivate ? PaveCopy.text("pave.wesh.conversation.privateTitle") : PaveCopy.text("pave.wesh.info.roomTitle")).weshInlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(PaveCopy.text("pave.wesh.action.done")) { dismiss() }.frame(minHeight: 44) } }
            .weshCanvas(title: isPrivate ? PaveCopy.text("pave.wesh.conversation.privateTitle") : PaveCopy.text("pave.wesh.info.roomTitle"))
        }.weshSheetBackground()
    }
}

private func bluetoothSummary(_ state: CBManagerState) -> String {
    switch state {
    case .poweredOn: return PaveCopy.text("pave.fluo.bluetooth.on")
    case .poweredOff: return PaveCopy.text("pave.wesh.bluetooth.off")
    case .unauthorized: return PaveCopy.text("pave.wesh.bluetooth.unauthorized")
    case .unsupported: return PaveCopy.text("pave.wesh.bluetooth.unsupported")
    default: return PaveCopy.text("pave.wesh.bluetooth.preparing")
    }
}

private struct WeshSettings: View {
    let runtime: AppRuntime
    @EnvironmentObject private var chrome: AppChromeModel
    @EnvironmentObject private var peers: PeerListModel
    @ObservedObject private var meetingNote: WeshMeetingNoteStore
    @AppStorage("wesh.appearance.v1") private var appearance: WeshAppearance = .night
    @AppStorage(NotificationPrivacySettings.hidePreviewsKey) private var hidePreviews = true
    @State private var destination: PaveSettingsDestination?
    @State private var connexion = false

    init(runtime: AppRuntime) {
        self.runtime = runtime
        _meetingNote = ObservedObject(wrappedValue: runtime.chatViewModel.weshMeetingNote)
    }

    private var summary: PaveSettingsSummary {
        // Read so the rows follow these settings; the values come from the same store below.
        let _ = (peers.renderID, hidePreviews, appearance)
        return PaveSettingsSummary.wesh(nickname: chrome.nickname, meetingNote: meetingNote.content,
                                        blockedCount: runtime.chatViewModel.identityManager.getBlockedFingerprints().count)
    }

    var body: some View {
        // The hold is the confirmation: no alert after it. The wipe rebuilds the tabs, so its
        // outcome shows above the app, in the window the « Tout effacer » shortcut uses.
        PaveSettingsScreen(summary: summary, presentsOutcome: false, onErase: {
            runtime.panicEraseAction(report: { erased in
                PaveEraseRequest.shared.show(PaveEraseScreen.Outcome(erased: erased))
            })()
        }, onSelect: { selected in
            if selected == .connexion { connexion = true } else { destination = selected }
        })
        .navigationTitle(PaveCopy.text("pave.settings.title"))
        .weshHiddenNavigationBar()
        .navigationDestination(isPresented: Binding(get: { destination != nil },
                                                    set: { if !$0 { destination = nil } })) {
            switch destination {
            case .profile: WeshProfileEditor()
            case .discretion: WeshPrivacySettings(runtime: runtime)
            case .meetingPoint: WeshMeetingNote(store: runtime.chatViewModel.weshMeetingNote)
            case .blocked: WeshBlockedContacts(runtime: runtime)
            case .appearance: WeshAppearanceSettings()
            case .about:
                PaveAboutScreen(version: WeshBuildInfo.displayVersion)
                    .navigationTitle(PaveSettingsDestination.about.title).weshInlineTitle()
            case .connexion, nil: EmptyView()
            }
        }
        .sheet(isPresented: $connexion) { WeshConnectionSettings() }
    }
}

@MainActor
private struct WeshContactDetails: View {
    let runtime: AppRuntime
    let contact: WeshQRTrust.Contact
    var inSheet = false
    @ObservedObject private var service: UnifiedPeerService
    @ObservedObject private var trust = WeshQRTrust.shared
    @ObservedObject private var internetMode = WeshInternetMode.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.weshTheme) private var theme
    @State private var removing = false
    @State private var blocking = false
    @State private var feedback = ""
    @State private var reportOffer: PaveReportTarget?
    @State private var localAlias: String
    @State private var localMemo: String
    @State private var editGeneration: UInt64
    @State private var noteOwner: Data?
    @State private var noteFeedback = ""

    init(runtime: AppRuntime, contact: WeshQRTrust.Contact, inSheet: Bool = false) {
        self.runtime = runtime
        self.contact = contact
        self.inSheet = inSheet
        _service = ObservedObject(wrappedValue: runtime.chatViewModel.unifiedPeerService)
        _localAlias = State(initialValue: contact.alias ?? "")
        _localMemo = State(initialValue: contact.memo ?? "")
        _editGeneration = State(initialValue: WeshQRTrust.shared.noteGeneration)
        _noteOwner = State(initialValue: contact.peerID.noiseKey)
    }

    private var currentContact: WeshQRTrust.Contact? {
        trust.contacts.first { $0.id == contact.id }
    }

    private var canEditNotes: Bool {
        trust.storageState == .available && editGeneration == trust.noteGeneration
            && noteOwner?.count == 32 && noteOwner == contact.peerID.noiseKey && currentContact != nil
    }

    private func noteBinding(_ value: Binding<String>, limit: Int, multiline: Bool) -> Binding<String> {
        let generation = editGeneration
        return Binding(get: { value.wrappedValue }, set: { edited in
            guard generation == trust.noteGeneration, canEditNotes else { return }
            value.wrappedValue = WeshContactNotes.editingText(edited, limit: limit, multiline: multiline)
            noteFeedback = ""
        })
    }

    private func saveNotes() {
        guard canEditNotes, let key = noteOwner else { return }
        guard WeshContactNotes.canDisplay(alias: WeshContactNotes.cleanAlias(localAlias)) else {
            noteFeedback = PaveCopy.text("pave.wesh.contactNote.invalidAlias")
            return
        }
        if trust.setNote(sessionKey: key, alias: localAlias, memo: localMemo, generation: editGeneration) {
            localAlias = currentContact?.alias ?? ""
            localMemo = currentContact?.memo ?? ""
            noteFeedback = PaveCopy.text("pave.wesh.contactNote.saved")
        } else {
            noteFeedback = PaveCopy.text("pave.wesh.contactNote.failed")
        }
    }

    private var blocked: Bool {
        contact.peerID.noiseKey.map { runtime.chatViewModel.identityManager.isBlocked(fingerprint: $0.sha256Fingerprint()) } ?? false
    }

    /// The stored record, so a rescan while this page is open updates the badge.
    private var internetBadge: PaveContactInternetBadge? {
        // Fail closed: a contact removed while this page is open gets no badge.
        guard let current = currentContact else { return nil }
        return PaveContactInternetBadge(contact: current, internet: internetMode.internetStatus,
                                        routable: runtime.chatViewModel.isWeshInternetContact(current.peerID),
                                        blocked: blocked)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    WeshAvatar(symbol: "person")
                    if let current = currentContact {
                        Text(PaveDisplayName.safe(current.displayName)).font(.title2.weight(.semibold))
                        Text(PaveCopy.text("pave.wesh.contactNote.qrName", PaveDisplayName.safe(current.nickname)))
                            .font(.subheadline).foregroundStyle(theme.secondary)
                        PaveFingerprintText(fingerprint: PaveFingerprint.short(current.peerID.noiseKey))
                    } else {
                        Text(PaveCopy.text("pave.wesh.contactNote.unavailable")).font(.subheadline)
                    }
                    if currentContact != nil {
                        Label(blocked ? PaveCopy.text("pave.wesh.contact.blocked") : PaveCopy.text("pave.wesh.contact.verifiedHere"), systemImage: blocked ? "hand.raised" : "lock")
                            .font(.subheadline).foregroundStyle(theme.secondary)
                    }
                    if let internetBadge {
                        PaveInternetBadge(badge: internetBadge)
                        if internetBadge == .rescanRequired {
                            Text(PaveCopy.text("pave.contact.rescanHelp"))
                                .font(.subheadline).foregroundStyle(theme.secondary)
                        }
                    }
                    Text(PaveCopy.text("pave.wesh.contact.qrNameScope"))
                        .font(.subheadline).foregroundStyle(theme.secondary)
                }.padding(.vertical, 16)
            }.listRowBackground(theme.canvas)
            Section {
                if canEditNotes {
                    TextField(PaveCopy.text("pave.wesh.contactNote.alias"),
                              text: noteBinding($localAlias, limit: WeshContactNotes.maximumAliasScalars, multiline: false))
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .accessibilityLabel(PaveCopy.text("pave.wesh.contactNote.alias"))
                    TextField(PaveCopy.text("pave.wesh.contactNote.memo"),
                              text: noteBinding($localMemo, limit: WeshContactNotes.maximumMemoScalars, multiline: true), axis: .vertical)
                        .lineLimit(3...8)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .accessibilityLabel(PaveCopy.text("pave.wesh.contactNote.memo"))
                    Button(PaveCopy.text("pave.wesh.action.save"), action: saveNotes).frame(minHeight: 44)
                } else {
                    Text(PaveCopy.text("pave.wesh.contactNote.unavailable")).font(.subheadline)
                }
                if !noteFeedback.isEmpty {
                    Text(noteFeedback).font(.subheadline).accessibilityAddTraits(.updatesFrequently)
                }
            } footer: {
                Text(PaveCopy.text("pave.wesh.contactNote.scope"))
            }.listRowBackground(theme.canvas).listRowSeparatorTint(theme.line)
            Section {
                if blocked {
                    Button(PaveCopy.text("pave.wesh.action.unblock")) {
                        if let key = contact.peerID.noiseKey, runtime.chatViewModel.unblockWeshIdentity(key.sha256Fingerprint()) {
                            feedback = PaveCopy.text("pave.wesh.contact.unblocked")
                        } else { feedback = PaveCopy.text("pave.wesh.contact.notBlocked") }
                    }.frame(minHeight: 48)
                        .accessibilityLabel(PaveCopy.text("pave.wesh.action.unblockName", weshIdentitySummary(PaveDisplayName.safe(contact.nickname), fingerprint: contact.peerID.noiseKey?.sha256Fingerprint())))
                        .accessibilityHint(PaveCopy.text("pave.wesh.unblock.hint"))
                } else {
                    Button(PaveCopy.text("pave.wesh.block.onPhone"), role: .destructive) { blocking = true }.frame(minHeight: 48)
                        .accessibilityLabel(PaveCopy.text("pave.action.block", weshIdentitySummary(PaveDisplayName.safe(contact.nickname), fingerprint: contact.peerID.noiseKey?.sha256Fingerprint())))
                        .accessibilityHint(PaveCopy.text("pave.wesh.block.hint"))
                }
                Button(PaveCopy.text("pave.wesh.contact.remove"), role: .destructive) { removing = true }.frame(minHeight: 48)
                if !feedback.isEmpty { Text(feedback).font(.subheadline).accessibilityAddTraits(.updatesFrequently) }
            } footer: {
                Text(PaveCopy.text("pave.wesh.contact.removeScope"))
            }.listRowBackground(theme.canvas).listRowSeparatorTint(theme.line)
        }.listStyle(.plain).scrollContentBackground(.hidden)
            .onChange(of: trust.noteGeneration) { _ in
                localAlias = ""; localMemo = ""; noteFeedback = ""
            }
            .navigationTitle(PaveCopy.text("pave.wesh.contact.title")).weshInlineTitle().weshCanvas(title: PaveCopy.text("pave.wesh.contact.title"))
            .toolbar { if inSheet { ToolbarItem(placement: .confirmationAction) { Button(PaveCopy.text("pave.wesh.action.done")) { dismiss() }.frame(minHeight: 44) } } }
            .alert(PaveCopy.text("pave.wesh.block.contactTitle"), isPresented: $blocking) {
                Button(PaveCopy.text("pave.action.cancel"), role: .cancel) {}
                Button(PaveCopy.text("pave.wesh.action.block"), role: .destructive) {
                    let reported = PaveReportTarget(rawNickname: contact.nickname, fingerprint: PaveFingerprint.short(contact.peerID.noiseKey), source: .contact)
                    reportOffer = PaveReportMail.blockThenOffer(reported) {
                        runtime.chatViewModel.blockMeshPeer(peerID: contact.peerID, displayName: PaveDisplayName.safe(contact.nickname))
                        return true
                    }.offer
                    feedback = PaveCopy.text("pave.wesh.contact.blockConfirmed")
                }
                .accessibilityLabel(PaveCopy.text("pave.action.block", weshIdentitySummary(PaveDisplayName.safe(contact.nickname), fingerprint: contact.peerID.noiseKey?.sha256Fingerprint())))
            } message: { Text(PaveCopy.text("pave.wesh.contact.unblockOffline")) }
            .paveReportSendFlow($reportOffer)
            .alert(PaveCopy.text("pave.wesh.contact.removeTitle"), isPresented: $removing) {
                Button(PaveCopy.text("pave.action.cancel"), role: .cancel) {}
                Button(PaveCopy.text("pave.wesh.action.remove"), role: .destructive) {
                    // The key leaves the sending allowlist either way; only a
                    // confirmed write closes this page.
                    if let key = contact.peerID.noiseKey, runtime.chatViewModel.removeWeshContact(for: key) {
                        dismiss()
                    } else {
                        feedback = PaveCopy.text("pave.wesh.contact.removeFailed")
                    }
                }
            } message: { Text(PaveCopy.text("pave.wesh.contact.removeBody")) }
    }
}

private struct WeshNearbyPeople: View {
    let runtime: AppRuntime
    @ObservedObject private var service: UnifiedPeerService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.weshTheme) private var theme
    @State private var selected: WeshQRTrust.Contact?
    @State private var feedback = ""

    init(runtime: AppRuntime) {
        self.runtime = runtime
        _service = ObservedObject(wrappedValue: runtime.chatViewModel.unifiedPeerService)
    }

    private var participants: [BitchatPeer] {
        service.peers.filter { $0.noisePublicKey.count == 32 && ($0.isConnected || $0.isReachable) }
    }

    var body: some View {
        List {
            Section {
                if participants.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(PaveCopy.text("pave.wesh.participants.empty")).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        Text(PaveCopy.text("pave.wesh.participants.emptyBody")).foregroundStyle(theme.secondary)
                    }.padding(.vertical, 24).listRowSeparator(.hidden)
                } else {
                    ForEach(participants, id: \.peerID) { person in
                        let name = PaveDisplayName.safe(person.displayName)
                        // One identity for the whole row: the key this peer proved in its Noise session.
                        // An announced key can be copied, so without a proven one there is nothing to block.
                        let proven = runtime.chatViewModel.noiseSessionPublicKeyData(for: person.peerID)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(name).font(.headline)
                            PaveFingerprintText(fingerprint: PaveFingerprint.short(proven))
                            if let proven, runtime.chatViewModel.identityManager.isBlocked(fingerprint: proven.sha256Fingerprint()) {
                                Text(PaveCopy.text("pave.wesh.contact.blocked")).font(.subheadline).foregroundStyle(theme.secondary)
                            } else if let proven {
                                Button(PaveCopy.text("pave.wesh.block.onPhone"), role: .destructive) {
                                    selected = .init(noiseKeyHex: proven.hexEncodedString(), nickname: name)
                                }.frame(minHeight: 44)
                                    .accessibilityLabel(PaveCopy.text("pave.action.block", weshIdentitySummary(name, fingerprint: proven.sha256Fingerprint())))
                                    .accessibilityHint(PaveCopy.text("pave.wesh.block.hint"))
                            }
                        }.padding(.vertical, 8)
                    }
                }
                if !feedback.isEmpty { Text(feedback).font(.subheadline).accessibilityAddTraits(.updatesFrequently) }
            } footer: { Text(PaveCopy.text("pave.wesh.participants.scope")) }
            .listRowBackground(theme.canvas).listRowSeparatorTint(theme.line)
        }.listStyle(.plain).scrollContentBackground(.hidden)
            .navigationTitle(PaveCopy.text("pave.wesh.participants.title")).weshInlineTitle().weshCanvas(title: PaveCopy.text("pave.wesh.participants.title"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(PaveCopy.text("pave.wesh.action.done")) { dismiss() }.frame(minHeight: 44) } }
            .alert(PaveCopy.text("pave.wesh.block.personTitle"), isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                Button(PaveCopy.text("pave.action.cancel"), role: .cancel) { selected = nil }
                Button(PaveCopy.text("pave.wesh.action.block"), role: .destructive) {
                    if let person = selected {
                        runtime.chatViewModel.blockMeshPeer(peerID: person.peerID, displayName: person.nickname)
                        feedback = PaveCopy.text("pave.wesh.block.confirmed")
                    }
                    selected = nil
                }
                .accessibilityLabel(PaveCopy.text("pave.action.block", selected.map { weshIdentitySummary($0.nickname, fingerprint: $0.peerID.noiseKey?.sha256Fingerprint()) } ?? PaveCopy.text("pave.wesh.person.lowercase")))
            } message: {
                Text(PaveCopy.text("pave.wesh.block.namedBody", selected.map { $0.nickname + " · " + (PaveFingerprint.short($0.peerID.noiseKey) ?? "") } ?? PaveCopy.text("pave.wesh.person.capitalized")))
            }
    }
}

private struct WeshBlockedContacts: View {
    let runtime: AppRuntime
    @ObservedObject private var service: UnifiedPeerService
    @Environment(\.weshTheme) private var theme
    @State private var selectedFingerprint: String?
    @State private var feedback = ""

    init(runtime: AppRuntime) {
        self.runtime = runtime
        _service = ObservedObject(wrappedValue: runtime.chatViewModel.unifiedPeerService)
    }

    private var fingerprints: [String] { runtime.chatViewModel.identityManager.getBlockedFingerprints().sorted() }
    private func name(for fingerprint: String) -> String {
        let identity = runtime.chatViewModel.identityManager.getSocialIdentity(for: fingerprint)
        return WeshDisplayName.blockedContact(petname: identity?.localPetname, claimedNickname: identity?.claimedNickname)
    }

    var body: some View {
        List {
            Section {
                if fingerprints.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(PaveCopy.text("pave.wesh.blocked.empty")).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        Text(PaveCopy.text("pave.wesh.blocked.emptyBody")).foregroundStyle(theme.secondary)
                    }.padding(.vertical, 24).listRowSeparator(.hidden)
                } else {
                    ForEach(fingerprints, id: \.self) { fingerprint in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(name(for: fingerprint)).font(.headline)
                            PaveFingerprintText(fingerprint: weshShortFingerprint(hex: fingerprint))
                            Button(PaveCopy.text("pave.wesh.action.unblock")) { selectedFingerprint = fingerprint }.frame(minHeight: 44)
                                .accessibilityLabel(PaveCopy.text("pave.wesh.action.unblockName", weshIdentitySummary(name(for: fingerprint), fingerprint: fingerprint)))
                                .accessibilityHint(PaveCopy.text("pave.wesh.unblock.confirmHint"))
                        }.padding(.vertical, 8)
                    }
                }
                if !feedback.isEmpty { Text(feedback).font(.subheadline).accessibilityAddTraits(.updatesFrequently) }
            } footer: { Text(PaveCopy.text("pave.wesh.unblock.scope")) }
            .listRowBackground(theme.canvas).listRowSeparatorTint(theme.line)
        }.listStyle(.plain).scrollContentBackground(.hidden)
            .navigationTitle(PaveCopy.text("pave.wesh.blocked.title")).weshInlineTitle().weshCanvas(title: PaveCopy.text("pave.wesh.blocked.title"))
            .alert(PaveCopy.text("pave.wesh.unblock.personTitle"), isPresented: Binding(get: { selectedFingerprint != nil }, set: { if !$0 { selectedFingerprint = nil } })) {
                Button(PaveCopy.text("pave.action.cancel"), role: .cancel) { selectedFingerprint = nil }
                Button(PaveCopy.text("pave.wesh.action.unblock")) {
                    if let fingerprint = selectedFingerprint {
                        feedback = runtime.chatViewModel.unblockWeshIdentity(fingerprint) ? PaveCopy.text("pave.wesh.unblock.confirmed") : PaveCopy.text("pave.wesh.unblock.notBlocked")
                    }
                    selectedFingerprint = nil
                }
                .accessibilityLabel(PaveCopy.text("pave.wesh.action.unblockName", selectedFingerprint.map { weshIdentitySummary(name(for: $0), fingerprint: $0) } ?? PaveCopy.text("pave.wesh.person.lowercase")))
            } message: { Text(PaveCopy.text("pave.wesh.unblock.namedBody", selectedFingerprint.map { name(for: $0) + " · " + (weshShortFingerprint(hex: $0) ?? "") } ?? PaveCopy.text("pave.wesh.person.lowercase"))) }
    }
}

private struct WeshAppearanceSettings: View {
    @AppStorage("wesh.appearance.v1") private var appearance: WeshAppearance = .night
    @Environment(\.weshTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(PaveCopy.text("pave.wesh.appearance.intro")).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                ForEach(WeshAppearance.allCases) { choice in
                    let palette = WeshTheme(appearance: choice)
                    Button { appearance = choice } label: {
                        HStack(spacing: 20) {
                            if !dynamicTypeSize.isAccessibilitySize {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("wesh").font(.system(.title2, design: .rounded).weight(.bold))
                                    Capsule().fill(palette.metalFill).frame(width: 44, height: 8)
                                    Capsule().fill(palette.ink).frame(width: 30, height: 4)
                                }.foregroundStyle(palette.ink).frame(width: 96, height: 108)
                                    .background(palette.canvas, in: RoundedRectangle(cornerRadius: palette.radius))
                                    .overlay(RoundedRectangle(cornerRadius: palette.radius).strokeBorder(theme.line, lineWidth: 1))
                                    .accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(choice.title).font(.headline)
                                Text(choice.subtitle).font(.subheadline).foregroundStyle(theme.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: appearance == choice ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(theme.accent).accessibilityHidden(true)
                        }.foregroundStyle(theme.ink).padding(.vertical, 8)
                    }.buttonStyle(.plain).accessibilityAddTraits(appearance == choice ? .isSelected : [])
                }
                Text(PaveCopy.text("pave.wesh.appearance.qrScope"))
                    .font(.subheadline).foregroundStyle(theme.secondary)
            }.padding(theme.contentInset)
        }.navigationTitle(PaveCopy.text("pave.settings.appearance")).weshInlineTitle().weshCanvas(title: PaveCopy.text("pave.settings.appearance"))
    }
}

private struct WeshProfileEditor: View {
    @EnvironmentObject private var chrome: AppChromeModel
    @Environment(\.weshTheme) private var theme
    @State private var nickname = ""
    @State private var feedback = ""
    @FocusState private var nicknameFocused: Bool
    @AccessibilityFocusState(for: .voiceOver) private var feedbackFocused: Bool
    @State private var softwareKeyboardVisible = false
    @State private var waitingForKeyboard = false
    @State private var focusRevision = 0

    var body: some View {
        ScrollViewReader { scroll in
            Form {
                Section {
                    TextField(PaveCopy.text("pave.onboarding.nicknameLabel"), text: $nickname).focused($nicknameFocused).onSubmit(save)
                        .accessibilityLabel(PaveCopy.text("pave.onboarding.nicknameLabel"))
                    Button(PaveCopy.text("pave.wesh.action.save"), action: save).frame(minHeight: 44)
                    if !feedback.isEmpty {
                        Text(feedback).font(.subheadline).id("profileFeedback")
                            .accessibilityFocused($feedbackFocused)
                    }
                } header: { WeshSectionLabel(text: PaveCopy.text("pave.onboarding.nicknameLabel")) } footer: {
                    Text(PaveCopy.text("pave.wesh.profile.scope"))
                }.listRowBackground(theme.canvas)
            }.scrollContentBackground(.hidden).navigationTitle(PaveCopy.text("pave.wesh.profile.title")).weshCanvas(title: PaveCopy.text("pave.wesh.profile.title"))
                .onAppear { nickname = chrome.nickname }
                .onChange(of: focusRevision) { _ in
                    scroll.scrollTo("profileFeedback", anchor: .center)
                    DispatchQueue.main.async { feedbackFocused = true }
                }
                .onReceive(NotificationCenter.default.publisher(for: WeshPlatform.keyboardWillShow)) { _ in softwareKeyboardVisible = true }
                .onReceive(NotificationCenter.default.publisher(for: WeshPlatform.keyboardDidHide)) { _ in
                    softwareKeyboardVisible = false
                    if waitingForKeyboard { waitingForKeyboard = false; focusRevision += 1 }
                }
        }
    }

    private func save() {
        let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, value.utf8.count <= 255 {
            chrome.setNickname(value); chrome.validateAndSaveNickname(); nickname = chrome.nickname
            feedback = PaveCopy.text("pave.wesh.profile.saved")
        } else { feedback = PaveCopy.text("pave.wesh.profile.invalid") }
        feedbackFocused = false
        waitingForKeyboard = nicknameFocused && softwareKeyboardVisible
        nicknameFocused = false
        if !waitingForKeyboard { focusRevision += 1 }
    }
}

private struct WeshConnectionSettings: View {
    @EnvironmentObject private var chrome: AppChromeModel
    @EnvironmentObject private var peers: PeerListModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            if chrome.noiseIdentityAvailability != .available {
                WeshNoiseIdentityRecoveryPanel().padding(16)
            }
            PaveConnexionSheet(bluetooth: PaveBluetoothStatus(chrome.bluetoothState),
                               peersInRange: peers.connectedMeshPeerCount,
                               internet: WeshInternetMode.shared,
                               onClose: { dismiss() })
        }
    }
}

private struct WeshPrivacySettings: View {
    let runtime: AppRuntime
    // periphery:ignore - observed so the view re-renders when QR trust changes
    @ObservedObject private var trust = WeshQRTrust.shared
    @Environment(\.weshTheme) private var theme
    @State private var forgetContacts = false
    @State private var forgetFeedback = ""
    @AppStorage(NotificationPrivacySettings.hidePreviewsKey) private var hidePreviews = true
    var body: some View {
        Form {
            Section {
                Text(PaveCopy.text("pave.wesh.privacy.scope"))
                Text(PaveCopy.text("pave.wesh.privacy.publicCopies")).foregroundStyle(theme.secondary)
            }.listRowBackground(theme.canvas)
            Section {
                Button(PaveCopy.text("pave.wesh.privacy.removeVerifications"), role: .destructive) { forgetContacts = true }.frame(minHeight: 44)
                if !forgetFeedback.isEmpty {
                    Text(forgetFeedback).font(.subheadline).accessibilityAddTraits(.updatesFrequently)
                }
            }.listRowBackground(theme.canvas)
            Section {
                Toggle(PaveCopy.text("pave.settings.previewsToggle"), isOn: $hidePreviews).frame(minHeight: 44)
            } footer: {
                Text(PaveCopy.text("pave.settings.previewsHelp"))
            }.listRowBackground(theme.canvas)
        }.scrollContentBackground(.hidden).navigationTitle(PaveSettingsDestination.discretion.title).weshCanvas(title: PaveSettingsDestination.discretion.title)
            .alert(PaveCopy.text("pave.wesh.privacy.removeTitle"), isPresented: $forgetContacts) {
                Button(PaveCopy.text("pave.action.cancel"), role: .cancel) {}
                Button(PaveCopy.text("pave.wesh.action.remove"), role: .destructive) {
                    forgetFeedback = runtime.chatViewModel.removeAllWeshContacts()
                        ? PaveCopy.text("pave.wesh.privacy.removed")
                        : PaveCopy.text("pave.wesh.privacy.removeFailed")
                }
            } message: { Text(PaveCopy.text("pave.wesh.privacy.removeBody")) }
    }
}

private struct WeshMeetingNote: View {
    @Environment(\.weshTheme) private var theme
    @ObservedObject var store: WeshMeetingNoteStore
    @State private var clear = false
    private func textBinding(_ field: WritableKeyPath<WeshMeetingNoteStore.Content, String>, generation: UInt64) -> Binding<String> {
        Binding(get: { store.content[keyPath: field] }, set: { value in
            store.edit(field, value: value, generation: generation)
        })
    }
    var body: some View {
        let generation = store.generation
        Form {
            Section {
                Label(PaveCopy.text("pave.wesh.note.introTitle"), systemImage: "calendar").font(.headline)
                Text(PaveCopy.text("pave.wesh.note.introBody")).foregroundStyle(theme.secondary)
            }.listRowBackground(theme.canvas)
            Section(PaveCopy.text("pave.wesh.note.section")) {
                TextField(PaveCopy.text("pave.wesh.note.title"), text: textBinding(\.title, generation: generation))
                TextField(PaveCopy.text("pave.wesh.note.place"), text: textBinding(\.place, generation: generation))
                DatePicker(PaveCopy.text("pave.wesh.note.when"), selection: Binding(get: { Date(timeIntervalSince1970: store.content.date) }, set: {
                    store.editDate($0.timeIntervalSince1970, generation: generation)
                }))
                TextField(PaveCopy.text("pave.wesh.note.remember"), text: textBinding(\.note, generation: generation), axis: .vertical).lineLimit(3...8)
            }.disabled(!store.isEditable).listRowBackground(theme.canvas)
            if store.isSuspended {
                Text(PaveCopy.text("pave.wesh.note.suspended"))
            } else if store.storageState == .unavailable {
                Text(PaveCopy.text("pave.wesh.note.unavailable"))
                Button(PaveCopy.text("pave.delivery.retry")) { store.reloadIfNeeded() }.frame(minHeight: 44)
            } else if store.storageState == .recoveryRequired {
                Text(PaveCopy.text("pave.wesh.note.recovery"))
            } else if !store.isSaveConfirmed {
                Text(PaveCopy.text("pave.wesh.note.unconfirmed"))
            }
            Section { Button(PaveCopy.text("pave.wesh.note.eraseAction"), role: .destructive) { clear = true }.frame(minHeight: 44).disabled(store.isSuspended) }.listRowBackground(theme.canvas)
        }
        .scrollContentBackground(.hidden).weshCanvas(title: PaveCopy.text("pave.wesh.note.screen"))
        .navigationTitle(PaveCopy.text("pave.wesh.note.screen"))
        .alert(PaveCopy.text("pave.wesh.note.eraseTitle"), isPresented: $clear) {
            Button(PaveCopy.text("pave.action.cancel"), role: .cancel) {}
            Button(PaveCopy.text("pave.wesh.action.erase"), role: .destructive) { store.clear(generation: generation) }
        }
    }
}

/// `safeName` has already been through `PaveDisplayName.safe`, once: a second pass would turn
/// « Sans surnom » into « Sans surnom (réservé) ».
private func weshIdentitySummary(_ safeName: String, fingerprint: String?) -> String {
    guard let short = weshShortFingerprint(hex: fingerprint) else { return safeName }
    return safeName + ", " + PaveFingerprint.accessibilityText(short)
}

/// The full short fingerprint ("A1B2 C3D4 E5F6 0718") of a SHA-256 fingerprint in hex; never shortened.
/// Fails closed on anything but a whole 64-digit ASCII hex fingerprint.
func weshShortFingerprint(hex: String?) -> String? {
    guard let hex, hex.count == 64, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
    let digits = Array(hex.uppercased().prefix(16))
    return stride(from: 0, to: 16, by: 4).map { String(digits[$0..<$0 + 4]) }.joined(separator: " ")
}

private func openWeshSystemSettings() {
    #if os(iOS)
    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    #endif
}
