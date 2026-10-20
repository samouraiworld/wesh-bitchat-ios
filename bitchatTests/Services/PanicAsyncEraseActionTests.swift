import Foundation
import Darwin
import Testing
@testable import bitchat

actor PanicSpineGate {
    private var open: Bool
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(open: Bool = false) { self.open = open }
    func wait() async {
        arrivals += 1
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func hasEntered() -> Bool { arrivals > 0 }
    func release() {
        open = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

final class PanicSpineThreadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var open = false
    private var entered = false
    func enterAndWait() {
        condition.lock()
        entered = true
        while !open { condition.wait() }
        condition.unlock()
    }
    func hasEntered() -> Bool {
        condition.lock(); defer { condition.unlock() }
        return entered
    }
    func release() {
        condition.lock(); open = true; condition.broadcast(); condition.unlock()
    }
}

final class PanicSpineTasks: @unchecked Sendable {
    struct Entry { let id: UUID; let handle: Task<Void, Never> }
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var ended = Set<UUID>()
    private var failures: [Error] = []
    private var waiterInstalls = 0
    func append(_ id: UUID, _ handle: Task<Void, Never>) {
        lock.lock(); entries.append(Entry(id: id, handle: handle)); lock.unlock()
    }
    func finish(_ id: UUID) { lock.lock(); ended.insert(id); lock.unlock() }
    func completed(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return ended.contains(id) }
    func snapshot() -> [Entry] { lock.lock(); defer { lock.unlock() }; return entries }
    func fail(_ error: Error) { lock.lock(); failures.append(error); lock.unlock() }
    func errors() -> [Error] { lock.lock(); defer { lock.unlock() }; return failures }
    func installedWaiter() { lock.lock(); waiterInstalls += 1; lock.unlock() }
    func installationCount() -> Int { lock.lock(); defer { lock.unlock() }; return waiterInstalls }
}

final class PanicSpineWorker: @unchecked Sendable {
    private let lock = NSLock()
    private let body: @Sendable () -> Void
    private var returned = false
    private var thread: pthread_t?
    init(body: @escaping @Sendable () -> Void) throws {
        self.body = body
        let retained = Unmanaged.passRetained(self).toOpaque()
        let code = pthread_create(&thread, nil, { pointer in
            let worker = Unmanaged<PanicSpineWorker>.fromOpaque(pointer).takeRetainedValue()
            worker.body()
            worker.lock.lock(); worker.returned = true; worker.lock.unlock()
            return nil
        }, retained)
        if code != 0 {
            Unmanaged<PanicSpineWorker>.fromOpaque(retained).release()
            throw PanicSpineFailure.messages(["pthread_create returned \(code)"])
        }
    }
    func hasReturned() -> Bool { lock.lock(); defer { lock.unlock() }; return returned }
    func reap() throws {
        guard let thread else { return }
        let code = pthread_join(thread, nil)
        self.thread = nil
        if code != 0 { throw PanicSpineFailure.messages(["pthread_join returned \(code)"]) }
    }
}

enum PanicSpineFailure: Error { case messages([String]) }
struct PanicSpineCleanupFailure: Error, CustomStringConvertible {
    let primary: Error
    let secondary: [Error]
    var description: String {
        "Primary: \(String(describing: primary)); secondary: \(secondary.map { String(describing: $0) })"
    }
}

@MainActor
final class PanicSpineFixture {
    let tasks = PanicSpineTasks()
    private var gates: [PanicSpineGate] = []
    private var threadGates: [PanicSpineThreadGate] = []
    private var workers: [PanicSpineWorker] = []

    func gate(open: Bool = false) -> PanicSpineGate {
        let gate = PanicSpineGate(open: open); gates.append(gate); return gate
    }
    func threadGate() -> PanicSpineThreadGate {
        let gate = PanicSpineThreadGate(); threadGates.append(gate); return gate
    }
    func owner(tail: PanicSpineGate, lateReturn: PanicSpineThreadGate? = nil) -> NostrOutboundOwner {
        let ledger = tasks
        return NostrOutboundOwner(taskCreator: { operation in
            let id = UUID()
            let handle = Task { @MainActor in
                operation()
                await tail.wait()
                ledger.finish(id)
            }
            ledger.append(id, handle)
            lateReturn?.enterAndWait()
            return handle
        }, waiterInstaller: { install in
            ledger.installedWaiter()
            NostrOutboundOwner.inlineWaiterInstaller(install)
        })
    }
    func command(erase: PanicEraseCommand.Erase?, begin: @escaping () -> Void = {},
                 needsBootstrap: @escaping () -> Bool = { false }, bootstrap: @escaping () -> Void = {},
                 needsRuntimeStart: @escaping () -> Bool = { false }, start: @escaping () -> Void = {}) -> PanicEraseCommand {
        let ledger = tasks
        return PanicEraseCommand(begin: { begin(); return erase }, creator: { work in
            let id = UUID()
            let handle = PanicEraseCommand.mainActorCreator {
                await work()
                ledger.finish(id)
            }
            ledger.append(id, handle)
            return handle
        }, needsBootstrap: needsBootstrap, bootstrap: bootstrap,
           needsRuntimeStart: needsRuntimeStart, startRuntime: start)
    }
    func task(_ operation: @escaping @MainActor () async throws -> Void) {
        let ledger = tasks
        let id = UUID()
        let handle = Task { @MainActor in
            do { try await operation() } catch { ledger.fail(error) }
            ledger.finish(id)
        }
        ledger.append(id, handle)
    }
    func worker(_ operation: @escaping @Sendable () -> Void) throws {
        workers.append(try PanicSpineWorker(body: operation))
    }
    func waitUntil(observation: @MainActor () -> String = { "" },
                   _ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw PanicSpineFailure.messages(["five-second readiness guard exceeded" + observation()]) }
            await Task.yield()
        }
    }
    func close() async throws {
        var failures: [Error] = []
        // Release every owned gate before waiting on any worker or Task.
        for gate in gates { await gate.release() }
        for gate in threadGates { gate.release() }
        for worker in workers {
            do { try await waitUntil { worker.hasReturned() } }
            catch { failures.append(error) }
            // A guard failure never substitutes for the actual same-thread reap.
            do { try worker.reap() } catch { failures.append(error) }
        }
        for entry in tasks.snapshot() {
            do { try await waitUntil { self.tasks.completed(entry.id) } }
            catch { failures.append(error); entry.handle.cancel() }
            await entry.handle.value
        }
        failures.append(contentsOf: tasks.errors())
        if let first = failures.first { throw PanicSpineCleanupFailure(primary: first, secondary: Array(failures.dropFirst())) }
    }
}

