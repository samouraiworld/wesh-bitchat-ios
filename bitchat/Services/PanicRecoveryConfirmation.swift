// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

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
