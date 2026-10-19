import BitFoundation
import Combine
import Foundation
import Testing
@testable import bitchat

/// Real injected callbacks and isolated owners; no live graph, keys or product stores.
@MainActor
struct NostrCallbackBodyAdmissionTests {
    @Test
    func recipientsAfterOriginalCloseCannotReplaceActualReachableContacts() async throws {
        let result = try await withBodyFixture { f in
            let box = BodyPublishers()
            let transport = f.makeWesh(box)
            box.recipients.send([f.peer: "synthetic-old"])
            box.online.send(true)
            try await f.finishKnownWork()
            try bodyRequire(transport.isPeerReachable(f.peer) && !transport.isPeerReachable(f.otherPeer), "Initial recipients were not observed")
            let before = f.owner.sourceBodyAdmissionSnapshot().rows.count
            let receipt = try f.close(transport)
            box.recipients.send([f.otherPeer: "synthetic-new"])
            let policy = transport.isPeerReachable(f.peer) && !transport.isPeerReachable(f.otherPeer)
            try await f.finishKnownWork()
            return try f.policyObservation(policy, before: before, receipt: receipt, kind: .weshRecipients)
        }
        try #require(result.policy, "A post-close recipients callback replaced the actual contact map")
        try expectBodyRefusal(result)
    }

    @Test
    func onlineAfterOriginalCloseCannotEnableActualReachability() async throws {
        let result = try await withBodyFixture { f in
            let box = BodyPublishers()
            let transport = f.makeWesh(box)
            box.recipients.send([f.peer: "synthetic-contact"])
            box.online.send(false)
            try await f.finishKnownWork()
            try bodyRequire(!transport.isPeerReachable(f.peer), "Initial offline state was not observed")
            let before = f.owner.sourceBodyAdmissionSnapshot().rows.count
            let receipt = try f.close(transport)
            box.online.send(true)
            let policy = !transport.isPeerReachable(f.peer)
            try await f.finishKnownWork()
            return try f.policyObservation(policy, before: before, receipt: receipt, kind: .weshOnline)
        }
        try #require(result.policy, "A post-close online callback enabled actual reachability")
        try expectBodyRefusal(result)
    }

    @Test
    func weshRelayAfterOriginalCloseCannotEnablePromptDelivery() async throws {
        let result = try await withBodyFixture { f in
            let box = BodyPublishers()
            let transport = f.makeWesh(box)
            box.recipients.send([f.peer: "synthetic-contact"])
            box.online.send(true)
            box.relay.send(false)
            try await f.finishKnownWork()
            try bodyRequire(transport.isPeerReachable(f.peer) && !transport.canDeliverPromptly(to: f.peer), "Initial Wesh relay state was not observed")
            let before = f.owner.sourceBodyAdmissionSnapshot().rows.count
            let receipt = try f.close(transport)
            box.relay.send(true)
            let policy = !transport.canDeliverPromptly(to: f.peer)
            try await f.finishKnownWork()
            return try f.policyObservation(policy, before: before, receipt: receipt, kind: .weshRelayConnectivity)
        }
        try #require(result.policy, "A post-close Wesh relay callback enabled prompt delivery")
        try expectBodyRefusal(result)
    }

    @Test
    func legacyRelayAfterOriginalCloseCannotEnablePromptDelivery() async throws {
        let result = try await withBodyFixture { f in
            let transport = f.makeLegacy(withFavorite: true)
            try await f.finishKnownWork()
            try bodyRequire(transport.isPeerReachable(f.peer) && !transport.canDeliverPromptly(to: f.peer), "Initial legacy relay state was not observed")
            let before = f.owner.sourceBodyAdmissionSnapshot().rows.count
            let receipt = try f.close(transport)
            f.legacyRelay.send(true)
            let policy = !transport.canDeliverPromptly(to: f.peer)
            try await f.finishKnownWork()
            return try f.policyObservation(policy, before: before, receipt: receipt, kind: .legacyRelayConnectivity)
        }
        try #require(result.policy, "A post-close legacy relay callback enabled prompt delivery")
        try expectBodyRefusal(result)
    }

