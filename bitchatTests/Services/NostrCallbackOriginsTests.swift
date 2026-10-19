import BitFoundation
import Combine
import Foundation
import Testing
@testable import bitchat

/// Separate source receipts with real injected subscriptions; no live graph or key providers.
@MainActor
struct NostrCallbackOriginsTests {
    @Test
    func legacyTransportInstallsObserverAndRelaySourcesWithoutOldWorkRows() async throws {
        try await withCallbackFixture { f in
            let transport = f.makeLegacy()
            let state = f.owner.sourceLedgerSnapshot()
            #expect(state.ownerID === f.owner.id)
            #expect(state.sources.map(\.kind) == [.legacyFavoriteObserver, .legacyRelayConnectivity])
            #expect(Set(state.sources.map(\.id)).count == 2)
            #expect(state.sources.allSatisfy { $0.installation == .installationReturned })
            #expect(state.events.isEmpty)
            #expect(state.writes.isEmpty)
            #expect(state.taskEdges.isEmpty)
            #expect(f.favoriteLoads.read() == 1)
            try expectNoOldWork(f.owner)
            _ = transport.isPeerReachable(f.peer)
        }
    }

    @Test
    func weshTransportInstallsOnlyItsActualThreePublishers() async throws {
        try await withCallbackFixture { f in
            let box = CallbackPublisherBox()
            let transport = f.makeWesh(box)
            let state = f.owner.sourceLedgerSnapshot()
            #expect(state.sources.map(\.kind) == [.weshRecipients, .weshOnline, .weshRelayConnectivity])
            #expect(state.sources.allSatisfy { $0.installation == .installationReturned })
            #expect(state.events.isEmpty)
            #expect(state.writes.isEmpty)
            #expect(f.favoriteLoads.read() == 0)
            try expectNoOldWork(f.owner)
            _ = transport.isPeerReachable(f.peer)
        }
        try await withCallbackFixture { f in
            let box = CallbackPublisherBox()
            let transport = f.makeWesh(box, includeOnline: false)
            #expect(f.owner.sourceLedgerSnapshot().sources.map(\.kind) == [.weshRecipients, .weshRelayConnectivity])
            #expect(f.favoriteLoads.read() == 0)
            try expectNoOldWork(f.owner)
            _ = transport.isPeerReachable(f.peer)
        }
    }

    @Test
    func currentValueEventIsRecordedBeforeItsInstallationReturns() async throws {
        try await withCallbackFixture { f in
            let observed = CallbackLocked<[NostrOutboundOwner.SourceLedgerSnapshot]>([])
            let owner = f.owner
            let box = CallbackPublisherBox()
            let publisher = InlineRecipientsPublisher(value: [f.peer: "synthetic-npub"], afterEmission: {
                observed.update { $0.append(owner.sourceLedgerSnapshot()) }
            })
            let transport = f.makeWesh(box, recipients: { publisher.eraseToAnyPublisher() })
            let inline = try #require(observed.read().first)
            #expect(observed.read().count == 1)
            let source = try #require(inline.sources.first)
            #expect(source.kind == .weshRecipients)
            #expect(source.installation == .installing)
            let event = try #require(inline.events.first)
            #expect(event.sourceID === source.id)
            #expect(event.state == .bodyEndRecorded)
            _ = transport.isPeerReachable(f.peer)
            let after = f.owner.sourceLedgerSnapshot()
            let retained = try #require(after.sources.first)
            #expect(retained.id === source.id)
            #expect(retained.installation == .installationReturned)
            #expect(after.events.first?.id === event.id)
            try expectWriteLineage(after, kind: .weshRecipientsState)
            try expectNoOldWork(f.owner)
        }
    }

    @Test
    func temporaryTransportsShareOwnerButNeverSourceRegistrationIdentity() async throws {
        try await withCallbackFixture { f in
            let first = f.makeLegacy()
            let before = f.owner.sourceLedgerSnapshot()
            let second = f.makeLegacy()
            let after = f.owner.sourceLedgerSnapshot()
            #expect(first.captureOutboundPanicBinding().ownerID === second.captureOutboundPanicBinding().ownerID)
            #expect(after.sources.count == 4)
            #expect(Set(after.sources.map(\.id)).count == 4)
            #expect(Array(after.sources.prefix(2)).map(\.id) == before.sources.map(\.id))
            #expect(after.sources.map(\.kind) == [.legacyFavoriteObserver, .legacyRelayConnectivity, .legacyFavoriteObserver, .legacyRelayConnectivity])
            #expect(f.favoriteLoads.read() == 2)
            try expectNoOldWork(f.owner)
            withExtendedLifetime(first) {}
            withExtendedLifetime(second) {}
        }
    }

