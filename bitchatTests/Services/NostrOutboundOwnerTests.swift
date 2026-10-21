import Foundation
import Testing
@testable import bitchat

/// Pure metadata, real owned Tasks and an isolated serial ACK queue. No transport graph is created.
struct NostrOutboundOwnerTests {
    @Test
    func defaultCreatorExecutesOnceWithExplicitTaskLocal() async throws {
        try await withFixture(useDefaultCreator: true, holdBody: false) { f in
            let observed = Locked<[String?]>([])
            let ticket = try taskTicket(f.owner, kind: .privateMessage)
            let callback = try callbackTicket(f.owner, kind: .refreshStateWrite, parent: .child(ticket))
            let submission = LocalValue.$value.withValue("original-synthetic-context") {
                f.owner.dispatch(ticket) { observed.update { $0.append(LocalValue.value) } }
            }
            guard case .handleRegistered(let submittedID) = submission else {
                throw FixtureError("valid task did not register its real handle")
            }
            #expect(submittedID === ticket.id)
            let batch = f.owner.taskBatchSnapshot()
            let joined = try await f.join(batch).joined()
            expectJoined(joined, batch: batch, owner: f.owner)
            #expect(observed.read() == ["original-synthetic-context"])
            let snapshot = f.owner.provenanceSnapshot()
            #expect(snapshot.ownerID === f.owner.id)
            let row = try #require(snapshot.tasks.first)
            #expect(row.id === ticket.id)
            #expect(row.parent == nil)
            #expect(row.kind == .privateMessage)
            #expect(row.body == .returned)
            #expect(row.registration == .supervisorJoined)
            let pending = try #require(snapshot.callbacks.first)
            #expect(pending.id === callback.id)
            #expect(pending.parent === ticket.id)
            #expect(pending.kind == .refreshStateWrite)
            #expect(pending.state == .reserved)
            #expect(snapshot.waiters.isEmpty)
            #expect(snapshot.debts.isEmpty)
            #expect(snapshot.unconfirmedHandleCount == 0)
        }
    }

    @Test
    func startedTaskBeforeHandleReturnRemainsRegistrationDebt() async throws {
        try await withFixture(holdReturn: true) { f in
            let executions = Locked(0)
            let ticket = try taskTicket(f.owner)
            f.dispatchOnWorker(ticket) { executions.update { $0 += 1 } }
            try await eventually { f.createdCount == 1 && f.taskEntered.read() }
            let batch = f.owner.taskBatchSnapshot()
            let joiner = f.join(batch)
            try await eventually { f.owner.provenanceSnapshot().waiters.first?.state == .waitingForHandle }
            let before = try taskRow(f.owner, ticket)
            #expect(before.registration == .reservedAwaitingHandle)
            #expect(before.body == .notEntered)
            #expect(joiner.result.read() == nil)
            let waiter = try #require(f.owner.provenanceSnapshot().waiters.first)
            #expect(waiter.taskID === ticket.id)
            f.releaseReturn()
            try await f.reapWorkers()
            #expect(try taskRow(f.owner, ticket).registration == .handleRegistered)
            #expect(executions.read() == 0)
            f.body.open()
            let joined = try await joiner.joined()
            expectJoined(joined, batch: batch, owner: f.owner)
            #expect(executions.read() == 1)
            #expect(try taskRow(f.owner, ticket).registration == .supervisorJoined)
        }
    }

    @Test
    func completedTaskBeforeHandleReturnStillRegistersAndJoinsExactTicket() async throws {
        try await withFixture(holdReturn: true, holdBody: false) { f in
            let ticket = try taskTicket(f.owner, kind: .favoriteNotification)
            f.dispatchOnWorker(ticket) {}
            // This observer sets completion only AFTER awaiting the actual handle.value.
            try await eventually { f.createdCount == 1 && f.ledger.finishedCount == 1 }
            let before = try taskRow(f.owner, ticket)
            #expect(before.body == .returned)
            #expect(before.registration == .reservedAwaitingHandle)
            let batch = f.owner.taskBatchSnapshot()
            let joiner = f.join(batch)
            try await eventually { f.owner.provenanceSnapshot().waiters.first?.state == .waitingForHandle }
            #expect(joiner.result.read() == nil)
            f.releaseReturn()
            try await f.reapWorkers()
            let joined = try await joiner.joined()
            expectJoined(joined, batch: batch, owner: f.owner)
            #expect(try taskRow(f.owner, ticket).registration == .supervisorJoined)
            #expect(f.createdCount == 1)
        }
    }

