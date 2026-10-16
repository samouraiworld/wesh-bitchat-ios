import BitFoundation
import CryptoKit
import CoreBluetooth
import Foundation
import Testing
@testable import bitchat

private final class WeshWipeFileManager: FileManager, @unchecked Sendable {
    var refuseRemoval = false
    var leaveFilePresent = false
    var refuseProbe = false
    override func removeItem(at URL: URL) throws {
        if refuseRemoval { throw CocoaError(.fileWriteNoPermission) }
        if !leaveFilePresent { try super.removeItem(at: URL) }
    }
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if refuseProbe { throw CocoaError(.fileReadNoPermission) }
        return try super.attributesOfItem(atPath: path)
    }
}

@Suite("Wesh native trust and public separation", .serialized)
struct WeshNativeUITests {
    @Test func rejectedComposerEditStaysInlineWithoutRequestingFocus() {
        var feedback = WeshComposerFeedbackState()
        feedback.appear()
        feedback.keyboardWillShow()
        feedback.edited(rejection: "Synthetic rejected edit")
        #expect(feedback.message == "Synthetic rejected edit")
        #expect(feedback.isEditingRejection)
        #expect(feedback.pendingFocus == nil)
        feedback.keyboardDidHide()
        #expect(feedback.readyFocus == nil)
        feedback.edited(rejection: nil)
        #expect(feedback.message.isEmpty)
        #expect(!feedback.isEditingRejection)
        #expect(feedback.pendingFocus == nil)
    }

    @Test func explicitComposerResultWaitsForKeyboardAndFocusesOnlyOnce() throws {
        var feedback = WeshComposerFeedbackState()
        feedback.appear()
        feedback.keyboardWillShow()
        feedback.showAction("Synthetic action result")
        let request = try #require(feedback.pendingFocus)
        #expect(feedback.readyFocus == nil)
        #expect(feedback.consume(request) == nil)
        #expect(feedback.pendingFocus == request)
        feedback.keyboardDidHide()
        #expect(feedback.readyFocus == request)
        feedback.keyboardWillShow()
        #expect(feedback.consume(request) == nil, "A queued callback must recheck keyboard visibility")
        feedback.keyboardDidHide()
        #expect(feedback.consume(request) == .feedback)
        #expect(feedback.consume(request) == nil)
        #expect(feedback.readyFocus == nil)
    }

    @Test func repeatedResultAndNewEditsInvalidateAlreadyQueuedFocus() throws {
        var feedback = WeshComposerFeedbackState()
        feedback.appear()
        feedback.showAction("Synthetic repeated result")
        let first = try #require(feedback.readyFocus)
        feedback.showAction("Synthetic repeated result")
        let second = try #require(feedback.readyFocus)
        #expect(first != second)
        #expect(feedback.consume(first) == nil)
        #expect(feedback.readyFocus == second)
        feedback.edited(rejection: "Synthetic inline error")
        #expect(feedback.consume(second) == nil)
        #expect(feedback.isEditingRejection)
        feedback.showAction("Synthetic result before accepted edit")
        let third = try #require(feedback.readyFocus)
        feedback.edited(rejection: nil)
        #expect(feedback.consume(third) == nil)
        #expect(feedback.message.isEmpty)
        feedback.showAction("Synthetic result before returning to editor")
        let fourth = try #require(feedback.readyFocus)
        feedback.composerBecameFocused()
        #expect(feedback.consume(fourth) == nil)
    }

    @Test func disappearedConversationCannotFocusItsOldResultOrImportedDraft() throws {
        var feedback = WeshComposerFeedbackState()
        feedback.appear()
        feedback.showAction("Synthetic result")
        let oldResult = try #require(feedback.readyFocus)
        feedback.disappear()
        feedback.showAction("Synthetic late hidden action")
        #expect(feedback.pendingFocus == nil)
        feedback.keyboardDidHide()
        #expect(feedback.consume(oldResult) == nil)
        feedback.appear()
        #expect(feedback.readyFocus == nil)
        feedback.showImportedDraft("Synthetic imported draft", focusComposer: true)
        let oldImport = try #require(feedback.readyFocus)
        feedback.disappear()
        feedback.appear()
        feedback.showImportedDraft("Synthetic imported draft", focusComposer: true)
        let currentImport = try #require(feedback.readyFocus)
        #expect(feedback.consume(oldImport) == nil)
        #expect(feedback.consume(currentImport) == .composer)
        #expect(feedback.consume(currentImport) == nil)
        feedback.showImportedDraft("Synthetic import before editing", focusComposer: true)
        let editedImport = try #require(feedback.readyFocus)
        feedback.edited(rejection: nil)
        #expect(feedback.consume(editedImport) == nil)
        feedback.showImportedDraft("Synthetic dismissed review", focusComposer: false)
        #expect(feedback.readyFocus == nil)
    }

