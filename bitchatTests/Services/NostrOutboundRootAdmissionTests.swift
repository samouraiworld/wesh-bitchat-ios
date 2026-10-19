import BitFoundation
import Combine
import Foundation
import Testing
@testable import bitchat

/// Actual transport roots with isolated metadata, RAM dependencies and owned scheduling only.
@MainActor
struct NostrOutboundRootAdmissionTests {
    @Test
    func postClosePrivateMessageRootDoesNotInvokeTaskCreator() async throws {
        try await withRootFixture { f in
            let before = f.creatorCount
            let receipt = try f.closeOriginal()
            f.transport.sendPrivateMessage("synthetic", to: f.peer, recipientNickname: "Synthetic", messageID: "root-pm")
            try await f.finishBeforePolicy()
            try #require(f.creatorCount - before == 0)
            try expectRootRefusal(f.owner.reserveTask(kind: .privateMessage, parent: .root), original: receipt)
            #expect(f.owner.provenanceSnapshot().tasks.isEmpty)
        }
    }

    @Test
    func postCloseFavoriteNotificationRootDoesNotInvokeTaskCreator() async throws {
        try await withRootFixture { f in
            let before = f.creatorCount
            let receipt = try f.closeOriginal()
            f.transport.sendFavoriteNotification(to: f.peer, isFavorite: true)
            try await f.finishBeforePolicy()
            try #require(f.creatorCount - before == 0)
            try expectRootRefusal(f.owner.reserveTask(kind: .favoriteNotification, parent: .root), original: receipt)
            #expect(f.owner.provenanceSnapshot().tasks.isEmpty)
        }
    }

    @Test
    func postCloseExplicitIdentityMessageRootDoesNotInvokeTaskCreator() async throws {
        try await withRootFixture { f in
            let before = f.creatorCount
            let receipt = try f.closeOriginal()
            f.transport.sendPrivateMessageForNostrIdentity(
                content: "synthetic", toRecipientHex: "", from: syntheticIdentity(), messageID: "root-explicit"
            )
            try await f.finishBeforePolicy()
            try #require(f.creatorCount - before == 0)
            try expectRootRefusal(f.owner.reserveTask(kind: .explicitIdentityMessage, parent: .root), original: receipt)
            #expect(f.owner.provenanceSnapshot().tasks.isEmpty)
        }
    }

    @Test
    func postCloseFavoriteObserverRefreshDoesNotInvokeTaskCreator() async throws {
        try await withRootFixture { f in
            let before = f.creatorCount
            let receipt = try f.closeOriginal()
            f.notifications.post(name: .favoriteStatusChanged, object: nil)
            try await f.finishBeforePolicy()
            try #require(f.creatorCount - before == 0)
            try expectRootRefusal(f.owner.reserveTask(kind: .refreshReachablePeers, parent: .root), original: receipt)
            #expect(f.owner.provenanceSnapshot().tasks.isEmpty)
            #expect(f.owner.provenanceSnapshot().callbacks.isEmpty)
        }
    }

    @Test
    func postCloseDeliveryAckRootDoesNotSchedulePacerWork() async throws {
        try await withRootFixture { f in
            let before = f.scheduler.submissionCount
            let receipt = try f.closeOriginal()
            f.transport.sendDeliveryAck(for: "root-ack", to: f.peer)
            try await f.finishBeforePolicy()
            try #require(f.scheduler.submissionCount - before == 0)
            try expectRootRefusal(f.owner.reserveCallback(kind: .pendingAckHandoff, parent: .root), original: receipt)
            #expect(f.owner.provenanceSnapshot().tasks.isEmpty)
            #expect(f.owner.provenanceSnapshot().callbacks.isEmpty)
        }
    }

