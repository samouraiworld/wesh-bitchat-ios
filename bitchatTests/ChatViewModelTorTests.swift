//
// ChatViewModelTorTests.swift
// bitchatTests
//
// Tests for ChatViewModel+Tor.swift Tor lifecycle notification handlers.
//

import Testing
import Foundation
@testable import bitchat

// MARK: - Test Helpers

@MainActor
private func makeTestableViewModel() -> (viewModel: ChatViewModel, transport: MockTransport) {
    let keychain = MockKeychain()
    let keychainHelper = MockKeychainHelper()
    let idBridge = NostrIdentityBridge(keychain: keychainHelper)
    let identityManager = MockIdentityManager(keychain)
    let transport = MockTransport()

    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: identityManager,
        transport: transport
    )

    return (viewModel, transport)
}

// MARK: - Tor Notification Handler Tests

struct ChatViewModelTorTests {

    // MARK: - handleTorWillStart Tests



    // MARK: - handleTorWillRestart Tests



    // MARK: - handleTorDidBecomeReady Tests




    // MARK: - handleTorPreferenceChanged Tests

    @Test @MainActor
    func handleTorPreferenceChanged_clearsBlockedBanner() async {
        let (viewModel, _) = makeTestableViewModel()

        // Setup: the retained connectivity banner is showing a stalled bootstrap.
        viewModel.torBlocked = true

        // Action
        viewModel.handleTorPreferenceChanged(Notification(name: .init("test")))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // A preference notification clears the retained connectivity banner.
        #expect(!viewModel.torBlocked)
    }

    @Test @MainActor
    func handleTorDidBecomeReady_clearsBlockedBanner() async {
        let (viewModel, _) = makeTestableViewModel()

        // Setup: a stalled bootstrap raised the banner, then tor got through.
        viewModel.torBlocked = true

        // Action
        viewModel.handleTorDidBecomeReady()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Assert
        #expect(!viewModel.torBlocked)
    }
}
