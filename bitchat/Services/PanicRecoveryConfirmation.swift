// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

import Combine
import Foundation

/// Common confirmed erase action for the root alert, Settings and the hold shortcut.
@MainActor
func makePanicEraseAction(
    erase: @escaping () -> Bool,
    report: @escaping (Bool) -> Void,
    needsBootstrap: @escaping () -> Bool,
    bootstrap: @escaping () -> Void,
    needsRuntimeStart: @escaping () -> Bool,
    startRuntime: @escaping () -> Void
) -> () -> Bool {
    {
        let completed = erase()
        report(completed)
        if completed {
            if needsBootstrap() { bootstrap() }
            if needsRuntimeStart() { startRuntime() }
        }
        return completed
    }
}

/// Application-owned continuation. Running is submission, never erase completion.
@MainActor
final class PanicEraseCommand: ObservableObject {
    typealias AttemptID = UUID
    enum Phase: Equatable { case idle, running(AttemptID), finished(AttemptID, Bool) }
    enum Submission { case started(AttemptID), busy(AttemptID), unavailable }
    typealias Work = @MainActor () async -> Void
    typealias Creator = @MainActor (@escaping Work) -> Task<Void, Never>
    typealias Erase = @MainActor () async throws -> Bool
    typealias Begin = @MainActor () -> Erase?

    static let mainActorCreator: Creator = { work in Task { @MainActor in await work() } }

    @MainActor private final class Attempt {
        let id = AttemptID()
        var retainedTasks: [Task<Void, Never>] = []
        var bodyStarted = false
    }
    @Published private(set) var phase: Phase = .idle
    private var active: Attempt?
    private let begin: Begin
    private let creator: Creator
    private let needsBootstrap: () -> Bool
    private let bootstrap: () -> Void
    private let needsRuntimeStart: () -> Bool
    private let startRuntime: () -> Void

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    init(begin: @escaping Begin, creator: @escaping Creator,
         needsBootstrap: @escaping () -> Bool, bootstrap: @escaping () -> Void,
         needsRuntimeStart: @escaping () -> Bool, startRuntime: @escaping () -> Void) {
        self.begin = begin; self.creator = creator
        self.needsBootstrap = needsBootstrap; self.bootstrap = bootstrap
        self.needsRuntimeStart = needsRuntimeStart; self.startRuntime = startRuntime
    }

    @discardableResult
    func submit(report: @escaping (Bool) -> Void = { _ in }) -> Submission {
        if let active { return .busy(active.id) }
        let attempt = Attempt()
        active = attempt
        phase = .running(attempt.id)
        // The real begin runs now: original fences and durable intent precede Task creation.
        guard let erase = begin() else {
            report(false)
            if active === attempt {
                active = nil
                phase = .finished(attempt.id, false)
            }
            return .unavailable
        }
        let handle = creator { [self, attempt] in
            guard active === attempt, !attempt.bodyStarted else { return }
            attempt.bodyStarted = true
            let completed: Bool
            do {
                // Always invoke the prepared continuation, including already-cancelled Tasks,
                // so its original attempt's cleanup/defer can run.
                let erased = try await erase()
                try Task.checkCancellation()
                completed = erased
            } catch {
                // Cancellation/error is a failed outcome; durable intent remains pending.
                completed = false
            }
            // Reuse the actual synchronous post-completion ordering, after the real Bool.
            _ = makePanicEraseAction(
                erase: { completed }, report: report,
                needsBootstrap: needsBootstrap, bootstrap: bootstrap,
                needsRuntimeStart: needsRuntimeStart, startRuntime: startRuntime
            )()
            if active === attempt {
                attempt.retainedTasks.removeAll()
                active = nil
                phase = .finished(attempt.id, completed)
            }
        }
        // Always attach the actual returned Task, even if a custom creator completed inline.
        attempt.retainedTasks.append(handle)
        if active !== attempt { attempt.retainedTasks.removeAll() }
        return .started(attempt.id)
    }
}
