import BitFoundation
import Combine
import Foundation
import Testing
@testable import bitchat

/// Actual constructor effects and isolated original owners; no live providers or stores.
@MainActor
struct NostrSourceInstallationAdmissionTests {
    @Test
    func postCloseWeshConstructionInvokesNoSourceProviders() async throws {
        let result = try await withInstallFixture { f in
            let receipt = try installClose(f.owner.captureOutboundPanicBinding())
            _ = f.makeWesh(InstallPublishers())
            try await f.finishKnownWork()
            return try f.policyObservation(f.counts.read() == InstallCounts(), receipt: receipt,
                kinds: [.weshRecipients, .weshOnline, .weshRelayConnectivity])
        }
        try #require(result.policy, "Closed Wesh construction invoked an actual source provider")
        try expectInstallRefusals(result)
    }

    @Test
    func postCloseLegacyConstructionInvokesNoObserverWarmupOrRelayProvider() async throws {
        let result = try await withInstallFixture { f in
            let receipt = try installClose(f.owner.captureOutboundPanicBinding())
            _ = f.makeLegacy(withFavorite: true)
            let before = f.owner.sourceLedgerSnapshot().events.count
            f.notifications.post(name: .favoriteStatusChanged, object: nil)
            try await f.finishKnownWork()
            let delta = f.owner.sourceLedgerSnapshot().events.count - before
            let counts = f.counts.read()
            return try f.policyObservation(delta == 0 && counts.favorites == 0 && counts.relay == 0,
                receipt: receipt, kinds: [.legacyFavoriteObserver, .legacyRelayConnectivity], warmup: true)
        }
        try #require(result.policy, "Closed legacy construction registered an observer or invoked warmup/relay")
        try expectInstallRefusals(result)
    }

    @Test
    func closeInsideAcceptedRecipientsProviderRefusesLaterInstallations() async throws {
        let result = try await withInstallFixture { f in
            let receipt = InstallLocked<NostrOutboundOwner.RootCloseReceipt?>(nil)
            let owner = f.owner
            let errors = f.errors
            let inline = InstallInlineRecipients(value: [f.peer: "synthetic-inline"], afterEmission: {})
            _ = f.makeWesh(InstallPublishers(), recipients: {
                do { let closed = try installClose(owner.captureOutboundPanicBinding()); receipt.update { $0 = closed } }
                catch { errors.update { $0.append("Original close failed: \(error)") } }
                return inline.eraseToAnyPublisher()
            })
            let closed = try #require(receipt.read())
            try await f.finishKnownWork()
            let counts = f.counts.read()
            try installRequire(counts.recipients == 1, "First accepted provider did not execute once")
            return try f.policyObservation(counts.online == 0 && counts.relay == 0, receipt: closed,
                kinds: [.weshRecipients, .weshOnline, .weshRelayConnectivity], acceptedPrefix: 1)
        }
        try #require(result.policy, "Later providers ran after the accepted first provider closed its owner")
        try expectInstallRefusals(result)
    }

    @Test
    func openWeshInstallsAllPresentPublishersAndPreservesActualEffects() async throws {
        let result = try await withInstallFixture { f in
            let box = InstallPublishers()
            let transport = f.makeWesh(box)
            box.recipients.send([f.peer: "synthetic-contact"])
            box.online.send(true)
            box.relay.send(true)
            try await f.finishKnownWork()
            return (transport.canDeliverPromptly(to: f.peer), f.counts.read(),
                    f.owner.sourceInstallationAdmissionSnapshot(), f.owner.sourceLedgerSnapshot(), f.owner.coldProviderSnapshot())
        }
        #expect(result.0)
        #expect(result.1 == InstallCounts(recipients: 1, online: 1, relay: 1))
        expectOpenInstallRows(result.2, kinds: [.weshRecipients, .weshOnline, .weshRelayConnectivity])
        #expect(result.3.sources.allSatisfy { $0.installation == .installationReturned })
        #expect(result.3.writes.count == 3 && result.3.faults.isEmpty)
        #expect(result.4.rows.isEmpty)
    }