private func panicReadinessObservation(_ site: StaticString, result: Bool?) -> String {
    guard let result else { return "; site=\(site) last=UNOBSERVED" }
    return "; site=\(site) last=COMPLETE result=\(result)"
}

@MainActor
func withPanicSpineFixture(_ body: @MainActor (PanicSpineFixture) async throws -> (@MainActor () throws -> Void)) async throws {
    let fixture = PanicSpineFixture()
    var primary: Error?
    var postcondition: (@MainActor () throws -> Void)?
    do { postcondition = try await body(fixture) } catch { primary = error }
    do { try await fixture.close() }
    catch {
        if let first = primary { throw PanicSpineCleanupFailure(primary: first, secondary: [error]) }
        throw error
    }
    if let primary { throw primary }
    try postcondition?()
}

struct PanicAsyncEraseActionTests {
    @Test @MainActor
    func heldOriginalTaskPreventsResultAndApplicationContinuation() async throws {
        try await withPanicSpineFixture { f in
            let held = f.gate()
            let owner = f.owner(tail: held)
            guard case .reserved(let ticket) = owner.reserveTask(kind: .privateMessage, parent: .root) else {
                throw PanicSpineFailure.messages(["original Task was not admitted"])
            }
            _ = owner.dispatch(ticket) {}
            var lastOriginalTailEntered: Bool?
            try await f.waitUntil(observation: {
                panicReadinessObservation("PANIC_ORIGINAL_TAIL_ENTERED", result: lastOriginalTailEntered)
            }) {
                let result = await held.hasEntered()
                lastOriginalTailEntered = result
                return result
            }
            try #require(owner.provenanceSnapshot().tasks.first?.body == .returned)
            let binding = owner.captureOutboundPanicBinding()
            var close: NostrOutboundOwner.RootCloseOutcome?
            var beginTaskCount: Int?
            var entered = false
            var reports: [Bool] = []
            var continuationCount = 0
            var bootstrapCount = 0
            let command = f.command(erase: {
                entered = true
                guard let close else { throw PanicSpineFailure.messages(["prepared close missing"]) }
                let known = try await awaitCapturedOriginalReturnedTaskBatch(binding, closeOutcome: close)
                guard known.permitsExistingOwnerCheck else { return false }
                continuationCount += 1
                return false // Synthetic downstream refusal; never an all-owner success claim.
            }, begin: {
                beginTaskCount = f.tasks.snapshot().count
                close = closeCapturedNostrOutboundRoots(binding)
            }, needsBootstrap: { true }, bootstrap: { bootstrapCount += 1 })
            guard case .started = command.submit(report: { reports.append($0) }) else {
                throw PanicSpineFailure.messages(["command was not admitted"])
            }
            guard case .closed? = close else { throw PanicSpineFailure.messages(["synchronous original close missing"]) }
            let beginWasSynchronous = beginTaskCount == 1 && f.tasks.snapshot().count == 2
            var lastJoinReadiness: (reported: Bool, installs: Int?, result: Bool)?
            try await f.waitUntil(observation: {
                guard let last = lastJoinReadiness else {
                    return "; site=PANIC_ORIGINAL_JOIN_READINESS last=UNOBSERVED"
                }
                let installs = last.installs.map { String($0) } ?? "UNOBSERVED"
                return "; site=PANIC_ORIGINAL_JOIN_READINESS last=COMPLETE reported=\(last.reported) installs=\(installs) result=\(last.result)"
            }) {
                let reported = !reports.isEmpty
                if reported {
                    lastJoinReadiness = (true, nil, true)
                    return true
                }
                let installs = f.tasks.installationCount()
                let result = installs > 0
                lastJoinReadiness = (false, installs, result)
                return result
            }
            try #require(entered)
            let reportsWhileHeld = reports
            let continuationWhileHeld = continuationCount
            let bootstrapWhileHeld = bootstrapCount
            return {
                try #require(reportsWhileHeld.isEmpty)
                #expect(beginWasSynchronous)
                #expect(continuationWhileHeld == 0)
                #expect(bootstrapWhileHeld == 0)
                #expect(reports == [false])
                #expect(continuationCount == 1 && bootstrapCount == 0)
            }
        }
    }

