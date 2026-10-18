import Foundation
import BitLogger
import Combine
import Tor

@MainActor
protocol NetworkActivationTorControlling: AnyObject {
    func setAutoStartAllowed(_ allowed: Bool)
    func startIfNeeded()
    func shutdownCompletely()
}

@MainActor
protocol NetworkActivationRelayControlling: AnyObject {
    func connect()
    func disconnect()
}

protocol NetworkActivationProxyControlling: AnyObject {
    func setProxyMode(useTor: Bool)
}

extension TorManager: NetworkActivationTorControlling {}
extension NostrRelayManager: NetworkActivationRelayControlling {}
extension TorURLSession: NetworkActivationProxyControlling {}

/// Coordinates when the app is allowed to start Tor and connect to Nostr relays.
/// Explicit Internet opt-in and a usable network path are both required.
/// Internet always uses Tor; BLE mesh is independent of this gate.
@MainActor
final class NetworkActivationService: ObservableObject {
    static let shared = NetworkActivationService()

    @Published private(set) var activationAllowed: Bool = false
    @Published private(set) var userTorEnabled: Bool = true
    @Published private(set) var userInternetEnabled: Bool = true

    /// BLE does not depend on this opt-in. Wesh nearby mode disables all relay activation.
    func setUserInternetEnabled(_ enabled: Bool) {
        userInternetEnabled = enabled
        if started { reevaluate() }
    }
    /// Coarse, debounced network reachability. `false` only when the OS reports
    /// no usable interface at all. Surfaced for UI ("offline" vs "connecting").
    @Published private(set) var isNetworkReachable: Bool = true

    private var cancellables = Set<AnyCancellable>()
    private var started = false
    /// Legacy preference erased at start; it can no longer enable direct routing.
    nonisolated static let torPreferenceKey = "networkActivationService.userTorEnabled"
    private var torAutoStartDesired: Bool = false
    private let storage: UserDefaults
    private let reachabilityMonitor: NetworkReachabilityMonitoring
    private let torController: NetworkActivationTorControlling
    // Resolved lazily: NostrRelayManager.init() reads NetworkActivationService.shared
    // (via its live dependencies), so capturing NostrRelayManager.shared here would
    // re-enter whichever singleton's dispatch_once started first and trap at launch.
    private lazy var relayController: NetworkActivationRelayControlling = relayControllerProvider()
    private let relayControllerProvider: () -> NetworkActivationRelayControlling
    private let proxyController: NetworkActivationProxyControlling
    /// Wesh Internet mode: the opt-in toggle is the whole policy and Tor is
    /// mandatory. The stored direct-mode preference is ignored and erased, and
    /// the proxy never switches to the direct session.

    private init() {
        storage = .standard
        reachabilityMonitor = NWPathReachabilityMonitor()
        torController = TorManager.shared
        relayControllerProvider = { NostrRelayManager.shared }
        proxyController = TorURLSession.shared
    }

    internal init(
        storage: UserDefaults,
        reachabilityMonitor: NetworkReachabilityMonitoring,
        torController: NetworkActivationTorControlling,
        relayController: NetworkActivationRelayControlling,
        proxyController: NetworkActivationProxyControlling
    ) {
        self.storage = storage
        self.reachabilityMonitor = reachabilityMonitor
        self.torController = torController
        self.relayControllerProvider = { relayController }
        self.proxyController = proxyController
    }

    func start() {
        guard !started else { return }
        started = true

        // Retired direct-mode preferences cannot opt this service out of Tor.
        storage.removeObject(forKey: Self.torPreferenceKey)
        userTorEnabled = true

        // Begin (idempotent) reachability monitoring and seed initial state.
        reachabilityMonitor.start()
        isNetworkReachable = reachabilityMonitor.isReachable

        // Initial compute
        let allowed = effectiveAllowed()
        activationAllowed = allowed
        torAutoStartDesired = allowed && userTorEnabled
        torController.setAutoStartAllowed(torAutoStartDesired)
        applyTorState(torDesired: torAutoStartDesired)
        if allowed {
            relayController.connect()
        } else {
            relayController.disconnect()
        }

        // React to network reachability changes (debounced, unsatisfied-only).
        reachabilityMonitor.reachabilityPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reachable in
                guard let self else { return }
                guard reachable != self.isNetworkReachable else { return }
                self.isNetworkReachable = reachable
                SecureLogger.info(
                    "NetworkActivationService: isNetworkReachable -> \(reachable)",
                    category: .session
                )
                self.reevaluate()
            }
            .store(in: &cancellables)
    }

    /// Stops all internet-facing work at the synchronous panic boundary.
    /// `start()` may be called again only after the full wipe commits.
    func stopForPanic() {
        cancellables.removeAll()
        started = false
        reachabilityMonitor.stop()
        activationAllowed = false
        torAutoStartDesired = false
        relayController.disconnect()
        torController.setAutoStartAllowed(false)
        applyTorState(torDesired: false)
    }

    private func reevaluate() {
        guard started else { return }
        let allowed = effectiveAllowed()
        let torDesired = allowed && userTorEnabled
        let statusChanged = allowed != activationAllowed
        let torChanged = torDesired != torAutoStartDesired
        if statusChanged {
            SecureLogger.info("NetworkActivationService: activationAllowed -> \(allowed)", category: .session)
            activationAllowed = allowed
        }
        if statusChanged || torChanged {
            torAutoStartDesired = torDesired
            torController.setAutoStartAllowed(torDesired)
            applyTorState(torDesired: torDesired)
        }

        if allowed {
            if torChanged {
                // Reset relay sockets when switching transport path (Tor ↔︎ direct)
                relayController.disconnect()
            }
            relayController.connect()
        } else if statusChanged {
            relayController.disconnect()
        }
    }

    /// Effective gate: base policy AND a usable network path. When there is
    /// provably no network, Tor bootstrap and relay reconnects are suppressed.
    private func effectiveAllowed() -> Bool {
        userInternetEnabled && reachabilityMonitor.isReachable
    }

    private func applyTorState(torDesired: Bool) {
        proxyController.setProxyMode(useTor: true)
        if torDesired {
            torController.startIfNeeded()
        } else {
            torController.shutdownCompletely()
        }
    }
}
