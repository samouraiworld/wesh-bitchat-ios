import Foundation
import Testing
@testable import bitchat

struct NostrOriginalReturnedTaskJoinTests {
    @Test @MainActor
    func exactOriginalClosedBatchJoinsSameReturnedTask() async throws {
        try await withPanicSpineFixture { f in
            let held = f.gate()
            let owner = f.owner(tail: held)
            guard case .reserved(let ticket) = owner.reserveTask(kind: .privateMessage, parent: .root) else {
                throw PanicSpineFailure.messages(["original Task was not admitted"])
            }
            _ = owner.dispatch(ticket) {}
            try await f.waitUntil { await held.hasEntered() }
            try #require(owner.provenanceSnapshot().tasks.first?.body == .returned)
            let binding = owner.captureOutboundPanicBinding()
            let close = closeCapturedNostrOutboundRoots(binding)
            guard case .closed(let receipt) = close else { throw PanicSpineFailure.messages(["original close missing"]) }
            var completed = false
            var result: NostrOutboundOwner.OriginalReturnedTaskResult?
            f.task {
                result = try await awaitCapturedOriginalReturnedTaskBatch(binding, closeOutcome: close)
                completed = true
            }
            try await f.waitUntil { completed || f.tasks.installationCount() > 0 }
            let completedWhileHeld = completed
            let registrationWhileHeld = owner.provenanceSnapshot().tasks.first?.registration
            return {
                try #require(!completedWhileHeld)
                #expect(registrationWhileHeld == .handleRegistered)
                let proof = try #require(result?.joined)
                #expect(proof.ownerID === binding.ownerID)
                #expect(proof.taskIDs.count == 1 && proof.taskIDs.first === ticket.id)
                #expect(receipt.ownerID === proof.ownerID)
                #expect(result?.empty == nil && result?.gap == nil)
                #expect(owner.provenanceSnapshot().tasks.first?.registration == .supervisorJoined)
            }
        }
    }

    @Test @MainActor
    func activeAndUnregisteredOriginalTasksRemainUnconfirmed() async throws {
        try await withPanicSpineFixture { f in
            let reservedOwner = f.owner(tail: f.gate(open: true))
            guard case .reserved = reservedOwner.reserveTask(kind: .privateMessage, parent: .root) else {
                throw PanicSpineFailure.messages(["reserved original Task missing"])
            }
            let reservedBinding = reservedOwner.captureOutboundPanicBinding()
            let reservedClose = closeCapturedNostrOutboundRoots(reservedBinding)
            let reserved = try await awaitCapturedOriginalReturnedTaskBatch(reservedBinding, closeOutcome: reservedClose)

            let lateReturn = f.threadGate()
            let owner = f.owner(tail: f.gate(open: true), lateReturn: lateReturn)
            guard case .reserved(let ticket) = owner.reserveTask(kind: .privateMessage, parent: .root) else {
                throw PanicSpineFailure.messages(["late-registration Task missing"])
            }
            try f.worker { _ = owner.dispatch(ticket) {} }
            try await f.waitUntil {
                lateReturn.hasEntered() && owner.provenanceSnapshot().tasks.first?.body == .returned
            }
            try #require(owner.provenanceSnapshot().tasks.first?.registration == .reservedAwaitingHandle)
            let binding = owner.captureOutboundPanicBinding()
            let close = closeCapturedNostrOutboundRoots(binding)
            let unregistered = try await awaitCapturedOriginalReturnedTaskBatch(binding, closeOutcome: close)
            let actualTaskCount = f.tasks.snapshot().count
            let installCount = f.tasks.installationCount()
            return {
                #expect(reserved.gap == .unsettledTask && !reserved.permitsExistingOwnerCheck)
                #expect(unregistered.gap == .unsettledTask && !unregistered.permitsExistingOwnerCheck)
                #expect(actualTaskCount == 1 && installCount == 0)
                #expect(owner.provenanceSnapshot().tasks.first?.registration == .handleRegistered)
            }
        }
    }