    @Test
    func weshEventsRecordTheirActualQueuedStateWrites() async throws {
        try await withCallbackFixture { f in
            let box = CallbackPublisherBox()
            let transport = f.makeWesh(box)
            box.recipients.send([f.peer: "synthetic-npub"])
            box.online.send(true)
            box.relay.send(true)
            #expect(transport.isPeerReachable(f.peer))
            #expect(transport.canDeliverPromptly(to: f.peer))
            box.online.send(false)
            #expect(!transport.isPeerReachable(f.peer))
            #expect(!transport.canDeliverPromptly(to: f.peer))
            let state = f.owner.sourceLedgerSnapshot()
            #expect(state.events.count == 4)
            #expect(Set(state.events.map(\.id)).count == 4)
            #expect(state.writes.count == 4)
            #expect(Set(state.writes.map(\.id)).count == 4)
            try expectWriteLineage(state, kind: .weshRecipientsState)
            try expectWriteLineage(state, kind: .weshOnlineState, count: 2)
            try expectWriteLineage(state, kind: .weshRelayState)
            #expect(state.taskEdges.isEmpty)
            #expect(f.favoriteLoads.read() == 0)
            try expectNoOldWork(f.owner)
        }
    }

    @Test
    func legacyRelayEventRecordsItsActualQueuedStateWrite() async throws {
        try await withCallbackFixture { f in
            let transport = f.makeLegacy(withFavorite: true)
            #expect(transport.isPeerReachable(f.peer))
            #expect(!transport.canDeliverPromptly(to: f.peer))
            f.legacyRelay.send(true)
            #expect(transport.canDeliverPromptly(to: f.peer))
            f.legacyRelay.send(false)
            #expect(!transport.canDeliverPromptly(to: f.peer))
            let state = f.owner.sourceLedgerSnapshot()
            #expect(state.events.count == 2)
            #expect(state.events[0].id !== state.events[1].id)
            #expect(state.events[0].sourceID === state.events[1].sourceID)
            try expectWriteLineage(state, kind: .legacyRelayState, count: 2)
            #expect(state.taskEdges.isEmpty)
            try expectNoOldWork(f.owner)
        }
    }

    @Test
    func favoriteObserverLinksExistingRootTaskAndRefreshWrite() async throws {
        try await withCallbackFixture { f in
            let transport = f.makeLegacy(withFavorite: true)
            f.notifications.post(name: .favoriteStatusChanged, object: nil)
            try await f.finishKnownWork()
            #expect(transport.isPeerReachable(f.peer))
            let state = f.owner.sourceLedgerSnapshot()
            let old = f.owner.provenanceSnapshot()
            let task = try #require(old.tasks.first)
            let write = try #require(old.callbacks.first)
            let event = try #require(state.events.first)
            let edge = try #require(state.taskEdges.first)
            #expect(old.tasks.count == 1)
            #expect(old.callbacks.count == 1)
            #expect(task.kind == .refreshReachablePeers)
            #expect(task.parent == nil)
            #expect(task.registration == .supervisorJoined)
            #expect(write.kind == .refreshStateWrite)
            #expect(write.parent === task.id)
            #expect(write.state == .bodyReturned)
            #expect(edge.sourceID === event.sourceID)
            #expect(edge.eventID === event.id)
            #expect(edge.taskID === task.id)
            #expect(event.state == .bodyEndRecorded)
            #expect(state.writes.isEmpty)
            let result = closeCapturedNostrOutboundRoots(transport.captureOutboundPanicBinding())
            guard case .closed = result else { throw CallbackFixtureError("Original isolated owner did not close") }
            f.notifications.post(name: .favoriteStatusChanged, object: nil)
            try await f.finishKnownWork()
            let refused = f.owner.sourceLedgerSnapshot()
            #expect(refused.events.count == 2)
            #expect(refused.taskEdges.count == 1)
            #expect(f.owner.provenanceSnapshot().tasks.count == 1)
            #expect(f.owner.provenanceSnapshot().callbacks.count == 1)
            #expect(f.creators.read() == 1)
        }
    }

