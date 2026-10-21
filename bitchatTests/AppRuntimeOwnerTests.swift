// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

import Combine
import Testing
@testable import bitchat

@MainActor
private final class SyntheticAppRuntime: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    func signalChange() { objectWillChange.send() }
}

@MainActor
struct AppRuntimeOwnerTests {
    @Test
    func testHostDoesNotInvokeRuntimeFactory() {
        var calls = 0
        let owner = AppRuntimeOwner(isTesting: true) {
            calls += 1
            return SyntheticAppRuntime()
        }

        #expect(calls == 0)
        #expect(owner.runtime == nil)
    }

    @Test
    func liveOwnerConstructsOnceAndSharesTheSameRuntimeAcrossReaders() {
        var calls = 0
        let owner = AppRuntimeOwner(isTesting: false) {
            calls += 1
            return SyntheticAppRuntime()
        }

        let firstWindow = owner.runtime
        let secondWindow = owner.runtime
        #expect(calls == 1)
        #expect(firstWindow != nil)
        #expect(firstWindow === secondWindow)
    }

    @Test
    func runtimeChangesAreForwardedSynchronouslyToTheOwner() throws {
        let owner = AppRuntimeOwner(isTesting: false) { SyntheticAppRuntime() }
        let runtime = try #require(owner.runtime)
        var changes = 0
        let observation = owner.objectWillChange.sink { changes += 1 }

        runtime.signalChange()

        #expect(changes == 1)
        withExtendedLifetime(observation) {}
    }

    @Test
    func observationDoesNotRetainTheOwnerOrItsRuntime() {
        weak var weakOwner: AppRuntimeOwner<SyntheticAppRuntime>?
        weak var weakRuntime: SyntheticAppRuntime?
        do {
            let owner = AppRuntimeOwner(isTesting: false) { SyntheticAppRuntime() }
            weakOwner = owner
            weakRuntime = owner.runtime
            #expect(weakOwner != nil)
            #expect(weakRuntime != nil)
        }

        #expect(weakOwner == nil)
        #expect(weakRuntime == nil)
    }
}