    @Test(arguments: ["gossip", "courier", "bridge", "prekeys", "board", "groups", "outbox"]) @MainActor
    func panicFileStoresRejectUnlinkFailureAndAllowVerifiedRetry(kind: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("checked-wipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.json")
        let bytes = Data("synthetic local fixture".utf8)
        try bytes.write(to: url)
        let files = WeshWipeFileManager()
        files.refuseRemoval = true
        let wipe: () -> Bool
        switch kind {
        case "gossip":
            let store = GossipMessageArchive(fileURL: url, wipeFileManager: files)
            wipe = { store.wipe() }
        case "courier":
            let store = CourierStore(fileURL: url, wipeFileManager: files)
            wipe = { store.wipe() }
        case "bridge":
            let store = BridgeDropDedupStore(fileURL: url, wipeFileManager: files)
            wipe = { store.wipe() }
        case "prekeys":
            let store = PrekeyBundleStore(fileURL: url, wipeFileManager: files)
            wipe = { store.wipe() }
        case "board":
            let store = BoardStore(fileURL: url, wipeFileManager: files)
            wipe = { store.wipe() }
        case "groups":
            let store = GroupStore(keychain: MockKeychain(), fileURL: url, wipeFileManager: files)
            wipe = { store.wipe() }
        default:
            let store = MessageOutboxStore(keychain: MockKeychain(), fileURL: url, wipeFileManager: files)
            wipe = { store.wipe() }
        }
        #expect(!wipe())
        #expect(try Data(contentsOf: url) == bytes)
        files.refuseRemoval = false
        files.leaveFilePresent = true
        #expect(!wipe(), "An acknowledged unlink is insufficient while the file still exists")
        files.leaveFilePresent = false
        files.refuseProbe = true
        #expect(!wipe(), "An unknown absence readback cannot confirm cleanup")
        files.refuseProbe = false
        #expect(wipe())
        #expect(wipe(), "ENOENT is an explicitly absent file")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func missingProductionPathIsNotAnEmptyStore() {
        #expect(!PanicFileRemoval.remove(nil, required: true))
        #expect(PanicFileRemoval.remove(nil, required: false))
    }