    @Test
    func freshPublisherAndFavoriteCallbacksRetainTheirActualEffects() async throws {
        let result = try await withBodyFixture { f in
            let box = BodyPublishers()
            let wesh = f.makeWesh(box)
            let legacy = f.makeLegacy(withFavorite: true)
            box.recipients.send([f.peer: "synthetic-contact"])
            box.online.send(true)
            box.relay.send(true)
            f.legacyRelay.send(true)
            f.notifications.post(name: .favoriteStatusChanged, object: nil)
            try await f.finishKnownWork()
            return (wesh.canDeliverPromptly(to: f.peer), legacy.canDeliverPromptly(to: f.peer),
                    f.favoriteLoads.read(), f.creators.read(), f.owner.sourceBodyAdmissionSnapshot(), f.owner.provenanceSnapshot(),
                    f.owner.sourceLedgerSnapshot().faults)
        }
        #expect(result.0 && result.1)
        #expect(result.2 == 2)
        #expect(result.3 == 1)
        #expect(result.4.rows.count == 5)
        #expect(result.4.rows.allSatisfy { $0.decision == .accepted && $0.permitID != nil && $0.closeReceipt == nil })
        #expect(result.4.rows.filter { $0.writeID != nil }.count == 4)
        #expect(result.5.tasks.count == 1 && result.5.callbacks.count == 1)
        #expect(result.5.tasks.first?.registration == .supervisorJoined)
        #expect(result.6.isEmpty)
    }

    @Test
    func acceptedBodyBeforeCloseCanReserveItsExactWriteOnceAfterClose() async throws {
        let result = try await withBodyFixture { f in
            let source = f.owner.beginSourceInstallation(kind: .weshRecipients)
            f.owner.noteSourceInstallationReturned(source)
            let event = try bodyEvent(f.owner, source)
            let permit = try bodyPermit(f.owner, event)
            let permitID = permit.id
            _ = try bodyClose(f.owner.captureOutboundPanicBinding())
            let write = try bodyWrite(f.owner, kind: .weshRecipientsState, permit: permit)
            let repeated: Bool
            if case .protocolFault = f.owner.reserveAdmittedSourceWrite(kind: .weshRecipientsState, permit: permit) {
                repeated = true
            } else { repeated = false }
            f.owner.sourceWriteEntered(write)
            f.owner.noteSourceWriteBodyEnd(write)
            f.owner.noteSourceEventBodyEnd(event)
            return (f.owner.sourceBodyAdmissionSnapshot(), permitID, write.id, repeated,
                    f.owner.sourceLedgerSnapshot().faults)
        }
        let row = try #require(result.0.rows.first)
        #expect(result.0.rows.count == 1)
        #expect(row.ownerID === result.0.ownerID)
        #expect(row.decision == .accepted && row.closeReceipt == nil)
        #expect(row.permitID === result.1 && row.writeID === result.2)
        #expect(row.permitID !== row.eventID && row.permitID !== row.sourceID && row.permitID !== row.ownerID)
        #expect(result.3)
        #expect(result.4 == [.repeatedBodyWrite])
        // This is an actual reservation control, not a held private-queue execution claim.
    }

    @Test
    func favoriteAfterCloseStillUsesExistingRootTaskRefusal() async throws {
        let result = try await withBodyFixture { f in
            let transport = f.makeLegacy(withFavorite: true)
            let before = f.favoriteLoads.read()
            _ = try f.close(transport)
            f.notifications.post(name: .favoriteStatusChanged, object: nil)
            try await f.finishKnownWork()
            return (transport.isPeerReachable(f.peer), f.favoriteLoads.read() == before,
                    f.creators.read(), f.owner.provenanceSnapshot(), f.owner.sourceLedgerSnapshot())
        }
        #expect(result.0 && result.1)
        #expect(result.2 == 0)
        #expect(result.3.tasks.isEmpty && result.3.callbacks.isEmpty)
        #expect(result.4.events.count == 1 && result.4.taskEdges.isEmpty)
        #expect(result.4.faults.isEmpty)
        // No new body-refusal expectation: the baseline's existing root gate already prevents the Task.
    }

