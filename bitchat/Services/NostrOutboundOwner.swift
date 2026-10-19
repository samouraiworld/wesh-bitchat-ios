import Foundation

/// Original outbound provenance. Task-batch joins never acknowledge the whole outbound owner.
final class NostrOutboundOwner: @unchecked Sendable {
    typealias Operation = @MainActor @Sendable () -> Void
    typealias TaskCreator = @Sendable (@escaping Operation) -> Task<Void, Never>
    typealias WaiterInstaller = @Sendable (@escaping @Sendable () -> Void) -> Void

    static let mainActorTaskCreator: TaskCreator = { operation in
        Task { @MainActor in operation() }
    }
    static let inlineWaiterInstaller: WaiterInstaller = { install in install() }
    static let originalProcess = NostrOutboundOwner(
        taskCreator: mainActorTaskCreator, waiterInstaller: inlineWaiterInstaller
    )

    final class Identity: Hashable, @unchecked Sendable {
        fileprivate init() {}
        static func == (lhs: Identity, rhs: Identity) -> Bool { lhs === rhs }
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    }
    final class RootPanicSubject: @unchecked Sendable {
        let ownerID: Identity
        fileprivate let nonce: Identity
        fileprivate init(ownerID: Identity, nonce: Identity) { self.ownerID = ownerID; self.nonce = nonce }
    }
    final class RootCloseReceipt: @unchecked Sendable {
        let ownerID: Identity
        let eventID: Identity
        fileprivate init(ownerID: Identity, eventID: Identity) { self.ownerID = ownerID; self.eventID = eventID }
    }
    enum RootCloseGap: Equatable, Sendable { case foreignSubject, participantMissing }
    enum RootCloseOutcome: Sendable { case closed(RootCloseReceipt), unconfirmed(RootCloseGap) }

    class Ticket: @unchecked Sendable {
        let ownerID: Identity
        let id: Identity
        fileprivate init(ownerID: Identity) { self.ownerID = ownerID; self.id = Identity() }
    }
    final class TaskTicket: Ticket, @unchecked Sendable {}
    final class CallbackTicket: Ticket, @unchecked Sendable {}
    enum Parent: Sendable { case root, child(Ticket) }
    enum TaskKind: Equatable, Sendable {
        case refreshReachablePeers, privateMessage, favoriteNotification, explicitIdentityMessage, ackItem
    }
    enum CallbackKind: Equatable, Sendable { case ackQueueAppend, pendingAckHandoff, ackResetScheduler, ackResetQueue, refreshStateWrite }
    enum BodyState: Equatable, Sendable { case notEntered, entered, returned }
    enum RegistrationState: Equatable, Sendable { case reservedAwaitingHandle, handleRegistered, supervisorJoined, unknownProtocolDebt }
    enum CallbackState: Equatable, Sendable { case reserved, entered, bodyReturned }
    enum WaiterState: Equatable, Sendable { case prepared, boundPendingInstall, cancelRequestedPendingInstall, waitingForHandle, delivered, cancelledDischarged }
    enum ProtocolFault: Equatable, Sendable { case foreignOwner, invalidParent, replayedSubmission, duplicateInstallation, unknownHandleRegistration }
    enum Reservation<T> { case reserved(T), protocolDebt(Identity), refusedBeforeRoot(RootCloseReceipt) }
    enum Submission { case handleRegistered(Identity), protocolDebt(Identity) }
    enum ReceiptUpdate { case recorded, protocolDebt(Identity) }
    enum JoinError: Error { case foreignBatch, protocolDebt }

    struct TaskRow: Sendable {
        let id: Identity
        let parent: Identity?
        let kind: TaskKind
        let registration: RegistrationState
        let body: BodyState
    }
    struct CallbackRow: Sendable {
        let id: Identity
        let parent: Identity?
        let kind: CallbackKind
        let state: CallbackState
    }
    struct WaiterRow: Sendable {
        let id: Identity
        let taskID: Identity
        let state: WaiterState
    }
    struct DebtRow: Sendable { let id: Identity; let workID: Identity?; let fault: ProtocolFault }
    struct Snapshot: Sendable {
        let ownerID: Identity
        let tasks: [TaskRow]
        let callbacks: [CallbackRow]
        let waiters: [WaiterRow]
        let debts: [DebtRow]
        let unconfirmedHandleCount: Int
    }
    final class TaskBatch: @unchecked Sendable {
        let ownerID: Identity
        let id = Identity()
        let taskIDs: [Identity]
        fileprivate init(ownerID: Identity, taskIDs: [Identity]) { self.ownerID = ownerID; self.taskIDs = taskIDs }
    }
    struct JoinedTaskBatch: Sendable {
        let ownerID: Identity
        let batchID: Identity
        let taskIDs: [Identity]
        fileprivate init(ownerID: Identity, batchID: Identity, taskIDs: [Identity]) {
            self.ownerID = ownerID; self.batchID = batchID; self.taskIDs = taskIDs
        }
    }