    @Test
    func cancellationBeforeWaiterInstallWaitsForRealDischarge() async throws {
        try await withFixture(holdReturn: true, holdInstaller: true) { f in
            let ticket = try taskTicket(f.owner)
            f.dispatchOnWorker(ticket) {}
            try await eventually { f.createdCount == 1 }
            let batch = f.owner.taskBatchSnapshot()
            let joiner = f.join(batch)
            try await eventually { f.installer.pendingCount == 1 }
            let bound = try #require(f.owner.provenanceSnapshot().waiters.first)
            #expect(bound.taskID === ticket.id)
            #expect(bound.state == .boundPendingInstall)
            joiner.handle.cancel()
            try await eventually { f.owner.provenanceSnapshot().waiters.first?.state == .cancelRequestedPendingInstall }
            let cancelled = try #require(f.owner.provenanceSnapshot().waiters.first)
            #expect(cancelled.id === bound.id)
            #expect(cancelled.taskID === ticket.id)
            #expect(joiner.result.read() == nil)
            #expect(try taskRow(f.owner, ticket).registration == .reservedAwaitingHandle)
            try f.installer.releaseFirst()
            try await joiner.cancelled()
            #expect(f.owner.provenanceSnapshot().waiters.isEmpty)
            f.installer.forwardAndRelease()
            f.releaseReturn()
            f.body.open()
            try await f.reapWorkers()
            let joined = try await f.join(batch).joined()
            expectJoined(joined, batch: batch, owner: f.owner)
            #expect(f.createdCount == 1)
        }
    }

    @Test
    func cancellationAfterWaiterInstallPreservesLateHandle() async throws {
        try await withFixture(holdReturn: true) { f in
            let ticket = try taskTicket(f.owner)
            f.dispatchOnWorker(ticket) {}
            try await eventually { f.createdCount == 1 }
            let batch = f.owner.taskBatchSnapshot()
            let joiner = f.join(batch)
            try await eventually { f.owner.provenanceSnapshot().waiters.first?.state == .waitingForHandle }
            let linked = try #require(f.owner.provenanceSnapshot().waiters.first)
            #expect(linked.taskID === ticket.id)
            joiner.handle.cancel()
            try await joiner.cancelled()
            #expect(f.owner.provenanceSnapshot().waiters.isEmpty)
            #expect(try taskRow(f.owner, ticket).registration == .reservedAwaitingHandle)
            f.releaseReturn()
            f.body.open()
            try await f.reapWorkers()
            let joined = try await f.join(batch).joined()
            expectJoined(joined, batch: batch, owner: f.owner)
            #expect(f.owner.provenanceSnapshot().tasks.count == 1)
            #expect(f.createdCount == 1)
        }
    }

    @Test
    func registrationBeforeWaiterInstallResumesExactlyOnce() async throws {
        try await withFixture(holdReturn: true, holdInstaller: true) { f in
            let ticket = try taskTicket(f.owner, kind: .explicitIdentityMessage)
            f.dispatchOnWorker(ticket) {}
            try await eventually { f.createdCount == 1 }
            let batch = f.owner.taskBatchSnapshot()
            let joiner = f.join(batch)
            try await eventually { f.installer.pendingCount == 1 }
            f.releaseReturn()
            try await f.reapWorkers()
            #expect(try taskRow(f.owner, ticket).registration == .handleRegistered)
            #expect(f.owner.provenanceSnapshot().waiters.first?.state == .boundPendingInstall)
            try f.installer.releaseFirst()
            #expect(f.owner.provenanceSnapshot().waiters.isEmpty)
            #expect(joiner.result.read() == nil)
            #expect(try taskRow(f.owner, ticket).body == .notEntered)
            f.body.open()
            let joined = try await joiner.joined()
            expectJoined(joined, batch: batch, owner: f.owner)
            #expect(joiner.completions.read() == 1)
            #expect(f.installer.invocations == 1)
            #expect(f.owner.provenanceSnapshot().debts.isEmpty)
        }
    }

