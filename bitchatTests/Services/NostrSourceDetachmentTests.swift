import BitFoundation
import Combine
import Foundation
import Testing
@testable import bitchat

/// Actual isolated source handles and the live original-binding close action only.
@MainActor
struct NostrSourceDetachmentTests {
    @Test
    func liveCloseCancelsAllInstalledWeshPublishers() async throws {
        let result = try await withDetachFixture { f in
            let box = DetachPublishers()
            let binding = f.owner.captureOutboundPanicBinding()
            let reentrant = DetachLocked<[NostrOutboundOwner.RootCloseReceipt]>([])
            let errors = f.errors
            box.onCancel = {
                do { let receipt = try detachLiveClose(binding); reentrant.update { $0.append(receipt) } }
                catch { errors.update { $0.append("Reentrant live close: \(error)") } }
            }
            let transport = f.makeWesh(box)
            box.recipients.send([f.peer: "synthetic-contact"])
            box.online.send(true)
            box.relay.send(true)
            try await f.finishKnownWork()
            try detachRequire(transport.canDeliverPromptly(to: f.peer), "Open actual Wesh effects did not converge")
            let receipt = try detachLiveClose(binding)
            let cancellations = box.cancellations.read()
            let before = f.owner.sourceLedgerSnapshot().events.count
            box.recipients.send([f.peer: "synthetic-after-close"])
            box.online.send(false)
            box.relay.send(false)
            try await f.finishKnownWork()
            return (cancellations, f.owner.sourceLedgerSnapshot().events.count - before,
                    receipt, f.owner.sourceDetachmentSnapshot(), reentrant.read())
        }
        try #require(result.0 == [1, 1, 1], "Live close did not invoke all three actual Wesh cancellations")
        #expect(result.1 == 0)
        try expectDetachReturned(result.3, receipt: result.2, count: 3)
        #expect(result.4.count == 3 && result.4.allSatisfy { $0 === result.2 })
    }

    @Test
    func liveCloseRemovesInstalledLegacyFavoriteObserver() async throws {
        let result = try await withDetachFixture { f in
            _ = f.makeLegacy()
            f.notifications.post(name: .favoriteStatusChanged, object: nil)
            try await f.finishKnownWork()
            try detachRequire(f.owner.sourceLedgerSnapshot().events.count == 1 && f.creators.read() == 1,
                              "Open actual notification did not enter and finish its refresh Task")
            let receipt = try detachLiveClose(f.owner.captureOutboundPanicBinding())
            let before = f.owner.sourceLedgerSnapshot().events.count
            let creators = f.creators.read()
            let loads = f.favoriteLoads.read()
            f.notifications.post(name: .favoriteStatusChanged, object: nil)
            try await f.finishKnownWork()
            return (f.owner.sourceLedgerSnapshot().events.count - before, receipt,
                    f.owner.sourceDetachmentSnapshot(), f.creators.read() == creators && f.favoriteLoads.read() == loads)
        }
        try #require(result.0 == 0, "A fresh actual favorite notification still entered after live detachment")
        try expectDetachReturned(result.2, receipt: result.1, count: 2)
        #expect(result.3)
    }