    private enum Kind { case task(TaskKind), callback(CallbackKind) }
    private final class Record {
        let ticket: Ticket
        let parent: Identity?
        let kind: Kind
        var dispatched = false
        var handle: Task<Void, Never>?
        var joined = false
        var failedProtocol = false
        var body: BodyState = .notEntered
        var callback: CallbackState = .reserved
        var waiters: [Identity] = []
        init(ticket: Ticket, parent: Identity?, kind: Kind) { self.ticket = ticket; self.parent = parent; self.kind = kind }
    }
    private final class Waiter: @unchecked Sendable {
        let id = Identity()
        let taskID: Identity
        var state: WaiterState = .prepared
        var continuation: CheckedContinuation<Task<Void, Never>, Error>?
        var cancelled = false
        var installed = false
        init(taskID: Identity) { self.taskID = taskID }
    }
    private struct Resume {
        let continuation: CheckedContinuation<Task<Void, Never>, Error>
        let result: Result<Task<Void, Never>, Error>
        func run() { continuation.resume(with: result) }
    }

    let id: Identity
    private let originalRootSubject: RootPanicSubject
    private var rootCloseReceipt: RootCloseReceipt?
    private let mutex = NSLock()
    private let taskCreator: TaskCreator
    private let waiterInstaller: WaiterInstaller
    private var order: [Identity] = []
    private var records: [Identity: Record] = [:]
    private var pendingWaiters: [Identity: Waiter] = [:]
    private var debts: [DebtRow] = []
    private var unconfirmedHandles: [Task<Void, Never>] = []

    init(taskCreator: @escaping TaskCreator, waiterInstaller: @escaping WaiterInstaller) {
        let id = Identity()
        self.id = id
        self.originalRootSubject = RootPanicSubject(ownerID: id, nonce: Identity())
        self.taskCreator = taskCreator
        self.waiterInstaller = waiterInstaller
    }

    /// Capture this installed actor's original subject, never a current/global successor.
    func captureOutboundPanicBinding() -> NostrOutboundPanicBinding {
        NostrOutboundPanicBinding(owner: self, subject: originalRootSubject)
    }

