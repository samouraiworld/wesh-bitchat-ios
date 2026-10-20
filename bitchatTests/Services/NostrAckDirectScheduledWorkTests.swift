import Foundation
import Testing
@testable import bitchat

/// Exact scheduled items and their real reset consumer; no providers, keys or live transport graph.
@MainActor
@Suite(.serialized)
struct NostrAckDirectScheduledWorkTests {
    @Test func heldOriginalScheduledItemPreventsNextAck() async throws {
        try await withAckFixture { f in
            try f.offer(1); try f.offer(2)
            try await f.checkpoint()
            let item = try f.scheduler.takeFirst()
            let before = f.handoffs.read()
            let pending = f.scheduler.pendingCount
            f.scheduler.performOnce(item)
            try await ackEventually { f.handoffs.read() == [1, 2] }
            let after = f.handoffs.read()
            return {
                #expect(before == [1])
                #expect(pending == 0)
                #expect(after == [1, 2])
            }
        }
    }

    @Test func notificationDoesNotClaimSchedulerOuterHostReturn() async throws {
        try await withAckFixture { f in
            let tail = f.gate()
            f.scheduler.useOuterTail(tail)
            try f.offer(1); try f.offer(2)
            try await ackEventually { tail.entered.read() && f.handoffs.read() == [1, 2] }
            let nextAlreadySent = f.handoffs.read() == [1, 2]
            let outerTailStillHeld = !tail.opened.read()
            return {
                #expect(nextAlreadySent)
                #expect(outerTailStillHeld)
            }
        }
    }

    @Test func canceledBeforeEntryRemainsUnconfirmed() async throws {
        try await withAckFixture { f in
            try f.offer(1); try f.offer(2)
            try await f.checkpoint()
            let item = try f.scheduler.takeFirst()
            item.cancel()
            f.scheduler.performOnce(item)
            await ackCompletion(item)
            try await f.checkpoint()
            let actual = f.handoffs.read()
            let resets = f.owner.provenanceSnapshot().callbacks.filter { $0.kind == .ackResetScheduler }
            let resetNeverEntered = resets.count == 1 && resets.allSatisfy { $0.state == .reserved }
            let canceled = item.isCancelled
            return {
                #expect(canceled)
                #expect(actual == [1])
                #expect(resetNeverEntered)
            }
        }
    }

    @Test func successiveResetsUseDistinctActualItemsAndPreserveFIFO() async throws {
        try await withAckFixture { f in
            try f.offer(1); try f.offer(2); try f.offer(3)
            try await f.checkpoint()
            let first = try f.scheduler.takeFirst()
            f.scheduler.performOnce(first)
            try await ackEventually { f.handoffs.read().count == 2 && f.scheduler.pendingCount == 1 }
            let second = try f.scheduler.takeFirst()
            let distinct = first !== second
            f.scheduler.performOnce(second)
            try await ackEventually { f.handoffs.read() == [1, 2, 3] }
            try await f.checkpoint()
            let order = f.handoffs.read()
            let delays = f.scheduler.delays
            return {
                #expect(distinct)
                #expect(order == [1, 2, 3])
                #expect(delays == Array(repeating: TransportConfig.nostrReadAckInterval, count: 3))
            }
        }
    }

    @Test func inlineOneShotSchedulerDoesNotRecurseIntoReset() async throws {
        try await withAckFixture { f in
            f.scheduler.useInline()
            try f.offer(1); try f.offer(2); try f.offer(3)
            try await ackEventually { f.handoffs.read() == [1, 2, 3] }
            try await f.checkpoint()
            let order = f.handoffs.read()
            let depth = f.maximumSendDepth.read()
            return {
                #expect(order == [1, 2, 3])
                #expect(depth == 1)
            }
        }
    }

    @Test func closedOriginalOwnerKeepsAcceptedResetAndAckChild() async throws {
        try await withAckFixture { f in
            let first = try f.offer(1)
            let second = try f.offer(2)
            try await f.checkpoint()
            let binding = f.owner.captureOutboundPanicBinding()
            guard case .closed(let receipt) = closeCapturedNostrOutboundRoots(binding) else {
                throw AckTestError("Original root did not close")
            }
            let newRoot = f.owner.reserveCallback(kind: .pendingAckHandoff, parent: .root)
            let item = try f.scheduler.takeFirst()
            f.scheduler.performOnce(item)
            try await ackEventually { f.handoffs.read() == [1, 2] }
            try await f.checkpoint()
            let snapshot = f.owner.provenanceSnapshot()
            let taskParents = snapshot.tasks.map(\.parent)
            let resetParents = snapshot.callbacks.filter { $0.kind == .ackResetScheduler }.map(\.parent)
            let refusedSame: Bool
            if case .refusedBeforeRoot(let original) = newRoot { refusedSame = original === receipt }
            else { refusedSame = false }
            return {
                #expect(refusedSame)
                #expect(taskParents == [first.id, second.id])
                #expect(resetParents == [first.id, second.id])
            }
        }
    }