    @Test
    func parentAndChildTasksKeepDistinctTicketsOutsideEarlierBatch() async throws {
        try await withFixture { f in
            let child = Locked<NostrOutboundOwner.TaskTicket?>(nil)
            let parent = try taskTicket(f.owner, kind: .privateMessage)
            f.owner.dispatch(parent) {
                guard case .reserved(let ticket) = f.owner.reserveTask(kind: .ackItem, parent: .child(parent)) else {
                    f.errors.update { $0.append("child reservation failed") }; return
                }
                child.update { $0 = ticket }
                f.owner.dispatch(ticket) {}
            }
            let earlier = f.owner.taskBatchSnapshot()
            #expect(earlier.taskIDs == [parent.id])
            f.body.open()
            try await eventually { child.read() != nil }
            let ticket = try #require(child.read())
            let firstProof = try await f.join(earlier).joined()
            expectJoined(firstProof, batch: earlier, owner: f.owner)
            #expect(firstProof.taskIDs == [parent.id])
            #expect(ticket.id !== parent.id)
            let row = try taskRow(f.owner, ticket)
            #expect(row.parent === parent.id)
            #expect(row.kind == .ackItem)
            #expect(row.registration == .handleRegistered)
            let later = f.owner.taskBatchSnapshot()
            #expect(later.id !== earlier.id)
            #expect(later.taskIDs == [parent.id, ticket.id])
            let secondProof = try await f.join(later).joined()
            expectJoined(secondProof, batch: later, owner: f.owner)
            #expect(try taskRow(f.owner, ticket).registration == .supervisorJoined)
        }
    }

    @Test
    func pacerAppendResetAndAckChildKeepOriginalOwnerLineage() async throws {
        try await withFixture(holdBody: false) { f in
            let queue = DispatchQueue(label: "synthetic.nostr-outbound-owner.serial-ack")
            let scheduler = ManualScheduler()
            let pacer = NostrTransport.AckPacer(owner: f.owner, queue: queue, scheduleAfter: { delay, action in
                scheduler.schedule(delay, action)
            })
            #expect(pacer.owner === f.owner)
            f.extraCleanup = {
                // Only the two known sends can schedule reset callbacks; each submits its real queue hop.
                for _ in 0..<3 {
                    scheduler.releaseAll()
                    try await checkpoint(queue)
                }
                try requireFixture(scheduler.pendingCount == 0, "ACK reset callback was not discharged")
                withExtendedLifetime(pacer) {}
            }
            let first = try callbackTicket(f.owner, kind: .pendingAckHandoff)
            let second = try callbackTicket(f.owner, kind: .pendingAckHandoff)
            let childIDs = Locked<[NostrOutboundOwner.Identity]>([])
            let send: (NostrOutboundOwner.CallbackTicket) -> Void = { parent in
                guard case .reserved(let ticket) = f.owner.reserveTask(kind: .ackItem, parent: .child(parent)) else {
                    f.errors.update { $0.append("ACK child reservation failed") }; return
                }
                childIDs.update { $0.append(ticket.id) }
                f.owner.dispatch(ticket) {}
            }
            pacer.enqueue(ticket: first, send)
            pacer.enqueue(ticket: second, send)
            try await checkpoint(queue)
            let initial = f.owner.provenanceSnapshot()
            #expect(initial.ownerID === f.owner.id)
            #expect(try callbackRow(initial, first.id).state == .bodyReturned)
            #expect(try callbackRow(initial, second.id).state == .reserved)
            let appendRows = initial.callbacks.filter { $0.kind == .ackQueueAppend }
            #expect(appendRows.count == 2)
            #expect(appendRows.map(\.parent) == [first.id, second.id])
            let appendsReturned = appendRows.allSatisfy { $0.state == .bodyReturned }
            #expect(appendsReturned)
            #expect(scheduler.pendingCount == 1)
            #expect(scheduler.delays == [TransportConfig.nostrReadAckInterval])
            try scheduler.releaseFirst()
            try await checkpoint(queue)
            #expect(childIDs.read().count == 2)
            #expect(scheduler.pendingCount == 1)
            try scheduler.releaseFirst()
            try await checkpoint(queue)
            let batch = f.owner.taskBatchSnapshot()
            let proof = try await f.join(batch).joined()
            expectJoined(proof, batch: batch, owner: f.owner)
            #expect(proof.taskIDs == childIDs.read())
            let final = f.owner.provenanceSnapshot()
            #expect(final.tasks.map(\.parent) == [first.id, second.id])
            let taskKinds = final.tasks.allSatisfy { $0.kind == .ackItem && $0.registration == .supervisorJoined }
            #expect(taskKinds)
            let resets = final.callbacks.filter { $0.kind == .ackResetScheduler }
            let hops = final.callbacks.filter { $0.kind == .ackResetQueue }
            #expect(resets.count == 2)
            #expect(hops.count == 2)
            #expect(resets.map(\.parent) == [first.id, second.id])
            #expect(hops.map(\.parent) == resets.map { Optional($0.id) })
            let allCallbacksReturned = final.callbacks.allSatisfy { $0.state == .bodyReturned }
            #expect(allCallbacksReturned)
            #expect(scheduler.pendingCount == 0)
            #expect(scheduler.delays == [TransportConfig.nostrReadAckInterval, TransportConfig.nostrReadAckInterval])
            #expect(final.debts.isEmpty)
            #expect(final.unconfirmedHandleCount == 0)
        }
    }