    @Test
    func openPublicRootsPreserveKindsAndAckLineage() async throws {
        try await withRootFixture { f in
            let initialLoads = f.favoriteLoads.read()
            f.transport.sendPrivateMessage("synthetic", to: f.peer, recipientNickname: "Synthetic", messageID: "open-pm")
            f.transport.sendFavoriteNotification(to: f.peer, isFavorite: true)
            f.transport.sendPrivateMessageForNostrIdentity(
                content: "synthetic", toRecipientHex: "", from: syntheticIdentity(), messageID: "open-explicit"
            )
            f.notifications.post(name: .favoriteStatusChanged, object: nil)
            f.transport.sendDeliveryAck(for: "open-ack", to: f.peer)
            try await f.finishBeforePolicy()
            #expect(f.creatorCount == 5)
            #expect(f.favoriteLoads.read() == initialLoads + 1)
            let state = f.owner.provenanceSnapshot()
            #expect(state.tasks.map(\.kind) == [.privateMessage, .favoriteNotification, .explicitIdentityMessage, .refreshReachablePeers, .ackItem])
            let roots = state.tasks.filter { $0.parent == nil }
            #expect(roots.count == 4)
            let handoff = try callbackRow(state, kind: .pendingAckHandoff)
            #expect(handoff.parent == nil)
            let child = try #require(state.tasks.first { $0.kind == .ackItem })
            #expect(child.parent === handoff.id)
            let refresh = try #require(state.tasks.first { $0.kind == .refreshReachablePeers })
            #expect(try callbackRow(state, kind: .refreshStateWrite).parent === refresh.id)
            try expectAckChain(state, handoff: handoff)
            #expect(f.scheduler.submissionCount == 1)
            #expect(f.scheduler.delays == [TransportConfig.nostrReadAckInterval])
        }
    }

    @Test
    func acceptedTaskRegistersAndRunsAfterRootClose() async throws {
        try await withRootFixture(holdCreatorReturn: true, holdTaskBody: true) { f in
            let transport = f.transport
            let peer = f.peer
            f.worker {
                transport.sendPrivateMessage("synthetic", to: peer, recipientNickname: "Synthetic", messageID: "late-pm")
            }
            try await eventually { f.creatorCount == 1 && f.taskEntered.read() }
            let before = try #require(f.owner.provenanceSnapshot().tasks.first)
            try #require(before.registration == .reservedAwaitingHandle)
            try #require(before.body == .notEntered)
            let receipt = try f.closeOriginal()
            let lookupsBefore = f.lookups.read()
            f.releaseCreator()
            f.taskBody.open()
            try await f.finishBeforePolicy()
            let after = try #require(f.owner.provenanceSnapshot().tasks.first)
            #expect(after.id === before.id)
            #expect(after.parent == nil)
            #expect(after.kind == .privateMessage)
            #expect(after.body == .returned)
            #expect(after.registration == .supervisorJoined)
            #expect(f.lookups.read() > lookupsBefore)
            #expect(try f.closeOriginal() === receipt)
            #expect(f.creatorCount == 1)
        }
    }

    @Test
    func acceptedAckHandoffAdmitsChildAndResetAfterRootClose() async throws {
        try await withRootFixture { f in
            let hold = f.holdAckQueue()
            try await eventually { hold.entered.read() }
            f.transport.sendDeliveryAck(for: "accepted-ack", to: f.peer)
            let before = f.owner.provenanceSnapshot()
            let handoff = try callbackRow(before, kind: .pendingAckHandoff)
            try #require(handoff.state == .reserved)
            let append = try callbackRow(before, kind: .ackQueueAppend)
            try #require(append.state == .reserved)
            try #require(append.parent === handoff.id)
            _ = try f.closeOriginal()
            hold.release.signal()
            try await f.finishBeforePolicy()
            #expect(hold.finished.read())
            let state = f.owner.provenanceSnapshot()
            let retained = try callbackRow(state, kind: .pendingAckHandoff)
            #expect(retained.id === handoff.id)
            let task = try #require(state.tasks.first)
            #expect(task.kind == .ackItem)
            #expect(task.parent === handoff.id)
            #expect(task.registration == .supervisorJoined)
            try expectAckChain(state, handoff: retained)
            #expect(f.scheduler.submissionCount == 1)
            #expect(f.creatorCount == 1)
        }
    }