    @Test func pendingScheduledItemDoesNotStronglyRetainOriginalPacer() async throws {
        try await withAckFixture { f in
            try f.offer(1)
            try await f.checkpoint()
            let item = try f.scheduler.takeFirst()
            let weakPacer = f.dropPacer()
            try await ackEventually { weakPacer.value == nil }
            let goneBefore = weakPacer.value == nil
            f.scheduler.performOnce(item)
            await ackCompletion(item)
            try await f.checkpoint()
            let goneAfter = weakPacer.value == nil
            let rows = f.owner.provenanceSnapshot().callbacks
            let resets = rows.filter { $0.kind == .ackResetScheduler }
            let resetReturned = resets.count == 1 && resets.allSatisfy { $0.state == .bodyReturned }
            let noNewConsumer = rows.allSatisfy { $0.kind != .ackResetQueue }
            return {
                #expect(goneBefore && goneAfter)
                #expect(resetReturned)
                #expect(noNewConsumer)
            }
        }
    }
    @Test func earlyPrimaryErrorReapsBothRealManualResetBatches() async throws {
        let injected = AckInjectedPrimary()
        let cleanupObservation = AckBox<AckCleanupObservation?>(nil)
        do {
            try await withAckFixture(cleanupObservation: cleanupObservation) { f in
                try f.offer(1); try f.offer(2)
                try await f.checkpoint()
                guard f.scheduler.pendingCount == 1 else { throw AckTestError("First original reset was not held") }
                _ = try f.scheduler.takeFirst()
                guard f.scheduler.pendingCount == 0 else { throw AckTestError("Taken original reset remained pending") }
                throw injected
            }
            throw AckTestError("Unique injected primary error did not propagate")
        } catch let actual as AckInjectedPrimary {
            guard actual === injected else { throw actual }
        }
        guard let observed = cleanupObservation.read() else { throw AckTestError("Actual cleanup observation unavailable") }
        #expect(observed.scheduledCount == 2)
        #expect(observed.allActualApplicationsCompleted)
        #expect(observed.deferredManualBatchExposed)
        #expect(observed.handoffs == [1, 2])
        #expect(observed.actualTaskCount == 2)
    }

}

private final class AckInjectedPrimary: Error {}
private struct AckCleanupObservation {
    let scheduledCount: Int
    let allActualApplicationsCompleted: Bool
    let deferredManualBatchExposed: Bool
    let handoffs: [Int]
    let actualTaskCount: Int
}

private struct AckTestError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
private struct AckCleanupError: Error, CustomStringConvertible {
    let primary: Error
    let independent: [Error]
    var description: String { "primary: \(primary); independent cleanup: \(independent)" }
}
private final class AckBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    @discardableResult func update<Result>(_ action: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }; return action(&value)
    }
}

private final class AckGate: @unchecked Sendable {
    let entered = AckBox(false)
    let opened = AckBox(false)
    private let condition = NSCondition()
    private let errors: AckBox<[String]>
    init(errors: AckBox<[String]>) { self.errors = errors }
    func open() { condition.lock(); opened.update { $0 = true }; condition.broadcast(); condition.unlock() }
    func hold() {
        condition.lock()
        entered.update { $0 = true }
        let deadline = Date().addingTimeInterval(5)
        while !opened.read() {
            if !condition.wait(until: deadline) { errors.update { $0.append("Owned scheduler tail exceeded guard") }; break }
        }
        while !opened.read() { condition.wait() }
        condition.unlock()
    }
}

