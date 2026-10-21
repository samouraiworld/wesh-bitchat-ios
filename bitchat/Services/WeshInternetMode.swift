import BitLogger
import Combine
import Foundation
import Tor

/// Wesh Internet mode policy constants. Off by default; Tor is mandatory.
enum WeshInternetPolicy {
    /// Intersection of the upstream iOS and Android defaults, so every
    /// BitChat client listens there. No custom relays.
    static let pinnedRelays = ["wss://relay.damus.io", "wss://relay.primal.net", "wss://offchain.pub"]
    /// Matches the Tor bootstrap deadline.
    static let connectingStallSeconds: TimeInterval = 75
    /// Bounded wait for Arti to exit before its directory is deleted at panic.
    static let artiStopTimeoutSeconds: TimeInterval = 3
    static let artiDeleteAttempts = 3

    /// Arti keeps its `state` and `cache` directories under this one.
    static func artiDataDirectory(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("bitchat/arti", isDirectory: true)
    }
}

enum WeshInternetState: Equatable {
    enum Failure: Equatable {
        case torBlocked, noNetwork, relaysUnreachable
        /// Tor could not be forced, or a relay was connected while Tor was
        /// not ready: the network is switched off until an explicit retry.
        case routeFault
        /// Arti exited mid-session without being asked to: the network is
        /// switched off until an explicit retry.
        case torStopped

        /// Faults that switch the network off and survive input changes and
        /// resume until an explicit retry.
        var isHard: Bool { self == .routeFault || self == .torStopped }
    }
    case off
    case connecting(torProgress: Int)
    /// Tor ready and at least one pinned relay connected.
    case on
    /// iOS app in background; Connecting again on resume.
    case paused
    case error(Failure)
}

/// Pure transitions of the Internet mode. Side effects live in `WeshInternetMode`.
struct WeshInternetStateMachine: Equatable {
    struct Inputs: Equatable {
        var networkReachable = true
        var torReady = false
        var torProgress = 0
        var relayConnected = false
    }

    enum Event: Equatable {
        case toggle(Bool)
        case panic
        case inputs(Inputs)
        case stallTimeout
        case routeFault
        /// Arti exited without a stop request.
        case torStopped
        case retry
        case background
        case foreground
    }

    private(set) var state: WeshInternetState = .off
    private(set) var inputs = Inputs()

    init(enabled: Bool = false, inputs: Inputs = Inputs()) {
        self.inputs = inputs
        if enabled { state = connecting() }
    }

    var isEnabled: Bool { state != .off }

    mutating func handle(_ event: Event) {
        switch event {
        case .toggle(let on):
            if !on {
                state = .off
            } else if state == .off {
                state = connecting()
            }
        case .panic:
            state = .off
        case .inputs(let new):
            let networkChanged = new.networkReachable != inputs.networkReachable
            inputs = new
            switch state {
            case .off, .paused:
                break
            case .error(let failure) where failure.isHard:
                break
            case .connecting, .on, .error:
                if inputs.relayConnected && !inputs.torReady {
                    state = .error(.routeFault)
                } else if case .error = state {
                    if networkChanged || isOnline { state = connecting() }
                } else {
                    state = connecting()
                }
            }
        case .stallTimeout:
            if case .connecting = state {
                state = .error(inputs.torReady ? .relaysUnreachable : .torBlocked)
            }
        case .routeFault:
            if state != .off { state = .error(.routeFault) }
        case .torStopped:
            // Also replaces a route fault: TorManager drops readiness before
            // it posts the exit, so a connected relay can be seen as a route
            // fault a moment earlier. The cause is the Arti exit.
            switch state {
            case .connecting, .on, .error: state = .error(.torStopped)
            case .off, .paused: break
            }
        case .retry:
            if case .error = state { state = connecting() }
        case .background:
            // A hard fault stays until an explicit retry, even across resume.
            if state != .off && !isInHardFault { state = .paused }
        case .foreground:
            if state == .paused { state = connecting() }
        }
    }

    private var isInHardFault: Bool {
        if case .error(let failure) = state { return failure.isHard }
        return false
    }

    private var isOnline: Bool { inputs.networkReachable && inputs.torReady && inputs.relayConnected }

    /// Connecting, resolved against what is already known.
    private func connecting() -> WeshInternetState {
        if inputs.relayConnected && !inputs.torReady { return .error(.routeFault) }
        if !inputs.networkReachable { return .error(.noNetwork) }
        if isOnline { return .on }
        return .connecting(torProgress: inputs.torReady ? 100 : min(max(inputs.torProgress, 0), 99))
    }
}