    @Test
    func foreignAndDuplicateProtocolUseRetainsOriginalDebtAndHandle() async throws {
        try await withFixture(holdReturn: true, holdInstaller: true) { f in
            let foreignCreations = Locked(0)
            let foreign = NostrOutboundOwner(taskCreator: { operation in
                foreignCreations.update { $0 += 1 }
                return f.ledger.track(Task { @MainActor in operation() })
            }, waiterInstaller: NostrOutboundOwner.inlineWaiterInstaller)
            let ticket = try taskTicket(f.owner)
            f.dispatchOnWorker(ticket) {}
            try await eventually { f.createdCount == 1 }
            let batch = f.owner.taskBatchSnapshot()
            let joiner = f.join(batch)
            try await eventually { f.installer.pendingCount == 1 }
            guard case .protocolDebt(let foreignDispatch) = foreign.dispatch(ticket, operation: {}) else {
                throw FixtureError("foreign ticket was dispatched")
            }
            guard case .protocolDebt(let invalidParent) = foreign.reserveCallback(kind: .ackQueueAppend, parent: .child(ticket)) else {
                throw FixtureError("foreign parent was accepted")
            }
            do {
                _ = try await foreign.joinTaskBatch(batch)
                throw FixtureError("foreign batch was joined")
            } catch NostrOutboundOwner.JoinError.foreignBatch {}
            guard case .protocolDebt(let replay) = f.owner.dispatch(ticket, operation: {}) else {
                throw FixtureError("duplicate submission invoked a creator")
            }
            f.releaseReturn()
            f.body.open()
            try await f.reapWorkers()
            try await eventually { f.ledger.finishedCount == 1 }
            try f.installer.releaseFirst(replay: true)
            try await joiner.protocolFailure()
            #expect(joiner.completions.read() == 1)
            #expect(f.installer.invocations == 2)
            #expect(f.createdCount == 1)
            #expect(foreignCreations.read() == 0)
            let original = f.owner.provenanceSnapshot()
            #expect(original.tasks.count == 1)
            let row = try #require(original.tasks.first)
            #expect(row.id === ticket.id)
            #expect(row.registration == .unknownProtocolDebt)
            #expect(row.body == .returned)
            #expect(original.waiters.isEmpty)
            #expect(original.unconfirmedHandleCount == 0)
            #expect(original.debts.first?.id === replay)
            #expect(original.debts.first?.workID === ticket.id)
            #expect(original.debts.first?.fault == .replayedSubmission)
            #expect(original.debts.last?.fault == .duplicateInstallation)
            let foreignDebt = foreign.provenanceSnapshot().debts
            try #require(foreignDebt.count == 3)
            #expect(foreignDebt.map(\.fault) == [.foreignOwner, .invalidParent, .foreignOwner])
            #expect(foreignDebt[0].id === foreignDispatch)
            #expect(foreignDebt[1].id === invalidParent)
            let foreignWorkAbsent = foreignDebt.allSatisfy { $0.workID == nil }
            #expect(foreignWorkAbsent)
            #expect(foreign.provenanceSnapshot().tasks.isEmpty)
            // Protocol debt deliberately forbids owner proof. Cleanup joins the ACTUAL creator-ledger handle.
            let actual = try #require(f.ledger.handles.first)
            await actual.handle.value
        }
    }
}

