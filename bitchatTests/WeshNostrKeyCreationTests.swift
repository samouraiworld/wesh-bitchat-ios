// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>

import Testing
@testable import bitchat

/// My QR always carries my npub, so the Nostr key is made locally once the welcome is done,
/// whether Internet is on or off. It is never overwritten, nor made while an erase is unconfirmed.
struct WeshNostrKeyCreationTests {
    @MainActor
    private func makeViewModel(_ keychain: MockKeychain, _ bridge: NostrIdentityBridge) -> ChatViewModel {
        ChatViewModel(keychain: keychain, idBridge: bridge,
                      identityManager: MockIdentityManager(keychain), transport: MockTransport())
    }

    @Test @MainActor
    func aKeyIsMadeOnceTheWelcomeIsDoneAndThenKept() throws {
        let helper = MockKeychainHelper()
        let bridge = NostrIdentityBridge(keychain: helper)
        let viewModel = makeViewModel(MockKeychain(), bridge)

        #expect(!viewModel.ensureWeshNostrIdentity(welcomeDone: false))
        #expect(try bridge.storedNostrIdentity() == nil)

        #expect(viewModel.ensureWeshNostrIdentity(welcomeDone: true))
        let made = try #require(try bridge.storedNostrIdentity())
        #expect(viewModel.ensureWeshNostrIdentity(welcomeDone: true))
        #expect(try bridge.storedNostrIdentity()?.npub == made.npub)
    }

    @Test @MainActor
    func aLockedKeychainIsNeverTakenForAMissingKey() throws {
        let helper = MockKeychainHelper()
        let bridge = NostrIdentityBridge(keychain: helper)
        let viewModel = makeViewModel(MockKeychain(), bridge)
        let existing = try #require(try bridge.getCurrentNostrIdentity())
        helper.simulatedGenericReadError = .deviceLocked

        #expect(!viewModel.ensureWeshNostrIdentity(welcomeDone: true))

        helper.simulatedGenericReadError = nil
        #expect(try bridge.storedNostrIdentity()?.npub == existing.npub)
    }

    @Test @MainActor
    func noKeyIsMadeWhileAnEraseIsUnconfirmed() throws {
        let keychain = MockKeychain()
        keychain.simulatedDeleteAllResult = false
        let helper = MockKeychainHelper()
        let bridge = NostrIdentityBridge(keychain: helper)
        let viewModel = makeViewModel(keychain, bridge)
        #expect(!viewModel.panicClearAllData())
        #expect(!viewModel.networkActivationAllowed)

        #expect(!viewModel.ensureWeshNostrIdentity(welcomeDone: true))
        #expect(try bridge.storedNostrIdentity() == nil)
    }
}
