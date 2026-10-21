// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

import Foundation
import Testing
@testable import bitchat

/// Legacy cleanup that fails at launch (Keychain or App Group still locked before first
/// unlock) must not wait for a tap, and a pending erase found by its retry must run.
@Suite(.serialized)
struct StartupCleanupRetryTests {
    private final class Fixture {
        var locked = true
        var pending = false
        var events: [String] = []
    }

    @MainActor
    private func makeBlockedViewModel(_ fixture: Fixture) -> (ChatViewModel, MockTransport) {
        let keychain = MockKeychain()
        let transport = MockTransport()
        let wipes = PanicPersistentStoreWipes(
            courier: { true }, bridge: { true }, publicArchive: { true }, prekeys: { true },
            board: { true }, geography: { true }, sightings: { !fixture.locked },
            legacyGroups: { true }, sharedContent: { true }
        )
        let operations = PanicRecoveryOperations(
            isPending: { fixture.pending },
            begin: {
                fixture.events.append("begin")
                return PanicRecoveryIntent(fileMarkerEstablished: true, externalMarkerEstablished: false)
            },
            wipeMedia: { _ in fixture.events.append("wipe") },
            complete: { fixture.events.append("complete"); fixture.pending = false }
        )
        let viewModel = ChatViewModel(
            keychain: keychain, idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain), transport: transport,
            panicRecoveryOperations: operations, panicPersistentStoreWipes: wipes,
            startupRetirementBlocked: true
        )
        return (viewModel, transport)
    }

    @Test @MainActor
    func blockedCleanupRetriesOnItsOwnOnceDataIsReadable() async {
        let fixture = Fixture()
        let (viewModel, _) = makeBlockedViewModel(fixture)
        #expect(viewModel.startupRetirementBlocked && !viewModel.networkActivationAllowed)

        fixture.locked = false
        for name in ChatViewModel.startupCleanupRetryNotifications {
            NotificationCenter.default.post(name: name, object: nil)
        }
        let deadline = Date().addingTimeInterval(TestConstants.settleTimeout)
        while viewModel.startupRetirementBlocked, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(!viewModel.startupRetirementBlocked)
        #expect(viewModel.networkActivationAllowed)
    }

    @Test @MainActor
    func retryThatFindsAPendingEraseRunsItInsteadOfStopping() {
        let fixture = Fixture()
        let (viewModel, transport) = makeBlockedViewModel(fixture)
        fixture.locked = false
        fixture.pending = true

        #expect(viewModel.retryStartupRetirement())

        #expect(fixture.events == ["begin", "wipe", "complete"])
        #expect(!fixture.pending)
        #expect(transport.emergencyDisconnectCallCount == 1)
        #expect(!viewModel.startupRetirementBlocked && !viewModel.panicRecoveryBlocked)
        #expect(viewModel.networkActivationAllowed)
    }
}