    @Test
    func providerReentrantCloseRetainsAlreadyAcceptedRoot() async throws {
        try await withRootFixture { f in
            let result = Locked<NostrOutboundOwner.RootCloseOutcome?>(nil)
            let binding = f.binding
            f.lookupAction.update { $0 = { result.update { $0 = closeCapturedNostrOutboundRoots(binding) } } }
            f.transport.sendPrivateMessage("synthetic", to: f.peer, recipientNickname: "Synthetic", messageID: "reentrant-pm")
            try await f.finishBeforePolicy()
            let actual = try #require(result.read())
            let receipt = try closedReceipt(actual, binding: binding)
            #expect(try f.closeOriginal() === receipt)
            #expect(f.creatorCount == 1)
            #expect(f.lookups.read() > 0)
            let task = try #require(f.owner.provenanceSnapshot().tasks.first)
            #expect(task.kind == .privateMessage)
            #expect(task.registration == .supervisorJoined)
        }
    }

    @Test
    func sameOwnerTemporaryTransportKeepsOriginalBindingAndCloseEvent() async throws {
        try await withRootFixture { f in
            // The getter returns closures only. Stop/restart are never invoked in this fixture.
            let live = PanicNetworkLifecycle.live
            let initialLoads = f.favoriteLoads.read()
            let temporary = f.makeTemporaryTransport()
            let secondBinding = temporary.captureOutboundPanicBinding()
            #expect(secondBinding.ownerID === f.binding.ownerID)
            #expect(secondBinding.subject === f.binding.subject)
            let first = try closedReceipt(live.closeInstalledNostrRoots(f.binding), binding: f.binding)
            let second = try closedReceipt(live.closeInstalledNostrRoots(secondBinding), binding: secondBinding)
            let repeated = try closedReceipt(live.closeInstalledNostrRoots(f.binding), binding: f.binding)
            #expect(second === first)
            #expect(repeated === first)
            #expect(second.eventID === first.eventID)
            #expect(f.favoriteLoads.read() == initialLoads + 1)
            try await f.finishBeforePolicy()
            #expect(f.creatorCount == 0)
            #expect(f.scheduler.submissionCount == 0)
            withExtendedLifetime(temporary) {}
        }
    }

    @Test
    func foreignSubjectCannotCloseDifferentOwner() async throws {
        try await withRootFixture { first in
            try await withRootFixture { second in
                let result = second.owner.closeRootAdmission(subject: first.binding.subject)
                guard case .unconfirmed(let gap) = result else { throw RootFixtureError("foreign subject closed another owner") }
                #expect(gap == .foreignSubject)
                #expect(first.binding.ownerID !== second.binding.ownerID)
                second.transport.sendPrivateMessage("synthetic", to: second.peer, recipientNickname: "Synthetic", messageID: "foreign-open")
                try await second.finishBeforePolicy()
                #expect(second.creatorCount == 1)
                let own = try second.closeOriginal()
                let other = try first.closeOriginal()
                #expect(own.ownerID === second.binding.ownerID)
                #expect(other.ownerID === first.binding.ownerID)
                #expect(own.eventID !== other.eventID)
            }
        }
    }

    @Test
    func noopPanicActionReportsMissingWithoutClosingInstalledOwner() async throws {
        try await withRootFixture { f in
            let result = PanicNetworkLifecycle.noop.closeInstalledNostrRoots(f.binding)
            guard case .unconfirmed(let gap) = result else { throw RootFixtureError("no-op participant manufactured a closed receipt") }
            #expect(gap == .participantMissing)
            f.transport.sendPrivateMessage("synthetic", to: f.peer, recipientNickname: "Synthetic", messageID: "noop-open")
            try await f.finishBeforePolicy()
            #expect(f.creatorCount == 1)
            let report = PanicAppOwnerAdmission.liveUnconfirmed()
            let missing = PanicOwnerStatus.unconfirmed(.checkedProducerMissing)
            #expect(report.localPersistenceAndEditors == missing)
            #expect(report.meshAndGossipCallbacks == missing)
            #expect(report.nostrOutboundAndAckTasks == missing)
            #expect(report.nostrInboundKeyUsers == missing)
            #expect(report.remainingApplicationKeyUsers == missing)
            #expect(report.startupProducers == missing)
            #expect(report.internalCryptoOwners == missing)
        }
    }
}