private final class AckScheduler: @unchecked Sendable {
    private enum ExecutionOwner: Equatable { case manual, inline, outer }
    private struct State {
        var items: [DispatchWorkItem] = []
        var pending: [DispatchWorkItem] = []
        var executionOwners: [ObjectIdentifier: ExecutionOwner] = [:]
        var performed: Set<ObjectIdentifier> = []
        var finished: Set<ObjectIdentifier> = []
        var outerItems: [DispatchWorkItem] = []
        var outerSubmitted: Set<ObjectIdentifier> = []
        var outerFinished: Set<ObjectIdentifier> = []
        var delays: [TimeInterval] = []
        var inline = false
        var outerTail: AckGate?
    }
    private let state = AckBox(State())
    private let completions = DispatchQueue(label: "synthetic.ack.work-completion")
    var pendingCount: Int { state.read().pending.count }
    var delays: [TimeInterval] { state.read().delays }
    func useInline() { state.update { $0.inline = true } }
    func useOuterTail(_ gate: AckGate) { state.update { $0.outerTail = gate } }
    func submit(_ delay: TimeInterval, _ item: DispatchWorkItem) {
        let itemID = ObjectIdentifier(item)
        item.notify(queue: completions) { [state] in
            state.update { snapshot in _ = snapshot.finished.insert(itemID) }
        }
        let mode = state.update { s -> (Bool, AckGate?) in
            s.items.append(item); s.delays.append(delay)
            if s.inline { s.executionOwners[itemID] = .inline }
            else if s.outerTail != nil { s.executionOwners[itemID] = .outer }
            else { s.executionOwners[itemID] = .manual; s.pending.append(item) }
            return (s.inline, s.outerTail)
        }
        if mode.0 { performOnce(item) }
        else if let tail = mode.1 {
            let outer = DispatchWorkItem { [self] in performOnce(item); tail.hold() }
            let outerID = ObjectIdentifier(outer)
            outer.notify(queue: completions) { [state] in
                state.update { snapshot in _ = snapshot.outerFinished.insert(outerID) }
            }
            state.update { $0.outerItems.append(outer) }
            DispatchQueue.global(qos: .utility).async(execute: outer)
            state.update { $0.outerSubmitted.insert(outerID) }
        }
    }
    func takeFirst() throws -> DispatchWorkItem {
        guard let item = state.update({ s in s.pending.isEmpty ? nil : s.pending.removeFirst() }) else {
            throw AckTestError("No actual scheduled item")
        }
        return item
    }
    struct CleanupBatch {
        let manualToPerform: [DispatchWorkItem]
        let invokedItems: [DispatchWorkItem]
        let submittedOuterItems: [DispatchWorkItem]
    }
    /// Claim before any performer runs: a later reset cannot enter this batch's await set.
    func claimCleanupBatch() -> CleanupBatch {
        state.update { s in
            // Taking an item transfers it to the test body, not out of the fixture's ownership.
            let manual = s.items.filter {
                s.executionOwners[ObjectIdentifier($0)] == .manual && !s.performed.contains(ObjectIdentifier($0))
            }
            let manualIDs = Set(manual.map { ObjectIdentifier($0) })
            s.pending.removeAll { manualIDs.contains(ObjectIdentifier($0)) }
            var selected = manualIDs
            var invoked = manual
            for item in s.items where s.performed.contains(ObjectIdentifier(item)) {
                if selected.insert(ObjectIdentifier(item)).inserted { invoked.append(item) }
            }
            let outer = s.outerItems.filter { s.outerSubmitted.contains(ObjectIdentifier($0)) }
            return CleanupBatch(manualToPerform: manual, invokedItems: invoked, submittedOuterItems: outer)
        }
    }
    func cleanupWorkObservation() -> (Int, Bool) {
        let snapshot = state.read()
        let complete = snapshot.items.allSatisfy { snapshot.finished.contains(ObjectIdentifier($0)) } &&
            snapshot.outerItems.allSatisfy { snapshot.outerFinished.contains(ObjectIdentifier($0)) }
        return (snapshot.items.count, complete)
    }
    /// Detach only genuinely completed work. Detached handles stay pinned through unlock.
    @MainActor func retireCompletedWork() {
        let detached = state.update { s -> ([DispatchWorkItem], [DispatchWorkItem])? in
            guard s.pending.isEmpty,
                  s.items.allSatisfy({ s.finished.contains(ObjectIdentifier($0)) }),
                  s.outerItems.allSatisfy({ s.outerFinished.contains(ObjectIdentifier($0)) }) else { return nil }
            let completed = (s.items, s.outerItems)
            s.items.removeAll(); s.outerItems.removeAll()
            s.executionOwners.removeAll(); s.performed.removeAll(); s.finished.removeAll()
            s.outerSubmitted.removeAll(); s.outerFinished.removeAll()
            return completed
        }
        withExtendedLifetime(detached) {}
    }
    func performOnce(_ item: DispatchWorkItem) {
        let admitted = state.update { $0.performed.insert(ObjectIdentifier(item)).inserted }
        if admitted { item.perform() }
    }
    @MainActor func reapActualWork(_ batch: CleanupBatch) async -> [Error] {
        var failures: [Error] = []
        for item in batch.invokedItems {
            do { try await ackEventually { self.state.read().finished.contains(ObjectIdentifier(item)) } }
            catch { failures.append(error) }
            await ackCompletion(item)
        }
        for item in batch.submittedOuterItems {
            do { try await ackEventually { self.state.read().outerFinished.contains(ObjectIdentifier(item)) } }
            catch { failures.append(error) }
            await ackCompletion(item)
        }
        return failures
    }
}