    @Test @MainActor
    func falseCompletionNeverBootstrapsOrStarts() async throws {
        try await withPanicSpineFixture { f in
            var sequence: [String] = []
            let command = f.command(erase: { sequence.append("erase"); return false }, begin: { sequence.append("begin") },
                needsBootstrap: { sequence.append("query-bootstrap"); return true }, bootstrap: { sequence.append("bootstrap") },
                needsRuntimeStart: { sequence.append("query-start"); return true }, start: { sequence.append("start") })
            let submission = command.submit { sequence.append("report:\($0)") }
            try await f.waitUntil { !command.isRunning }
            let observed = sequence
            let phase = command.phase
            return {
                guard case .started(let attempt) = submission, case .finished(let completedAttempt, let result) = phase else {
                    Issue.record("Actual command phase did not finish"); return
                }
                #expect(attempt == completedAttempt && !result)
                #expect(observed == ["begin", "erase", "report:false"])
            }
        }
    }

    @Test @MainActor
    func cancelledAttemptKeepsRecoveryPendingAndDoesNotRunFinish() async throws {
        try await withPanicSpineFixture { f in
            let held = f.gate()
            var pending = false
            var finishCount = 0
            var cleanupCount = 0
            var reports: [Bool] = []
            let command = f.command(erase: {
                defer { cleanupCount += 1 }
                await held.wait()
                try Task.checkCancellation()
                pending = false
                finishCount += 1
                return true
            }, begin: { pending = true })
            _ = command.submit { reports.append($0) }
            var lastCancelledTailEntered: Bool?
            try await f.waitUntil(observation: {
                panicReadinessObservation("PANIC_CANCEL_TAIL_ENTERED", result: lastCancelledTailEntered)
            }) {
                let result = await held.hasEntered()
                lastCancelledTailEntered = result
                return result
            }
            let handle = try #require(f.tasks.snapshot().last?.handle)
            handle.cancel()
            let beforeRelease = (pending, finishCount, reports)
            var earlyPending = false
            var earlyCleanupCount = 0
            var earlyFinishCount = 0
            var earlyReports: [Bool] = []
            let early = f.command(erase: {
                defer { earlyCleanupCount += 1 }
                try Task.checkCancellation()
                earlyFinishCount += 1
                return true
            }, begin: { earlyPending = true })
            _ = early.submit { earlyReports.append($0) }
            let earlyHandle = try #require(f.tasks.snapshot().last?.handle)
            earlyHandle.cancel() // Same MainActor turn: cancel before its Task body can start.
            var lastEarlyFinished: Bool?
            try await f.waitUntil(observation: {
                panicReadinessObservation("PANIC_EARLY_COMMAND_FINISHED", result: lastEarlyFinished)
            }) {
                let result = !early.isRunning
                lastEarlyFinished = result
                return result
            }
            let earlyObserved = (earlyPending, earlyCleanupCount, earlyFinishCount, earlyReports)
            return {
                #expect(beforeRelease.0 && beforeRelease.1 == 0 && beforeRelease.2.isEmpty)
                #expect(pending && finishCount == 0 && cleanupCount == 1)
                #expect(reports == [false])
                #expect(earlyObserved.0 && earlyObserved.1 == 1 && earlyObserved.2 == 0 && earlyObserved.3 == [false])
            }
        }
    }