    @Test
    func openLegacyInstallsObserverWarmsCacheAndRefreshesThroughActualRoot() async throws {
        let result = try await withInstallFixture { f in
            let transport = f.makeLegacy(withFavorite: true)
            f.legacyRelay.send(true)
            f.notifications.post(name: .favoriteStatusChanged, object: nil)
            try await f.finishKnownWork()
            return (transport.canDeliverPromptly(to: f.peer), f.counts.read(), f.creators.read(),
                    f.owner.sourceInstallationAdmissionSnapshot(), f.owner.coldProviderSnapshot(),
                    f.owner.sourceLedgerSnapshot(), f.owner.provenanceSnapshot())
        }
        #expect(result.0)
        #expect(result.1 == InstallCounts(relay: 1, favorites: 2))
        #expect(result.2 == 1)
        expectOpenInstallRows(result.3, kinds: [.legacyFavoriteObserver, .legacyRelayConnectivity])
        try expectReturnedWarmup(result.4)
        #expect(result.5.events.count == 2 && result.5.taskEdges.count == 1 && result.5.faults.isEmpty)
        #expect(result.6.tasks.count == 1 && result.6.tasks.first?.registration == .supervisorJoined)
    }

    @Test
    func nilOnlineInstallsOnlyPresentWeshSourcesWithoutLegacyFallback() async throws {
        let result = try await withInstallFixture { f in
            let box = InstallPublishers()
            let transport = f.makeWesh(box, includeOnline: false)
            box.recipients.send([f.peer: "synthetic-contact"])
            box.relay.send(true)
            try await f.finishKnownWork()
            return (transport.isPeerReachable(f.peer), f.counts.read(),
                    f.owner.sourceInstallationAdmissionSnapshot(), f.owner.coldProviderSnapshot())
        }
        #expect(!result.0)
        #expect(result.1 == InstallCounts(recipients: 1, relay: 1))
        expectOpenInstallRows(result.2, kinds: [.weshRecipients, .weshRelayConnectivity])
        #expect(result.3.rows.isEmpty)
    }

    @Test
    func inlineInitialEventsPrecedeInstallationReturnWithoutBypassingBodyGate() async throws {
        let result = try await withInstallFixture { f in
            let owner = f.owner
            let observed = InstallLocked<[(NostrOutboundOwner.SourceLedgerSnapshot, NostrOutboundOwner.SourceBodyAdmissionSnapshot)]>([])
            let inline = InstallInlineRecipients(value: [f.peer: "synthetic-inline"], afterEmission: {
                observed.update { $0.append((owner.sourceLedgerSnapshot(), owner.sourceBodyAdmissionSnapshot())) }
            })
            let box = InstallPublishers()
            let transport = f.makeWesh(box, recipients: { inline.eraseToAnyPublisher() })
            box.online.send(true)
            try await f.finishKnownWork()
            try installRequire(observed.read().count == 1, "Actual inline emission was not observed")
            return (observed.read()[0], transport.isPeerReachable(f.peer))
        }
        let source = try #require(result.0.0.sources.first)
        let event = try #require(result.0.0.events.first)
        let body = try #require(result.0.1.rows.first)
        #expect(source.installation == .installing)
        #expect(event.sourceID === source.id && event.state == .bodyEndRecorded)
        #expect(body.sourceID === source.id && body.eventID === event.id)
        #expect(body.decision == .accepted && body.permitID != nil && body.writeID != nil)
        #expect(result.1 && result.0.0.faults.isEmpty)
    }

    @Test
    func acceptedInstallationReturnsAfterOriginalCloseWithSameTicket() async throws {
        let result = try await withInstallFixture { f in
            let source = try installSource(f.owner, kind: .weshOnline)
            let receipt = try installClose(f.owner.captureOutboundPanicBinding())
            let returned = installRecorded(f.owner.noteSourceInstallationReturned(source))
            let repeatedClose = try installClose(f.owner.captureOutboundPanicBinding())
            return (source.id, receipt, repeatedClose, returned,
                    f.owner.sourceInstallationAdmissionSnapshot(), f.owner.sourceLedgerSnapshot())
        }
        #expect(result.1 === result.2 && result.3)
        expectOpenInstallRows(result.4, kinds: [.weshOnline])
        #expect(result.4.rows.first?.sourceID === result.0)
        #expect(result.5.sources.first?.id === result.0 && result.5.sources.first?.installation == .installationReturned)
        #expect(result.5.faults.isEmpty)
    }

