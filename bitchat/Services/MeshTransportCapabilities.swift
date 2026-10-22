import BitFoundation
import CoreBluetooth
import Foundation

/// Optional identity recovery. Retrying never deletes existing identity data or
/// overrides a transport stop or panic suspension.
protocol MeshIdentityRecovering: AnyObject {
    var noiseIdentityAvailability: NoiseIdentityAvailability { get }
    var isNoiseIdentityTrafficAllowed: Bool { get }
    func retryNoiseIdentityRecovery(completion: @escaping @MainActor (Bool) -> Void)
}


/// Optional transport capabilities, discovered with `as?` instead of casting
/// to a concrete transport class. `Transport` stays the contract every
/// transport genuinely implements; a capability protocol here is the
/// contract for one mesh-only feature surface, so app wiring depends on the
/// feature it needs rather than on `BLEService` itself.

/// Radio-state reporting for transports backed by a local radio.
protocol BluetoothStateReporting: AnyObject {
    func getCurrentBluetoothState() -> CBManagerState
}

/// Panic-mode lifecycle for transports that own durable identity state.
/// A transport implementing this owns its own restart sequencing:
/// `completePanicReset` decides whether services come back, so generic
/// `startServices()` calls after a panic belong only to transports that
/// don't implement it.
protocol PanicResettingTransport: AnyObject {
    /// Quiesces the radio and drains in-flight work ahead of a panic wipe.
    func suspendForPanicReset()
    /// Finishes a panic wipe, optionally restarting services.
    func completePanicReset(restartServices: Bool)
    /// Rotates the transport identity as part of a panic reset.
    func resetIdentityForPanic(currentNickname: String, restartServices: Bool)
}

/// Courier store-and-forward: seal a message to the recipient's static
/// key and hand it to connected couriers for physical delivery while the
/// recipient is offline. Returns false when the transport cannot courier.
protocol MeshCourierTransporting: AnyObject {
    @discardableResult
    func sendCourierMessage(_ content: String, messageID: String, recipientNoiseKey: Data, via couriers: [PeerID]) -> Bool
}

/// Mesh diagnostics (/ping, /trace).
protocol MeshDiagnosing: AnyObject {
    /// Sends a directed ping probe; the completion fires exactly once on
    /// the main actor with the measured result, or nil on timeout.
    func sendMeshPing(to peerID: PeerID, completion: @escaping @MainActor (MeshPingResult?) -> Void)
    /// Estimated intermediate hops toward `peerID` from gossiped topology
    /// ([] = direct link, nil = no known path).
    func computeMeshPath(to peerID: PeerID) -> [PeerID]?
}

/// QR verification over the Noise session.
protocol MeshVerifying: AnyObject {
    func sendVerifyChallenge(to peerID: PeerID, noiseKeyHex: String, nonceA: Data)
    func sendVerifyResponse(to peerID: PeerID, noiseKeyHex: String, nonceA: Data)
}

/// Store-and-forward archive: the public messages this device is carrying
/// for gossip sync, decoded for display as "heard here earlier" echoes.
protocol MeshPublicArchiving: AnyObject {
    func collectArchivedPublicMessages(completion: @escaping @MainActor ([ArchivedPublicMessage]) -> Void)
    /// Drops any carried public messages from a (newly blocked) sender so
    /// they can't resurface as archived echoes on a later launch.
    func purgeArchivedPublicMessages(from peerID: PeerID)
    /// Erases the whole carried public-message archive, on disk included.
    func purgeAllArchivedPublicMessages()
}