private final class AckTaskLedger: @unchecked Sendable {
    private struct Row {
        let handle: Task<Void, Never>
        let observer: Task<Void, Never>
        let returned: AckBox<Bool>
    }
    private let rows = AckBox<[Row]>([])
    func track(_ handle: Task<Void, Never>) {
        let returned = AckBox(false)
        let observer = Task { await handle.value; returned.update { $0 = true } }
        rows.update { $0.append(Row(handle: handle, observer: observer, returned: returned)) }
    }
    var actualTaskCount: Int { rows.read().count }
    @MainActor func reap() async -> [Error] {
        var failures: [Error] = []
        for row in rows.read() {
            do { try await ackEventually { row.returned.read() } } catch { failures.append(error) }
            await row.handle.value
            await row.observer.value
        }
        return failures
    }
    /// Called only after the final actual-handle reap and immutable observation capture.
    @MainActor func retireReapedRows() {
        let detached = rows.update { known -> [Row] in
            let completed = known
            known.removeAll()
            return completed
        }
        withExtendedLifetime(detached) {}
    }
}

private final class AckWeakPacer {
    weak var value: NostrTransport.AckPacer?
    init(_ value: NostrTransport.AckPacer?) { self.value = value }
}

@MainActor
private final class AckFixture {
    let owner: NostrOutboundOwner
    let scheduler: AckScheduler
    let handoffs = AckBox<[Int]>([])
    let maximumSendDepth = AckBox(0)
    private let depth = AckBox(0)
    private let errors = AckBox<[String]>([])
    private let ledger: AckTaskLedger
    private let queue = DispatchQueue(label: "synthetic.ack.original-serial")
    private var pacer: NostrTransport.AckPacer?
    private var gates: [AckGate] = []
    private var offers = 0
    private var deferredManualBatchExposed = false
    private var savedCleanupObservation: AckCleanupObservation?
    init() {
        let ledger = AckTaskLedger()
        self.ledger = ledger
        let scheduler = AckScheduler()
        self.scheduler = scheduler
        let owner = NostrOutboundOwner(taskCreator: { operation in
            let task = NostrOutboundOwner.mainActorTaskCreator(operation)
            ledger.track(task)
            return task
        }, waiterInstaller: NostrOutboundOwner.inlineWaiterInstaller)
        self.owner = owner
        self.pacer = NostrTransport.AckPacer(owner: owner, queue: queue, scheduleAfter: { delay, item in
            scheduler.submit(delay, item)
        })
    }
    func gate() -> AckGate {
        let gate = AckGate(errors: errors); gates.append(gate); return gate
    }
    @discardableResult func offer(_ value: Int) throws -> NostrOutboundOwner.CallbackTicket {
        guard let pacer, case .reserved(let ticket) = owner.reserveCallback(kind: .pendingAckHandoff, parent: .root) else {
            throw AckTestError("Actual handoff root unavailable")
        }
        offers += 1
        let owner = self.owner, handoffs = self.handoffs, errors = self.errors
        let depth = self.depth, maximum = self.maximumSendDepth
        pacer.enqueue(ticket: ticket) { parent in
            let current = depth.update { $0 += 1; return $0 }
            maximum.update { $0 = max($0, current) }
            defer { depth.update { $0 -= 1 } }
            handoffs.update { $0.append(value) }
            guard case .reserved(let task) = owner.reserveTask(kind: .ackItem, parent: .child(parent)) else {
                errors.update { $0.append("Actual ACK child unavailable") }; return
            }
            owner.dispatch(task) { @MainActor in }
        }
        return ticket
    }
    func dropPacer() -> AckWeakPacer {
        let probe = AckWeakPacer(pacer); pacer = nil; return probe
    }
    func checkpoint() async throws { try await ackCheckpoint(queue) }
    func cleanupObservation() -> AckCleanupObservation {
        if let savedCleanupObservation { return savedCleanupObservation }
        let (count, complete) = scheduler.cleanupWorkObservation()
        return AckCleanupObservation(scheduledCount: count, allActualApplicationsCompleted: complete,
                                     deferredManualBatchExposed: deferredManualBatchExposed,
                                     handoffs: handoffs.read(), actualTaskCount: ledger.actualTaskCount)
    }
    func cleanup() async -> [Error] {
        gates.forEach { $0.open() }
        var failures: [Error] = []
        // Each accepted fixture offer creates at most one reset. Snapshot each await set BEFORE its performers run.
        for _ in 0..<(offers + 1) {
            let batch = scheduler.claimCleanupBatch()
            batch.manualToPerform.forEach { scheduler.performOnce($0) }
            // Deliberately expose the next actual manual reset before reaping this captured batch.
            do { try await checkpoint() } catch { failures.append(error) }
            if scheduler.pendingCount > 0 { deferredManualBatchExposed = true }
            failures.append(contentsOf: await scheduler.reapActualWork(batch))
            // Submitted outer producers may have performed while being joined; expose their real consumer now.
            do { try await checkpoint() } catch { failures.append(error) }
            failures.append(contentsOf: await ledger.reap())
        }
        let finalBatch = scheduler.claimCleanupBatch()
        finalBatch.manualToPerform.forEach { scheduler.performOnce($0) }
        do { try await checkpoint() } catch { failures.append(error) }
        failures.append(contentsOf: await scheduler.reapActualWork(finalBatch))
        do { try await checkpoint() } catch { failures.append(error) }
        failures.append(contentsOf: await ledger.reap())
        if scheduler.pendingCount != 0 { failures.append(AckTestError("Actual fixture scheduled items remain pending")) }
        let (_, allApplicationsCompleted) = scheduler.cleanupWorkObservation()
        if !allApplicationsCompleted { failures.append(AckTestError("Known original scheduled work or outer producer has not completed")) }
        if !errors.read().isEmpty { failures.append(AckTestError(errors.read().joined(separator: "; "))) }
        let provenance = owner.provenanceSnapshot()
        if !provenance.debts.isEmpty || provenance.unconfirmedHandleCount != 0 || !provenance.waiters.isEmpty {
            failures.append(AckTestError("Unexpected original Owner registration debt"))
        }
        savedCleanupObservation = cleanupObservation()
        if allApplicationsCompleted && scheduler.pendingCount == 0 {
            scheduler.retireCompletedWork()
            ledger.retireReapedRows()
        }
        pacer = nil
        return failures
    }
}

