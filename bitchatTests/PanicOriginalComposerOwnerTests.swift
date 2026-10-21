import Foundation
import Combine
import Testing
@testable import bitchat

private enum ComposerFixtureFailure: Error { case readiness, missingOriginalClose, unexpectedNostrWork }
private struct ComposerFixtureCleanupFailure: Error {
    let primary: Error
    let secondary: [Error]
}

/// Blocks only the actual repository's utility-queue FileAccess call, never Main.
private final class ComposerFileGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var open = false
    private var entered = false
    func arriveAndWait() {
        condition.lock()
        entered = true
        while !open { condition.wait() }
        condition.unlock()
    }
    func hasEntered() -> Bool {
        condition.lock(); defer { condition.unlock() }; return entered
    }
    func release() {
        condition.lock(); open = true; condition.broadcast(); condition.unlock()
    }
}

private final class ComposerFileControl: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    private var reads = 0
    private var writes = 0
    private var readGate: ComposerFileGate?
    private var writeGate: ComposerFileGate?
    private var onRead: (@Sendable () -> Void)?
    func armRead(_ gate: ComposerFileGate) { lock.lock(); readGate = gate; lock.unlock() }
    func armWrite(_ gate: ComposerFileGate) { lock.lock(); writeGate = gate; lock.unlock() }
    func armReentry(_ action: @escaping @Sendable () -> Void) { lock.lock(); onRead = action; lock.unlock() }
    func counts() -> (reads: Int, writes: Int) {
        lock.lock(); defer { lock.unlock() }; return (reads, writes)
    }
    func access() -> ComposerDraftPersistence.FileAccess {
        ComposerDraftPersistence.FileAccess(read: { [self] _ in
            lock.lock(); reads += 1
            let gate = readGate; let action = onRead
            onRead = nil
            lock.unlock()
            gate?.arriveAndWait()
            action?()
            lock.lock(); let result = bytes; lock.unlock()
            guard let result else { throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError) }
            return result
        }, write: { [self] value, _ in
            lock.lock(); writes += 1; let gate = writeGate; lock.unlock()
            gate?.arriveAndWait()
            lock.lock(); bytes = value; lock.unlock()
        }, remove: { [self] _ in
            lock.lock(); bytes = nil; lock.unlock()
        })
    }
}

private final class ComposerTaskLedger: @unchecked Sendable {
    struct Row { let id: UUID; let task: Task<Void, Never> }
    private let lock = NSLock()
    private var rows: [Row] = []
    private var returned = Set<UUID>()
    private var failures: [Error] = []
    func add(_ id: UUID, _ task: Task<Void, Never>) { lock.lock(); rows.append(Row(id: id, task: task)); lock.unlock() }
    func finish(_ id: UUID) { lock.lock(); returned.insert(id); lock.unlock() }
    func fail(_ error: Error) { lock.lock(); failures.append(error); lock.unlock() }
    func snapshot() -> [Row] { lock.lock(); defer { lock.unlock() }; return rows }
    func hasReturned(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return returned.contains(id) }
    func errors() -> [Error] { lock.lock(); defer { lock.unlock() }; return failures }
}

private final class ComposerCloseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ComposerOriginalCloseResult?
    func set(_ value: ComposerOriginalCloseResult) { lock.lock(); result = value; lock.unlock() }
    func get() -> ComposerOriginalCloseResult? { lock.lock(); defer { lock.unlock() }; return result }
}

@MainActor
private final class ComposerNostrCloseObservation {
    var ownerMatches = false
    var actualClose: NostrOutboundOwner.RootCloseOutcome?
    func requireActualClose() throws {
        try #require(ownerMatches)
        guard let actualClose, case .closed = actualClose else { throw ComposerFixtureFailure.missingOriginalClose }
    }
}

@MainActor
private final class ComposerOwnerFixture {
    let tasks = ComposerTaskLedger()
    private var gates: [ComposerFileGate] = []
    private var repositories: [ComposerDraftRepository] = []
    private var nostrOwners: [NostrOutboundOwner] = []
    private var cleanupFinished = false
    let owner = Data(repeating: 0x31, count: 32)