    @Test
    func acceptedLegacyWarmupCompletesProviderAndCacheAcrossClose() async throws {
        let result = try await withInstallFixture { f in
            let owner = f.owner
            let errors = f.errors
            let during = InstallLocked<NostrOutboundOwner.ColdProviderSnapshot?>(nil)
            let receipt = InstallLocked<NostrOutboundOwner.RootCloseReceipt?>(nil)
            let transport = f.makeLegacy(loadFavorites: {
                during.update { $0 = owner.coldProviderSnapshot() }
                do { let closed = try installClose(owner.captureOutboundPanicBinding()); receipt.update { $0 = closed } }
                catch { errors.update { $0.append("Original close failed: \(error)") } }
                return installFavorites()
            })
            try await f.finishKnownWork()
            return (try #require(during.read()), try #require(receipt.read()),
                    transport.isPeerReachable(f.peer), owner.coldProviderSnapshot())
        }
        let before = try #require(result.0.rows.first)
        let after = try #require(result.3.rows.first)
        #expect(before.state == .inFlight && before.decision == .accepted)
        #expect(before.requestID === after.requestID && before.permissionID === after.permissionID)
        #expect(result.1.ownerID === result.3.ownerID && result.2)
        try expectReturnedWarmup(result.3)
        // Source ordering proves settlement follows the sync cache barrier; no held private queue is claimed.
    }

    @Test
    func foreignAndReplaySettlementsPreserveOriginalAuthorityAndProtocolDebt() async throws {
        let result = try await withInstallFixture { first in
            try await withInstallFixture { second in
                let source = try installSource(first.owner, kind: .weshRecipients)
                let permission = try installWarmup(first.owner)
                let foreignSource = installFault(second.owner.noteSourceInstallationReturned(source))
                let foreignWarmup = installFault(second.owner.noteColdProviderReturned(permission))
                let before = (first.owner.sourceLedgerSnapshot(), first.owner.coldProviderSnapshot())
                let recorded = [installRecorded(first.owner.noteSourceInstallationReturned(source)),
                                installRecorded(first.owner.noteColdProviderReturned(permission))]
                let replayed = [installFault(first.owner.noteSourceInstallationReturned(source)),
                                installFault(first.owner.noteColdProviderReturned(permission))]
                return (foreignSource && foreignWarmup, before, recorded, replayed,
                        first.owner.sourceLedgerSnapshot(), first.owner.coldProviderSnapshot(), second.owner.sourceLedgerSnapshot())
            }
        }
        #expect(result.0 && result.2.allSatisfy { $0 } && result.3.allSatisfy { $0 })
        #expect(result.1.0.sources.first?.installation == .installing)
        #expect(result.1.1.rows.first?.state == .inFlight)
        #expect(result.4.sources.first?.installation == .installationReturned)
        try expectReturnedWarmup(result.5)
        #expect(result.4.faults == [.repeatedInstallationReturn, .repeatedColdProviderReturn])
        #expect(result.6.faults == [.foreignSource, .invalidColdProviderPermission])
        #expect(result.6.sources.isEmpty)
    }
}

private struct InstallFixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct InstallCleanupFailure: Error, CustomStringConvertible {
    let primary: Error
    let cleanup: [String]
    var description: String { "primary: \(primary); cleanup: \(cleanup.joined(separator: "; "))" }
}

private struct InstallCounts: Equatable {
    var recipients = 0
    var online = 0
    var relay = 0
    var favorites = 0
}

private struct InstallPolicyObservation {
    let policy: Bool
    let receipt: NostrOutboundOwner.RootCloseReceipt
    let kinds: [NostrOutboundOwner.SourceKind]
    let acceptedPrefix: Int
    let warmup: Bool
    let installations: NostrOutboundOwner.SourceInstallationAdmissionSnapshot
    let cold: NostrOutboundOwner.ColdProviderSnapshot
    let ledger: NostrOutboundOwner.SourceLedgerSnapshot
}

private func expectInstallRefusals(_ result: InstallPolicyObservation) throws {
    #expect(result.installations.ownerID === result.receipt.ownerID)
    #expect(result.installations.rows.map(\.kind) == result.kinds)
    #expect(result.ledger.sources.count == result.acceptedPrefix)
    for (index, row) in result.installations.rows.enumerated() {
        #expect(row.ownerID === result.installations.ownerID)
        #expect(row.requestID !== row.ownerID && row.requestID !== row.sourceID)
        if index < result.acceptedPrefix {
            #expect(row.decision == .accepted && row.closeReceipt == nil && row.sourceID != nil)
            let source = try #require(result.ledger.sources.first { $0.id === row.sourceID })
            #expect(source.installation == .installationReturned)
        } else {
            #expect(row.decision == .refusedBeforeRoot && row.sourceID == nil)
            #expect(row.closeReceipt === result.receipt)
        }
    }
    #expect(result.cold.ownerID === result.receipt.ownerID)
    #expect(result.cold.rows.count == (result.warmup ? 1 : 0))
    if result.warmup {
        let row = try #require(result.cold.rows.first)
        #expect(row.ownerID === result.cold.ownerID && row.requestID !== row.ownerID)
        #expect(row.purpose == .legacyFavoritesWarm && row.decision == .refusedBeforeRoot)
        #expect(row.permissionID == nil && row.state == nil && row.closeReceipt === result.receipt)
    }
}

