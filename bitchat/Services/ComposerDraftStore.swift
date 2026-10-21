//
// ComposerDraftStore.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import BitFoundation
import Combine
import CryptoKit

enum ComposerDraftStatus: Equatable {
    case sessionOnly, waitingForIdentity, loading, dirty, saving, durable, suspended
    case unavailable(ComposerDraftFailure)
}

/// Compatible RAM facade. Only AppRuntime explicitly enables the encrypted
/// backend for Wesh. Tests never configure a real singleton backend.
enum ComposerDraftStore {
    static let maxDraftLength = 8_000
    static let maxDraftCount = 64
    static let repository = ComposerDraftRepository()

    enum Key: Hashable, Equatable {
        case mesh
        case location(geohash: String)
        /// Legacy fingerprint/short routing fallback is deliberately RAM only.
        case privateChat(stableID: String)
        /// Persistence requires the complete authenticated destination key.
        case privateNoiseKey(Data)

        var storageString: String {
            switch self {
            case .mesh: return "mesh"
            case .location(let value): return "geo:\(value.lowercased())"
            case .privateChat(let value): return "dm:\(value.lowercased())"
            case .privateNoiseKey(let value): return "noise:\(value.hexEncodedString())"
            }
        }
        var isPersistentDestination: Bool {
            switch self {
            case .mesh: return true
            case .privateNoiseKey(let key): return key.count == 32
            default: return false
            }
        }
        static func from(peerID: PeerID?, fingerprint: String?, channel: ChannelID) -> Key {
            if let peerID {
                if let key = peerID.noiseKey, key.count == 32 { return .privateNoiseKey(key) }
                if let fingerprint, !fingerprint.isEmpty { return .privateChat(stableID: fingerprint) }
                return .privateChat(stableID: peerID.id)
            }
            switch channel {
            case .mesh: return .mesh
            case .location(let channel): return .location(geohash: channel.geohash)
            }
        }
    }

    static func load(_ key: Key) -> String { repository.load(key) }
    @discardableResult
    static func save(_ text: String, for key: Key, generation: UInt64? = nil) -> Bool {
        repository.save(text, for: key, generation: generation)
    }
    static func reset() { repository.resetMemory() }
    static func owner(for noiseKey: Data) -> Data? {
        guard noiseKey.count == 32 else { return nil }
        return Data(SHA256.hash(data: noiseKey))
    }
    @MainActor
    static func configurePersistence(keychain: KeychainManagerProtocol, noiseKey: Data) {
        guard !TestEnvironment.isRunningTests, WeshMode.isActive else { return }
        repository.configureLive(keychain: keychain, owner: owner(for: noiseKey))
    }
    /// Security barrier: invalidate callbacks and drain old IO before Keychain deletion.
    static func suspendForPanic() { repository.suspendForPanic() }
    static func wipePersistentDraftsForPanic() throws {
        try repository.wipeForPanic(defaultFileURL: TestEnvironment.isRunningTests ? nil : ComposerDraftPersistence.defaultFileURL())
    }
    static func completePanic(success: Bool, noiseKey: Data) {
        repository.completePanic(success: success, owner: owner(for: noiseKey))
    }
    @discardableResult
    static func replaceAllForTesting(_ entries: [String: String] = [:]) -> [String: String] {
        repository.replaceForTesting(entries)
    }
    static func countForTesting() -> Int { repository.count }
}

/// Scalar evidence never restores authority to an original repository or epoch.
struct ComposerOriginalIOIdentity: Equatable, Sendable {
    let repository: UUID
    let epoch: UUID
    let close: UUID
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.repository == rhs.repository && lhs.epoch == rhs.epoch && lhs.close == rhs.close
    }
}

enum ComposerOriginalIOGap: Equatable, Sendable {
    case foreignRepository, changedEpoch, configurationOrLegacyOverlap, originalQueueCaller
}