    @Test
    func openBindingsPreserveInlineSourceEffectsAndOriginalHandleOwnership() async throws {
        let result = try await withDetachFixture { f in
            let owner = f.owner
            let during = DetachLocked<NostrOutboundOwner.SourceDetachmentSnapshot?>(nil)
            let inline = DetachInlineRecipients(value: [f.peer: "synthetic-inline"], afterEmission: {
                during.update { $0 = owner.sourceDetachmentSnapshot() }
            })
            let box = DetachPublishers()
            let wesh = f.makeWesh(box, recipients: { inline.eraseToAnyPublisher() })
            let legacy = f.makeLegacy()
            box.online.send(true)
            box.relay.send(true)
            f.legacyRelay.send(true)
            f.notifications.post(name: .favoriteStatusChanged, object: nil)
            try await f.finishKnownWork()
            return (try #require(during.read()), f.owner.sourceDetachmentSnapshot(),
                    wesh.canDeliverPromptly(to: f.peer), legacy.canDeliverPromptly(to: f.peer))
        }
        #expect(result.0.rows.count == 1 && result.0.rows.first?.installation == .installing)
        #expect(result.0.rows.first?.binding == .unbound)
        #expect(result.1.rows.count == 5 && result.1.faults.isEmpty && result.2 && result.3)
        #expect(result.1.rows.allSatisfy {
            $0.installation == .installationReturned && $0.binding == .ready && $0.availability == .present &&
            $0.requestID == nil && $0.claimID == nil && $0.invocation == .unclaimed
        })
        #expect(Set(result.1.rows.compactMap(\.endpointID)).count == 5)
        #expect(Set(result.1.rows.compactMap(\.bindingID)).count == 5)
    }

    @Test
    func reentrantCloseInsideAcceptedProviderKeepsPendingRequestThroughLateBinding() async throws {
        let result = try await withDetachFixture { f in
            let owner = f.owner
            let errors = f.errors
            let during = DetachLocked<NostrOutboundOwner.SourceDetachmentSnapshot?>(nil)
            let receipt = DetachLocked<NostrOutboundOwner.RootCloseReceipt?>(nil)
            let box = DetachPublishers()
            _ = f.makeWesh(box, recipients: {
                do {
                    let closed = try detachLiveClose(owner.captureOutboundPanicBinding())
                    receipt.update { $0 = closed }
                    during.update { $0 = owner.sourceDetachmentSnapshot() }
                } catch { errors.update { $0.append("Provider live close: \(error)") } }
                return box.recipients.eraseToAnyPublisher()
            })
            try await f.finishKnownWork()
            return (try #require(during.read()), f.owner.sourceDetachmentSnapshot(),
                    try #require(receipt.read()), f.providerCounts.read())
        }
        let before = try #require(result.0.rows.first)
        let after = try #require(result.1.rows.first)
        #expect(result.0.rows.count == 1 && before.installation == .installing && before.binding == .unbound)
        #expect(before.requestID === result.0.requestID && before.closeReceipt === result.2 && before.claimID == nil)
        #expect(result.1.rows.count == 1 && after.sourceID === before.sourceID && after.requestID === before.requestID)
        #expect(after.closeReceipt === result.2 && after.binding == .ready && after.claimID != nil)
        #expect(after.invocation == .invocationAdmittedNotReturned || after.invocation == .invocationReturned)
        #expect(result.1.faults.isEmpty && result.3 == [1, 0, 0])
    }

    @Test
    func duplicateLiveRequestsPreserveOneRequestAndOneClaimPerBoundSource() async throws {
        let result = try await withDetachFixture { f in
            _ = f.makeWesh(DetachPublishers())
            let binding = f.owner.captureOutboundPanicBinding()
            let first = try detachLiveClose(binding)
            let before = f.owner.sourceDetachmentSnapshot()
            let second = try detachLiveClose(binding)
            return (first, second, before, f.owner.sourceDetachmentSnapshot())
        }
        #expect(result.0 === result.1 && result.2.requestID === result.3.requestID)
        #expect(result.2.rows.count == 3 && result.3.rows.count == 3)
        #expect(result.2.rows.compactMap(\.claimID) == result.3.rows.compactMap(\.claimID))
        #expect(Set(result.3.rows.compactMap(\.claimID)).count == 3)
        #expect(result.3.rows.allSatisfy { $0.closeReceipt === result.0 && $0.binding == .ready })
        #expect(result.3.faults.isEmpty)
    }

    @Test
    func foreignSubjectAndReceiptCannotRequestDetachmentForAnotherOwner() async throws {
        let result = try await withDetachFixture { first in
            try await withDetachFixture { second in
                _ = first.makeWesh(DetachPublishers())
                _ = second.makeWesh(DetachPublishers())
                let firstBinding = first.owner.captureOutboundPanicBinding()
                let secondBinding = second.owner.captureOutboundPanicBinding()
                let receipt = try detachLiveClose(firstBinding)
                _ = try detachLiveClose(secondBinding)
                let before = first.owner.sourceDetachmentSnapshot()
                let other = second.owner.sourceDetachmentSnapshot()
                let badSubject = first.owner.requestSourceDetachment(subject: secondBinding.subject, receipt: receipt)
                let badReceipt = second.owner.requestSourceDetachment(subject: secondBinding.subject, receipt: receipt)
                return (detachGap(badSubject, .foreignSubject), detachGap(badReceipt, .foreignReceipt),
                        before, first.owner.sourceDetachmentSnapshot(), other, second.owner.sourceDetachmentSnapshot())
            }
        }
        #expect(result.0 && result.1)
        #expect(result.2.requestID === result.3.requestID && result.4.requestID === result.5.requestID)
        #expect(result.2.rows.compactMap(\.claimID) == result.3.rows.compactMap(\.claimID))
        #expect(result.4.rows.compactMap(\.claimID) == result.5.rows.compactMap(\.claimID))
        #expect(result.3.faults == [.foreignSubject] && result.5.faults == [.foreignReceipt])
    }

    @Test
    func metadataOnlyOrLostWeakEndpointNeverManufacturesInvocationReturn() async throws {
        let result = try await withDetachFixture { metadata in
            try await withDetachFixture { released in
                let source = try detachSource(metadata.owner, kind: .weshOnline)
                try detachRequire(detachRecorded(metadata.owner.noteSourceInstallationReturned(source)), "Metadata return was refused")
                _ = try detachLiveClose(metadata.owner.captureOutboundPanicBinding())
                let box = DetachPublishers()
                let weakTransport = released.makeUnretainedWesh(box)
                try await detachEventually { weakTransport.value == nil && box.cancellations.read() == [1, 1, 1] }
                _ = try detachLiveClose(released.owner.captureOutboundPanicBinding())
                return (metadata.owner.sourceDetachmentSnapshot(), released.owner.sourceDetachmentSnapshot(), box.cancellations.read())
            }
        }
        #expect(result.0.rows.count == 1 && result.0.rows.first?.binding == .unbound)
        #expect(result.0.rows.first?.availability == .unbound && result.0.rows.first?.claimID == nil)
        #expect(result.0.rows.first?.invocation == .unclaimed && result.0.faults.isEmpty)
        #expect(result.1.rows.count == 3 && result.1.faults.isEmpty && result.2 == [1, 1, 1])
        #expect(result.1.rows.allSatisfy {
            $0.binding == .ready && $0.availability == .unavailable && $0.claimID == nil && $0.invocation == .unclaimed
        })
    }

    @Test
    func foreignAndRepeatedEndpointBindingCannotReplaceOriginalAssociation() async throws {
        let result = try await withDetachFixture { first in
            try await withDetachFixture { second in
                let source = try detachSource(first.owner, kind: .weshOnline)
                let foreignSource = try detachSource(second.owner, kind: .weshOnline)
                let subject = PassthroughSubject<Bool, Never>()
                let otherSubject = PassthroughSubject<Bool, Never>()
                let endpoint = try first.retainEndpoint(first.owner.makeCancellableSourceEndpoint(source,
                    cancellable: subject.sink { _ in }))
                let foreignEndpoint = try second.retainEndpoint(second.owner.makeCancellableSourceEndpoint(foreignSource,
                    cancellable: otherSubject.sink { _ in }))
                let bindingID = try detachBinding(first.owner.bindSourceEndpoint(endpoint, to: source))
                let before = first.owner.sourceDetachmentSnapshot()
                let rejected = [detachBindingFault(first.owner.bindSourceEndpoint(foreignEndpoint, to: source)),
                                detachBindingFault(first.owner.bindSourceEndpoint(endpoint, to: foreignSource)),
                                detachBindingFault(first.owner.bindSourceEndpoint(endpoint, to: source))]
                try detachRequire(detachRecorded(first.owner.noteSourceInstallationReturned(source)), "Original manual source return failed")
                guard case .ready(nil) = first.owner.finishSourceEndpointBinding(source, bindingID: bindingID) else {
                    throw DetachFixtureError("Open manual association unexpectedly failed or issued a claim")
                }
                let replay = detachFinishFault(first.owner.finishSourceEndpointBinding(source, bindingID: bindingID))
                let receipt = try detachLiveClose(first.owner.captureOutboundPanicBinding())
                return (before, first.owner.sourceDetachmentSnapshot(), rejected, replay, receipt)
            }
        }
        let before = try #require(result.0.rows.first)
        let after = try #require(result.1.rows.first)
        #expect(result.2.allSatisfy { $0 } && result.3)
        #expect(before.binding == .awaitingReturn && before.sourceID === after.sourceID)
        #expect(before.bindingID === after.bindingID && before.endpointID === after.endpointID)
        #expect(after.binding == .ready && after.claimID != nil && after.closeReceipt === result.4)
        #expect(result.1.faults == [.foreignEndpoint, .foreignEndpoint, .repeatedBinding, .repeatedFinish])
    }
}