    @Test
    func deinitCancellationIsNotCallbackOrTaskCompletionProof() async throws {
        try await withCallbackFixture(holdBody: true) { f in
            let retainedB = f.makeLegacy()
            f.notifications.post(name: .favoriteStatusChanged, object: nil)
            try await callbackEventually { f.entered.read() == 1 && f.bodyGate.waitingCount == 1 }
            try callbackRequire(f.ledger.count == 1 && f.ledger.finishedCount == 0, "Actual B task was not held")
            let oldBefore = f.owner.provenanceSnapshot()
            let actualBTask = try #require(oldBefore.tasks.first)
            #expect(actualBTask.body == .notEntered)
            let box = CallbackPublisherBox()
            let (probe, returnedBox) = makeAndDropWeshTransport(owner: f.owner, pacer: f.pacer, publishers: box, errors: f.errors)
            #expect(returnedBox === box)
            try await callbackEventually { probe.value == nil && box.cancelCounts.read() == [1, 1, 1] }
            // Upstreams remain caller-owned: their release did not manufacture cancellation.
            #expect(f.bodyGate.waitingCount == 1)
            #expect(f.ledger.finishedCount == 0)
            #expect(f.creators.read() == 1)
            let beforeRelease = f.owner.sourceLedgerSnapshot()
            let aSources = beforeRelease.sources.filter { [.weshRecipients, .weshOnline, .weshRelayConnectivity].contains($0.kind) }
            #expect(aSources.count == 3)
            #expect(aSources.allSatisfy { $0.installation == .installationReturned })
            #expect(beforeRelease.events.count == 1)
            #expect(beforeRelease.writes.isEmpty)
            f.bodyGate.open()
            try await f.finishKnownWork()
            _ = retainedB.isPeerReachable(f.peer)
            let after = f.owner.sourceLedgerSnapshot()
            let event = try #require(after.events.first)
            let edge = try #require(after.taskEdges.first)
            let old = f.owner.provenanceSnapshot()
            #expect(edge.eventID === event.id)
            #expect(edge.sourceID === event.sourceID)
            #expect(edge.taskID === actualBTask.id)
            #expect(old.tasks.count == 1)
            #expect(old.callbacks.count == 1)
            #expect(old.tasks.first?.registration == .supervisorJoined)
            #expect(old.callbacks.first?.parent === actualBTask.id)
            #expect(old.callbacks.first?.state == .bodyReturned)
            #expect(after.sources.count == 5)
            #expect(after.writes.isEmpty)
            #expect(after.faults.isEmpty)
            #expect(box.cancelCounts.read() == [1, 1, 1])
            withExtendedLifetime(box) {}
            withExtendedLifetime(returnedBox) {}
        }
    }
}

private struct CallbackFixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct CallbackCleanupFailure: Error, CustomStringConvertible {
    let primary: Error
    let cleanup: [String]
    var description: String { "primary: \(primary); cleanup: \(cleanup.joined(separator: "; "))" }
}

private final class CallbackLocked<Value>: @unchecked Sendable {
    private let mutex = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { mutex.lock(); defer { mutex.unlock() }; return value }
    @discardableResult func update<Result>(_ action: (inout Value) -> Result) -> Result {
        mutex.lock(); defer { mutex.unlock() }; return action(&value)
    }
}

private final class CallbackGate: @unchecked Sendable {
    private struct State { var open = false; var waiting: [CheckedContinuation<Void, Never>] = [] }
    private let state = CallbackLocked(State())
    var waitingCount: Int { state.read().waiting.count }
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
            let waiting = state.waiting; state.waiting.removeAll(); return waiting
        }
        waiting.forEach { $0.resume() }
    }
}

private final class CallbackTaskLedger: @unchecked Sendable {
    private struct Row { let handle: Task<Void, Never>; let observer: Task<Void, Never>; let finished: CallbackLocked<Bool> }
    private let rows = CallbackLocked<[Row]>([])
    var count: Int { rows.read().count }
    var finishedCount: Int { rows.read().filter { $0.finished.read() }.count }
    func track(_ handle: Task<Void, Never>) {
        let done = CallbackLocked(false)
        let observer = Task { await handle.value; done.update { $0 = true } }
        rows.update { $0.append(Row(handle: handle, observer: observer, finished: done)) }
    }
    func drain() async throws {
        var index = 0
        while index < rows.read().count {
            let row = rows.read()[index]
            try await callbackEventually { row.finished.read() }
            await row.handle.value
            await row.observer.value
            index += 1
        }
    }
}