private enum LocalValue { @TaskLocal static var value: String? }

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct FixtureCleanupFailure: Error, CustomStringConvertible {
    let primary: Error
    let cleanup: [String]
    var description: String {
        "primary: \(primary); independent cleanup failures: \(cleanup.joined(separator: "; "))"
    }
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
    private struct State { var open = false; var continuations: [CheckedContinuation<Void, Never>] = [] }
    private let state = Locked(State())
    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = state.update { state in
                if state.open { return true }
                state.continuations.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }
    func open() {
        let pending = state.update { state in
            state.open = true
            let pending = state.continuations
            state.continuations.removeAll()
            return pending
        }
        pending.forEach { $0.resume() }
    }
}

private final class TaskLedger: @unchecked Sendable {
    struct Tracked: Sendable {
        let handle: Task<Void, Never>
        let observer: Task<Void, Never>
        let finished: Locked<Bool>
    }
    private let rows = Locked<[Tracked]>([])
    var handles: [Tracked] { rows.read() }
    var finishedCount: Int { handles.filter { $0.finished.read() }.count }
    @discardableResult func track(_ handle: Task<Void, Never>) -> Task<Void, Never> {
        let finished = Locked(false)
        let observer = Task { await handle.value; finished.update { $0 = true } }
        rows.update { $0.append(Tracked(handle: handle, observer: observer, finished: finished)) }
        return handle
    }
    func drain() async throws {
        // A finite controlled parent may register a child while being joined; reread this actual ledger.
        var index = 0
        while index < handles.count {
            let row = handles[index]
            try await eventually { row.finished.read() }
            await row.handle.value
            await row.observer.value
            index += 1
        }
    }
}

private final class Installer: @unchecked Sendable {
    private struct State {
        var hold: Bool
        var pending: [@Sendable () -> Void] = []
        var invocations = 0
    }
    private let state: Locked<State>
    init(hold: Bool) { state = Locked(State(hold: hold)) }
    var pendingCount: Int { state.read().pending.count }
    var invocations: Int { state.read().invocations }
    func submit(_ action: @escaping @Sendable () -> Void) {
        let run = state.update { state in
            if state.hold { state.pending.append(action); return false }
            state.invocations += 1
            return true
        }
        if run { action() }
    }
    func releaseFirst(replay: Bool = false) throws {
        let action = state.update { state -> (@Sendable () -> Void)? in
            guard !state.pending.isEmpty else { return nil }
            return state.pending.removeFirst()
        }
        guard let action else { throw FixtureError("no real held installer action") }
        state.update { $0.invocations += 1 }
        action()
        if replay { state.update { $0.invocations += 1 }; action() }
    }
    func forwardAndRelease() {
        let pending = state.update { state in
            state.hold = false
            let pending = state.pending
            state.pending.removeAll()
            state.invocations += pending.count
            return pending
        }
        pending.forEach { $0() }
    }
}

private enum JoinOutcome {
    case joined(NostrOutboundOwner.JoinedTaskBatch), cancelled, protocolFailure, unexpected(String)
}