private struct RootFixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct RootCleanupFailure: Error, CustomStringConvertible {
    let primary: Error
    let cleanup: [String]
    var description: String { "primary: \(primary); cleanup: \(cleanup.joined(separator: "; "))" }
}

private final class Locked<Value>: @unchecked Sendable {
    private let mutex = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { mutex.lock(); defer { mutex.unlock() }; return value }
    @discardableResult func update<Result>(_ action: (inout Value) -> Result) -> Result {
        mutex.lock(); defer { mutex.unlock() }; return action(&value)
    }
}

private final class AsyncGate: @unchecked Sendable {
    private struct State { var open = false; var waiting: [CheckedContinuation<Void, Never>] = [] }
    private let state = Locked(State())
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = state.update { state in
                if state.open { return true }
                state.waiting.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
    func open() {
        let waiting = state.update { state in
            state.open = true
            let waiting = state.waiting
            state.waiting.removeAll()
            return waiting
        }
        waiting.forEach { $0.resume() }
    }
}

private final class TaskLedger: @unchecked Sendable {
    private struct Row {
        let handle: Task<Void, Never>
        let observer: Task<Void, Never>
        let finished: Locked<Bool>
    }
    private let rows = Locked<[Row]>([])
    @discardableResult func track(_ handle: Task<Void, Never>) -> Task<Void, Never> {
        let finished = Locked(false)
        let observer = Task { await handle.value; finished.update { $0 = true } }
        rows.update { $0.append(Row(handle: handle, observer: observer, finished: finished)) }
        return handle
    }
    func drain() async throws {
        var index = 0
        while index < rows.read().count {
            let row = rows.read()[index]
            try await eventually { row.finished.read() }
            await row.handle.value
            await row.observer.value
            index += 1
        }
    }
}

private final class RealInstaller: @unchecked Sendable {
    private let active = Locked(0)
    var pendingCount: Int { active.read() }
    func install(_ action: @escaping @Sendable () -> Void) {
        active.update { $0 += 1 }
        defer { active.update { $0 -= 1 } }
        action()
    }
}

private final class ManualScheduler: @unchecked Sendable {
    private struct State {
        var actions: [@Sendable () -> Void] = []
        var delays: [TimeInterval] = []
    }
    private let state = Locked(State())
    var pendingCount: Int { state.read().actions.count }
    var submissionCount: Int { state.read().delays.count }
    var delays: [TimeInterval] { state.read().delays }
    func submit(_ delay: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        state.update { $0.delays.append(delay); $0.actions.append(action) }
    }
    func releaseAll() {
        let actions = state.update { state in
            let actions = state.actions; state.actions.removeAll(); return actions
        }
        actions.forEach { $0() }
    }
}

private final class QueueHold: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let entered = Locked(false)
    let finished = Locked(false)
}

private final class BatchJoiner: @unchecked Sendable {
    enum Outcome { case joined(NostrOutboundOwner.JoinedTaskBatch), cancelled, failed(Error) }
    let outcome = Locked<Outcome?>(nil)
    private(set) var handle: Task<Void, Never>!
    init(owner: NostrOutboundOwner, batch: NostrOutboundOwner.TaskBatch, ledger: TaskLedger) {
        handle = ledger.track(Task { [self] in
            let result: Outcome
            do { result = .joined(try await owner.joinTaskBatch(batch)) }
            catch is CancellationError { result = .cancelled }
            catch { result = .failed(error) }
            outcome.update { $0 = result }
        })
    }
    func joined() async throws -> NostrOutboundOwner.JoinedTaskBatch {
        try await eventually { self.outcome.read() != nil }
        await handle.value
        guard let outcome = outcome.read() else { throw RootFixtureError("owned join outcome disappeared") }
        switch outcome {
        case .joined(let proof): return proof
        case .cancelled: throw RootFixtureError("owned batch join was cancelled")
        case .failed(let error): throw error
        }
    }
}