    @Test
    func inlineInitialEventCanBeAdmittedBeforeInstallationReturns() async throws {
        let result = try await withBodyFixture { f in
            let box = BodyPublishers()
            let observed = BodyLocked<[(NostrOutboundOwner.SourceLedgerSnapshot, NostrOutboundOwner.SourceBodyAdmissionSnapshot)]>([])
            let owner = f.owner
            let publisher = BodyInlineRecipients(value: [f.peer: "synthetic-inline"], afterEmission: {
                observed.update { $0.append((owner.sourceLedgerSnapshot(), owner.sourceBodyAdmissionSnapshot())) }
            })
            let transport = f.makeWesh(box, recipients: { publisher.eraseToAnyPublisher() })
            box.online.send(true)
            try await f.finishKnownWork()
            try bodyRequire(observed.read().count == 1, "Inline publisher did not report its actual emission")
            return (observed.read()[0], transport.isPeerReachable(f.peer))
        }
        let source = try #require(result.0.0.sources.first)
        let event = try #require(result.0.0.events.first)
        let row = try #require(result.0.1.rows.first)
        #expect(source.installation == .installing)
        #expect(event.sourceID === source.id && event.state == .bodyEndRecorded)
        #expect(row.sourceID === source.id && row.eventID === event.id)
        #expect(row.decision == .accepted && row.permitID != nil && row.writeID != nil)
        #expect(result.1)
        #expect(result.0.0.faults.isEmpty)
    }

    @Test
    func sameOwnerTransportsRetainDistinctSourcesAndOriginalCloseReceipt() async throws {
        let result = try await withBodyFixture { f in
            let first = f.makeLegacy()
            let second = f.makeLegacy()
            let firstReceipt = try f.close(first)
            let secondReceipt = try f.close(second)
            return (f.owner.sourceLedgerSnapshot(), firstReceipt, secondReceipt)
        }
        #expect(result.0.sources.count == 4)
        #expect(Set(result.0.sources.map(\.id)).count == 4)
        #expect(result.0.sources.allSatisfy { $0.installation == .installationReturned })
        #expect(result.1 === result.2)
        #expect(result.1.ownerID === result.0.ownerID)
    }

    @Test
    func foreignReplayAndWrongKindCannotLaunderBodyWriteAuthority() async throws {
        let result = try await withBodyFixture { first in
            try await withBodyFixture { second in
                let source = first.owner.beginSourceInstallation(kind: .weshOnline)
                let event = try bodyEvent(first.owner, source)
                let permit = try bodyPermit(first.owner, event)
                let foreignEvent = bodyAdmissionRejected(second.owner.admitBody(event))
                let foreignPermit = bodyWriteRejected(second.owner.reserveAdmittedSourceWrite(kind: .weshOnlineState, permit: permit))
                let replay = bodyAdmissionRejected(first.owner.admitBody(event))
                let wrongKind = bodyWriteRejected(first.owner.reserveAdmittedSourceWrite(kind: .weshRecipientsState, permit: permit))
                let write = try bodyWrite(first.owner, kind: .weshOnlineState, permit: permit)
                let repeated = bodyWriteRejected(first.owner.reserveAdmittedSourceWrite(kind: .weshOnlineState, permit: permit))
                first.owner.sourceWriteEntered(write)
                first.owner.noteSourceWriteBodyEnd(write)
                first.owner.noteSourceEventBodyEnd(event)
                let ended = bodyWriteRejected(first.owner.reserveAdmittedSourceWrite(kind: .weshOnlineState, permit: permit))
                return ([foreignEvent, foreignPermit, replay, wrongKind, repeated, ended],
                        first.owner.sourceBodyAdmissionSnapshot(), first.owner.sourceLedgerSnapshot().faults,
                        second.owner.sourceBodyAdmissionSnapshot(), second.owner.sourceLedgerSnapshot().faults)
            }
        }
        #expect(result.0.allSatisfy { $0 })
        #expect(result.1.rows.count == 1 && result.1.rows.first?.writeID != nil)
        #expect(result.2 == [.repeatedBodyAdmission, .invalidBodyWriteKind, .repeatedBodyWrite, .invalidBodyPermit])
        #expect(result.3.rows.isEmpty)
        #expect(result.4 == [.invalidBodyAdmission, .invalidBodyPermit])
    }
}

private struct BodyFixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct BodyCleanupFailure: Error, CustomStringConvertible {
    let primary: Error
    let cleanup: [String]
    var description: String { "primary: \(primary); cleanup: \(cleanup.joined(separator: "; "))" }
}

private struct BodyPolicyObservation {
    let policy: Bool
    let before: Int
    let receipt: NostrOutboundOwner.RootCloseReceipt
    let snapshot: NostrOutboundOwner.SourceBodyAdmissionSnapshot
    let ledger: NostrOutboundOwner.SourceLedgerSnapshot
    let sourceKind: NostrOutboundOwner.SourceKind
}