private final class CallbackScheduler: @unchecked Sendable {
    private let pending = CallbackLocked<[DispatchWorkItem]>([])
    func submit(_ action: DispatchWorkItem) { pending.update { $0.append(action) } }
    var count: Int { pending.read().count }
    func releaseAll() {
        let actions = pending.update { actions in let copy = actions; actions.removeAll(); return copy }
        actions.forEach { $0.perform() }
    }
}

private final class CallbackInstaller: @unchecked Sendable {
    private let count = CallbackLocked(0)
    var activeCount: Int { count.read() }
    func install(_ action: @escaping @Sendable () -> Void) {
        count.update { $0 += 1 }
        defer { count.update { $0 -= 1 } }
        action()
    }
}

/// Only publishers and cancellation counters. Framework subscribers use the real weak sink closures.
private final class CallbackPublisherBox: @unchecked Sendable {
    let recipients = PassthroughSubject<[PeerID: String], Never>()
    let online = PassthroughSubject<Bool, Never>()
    let relay = PassthroughSubject<Bool, Never>()
    let cancelCounts = CallbackLocked([0, 0, 0])
    func recipientsPublisher() -> AnyPublisher<[PeerID: String], Never> {
        let counts = cancelCounts
        return recipients.handleEvents(receiveCancel: { counts.update { $0[0] += 1 } }).eraseToAnyPublisher()
    }
    func onlinePublisher() -> AnyPublisher<Bool, Never> {
        let counts = cancelCounts
        return online.handleEvents(receiveCancel: { counts.update { $0[1] += 1 } }).eraseToAnyPublisher()
    }
    func relayPublisher() -> AnyPublisher<Bool, Never> {
        let counts = cancelCounts
        return relay.handleEvents(receiveCancel: { counts.update { $0[2] += 1 } }).eraseToAnyPublisher()
    }
}

private final class CallbackWeakProbe: @unchecked Sendable {
    weak var value: NostrTransport?
    init(_ value: NostrTransport) { self.value = value }
}

@MainActor
private func makeAndDropWeshTransport(owner: NostrOutboundOwner, pacer: NostrTransport.AckPacer,
                                      publishers: CallbackPublisherBox, errors: CallbackLocked<[String]>) -> (CallbackWeakProbe, CallbackPublisherBox) {
    let dependencies = callbackDependencies(owner: owner, pacer: pacer, notifications: NotificationCenter(), errors: errors,
        loadFavorites: { errors.update { $0.append("Temporary Wesh transport loaded favorites") }; return [:] },
        relay: { publishers.relayPublisher() }, recipients: { publishers.recipientsPublisher() }, online: { publishers.onlinePublisher() })
    let actual = callbackTransport(dependencies)
    let probe = CallbackWeakProbe(actual)
    withExtendedLifetime(actual) {}
    return (probe, publishers)
}

@MainActor
private final class CallbackFixture {
    let owner: NostrOutboundOwner
    let pacer: NostrTransport.AckPacer
    let notifications = NotificationCenter()
    let legacyRelay = PassthroughSubject<Bool, Never>()
    let peer = PeerID(publicKey: Data(repeating: 0x11, count: 32))
    let favoriteLoads = CallbackLocked(0)
    let errors = CallbackLocked<[String]>([])
    let bodyGate: CallbackGate
    let entered: CallbackLocked<Int>
    let creators: CallbackLocked<Int>
    let ledger: CallbackTaskLedger
    private let installer: CallbackInstaller
    private let scheduler: CallbackScheduler
    private let ackQueue: DispatchQueue
    private var transports: [NostrTransport] = []

    init(holdBody: Bool) {
        let gate = CallbackGate()
        let entered = CallbackLocked(0)
        let creators = CallbackLocked(0)
        let ledger = CallbackTaskLedger()
        let installer = CallbackInstaller()
        let scheduler = CallbackScheduler()
        let ackQueue = DispatchQueue(label: "synthetic.callback.serial-ack")
        self.bodyGate = gate; self.entered = entered; self.creators = creators; self.ledger = ledger
        self.installer = installer; self.scheduler = scheduler; self.ackQueue = ackQueue
        if !holdBody { gate.open() }
        let owner = NostrOutboundOwner(taskCreator: { operation in
            let task = Task { @MainActor in
                entered.update { $0 += 1 }
                await gate.wait()
                operation()
            }
            ledger.track(task)
            creators.update { $0 += 1 }
            return task
        }, waiterInstaller: { action in installer.install(action) })
        self.owner = owner
        self.pacer = NostrTransport.AckPacer(owner: owner, queue: ackQueue, scheduleAfter: { _, action in scheduler.submit(action) })
    }