private final class RootFixture: @unchecked Sendable {
    let owner: NostrOutboundOwner
    let transport: NostrTransport
    let binding: NostrOutboundPanicBinding
    let notifications: NotificationCenter
    let scheduler: ManualScheduler
    let ackQueue: DispatchQueue
    let taskBody: AsyncGate
    let taskEntered: Locked<Bool>
    let favoriteLoads: Locked<Int>
    let lookups: Locked<Int>
    let lookupAction: Locked<(@MainActor () -> Void)?>
    let peer = PeerID(str: "1122334455667788")
    private let dependencies: NostrTransport.Dependencies
    private let ledger: TaskLedger
    private let installer: RealInstaller
    private let creations: Locked<Int>
    private let errors: Locked<[String]>
    private let returnGate: DispatchSemaphore
    private let workers = Locked<[Thread]>([])
    private let holds = Locked<[QueueHold]>([])
    private let joiners = Locked<[BatchJoiner]>([])
    private var temporaryTransports: [NostrTransport] = []
    var creatorCount: Int { creations.read() }

    @MainActor
    init(holdCreatorReturn: Bool, holdTaskBody: Bool) {
        let ledger = TaskLedger()
        let installer = RealInstaller()
        let body = AsyncGate()
        let entered = Locked(false)
        let creations = Locked(0)
        let errors = Locked<[String]>([])
        let returnGate = DispatchSemaphore(value: 0)
        let loads = Locked(0)
        let lookups = Locked(0)
        let lookupAction = Locked<(@MainActor () -> Void)?>(nil)
        let notifications = NotificationCenter()
        let scheduler = ManualScheduler()
        let queue = DispatchQueue(label: "synthetic.nostr-root.serial-ack")
        let relay = PassthroughSubject<Bool, Never>()
        self.ledger = ledger; self.installer = installer; self.taskBody = body
        self.taskEntered = entered; self.creations = creations; self.errors = errors; self.returnGate = returnGate
        self.favoriteLoads = loads; self.lookups = lookups; self.lookupAction = lookupAction
        self.notifications = notifications; self.scheduler = scheduler; self.ackQueue = queue
        if !holdTaskBody { body.open() }
        let owner = NostrOutboundOwner(taskCreator: { operation in
            let handle = Task { @MainActor in
                entered.update { $0 = true }
                await body.wait()
                operation()
            }
            ledger.track(handle)
            creations.update { $0 += 1 }
            if holdCreatorReturn && returnGate.wait(timeout: .now() + 5) != .success {
                errors.update { $0.append("owned creator return barrier timed out") }
            }
            return handle
        }, waiterInstaller: { action in installer.install(action) })
        self.owner = owner
        let pacer = NostrTransport.AckPacer(owner: owner, queue: queue, scheduleAfter: { delay, action in
            scheduler.submit(delay, action)
        })
        let dependencies = NostrTransport.Dependencies(
            outboundOwner: owner,
            notificationCenter: notifications,
            loadFavorites: { loads.update { $0 += 1 }; return [:] },
            favoriteStatusForNoiseKey: { _ in lookups.update { $0 += 1 }; lookupAction.read()?(); return nil },
            favoriteStatusForPeerID: { _ in lookups.update { $0 += 1 }; lookupAction.read()?(); return nil },
            currentIdentity: { errors.update { $0.append("fixture reached unexpected identity provider") }; return nil },
            registerPendingGiftWrap: { _ in errors.update { $0.append("fixture registered a crypto event") } },
            sendEvent: { _ in errors.update { $0.append("fixture sent a crypto event") } },
            scheduleAfter: { delay, action in scheduler.submit(delay, action) },
            relayConnectivity: { relay.eraseToAnyPublisher() },
            ackPacer: pacer
        )
        self.dependencies = dependencies
        let keychain = MockKeychain()
        let transport = NostrTransport(keychain: keychain, idBridge: NostrIdentityBridge(keychain: keychain), dependencies: dependencies)
        self.transport = transport
        self.binding = transport.captureOutboundPanicBinding()
    }