private func expectBodyRefusal(_ result: BodyPolicyObservation) throws {
    #expect(result.snapshot.rows.count == result.before + 1)
    let row = try #require(result.snapshot.rows.last)
    #expect(row.ownerID === result.snapshot.ownerID)
    #expect(row.decision == .refusedBeforeRoot)
    #expect(row.closeReceipt === result.receipt)
    #expect(row.permitID == nil && row.writeID == nil)
    #expect(row.sourceID !== row.eventID)
    #expect(row.ownerID === result.receipt.ownerID)
    let source = try #require(result.ledger.sources.first { $0.id === row.sourceID })
    let event = try #require(result.ledger.events.first { $0.id === row.eventID })
    #expect(source.kind == result.sourceKind)
    #expect(event.sourceID === source.id && event.state == .bodyEndRecorded)
    #expect(result.ledger.writes.allSatisfy { $0.eventID !== event.id })
}

private func bodyAdmissionRejected(_ result: NostrOutboundOwner.SourceBodyAdmission) -> Bool {
    if case .protocolFault = result { return true }
    return false
}

private func bodyWriteRejected(_ result: NostrOutboundOwner.AdmittedSourceWriteReservation) -> Bool {
    if case .protocolFault = result { return true }
    return false
}

private func bodyEvent(_ owner: NostrOutboundOwner, _ source: NostrOutboundOwner.SourceInstallation) throws -> NostrOutboundOwner.SourceEventTicket {
    guard let event = owner.sourceEventEntered(source) else { throw BodyFixtureError("Actual source did not create its wrapper event") }
    return event
}

private func bodyPermit(_ owner: NostrOutboundOwner, _ event: NostrOutboundOwner.SourceEventTicket) throws -> NostrOutboundOwner.SourceEventBodyPermit {
    guard case .accepted(let permit) = owner.admitBody(event) else { throw BodyFixtureError("Valid baseline body was not admitted") }
    return permit
}

private func bodyWrite(_ owner: NostrOutboundOwner, kind: NostrOutboundOwner.SourceWriteKind,
                       permit: NostrOutboundOwner.SourceEventBodyPermit) throws -> NostrOutboundOwner.SourceWriteTicket {
    guard case .reserved(let write) = owner.reserveAdmittedSourceWrite(kind: kind, permit: permit) else {
        throw BodyFixtureError("Accepted exact-kind body did not reserve its write")
    }
    return write
}

private func bodyClose(_ binding: NostrOutboundPanicBinding) throws -> NostrOutboundOwner.RootCloseReceipt {
    guard case .closed(let receipt) = closeCapturedNostrOutboundRoots(binding) else {
        throw BodyFixtureError("Actual isolated original binding did not close")
    }
    return receipt
}

private final class BodyLocked<Value>: @unchecked Sendable {
    private let mutex = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { mutex.lock(); defer { mutex.unlock() }; return value }
    @discardableResult func update<Result>(_ action: (inout Value) -> Result) -> Result {
        mutex.lock(); defer { mutex.unlock() }; return action(&value)
    }
}

private final class BodyTaskLedger: @unchecked Sendable {
    private struct Row { let task: Task<Void, Never>; let observer: Task<Void, Never>; let finished: BodyLocked<Bool> }
    private let rows = BodyLocked<[Row]>([])
    func track(_ task: Task<Void, Never>) {
        let finished = BodyLocked(false)
        let observer = Task { await task.value; finished.update { $0 = true } }
        rows.update { $0.append(Row(task: task, observer: observer, finished: finished)) }
    }
    func drain() async throws {
        var readinessErrors: [Error] = []
        var index = 0
        while index < rows.read().count {
            let row = rows.read()[index]
            do { try await bodyEventually { row.finished.read() } }
            catch { readinessErrors.append(error) }
            // A readiness failure never replaces either actual join or skips finite children.
            await row.task.value
            await row.observer.value
            index += 1
        }
        guard let first = readinessErrors.first else { return }
        if readinessErrors.count == 1 { throw first }
        throw BodyCleanupFailure(primary: first, cleanup: readinessErrors.dropFirst().map { String(describing: $0) })
    }
}

private final class BodyInstaller: @unchecked Sendable {
    private let count = BodyLocked(0)
    var activeCount: Int { count.read() }
    func install(_ action: @escaping @Sendable () -> Void) {
        count.update { $0 += 1 }
        defer { count.update { $0 -= 1 } }
        action()
    }
}