    func gate() -> ComposerFileGate { let gate = ComposerFileGate(); gates.append(gate); return gate }
    func repository(_ files: ComposerFileControl, debounce: TimeInterval = 0.02) -> ComposerDraftRepository {
        let backend = ComposerDraftPersistence(keychain: MockKeychain(),
            fileURL: URL(fileURLWithPath: "/synthetic-composer-owner/no-file-access"), files: files.access())
        // Register the actual owner before accepting the first ordinary IO offer.
        let repository = ComposerDraftRepository(persistence: backend, debounce: debounce)
        repositories.append(repository)
        repository.setOwner(owner)
        return repository
    }
    @discardableResult
    func task(_ action: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        let id = UUID(); let ledger = tasks
        let handle = Task { @MainActor in
            do { try await action() } catch { ledger.fail(error) }
            ledger.finish(id)
        }
        ledger.add(id, handle)
        return handle
    }
    func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw ComposerFixtureFailure.readiness }
            await Task.yield()
        }
    }
    func captured(_ result: ComposerOriginalCloseResult) throws -> ComposerOriginalIOClose {
        guard case .captured(let close) = result else { throw ComposerFixtureFailure.missingOriginalClose }
        return close
    }
    func makeViewModel(_ repository: ComposerDraftRepository) -> (ChatViewModel, MockKeychain, NostrOutboundOwner, ComposerNostrCloseObservation) {
        let ledger = tasks
        let owner = NostrOutboundOwner(taskCreator: { operation in
            let id = UUID()
            let handle = Task { @MainActor in operation(); ledger.finish(id) }
            ledger.add(id, handle)
            return handle
        }, waiterInstaller: NostrOutboundOwner.inlineWaiterInstaller)
        nostrOwners.append(owner)
        let unexpected: @Sendable () -> Void = { ledger.fail(ComposerFixtureFailure.unexpectedNostrWork) }
        let dependencies = NostrTransport.Dependencies(
            outboundOwner: owner, notificationCenter: NotificationCenter(),
            loadFavorites: { [:] }, favoriteStatusForNoiseKey: { _ in nil }, favoriteStatusForPeerID: { _ in nil },
            currentIdentity: { nil }, registerPendingGiftWrap: { _ in unexpected() }, sendEvent: { _ in unexpected() },
            scheduleAfter: { _, action in unexpected(); action() },
            relayConnectivity: { Empty<Bool, Never>(completeImmediately: false).eraseToAnyPublisher() }
        )
        let observation = ComposerNostrCloseObservation()
        let keychain = MockKeychain()
        let lifecycle = PanicNetworkLifecycle(stop: { true }, restart: {}, closeInstalledNostrRoots: { binding in
            observation.ownerMatches = binding.ownerID === owner.id
            guard observation.ownerMatches else { return .unconfirmed(.foreignSubject) }
            let actualClose = closeCapturedNostrOutboundRootsAndRequestSourceDetachment(binding)
            observation.actualClose = actualClose
            return actualClose
        })
        let vm = ChatViewModel(keychain: keychain, idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain), transport: MockTransport(), nostrDependencies: dependencies,
            panicComposerRepository: repository,
            panicRecoveryOperations: .ephemeral(collectAppOwners: PanicAppOwnerAdmission.liveUnconfirmed, wipeMedia: {}),
            panicNetworkLifecycle: lifecycle, weshPrivatePolicyEnabled: true, weshMeetingNote: WeshMeetingNoteStore())
        return (vm, keychain, owner, observation)
    }

    func awaitReturn(_ repository: ComposerDraftRepository, _ close: ComposerOriginalIOClose) async throws -> ComposerOriginalWaitOutcome {
        var result: ComposerOriginalWaitOutcome?
        var actualFailure: Error?
        let observer = task {
            do { result = try await repository.awaitOriginalIO(close) }
            catch { actualFailure = error }
        }
        var readiness: Error?
        do { try await waitUntil { result != nil || actualFailure != nil } } catch { readiness = error }
        // A readiness guard never substitutes for the same actual observer.
        await observer.value
        if let readiness {
            if let actualFailure { throw ComposerFixtureCleanupFailure(primary: readiness, secondary: [actualFailure]) }
            throw readiness
        }
        if let actualFailure { throw actualFailure }
        return try #require(result)
    }

    func close() async throws {
        var failures: [Error] = []
        // No readiness failure can skip release of another original FileAccess gate.
        for gate in gates { gate.release() }
        // Source detachment uses the SAME installed owners, never originalProcess.
        for owner in nostrOwners {
            let binding = owner.captureOutboundPanicBinding()
            let close = closeCapturedNostrOutboundRootsAndRequestSourceDetachment(binding)
            do {
                let returned = try await awaitCapturedOriginalReturnedTaskBatch(binding, closeOutcome: close)
                if !returned.permitsExistingOwnerCheck { throw ComposerFixtureFailure.missingOriginalClose }
            } catch { failures.append(error) }
        }
        // Observe every actual Task, including any genuinely published late child.
        var seen = Set<UUID>()
        while let row = tasks.snapshot().first(where: { !seen.contains($0.id) }) {
            seen.insert(row.id)
            do { try await waitUntil { self.tasks.hasReturned(row.id) } } catch { failures.append(error) }
            await row.task.value
        }
        // A fresh cleanup-only epoch does not repair or substitute an old tested
        // receipt. Its real close includes all still-retained original items,
        // including canceled/delayed submissions from previous epochs.
        for repository in repositories {
            repository.completePanic(success: true, owner: nil)
            let binding = repository.captureOriginalIOBinding()
            do {
                let close = try captured(repository.closeOriginalIO(binding))
                let returned = try await awaitReturn(repository, close)
                guard case .ordinaryDraftSubmissionsReturned = returned else { throw ComposerFixtureFailure.missingOriginalClose }
            } catch { failures.append(error) }
        }
        failures.append(contentsOf: tasks.errors())
        cleanupFinished = true
        if let first = failures.first {
            if failures.count == 1 { throw first }
            throw ComposerFixtureCleanupFailure(primary: first, secondary: Array(failures.dropFirst()))
        }
    }
    func requireCleanup() throws { try #require(cleanupFinished) }
}

