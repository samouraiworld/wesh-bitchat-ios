// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

import Combine

/// App-scoped ownership keeps one runtime shared by every window. Runtime
/// change notifications are delivered on the main actor, like its mutations.
@MainActor
final class AppRuntimeOwner<Runtime: ObservableObject>: ObservableObject {
    let runtime: Runtime?
    private var runtimeChanges: AnyCancellable?

    init(isTesting: Bool, makeRuntime: () -> Runtime) {
        guard !isTesting else {
            runtime = nil
            return
        }
        let runtime = makeRuntime()
        self.runtime = runtime
        runtimeChanges = runtime.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}