private struct DetachFixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct DetachCleanupFailure: Error, CustomStringConvertible {
    let primary: Error
    let cleanup: [String]
    var description: String { "primary: \(primary); cleanup: \(cleanup.joined(separator: "; "))" }
}

private final class DetachLocked<Value>: @unchecked Sendable {
    private let mutex = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { mutex.lock(); defer { mutex.unlock() }; return value }
    @discardableResult func update<Result>(_ action: (inout Value) -> Result) -> Result {
        mutex.lock(); defer { mutex.unlock() }; return action(&value)
    }
}

private final class DetachTaskLedger: @unchecked Sendable {
    private struct Row { let task: Task<Void, Never>; let observer: Task<Void, Never>; let finished: DetachLocked<Bool> }
    private let rows = DetachLocked<[Row]>([])
    func track(_ task: Task<Void, Never>) {
        let finished = DetachLocked(false)
        let observer = Task { await task.value; finished.update { $0 = true } }
        rows.update { $0.append(Row(task: task, observer: observer, finished: finished)) }
    }
    @MainActor
    func drain() async throws {
        var readinessErrors: [Error] = []
        var index = 0
        while index < rows.read().count {
            let row = rows.read()[index]
            do { try await detachEventually { row.finished.read() } }
            catch { readinessErrors.append(error) }
            // A readiness failure never replaces either actual join or skips finite children.
            await row.task.value
            await row.observer.value
            index += 1
        }
        guard let first = readinessErrors.first else { return }
        if readinessErrors.count == 1 { throw first }
        throw DetachCleanupFailure(primary: first, cleanup: readinessErrors.dropFirst().map { String(describing: $0) })
    }
}