    func makeLegacy(withFavorite: Bool = false) -> NostrTransport {
        let loads = favoriteLoads
        let errors = self.errors
        let relay = legacyRelay
        let favorites = withFavorite ? callbackFavorites() : [:]
        let dependencies = callbackDependencies(owner: owner, pacer: pacer, notifications: notifications, errors: errors,
            loadFavorites: { loads.update { $0 += 1 }; return favorites }, relay: { relay.eraseToAnyPublisher() })
        let actual = callbackTransport(dependencies)
        transports.append(actual)
        return actual
    }

    func makeWesh(_ box: CallbackPublisherBox, includeOnline: Bool = true,
                  recipients: (@MainActor () -> AnyPublisher<[PeerID: String], Never>)? = nil) -> NostrTransport {
        let errors = self.errors
        let loads = favoriteLoads
        var online: (@MainActor () -> AnyPublisher<Bool, Never>)?
        if includeOnline { online = { box.onlinePublisher() } }
        let dependencies = callbackDependencies(owner: owner, pacer: pacer, notifications: notifications, errors: errors,
            loadFavorites: { loads.update { $0 += 1 }; errors.update { $0.append("Wesh fixture loaded favorites") }; return [:] },
            relay: { box.relayPublisher() }, recipients: recipients ?? { box.recipientsPublisher() }, online: online)
        let actual = callbackTransport(dependencies)
        transports.append(actual)
        return actual
    }

    /// Only actual finite work initiated by this fixture, never a complete source census/drain.
    func finishKnownWork() async throws {
        try await ledger.drain()
        for transport in transports { _ = transport.isPeerReachable(peer) }
        let batch = owner.taskBatchSnapshot()
        let proof = try await owner.joinTaskBatch(batch)
        try callbackRequire(proof.ownerID === owner.id && proof.batchID === batch.id && proof.taskIDs == batch.taskIDs,
                            "Actual captured task-batch identity changed")
        try callbackRequire(owner.provenanceSnapshot().waiters.isEmpty && installer.activeCount == 0, "Actual waiter installation remains pending")
        try callbackRequire(owner.provenanceSnapshot().debts.isEmpty, "Unexpected old work protocol debt")
        try callbackRequire(owner.sourceLedgerSnapshot().faults.isEmpty, "Unexpected source protocol fault")
        try callbackRequire(errors.read().isEmpty, errors.read().joined(separator: "; "))
    }

    func cleanup() async -> [String] {
        var failures: [String] = []
        bodyGate.open()
        scheduler.releaseAll()
        do { try await callbackCheckpoint(ackQueue) } catch { failures.append("ACK queue: \(error)") }
        do { try await finishKnownWork() } catch { failures.append("Known work: \(error)") }
        // A failed first cleanup must not skip actual handle/observer reaping.
        scheduler.releaseAll()
        do { try await ledger.drain(); try await callbackCheckpoint(ackQueue) }
        catch { failures.append("Late owned cleanup: \(error)") }
        if scheduler.count != 0 { failures.append("Manual scheduler action remains pending") }
        if installer.activeCount != 0 || !owner.provenanceSnapshot().waiters.isEmpty { failures.append("Actual registration continuation remains pending") }
        if !errors.read().isEmpty { failures.append(contentsOf: errors.read()) }
        transports.removeAll()
        return failures
    }
}

@MainActor
private func callbackTransport(_ dependencies: NostrTransport.Dependencies) -> NostrTransport {
    let keychain = MockKeychain()
    return NostrTransport(keychain: keychain, idBridge: NostrIdentityBridge(keychain: keychain), dependencies: dependencies)
}

