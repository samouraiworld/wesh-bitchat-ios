import Foundation
import Tor

extension ChatViewModel {
    @objc func handleTorWillStart() {
        Task { @MainActor in self.torBlocked = false }
    }

    @objc func handleTorWillRestart() {
        Task { @MainActor in self.torBlocked = false }
    }

    @objc func handleTorDidBecomeReady() {
        Task { @MainActor in self.torBlocked = false }
    }

    @objc func handleTorBootstrapDidStall() {
        Task { @MainActor in
            guard TorManager.shared.torEnforced,
                  NetworkActivationService.shared.activationAllowed else { return }
            self.torBlocked = true
        }
    }

    @objc func handleTorPreferenceChanged(_: Notification) {
        Task { @MainActor in self.torBlocked = false }
    }
}