/// Observable Internet mode for the Wesh UI.
///
/// UI contract: read `state`, `isEnabled`, `needsDisclosure`; once the
/// disclosure has been shown call `acceptDisclosure()`, then `setEnabled(true)`
/// (false = refused: disclosure missing or Tor could not be forced). `retry()`
/// from the error pill. AppRuntime forwards background/foreground; panic calls
/// `wipeForPanic()`.
@MainActor
final class WeshInternetMode: ObservableObject {
    static let shared = WeshInternetMode()

    @Published private(set) var state: WeshInternetState
    @Published private(set) var disclosureAccepted: Bool

    var isEnabled: Bool { machine.isEnabled }
    /// The first activation must show the disclosure before `setEnabled(true)` succeeds.
    var needsDisclosure: Bool { !disclosureAccepted }

    struct Dependencies {
        /// Forces Tor on; true only when every connection is then Tor-only.
        var forceTor: () -> Bool
        /// Creates the Nostr identity if needed. Switching Internet on is the only
        /// path that creates it; QR and verification code only read it.
        var ensureNostrIdentity: () -> Bool
        /// The only switch for Tor and relays (NetworkActivationService opt-in).
        var setNetworkEnabled: (Bool) -> Void
        var retryConnections: () -> Void
        /// Stops Arti and waits, bounded, for it to exit.
        var stopTorAndWait: () -> Bool
        /// Deletes Arti's data directory; true once it is gone.
        var deleteArtiDirectory: () -> Bool
        var inputs: AnyPublisher<WeshInternetStateMachine.Inputs, Never>
        var scheduleAfter: (TimeInterval, @escaping @MainActor () -> Void) -> Void
        /// Fires when Arti exits without a stop request.
        var torStoppedUnexpectedly: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()
    }

    private var machine: WeshInternetStateMachine
    private let defaults: UserDefaults
    private let dependencies: Dependencies
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    /// Invalidates stall timers armed by an earlier entry into Connecting.
    private var stallGeneration = 0