enum ComposerOriginalWaitOutcome: Equatable, Sendable {
    case requestedNotAwaited(ComposerOriginalIOIdentity)
    case ordinaryDraftSubmissionsReturned(ComposerOriginalIOIdentity, itemIDs: [UUID])
    case unconfirmed(ComposerOriginalIOGap)
}

struct ComposerOriginalIOBinding: @unchecked Sendable {
    fileprivate let repository: ComposerDraftRepository
    fileprivate let epoch: UUID
}

struct ComposerOriginalIOClose: @unchecked Sendable {
    fileprivate let repository: ComposerDraftRepository
    fileprivate let state: ComposerOriginalCloseState
    fileprivate let externalCaller: Bool
    var identity: ComposerOriginalIOIdentity { state.identity }
}

enum ComposerOriginalCloseResult: @unchecked Sendable {
    case captured(ComposerOriginalIOClose)
    case unconfirmed(ComposerOriginalIOGap)
}

private final class ComposerOriginalItem {
    let id = UUID()
    var work: DispatchWorkItem?
}

private final class ComposerOriginalWaiter: @unchecked Sendable {
    let id = UUID()
    var continuation: CheckedContinuation<ComposerOriginalWaitOutcome, Error>?
    var cancelled = false
    var resolved = false
}

private final class ComposerOriginalCloseState: @unchecked Sendable {
    let identity: ComposerOriginalIOIdentity
    let controlVersion: UInt64
    let admittedWithoutControlOverlap: Bool
    let itemIDs: [UUID]
    var pending: Set<UUID>
    var invalidationOffered = false
    var invalidationReturned = false
    var waiters: [UUID: ComposerOriginalWaiter] = [:]
    init(identity: ComposerOriginalIOIdentity, controlVersion: UInt64, admittedWithoutControlOverlap: Bool, itemIDs: [UUID]) {
        self.identity = identity
        self.controlVersion = controlVersion
        self.admittedWithoutControlOverlap = admittedWithoutControlOverlap
        self.itemIDs = itemIDs
        self.pending = Set(itemIDs)
    }
}