    func closeOriginal() throws -> NostrOutboundOwner.RootCloseReceipt {
        try closedReceipt(closeCapturedNostrOutboundRoots(binding), binding: binding)
    }
    @MainActor func makeTemporaryTransport() -> NostrTransport {
        let keychain = MockKeychain()
        let temporary = NostrTransport(keychain: keychain, idBridge: NostrIdentityBridge(keychain: keychain), dependencies: dependencies)
        temporaryTransports.append(temporary)
        return temporary
    }
    func releaseCreator() { returnGate.signal() }
    func worker(_ action: @escaping @Sendable () -> Void) {
        let thread = Thread { action() }
        thread.name = "synthetic-nostr-root-creator"
        workers.update { $0.append(thread) }
        thread.start()
    }
    func holdAckQueue() -> QueueHold {
        let hold = QueueHold()
        holds.update { $0.append(hold) }
        let errors = self.errors
        ackQueue.async {
            hold.entered.update { $0 = true }
            defer { hold.finished.update { $0 = true } }
            if hold.release.wait(timeout: .now() + 5) != .success {
                errors.update { $0.append("owned ACK queue hold timed out") }
            }
        }
        return hold
    }
    private func reapWorkers() async throws {
        for worker in workers.read() { try await eventually { worker.isFinished } }
        try requireFixture(errors.read().isEmpty, errors.read().joined(separator: "; "))
    }

    /// Settle only the finite actions submitted by this fixture; never an owner/fixed-point drain.
    func finishBeforePolicy() async throws {
        try await reapWorkers()
        try await checkpoint(ackQueue)
        // These cases enqueue at most one ACK. Invoke its real reset, then checkpoint its actual hop.
        for _ in 0..<2 { scheduler.releaseAll(); try await checkpoint(ackQueue) }
        try await ledger.drain()
        // The completed refresh Task submitted this known private barrier before returning.
        _ = transport.isPeerReachable(peer)
        let batch = owner.taskBatchSnapshot()
        let joiner = BatchJoiner(owner: owner, batch: batch, ledger: ledger)
        joiners.update { $0.append(joiner) }
        let proof = try await joiner.joined()
        try requireFixture(proof.ownerID === owner.id && proof.ownerID === batch.ownerID, "batch owner identity changed")
        try requireFixture(proof.batchID === batch.id && proof.taskIDs == batch.taskIDs, "batch task identity changed")
        try await ledger.drain()
        try requireFixture(installer.pendingCount == 0, "actual waiter installer remains active")
        try requireFixture(owner.provenanceSnapshot().waiters.isEmpty, "registration continuation remains pending")
        try requireFixture(owner.provenanceSnapshot().debts.isEmpty, "unexpected owner protocol debt")
        try requireFixture(scheduler.pendingCount == 0, "known reset callback remains held")
        try requireFixture(errors.read().isEmpty, errors.read().joined(separator: "; "))
    }