private final class BodyScheduler: @unchecked Sendable {
    private let pending = BodyLocked<[@Sendable () -> Void]>([])
    var count: Int { pending.read().count }
    func submit(_ action: @escaping @Sendable () -> Void) { pending.update { $0.append(action) } }
    func releaseAll() {
        let actions = pending.update { let copy = $0; $0.removeAll(); return copy }
        actions.forEach { $0() }
    }
}

private final class BodyPublishers: @unchecked Sendable {
    let recipients = PassthroughSubject<[PeerID: String], Never>()
    let online = PassthroughSubject<Bool, Never>()
    let relay = PassthroughSubject<Bool, Never>()
}

@MainActor
private final class BodyFixture {
    let owner: NostrOutboundOwner
    let pacer: NostrTransport.AckPacer
    let notifications = NotificationCenter()
    let legacyRelay = PassthroughSubject<Bool, Never>()
    let peer = PeerID(publicKey: Data(repeating: 0x11, count: 32))
    let otherPeer = PeerID(publicKey: Data(repeating: 0x22, count: 32))
    let favoriteLoads = BodyLocked(0)
    let creators: BodyLocked<Int>
    let errors = BodyLocked<[String]>([])
    private let ledger: BodyTaskLedger
    private let installer: BodyInstaller
    private let scheduler: BodyScheduler
    private let ackQueue: DispatchQueue
    private var transports: [NostrTransport] = []
    private var publishers: [BodyPublishers] = []