private func expectOpenInstallRows(_ snapshot: NostrOutboundOwner.SourceInstallationAdmissionSnapshot,
                                   kinds: [NostrOutboundOwner.SourceKind]) {
    #expect(snapshot.rows.map(\.kind) == kinds)
    #expect(Set(snapshot.rows.map(\.requestID)).count == kinds.count)
    #expect(Set(snapshot.rows.compactMap(\.sourceID)).count == kinds.count)
    #expect(snapshot.rows.allSatisfy {
        $0.ownerID === snapshot.ownerID && $0.requestID !== $0.ownerID && $0.sourceID != nil &&
        $0.requestID !== $0.sourceID && $0.decision == .accepted && $0.closeReceipt == nil
    })
}

private func expectReturnedWarmup(_ snapshot: NostrOutboundOwner.ColdProviderSnapshot) throws {
    #expect(snapshot.rows.count == 1)
    let row = try #require(snapshot.rows.first)
    #expect(row.ownerID === snapshot.ownerID && row.requestID !== row.ownerID)
    #expect(row.permissionID != nil && row.permissionID !== row.ownerID && row.permissionID !== row.requestID)
    #expect(row.purpose == .legacyFavoritesWarm && row.decision == .accepted)
    #expect(row.state == .returned && row.closeReceipt == nil)
}

private func installSource(_ owner: NostrOutboundOwner, kind: NostrOutboundOwner.SourceKind) throws -> NostrOutboundOwner.SourceInstallation {
    guard case .accepted(let source) = owner.beginSourceInstallation(kind: kind) else {
        throw InstallFixtureError("Open original source installation was refused")
    }
    return source
}

private func installWarmup(_ owner: NostrOutboundOwner) throws -> NostrOutboundOwner.ColdProviderPermission {
    guard case .accepted(let permission) = owner.beginColdProvider(purpose: .legacyFavoritesWarm) else {
        throw InstallFixtureError("Open original warmup was refused")
    }
    return permission
}

private func installRecorded(_ update: NostrOutboundOwner.SourceReceiptUpdate) -> Bool {
    if case .recorded = update { return true }
    return false
}

private func installFault(_ update: NostrOutboundOwner.SourceReceiptUpdate) -> Bool {
    if case .protocolFault = update { return true }
    return false
}

private func installClose(_ binding: NostrOutboundPanicBinding) throws -> NostrOutboundOwner.RootCloseReceipt {
    guard case .closed(let receipt) = closeCapturedNostrOutboundRoots(binding) else {
        throw InstallFixtureError("Actual isolated original binding did not close")
    }
    return receipt
}

private final class InstallLocked<Value>: @unchecked Sendable {
    private let mutex = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { mutex.lock(); defer { mutex.unlock() }; return value }
    @discardableResult func update<Result>(_ action: (inout Value) -> Result) -> Result {
        mutex.lock(); defer { mutex.unlock() }; return action(&value)
    }
}

private final class InstallTaskLedger: @unchecked Sendable {
    private struct Row { let task: Task<Void, Never>; let observer: Task<Void, Never>; let finished: InstallLocked<Bool> }
    private let rows = InstallLocked<[Row]>([])
    func track(_ task: Task<Void, Never>) {
        let finished = InstallLocked(false)
        let observer = Task { await task.value; finished.update { $0 = true } }
        rows.update { $0.append(Row(task: task, observer: observer, finished: finished)) }
    }
    func drain() async throws {
        var readinessErrors: [Error] = []
        var index = 0
        while index < rows.read().count {
            let row = rows.read()[index]
            do { try await installEventually { row.finished.read() } }
            catch { readinessErrors.append(error) }
            // A readiness failure never replaces either actual join or skips finite children.
            await row.task.value
            await row.observer.value
            index += 1
        }
        guard let first = readinessErrors.first else { return }
        if readinessErrors.count == 1 { throw first }
        throw InstallCleanupFailure(primary: first, cleanup: readinessErrors.dropFirst().map { String(describing: $0) })
    }
}