private final class Joiner: @unchecked Sendable {
    let result = Locked<JoinOutcome?>(nil)
    let completions = Locked(0)
    private(set) var handle: Task<Void, Never>!
    init(owner: NostrOutboundOwner, batch: NostrOutboundOwner.TaskBatch, ledger: TaskLedger) {
        handle = ledger.track(Task { [self] in
            let outcome: JoinOutcome
            do { outcome = .joined(try await owner.joinTaskBatch(batch)) }
            catch is CancellationError { outcome = .cancelled }
            catch NostrOutboundOwner.JoinError.protocolDebt { outcome = .protocolFailure }
            catch { outcome = .unexpected(String(describing: error)) }
            result.update { $0 = outcome }
            completions.update { $0 += 1 }
        })
    }
    private func settled() async throws -> JoinOutcome {
        try await eventually { self.result.read() != nil }
        await handle.value
        guard let outcome = result.read() else { throw FixtureError("owned join lost its outcome") }
        if case .unexpected(let reason) = outcome { throw FixtureError("unexpected owned join failure: \(reason)") }
        return outcome
    }
    func joined() async throws -> NostrOutboundOwner.JoinedTaskBatch {
        guard case .joined(let proof) = try await settled() else {
            throw FixtureError("join did not produce exact task proof")
        }
        return proof
    }
    func cancelled() async throws {
        guard case .cancelled = try await settled() else {
            throw FixtureError("join did not observe cancellation")
        }
    }
    func protocolFailure() async throws {
        guard case .protocolFailure = try await settled() else {
            throw FixtureError("join did not preserve protocol debt")
        }
    }
}

private final class Fixture: @unchecked Sendable {
    let owner: NostrOutboundOwner
    let body: AsyncGate
    let taskEntered: Locked<Bool>
    let ledger: TaskLedger
    let installer: Installer
    let errors: Locked<[String]>
    private let creators: Locked<Int>
    private let returnGate: DispatchSemaphore
    private let workers = Locked<[Thread]>([])
    private let joiners = Locked<[Joiner]>([])
    var extraCleanup: (() async throws -> Void)?
    var createdCount: Int { creators.read() }

    init(useDefaultCreator: Bool, holdReturn: Bool, holdBody: Bool, holdInstaller: Bool) {
        let body = AsyncGate()
        let ledger = TaskLedger()
        let installer = Installer(hold: holdInstaller)
        let errors = Locked<[String]>([])
        self.body = body; self.ledger = ledger; self.installer = installer; self.errors = errors
        let creators = Locked(0)
        let taskEntered = Locked(false)
        let returnGate = DispatchSemaphore(value: 0)
        self.creators = creators; self.taskEntered = taskEntered; self.returnGate = returnGate
        if !holdBody { body.open() }
        owner = NostrOutboundOwner(taskCreator: { operation in
            let handle: Task<Void, Never>
            if useDefaultCreator {
                handle = NostrOutboundOwner.mainActorTaskCreator(operation)
            } else {
                handle = Task { @MainActor in
                    taskEntered.update { $0 = true }
                    await body.wait()
                    operation()
                }
            }
            ledger.track(handle)
            creators.update { $0 += 1 }
            if holdReturn && returnGate.wait(timeout: .now() + TestConstants.settleTimeout) != .success {
                errors.update { $0.append("owned Task creator handle-return barrier timed out") }
            }
            return handle
        }, waiterInstaller: { action in installer.submit(action) })
    }

    func dispatchOnWorker(_ ticket: NostrOutboundOwner.TaskTicket, operation: @escaping NostrOutboundOwner.Operation) {
        let worker = Thread { [self] in _ = owner.dispatch(ticket, operation: operation) }
        worker.name = "synthetic-nostr-owned-creator"
        workers.update { $0.append(worker) }
        worker.start()
    }
    func releaseReturn() { returnGate.signal() }
    func join(_ batch: NostrOutboundOwner.TaskBatch) -> Joiner {
        let joiner = Joiner(owner: owner, batch: batch, ledger: ledger)
        joiners.update { $0.append(joiner) }
        return joiner
    }
    func reapWorkers() async throws {
        for worker in workers.read() { try await eventually { worker.isFinished } }
        try requireFixture(errors.read().isEmpty, errors.read().joined(separator: "; "))
    }
    func cleanup() async -> [String] {
        var failures: [String] = []
        body.open()
        workers.read().forEach { _ in returnGate.signal() }
        joiners.read().forEach { $0.handle.cancel() }
        installer.forwardAndRelease()
        if let extraCleanup {
            do { try await extraCleanup() } catch { failures.append("queue cleanup: \(error)") }
        }
        do { try await reapWorkers() } catch { failures.append("worker cleanup: \(error)") }
        do { try await ledger.drain() } catch { failures.append("actual Task.value cleanup: \(error)") }
        installer.forwardAndRelease()
        if installer.pendingCount != 0 { failures.append("real waiter installer still held") }
        if !owner.provenanceSnapshot().waiters.isEmpty { failures.append("registration continuation still pending") }
        return failures
    }
}

