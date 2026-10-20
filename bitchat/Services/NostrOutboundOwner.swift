import Foundation
import Combine

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

    final class SourceInstallation: @unchecked Sendable {
        let ownerID: Identity
        let id = Identity()
        fileprivate init(ownerID: Identity) { self.ownerID = ownerID }
    }
    enum SourceInstallationAdmission {
        case accepted(SourceInstallation), refusedBeforeRoot(RootCloseReceipt)
    }
    enum SourceAdmissionDecision: Equatable, Sendable { case accepted, refusedBeforeRoot }
    struct SourceInstallationAdmissionRow: Sendable {
        let ownerID: Identity
        let requestID: Identity
        let kind: SourceKind
        let sourceID: Identity?
        let decision: SourceAdmissionDecision
        let closeReceipt: RootCloseReceipt?
    }
    struct SourceInstallationAdmissionSnapshot: Sendable {
        let ownerID: Identity
        let rows: [SourceInstallationAdmissionRow]
    }
    enum ColdProviderPurpose: Equatable, Sendable { case legacyFavoritesWarm }
    enum ColdProviderState: Equatable, Sendable { case inFlight, returned }
    final class ColdProviderPermission: @unchecked Sendable {
        let ownerID: Identity
        let id = Identity()
        let purpose: ColdProviderPurpose
        fileprivate init(ownerID: Identity, purpose: ColdProviderPurpose) {
            self.ownerID = ownerID; self.purpose = purpose
        }
    }
    enum ColdProviderAdmission {
        case accepted(ColdProviderPermission), refusedBeforeRoot(RootCloseReceipt)
    }
    struct ColdProviderRow: Sendable {
        let ownerID: Identity
        let requestID: Identity
        let purpose: ColdProviderPurpose
        let permissionID: Identity?
        let state: ColdProviderState?
        let decision: SourceAdmissionDecision
        let closeReceipt: RootCloseReceipt?
    }
    struct ColdProviderSnapshot: Sendable {
        let ownerID: Identity
        let rows: [ColdProviderRow]
    }
    final class SourceEventTicket: @unchecked Sendable {
        let ownerID: Identity
        let sourceID: Identity
        let id = Identity()
        fileprivate init(ownerID: Identity, sourceID: Identity) { self.ownerID = ownerID; self.sourceID = sourceID }
    }
    final class SourceWriteTicket: @unchecked Sendable {
        let ownerID: Identity
        let sourceID: Identity
        let eventID: Identity
        let id = Identity()
        fileprivate init(ownerID: Identity, parent: SourceEventTicket) {
            self.ownerID = ownerID; self.sourceID = parent.sourceID; self.eventID = parent.id
        }
    }
    /// The capability is distinct from every identity exposed by inspection.
    final class SourceEventBodyPermit: @unchecked Sendable {
        let ownerID: Identity
        let sourceID: Identity
        let eventID: Identity
        let id = Identity()
        let kind: SourceKind
        fileprivate init(ownerID: Identity, event: SourceEventTicket, kind: SourceKind) {
            self.ownerID = ownerID; self.sourceID = event.sourceID; self.eventID = event.id; self.kind = kind
        }
    }
    enum SourceBodyAdmission {
        case accepted(SourceEventBodyPermit), refusedBeforeRoot(RootCloseReceipt), protocolFault
    }
    enum AdmittedSourceWriteReservation { case reserved(SourceWriteTicket), protocolFault }
    enum SourceBodyDecision: Equatable, Sendable { case accepted, refusedBeforeRoot }
    struct SourceBodyAdmissionRow: Sendable {
        let ownerID: Identity
        let sourceID: Identity
        let eventID: Identity
        let permitID: Identity?
        let decision: SourceBodyDecision
        let writeID: Identity?
        let closeReceipt: RootCloseReceipt?
    }
    struct SourceBodyAdmissionSnapshot: Sendable {
        let ownerID: Identity
        let rows: [SourceBodyAdmissionRow]
    }
    enum SourceKind: Equatable, Sendable {
        case weshRecipients, weshOnline, weshRelayConnectivity, legacyFavoriteObserver, legacyRelayConnectivity
    }
    enum SourceWriteKind: Equatable, Sendable { case weshRecipientsState, weshOnlineState, weshRelayState, legacyRelayState }
    enum SourceInstallationState: Equatable, Sendable { case installing, installationReturned }
    enum SourceEventState: Equatable, Sendable { case entered, bodyEndRecorded }
    enum SourceWriteState: Equatable, Sendable { case reserved, entered, bodyEndRecorded }
    enum SourceProtocolFault: Equatable, Sendable {
        case foreignSource, unknownSource, repeatedInstallationReturn, invalidEvent, repeatedBodyEnd, invalidWrite, invalidExistingTask
        case invalidBodyAdmission, repeatedBodyAdmission, invalidBodyPermit, invalidBodyWriteKind, repeatedBodyWrite
        case invalidColdProviderPermission, repeatedColdProviderReturn
    }
    enum SourceReceiptUpdate { case recorded, protocolFault }
    struct SourceRow: Sendable { let id: Identity; let kind: SourceKind; let installation: SourceInstallationState }
    struct SourceEventRow: Sendable { let id: Identity; let sourceID: Identity; let state: SourceEventState }
    struct SourceWriteRow: Sendable {
        let id: Identity; let sourceID: Identity; let eventID: Identity; let kind: SourceWriteKind; let state: SourceWriteState
    }
    struct SourceTaskEdge: Sendable { let sourceID: Identity; let eventID: Identity; let taskID: Identity }
    struct SourceLedgerSnapshot: Sendable {
        let ownerID: Identity
        let sources: [SourceRow]
        let events: [SourceEventRow]
        let writes: [SourceWriteRow]
        let taskEdges: [SourceTaskEdge]
        let faults: [SourceProtocolFault]
    }

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

    private final class SourceRecord {
        let ticket: SourceInstallation
        let kind: SourceKind
        var installation: SourceInstallationState = .installing
        init(ticket: SourceInstallation, kind: SourceKind) { self.ticket = ticket; self.kind = kind }
    }
    private final class ColdProviderRecord {
        let requestID: Identity
        let purpose: ColdProviderPurpose
        let decision: SourceAdmissionDecision
        let permission: ColdProviderPermission?
        let closeReceipt: RootCloseReceipt?
        var state: ColdProviderState?
        init(requestID: Identity, purpose: ColdProviderPurpose, decision: SourceAdmissionDecision,
             permission: ColdProviderPermission?, closeReceipt: RootCloseReceipt?) {
            self.requestID = requestID; self.purpose = purpose; self.decision = decision
            self.permission = permission; self.closeReceipt = closeReceipt
            self.state = permission == nil ? nil : .inFlight
        }
    }
    private final class SourceEventRecord {
        let ticket: SourceEventTicket
        var state: SourceEventState = .entered
        init(ticket: SourceEventTicket) { self.ticket = ticket }
    }
    private final class SourceWriteRecord {
        let ticket: SourceWriteTicket
        let kind: SourceWriteKind
        var state: SourceWriteState = .reserved
        init(ticket: SourceWriteTicket, kind: SourceWriteKind) { self.ticket = ticket; self.kind = kind }
    }

    private final class SourceBodyAdmissionRecord {
        let ownerID: Identity
        let sourceID: Identity
        let eventID: Identity
        let decision: SourceBodyDecision
        let permit: SourceEventBodyPermit?
        let closeReceipt: RootCloseReceipt?
        var writeID: Identity?
        init(ownerID: Identity, event: SourceEventTicket, decision: SourceBodyDecision,
             permit: SourceEventBodyPermit?, closeReceipt: RootCloseReceipt?) {
            self.ownerID = ownerID; self.sourceID = event.sourceID; self.eventID = event.id
            self.decision = decision; self.permit = permit; self.closeReceipt = closeReceipt
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
    private var installationAdmissions: [SourceInstallationAdmissionRow] = []
    private var coldProviderOrder: [Identity] = []
    private var coldProviders: [Identity: ColdProviderRecord] = [:]
    private var sourceOrder: [Identity] = []
    private var sourceRecords: [Identity: SourceRecord] = [:]
    private var sourceEventOrder: [Identity] = []
    private var sourceEvents: [Identity: SourceEventRecord] = [:]
    private var sourceWriteOrder: [Identity] = []
    private var sourceWrites: [Identity: SourceWriteRecord] = [:]
    private var sourceTaskEdges: [SourceTaskEdge] = []
    private var sourceFaults: [SourceProtocolFault] = []
    private var sourceBodyOrder: [Identity] = []
    private var sourceBodies: [Identity: SourceBodyAdmissionRecord] = [:]

    init(taskCreator: @escaping TaskCreator, waiterInstaller: @escaping WaiterInstaller) {
        let id = Identity()
        self.id = id
        self.originalRootSubject = RootPanicSubject(ownerID: id, nonce: Identity())
        self.taskCreator = taskCreator
        self.waiterInstaller = waiterInstaller
    }

    // Source admission remains separate from existing Task/callback debt and batch semantics.
    func beginSourceInstallation(kind: SourceKind) -> SourceInstallationAdmission {
        locked {
            let requestID = Identity()
            if let rootCloseReceipt {
                installationAdmissions.append(SourceInstallationAdmissionRow(ownerID: id, requestID: requestID,
                    kind: kind, sourceID: nil, decision: .refusedBeforeRoot, closeReceipt: rootCloseReceipt))
                return .refusedBeforeRoot(rootCloseReceipt)
            }
            let ticket = SourceInstallation(ownerID: id)
            sourceOrder.append(ticket.id)
            sourceRecords[ticket.id] = SourceRecord(ticket: ticket, kind: kind)
            installationAdmissions.append(SourceInstallationAdmissionRow(ownerID: id, requestID: requestID,
                kind: kind, sourceID: ticket.id, decision: .accepted, closeReceipt: nil))
            return .accepted(ticket)
        }
    }
    func sourceInstallationAdmissionSnapshot() -> SourceInstallationAdmissionSnapshot {
        locked { SourceInstallationAdmissionSnapshot(ownerID: id, rows: installationAdmissions) }
    }
    func beginColdProvider(purpose: ColdProviderPurpose) -> ColdProviderAdmission {
        locked {
            let requestID = Identity()
            if let rootCloseReceipt {
                coldProviderOrder.append(requestID)
                coldProviders[requestID] = ColdProviderRecord(requestID: requestID, purpose: purpose, decision: .refusedBeforeRoot,
                    permission: nil, closeReceipt: rootCloseReceipt)
                return .refusedBeforeRoot(rootCloseReceipt)
            }
            let permission = ColdProviderPermission(ownerID: id, purpose: purpose)
            coldProviderOrder.append(permission.id)
            coldProviders[permission.id] = ColdProviderRecord(requestID: requestID, purpose: purpose, decision: .accepted,
                permission: permission, closeReceipt: nil)
            return .accepted(permission)
        }
    }
    @discardableResult
    func noteColdProviderReturned(_ permission: ColdProviderPermission) -> SourceReceiptUpdate {
        locked {
            guard permission.ownerID === id,
                  let record = coldProviders[permission.id], record.permission === permission,
                  record.purpose == permission.purpose, record.decision == .accepted else {
                return sourceFault(.invalidColdProviderPermission)
            }
            guard record.state == .inFlight else { return sourceFault(.repeatedColdProviderReturn) }
            record.state = .returned
            return .recorded
        }
    }
    /// Inspection exposes IDs and settlement metadata, never installation or warmup capabilities.
    func coldProviderSnapshot() -> ColdProviderSnapshot {
        locked {
            ColdProviderSnapshot(ownerID: id, rows: coldProviderOrder.compactMap { coldProviders[$0] }.map {
                ColdProviderRow(ownerID: id, requestID: $0.requestID, purpose: $0.purpose,
                    permissionID: $0.permission?.id, state: $0.state, decision: $0.decision, closeReceipt: $0.closeReceipt)
            })
        }
    }
    @discardableResult
    func noteSourceInstallationReturned(_ ticket: SourceInstallation) -> SourceReceiptUpdate {
        locked {
            guard ticket.ownerID === id else { return sourceFault(.foreignSource) }
            guard let record = sourceRecords[ticket.id], record.ticket === ticket else { return sourceFault(.unknownSource) }
            guard record.installation == .installing else { return sourceFault(.repeatedInstallationReturn) }
            record.installation = .installationReturned
            return .recorded
        }
    }
    func sourceEventEntered(_ source: SourceInstallation) -> SourceEventTicket? {
        locked {
            guard source.ownerID === id else { _ = sourceFault(.foreignSource); return nil }
            guard sourceRecords[source.id]?.ticket === source else { _ = sourceFault(.unknownSource); return nil }
            let event = SourceEventTicket(ownerID: id, sourceID: source.id)
            sourceEventOrder.append(event.id)
            sourceEvents[event.id] = SourceEventRecord(ticket: event)
            return event
        }
    }
    @discardableResult
    func noteSourceEventBodyEnd(_ event: SourceEventTicket) -> SourceReceiptUpdate {
        locked {
            guard event.ownerID === id, let record = sourceEvents[event.id], record.ticket === event else {
                return sourceFault(.invalidEvent)
            }
            guard record.state == .entered else { return sourceFault(.repeatedBodyEnd) }
            record.state = .bodyEndRecorded
            return .recorded
        }
    }
    @discardableResult
    func sourceWriteEntered(_ write: SourceWriteTicket) -> SourceReceiptUpdate {
        locked {
            guard write.ownerID === id, let record = sourceWrites[write.id], record.ticket === write,
                  record.state == .reserved else { return sourceFault(.invalidWrite) }
            record.state = .entered
            return .recorded
        }
    }
    @discardableResult
    func noteSourceWriteBodyEnd(_ write: SourceWriteTicket) -> SourceReceiptUpdate {
        locked {
            guard write.ownerID === id, let record = sourceWrites[write.id], record.ticket === write,
                  record.state == .entered else { return sourceFault(.invalidWrite) }
            record.state = .bodyEndRecorded
            return .recorded
        }
    }
    @discardableResult
    func linkSourceEvent(_ event: SourceEventTicket, toExistingTask task: TaskTicket) -> SourceReceiptUpdate {
        locked {
            guard event.ownerID === id, sourceEvents[event.id]?.ticket === event else { return sourceFault(.invalidEvent) }
            guard task.ownerID === id, records[task.id]?.ticket === task else { return sourceFault(.invalidExistingTask) }
            sourceTaskEdges.append(SourceTaskEdge(sourceID: event.sourceID, eventID: event.id, taskID: task.id))
            return .recorded
        }
    }
    /// Call only with mutex held when appending a body-authorized write row.
    private func appendSourceWriteLocked(kind: SourceWriteKind, parent: SourceEventTicket) -> SourceWriteTicket {
        let write = SourceWriteTicket(ownerID: id, parent: parent)
        sourceWriteOrder.append(write.id)
        sourceWrites[write.id] = SourceWriteRecord(ticket: write, kind: kind)
        return write
    }

    /// Wrapper entry metadata is not permission to run its business body.
    func admitBody(_ event: SourceEventTicket) -> SourceBodyAdmission {
        locked {
            guard event.ownerID === id, let record = sourceEvents[event.id], record.ticket === event,
                  record.state == .entered, let source = sourceRecords[event.sourceID],
                  source.ticket.id === event.sourceID else {
                _ = sourceFault(.invalidBodyAdmission); return .protocolFault
            }
            guard sourceBodies[event.id] == nil else {
                _ = sourceFault(.repeatedBodyAdmission); return .protocolFault
            }
            // Refuse a new business body after this original owner's terminal root event.
            if let rootCloseReceipt {
                sourceBodyOrder.append(event.id)
                sourceBodies[event.id] = SourceBodyAdmissionRecord(ownerID: id, event: event, decision: .refusedBeforeRoot,
                                                                  permit: nil, closeReceipt: rootCloseReceipt)
                return .refusedBeforeRoot(rootCloseReceipt)
            }
            let permit = SourceEventBodyPermit(ownerID: id, event: event, kind: source.kind)
            sourceBodyOrder.append(event.id)
            sourceBodies[event.id] = SourceBodyAdmissionRecord(ownerID: id, event: event, decision: .accepted,
                                                              permit: permit, closeReceipt: nil)
            return .accepted(permit)
        }
    }

    func reserveAdmittedSourceWrite(kind: SourceWriteKind, permit: SourceEventBodyPermit) -> AdmittedSourceWriteReservation {
        locked {
            guard permit.ownerID === id, let body = sourceBodies[permit.eventID], body.ownerID === id,
                  body.sourceID === permit.sourceID, body.eventID === permit.eventID, body.decision == .accepted,
                  body.permit === permit, body.permit?.id === permit.id,
                  let event = sourceEvents[permit.eventID], event.ticket.sourceID === permit.sourceID,
                  event.state == .entered, sourceRecords[permit.sourceID]?.kind == permit.kind else {
                _ = sourceFault(.invalidBodyPermit); return .protocolFault
            }
            let matches: Bool
            switch (permit.kind, kind) {
            case (.weshRecipients, .weshRecipientsState), (.weshOnline, .weshOnlineState),
                 (.weshRelayConnectivity, .weshRelayState), (.legacyRelayConnectivity, .legacyRelayState): matches = true
            default: matches = false
            }
            guard matches else { _ = sourceFault(.invalidBodyWriteKind); return .protocolFault }
            guard body.writeID == nil else { _ = sourceFault(.repeatedBodyWrite); return .protocolFault }
            // An accepted body keeps this exact child-write permission after terminal root closure.
            let write = appendSourceWriteLocked(kind: kind, parent: event.ticket)
            body.writeID = write.id
            return .reserved(write)
        }
    }

    /// Immutable inspection contains distinct IDs, never a recoverable permit or source/work ticket.
    func sourceBodyAdmissionSnapshot() -> SourceBodyAdmissionSnapshot {
        locked {
            SourceBodyAdmissionSnapshot(ownerID: id, rows: sourceBodyOrder.compactMap { sourceBodies[$0] }.map {
                SourceBodyAdmissionRow(ownerID: $0.ownerID, sourceID: $0.sourceID, eventID: $0.eventID,
                    permitID: $0.permit?.id, decision: $0.decision, writeID: $0.writeID, closeReceipt: $0.closeReceipt)
            })
        }
    }

    private func sourceFault(_ fault: SourceProtocolFault) -> SourceReceiptUpdate {
        sourceFaults.append(fault)
        return .protocolFault
    }
    /// Installation/body-end metadata is not observer detachment, handler join or whole-owner completion.
    func sourceLedgerSnapshot() -> SourceLedgerSnapshot {
        locked {
            SourceLedgerSnapshot(ownerID: id,
                sources: sourceOrder.compactMap { sourceRecords[$0] }.map {
                    SourceRow(id: $0.ticket.id, kind: $0.kind, installation: $0.installation)
                },
                events: sourceEventOrder.compactMap { sourceEvents[$0] }.map {
                    SourceEventRow(id: $0.ticket.id, sourceID: $0.ticket.sourceID, state: $0.state)
                },
                writes: sourceWriteOrder.compactMap { sourceWrites[$0] }.map {
                    SourceWriteRow(id: $0.ticket.id, sourceID: $0.ticket.sourceID, eventID: $0.ticket.eventID, kind: $0.kind, state: $0.state)
                }, taskEdges: sourceTaskEdges, faults: sourceFaults)
        }
    }

    enum SourceEndpointCreation { case created(NostrSourceDetachmentEndpoint), protocolFault }
    enum SourceEndpointBindingResult { case bound(Identity), protocolFault }
    enum SourceEndpointBindingFinish { case ready(SourceDetachmentClaim?), protocolFault }
    enum SourceDetachmentRequestResult {
        case prepared(Identity, [SourceDetachmentClaim]), unconfirmed(SourceDetachmentGap)
    }
    enum SourceDetachmentInvocationResult { case invocationReturned, unconfirmed(SourceDetachmentGap) }
    enum SourceDetachmentGap: Equatable, Sendable {
        case foreignSubject, foreignReceipt, invalidClaim, invocationNotReturned
    }
    enum SourceBindingState: Equatable, Sendable { case unbound, awaitingReturn, awaitingFinish, ready }
    enum SourceEndpointAvailability: Equatable, Sendable { case unbound, present, unavailable }
    enum SourceInvocationState: Equatable, Sendable {
        case unclaimed, claimedAwaitingInvocation, invocationAdmittedNotReturned, invocationReturned
    }
    enum SourceDetachmentFault: Equatable, Sendable {
        case invalidEndpointSource, wrongEndpointKind, foreignEndpoint, repeatedBinding
        case invalidBinding, repeatedFinish, foreignSubject, foreignReceipt, invalidClaim, repeatedInvocation
    }
    struct SourceDetachmentRow: Sendable {
        let sourceID: Identity
        let installation: SourceInstallationState
        let bindingID: Identity?
        let endpointID: Identity?
        let binding: SourceBindingState
        let availability: SourceEndpointAvailability
        let requestID: Identity?
        let closeReceipt: RootCloseReceipt?
        let claimID: Identity?
        let invocation: SourceInvocationState
    }
    struct SourceDetachmentSnapshot: Sendable {
        let ownerID: Identity
        let requestID: Identity?
        let closeReceipt: RootCloseReceipt?
        let rows: [SourceDetachmentRow]
        let faults: [SourceDetachmentFault]
    }
    private final class SourceDetachmentRecord {
        let sourceID: Identity
        var bindingID: Identity?
        var endpointID: Identity?
        weak var endpoint: NostrSourceDetachmentEndpoint?
        var ready = false
        var requestID: Identity?
        var closeReceipt: RootCloseReceipt?
        var claimID: Identity?
        var invocation: SourceInvocationState = .unclaimed
        init(sourceID: Identity) { self.sourceID = sourceID }
    }
    private var sourceDetachmentRequestID: Identity?
    private var sourceDetachmentReceipt: RootCloseReceipt?
    private var sourceDetachments: [Identity: SourceDetachmentRecord] = [:]
    private var sourceDetachmentFaults: [SourceDetachmentFault] = []

    @MainActor
    func makeCancellableSourceEndpoint(_ source: SourceInstallation, cancellable: AnyCancellable) -> SourceEndpointCreation {
        guard let descriptor = endpointDescriptor(source, observer: false) else { return .protocolFault }
        return .created(NostrSourceDetachmentEndpoint(descriptor: descriptor, cancellable: cancellable))
    }
    @MainActor
    func makeObserverSourceEndpoint(_ source: SourceInstallation, center: NotificationCenter,
                                    token: NSObjectProtocol) -> SourceEndpointCreation {
        guard let descriptor = endpointDescriptor(source, observer: true) else { return .protocolFault }
        return .created(NostrSourceDetachmentEndpoint(descriptor: descriptor, center: center, token: token))
    }
    private func endpointDescriptor(_ source: SourceInstallation, observer: Bool) -> NostrSourceEndpointDescriptor? {
        locked {
            guard source.ownerID === id, let record = sourceRecords[source.id], record.ticket === source else {
                sourceDetachmentFaults.append(.invalidEndpointSource)
                return nil
            }
            guard (record.kind == .legacyFavoriteObserver) == observer else {
                sourceDetachmentFaults.append(.wrongEndpointKind)
                return nil
            }
            return NostrSourceEndpointDescriptor(ownerID: id, sourceID: source.id, kind: record.kind, endpointID: Identity())
        }
    }
    @MainActor
    func bindSourceEndpoint(_ endpoint: NostrSourceDetachmentEndpoint,
                            to source: SourceInstallation) -> SourceEndpointBindingResult {
        // Copy actor-isolated metadata before entering the nonrecursive RAM monitor.
        let descriptor = endpoint.descriptor
        defer { withExtendedLifetime(endpoint) {} }
        return locked {
            guard source.ownerID === id, let record = sourceRecords[source.id], record.ticket === source,
                  descriptor.ownerID === id, descriptor.sourceID === source.id, descriptor.kind == record.kind else {
                sourceDetachmentFaults.append(.foreignEndpoint)
                return .protocolFault
            }
            let association = detachmentRecordLocked(record)
            guard association.bindingID == nil else {
                sourceDetachmentFaults.append(.repeatedBinding)
                return .protocolFault
            }
            guard record.installation == .installing else {
                sourceDetachmentFaults.append(.invalidBinding)
                return .protocolFault
            }
            let bindingID = Identity()
            association.bindingID = bindingID
            association.endpointID = descriptor.endpointID
            association.endpoint = endpoint
            return .bound(bindingID)
        }
    }
    @MainActor
    func finishSourceEndpointBinding(_ source: SourceInstallation, bindingID: Identity) -> SourceEndpointBindingFinish {
        var pins: [NostrSourceDetachmentEndpoint] = []
        let prepared: (Bool, NostrSourceDetachmentPreparedClaim?) = locked {
            guard source.ownerID === id, let record = sourceRecords[source.id], record.ticket === source,
                  let association = sourceDetachments[source.id], association.bindingID === bindingID,
                  record.installation == .installationReturned else {
                sourceDetachmentFaults.append(.invalidBinding)
                return (false, nil)
            }
            guard !association.ready else {
                sourceDetachmentFaults.append(.repeatedFinish)
                return (false, nil)
            }
            association.ready = true
            return (true, prepareSourceClaimLocked(association, pins: &pins))
        }
        let claim = prepared.1.map { SourceDetachmentClaim(prepared: $0) }
        // No last upgraded endpoint/handle release may happen under the owner monitor.
        withExtendedLifetime(pins) {}
        return prepared.0 ? .ready(claim) : .protocolFault
    }
    @MainActor
    func requestSourceDetachment(subject: RootPanicSubject, receipt: RootCloseReceipt) -> SourceDetachmentRequestResult {
        var pins: [NostrSourceDetachmentEndpoint] = []
        let prepared: Result<(Identity, [NostrSourceDetachmentPreparedClaim]), SourceDetachmentRequestError> = locked {
            guard subject.ownerID === id, subject.nonce === originalRootSubject.nonce else {
                sourceDetachmentFaults.append(.foreignSubject)
                return .failure(SourceDetachmentRequestError(gap: .foreignSubject))
            }
            guard receipt.ownerID === id, rootCloseReceipt === receipt else {
                sourceDetachmentFaults.append(.foreignReceipt)
                return .failure(SourceDetachmentRequestError(gap: .foreignReceipt))
            }
            let requestID = sourceDetachmentRequestID ?? Identity()
            sourceDetachmentRequestID = requestID
            sourceDetachmentReceipt = receipt
            var claims: [NostrSourceDetachmentPreparedClaim] = []
            for key in sourceOrder {
                guard let record = sourceRecords[key] else { continue }
                let association = detachmentRecordLocked(record)
                association.requestID = requestID
                association.closeReceipt = receipt
                if let claim = prepareSourceClaimLocked(association, pins: &pins) { claims.append(claim) }
            }
            return .success((requestID, claims))
        }
        let result: SourceDetachmentRequestResult
        switch prepared {
        case .success(let (requestID, values)):
            result = .prepared(requestID, values.map { SourceDetachmentClaim(prepared: $0) })
        case .failure(let error): result = .unconfirmed(error.gap)
        }
        withExtendedLifetime(pins) {}
        return result
    }
    private struct SourceDetachmentRequestError: Error { let gap: SourceDetachmentGap }
    private func detachmentRecordLocked(_ source: SourceRecord) -> SourceDetachmentRecord {
        if let existing = sourceDetachments[source.ticket.id] { return existing }
        let record = SourceDetachmentRecord(sourceID: source.ticket.id)
        sourceDetachments[source.ticket.id] = record
        return record
    }
    private func prepareSourceClaimLocked(_ record: SourceDetachmentRecord,
                                          pins: inout [NostrSourceDetachmentEndpoint]) -> NostrSourceDetachmentPreparedClaim? {
        guard record.ready, sourceRecords[record.sourceID]?.installation == .installationReturned,
              record.invocation == .unclaimed, let requestID = record.requestID, let receipt = record.closeReceipt,
              let bindingID = record.bindingID, let endpointID = record.endpointID else { return nil }
        guard let endpoint = record.endpoint else { return nil }
        pins.append(endpoint)
        let claimID = Identity()
        record.claimID = claimID
        record.invocation = .claimedAwaitingInvocation
        let descriptor = NostrSourceDetachmentClaimDescriptor(ownerID: id, sourceID: record.sourceID,
            bindingID: bindingID, endpointID: endpointID, requestID: requestID, closeReceipt: receipt, claimID: claimID)
        return NostrSourceDetachmentPreparedClaim(descriptor: descriptor, endpoint: endpoint)
    }
    @MainActor
    func invokeSourceDetachment(_ claim: SourceDetachmentClaim) -> SourceDetachmentInvocationResult {
        let descriptor = claim.descriptor
        let endpoint = claim.endpoint
        defer { withExtendedLifetime(claim) {}; withExtendedLifetime(endpoint) {} }
        let admitted = locked {
            guard descriptor.ownerID === id, let record = sourceDetachments[descriptor.sourceID],
                  record.bindingID === descriptor.bindingID, record.endpointID === descriptor.endpointID,
                  record.requestID === descriptor.requestID, record.closeReceipt === descriptor.closeReceipt,
                  record.claimID === descriptor.claimID else {
                sourceDetachmentFaults.append(.invalidClaim)
                return false
            }
            guard record.invocation == .claimedAwaitingInvocation else {
                sourceDetachmentFaults.append(.repeatedInvocation)
                return false
            }
            record.invocation = .invocationAdmittedNotReturned
            return true
        }
        guard admitted else { return .unconfirmed(.invalidClaim) }
        // Real dispatch on the admitted original claim, never an action under RAM.
        switch endpoint.invoke() {
        case .notInvoked: return .unconfirmed(.invocationNotReturned)
        case .invocationReturned:
            return locked {
                guard let record = sourceDetachments[descriptor.sourceID], record.claimID === descriptor.claimID,
                      record.requestID === descriptor.requestID, record.closeReceipt === descriptor.closeReceipt,
                      record.invocation == .invocationAdmittedNotReturned else {
                    sourceDetachmentFaults.append(.invalidClaim)
                    return .unconfirmed(.invalidClaim)
                }
                record.invocation = .invocationReturned
                return .invocationReturned
            }
        }
    }
    /// Dynamic weak inspection is actor-bound; temporary strong pins outlive the RAM lock.
    @MainActor
    func sourceDetachmentSnapshot() -> SourceDetachmentSnapshot {
        var pins: [NostrSourceDetachmentEndpoint] = []
        let snapshot = locked {
            SourceDetachmentSnapshot(ownerID: id, requestID: sourceDetachmentRequestID, closeReceipt: sourceDetachmentReceipt,
                rows: sourceOrder.compactMap { key in
                    guard let source = sourceRecords[key] else { return nil }
                    let association = sourceDetachments[key]
                    let availability: SourceEndpointAvailability
                    if association?.bindingID == nil { availability = .unbound }
                    else if let endpoint = association?.endpoint { pins.append(endpoint); availability = .present }
                    else { availability = .unavailable }
                    let phase: SourceBindingState
                    if association?.bindingID == nil { phase = .unbound }
                    else if association?.ready == true { phase = .ready }
                    else if source.installation == .installing { phase = .awaitingReturn }
                    else { phase = .awaitingFinish }
                    return SourceDetachmentRow(sourceID: key, installation: source.installation,
                        bindingID: association?.bindingID, endpointID: association?.endpointID, binding: phase,
                        availability: availability, requestID: association?.requestID, closeReceipt: association?.closeReceipt,
                        claimID: association?.claimID, invocation: association?.invocation ?? .unclaimed)
                }, faults: sourceDetachmentFaults)
        }
        withExtendedLifetime(pins) {}
        return snapshot
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
            if case .root = parent, let rootCloseReceipt { return .refusedBeforeRoot(rootCloseReceipt) }
            let ticket = TaskTicket(ownerID: id)
            order.append(ticket.id)
            records[ticket.id] = Record(ticket: ticket, parent: parentID(parent), kind: .task(kind))
            return .reserved(ticket)
        }
    }
    func reserveCallback(kind: CallbackKind, parent: Parent) -> Reservation<CallbackTicket> {
        locked {
            guard valid(parent) else { return .protocolDebt(debt(.invalidParent, workID: nil)) }
            if case .root = parent, let rootCloseReceipt { return .refusedBeforeRoot(rootCloseReceipt) }
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

    enum OriginalReturnedTaskGap: Equatable, Sendable {
        case invalidOriginalBinding, missingCloseReceipt, protocolUncertainty, unsettledTask
        case requestedNotAwaited(ownerID: Identity, batchID: Identity, taskIDs: [Identity])
    }
    /// Authentic empty preparation only; contains no owner, receipt or restore authority.
    struct EmptyOriginalReturnedTasks: Sendable {
        fileprivate init() {}
    }
    struct OriginalReturnedTaskResult: Sendable {
        let joined: JoinedTaskBatch?
        let empty: EmptyOriginalReturnedTasks?
        let gap: OriginalReturnedTaskGap?
        var permitsExistingOwnerCheck: Bool { joined != nil || empty != nil }
        fileprivate init(joined: JoinedTaskBatch?, empty: EmptyOriginalReturnedTasks?, gap: OriginalReturnedTaskGap?) {
            self.joined = joined; self.empty = empty; self.gap = gap
        }
    }
    private enum OriginalReturnedPreparation {
        case ready(TaskBatch), empty(EmptyOriginalReturnedTasks), unconfirmed(OriginalReturnedTaskGap)
    }

    /// Known returned bodies only, not a closed callback frontier or whole-owner drain.
    private func prepareOriginalReturnedTasks(subject: RootPanicSubject, receipt: RootCloseReceipt) -> OriginalReturnedPreparation {
        locked {
            guard subject === originalRootSubject else { return .unconfirmed(.invalidOriginalBinding) }
            guard let actual = rootCloseReceipt, receipt === actual else { return .unconfirmed(.missingCloseReceipt) }
            guard debts.isEmpty, unconfirmedHandles.isEmpty else { return .unconfirmed(.protocolUncertainty) }
            let taskIDs = order.filter { records[$0]?.ticket is TaskTicket }
            for key in taskIDs {
                guard let record = records[key], record.dispatched, record.body == .returned,
                      record.handle != nil, !record.failedProtocol else { return .unconfirmed(.unsettledTask) }
            }
            if taskIDs.isEmpty { return .empty(EmptyOriginalReturnedTasks()) }
            return .ready(TaskBatch(ownerID: id, taskIDs: taskIDs))
        }
    }

    @MainActor
    fileprivate func awaitOriginalReturnedTasks(subject: RootPanicSubject, receipt: RootCloseReceipt) async throws -> OriginalReturnedTaskResult {
        try Task.checkCancellation()
        switch prepareOriginalReturnedTasks(subject: subject, receipt: receipt) {
        case .unconfirmed(let gap): return OriginalReturnedTaskResult(joined: nil, empty: nil, gap: gap)
        case .empty(let witness): return OriginalReturnedTaskResult(joined: nil, empty: witness, gap: nil)
        case .ready(let batch):
            // BASELINE omission: the same batch's actual Task.value await is not performed yet.
            return OriginalReturnedTaskResult(joined: nil, empty: nil,
                gap: .requestedNotAwaited(ownerID: batch.ownerID, batchID: batch.id, taskIDs: batch.taskIDs))
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

private struct NostrSourceEndpointDescriptor {
    let ownerID: NostrOutboundOwner.Identity
    let sourceID: NostrOutboundOwner.Identity
    let kind: NostrOutboundOwner.SourceKind
    let endpointID: NostrOutboundOwner.Identity
}
private enum NostrSourceEndpointInvocation { case notInvoked, invocationReturned }

/// The transport owns actual resources; the process journal keeps only a weak endpoint.
@MainActor
final class NostrSourceDetachmentEndpoint {
    fileprivate let descriptor: NostrSourceEndpointDescriptor
    private enum Payload {
        case cancellable(AnyCancellable)
        case observer(NotificationCenter, NSObjectProtocol)
    }
    private let payload: Payload
    fileprivate init(descriptor: NostrSourceEndpointDescriptor, cancellable: AnyCancellable) {
        self.descriptor = descriptor; self.payload = .cancellable(cancellable)
    }
    fileprivate init(descriptor: NostrSourceEndpointDescriptor, center: NotificationCenter, token: NSObjectProtocol) {
        self.descriptor = descriptor; self.payload = .observer(center, token)
    }
    fileprivate func invoke() -> NostrSourceEndpointInvocation {
        switch payload {
        case .cancellable(let cancellable):
            cancellable.cancel()
            return .invocationReturned
        case .observer(let center, let token):
            center.removeObserver(token)
            return .invocationReturned
        }
    }
}

private struct NostrSourceDetachmentClaimDescriptor {
    let ownerID: NostrOutboundOwner.Identity
    let sourceID: NostrOutboundOwner.Identity
    let bindingID: NostrOutboundOwner.Identity
    let endpointID: NostrOutboundOwner.Identity
    let requestID: NostrOutboundOwner.Identity
    let closeReceipt: NostrOutboundOwner.RootCloseReceipt
    let claimID: NostrOutboundOwner.Identity
}
private struct NostrSourceDetachmentPreparedClaim {
    let descriptor: NostrSourceDetachmentClaimDescriptor
    let endpoint: NostrSourceDetachmentEndpoint
}

/// Local invocation authority, never returned by metadata inspection or stored by the process owner.
@MainActor
final class SourceDetachmentClaim {
    fileprivate let descriptor: NostrSourceDetachmentClaimDescriptor
    fileprivate let endpoint: NostrSourceDetachmentEndpoint
    fileprivate init(prepared: NostrSourceDetachmentPreparedClaim) {
        self.descriptor = prepared.descriptor; self.endpoint = prepared.endpoint
    }
}

@MainActor
func closeCapturedNostrOutboundRootsAndRequestSourceDetachment(
    _ binding: NostrOutboundPanicBinding
) -> NostrOutboundOwner.RootCloseOutcome {
    let original = closeCapturedNostrOutboundRoots(binding)
    if case .closed(let receipt) = original,
       case .prepared(_, let claims) = binding.owner.requestSourceDetachment(subject: binding.subject, receipt: receipt) {
        for claim in claims { _ = binding.owner.invokeSourceDetachment(claim) }
    }
    return original
}

/// Caller contract: the application command is outside this owner. Only returned synchronous
/// live Task bodies are eligible; arbitrary custom async tails are not a universal self-safety proof.
@MainActor
func awaitCapturedOriginalReturnedTaskBatch(
    _ binding: NostrOutboundPanicBinding,
    closeOutcome: NostrOutboundOwner.RootCloseOutcome
) async throws -> NostrOutboundOwner.OriginalReturnedTaskResult {
    guard case .closed(let receipt) = closeOutcome else {
        return NostrOutboundOwner.OriginalReturnedTaskResult(joined: nil, empty: nil, gap: .missingCloseReceipt)
    }
    return try await binding.owner.awaitOriginalReturnedTasks(subject: binding.subject, receipt: receipt)
}