private final class DetachInstaller: @unchecked Sendable {
    private let count = DetachLocked(0)
    var activeCount: Int { count.read() }
    func install(_ action: @escaping @Sendable () -> Void) {
        count.update { $0 += 1 }
        defer { count.update { $0 -= 1 } }
        action()
    }
}

private final class DetachScheduler: @unchecked Sendable {
    private let pending = DetachLocked<[@Sendable () -> Void]>([])
    var count: Int { pending.read().count }
    func submit(_ action: @escaping @Sendable () -> Void) { pending.update { $0.append(action) } }
    func releaseAll() {
        let actions = pending.update { let copy = $0; $0.removeAll(); return copy }
        actions.forEach { $0() }
    }
}

@MainActor
private final class DetachPublishers {
    let recipients = PassthroughSubject<[PeerID: String], Never>()
    let online = PassthroughSubject<Bool, Never>()
    let relay = PassthroughSubject<Bool, Never>()
    let cancellations = DetachLocked([0, 0, 0])
    var onCancel: (() -> Void)?

    func recipientsPublisher() -> AnyPublisher<[PeerID: String], Never> {
        let cancellations = self.cancellations
        let hook = onCancel
        return recipients.handleEvents(receiveCancel: { cancellations.update { $0[0] += 1 }; hook?() }).eraseToAnyPublisher()
    }
    func onlinePublisher() -> AnyPublisher<Bool, Never> {
        let cancellations = self.cancellations
        let hook = onCancel
        return online.handleEvents(receiveCancel: { cancellations.update { $0[1] += 1 }; hook?() }).eraseToAnyPublisher()
    }
    func relayPublisher() -> AnyPublisher<Bool, Never> {
        let cancellations = self.cancellations
        let hook = onCancel
        return relay.handleEvents(receiveCancel: { cancellations.update { $0[2] += 1 }; hook?() }).eraseToAnyPublisher()
    }
}

private final class DetachWeakTransport {
    weak var value: NostrTransport?
    init(_ value: NostrTransport) { self.value = value }
}

@MainActor
private final class DetachFixture {
    let owner: NostrOutboundOwner
    let pacer: NostrTransport.AckPacer
    let notifications = NotificationCenter()
    let legacyRelay = PassthroughSubject<Bool, Never>()
    let peer = PeerID(publicKey: Data(repeating: 0x11, count: 32))
    let providerCounts = DetachLocked([0, 0, 0])
    let favoriteLoads = DetachLocked(0)
    let creators: DetachLocked<Int>
    let errors = DetachLocked<[String]>([])
    private let ledger: DetachTaskLedger
    private let installer: DetachInstaller
    private let scheduler: DetachScheduler
    private let ackQueue: DispatchQueue
    private var transports: [NostrTransport] = []
    private var publishers: [DetachPublishers] = []
    private var manualEndpoints: [NostrSourceDetachmentEndpoint] = []