@MainActor
private func ackEventually(_ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        if Date() >= deadline { throw AckTestError("Owned work exceeded five-second guard") }
        await Task.yield()
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

@MainActor
private func ackCompletion(_ item: DispatchWorkItem) async {
    await withCheckedContinuation { continuation in
        item.notify(queue: DispatchQueue.global(qos: .utility)) { continuation.resume() }
    }
}

@MainActor
private func ackCheckpoint(_ queue: DispatchQueue) async throws {
    let finished = AckBox(false)
    let item = DispatchWorkItem {}
    item.notify(queue: DispatchQueue.global(qos: .utility)) { finished.update { $0 = true } }
    queue.async(execute: item)
    var guardFailure: Error?
    do { try await ackEventually { finished.read() } } catch { guardFailure = error }
    await ackCompletion(item)
    if let guardFailure { throw guardFailure }
}

@MainActor
private func withAckFixture(cleanupObservation: AckBox<AckCleanupObservation?>? = nil,
                            _ body: (AckFixture) async throws -> (@MainActor () -> Void)) async throws {
    let fixture = AckFixture()
    var primary: Error?
    var saved: (@MainActor () -> Void)?
    do { saved = try await body(fixture) } catch { primary = error }
    let cleanup = await fixture.cleanup()
    let observedCleanup = fixture.cleanupObservation()
    cleanupObservation?.update { $0 = observedCleanup }
    if let primary {
        if !cleanup.isEmpty { throw AckCleanupError(primary: primary, independent: cleanup) }
        throw primary
    }
    if let first = cleanup.first { throw AckCleanupError(primary: first, independent: Array(cleanup.dropFirst())) }
    guard let saved else { throw AckTestError("No saved postconditions") }
    saved()
}