    @Test @MainActor
    func lateAcceptedCallbackChildIsOutsideEarlierJoinedSubset() async throws {
        try await withPanicSpineFixture { f in
            let open = f.gate(open: true)
            let owner = f.owner(tail: open)
            guard case .reserved(let original) = owner.reserveTask(kind: .privateMessage, parent: .root),
                  case .reserved(let callback) = owner.reserveCallback(kind: .pendingAckHandoff, parent: .root) else {
                throw PanicSpineFailure.messages(["original task/callback admission missing"])
            }
            _ = owner.dispatch(original) {}
            try await f.waitUntil { await open.hasEntered() }
            let binding = owner.captureOutboundPanicBinding()
            guard case .closed = closeCapturedNostrOutboundRoots(binding) else {
                throw PanicSpineFailure.messages(["actual close missing"])
            }
            let firstBatch = owner.taskBatchSnapshot()
            _ = owner.callbackEntered(callback)
            guard case .reserved(let child) = owner.reserveTask(kind: .ackItem, parent: .child(callback)) else {
                throw PanicSpineFailure.messages(["accepted callback child refused"])
            }
            _ = owner.dispatch(child) {}
            _ = owner.callbackBodyReturned(callback)
            // Exercise the same existing real join primitive; no new consumer guard is fabricated.
            let first = try await owner.joinTaskBatch(firstBatch)
            let second = try await owner.joinTaskBatch(owner.taskBatchSnapshot())
            let rows = owner.provenanceSnapshot()
            return {
                #expect(first.taskIDs.count == 1 && first.taskIDs.first === original.id)
                #expect(!first.taskIDs.contains { $0 === child.id })
                #expect(second.taskIDs.count == 2 && second.taskIDs.contains { $0 === child.id })
                #expect(rows.tasks.first(where: { $0.id === child.id })?.parent === callback.id)
                #expect(rows.callbacks.first?.state == .bodyReturned)
                #expect(rows.debts.isEmpty)
            }
        }
    }

    @Test @MainActor
    func foreignReceiptAndProtocolDebtDoNotJoin() async throws {
        try await withPanicSpineFixture { f in
            let owner = f.owner(tail: f.gate(open: true))
            let other = f.owner(tail: f.gate(open: true))
            guard case .reserved(let ticket) = owner.reserveTask(kind: .privateMessage, parent: .root) else {
                throw PanicSpineFailure.messages(["original Task missing"])
            }
            _ = owner.dispatch(ticket) {}
            let binding = owner.captureOutboundPanicBinding()
            let actualClose = closeCapturedNostrOutboundRoots(binding)
            let otherBinding = other.captureOutboundPanicBinding()
            let foreignClose = closeCapturedNostrOutboundRoots(otherBinding)
            let empty = try await awaitCapturedOriginalReturnedTaskBatch(otherBinding, closeOutcome: foreignClose)
            let foreign = try await awaitCapturedOriginalReturnedTaskBatch(binding, closeOutcome: foreignClose)
            _ = owner.dispatch(ticket) {} // Real replay misuse adds actual protocol debt.
            let uncertain = try await awaitCapturedOriginalReturnedTaskBatch(binding, closeOutcome: actualClose)
            let installs = f.tasks.installationCount()
            let actualTaskCount = f.tasks.snapshot().count
            return {
                _ = try #require(empty.empty)
                guard case .closed = foreignClose else {
                    Issue.record("Actual empty-owner close missing"); return
                }
                #expect(empty.joined == nil && empty.gap == nil && empty.permitsExistingOwnerCheck)
                #expect(foreign.empty == nil && foreign.joined == nil && foreign.gap == .missingCloseReceipt && !foreign.permitsExistingOwnerCheck)
                #expect(uncertain.gap == .protocolUncertainty && !uncertain.permitsExistingOwnerCheck)
                #expect(installs == 0 && actualTaskCount == 1)
                #expect(owner.provenanceSnapshot().debts.map(\.fault) == [.replayedSubmission])
            }
        }
    }
}