    init() {
        let ledger = DetachTaskLedger()
        let installer = DetachInstaller()
        let creators = DetachLocked(0)
        let scheduler = DetachScheduler()
        let ackQueue = DispatchQueue(label: "synthetic.source-detachment.serial-ack")
        self.ledger = ledger; self.installer = installer; self.creators = creators
        self.scheduler = scheduler; self.ackQueue = ackQueue
        let owner = NostrOutboundOwner(taskCreator: { operation in
            let task = NostrOutboundOwner.mainActorTaskCreator(operation)
            ledger.track(task)
            creators.update { $0 += 1 }
            return task
        }, waiterInstaller: { action in installer.install(action) })
        self.owner = owner
        self.pacer = NostrTransport.AckPacer(owner: owner, queue: ackQueue, scheduleAfter: { _, action in scheduler.submit(action) })
    }

    func makeLegacy() -> NostrTransport {
        let loads = favoriteLoads
        let relay = legacyRelay
        let dependencies = detachDependencies(owner: owner, pacer: pacer, notifications: notifications, errors: errors,
            loadFavorites: { loads.update { $0 += 1 }; return detachFavorites() },
            relay: { relay.eraseToAnyPublisher() })
        let transport = createTransport(dependencies)
        transports.append(transport)
        return transport
    }

    func makeWesh(_ box: DetachPublishers,
                  recipients: (@MainActor () -> AnyPublisher<[PeerID: String], Never>)? = nil) -> NostrTransport {
        publishers.append(box)
        let transport = createTransport(weshDependencies(box, recipients: recipients))
        transports.append(transport)
        return transport
    }

    /// Returns no transport, dependencies, endpoint, callback or Task: only a weak probe.
    func makeUnretainedWesh(_ box: DetachPublishers) -> DetachWeakTransport {
        let transport = createTransport(weshDependencies(box, recipients: nil))
        let probe = DetachWeakTransport(transport)
        withExtendedLifetime(transport) {}
        return probe
    }

    private func weshDependencies(_ box: DetachPublishers,
                                  recipients: (@MainActor () -> AnyPublisher<[PeerID: String], Never>)?) -> NostrTransport.Dependencies {
        let counts = providerCounts
        let errors = self.errors
        return detachDependencies(owner: owner, pacer: pacer, notifications: notifications, errors: errors,
            loadFavorites: { errors.update { $0.append("Wesh loaded favorites") }; return [:] },
            relay: { counts.update { $0[2] += 1 }; return box.relayPublisher() },
            recipients: { counts.update { $0[0] += 1 }; return recipients?() ?? box.recipientsPublisher() },
            online: { counts.update { $0[1] += 1 }; return box.onlinePublisher() })
    }

    private func createTransport(_ dependencies: NostrTransport.Dependencies) -> NostrTransport {
        let keychain = MockKeychain()
        return NostrTransport(keychain: keychain, idBridge: NostrIdentityBridge(keychain: keychain), dependencies: dependencies)
    }

    func retainEndpoint(_ creation: NostrOutboundOwner.SourceEndpointCreation) throws -> NostrSourceDetachmentEndpoint {
        guard case .created(let endpoint) = creation else { throw DetachFixtureError("Genuine manual endpoint was refused") }
        manualEndpoints.append(endpoint)
        return endpoint
    }

    /// Finite fixture work only. Source cancellation/removal is never a handler/Task join.
    func finishKnownWork() async throws {
        try await ledger.drain()
        for transport in transports { _ = transport.isPeerReachable(peer) }
        let state = owner.provenanceSnapshot()
        try detachRequire(state.tasks.allSatisfy { $0.registration == .handleRegistered || $0.registration == .supervisorJoined },
                          "A completed actual Task has no registered handle")
        try detachRequire(state.debts.isEmpty && state.unconfirmedHandleCount == 0, "Unexpected registration debt")
        let batch = owner.taskBatchSnapshot()
        let joined = try await owner.joinTaskBatch(batch)
        try detachRequire(joined.ownerID === owner.id && joined.batchID === batch.id && joined.taskIDs == batch.taskIDs,
                          "Actual batch identity changed")
        try detachRequire(owner.provenanceSnapshot().waiters.isEmpty && installer.activeCount == 0, "Actual installer remains pending")
        try detachRequire(owner.sourceLedgerSnapshot().faults.isEmpty, "Unexpected old source protocol fault")
        try detachRequire(errors.read().isEmpty, errors.read().joined(separator: "; "))
    }