    private convenience init() {
        self.init(defaults: .standard, dependencies: Dependencies(
            forceTor: {
                return NetworkActivationService.shared.userTorEnabled && TorManager.shared.torEnforced
            },
            ensureNostrIdentity: { (try? NostrIdentityBridge().getCurrentNostrIdentity()) != nil },
            setNetworkEnabled: { NetworkActivationService.shared.setUserInternetEnabled($0) },
            retryConnections: {
                TorManager.shared.ensureRunningOnForeground()
                // Queues until Tor is ready; never connects directly.
                NostrRelayManager.shared.connect()
            },
            stopTorAndWait: { TorManager.shared.stopSynchronously(timeout: WeshInternetPolicy.artiStopTimeoutSeconds) },
            deleteArtiDirectory: {
                guard let dir = WeshInternetPolicy.artiDataDirectory() else { return true }
                try? FileManager.default.removeItem(at: dir)
                return !FileManager.default.fileExists(atPath: dir.path)
            },
            inputs: Publishers.CombineLatest4(
                NetworkActivationService.shared.$isNetworkReachable,
                TorManager.shared.$isReady,
                TorManager.shared.$bootstrapProgress,
                NostrRelayManager.shared.$isDMRelayConnected
            )
            .map { WeshInternetStateMachine.Inputs(networkReachable: $0, torReady: $1, torProgress: $2, relayConnected: $3) }
            .eraseToAnyPublisher(),
            scheduleAfter: { delay, action in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Task { @MainActor in action() } }
            },
            torStoppedUnexpectedly: NotificationCenter.default.publisher(for: .TorDidStopUnexpectedly)
                .map { _ in () }
                .eraseToAnyPublisher()
        ))
    }

    init(defaults: UserDefaults, dependencies: Dependencies) {
        self.defaults = defaults
        self.dependencies = dependencies
        machine = WeshInternetStateMachine(enabled: WeshInternetSettings.isEnabled(in: defaults))
        state = machine.state
        disclosureAccepted = defaults.bool(forKey: WeshInternetSettings.disclosureAcceptedKey)
    }

    /// Applies the persisted toggle and starts observing Tor, relays and the network.
    func start() {
        guard !started else { return }
        started = true
        if machine.isEnabled {
            if dependencies.forceTor() {
                dependencies.setNetworkEnabled(true)
            } else {
                dependencies.setNetworkEnabled(false)
                apply(.routeFault)
            }
        } else {
            dependencies.setNetworkEnabled(false)
            // Completes an interrupted panic wipe; Arti keeps nothing while Off.
            _ = deleteArtiDirectory()
        }
        dependencies.inputs
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply(.inputs($0)) }
            .store(in: &cancellables)
        dependencies.torStoppedUnexpectedly
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply(.torStopped) }
            .store(in: &cancellables)
        armStallTimer()
    }

    func acceptDisclosure() {
        disclosureAccepted = true
        defaults.set(true, forKey: WeshInternetSettings.disclosureAcceptedKey)
    }

    /// Returns false when turning on is refused: no disclosure yet, Tor could
    /// not be forced, or no Nostr identity could be stored (the network then stays off).
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            guard disclosureAccepted, dependencies.forceTor(), dependencies.ensureNostrIdentity() else { return false }
        }
        defaults.set(enabled, forKey: WeshInternetSettings.enabledKey)
        apply(.toggle(enabled))
        dependencies.setNetworkEnabled(enabled)
        if !enabled {
            // Arti keeps nothing while Off. Deleted only once Arti is
            // confirmed stopped; otherwise the next launch (toggle off)
            // deletes it.
            if dependencies.stopTorAndWait() {
                _ = deleteArtiDirectory()
            } else {
                SecureLogger.warning("Internet off: Arti did not stop in time; its directory is deleted at next launch", category: .session)
            }
        }
        return true
    }

    func retry() {
        guard case .error(let failure) = state else { return }
        if failure == .routeFault {
            guard dependencies.forceTor() else { return }
        }
        apply(.retry)
        guard state != .error(.routeFault) else { return }
        if failure.isHard { dependencies.setNetworkEnabled(true) }
        dependencies.retryConnections()
    }

    /// Before the welcome: no Internet yet, but a wipe interrupted on Arti still completes, as
    /// `start()` would do with Internet off. Does nothing while Internet is on.
    func clearArtiWhileOff() {
        guard !machine.isEnabled else { return }
        dependencies.setNetworkEnabled(false)
        _ = deleteArtiDirectory()
    }

    func appDidEnterBackground() { apply(.background) }
    func appWillEnterForeground() { apply(.foreground) }

    /// Panic: Internet off (persisted), Tor stopped and awaited, Arti state
    /// deleted and checked. Nostr keys are wiped by the identity bridge in the
    /// same transaction. The directory is deleted even if Arti did not stop
    /// in time: under duress it must not wait for the next launch. Returns
    /// false if Arti did not stop or the directory survived, so the panic
    /// stays pending; the next launch (toggle absent) deletes again whatever
    /// Arti recreated.
    @discardableResult
    func wipeForPanic() -> Bool {
        defaults.removeObject(forKey: WeshInternetSettings.enabledKey)
        defaults.removeObject(forKey: WeshInternetSettings.disclosureAcceptedKey)
        disclosureAccepted = false
        apply(.panic)
        dependencies.setNetworkEnabled(false)
        let stopped = dependencies.stopTorAndWait()
        if !stopped {
            SecureLogger.error("Panic: Arti did not stop in time; deleting its directory anyway, wipe left pending", category: .security)
        }
        let deleted = deleteArtiDirectory()
        return stopped && deleted
    }

    private func deleteArtiDirectory() -> Bool {
        for _ in 0..<WeshInternetPolicy.artiDeleteAttempts {
            if dependencies.deleteArtiDirectory() { return true }
        }
        return false
    }

    private func apply(_ event: WeshInternetStateMachine.Event) {
        let previous = machine.state
        machine.handle(event)
        guard machine.state != previous else { return }
        state = machine.state
        if case .error(let failure) = machine.state, failure.isHard {
            // Hard fault: nothing may stay connected outside a ready Tor.
            dependencies.setNetworkEnabled(false)
        }
        if case .connecting = previous { return }
        armStallTimer()
    }

    /// One stall deadline per entry into Connecting; progress updates keep it.
    private func armStallTimer() {
        stallGeneration &+= 1
        guard case .connecting = machine.state else { return }
        let armed = stallGeneration
        dependencies.scheduleAfter(WeshInternetPolicy.connectingStallSeconds) { [weak self] in
            guard let self, self.stallGeneration == armed else { return }
            self.apply(.stallTimeout)
        }
    }
}
