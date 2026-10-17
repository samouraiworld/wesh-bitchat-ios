import BitFoundation
import Foundation

/// Lock-backed record of which Noise generation each peer's authenticated
/// peer-state exchange (`NoisePayloadType.authenticatedPeerState`) is bound
/// to. A fresh Noise authentication rotates the generation UUID, so a state
/// packet from a replaced session cannot bind a signing key.
///
/// Lock-backed rather than engine-confined: several transitions run inside
/// noise-manager critical sections that the engine is sync-waiting on (where
/// re-entering the engine would self-deadlock, but taking a leaf lock is
/// safe). Every method is one whole transition under the lock.
final class BLEAuthenticatedPeerStateSessions: @unchecked Sendable {
    private struct SendProgress {
        let sessionGeneration: UUID
        var sentInitial = false
        var sentEcho = false
    }

    private let lock = NSLock()
    private var sessionGenerations: [PeerID: UUID] = [:]
    private var sendProgress: [PeerID: SendProgress] = [:]

    func currentGeneration(for peerID: PeerID) -> UUID? {
        lock.withLock { sessionGenerations[peerID] }
    }

    /// Installs a freshly authenticated generation and resets its send
    /// slots. Returns false when the generation is already current — the
    /// same-generation reconciliation path, which must not resend state.
    func beginAuthenticatedGeneration(for peerID: PeerID, generation: UUID) -> Bool {
        lock.withLock {
            guard sessionGenerations[peerID] != generation else { return false }
            sessionGenerations[peerID] = generation
            sendProgress[peerID] = SendProgress(sessionGeneration: generation)
            return true
        }
    }

    /// Consumes one peer-state send slot (initial or echo) for the current
    /// generation. Returns whether the packet should actually go out.
    func markPeerStateSend(for peerID: PeerID, echo: Bool) -> Bool {
        lock.withLock {
            guard let generation = sessionGenerations[peerID],
                  var progress = sendProgress[peerID],
                  progress.sessionGeneration == generation else { return false }
            if echo {
                guard !progress.sentEcho else { return false }
                progress.sentEcho = true
            } else {
                guard !progress.sentInitial else { return false }
                progress.sentInitial = true
            }
            sendProgress[peerID] = progress
            return true
        }
    }

    /// A session clear retires the peer's generation-bound record.
    func clearSession(for peerID: PeerID) {
        lock.withLock {
            sessionGenerations.removeValue(forKey: peerID)
            sendProgress.removeValue(forKey: peerID)
        }
    }

    /// Panic wipe: no pre-panic session record survives.
    func panicReset() {
        lock.withLock {
            sessionGenerations.removeAll()
            sendProgress.removeAll()
        }
    }
}