    func cleanup() async -> [String] {
        var failures: [String] = []
        scheduler.releaseAll()
        do { try await detachCheckpoint(ackQueue) } catch { failures.append("ACK queue: \(error)") }
        do { try await finishKnownWork() } catch { failures.append("Known work: \(error)") }
        scheduler.releaseAll()
        do { try await ledger.drain() }
        catch { failures.append("Late actual Task/observer joins: \(error)") }
        for transport in transports { _ = transport.isPeerReachable(peer) }
        do { try await detachCheckpoint(ackQueue) }
        catch { failures.append("Late ACK checkpoint: \(error)") }
        if scheduler.count != 0 { failures.append("Owned scheduler action remains pending") }
        if installer.activeCount != 0 || !owner.provenanceSnapshot().waiters.isEmpty { failures.append("Actual continuation remains pending") }
        if !errors.read().isEmpty { failures.append(contentsOf: errors.read()) }
        // Policy observations were copied before these ordinary lifecycle releases.
        transports.removeAll()
        manualEndpoints.removeAll()
        publishers.removeAll()
        if !errors.read().isEmpty { failures.append(contentsOf: errors.read()) }
        return failures
    }
}

private func detachGap(_ result: NostrOutboundOwner.SourceDetachmentRequestResult,
                       _ expected: NostrOutboundOwner.SourceDetachmentGap) -> Bool {
    if case .unconfirmed(let gap) = result { return gap == expected }
    return false
}
private func detachBinding(_ result: NostrOutboundOwner.SourceEndpointBindingResult) throws -> NostrOutboundOwner.Identity {
    guard case .bound(let bindingID) = result else { throw DetachFixtureError("Genuine source endpoint did not bind") }
    return bindingID
}
private func detachBindingFault(_ result: NostrOutboundOwner.SourceEndpointBindingResult) -> Bool {
    if case .protocolFault = result { return true }
    return false
}
private func detachFinishFault(_ result: NostrOutboundOwner.SourceEndpointBindingFinish) -> Bool {
    if case .protocolFault = result { return true }
    return false
}
private func detachSource(_ owner: NostrOutboundOwner, kind: NostrOutboundOwner.SourceKind) throws -> NostrOutboundOwner.SourceInstallation {
    guard case .accepted(let source) = owner.beginSourceInstallation(kind: kind) else {
        throw DetachFixtureError("Open actual source was refused")
    }
    return source
}
private func detachRecorded(_ update: NostrOutboundOwner.SourceReceiptUpdate) -> Bool {
    if case .recorded = update { return true }
    return false
}
@MainActor
private func detachLiveClose(_ binding: NostrOutboundPanicBinding) throws -> NostrOutboundOwner.RootCloseReceipt {
    let live = PanicNetworkLifecycle.live
    guard case .closed(let receipt) = live.closeInstalledNostrRoots(binding) else {
        throw DetachFixtureError("Actual isolated live close did not return its original root receipt")
    }
    return receipt
}
private func expectDetachReturned(_ snapshot: NostrOutboundOwner.SourceDetachmentSnapshot,
                                  receipt: NostrOutboundOwner.RootCloseReceipt, count: Int) throws {
    #expect(snapshot.ownerID === receipt.ownerID && snapshot.closeReceipt === receipt)
    #expect(snapshot.rows.count == count && snapshot.faults.isEmpty)
    #expect(Set(snapshot.rows.compactMap(\.claimID)).count == count)
    #expect(snapshot.rows.allSatisfy {
        $0.closeReceipt === receipt && $0.requestID === snapshot.requestID && $0.binding == .ready &&
        $0.availability == .present && $0.invocation == .invocationReturned
    })
}