private final class ManualScheduler: @unchecked Sendable {
    private struct State {
        var pending: [@Sendable () -> Void] = []
        var delays: [TimeInterval] = []
    }
    private let state = Locked(State())
    var pendingCount: Int { state.read().pending.count }
    var delays: [TimeInterval] { state.read().delays }
    func schedule(_ delay: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        state.update { $0.delays.append(delay); $0.pending.append(action) }
    }
    func releaseFirst() throws {
        let action = state.update { state -> (@Sendable () -> Void)? in
            state.pending.isEmpty ? nil : state.pending.removeFirst()
        }
        guard let action else { throw FixtureError("no submitted ACK reset callback") }
        action()
    }
    func releaseAll() {
        let pending = state.update { state in
            let pending = state.pending; state.pending.removeAll(); return pending
        }
        pending.forEach { $0() }
    }
}

private func withFixture(useDefaultCreator: Bool = false, holdReturn: Bool = false,
                         holdBody: Bool = true, holdInstaller: Bool = false,
                         _ body: (Fixture) async throws -> Void) async throws {
    let fixture = Fixture(useDefaultCreator: useDefaultCreator, holdReturn: holdReturn,
                          holdBody: holdBody, holdInstaller: holdInstaller)
    var primary: Error?
    do { try await body(fixture) } catch { primary = error }
    let cleanup = await fixture.cleanup()
    if let primary {
        if cleanup.isEmpty { throw primary }
        throw FixtureCleanupFailure(primary: primary, cleanup: cleanup)
    }
    try requireFixture(cleanup.isEmpty, cleanup.joined(separator: "; "))
}

private func taskTicket(_ owner: NostrOutboundOwner, kind: NostrOutboundOwner.TaskKind = .privateMessage,
                        parent: NostrOutboundOwner.Parent = .root) throws -> NostrOutboundOwner.TaskTicket {
    guard case .reserved(let ticket) = owner.reserveTask(kind: kind, parent: parent) else {
        throw FixtureError("task ticket reservation failed")
    }
    return ticket
}

private func callbackTicket(_ owner: NostrOutboundOwner, kind: NostrOutboundOwner.CallbackKind,
                            parent: NostrOutboundOwner.Parent = .root) throws -> NostrOutboundOwner.CallbackTicket {
    guard case .reserved(let ticket) = owner.reserveCallback(kind: kind, parent: parent) else {
        throw FixtureError("callback ticket reservation failed")
    }
    return ticket
}

private func taskRow(_ owner: NostrOutboundOwner, _ ticket: NostrOutboundOwner.TaskTicket) throws -> NostrOutboundOwner.TaskRow {
    try #require(owner.provenanceSnapshot().tasks.first { $0.id === ticket.id })
}

private func callbackRow(_ snapshot: NostrOutboundOwner.Snapshot, _ id: NostrOutboundOwner.Identity) throws -> NostrOutboundOwner.CallbackRow {
    try #require(snapshot.callbacks.first { $0.id === id })
}

private func expectJoined(_ joined: NostrOutboundOwner.JoinedTaskBatch,
                          batch: NostrOutboundOwner.TaskBatch, owner: NostrOutboundOwner) {
    #expect(joined.ownerID === owner.id)
    #expect(joined.ownerID === batch.ownerID)
    #expect(joined.batchID === batch.id)
    #expect(joined.taskIDs == batch.taskIDs)
}

private func requireFixture(_ condition: Bool, _ message: String) throws {
    if !condition { throw FixtureError(message) }
}

private func eventually(fileID: StaticString = #fileID, line: UInt = #line,
                        _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    // A hang guard, not a latency budget: starved CI queues took over 5 s.
    let deadline = clock.now.advanced(by: .seconds(TestConstants.settleTimeout))
    while !condition() {
        if clock.now >= deadline { throw FixtureError("owned completion/readiness guard expired at \(fileID):\(line)") }
        // Cancellation cannot skip the owned-fixture release/reap protocol. This is a readiness guard.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
}

private func checkpoint(_ queue: DispatchQueue) async throws {
    let passed = Locked(false)
    queue.async { passed.update { $0 = true } }
    try await eventually { passed.read() }
}