@MainActor
private func callbackDependencies(owner: NostrOutboundOwner, pacer: NostrTransport.AckPacer,
                                  notifications: NotificationCenter, errors: CallbackLocked<[String]>,
                                  loadFavorites: @escaping @MainActor () -> [Data: FavoritesPersistenceService.FavoriteRelationship],
                                  relay: @escaping @MainActor () -> AnyPublisher<Bool, Never>,
                                  recipients: (@MainActor () -> AnyPublisher<[PeerID: String], Never>)? = nil,
                                  online: (@MainActor () -> AnyPublisher<Bool, Never>)? = nil) -> NostrTransport.Dependencies {
    let blockCheck: (@MainActor (Data) -> Bool)?
    if recipients == nil {
        blockCheck = nil
    } else {
        blockCheck = { _ in false }
    }
    return NostrTransport.Dependencies(outboundOwner: owner, notificationCenter: notifications, loadFavorites: loadFavorites,
        favoriteStatusForNoiseKey: { _ in errors.update { $0.append("Unexpected favorite key lookup") }; return nil },
        favoriteStatusForPeerID: { _ in errors.update { $0.append("Unexpected favorite peer lookup") }; return nil },
        currentIdentity: { errors.update { $0.append("Unexpected identity provider") }; return nil },
        registerPendingGiftWrap: { _ in errors.update { $0.append("Unexpected crypto registration") } },
        sendEvent: { _ in errors.update { $0.append("Unexpected crypto send") } },
        scheduleAfter: { _, _ in errors.update { $0.append("Unexpected dependency scheduler") } },
        relayConnectivity: relay, ackPacer: pacer, weshRecipients: recipients, weshOnline: online,
        weshIsBlocked: blockCheck)
}

private func callbackFavorites() -> [Data: FavoritesPersistenceService.FavoriteRelationship] {
    let noise = Data(repeating: 0x11, count: 32)
    let relationship = FavoritesPersistenceService.FavoriteRelationship(peerNoisePublicKey: noise, peerNostrPublicKey: "synthetic-npub",
        peerNickname: "Synthetic", isFavorite: true, theyFavoritedUs: true,
        favoritedAt: Date(timeIntervalSince1970: 1), lastUpdated: Date(timeIntervalSince1970: 2))
    return [noise: relationship]
}

private struct InlineRecipientsPublisher: Publisher {
    typealias Output = [PeerID: String]
    typealias Failure = Never
    let value: Output
    let afterEmission: () -> Void
    func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Never {
        let subscription = InlineRecipientsSubscription(subscriber: subscriber, value: value, afterEmission: afterEmission)
        subscriber.receive(subscription: subscription)
    }
}

private final class InlineRecipientsSubscription<S: Subscriber>: Subscription where S.Input == [PeerID: String], S.Failure == Never {
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
        mutex.lock()
        subscriber = nil
        afterEmission = nil
        mutex.unlock()
    }
}

@MainActor
private func withCallbackFixture(holdBody: Bool = false, _ body: (CallbackFixture) async throws -> Void) async throws {
    let f = CallbackFixture(holdBody: holdBody)
    var primary: Error?
    do { try await body(f) } catch { primary = error }
    let cleanup = await f.cleanup()
    if let primary {
        if cleanup.isEmpty { throw primary }
        throw CallbackCleanupFailure(primary: primary, cleanup: cleanup)
    }
    try callbackRequire(cleanup.isEmpty, cleanup.joined(separator: "; "))
}

private func expectNoOldWork(_ owner: NostrOutboundOwner) throws {
    let old = owner.provenanceSnapshot()
    #expect(old.tasks.isEmpty)
    #expect(old.callbacks.isEmpty)
    #expect(old.waiters.isEmpty)
    #expect(old.debts.isEmpty)
    #expect(old.unconfirmedHandleCount == 0)
    #expect(owner.sourceLedgerSnapshot().faults.isEmpty)
}

private func expectWriteLineage(_ state: NostrOutboundOwner.SourceLedgerSnapshot,
                                kind: NostrOutboundOwner.SourceWriteKind, count: Int = 1) throws {
    let writes = state.writes.filter { $0.kind == kind }
    #expect(writes.count == count)
    for write in writes {
        let event = try #require(state.events.first { $0.id === write.eventID })
        #expect(write.sourceID === event.sourceID)
        #expect(write.state == .bodyEndRecorded)
        #expect(event.state == .bodyEndRecorded)
        #expect(state.sources.contains { $0.id === write.sourceID })
    }
}

private func callbackRequire(_ condition: Bool, _ message: String) throws {
    if !condition { throw CallbackFixtureError(message) }
}

private func callbackEventually(_ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !condition() {
        if clock.now >= deadline { throw CallbackFixtureError("Owned readiness/completion checkpoint expired") }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
}

private func callbackCheckpoint(_ queue: DispatchQueue) async throws {
    let done = CallbackLocked(false)
    queue.async { done.update { $0 = true } }
    try await callbackEventually { done.read() }
}