@MainActor
private func detachDependencies(owner: NostrOutboundOwner, pacer: NostrTransport.AckPacer,
                                notifications: NotificationCenter, errors: DetachLocked<[String]>,
                                loadFavorites: @escaping @MainActor () -> [Data: FavoritesPersistenceService.FavoriteRelationship],
                                relay: @escaping @MainActor () -> AnyPublisher<Bool, Never>,
                                recipients: (@MainActor () -> AnyPublisher<[PeerID: String], Never>)? = nil,
                                online: (@MainActor () -> AnyPublisher<Bool, Never>)? = nil) -> NostrTransport.Dependencies {
    let blockCheck: (@MainActor (Data) -> Bool)?
    if recipients == nil { blockCheck = nil } else { blockCheck = { _ in false } }
    return NostrTransport.Dependencies(outboundOwner: owner, notificationCenter: notifications, loadFavorites: loadFavorites,
        favoriteStatusForNoiseKey: { _ in errors.update { $0.append("Unexpected favorite key lookup") }; return nil },
        favoriteStatusForPeerID: { _ in errors.update { $0.append("Unexpected favorite peer lookup") }; return nil },
        currentIdentity: { errors.update { $0.append("Unexpected identity provider") }; return nil },
        registerPendingGiftWrap: { _ in errors.update { $0.append("Unexpected crypto registration") } },
        sendEvent: { _ in errors.update { $0.append("Unexpected crypto send") } },
        scheduleAfter: { _, _ in errors.update { $0.append("Unexpected dependency scheduler") } },
        relayConnectivity: relay, ackPacer: pacer, weshRecipients: recipients, weshOnline: online, weshIsBlocked: blockCheck)
}

private func detachFavorites() -> [Data: FavoritesPersistenceService.FavoriteRelationship] {
    let noise = Data(repeating: 0x11, count: 32)
    let relationship = FavoritesPersistenceService.FavoriteRelationship(peerNoisePublicKey: noise, peerNostrPublicKey: "synthetic-npub",
        peerNickname: "Synthetic", isFavorite: true, theyFavoritedUs: true,
        favoritedAt: Date(timeIntervalSince1970: 1), lastUpdated: Date(timeIntervalSince1970: 2))
    return [noise: relationship]
}

private struct DetachInlineRecipients: Publisher {
    typealias Output = [PeerID: String]
    typealias Failure = Never
    let value: Output
    let afterEmission: () -> Void
    func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Never {
        subscriber.receive(subscription: DetachInlineSubscription(subscriber: subscriber, value: value, afterEmission: afterEmission))
    }
}

private final class DetachInlineSubscription<S: Subscriber>: Subscription where S.Input == [PeerID: String], S.Failure == Never {
    private let mutex = NSLock()
    private var subscriber: S?
    private var afterEmission: (() -> Void)?
    private let value: [PeerID: String]
    private var sent = false
    init(subscriber: S, value: [PeerID: String], afterEmission: @escaping () -> Void) {
        self.subscriber = subscriber; self.value = value; self.afterEmission = afterEmission
    }
    func request(_ demand: Subscribers.Demand) {
        guard demand > .none else { return }
        let output: (S, () -> Void)? = {
            mutex.lock(); defer { mutex.unlock() }
            guard !sent, let subscriber, let afterEmission else { return nil }
            sent = true
            return (subscriber, afterEmission)
        }()
        guard let (subscriber, afterEmission) = output else { return }
        _ = subscriber.receive(value)
        afterEmission()
    }
    func cancel() {
        mutex.lock(); subscriber = nil; afterEmission = nil; mutex.unlock()
    }
}

@MainActor
private func withDetachFixture<T>(_ detach: (DetachFixture) async throws -> T) async throws -> T {
    let fixture = DetachFixture()
    var result: T?
    var primary: Error?
    do { result = try await detach(fixture) } catch { primary = error }
    let cleanup = await fixture.cleanup()
    if let primary {
        if cleanup.isEmpty { throw primary }
        throw DetachCleanupFailure(primary: primary, cleanup: cleanup)
    }
    try detachRequire(cleanup.isEmpty, cleanup.joined(separator: "; "))
    guard let result else { throw DetachFixtureError("Owned fixture lost its completed result") }
    return result
}

private func detachRequire(_ condition: Bool, _ message: String) throws {
    if !condition { throw DetachFixtureError(message) }
}

@MainActor
private func detachEventually(fileID: StaticString = #fileID, line: UInt = #line, _ condition: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !condition() {
        if clock.now >= deadline { throw DetachFixtureError("Owned completion checkpoint expired at \(fileID):\(line)") }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
private func detachCheckpoint(_ queue: DispatchQueue) async throws {
    let done = DetachLocked(false)
    queue.async { done.update { $0 = true } }
    var guardError: Error?
    do { try await detachEventually { done.read() } }
    catch { guardError = error }
    queue.sync {}
    if let guardError { throw guardError }
}