    /// Terminal root admission event only; accepted work and all drain evidence remain separate.
    func closeRootAdmission(subject: RootPanicSubject) -> RootCloseOutcome {
        locked {
            guard subject.ownerID === id, subject.nonce === originalRootSubject.nonce else {
                return .unconfirmed(.foreignSubject)
            }
            if let rootCloseReceipt { return .closed(rootCloseReceipt) }
            let receipt = RootCloseReceipt(ownerID: id, eventID: Identity())
            rootCloseReceipt = receipt
            return .closed(receipt)
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        mutex.lock()
        defer { mutex.unlock() }
        return try body()
    }
    // Metadata helpers below run only under mutex. No external action or continuation resumes there.
    private func debt(_ fault: ProtocolFault, workID: Identity?) -> Identity {
        let row = DebtRow(id: Identity(), workID: workID, fault: fault)
        debts.append(row)
        if let workID, let record = records[workID] { record.failedProtocol = true }
        return row.id
    }
    private func valid(_ parent: Parent) -> Bool {
        switch parent {
        case .root: return true
        case .child(let ticket): return ticket.ownerID === id && records[ticket.id]?.ticket === ticket
        }
    }
    private func parentID(_ parent: Parent) -> Identity? {
        if case .child(let ticket) = parent { return ticket.id }
        return nil
    }

    func reserveTask(kind: TaskKind, parent: Parent) -> Reservation<TaskTicket> {
        locked {
            guard valid(parent) else { return .protocolDebt(debt(.invalidParent, workID: nil)) }
            let ticket = TaskTicket(ownerID: id)
            order.append(ticket.id)
            records[ticket.id] = Record(ticket: ticket, parent: parentID(parent), kind: .task(kind))
            return .reserved(ticket)
        }
    }
    func reserveCallback(kind: CallbackKind, parent: Parent) -> Reservation<CallbackTicket> {
        locked {
            guard valid(parent) else { return .protocolDebt(debt(.invalidParent, workID: nil)) }
            let ticket = CallbackTicket(ownerID: id)
            order.append(ticket.id)
            records[ticket.id] = Record(ticket: ticket, parent: parentID(parent), kind: .callback(kind))
            return .reserved(ticket)
        }
    }

    @discardableResult
    func dispatch(_ ticket: TaskTicket, operation: @escaping Operation) -> Submission {
        let fault: Identity? = locked {
            guard ticket.ownerID === id, let record = records[ticket.id], record.ticket === ticket else {
                return debt(.foreignOwner, workID: nil)
            }
            guard !record.dispatched else { return debt(.replayedSubmission, workID: ticket.id) }
            record.dispatched = true
            return nil
        }
        if let fault { return .protocolDebt(fault) }
        // The creator can run/finish the real task before returning this exact handle.
        let handle = taskCreator { [self] in
            noteBody(ticket, .entered)
            defer { noteBody(ticket, .returned) }
            operation()
        }
        let registration: (resumes: [Resume], fault: Identity?) = locked {
            guard let record = records[ticket.id], record.ticket === ticket, record.handle == nil else {
                unconfirmedHandles.append(handle)
                return ([], debt(.unknownHandleRegistration, workID: ticket.id))
            }
            record.handle = handle
            let ready = record.waiters.compactMap { pendingWaiters[$0] }
            record.waiters.removeAll()
            return (ready.compactMap { waiter in
                consume(waiter, result: record.failedProtocol ? .failure(JoinError.protocolDebt) : .success(handle))
            }, nil)
        }
        registration.resumes.forEach { $0.run() }
        if let fault = registration.fault { return .protocolDebt(fault) }
        return .handleRegistered(ticket.id)
    }
    private func noteBody(_ ticket: TaskTicket, _ state: BodyState) {
        locked { records[ticket.id]?.body = state }
    }

    @discardableResult
    func callbackEntered(_ ticket: CallbackTicket) -> ReceiptUpdate {
        locked {
            guard ticket.ownerID === id, let record = records[ticket.id], record.ticket === ticket else {
                return .protocolDebt(debt(.foreignOwner, workID: nil))
            }
            guard record.callback == .reserved else { return .protocolDebt(debt(.replayedSubmission, workID: ticket.id)) }
            record.callback = .entered
            return .recorded
        }
    }
    @discardableResult
    func callbackBodyReturned(_ ticket: CallbackTicket) -> ReceiptUpdate {
        locked {
            guard ticket.ownerID === id, let record = records[ticket.id], record.ticket === ticket else {
                return .protocolDebt(debt(.foreignOwner, workID: nil))
            }
            guard record.callback == .entered else { return .protocolDebt(debt(.replayedSubmission, workID: ticket.id)) }
            record.callback = .bodyReturned
            return .recorded
        }
    }

    /// Captured task IDs only; pending callbacks can still admit children after this snapshot.
    func taskBatchSnapshot() -> TaskBatch {
        locked { TaskBatch(ownerID: id, taskIDs: order.filter { records[$0]?.ticket is TaskTicket }) }
    }
    func joinTaskBatch(_ batch: TaskBatch) async throws -> JoinedTaskBatch {
        try locked {
            guard batch.ownerID === id else { _ = debt(.foreignOwner, workID: nil); throw JoinError.foreignBatch }
            guard debts.isEmpty else { throw JoinError.protocolDebt }
        }
        for taskID in batch.taskIDs {
            try Task.checkCancellation()
            let handle = try await registeredHandle(taskID)
            try Task.checkCancellation()
            await handle.value
            try Task.checkCancellation()
            try locked {
                guard debts.isEmpty, let record = records[taskID], record.handle != nil else { throw JoinError.protocolDebt }
                record.joined = true
            }
        }
        try Task.checkCancellation()
        return try locked {
            guard debts.isEmpty else { throw JoinError.protocolDebt }
            return JoinedTaskBatch(ownerID: id, batchID: batch.id, taskIDs: batch.taskIDs)
        }
    }

    private func registeredHandle(_ taskID: Identity) async throws -> Task<Void, Never> {
        let waiter = locked { () -> Waiter in
            let waiter = Waiter(taskID: taskID)
            pendingWaiters[waiter.id] = waiter
            return waiter
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                locked {
                    waiter.continuation = continuation
                    waiter.state = waiter.cancelled ? .cancelRequestedPendingInstall : .boundPendingInstall
                }
                waiterInstaller { [self] in install(waiter) }
            }
        } onCancel: { [self] in cancel(waiter) }
    }
    private func install(_ waiter: Waiter) {
        let resume: Resume? = locked {
            guard !waiter.installed else {
                _ = debt(.duplicateInstallation, workID: waiter.taskID)
                return nil
            }
            waiter.installed = true
            if waiter.cancelled { return consume(waiter, result: .failure(CancellationError())) }
            guard let record = records[waiter.taskID], !record.failedProtocol else {
                return consume(waiter, result: .failure(JoinError.protocolDebt))
            }
            if let handle = record.handle { return consume(waiter, result: .success(handle)) }
            waiter.state = .waitingForHandle
            record.waiters.append(waiter.id)
            return nil
        }
        resume?.run()
    }
    private func cancel(_ waiter: Waiter) {
        let resume: Resume? = locked {
            waiter.cancelled = true
            switch waiter.state {
            case .prepared, .boundPendingInstall, .cancelRequestedPendingInstall:
                // Keep the real continuation until the held installer action is actually invoked.
                waiter.state = .cancelRequestedPendingInstall
                return nil
            case .waitingForHandle:
                records[waiter.taskID]?.waiters.removeAll { $0 === waiter.id }
                return consume(waiter, result: .failure(CancellationError()))
            case .delivered, .cancelledDischarged: return nil
            }
        }
        resume?.run()
    }
    private func consume(_ waiter: Waiter, result: Result<Task<Void, Never>, Error>) -> Resume? {
        guard let continuation = waiter.continuation else { return nil }
        waiter.continuation = nil
        switch result {
        case .success: waiter.state = .delivered
        case .failure: waiter.state = .cancelledDischarged
        }
        pendingWaiters.removeValue(forKey: waiter.id)
        return Resume(continuation: continuation, result: result)
    }