    @Test func retiredGossipArchiveCannotRestoreSaveOrWipeANewManagersFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retired-gossip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("public.json")
        let old = GossipMessageArchive(fileURL: url)
        old.save([Data("old signed fixture".utf8)])
        #expect(old.load().count == 1)
        old.retireForPanic()
        let current = GossipMessageArchive(fileURL: url)
        #expect(current.wipe())
        old.save([Data("late old save".utf8)])
        #expect(old.load().isEmpty)
        #expect(current.load().isEmpty)
        let fresh = Data("new generation fixture".utf8)
        current.save([fresh])
        #expect(!old.wipe())
        old.save([Data("late old rewrite".utf8)])
        #expect(current.load() == [fresh])
    }

    @Test(arguments: ["courier", "bridge", "archive", "prekeys", "board", "share", "groups", "outbox"]) @MainActor
    func everyPersistentStoreRefusalBlocksGlobalCommitAndAllStoresAreStillAttempted(failing: String) throws {
        var failed = true
        var attempts: [String] = []
        func wipe(_ name: String) -> Bool { attempts.append(name); return !(failed && name == failing) }
        let wipes = PanicPersistentStoreWipes(
            courier: { wipe("courier") }, bridge: { wipe("bridge") },
            publicArchive: { wipe("archive") }, prekeys: { wipe("prekeys") },
            board: { wipe("board") }, sharedContent: { wipe("share") }
        )
        let keychain = MockKeychain()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("global-checked-wipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fixture.json")
        try Data("synthetic persisted metadata".utf8).write(to: url)
        let files = WeshWipeFileManager()
        files.refuseRemoval = true
        let group = failing == "groups" ? GroupStore(keychain: keychain, fileURL: url, wipeFileManager: files) : nil
        let outbox = failing == "outbox" ? MessageOutboxStore(keychain: keychain, fileURL: url, wipeFileManager: files) : nil
        let transport = MockTransport()
        var committed = 0
        let operations = PanicRecoveryOperations(isPending: { false }, begin: {
            PanicRecoveryIntent(fileMarkerEstablished: true, externalMarkerEstablished: false)
        }, wipeMedia: { _ in }, complete: { committed += 1 })
        let vm = ChatViewModel(keychain: keychain, idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain), transport: transport, outboxStore: outbox,
            panicRecoveryOperations: operations, weshPrivatePolicyEnabled: true,
            panicPersistentStoreWipes: wipes, groupStore: group)
        let starts = transport.startServicesCallCount
        #expect(!vm.panicClearAllData())
        #expect(attempts == ["courier", "bridge", "archive", "prekeys", "board", "share"])
        #expect(committed == 0 && vm.panicRecoveryBlocked)
        #expect(transport.startServicesCallCount == starts)
        #expect(vm.weshMeetingNote.isSuspended)
        failed = false
        files.refuseRemoval = false
        attempts.removeAll()
        #expect(vm.panicClearAllData())
        #expect(committed == 1 && !vm.panicRecoveryBlocked)
        #expect(transport.startServicesCallCount == starts + 1)
        #expect(attempts.count == 6)
    }

    @Test @MainActor func meetingNoteWipeRemovesEveryPersistedFieldAndRejectsOldEditorEvents() throws {
        let suite = "wesh-note-wipe-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WeshMeetingNoteStore(defaults: defaults)
        let oldGeneration = store.generation
        #expect(store.edit(\.title, value: "Titre synthétique", generation: oldGeneration))
        #expect(store.edit(\.place, value: "Repère synthétique", generation: oldGeneration))
        #expect(store.edit(\.note, value: "Note synthétique", generation: oldGeneration))
        #expect(store.editDate(123, generation: oldGeneration))
        #expect(defaults.string(forKey: "wesh.meeting.title") == "Titre synthétique")
        #expect(defaults.string(forKey: "wesh.meeting.place") == "Repère synthétique")
        #expect(defaults.string(forKey: "wesh.meeting.note") == "Note synthétique")
        #expect(defaults.double(forKey: "wesh.meeting.date") == 123)
        store.suspendForPanic()
        let suspendedGeneration = store.generation
        #expect(store.content.title.isEmpty && store.content.place.isEmpty && store.content.note.isEmpty)
        #expect(!store.edit(\.note, value: "Événement pendant effacement", generation: suspendedGeneration))
        #expect(store.wipeForPanic())
        for key in ["wesh.meeting.title", "wesh.meeting.place", "wesh.meeting.note", "wesh.meeting.date"] {
            #expect(defaults.object(forKey: key) == nil)
        }
        store.completePanic()
        #expect(store.edit(\.note, value: "Nouvelle note", generation: store.generation))
        for generation in [oldGeneration, suspendedGeneration] {
            #expect(!store.edit(\.title, value: "Ancien titre", generation: generation))
            #expect(!store.edit(\.place, value: "Ancien lieu", generation: generation))
            #expect(!store.edit(\.note, value: "Ancienne note", generation: generation))
            #expect(!store.editDate(456, generation: generation))
            #expect(!store.clear(generation: generation))
        }
        #expect(store.content.note == "Nouvelle note")
        #expect(defaults.string(forKey: "wesh.meeting.note") == "Nouvelle note")
        #expect(defaults.object(forKey: "wesh.meeting.title") == nil)
        #expect(defaults.object(forKey: "wesh.meeting.place") == nil)
        #expect(defaults.object(forKey: "wesh.meeting.date") == nil)
    }

    @Test @MainActor func clearingOneMeetingNoteAlsoInvalidatesItsOldBindings() {
        let store = WeshMeetingNoteStore()
        let generation = store.generation
        #expect(store.edit(\.note, value: "À effacer", generation: generation))
        #expect(store.clear(generation: generation))
        #expect(!store.isSuspended)
        #expect(store.content.note.isEmpty)
        #expect(!store.edit(\.note, value: "Ancienne composition IME", generation: generation))
        #expect(store.edit(\.note, value: "Nouveau texte", generation: store.generation))
    }

    @Test(arguments: [false, true]) @MainActor
    func confirmedGlobalWipeKeepsAdmissionClosedUntilNoteErasureAndRetryCommit(failNote: Bool) {
        var allowNoteErasure = !failNote
        var eraseAttempts = 0
        let note = WeshMeetingNoteStore(erasePersisted: {
            eraseAttempts += 1
            return allowNoteErasure
        })
        let oldGeneration = note.generation
        #expect(note.edit(\.note, value: "Note synthétique privée", generation: oldGeneration))
        let keychain = MockKeychain()
        keychain.simulatedDeleteAllResult = failNote
        let transport = MockTransport()
        var begun = 0
        var committed = 0
        let operations = PanicRecoveryOperations(
            isPending: { false },
            begin: {
                begun += 1
                return PanicRecoveryIntent(fileMarkerEstablished: true, externalMarkerEstablished: false)
            },
            wipeMedia: { _ in },
            complete: { committed += 1 }
        )
        let vm = ChatViewModel(
            keychain: keychain, idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain), transport: transport,
            panicRecoveryOperations: operations, weshPrivatePolicyEnabled: true, weshMeetingNote: note
        )
        vm.bluetoothState = .poweredOn
        let chrome = AppChromeModel(chatViewModel: vm, privateInboxModel: PrivateInboxModel(conversations: vm.conversations))
        let starts = transport.startServicesCallCount
        chrome.requestPanicWipe()
        #expect(chrome.showPanicConfirmation)
        #expect(begun == 0 && eraseAttempts == 0 && keychain.deleteAllCallCount == 0)
        // Cancelling the confirmation never enters the destructive path.
        chrome.showPanicConfirmation = false
        #expect(note.content.note == "Note synthétique privée")
        chrome.requestPanicWipe()
        #expect(!chrome.panicClearAllData())
        #expect(!chrome.showPanicConfirmation)
        #expect(vm.panicRecoveryBlocked && note.isSuspended)
        #expect(note.content.note.isEmpty)
        #expect(committed == 0 && begun == 1 && eraseAttempts == 1)
        #expect(transport.startServicesCallCount == starts)
        #expect(!vm.canSendWeshPublic)
        var draft = "Brouillon après refus"
        #expect(!vm.sendWeshDraft(&draft, to: nil))
        #expect(draft == "Brouillon après refus")
        #expect(transport.sentMessages.isEmpty)
        let failedGeneration = note.generation
        #expect(!note.edit(\.note, value: "Retour ancien éditeur", generation: oldGeneration))
        allowNoteErasure = true
        keychain.simulatedDeleteAllResult = true
        chrome.requestPanicWipe()
        #expect(chrome.panicClearAllData())
        #expect(!vm.panicRecoveryBlocked && !note.isSuspended)
        #expect(committed == 1 && begun == 2 && eraseAttempts == 2)
        #expect(vm.weshPanicGeneration == 2)
        #expect(transport.startServicesCallCount == starts + 1)
        #expect(note.edit(\.note, value: "Note après reprise", generation: note.generation))
        #expect(!note.edit(\.note, value: "Ancienne vue", generation: failedGeneration))
        #expect(note.content.note == "Note après reprise")
    }

    @Test func noiseRecoveryNoticesExplainEveryUnavailableStateWithoutDestructiveAction() {
        #expect(WeshNoiseIdentityNotice(.available) == nil)
        for availability in [NoiseIdentityAvailability.storageUnavailable, .persistenceUnconfirmed, .recoveryRequired, .invalidated] {
            let notice = WeshNoiseIdentityNotice(availability)
            #expect(notice?.message.isEmpty == false)
            #expect(notice?.title.isEmpty == false)
            #expect(notice?.allowsRetry == (availability != .invalidated))
            #expect(notice?.message.contains("Réglages") == false)
        }
    }

    @Test @MainActor func unavailableNoisePreservesPublicDraftDespitePoweredOnRadioAndValidKeys() {
        for availability in [NoiseIdentityAvailability.storageUnavailable, .persistenceUnconfirmed, .recoveryRequired, .invalidated] {
            let transport = MockTransport()
            transport.noiseIdentityAvailabilityOverride = availability
            let vm = makeNoiseRecoveryViewModel(transport)
            vm.bluetoothState = .poweredOn
            var draft = "Brouillon conservé"
            #expect(vm.noiseIdentityAvailability == availability)
            #expect(!vm.canSendWeshPublic)
            #expect(!vm.sendWeshDraft(&draft, to: nil))
            #expect(draft == "Brouillon conservé")
            #expect(transport.sentMessages.isEmpty)
        }
    }

    @Test @MainActor func failedNoiseRetryIsCoalescedAndPropagatesToChromeWithoutSending() async {
        let transport = MockTransport()
        transport.noiseIdentityAvailabilityOverride = .storageUnavailable
        transport.simulatedNoiseIdentityRetryResult = false
        let vm = makeNoiseRecoveryViewModel(transport)
        let chrome = AppChromeModel(chatViewModel: vm, privateInboxModel: PrivateInboxModel(conversations: vm.conversations))
        vm.bluetoothState = .poweredOn
        vm.retryNoiseIdentityRecovery()
        vm.retryNoiseIdentityRecovery()
        #expect(vm.isRecoveringNoiseIdentity)
        #expect(transport.noiseIdentityRetryCount == 1)
        #expect(await TestHelpers.waitUntil({ !vm.isRecoveringNoiseIdentity && chrome.noiseIdentityRetryFailed }, timeout: TestConstants.longTimeout))
        #expect(chrome.noiseIdentityAvailability == .storageUnavailable)
        #expect(!vm.canSendWeshPublic)
        var draft = "Ne pas envoyer"
        #expect(!vm.sendWeshDraft(&draft, to: nil))
        #expect(draft == "Ne pas envoyer")
        #expect(transport.sentMessages.isEmpty)
    }

    @Test @MainActor func reportedNoiseRetrySuccessCannotHideAnUnavailableIdentity() async {
        let transport = MockTransport()
        transport.noiseIdentityAvailabilityOverride = .recoveryRequired
        transport.simulatedNoiseIdentityRetryResult = true
        let vm = makeNoiseRecoveryViewModel(transport)
        vm.retryNoiseIdentityRecovery()
        #expect(await TestHelpers.waitUntil({ !vm.isRecoveringNoiseIdentity }, timeout: TestConstants.longTimeout))
        #expect(vm.noiseIdentityRetryFailed)
        #expect(vm.noiseIdentityAvailability == .recoveryRequired)
        #expect(!vm.canSendWeshPublic)
        #expect(transport.sentMessages.isEmpty)
    }

    @Test @MainActor func confirmedNoiseRecoveryUpdatesChromeWithoutSubmittingTheDraft() async {
        let transport = MockTransport()
        transport.noiseIdentityAvailabilityOverride = .persistenceUnconfirmed
        transport.simulatedNoiseIdentityRetryAvailability = .available
        transport.simulatedNoiseIdentityRetryResult = true
        let vm = makeNoiseRecoveryViewModel(transport)
        let chrome = AppChromeModel(chatViewModel: vm, privateInboxModel: PrivateInboxModel(conversations: vm.conversations))
        vm.bluetoothState = .poweredOn
        let draft = "Envoi toujours explicite"
        vm.retryNoiseIdentityRecovery()
        #expect(await TestHelpers.waitUntil({ !vm.isRecoveringNoiseIdentity && chrome.noiseIdentityAvailability == .available }, timeout: TestConstants.longTimeout))
        #expect(!vm.noiseIdentityRetryFailed)
        #expect(vm.canSendWeshPublic)
        #expect(draft == "Envoi toujours explicite")
        #expect(transport.sentMessages.isEmpty)
    }

    @Test @MainActor func recoveryAfterExplicitStopCannotClearAPublicDraftOrRestartRadio() async {
        let consentKey = "wesh.publicDisclosureAccepted.v1"
        let previous = UserDefaults.standard.object(forKey: consentKey)
        UserDefaults.standard.set(true, forKey: consentKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: consentKey) }
            else { UserDefaults.standard.removeObject(forKey: consentKey) }
        }
        let storage = MockKeychain()
        storage.simulatedReadError = .deviceLocked
        let transport = BLEService(keychain: storage,
            idBridge: NostrIdentityBridge(keychain: MockKeychain()),
            identityManager: MockIdentityManager(storage), initializeBluetoothManagers: false)
        let keychain = MockKeychain()
        let vm = ChatViewModel(keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychain()),
            identityManager: MockIdentityManager(keychain), transport: transport,
            weshPrivatePolicyEnabled: true)
        transport.stopServices()
        vm.bluetoothState = .poweredOn
        storage.simulatedReadError = nil
        vm.retryNoiseIdentityRecovery()
        #expect(await TestHelpers.waitUntil({ !vm.isRecoveringNoiseIdentity }, timeout: TestConstants.longTimeout))
        #expect(vm.noiseIdentityAvailability == .available)
        #expect(!transport.areServicesRequested)
        #expect(!vm.canSendWeshPublic)
        var draft = "Attendre une reprise explicite"
        #expect(!vm.sendWeshDraft(&draft, to: nil))
        #expect(draft == "Attendre une reprise explicite")
        #expect(transport.centralManager == nil && transport.peripheralManager == nil)
    }

    @MainActor private func makeNoiseRecoveryViewModel(_ transport: MockTransport) -> ChatViewModel {
        let keychain = MockKeychain()
        return ChatViewModel(keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychain()),
            identityManager: MockIdentityManager(keychain), transport: transport,
            weshPrivatePolicyEnabled: true)
    }

    @Test @MainActor func privateDraftSurvivesStoppedTrafficAndNeedsExplicitResubmission() async throws {
        try await withVerifiedPrivateFixture { fixture in
            let consentKey = "wesh.publicDisclosureAccepted.v1"
            let previous = UserDefaults.standard.object(forKey: consentKey)
            UserDefaults.standard.set(false, forKey: consentKey)
            defer {
                if let previous { UserDefaults.standard.set(previous, forKey: consentKey) }
                else { UserDefaults.standard.removeObject(forKey: consentKey) }
            }
            fixture.transport.isNoiseIdentityTrafficAllowed = false
            assertPrivateDraftRetained(fixture)
            fixture.transport.isNoiseIdentityTrafficAllowed = true
            #expect(fixture.vm.canSendWeshPrivate(to: fixture.peer))
            #expect(fixture.transport.sentPrivateMessages.isEmpty)
            var draft = "Synthetic private draft"
            #expect(fixture.vm.sendWeshDraft(&draft, to: fixture.peer))
            #expect(draft.isEmpty)
            #expect(fixture.transport.sentPrivateMessages.count == 1)
        }
    }

    @Test @MainActor func unavailableBluetoothPreservesAnEnrolledPrivateDraft() async throws {
        try await withVerifiedPrivateFixture { fixture in
            let states: [CBManagerState] = [.unknown, .resetting, .poweredOff, .unauthorized, .unsupported]
            for state in states {
                fixture.vm.bluetoothState = state
                assertPrivateDraftRetained(fixture)
            }
            fixture.vm.bluetoothState = .poweredOn
            #expect(fixture.vm.canSendWeshPrivate(to: fixture.peer))
        }
    }

    @Test @MainActor func unavailableNoisePreservesAnEnrolledPrivateDraft() async throws {
        try await withVerifiedPrivateFixture { fixture in
            let states: [NoiseIdentityAvailability] = [.storageUnavailable, .persistenceUnconfirmed, .recoveryRequired, .invalidated]
            for state in states {
                fixture.transport.noiseIdentityAvailabilityOverride = state
                fixture.vm.didReceiveTransportEvent(.noiseIdentityAvailabilityUpdated(state))
                assertPrivateDraftRetained(fixture)
            }
        }
    }

    @Test @MainActor func pendingNoiseRetryPreservesAnEnrolledPrivateDraft() async throws {
        try await withVerifiedPrivateFixture { fixture in
            fixture.transport.simulatedNoiseIdentityRetryResult = true
            fixture.vm.retryNoiseIdentityRecovery()
            #expect(fixture.vm.isRecoveringNoiseIdentity)
            assertPrivateDraftRetained(fixture)
            #expect(await TestHelpers.waitUntil({ !fixture.vm.isRecoveringNoiseIdentity }, timeout: TestConstants.longTimeout))
            #expect(fixture.vm.canSendWeshPrivate(to: fixture.peer))
            #expect(fixture.transport.sentPrivateMessages.isEmpty)
        }
    }

    @Test @MainActor func shortPrivateAliasCannotAcceptOrClearAnEnrolledDraft() async throws {
        try await withVerifiedPrivateFixture { fixture in
            var draft = "Synthetic pinned draft"
            #expect(!fixture.vm.canSendWeshPrivate(to: fixture.shortID))
            #expect(!fixture.vm.sendWeshDraft(&draft, to: fixture.shortID))
            #expect(draft == "Synthetic pinned draft")
            #expect(fixture.transport.sentPrivateMessages.isEmpty)
        }
    }

    @Test @MainActor func revokedOrBlockedEnrollmentPreservesThePrivateDraft() async throws {
        try await withVerifiedPrivateFixture { fixture in
            #expect(WeshQRTrust.shared.remove(sessionKey: fixture.key))
            assertPrivateDraftRetained(fixture)
            WeshQRTrust.shared.record(sessionKey: fixture.key, nickname: "Synthetic peer")
            fixture.identity.setBlocked(fixture.key.sha256Fingerprint(), isBlocked: true)
            assertPrivateDraftRetained(fixture)
            fixture.identity.setBlocked(fixture.key.sha256Fingerprint(), isBlocked: false)
            fixture.vm.peerIdentityStore.setVerified(fixture.key.sha256Fingerprint(), verified: false)
            assertPrivateDraftRetained(fixture)
        }
    }

    @Test @MainActor func aDifferentEnrolledKeyCannotUseTheExistingPrivateSession() async throws {
        try await withVerifiedPrivateFixture { fixture in
            let differentKey = Data(repeating: 0x39, count: 32)
            let differentPeer = PeerID(hexData: differentKey)
            WeshQRTrust.shared.record(sessionKey: differentKey, nickname: "Synthetic other peer")
            defer { WeshQRTrust.shared.remove(sessionKey: differentKey) }
            fixture.vm.peerIdentityStore.setVerified(differentKey.sha256Fingerprint(), verified: true)
            fixture.vm.cacheStablePeerID(differentPeer, for: fixture.shortID)
            var draft = "Synthetic pinned draft"
            #expect(!fixture.vm.canSendWeshPrivate(to: differentPeer))
            #expect(!fixture.vm.sendWeshDraft(&draft, to: differentPeer))
            #expect(draft == "Synthetic pinned draft")
            #expect(fixture.transport.sentPrivateMessages.isEmpty)
        }
    }

    @Test @MainActor func privateTextLimitCountsUTF8BytesAndRetainsOversizedDrafts() async throws {
        try await withVerifiedPrivateFixture { fixture in
            for text in [String(repeating: "a", count: 2000), String(repeating: "é", count: 1000), String(repeating: "😀", count: 500)] {
                var oversized = text + "a"
                let before = fixture.transport.sentPrivateMessages.count
                #expect(!fixture.vm.sendWeshDraft(&oversized, to: fixture.peer))
                #expect(oversized == text + "a")
                #expect(fixture.transport.sentPrivateMessages.count == before)
                var exact = text
                #expect(fixture.vm.sendWeshDraft(&exact, to: fixture.peer))
                #expect(exact.isEmpty)
                #expect(fixture.transport.sentPrivateMessages.last?.content == text)
            }
        }
    }

    @Test @MainActor func publicTextLimitCountsUTF8BytesAndRetainsOversizedDrafts() {
        let consentKey = "wesh.publicDisclosureAccepted.v1"
        let previous = UserDefaults.standard.object(forKey: consentKey)
        UserDefaults.standard.set(true, forKey: consentKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: consentKey) }
            else { UserDefaults.standard.removeObject(forKey: consentKey) }
        }
        let transport = MockTransport()
        let vm = makeNoiseRecoveryViewModel(transport)
        vm.bluetoothState = .poweredOn
        for text in [String(repeating: "a", count: 2000), String(repeating: "é", count: 1000), String(repeating: "😀", count: 500)] {
            var oversized = text + "a"
            let before = transport.sentMessages.count
            #expect(!vm.sendWeshDraft(&oversized, to: nil))
            #expect(oversized == text + "a")
            #expect(transport.sentMessages.count == before)
            var exact = text
            #expect(vm.sendWeshDraft(&exact, to: nil))
            #expect(exact.isEmpty)
            #expect(transport.sentMessages.last?.content == text)
        }
    }

    @MainActor private struct VerifiedPrivateFixture {
        let vm: ChatViewModel
        let transport: MockTransport
        let identity: MockIdentityManager
        let peer: PeerID
        let shortID: PeerID
        let key: Data
    }

    @MainActor private func withVerifiedPrivateFixture(
        _ body: (VerifiedPrivateFixture) async throws -> Void
    ) async throws {
        let transport = MockTransport()
        let remote = NoiseEncryptionService(keychain: MockKeychain())
        let key = try #require(remote.getStaticPublicKeyData())
        let shortID = PeerID(publicKey: key)
        let localID = PeerID(publicKey: try #require(transport.mockNoiseService.getStaticPublicKeyData()))
        let first = try transport.mockNoiseService.initiateHandshake(with: shortID)
        let second = try #require(try remote.processHandshakeMessage(from: localID, message: first))
        let third = try #require(try transport.mockNoiseService.processHandshakeMessage(from: shortID, message: second))
        _ = try remote.processHandshakeMessage(from: localID, message: third)
        let storage = MockKeychain()
        let identity = MockIdentityManager(storage)
        let vm = ChatViewModel(keychain: storage,
            idBridge: NostrIdentityBridge(keychain: MockKeychain()),
            identityManager: identity, transport: transport, weshPrivatePolicyEnabled: true)
        let peer = PeerID(hexData: key)
        transport.connectedPeers.formUnion([shortID, peer])
        transport.peerFingerprints[shortID] = key.sha256Fingerprint()
        vm.cacheStablePeerID(peer, for: shortID)
        vm.peerIdentityStore.setVerified(key.sha256Fingerprint(), verified: true)
        vm.bluetoothState = .poweredOn
        WeshQRTrust.shared.record(sessionKey: key, nickname: "Synthetic peer")
        defer { WeshQRTrust.shared.remove(sessionKey: key) }
        try #require(vm.canSendWeshPrivate(to: peer))
        try await body(VerifiedPrivateFixture(vm: vm, transport: transport, identity: identity,
                                              peer: peer, shortID: shortID, key: key))
    }

    @MainActor private func assertPrivateDraftRetained(_ fixture: VerifiedPrivateFixture) {
        var draft = "Synthetic retained draft"
        #expect(!fixture.vm.canSendWeshPrivate(to: fixture.peer))
        #expect(!fixture.vm.sendWeshDraft(&draft, to: fixture.peer))
        #expect(draft == "Synthetic retained draft")
        #expect(fixture.transport.sentPrivateMessages.isEmpty)
        #expect(fixture.transport.sentMessages.isEmpty)
    }

    @Test @MainActor func unavailableIdentityCacheRefusesImportAndRecoversOnForeground() {
        let previousContacts = WeshQRTrust.shared.contacts
        let key = Data(repeating: 0x76, count: 32)
        let peer = PeerID(hexData: key)
        WeshQRTrust.shared.record(sessionKey: key, nickname: "Contact test")
        defer {
            WeshQRTrust.shared.clear()
            for contact in previousContacts {
                if let restored = Data(hexString: contact.noiseKeyHex) {
                    WeshQRTrust.shared.record(sessionKey: restored, nickname: contact.nickname)
                }
            }
        }
        let storage = MockKeychain()
        storage.simulatedReadError = .deviceLocked
        let identity = SecureIdentityStateManager(storage)
        let vm = ChatViewModel(keychain: MockKeychain(),
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: identity, transport: MockTransport(), weshPrivatePolicyEnabled: true)
        #expect(!vm.canImportWeshSharedContent(to: peer))
        #expect(!vm.canSendWeshPrivate(to: peer))
        storage.simulatedReadError = nil
        vm.handleDidBecomeActive()
        #expect(identity.isPersistenceAvailable)
        #expect(vm.canImportWeshSharedContent(to: peer))
    }

    @Test func timelineUsesCalendarDaysAcrossMidnightAndDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute)))
        }
        let beforeMidnight = try date(28, 23, 59)
        let afterMidnight = try date(29, 0, 1)
        #expect(WeshTimeline.startsDay(at: beforeMidnight, after: nil, calendar: calendar))
        #expect(WeshTimeline.startsDay(at: afterMidnight, after: beforeMidnight, calendar: calendar))
        #expect(!WeshTimeline.startsDay(at: try date(29, 23), after: afterMidnight, calendar: calendar))
        #expect(!WeshTimeline.startsDay(at: try date(29, 3), after: try date(29, 1), calendar: calendar))
    }

    @Test @MainActor func unavailableBluetoothPreservesPublicDraftAndPreventsDispatch() {
        let consentKey = "wesh.publicDisclosureAccepted.v1"
        let previous = UserDefaults.standard.object(forKey: consentKey)
        UserDefaults.standard.set(true, forKey: consentKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: consentKey) }
            else { UserDefaults.standard.removeObject(forKey: consentKey) }
        }
        let keychain = MockKeychain()
        let transport = MockTransport()
        let vm = ChatViewModel(keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain), transport: transport,
            weshPrivatePolicyEnabled: true)
        let unavailableStates: [CBManagerState] = [.unknown, .resetting, .poweredOff, .unauthorized, .unsupported]
        for state in unavailableStates {
            vm.bluetoothState = state
            var draft = "Essai local — brouillon"
            #expect(!vm.canSendWeshPublic)
            #expect(!vm.sendWeshDraft(&draft, to: nil))
            #expect(draft == "Essai local — brouillon")
            #expect(transport.sentMessages.isEmpty)
        }
        vm.bluetoothState = .poweredOn
        var draft = "Essai local — brouillon"
        #expect(vm.canSendWeshPublic)
        #expect(vm.sendWeshDraft(&draft, to: nil))
        #expect(draft.isEmpty)
        #expect(transport.sentMessages.count == 1)
    }
    @Test @MainActor func notificationWaveRequiresDisclosureAndAvailableBluetooth() {
        let consentKey = "wesh.publicDisclosureAccepted.v1"
        let previous = UserDefaults.standard.object(forKey: consentKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: consentKey) }
            else { UserDefaults.standard.removeObject(forKey: consentKey) }
        }
        let keychain = MockKeychain()
        let transport = MockTransport()
        let vm = ChatViewModel(keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain), transport: transport,
            weshPrivatePolicyEnabled: true)

        vm.bluetoothState = .poweredOn
        UserDefaults.standard.set(false, forKey: consentKey)
        vm.sendMeshWave()
        #expect(transport.sentMessages.isEmpty)

        UserDefaults.standard.set(true, forKey: consentKey)
        vm.bluetoothState = .poweredOff
        vm.sendMeshWave()
        #expect(transport.sentMessages.isEmpty)

        vm.bluetoothState = .poweredOn
        vm.sendMeshWave()
        #expect(transport.sentMessages.count == 1)
    }

    @Test @MainActor func sharedDraftRequiresExactCurrentUnblockedEnrollment() {
        let key = Data(repeating: 41, count: 32)
        let otherKey = Data(repeating: 42, count: 32)
        let peer = PeerID(hexData: key)
        let other = PeerID(hexData: otherKey)
        let contacts = [WeshQRTrust.Contact(noiseKeyHex: key.hexEncodedString(), nickname: "Contact test")]
        let enrolled: Set<String> = [key.sha256Fingerprint(), otherKey.sha256Fingerprint()]
        #expect(WeshQRTrust.canPrepareDraft(to: peer, contacts: contacts, qrFingerprints: enrolled, blockedFingerprints: []))
        #expect(!WeshQRTrust.canPrepareDraft(to: peer.toShort(), contacts: contacts, qrFingerprints: enrolled, blockedFingerprints: []))
        #expect(!WeshQRTrust.canPrepareDraft(to: other, contacts: contacts, qrFingerprints: enrolled, blockedFingerprints: []))
        #expect(!WeshQRTrust.canPrepareDraft(to: peer, contacts: [], qrFingerprints: enrolled, blockedFingerprints: []))
        #expect(!WeshQRTrust.canPrepareDraft(to: peer, contacts: contacts, qrFingerprints: [], blockedFingerprints: []))
        #expect(!WeshQRTrust.canPrepareDraft(to: peer, contacts: contacts, qrFingerprints: enrolled, blockedFingerprints: [key.sha256Fingerprint()]))
    }

    private var vector: VerificationService.VerificationQR {
        .init(v: 1, noiseKeyHex: "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a",
              signKeyHex: "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
              npub: nil, nickname: "Nora café", ts: 1700000000, nonceB64: "AAECAwQFBgcICQoLDA0ODw", sigHex: String(repeating: "ab", count: 64))
    }

    @Test func crossPlatformCanonicalVector() {
        #expect(vector.canonicalBytes().count == 196)
        #expect(Data(SHA256.hash(data: vector.canonicalBytes())).hexEncodedString() == "54177f15665e6a07bcad135c1889fb40b2e932e301cb9da2529c672a945d4b3c")
        #expect(VerificationService.VerificationQR.fromURL(URL(string: vector.toURLString())!) != nil)
    }

    @Test func parserRejectsAmbiguousOrMalformedQR() {
        let good = vector.toURLString()
        let invalid = [good + "&v=1", good + "&unknown=1", good + "#fragment",
                       good.replacingOccurrences(of: "v=1", with: "v=2"),
                       good.replacingOccurrences(of: vector.noiseKeyHex, with: "aa"),
                       good.replacingOccurrences(of: vector.signKeyHex, with: String(repeating: "g", count: 64)),
                       good.replacingOccurrences(of: vector.sigHex, with: "ab"),
                       good.replacingOccurrences(of: vector.nonceB64, with: vector.nonceB64 + "=="),
                       good.replacingOccurrences(of: "bitchat://verify", with: "bitchat://verify/extra"),
                       good.replacingOccurrences(of: "bitchat://verify", with: "bitchat://user@verify"),
                       good.replacingOccurrences(of: "bitchat://verify", with: "bitchat://verify:443")]
        for value in invalid { #expect(VerificationService.VerificationQR.fromURL(URL(string: value)!) == nil) }
        let tooLong = VerificationService.VerificationQR(v: 1, noiseKeyHex: vector.noiseKeyHex, signKeyHex: vector.signKeyHex,
            npub: nil, nickname: String(repeating: "é", count: 128), ts: vector.ts, nonceB64: vector.nonceB64, sigHex: vector.sigHex)
        #expect(VerificationService.VerificationQR.fromURL(URL(string: tooLong.toURLString())!) == nil)
    }

    @Test @MainActor func privateSendRequiresQRAndCurrentSession() {
        let old = Data(repeating: 1, count: 32)
        let rotated = Data(repeating: 2, count: 32)
        let verified: Set<String> = [old.sha256Fingerprint()]
        #expect(WeshQRTrust.canSend(sessionKey: old, qrFingerprints: verified, locallyVerified: true))
        #expect(!WeshQRTrust.canSend(sessionKey: rotated, qrFingerprints: verified, locallyVerified: true))
        let bothVerified = verified.union([rotated.sha256Fingerprint()])
        #expect(!WeshQRTrust.canSend(sessionKey: rotated, qrFingerprints: bothVerified, locallyVerified: true, requestedKey: old))
        #expect(WeshQRTrust.canSend(sessionKey: old, qrFingerprints: bothVerified, locallyVerified: true, requestedKey: old))
        #expect(!WeshQRTrust.canSend(sessionKey: nil, qrFingerprints: verified, locallyVerified: true))
        #expect(!WeshQRTrust.canSend(sessionKey: old, qrFingerprints: [], locallyVerified: true))
        #expect(!WeshQRTrust.canSend(sessionKey: old, qrFingerprints: verified, locallyVerified: false))
    }

    @Test func historicalMessageBlockUsesPinnedIdentityAndRejectsShortAlias() {
        let first = PeerID(hexData: Data(repeating: 31, count: 32))
        let second = PeerID(hexData: Data(repeating: 32, count: 32))
        let staleAlias = PeerID(str: "1122334455667788")
        #expect(WeshMessageActions.blockIdentity(messageSender: staleAlias, pinnedConversation: first) == first)
        #expect(WeshMessageActions.blockIdentity(messageSender: second, pinnedConversation: first) == first)
        #expect(WeshMessageActions.blockIdentity(messageSender: staleAlias, pinnedConversation: nil) == nil)
        #expect(WeshMessageActions.blockIdentity(messageSender: second, pinnedConversation: nil) == second)
        #expect(WeshMessageActions.blockIdentity(messageSender: first, pinnedConversation: staleAlias) == nil)
    }

    @Test @MainActor func contactRemovalRevokesOnlyExactKeyAndPersists() throws {
        let suite = "wesh-contact-removal-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let trust = WeshQRTrust(defaults: defaults)
        let first = Data(repeating: 11, count: 32)
        let second = Data(repeating: 12, count: 32)
        trust.record(sessionKey: first, nickname: "Même surnom")
        trust.record(sessionKey: second, nickname: "Même surnom")
        #expect(!trust.remove(sessionKey: Data(repeating: 11, count: 31)))
        #expect(!trust.remove(sessionKey: Data(repeating: 13, count: 32)))
        #expect(trust.contacts.count == 2)
        #expect(trust.remove(sessionKey: first))
        let reloaded = WeshQRTrust(defaults: defaults)
        #expect(reloaded.contacts.map(\.noiseKeyHex) == [second.hexEncodedString()])
        #expect(!WeshQRTrust.canSend(sessionKey: first, qrFingerprints: reloaded.fingerprints, locallyVerified: true))
        #expect(WeshQRTrust.canSend(sessionKey: second, qrFingerprints: reloaded.fingerprints, locallyVerified: true))
        #expect(!reloaded.remove(sessionKey: first))
    }

    @Test func receiptsDoNotConflateQueuedCarriedAndDelivered() {
        #expect(WeshDelivery.publicLabel(.notSentYet) == "En attente de diffusion")
        #expect(WeshDelivery.publicLabel(.failed(reason: "offline")) == "Échec de diffusion")
        #expect(WeshDelivery.publicLabel(.read(by: "Nora", at: Date())).contains("non confirmée"))
        #expect(WeshDelivery.label(.notSentYet) != WeshDelivery.label(.sent))
        #expect(WeshDelivery.label(.sent).contains("non confirmée"))
        #expect(WeshDelivery.label(.carried).contains("non confirmée"))
        #expect(WeshDelivery.label(.delivered(to: "Nora", at: Date())) == "Réception confirmée")
        #expect(WeshDelivery.label(.read(by: "Nora", at: Date())) == "Lu")
    }
}