private final class InstallInstaller: @unchecked Sendable {
    private let count = InstallLocked(0)
    var activeCount: Int { count.read() }
    func install(_ action: @escaping @Sendable () -> Void) {
        count.update { $0 += 1 }
        defer { count.update { $0 -= 1 } }
        action()
    }
}

private final class InstallScheduler: @unchecked Sendable {
    private let pending = InstallLocked<[DispatchWorkItem]>([])
    var count: Int { pending.read().count }
    func submit(_ action: DispatchWorkItem) { pending.update { $0.append(action) } }
    func releaseAll() {
        let actions = pending.update { let copy = $0; $0.removeAll(); return copy }
        actions.forEach { $0.perform() }
    }
}

private final class InstallPublishers: @unchecked Sendable {
    let recipients = PassthroughSubject<[PeerID: String], Never>()
    let online = PassthroughSubject<Bool, Never>()
    let relay = PassthroughSubject<Bool, Never>()
}

@MainActor
private final class InstallFixture {
    let owner: NostrOutboundOwner
    let pacer: NostrTransport.AckPacer
    let notifications = NotificationCenter()
    let legacyRelay = PassthroughSubject<Bool, Never>()
    let peer = PeerID(publicKey: Data(repeating: 0x11, count: 32))
    let counts = InstallLocked(InstallCounts())
    let creators: InstallLocked<Int>
    let errors = InstallLocked<[String]>([])
    private let ledger: InstallTaskLedger
    private let installer: InstallInstaller
    private let scheduler: InstallScheduler
    private let ackQueue: DispatchQueue
    private var transports: [NostrTransport] = []
    private var publishers: [InstallPublishers] = []