    /// Typed provenance, not a quiescence check. Retained records/copies have no qualified bound.
    func provenanceSnapshot() -> Snapshot {
        locked {
            var tasks: [TaskRow] = []
            var callbacks: [CallbackRow] = []
            for key in order {
                guard let record = records[key] else { continue }
                switch record.kind {
                case .task(let kind):
                    let state: RegistrationState = record.failedProtocol ? .unknownProtocolDebt :
                        (record.joined ? .supervisorJoined : (record.handle == nil ? .reservedAwaitingHandle : .handleRegistered))
                    tasks.append(TaskRow(id: key, parent: record.parent, kind: kind, registration: state, body: record.body))
                case .callback(let kind):
                    callbacks.append(CallbackRow(id: key, parent: record.parent, kind: kind, state: record.callback))
                }
            }
            return Snapshot(ownerID: id, tasks: tasks, callbacks: callbacks,
                waiters: pendingWaiters.values.map { WaiterRow(id: $0.id, taskID: $0.taskID, state: $0.state) },
                debts: debts, unconfirmedHandleCount: unconfirmedHandles.count)
        }
    }
}

/// Immutable binding to the owner actually installed by the transport. No transport or key payload.
final class NostrOutboundPanicBinding: @unchecked Sendable {
    let ownerID: NostrOutboundOwner.Identity
    let subject: NostrOutboundOwner.RootPanicSubject
    fileprivate let owner: NostrOutboundOwner
    fileprivate init(owner: NostrOutboundOwner, subject: NostrOutboundOwner.RootPanicSubject) {
        self.owner = owner; self.ownerID = owner.id; self.subject = subject
    }
}

func closeCapturedNostrOutboundRoots(_ binding: NostrOutboundPanicBinding) -> NostrOutboundOwner.RootCloseOutcome {
    binding.owner.closeRootAdmission(subject: binding.subject)
}