/// RAM access never performs IO. A serial utility queue owns the encrypted
/// backend. IO only sends asynchronous Main notifications and never waits Main.
/// Mutable RAM state is protected by lock; backend IO is confined to ioQueue.
final class ComposerDraftRepository: ObservableObject, @unchecked Sendable {
    struct Change {
        let generation: UInt64
        // periphery:ignore - part of the published change event
        let keys: Set<ComposerDraftStore.Key>
        let restoredRevisions: [ComposerDraftStore.Key: UInt64]
        let reset: Bool
    }
    struct Snapshot {
        let key: ComposerDraftStore.Key
        let text: String
        fileprivate let revision: UInt64
        fileprivate let generation: UInt64
    }
    private struct Entry {
        let key: ComposerDraftStore.Key
        let text: String
        let updatedAt: Date
        let revision: UInt64
        let unsupported: Bool
    }
    private struct Mutation {
        let entry: Entry?
        let revision: UInt64
    }
    let objectWillChange = ObservableObjectPublisher()
    let changes = PassthroughSubject<Change, Never>()
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "wesh.composer-drafts.io", qos: .utility)
    private let ioSpecific = DispatchSpecificKey<UInt8>()
    private let debounce: TimeInterval
    private var entries: [String: Entry] = [:]
    private var pending: [String: Mutation] = [:]
    private var revision: UInt64 = 0
    private var generation: UInt64 = 0
    private var backend: ComposerDraftPersistence?
    private var owner: Data?
    private var boundOwner: Data?
    private var loaded = false
    private var suspended = false
    private var state: ComposerDraftStatus = .sessionOnly
    private var scheduled: DispatchWorkItem?

    private let originalRepositoryID = UUID()
    private var originalEpoch = UUID()
    private var originalItems: [UUID: ComposerOriginalItem] = [:]
    private var originalClose: ComposerOriginalCloseState?
    private var controlVersion: UInt64 = 0
    private var controlAdmissions = 0

    func captureOriginalIOBinding() -> ComposerOriginalIOBinding {
        locked { ComposerOriginalIOBinding(repository: self, epoch: originalEpoch) }
    }

    /// This fence never waits for the utility queue or invokes a provider.
    func closeOriginalIO(_ binding: ComposerOriginalIOBinding) -> ComposerOriginalCloseResult {
        guard binding.repository === self else { return .unconfirmed(.foreignRepository) }
        let externalCaller = DispatchQueue.getSpecific(key: ioSpecific) == nil
        var cancelled: DispatchWorkItem?
        let result: ComposerOriginalCloseResult = locked {
            guard binding.epoch == originalEpoch else { return .unconfirmed(.changedEpoch) }
            if let originalClose {
                return .captured(ComposerOriginalIOClose(repository: self, state: originalClose, externalCaller: externalCaller))
            }
            // The old synchronous protective prefix is preserved here; only its
            // queue wait moves into the authentic external continuation.
            generation &+= 1; suspended = true; loaded = false
            entries.removeAll(); pending.removeAll()
            cancelled = scheduled
            owner = nil; boundOwner = nil; state = .suspended; notify(reset: true)
            let identity = ComposerOriginalIOIdentity(repository: originalRepositoryID, epoch: originalEpoch, close: UUID())
            let close = ComposerOriginalCloseState(identity: identity, controlVersion: controlVersion,
                admittedWithoutControlOverlap: controlAdmissions == 0, itemIDs: originalItems.keys.sorted { $0.uuidString < $1.uuidString })
            originalClose = close
            return .captured(ComposerOriginalIOClose(repository: self, state: close, externalCaller: externalCaller))
        }
        cancelled?.cancel()
        progressOriginalClose()
        return result
    }

    /// A request is evidence of preparation only, including when items are held.
    func requestedOriginalIO(_ result: ComposerOriginalCloseResult) -> ComposerOriginalWaitOutcome {
        switch result {
        case .unconfirmed(let gap): return .unconfirmed(gap)
        case .captured(let close):
            return locked {
                if let gap = originalGapLocked(close) { return .unconfirmed(gap) }
                return .requestedNotAwaited(close.identity)
            }
        }
    }

    func awaitOriginalIO(_ close: ComposerOriginalIOClose) async throws -> ComposerOriginalWaitOutcome {
        let waiter = ComposerOriginalWaiter()
        let outcome = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                var resolution: Result<ComposerOriginalWaitOutcome, Error>?
                locked {
                    if waiter.cancelled { resolution = .failure(CancellationError()) }
                    else if let gap = originalGapLocked(close) { resolution = .success(.unconfirmed(gap)) }
                    else if close.state.invalidationReturned {
                        resolution = .success(.ordinaryDraftSubmissionsReturned(close.identity, itemIDs: close.state.itemIDs))
                    } else {
                        waiter.continuation = continuation
                        close.state.waiters[waiter.id] = waiter
                    }
                    if resolution != nil { waiter.resolved = true }
                }
                if let resolution { continuation.resume(with: resolution) }
            }
        }, onCancel: {
            var continuation: CheckedContinuation<ComposerOriginalWaitOutcome, Error>?
            self.locked {
                guard !waiter.resolved else { return }
                waiter.cancelled = true
                if let installed = waiter.continuation {
                    continuation = installed
                    waiter.continuation = nil
                    waiter.resolved = true
                    close.state.waiters.removeValue(forKey: waiter.id)
                }
            }
            continuation?.resume(throwing: CancellationError())
        })
        try Task.checkCancellation()
        return locked {
            if let gap = originalGapLocked(close) { return .unconfirmed(gap) }
            return outcome
        }
    }

    private func originalGapLocked(_ close: ComposerOriginalIOClose) -> ComposerOriginalIOGap? {
        guard close.repository === self else { return .foreignRepository }
        guard close.state.identity.epoch == originalEpoch, originalClose === close.state else { return .changedEpoch }
        guard close.externalCaller else { return .originalQueueCaller }
        guard close.state.admittedWithoutControlOverlap, controlAdmissions == 0,
              close.state.controlVersion == controlVersion else { return .configurationOrLegacyOverlap }
        return nil
    }

    // Called only under RAM, before an escaping body captures its token.
    private func reserveOriginalItemLocked() -> ComposerOriginalItem {
        let item = ComposerOriginalItem()
        originalItems[item.id] = item
        return item
    }

    private func offerOriginalItemLocked(_ item: ComposerOriginalItem, after delay: TimeInterval? = nil,
                                         body: @escaping () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem(block: body)
        item.work = work
        let itemID = item.id
        work.notify(queue: ioQueue) { [self] in originalItemReturned(itemID) }
        if let delay { ioQueue.asyncAfter(deadline: .now() + delay, execute: work) }
        else { ioQueue.async(execute: work) }
        return work
    }

    private func originalItemReturned(_ id: UUID) {
        // Detach the original item under RAM; release its actual handle after it.
        let returned = locked { () -> ComposerOriginalItem? in
            originalClose?.pending.remove(id)
            let item = originalItems.removeValue(forKey: id)
            if let work = item?.work, scheduled === work { scheduled = nil }
            return item
        }
        withExtendedLifetime(returned) {}
        progressOriginalClose()
    }

    private func progressOriginalClose() {
        var resolutions: [(CheckedContinuation<ComposerOriginalWaitOutcome, Error>, ComposerOriginalWaitOutcome)] = []
        locked {
            guard let close = originalClose else { return }
            let capability = ComposerOriginalIOClose(repository: self, state: close, externalCaller: true)
            let outcome: ComposerOriginalWaitOutcome?
            if let gap = originalGapLocked(capability) { outcome = .unconfirmed(gap) }
            else if close.invalidationReturned {
                outcome = .ordinaryDraftSubmissionsReturned(close.identity, itemIDs: close.itemIDs)
            } else {
                outcome = nil
                if close.pending.isEmpty, !close.invalidationOffered {
                    close.invalidationOffered = true
                    let capturedBackend = backend
                    let work = DispatchWorkItem { capturedBackend?.invalidate() }
                    // Retain this one actual submission exactly like ordinary work.
                    let item = reserveOriginalItemLocked()
                    item.work = work
                    let itemID = item.id
                    work.notify(queue: ioQueue) { [self] in
                        locked { close.invalidationReturned = true }
                        originalItemReturned(itemID)
                    }
                    ioQueue.async(execute: work)
                }
            }
            if let outcome {
                for waiter in close.waiters.values {
                    if let continuation = waiter.continuation {
                        resolutions.append((continuation, outcome))
                        waiter.continuation = nil
                        waiter.resolved = true
                    }
                }
                close.waiters.removeAll()
            }
        }
        for (continuation, outcome) in resolutions { continuation.resume(returning: outcome) }
    }

    // Control admission precedes the whole existing RAM prefix/provider call.
    private func beginControl() {
        locked { controlAdmissions += 1; controlVersion &+= 1 }
        progressOriginalClose()
    }
    private func endControl() {
        locked { controlAdmissions -= 1 }
        progressOriginalClose()
    }

    init(persistence: ComposerDraftPersistence? = nil, owner: Data? = nil, debounce: TimeInterval = 0.3) {
        self.backend = persistence
        self.owner = owner
        self.boundOwner = owner
        self.debounce = debounce
        ioQueue.setSpecific(key: ioSpecific, value: 1)
        if persistence != nil {
            state = owner == nil ? .waitingForIdentity : .loading
            if owner != nil { retry() }
        }
    }

    private func locked<T>(_ work: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return work()
    }
    var count: Int { locked { entries.count } }
    var pendingCountForTesting: Int { locked { pending.count } }
    var currentGeneration: UInt64 { locked { generation } }
    var persistenceStatus: ComposerDraftStatus { locked { state } }
    func status(for key: ComposerDraftStore.Key, displayedText: String? = nil) -> ComposerDraftStatus {
        locked {
            if suspended { return .suspended }
            guard key.isPersistentDestination, backend != nil else { return .sessionOnly }
            if let displayedText {
                if displayedText.count > ComposerDraftStore.maxDraftLength || displayedText.utf8.count > ComposerDraftPersistence.maxTextBytes {
                    return .unavailable(.tooLarge)
                }
                if displayedText != (entries[key.storageString]?.text ?? "") { return .unavailable(.capacityReached) }
            }
            return state
        }
    }
    func load(_ key: ComposerDraftStore.Key) -> String { locked { entries[key.storageString]?.text ?? "" } }
    func snapshot(_ key: ComposerDraftStore.Key) -> Snapshot {
        locked {
            let entry = entries[key.storageString]
            return Snapshot(key: key, text: entry?.text ?? "", revision: entry?.revision ?? 0, generation: generation)
        }
    }
    @discardableResult
    func save(_ text: String, for key: ComposerDraftStore.Key, generation expected: UInt64? = nil) -> Bool {
        let accepted = locked {
            guard expected == nil || expected == generation else { return false }
            return mutate(text, key: key)
        }
        scheduleSave()
        return accepted
    }
    /// UI admission preserves the previous bounded text if a new edit is refused.
    func admitDisplayedText(_ text: String, for key: ComposerDraftStore.Key, generation: UInt64) -> Bool {
        guard text.utf8.count <= ComposerDraftPersistence.maxTextBytes,
              text.count <= ComposerDraftStore.maxDraftLength else { return false }
        return save(text, for: key, generation: generation)
    }
    func submission(for key: ComposerDraftStore.Key, displayedText: String, generation expected: UInt64) -> Snapshot? {
        locked {
            guard !suspended, generation == expected, let entry = entries[key.storageString],
                  entry.text == displayedText else { return nil }
            return Snapshot(key: key, text: entry.text, revision: entry.revision, generation: generation)
        }
    }
    @discardableResult
    func clearIfUnchanged(_ snapshot: Snapshot) -> Bool {
        let changed = locked { () -> Bool in
            let current = entries[snapshot.key.storageString]
            guard !suspended, generation == snapshot.generation, current?.revision == snapshot.revision,
                  current?.text == snapshot.text else { return false }
            return mutate("", key: snapshot.key)
        }
        if changed { scheduleSave() }
        return changed
    }
    /// Refusal leaves the previous map and tombstones intact. In particular,
    /// no delayed callback can repopulate a suspended post-panic repository.
    private func mutate(_ text: String, key: ComposerDraftStore.Key) -> Bool {
        guard !suspended else { return false }
        guard text.utf8.count <= ComposerDraftPersistence.maxTextBytes else {
            state = .unavailable(.tooLarge); notify(); return false
        }
        let value = String(text.prefix(ComposerDraftStore.maxDraftLength))
        let nextRevision = revision &+ 1
        let entry = value.isEmpty ? nil : Entry(key: key, text: value, updatedAt: Date(), revision: nextRevision,
            unsupported: text.count > ComposerDraftStore.maxDraftLength)
        var candidate = entries
        candidate[key.storageString] = entry
        let doomed = evictionKeys(in: candidate)
        var mutationKeys = Set(pending.keys)
        if backend != nil, key.isPersistentDestination { mutationKeys.insert(key.storageString) }
        if backend != nil {
            for removed in doomed where removed.isPersistentDestination { mutationKeys.insert(removed.storageString) }
        }
        guard mutationKeys.count <= ComposerDraftStore.maxDraftCount else {
            state = .unavailable(.capacityReached); notify(); return false
        }
        revision = nextRevision
        entries = candidate
        if backend != nil, key.isPersistentDestination { pending[key.storageString] = Mutation(entry: entry, revision: revision) }
        for removed in doomed {
            entries.removeValue(forKey: removed.storageString)
            if backend != nil, removed.isPersistentDestination {
                revision &+= 1
                pending[removed.storageString] = Mutation(entry: nil, revision: revision)
            }
        }
        if backend != nil && loaded && !pending.isEmpty { state = .dirty }
        notify(keys: [key])
        return true
    }
    private func evictionKeys(in values: [String: Entry]) -> [ComposerDraftStore.Key] {
        // Transient geohash/routing drafts cannot evict durable records.
        let pools: [[Entry]] = backend == nil ? [Array(values.values)] : [
            values.values.filter { $0.key.isPersistentDestination },
            values.values.filter { !$0.key.isPersistentDestination }
        ]
        return pools.flatMap { pool -> [ComposerDraftStore.Key] in
            guard pool.count > ComposerDraftStore.maxDraftCount else { return [] }
            return pool.sorted { $0.updatedAt < $1.updatedAt }.prefix(pool.count - ComposerDraftStore.maxDraftCount).map(\.key)
        }
    }
    private func notify(keys: Set<ComposerDraftStore.Key> = [],
                        restoredRevisions: [ComposerDraftStore.Key: UInt64] = [:], reset: Bool = false) {
        let event = Change(generation: generation, keys: keys, restoredRevisions: restoredRevisions, reset: reset)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentGeneration == event.generation else { return }
            self.objectWillChange.send()
            self.changes.send(event)
        }
    }
    /// Delayed load events may update only the same untouched destination/revision.
    func restoredText(for key: ComposerDraftStore.Key, from change: Change) -> String? {
        locked {
            guard change.generation == generation, let expected = change.restoredRevisions[key],
                  let entry = entries[key.storageString], entry.revision == expected else { return nil }
            return entry.text
        }
    }
    func configureLive(keychain: KeychainManagerProtocol, owner: Data?) {
        guard !TestEnvironment.isRunningTests else { return }
        beginControl()
        defer { endControl() }
        let admission = locked { () -> UUID? in
            guard !suspended, backend == nil else { return nil }
            return originalEpoch
        }
        if let admission {
            let candidate = ComposerDraftPersistence.defaultFileURL().map {
                ComposerDraftPersistence(keychain: keychain, fileURL: $0)
            }
            locked {
                guard !suspended, originalEpoch == admission, backend == nil else { return }
                guard let candidate else { return }
                backend = candidate
                for entry in entries.values where entry.key.isPersistentDestination {
                    pending[entry.key.storageString] = Mutation(entry: entry, revision: entry.revision)
                }
            }
            withExtendedLifetime(candidate) {}
        }
        setOwner(owner)
    }
    /// Explicitly injected owners are useful to tests without accessing live storage.
    func setOwner(_ newOwner: Data?) {
        beginControl()
        defer { endControl() }
        locked {
            guard !suspended else { return }
            if let boundOwner, let newOwner, boundOwner != newOwner {
                entries.removeAll(); pending.removeAll(); generation &+= 1
                notify(reset: true)
            }
            if owner != newOwner { generation &+= 1 }
            owner = newOwner
            if let newOwner { boundOwner = newOwner }
            loaded = false
            state = backend == nil ? .sessionOnly : (newOwner == nil ? .waitingForIdentity : .loading)
            notify()
        }
        retry()
    }
    func retry(completion: (@MainActor () -> Void)? = nil) {
        let offered = locked { () -> Bool in
            guard !suspended, let backend, let owner else { return false }
            let item = reserveOriginalItemLocked()
            loaded = false; state = .loading; notify()
            let token = (backend, owner, generation)
            _ = offerOriginalItemLocked(item) { [weak self] in
                guard let self, self.isCurrent(token.2, owner: token.1) else { return }
                do {
                    let records = try token.0.load(owner: token.1)
                    self.locked {
                        guard self.isCurrentLocked(token.2, owner: token.1) else { return }
                        // Only edits/tombstones made locally override the validated baseline.
                        var candidate = self.entries.filter { !$0.value.key.isPersistentDestination }
                        var restored: [ComposerDraftStore.Key: UInt64] = [:]
                        for record in records {
                            self.revision &+= 1
                            candidate[record.key.storageString] = Entry(key: record.key, text: record.text,
                                updatedAt: record.updatedAt, revision: self.revision, unsupported: false)
                            if self.pending[record.key.storageString] == nil { restored[record.key] = self.revision }
                        }
                        for (key, mutation) in self.pending { candidate[key] = mutation.entry }
                        // Capacity conflicts preserve the durable baseline and all
                        // pending intents. Never drop a tombstone to make space.
                        guard candidate.values.filter({ $0.key.isPersistentDestination }).count <= ComposerDraftStore.maxDraftCount else {
                            self.loaded = false; self.state = .unavailable(.capacityReached); self.notify(); return
                        }
                        self.entries = candidate
                        self.loaded = true
                        self.state = self.pending.isEmpty ? .durable : .dirty
                        restored = restored.filter { self.entries[$0.key.storageString]?.revision == $0.value }
                        self.notify(keys: Set(restored.keys), restoredRevisions: restored)
                    }
                    self.persistOnQueue(generation: token.2, owner: token.1)
                } catch { self.fail(error, generation: token.2, owner: token.1) }
                if let completion { Task { @MainActor in completion() } }
            }
            return true
        }
        if !offered, let completion { Task { @MainActor in completion() } }
    }
    private func scheduleSave() {
        var previous: DispatchWorkItem?
        locked {
            previous = scheduled
            previous?.cancel()
            guard backend != nil, loaded, !suspended, let owner else { return }
            let item = reserveOriginalItemLocked()
            let token = generation
            scheduled = offerOriginalItemLocked(item, after: debounce) { [weak self] in
                self?.persistOnQueue(generation: token, owner: owner)
            }
        }
        withExtendedLifetime(previous) {}
    }
    /// Queue a best-effort flush; it never claims a still-pending keystroke is durable.
    func flush(completion: (@MainActor () -> Void)? = nil) {
        let offered = locked { () -> Bool in
            scheduled?.cancel()
            guard loaded, !suspended, let owner else { return false }
            let item = reserveOriginalItemLocked()
            let token = generation
            _ = offerOriginalItemLocked(item) { [weak self] in
                self?.persistOnQueue(generation: token, owner: owner)
                if let completion { Task { @MainActor in completion() } }
            }
            return true
        }
        if !offered { retry(completion: completion) }
    }
    private func persistOnQueue(generation token: UInt64, owner: Data) {
        let snapshot: (ComposerDraftPersistence, [ComposerDraftRecord], UInt64)? = locked {
            guard isCurrentLocked(token, owner: owner), loaded, !pending.isEmpty, let backend else { return nil }
            let persistent = entries.values.filter { $0.key.isPersistentDestination }
            guard !persistent.contains(where: \.unsupported) else {
                state = .unavailable(.tooLarge); notify(); return nil
            }
            state = .saving; notify()
            return (backend, persistent.map { ComposerDraftRecord(key: $0.key, text: $0.text, updatedAt: $0.updatedAt) }, revision)
        }
        guard let snapshot else { return }
        do {
            try snapshot.0.persist(snapshot.1, owner: owner)
            locked {
                guard isCurrentLocked(token, owner: owner) else { return }
                pending = pending.filter { $0.value.revision > snapshot.2 }
                state = pending.isEmpty ? .durable : .dirty
                notify()
            }
            scheduleSave()
        } catch { fail(error, generation: token, owner: owner) }
    }
    private func fail(_ error: Error, generation: UInt64, owner: Data) {
        locked {
            guard isCurrentLocked(generation, owner: owner) else { return }
            loaded = false
            state = .unavailable(error as? ComposerDraftFailure ?? .storageUnavailable)
            notify()
        }
    }
    private func isCurrent(_ generation: UInt64, owner: Data) -> Bool {
        locked { isCurrentLocked(generation, owner: owner) }
    }
    private func isCurrentLocked(_ generation: UInt64, owner: Data) -> Bool {
        !suspended && self.generation == generation && self.owner == owner
    }
    func resetMemory() {
        beginControl()
        defer { endControl() }
        locked {
            generation &+= 1; entries.removeAll(); pending.removeAll(); scheduled?.cancel()
            loaded = false; state = suspended ? .suspended : .sessionOnly
            notify(reset: true)
        }
    }
    /// Main may wait at this security barrier. Actual IO remains on the utility
    /// queue; that queue never synchronously waits on Main or a UI callback.
    func suspendForPanic() {
        beginControl()
        defer { endControl() }
        locked {
            generation &+= 1; suspended = true; loaded = false
            entries.removeAll(); pending.removeAll(); scheduled?.cancel()
            owner = nil; boundOwner = nil; state = .suspended; notify(reset: true)
        }
        onIO { locked { backend }?.invalidate() }
    }
    func wipeForPanic(defaultFileURL: URL? = nil) throws {
        beginControl()
        defer { endControl() }
        try onIO {
            if let backend = locked({ backend }) { try backend.wipeFile() }
            else if let defaultFileURL {
                // Startup recovery runs before AppRuntime configures a backend.
                let files = ComposerDraftPersistence.FileAccess.live
                do { try files.remove(defaultFileURL) }
                catch {
                    let ns = error as NSError
                    guard (ns.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code))
                        || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT)) else { throw error }
                }
                do { _ = try files.read(defaultFileURL); throw ComposerDraftFailure.writeUnconfirmed }
                catch {
                    let ns = error as NSError
                    guard (ns.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code))
                        || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT)) else { throw error }
                }
            }
        }
    }
    func completePanic(success: Bool, owner: Data?) {
        beginControl()
        defer { endControl() }
        locked {
            guard success else { return }
            originalEpoch = UUID()
            originalClose = nil
            suspended = false; self.owner = owner; boundOwner = owner
            loaded = false; state = backend == nil ? .sessionOnly : .loading; notify()
        }
        if success { retry() }
    }
    private func onIO<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: ioSpecific) != nil { return try body() }
        return try ioQueue.sync(execute: body)
    }
    @discardableResult
    func replaceForTesting(_ newEntries: [String: String]) -> [String: String] {
        beginControl()
        defer { endControl() }
        return locked {
            let previous = entries.mapValues(\.text)
            generation &+= 1; scheduled?.cancel(); entries.removeAll(); pending.removeAll()
            if backend == nil {
                originalEpoch = UUID(); originalClose = nil
                suspended = false; owner = nil; boundOwner = nil
            }
            for (key, text) in newEntries {
                let decoded: ComposerDraftStore.Key
                if key == "mesh" { decoded = .mesh }
                else if key.hasPrefix("geo:") { decoded = .location(geohash: String(key.dropFirst(4))) }
                else if key.hasPrefix("noise:"), let data = Data(hexString: String(key.dropFirst(6))), data.count == 32 { decoded = .privateNoiseKey(data) }
                else { decoded = .privateChat(stableID: String(key.dropFirst(3))) }
                revision &+= 1
                entries[key] = Entry(key: decoded, text: text, updatedAt: Date(), revision: revision, unsupported: false)
            }
            state = backend == nil ? .sessionOnly : .loading
            return previous
        }
    }
}