@MainActor
private func withComposerOwnerFixture(_ body: @MainActor (ComposerOwnerFixture) async throws -> (@MainActor () throws -> Void)) async throws {
    let fixture = ComposerOwnerFixture()
    var primary: Error?
    var check: (@MainActor () throws -> Void)?
    do { check = try await body(fixture) } catch { primary = error }
    do { try await fixture.close() }
    catch {
        if let primary { throw ComposerFixtureCleanupFailure(primary: primary, secondary: [error]) }
        throw error
    }
    if let primary { throw primary }
    try fixture.requireCleanup()
    try check?()
}

@MainActor
struct PanicOriginalComposerOwnerTests {
    private struct HeldObservation {
        let inspection: ChatViewModel.PreparedPanicOperation.Inspection
    }
    private func held(_ persist: Bool) async throws -> HeldObservation {
        var observation: HeldObservation?
        try await withComposerOwnerFixture { fixture in
            let files = ComposerFileControl(); let gate = fixture.gate()
            if !persist { files.armRead(gate) }
            let repository = fixture.repository(files)
            if persist {
                try await fixture.waitUntil { repository.persistenceStatus == .durable }
                files.armWrite(gate)
                try #require(repository.save("synthetic original draft", for: .mesh))
                repository.flush()
            }
            try await fixture.waitUntil { gate.hasEntered() }
            let (vm, keychain, owner, nostrClose) = fixture.makeViewModel(repository)
            try #require(owner.taskBatchSnapshot().taskIDs.isEmpty)
            let binding = repository.captureOriginalIOBinding()
            let operation = try #require(vm.beginPreparedPanicApplicationErasure())
            try #require(vm.beginPreparedPanicApplicationErasure() == nil)
            let close = try fixture.captured(repository.closeOriginalIO(binding))
            var outcome: ChatViewModel.PreparedPanicOperation.Outcome?
            fixture.task { outcome = try await operation.run() }
            try await fixture.waitUntil {
                let value = operation.inspect()
                return value.stage == .composer || value.finalized
            }
            // ONE atomic MainActor observation before ANY release/advancement.
            let saved = operation.inspect()
            try #require(gate.hasEntered())
            return {
                let actual = try #require(outcome)
                try nostrClose.requireActualClose()
                try #require(actual.outboundPermitted && actual.outboundEmpty && !actual.applicationErased)
                try #require(actual.originalComposer == close.identity)
                switch actual.composer {
                case .some(.requestedNotAwaited(let identity)): try #require(identity == close.identity)
                case .some(.ordinaryDraftSubmissionsReturned(let identity, _)): try #require(identity == close.identity)
                default: throw ComposerFixtureFailure.missingOriginalClose
                }
                try #require(owner.taskBatchSnapshot().taskIDs.isEmpty)
                try #require(keychain.deleteAllCallCount == 0)
                try #require(operation.inspect().outcome == actual && operation.inspect().finalized)
                if saved.finalized { try #require(saved.outcome == actual) }
                else { try #require(saved.stage == .composer && saved.outcome == nil) }
                observation = HeldObservation(inspection: saved)
            }
        }
        return try #require(observation)
    }

    @Test func heldOriginalPersistKeepsPreparedPanicPending() async throws {
        let saved = try await held(true)
        #expect(!saved.inspection.finalized)
    }

    @Test func heldOriginalLoadKeepsPreparedPanicPending() async throws {
        let saved = try await held(false)
        #expect(!saved.inspection.finalized)
    }

    @Test func terminalCloseRefusesFreshOrdinaryOffers() async throws {
        try await withComposerOwnerFixture { fixture in
            let files = ComposerFileControl(); let repository = fixture.repository(files)
            try await fixture.waitUntil { repository.persistenceStatus == .durable }
            let binding = repository.captureOriginalIOBinding()
            let close = try fixture.captured(repository.closeOriginalIO(binding))
            let returned = try await fixture.awaitReturn(repository, close)
            let before = files.counts()
            let admitted = repository.save("refused after close", for: .mesh)
            repository.retry(); repository.flush()
            let repeated = try fixture.captured(repository.closeOriginalIO(binding))
            return {
                guard case .ordinaryDraftSubmissionsReturned(let identity, _) = returned,
                      identity == close.identity else { throw ComposerFixtureFailure.missingOriginalClose }
                #expect(!admitted && repository.load(.mesh).isEmpty)
                #expect(repeated.identity == close.identity)
                #expect(files.counts().reads == before.reads && files.counts().writes == before.writes)
            }
        }
    }

    @Test func cancelledDebounceRequiresItsActualCompletion() async throws {
        try await withComposerOwnerFixture { fixture in
            let files = ComposerFileControl(); let repository = fixture.repository(files)
            try await fixture.waitUntil { repository.persistenceStatus == .durable }
            let gate = fixture.gate(); files.armWrite(gate)
            try #require(repository.save("one-shot naturally delayed edit", for: .mesh))
            // Positive actual FileAccess entry, not elapsed-time readiness.
            try await fixture.waitUntil { gate.hasEntered() }
            let close = try fixture.captured(repository.closeOriginalIO(repository.captureOriginalIOBinding()))
            var returned: ComposerOriginalWaitOutcome?
            fixture.task { returned = try await repository.awaitOriginalIO(close) }
            // Close cancels this SAME already-running delayed item. No flush,
            // competing offer, started/nil oracle or per-notify-return claim.
            return {
                guard case .some(.ordinaryDraftSubmissionsReturned(let identity, let ids)) = returned else {
                    throw ComposerFixtureFailure.missingOriginalClose
                }
                // An extra retained row invalidates this positive's setup.
                try #require(identity == close.identity && ids.count == 1)
            }
        }
    }

    @Test func foreignAndReopenedEpochsDoNotAuthorizeOriginalCompletion() async throws {
        try await withComposerOwnerFixture { fixture in
            let files = ComposerFileControl(); let gate = fixture.gate(); files.armRead(gate)
            let first = fixture.repository(files)
            let other = fixture.repository(ComposerFileControl())
            try await fixture.waitUntil { gate.hasEntered() }
            let original = first.captureOriginalIOBinding()
            let close = try fixture.captured(first.closeOriginalIO(original))
            let foreign = other.requestedOriginalIO(.captured(close))
            first.completePanic(success: true, owner: nil)
            let stale = try await first.awaitOriginalIO(close)
            let newClose = try fixture.captured(first.closeOriginalIO(first.captureOriginalIOBinding()))
            var current: ComposerOriginalWaitOutcome?
            fixture.task { current = try await first.awaitOriginalIO(newClose) }
            return {
                #expect(foreign == .unconfirmed(.foreignRepository))
                #expect(stale == .unconfirmed(.changedEpoch))
                #expect(newClose.identity.epoch != close.identity.epoch)
                guard case .some(.ordinaryDraftSubmissionsReturned) = current else { throw ComposerFixtureFailure.missingOriginalClose }
            }
        }
    }

    @Test func queueReentryFencesWithoutWaitingItsCurrentFrame() async throws {
        try await withComposerOwnerFixture { fixture in
            let files = ComposerFileControl(); let repository = fixture.repository(files)
            try await fixture.waitUntil { repository.persistenceStatus == .durable }
            let box = ComposerCloseBox()
            files.armReentry { box.set(repository.closeOriginalIO(repository.captureOriginalIOBinding())) }
            repository.retry()
            try await fixture.waitUntil { box.get() != nil }
            let onQueue = try fixture.captured(try #require(box.get()))
            let refused = try await repository.awaitOriginalIO(onQueue)
            let external = try fixture.captured(repository.closeOriginalIO(repository.captureOriginalIOBinding()))
            let returned = try await fixture.awaitReturn(repository, external)
            return {
                #expect(refused == .unconfirmed(.originalQueueCaller))
                #expect(external.identity == onQueue.identity)
                guard case .ordinaryDraftSubmissionsReturned = returned else { throw ComposerFixtureFailure.missingOriginalClose }
            }
        }
    }

    @Test func callerCancellationPreservesOriginalIOAndOtherWaiters() async throws {
        try await withComposerOwnerFixture { fixture in
            let files = ComposerFileControl(); let gate = fixture.gate(); files.armRead(gate)
            let repository = fixture.repository(files)
            try await fixture.waitUntil { gate.hasEntered() }
            let close = try fixture.captured(repository.closeOriginalIO(repository.captureOriginalIOBinding()))
            var cancelled = false
            var follower: ComposerOriginalWaitOutcome?
            // Both Tasks are retained and first.cancel() occurs in this SAME
            // MainActor turn before the first readiness yield: before-install
            // cancellation, not two registered continuations or after-install.
            let first = fixture.task {
                do { _ = try await repository.awaitOriginalIO(close) }
                catch is CancellationError { cancelled = true }
            }
            fixture.task { follower = try await repository.awaitOriginalIO(close) }
            first.cancel()
            try await fixture.waitUntil { cancelled }
            let savedFollower = follower
            return {
                #expect(cancelled && savedFollower == nil)
                guard case .some(.ordinaryDraftSubmissionsReturned) = follower else { throw ComposerFixtureFailure.missingOriginalClose }
            }
        }
    }

    @Test func returnedQueueFramesStillCannotAdmitApplicationErasure() async throws {
        try await withComposerOwnerFixture { fixture in
            let repository = fixture.repository(ComposerFileControl())
            try await fixture.waitUntil { repository.persistenceStatus == .durable }
            let (vm, keychain, owner, nostrClose) = fixture.makeViewModel(repository)
            let binding = repository.captureOriginalIOBinding()
            let operation = try #require(vm.beginPreparedPanicApplicationErasure())
            let close = try fixture.captured(repository.closeOriginalIO(binding))
            let returned = try await fixture.awaitReturn(repository, close)
            let outcome = try await operation.run()
            var replayRefused = false
            do { _ = try await operation.run() }
            catch ChatViewModel.PreparedPanicOperationError.refusedReplayOrStaleAttempt { replayRefused = true }
            return {
                guard case .ordinaryDraftSubmissionsReturned = returned else { throw ComposerFixtureFailure.missingOriginalClose }
                try nostrClose.requireActualClose()
                try #require(outcome.outboundPermitted && outcome.outboundEmpty && outcome.originalComposer == close.identity)
                #expect(replayRefused && !outcome.applicationErased && keychain.deleteAllCallCount == 0)
                #expect(owner.taskBatchSnapshot().taskIDs.isEmpty)
                let report = PanicAppOwnerAdmission.liveUnconfirmed()
                #expect(report.localPersistenceAndEditors == .unconfirmed(.checkedProducerMissing))
                #expect(report.meshAndGossipCallbacks == .unconfirmed(.checkedProducerMissing))
                #expect(report.nostrOutboundAndAckTasks == .unconfirmed(.checkedProducerMissing))
                #expect(report.nostrInboundKeyUsers == .unconfirmed(.checkedProducerMissing))
                #expect(report.remainingApplicationKeyUsers == .unconfirmed(.checkedProducerMissing))
                #expect(report.startupProducers == .unconfirmed(.checkedProducerMissing))
                #expect(report.internalCryptoOwners == .unconfirmed(.checkedProducerMissing))
            }
        }
    }
}