    @Test @MainActor
    func secondSubmissionWhilePendingDoesNotBeginAnotherTransaction() async throws {
        try await withPanicSpineFixture { f in
            let held = f.gate()
            var begins = 0
            var reports = 0
            weak var commandReference: PanicEraseCommand?
            var duringBegin: PanicEraseCommand.Submission?
            var tasksDuringBegin: Int?
            let command = f.command(erase: { await held.wait(); return false }, begin: {
                begins += 1
                tasksDuringBegin = f.tasks.snapshot().count
                duringBegin = commandReference?.submit { _ in reports += 1000 }
            })
            commandReference = command
            let first = command.submit { _ in reports += 1 }
            let immediateBeginCount = begins
            var lastPendingTailEntered: Bool?
            try await f.waitUntil(observation: {
                panicReadinessObservation("PANIC_BUSY_TAIL_ENTERED", result: lastPendingTailEntered)
            }) {
                let result = await held.hasEntered()
                lastPendingTailEntered = result
                return result
            }
            let second = command.submit { _ in reports += 100 }
            let beforeRelease = (begins, reports)
            return {
                guard case .started(let original) = first, case .busy(let pending) = second else {
                    Issue.record("Expected actual pending command refusal"); return
                }
                guard case .busy(let reentrant)? = duringBegin else { Issue.record("Begin reentry was admitted"); return }
                #expect(original == pending && original == reentrant)
                #expect(immediateBeginCount == 1 && tasksDuringBegin == 0)
                #expect(beforeRelease.0 == 1 && beforeRelease.1 == 0)
                #expect(begins == 1 && reports == 1)
            }
        }
    }

    @Test @MainActor
    func missingOriginalRuntimeFailsClosedWithoutGraphConstruction() async throws {
        try await withPanicSpineFixture { f in
            var effects = 0
            var reports: [Bool] = []
            let command = f.command(erase: nil, needsBootstrap: { effects += 1; return true }, bootstrap: { effects += 1 },
                needsRuntimeStart: { effects += 1; return true }, start: { effects += 1 })
            let result = command.submit { reports.append($0) }
            let taskCount = f.tasks.snapshot().count
            return {
                guard case .unavailable = result else { Issue.record("Missing original runtime was admitted"); return }
                #expect(effects == 0 && taskCount == 0)
                #expect(reports == [false] && !command.isRunning)
            }
        }
    }

    @Test @MainActor
    func actualCompletionReportsOnceAndActivatesOnlyAfterSuccessfulFinish() async throws {
        try await withPanicSpineFixture { f in
            var sequence: [String] = []
            let command = f.command(erase: { sequence.append("finish"); return true }, begin: { sequence.append("begin") },
                needsBootstrap: { sequence.append("query-bootstrap"); return true }, bootstrap: { sequence.append("bootstrap") },
                needsRuntimeStart: { sequence.append("query-start"); return true }, start: { sequence.append("start") })
            _ = command.submit { sequence.append("report:\($0)") }
            try await f.waitUntil { !command.isRunning }
            let observed = sequence
            return { #expect(observed == ["begin", "finish", "report:true", "query-bootstrap", "bootstrap", "query-start", "start"]) }
        }
    }
}