    init() {
        let ledger = InstallTaskLedger()
        let installer = InstallInstaller()
        let creators = InstallLocked(0)
        let scheduler = InstallScheduler()
        let ackQueue = DispatchQueue(label: "synthetic.source-installation.serial-ack")
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

    func makeLegacy(withFavorite: Bool = false,
                    loadFavorites: (@MainActor () -> [Data: FavoritesPersistenceService.FavoriteRelationship])? = nil) -> NostrTransport {
        let counts = self.counts
        let relay = legacyRelay
        let favorites = withFavorite ? installFavorites() : [:]
        let dependencies = installDependencies(owner: owner, pacer: pacer, notifications: notifications, errors: errors,
            loadFavorites: { counts.update { $0.favorites += 1 }; return loadFavorites?() ?? favorites },
            relay: { counts.update { $0.relay += 1 }; return relay.eraseToAnyPublisher() })
        return retainTransport(dependencies)
    }

    func makeWesh(_ box: InstallPublishers, includeOnline: Bool = true,
                  recipients: (@MainActor () -> AnyPublisher<[PeerID: String], Never>)? = nil) -> NostrTransport {
        publishers.append(box)
        let counts = self.counts
        let errors = self.errors
        let online: (@MainActor () -> AnyPublisher<Bool, Never>)?
        if includeOnline {
            online = { counts.update { $0.online += 1 }; return box.online.eraseToAnyPublisher() }
        } else { online = nil }
        let dependencies = installDependencies(owner: owner, pacer: pacer, notifications: notifications, errors: errors,
            loadFavorites: { counts.update { $0.favorites += 1 }; errors.update { $0.append("Wesh loaded favorites") }; return [:] },
            relay: { counts.update { $0.relay += 1 }; return box.relay.eraseToAnyPublisher() },
            recipients: {
                counts.update { $0.recipients += 1 }
                return recipients?() ?? box.recipients.eraseToAnyPublisher()
            }, online: online)
        return retainTransport(dependencies)
    }

    private func retainTransport(_ dependencies: NostrTransport.Dependencies) -> NostrTransport {
        let keychain = MockKeychain()
        let transport = NostrTransport(keychain: keychain, idBridge: NostrIdentityBridge(keychain: keychain), dependencies: dependencies)
        transports.append(transport)
        return transport
    }

    func policyObservation(_ policy: Bool, receipt: NostrOutboundOwner.RootCloseReceipt,
                           kinds: [NostrOutboundOwner.SourceKind], acceptedPrefix: Int = 0,
                           warmup: Bool = false) throws -> InstallPolicyObservation {
        let ledger = owner.sourceLedgerSnapshot()
        try installRequire(ledger.faults.isEmpty, "Unexpected source protocol fault before policy assertion")
        try installRequire(receipt.ownerID === owner.id, "Original close receipt changed owner")
        return InstallPolicyObservation(policy: policy, receipt: receipt, kinds: kinds, acceptedPrefix: acceptedPrefix,
            warmup: warmup, installations: owner.sourceInstallationAdmissionSnapshot(),
            cold: owner.coldProviderSnapshot(), ledger: ledger)
    }

    /// Finite fixture work only; this is not a complete source census or global drain.
    func finishKnownWork() async throws {
        try await ledger.drain()
        for transport in transports { _ = transport.isPeerReachable(peer) }
        let state = owner.provenanceSnapshot()
        try installRequire(state.tasks.allSatisfy { $0.registration == .handleRegistered || $0.registration == .supervisorJoined },
                           "A completed owned Task has no registered handle")
        try installRequire(state.debts.isEmpty && state.unconfirmedHandleCount == 0, "Unexpected registration debt")
        let batch = owner.taskBatchSnapshot()
        let joined = try await owner.joinTaskBatch(batch)
        try installRequire(joined.ownerID === owner.id && joined.batchID === batch.id && joined.taskIDs == batch.taskIDs,
                           "Actual batch identity changed")
        try installRequire(owner.provenanceSnapshot().waiters.isEmpty && installer.activeCount == 0, "Actual installer remains pending")
        try installRequire(errors.read().isEmpty, errors.read().joined(separator: "; "))
    }

    func cleanup() async -> [String] {
        var failures: [String] = []
        scheduler.releaseAll()
        do { try await installCheckpoint(ackQueue) } catch { failures.append("ACK queue: \(error)") }
        do { try await finishKnownWork() } catch { failures.append("Known work: \(error)") }
        scheduler.releaseAll()
        do { try await ledger.drain() }
        catch { failures.append("Late actual Task/observer cleanup: \(error)") }
        for transport in transports { _ = transport.isPeerReachable(peer) }
        do { try await installCheckpoint(ackQueue) }
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
private func installDependencies(owner: NostrOutboundOwner, pacer: NostrTransport.AckPacer,
                                 notifications: NotificationCenter, errors: InstallLocked<[String]>,
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

private func installFavorites() -> [Data: FavoritesPersistenceService.FavoriteRelationship] {
    let noise = Data(repeating: 0x11, count: 32)
    let relationship = FavoritesPersistenceService.FavoriteRelationship(peerNoisePublicKey: noise, peerNostrPublicKey: "synthetic-npub",
        peerNickname: "Synthetic", isFavorite: true, theyFavoritedUs: true,
        favoritedAt: Date(timeIntervalSince1970: 1), lastUpdated: Date(timeIntervalSince1970: 2))
    return [noise: relationship]
}

private struct InstallInlineRecipients: Publisher {
    typealias Output = [PeerID: String]
    typealias Failure = Never
    let value: Output
    let afterEmission: () -> Void
    func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Never {
        subscriber.receive(subscription: InstallInlineSubscription(subscriber: subscriber, value: value, afterEmission: afterEmission))
    }
}

private final class InstallInlineSubscription<S: Subscriber>: Subscription where S.Input == [PeerID: String], S.Failure == Never {
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
private func withInstallFixture<T>(_ install: (InstallFixture) async throws -> T) async throws -> T {
    let fixture = InstallFixture()
    var result: T?
    var primary: Error?
    do { result = try await install(fixture) } catch { primary = error }
    let cleanup = await fixture.cleanup()
    if let primary {
        if cleanup.isEmpty { throw primary }
        throw InstallCleanupFailure(primary: primary, cleanup: cleanup)
    }
    try installRequire(cleanup.isEmpty, cleanup.joined(separator: "; "))
    guard let result else { throw InstallFixtureError("Owned fixture lost its completed result") }
    return result
}

private func installRequire(_ condition: Bool, _ message: String) throws {
    if !condition { throw InstallFixtureError(message) }
}

private func installEventually(fileID: StaticString = #fileID, line: UInt = #line, _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !condition() {
        if clock.now >= deadline { throw InstallFixtureError("Owned completion checkpoint expired at \(fileID):\(line)") }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
}

private func installCheckpoint(_ queue: DispatchQueue) async throws {
    let done = InstallLocked(false)
    queue.async { done.update { $0 = true } }
    var guardError: Error?
    do { try await installEventually { done.read() } }
    catch { guardError = error }
    queue.sync {}
    if let guardError { throw guardError }
}