    @MainActor func cleanup() async -> [String] {
        var failures: [String] = []
        taskBody.open()
        workers.read().forEach { _ in returnGate.signal() }
        holds.read().forEach { $0.release.signal() }
        joiners.read().forEach { $0.handle.cancel() }
        do { try await finishBeforePolicy() } catch { failures.append("known-work cleanup: \(error)") }
        // Release callbacks submitted while a previously held creator was escaping, then join again.
        scheduler.releaseAll()
        do { try await checkpoint(ackQueue); try await ledger.drain() }
        catch { failures.append("late owned cleanup: \(error)") }
        lookupAction.update { $0 = nil }
        if scheduler.pendingCount != 0 { failures.append("manual callback still held") }
        if !owner.provenanceSnapshot().waiters.isEmpty { failures.append("checked continuation still pending") }
        if installer.pendingCount != 0 { failures.append("real installer still active") }
        if !errors.read().isEmpty { failures.append(contentsOf: errors.read()) }
        withExtendedLifetime(temporaryTransports) {}
        withExtendedLifetime(transport) {}
        return failures
    }
}

@MainActor
private func withRootFixture(holdCreatorReturn: Bool = false, holdTaskBody: Bool = false,
                             _ body: (RootFixture) async throws -> Void) async throws {
    let f = RootFixture(holdCreatorReturn: holdCreatorReturn, holdTaskBody: holdTaskBody)
    var primary: Error?
    do { try await body(f) } catch { primary = error }
    let cleanup = await f.cleanup()
    if let primary {
        if cleanup.isEmpty { throw primary }
        throw RootCleanupFailure(primary: primary, cleanup: cleanup)
    }
    try requireFixture(cleanup.isEmpty, cleanup.joined(separator: "; "))
}

private func closedReceipt(_ result: NostrOutboundOwner.RootCloseOutcome,
                           binding: NostrOutboundPanicBinding) throws -> NostrOutboundOwner.RootCloseReceipt {
    guard case .closed(let receipt) = result else { throw RootFixtureError("actual captured owner did not close") }
    try requireFixture(receipt.ownerID === binding.ownerID && binding.subject.ownerID === binding.ownerID,
                       "actual installed binding owner mismatch")
    return receipt
}

private func expectRootRefusal<T>(_ result: NostrOutboundOwner.Reservation<T>,
                                  original: NostrOutboundOwner.RootCloseReceipt) throws {
    let refusal: NostrOutboundOwner.RootCloseReceipt?
    if case .refusedBeforeRoot(let receipt) = result { refusal = receipt } else { refusal = nil }
    let actual = try #require(refusal)
    #expect(actual === original)
    #expect(actual.ownerID === original.ownerID)
    #expect(actual.eventID === original.eventID)
}

private func callbackRow(_ state: NostrOutboundOwner.Snapshot,
                         kind: NostrOutboundOwner.CallbackKind) throws -> NostrOutboundOwner.CallbackRow {
    let matching = state.callbacks.filter { $0.kind == kind }
    try requireFixture(matching.count == 1, "expected one actual callback of kind \(kind)")
    return matching[0]
}

private func expectAckChain(_ state: NostrOutboundOwner.Snapshot, handoff: NostrOutboundOwner.CallbackRow) throws {
    let append = try callbackRow(state, kind: .ackQueueAppend)
    let reset = try callbackRow(state, kind: .ackResetScheduler)
    let hop = try callbackRow(state, kind: .ackResetQueue)
    #expect(append.parent === handoff.id)
    #expect(reset.parent === handoff.id)
    #expect(hop.parent === reset.id)
    #expect(handoff.state == .bodyReturned)
    #expect(append.state == .bodyReturned)
    #expect(reset.state == .bodyReturned)
    #expect(hop.state == .bodyReturned)
}

private func syntheticIdentity() -> NostrIdentity {
    NostrIdentity(privateKey: Data(), publicKey: Data(), npub: "synthetic-unused", createdAt: Date(timeIntervalSince1970: 0))
}

private func requireFixture(_ condition: Bool, _ message: String) throws {
    if !condition { throw RootFixtureError(message) }
}

private func eventually(_ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !condition() {
        if clock.now >= deadline { throw RootFixtureError("owned readiness/completion guard expired") }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
}

private func checkpoint(_ queue: DispatchQueue) async throws {
    let completed = Locked(false)
    queue.async { completed.update { $0 = true } }
    try await eventually { completed.read() }
}