    init() {
        let ledger = BodyTaskLedger()
        let installer = BodyInstaller()
        let creators = BodyLocked(0)
        let scheduler = BodyScheduler()
        let ackQueue = DispatchQueue(label: "synthetic.callback-body.serial-ack")
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

    func makeLegacy(withFavorite: Bool = false) -> NostrTransport {
        let loads = favoriteLoads
        let relay = legacyRelay
        let favorites = withFavorite ? bodyFavorites() : [:]
        let dependencies = bodyDependencies(owner: owner, pacer: pacer, notifications: notifications, errors: errors,
            loadFavorites: { loads.update { $0 += 1 }; return favorites }, relay: { relay.eraseToAnyPublisher() })
        return retainTransport(dependencies)
    }

    func makeWesh(_ box: BodyPublishers,
                  recipients: (@MainActor () -> AnyPublisher<[PeerID: String], Never>)? = nil) -> NostrTransport {
        publishers.append(box)
        let loads = favoriteLoads
        let errors = self.errors
        let dependencies = bodyDependencies(owner: owner, pacer: pacer, notifications: notifications, errors: errors,
            loadFavorites: { loads.update { $0 += 1 }; errors.update { $0.append("Wesh loaded favorites") }; return [:] },
            relay: { box.relay.eraseToAnyPublisher() }, recipients: recipients ?? { box.recipients.eraseToAnyPublisher() },
            online: { box.online.eraseToAnyPublisher() })
        return retainTransport(dependencies)
    }

    private func retainTransport(_ dependencies: NostrTransport.Dependencies) -> NostrTransport {
        let keychain = MockKeychain()
        let transport = NostrTransport(keychain: keychain, idBridge: NostrIdentityBridge(keychain: keychain), dependencies: dependencies)
        transports.append(transport)
        return transport
    }

    func close(_ transport: NostrTransport) throws -> NostrOutboundOwner.RootCloseReceipt {
        let binding = transport.captureOutboundPanicBinding()
        try bodyRequire(binding.ownerID === owner.id, "Transport changed original owner")
        return try bodyClose(binding)
    }

    func policyObservation(_ policy: Bool, before: Int, receipt: NostrOutboundOwner.RootCloseReceipt,
                           kind: NostrOutboundOwner.SourceKind) throws -> BodyPolicyObservation {
        let ledger = owner.sourceLedgerSnapshot()
        try bodyRequire(ledger.faults.isEmpty, "Unexpected source protocol fault before policy assertion")
        return BodyPolicyObservation(policy: policy, before: before, receipt: receipt,
            snapshot: owner.sourceBodyAdmissionSnapshot(), ledger: ledger, sourceKind: kind)
    }

    /// Finite fixture work only; this is not a complete source census or global drain.
    func finishKnownWork() async throws {
        try await ledger.drain()
        for transport in transports { _ = transport.isPeerReachable(peer) }
        let state = owner.provenanceSnapshot()
        try bodyRequire(state.tasks.allSatisfy { $0.registration == .handleRegistered || $0.registration == .supervisorJoined },
                        "A completed owned Task has no registered handle")
        try bodyRequire(state.debts.isEmpty && state.unconfirmedHandleCount == 0, "Unexpected registration debt")
        let batch = owner.taskBatchSnapshot()
        let joined = try await owner.joinTaskBatch(batch)
        try bodyRequire(joined.ownerID === owner.id && joined.batchID === batch.id && joined.taskIDs == batch.taskIDs,
                        "Actual batch identity changed")
        try bodyRequire(owner.provenanceSnapshot().waiters.isEmpty && installer.activeCount == 0, "Actual installer remains pending")
        try bodyRequire(owner.provenanceSnapshot().debts.isEmpty, "Unexpected old-work protocol debt")
        try bodyRequire(errors.read().isEmpty, errors.read().joined(separator: "; "))
    }

    func cleanup() async -> [String] {
        var failures: [String] = []
        scheduler.releaseAll()
        do { try await bodyCheckpoint(ackQueue) } catch { failures.append("ACK queue: \(error)") }
        do { try await finishKnownWork() } catch { failures.append("Known work: \(error)") }
        scheduler.releaseAll()
        do { try await ledger.drain() }
        catch { failures.append("Late actual Task/observer cleanup: \(error)") }
        for transport in transports { _ = transport.isPeerReachable(peer) }
        do { try await bodyCheckpoint(ackQueue) }
        catch { failures.append("Late ACK queue cleanup: \(error)") }
        if scheduler.count != 0 { failures.append("Owned scheduler action remains pending") }
        if installer.activeCount != 0 || !owner.provenanceSnapshot().waiters.isEmpty { failures.append("Actual continuation remains pending") }
        if !errors.read().isEmpty { failures.append(contentsOf: errors.read()) }
        transports.removeAll()
        publishers.removeAll()
        return failures
    }
}

@MainActor
private func bodyDependencies(owner: NostrOutboundOwner, pacer: NostrTransport.AckPacer,
                              notifications: NotificationCenter, errors: BodyLocked<[String]>,
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

private func bodyFavorites() -> [Data: FavoritesPersistenceService.FavoriteRelationship] {
    let noise = Data(repeating: 0x11, count: 32)
    let relationship = FavoritesPersistenceService.FavoriteRelationship(peerNoisePublicKey: noise, peerNostrPublicKey: "synthetic-npub",
        peerNickname: "Synthetic", isFavorite: true, theyFavoritedUs: true,
        favoritedAt: Date(timeIntervalSince1970: 1), lastUpdated: Date(timeIntervalSince1970: 2))
    return [noise: relationship]
}

private struct BodyInlineRecipients: Publisher {
    typealias Output = [PeerID: String]
    typealias Failure = Never
    let value: Output
    let afterEmission: () -> Void
    func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Never {
        subscriber.receive(subscription: BodyInlineSubscription(subscriber: subscriber, value: value, afterEmission: afterEmission))
    }
}

private final class BodyInlineSubscription<S: Subscriber>: Subscription where S.Input == [PeerID: String], S.Failure == Never {
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
private func withBodyFixture<T>(_ body: (BodyFixture) async throws -> T) async throws -> T {
    let fixture = BodyFixture()
    var result: T?
    var primary: Error?
    do { result = try await body(fixture) } catch { primary = error }
    let cleanup = await fixture.cleanup()
    if let primary {
        if cleanup.isEmpty { throw primary }
        throw BodyCleanupFailure(primary: primary, cleanup: cleanup)
    }
    try bodyRequire(cleanup.isEmpty, cleanup.joined(separator: "; "))
    guard let result else { throw BodyFixtureError("Owned fixture lost its completed result") }
    return result
}

private func bodyRequire(_ condition: Bool, _ message: String) throws {
    if !condition { throw BodyFixtureError(message) }
}

private func bodyEventually(fileID: StaticString = #fileID, line: UInt = #line, _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !condition() {
        if clock.now >= deadline { throw BodyFixtureError("Owned completion checkpoint expired at \(fileID):\(line)") }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
}

private func bodyCheckpoint(_ queue: DispatchQueue) async throws {
    let done = BodyLocked(false)
    queue.async { done.update { $0 = true } }
    try await bodyEventually { done.read() }
}
