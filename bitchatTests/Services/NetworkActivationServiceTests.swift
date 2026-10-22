import Combine
import Foundation
import Testing
@testable import bitchat

@MainActor
struct GeographicNetworkGraphRetirementTests {
    @Test
    func internetOptInAndPanicStayIndependentOfRetiredGeographicOwners() async {
        let preferences = GeographicNetworkMemoryDefaults()
        preferences.set(false, forKey: NetworkActivationService.torPreferenceKey)
        let tor = MockNetworkActivationTorController()
        let relay = MockNetworkActivationRelayController()
        let proxy = MockNetworkActivationProxyController()
        let reachability = MockNetworkActivationReachability()
        let service = NetworkActivationService(storage: preferences,
            reachabilityMonitor: reachability, torController: tor, relayController: relay, proxyController: proxy)
        defer { service.stopForPanic() }
        service.setUserInternetEnabled(false)
        service.start()
        #expect(!service.activationAllowed)
        #expect(relay.connectCallCount == 0)
        #expect(tor.startIfNeededCallCount == 0)
        #expect(preferences.object(forKey: NetworkActivationService.torPreferenceKey) == nil)
        service.setUserInternetEnabled(true)
        #expect(service.activationAllowed)
        #expect(tor.startIfNeededCallCount == 1)
        #expect(relay.connectCallCount == 1)
        service.setUserInternetEnabled(false)
        #expect(!service.activationAllowed)
        #expect(tor.autoStartAllowedValues.last == false)
        service.stopForPanic()
        let connections = relay.connectCallCount
        let starts = tor.startIfNeededCallCount
        service.setUserInternetEnabled(true)
        reachability.set(false)
        reachability.set(true)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(!service.activationAllowed)
        #expect(relay.connectCallCount == connections)
        #expect(tor.startIfNeededCallCount == starts)
        #expect(!proxy.proxyModes.contains(false))
    }
}

private final class GeographicNetworkMemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "GeographicNetworkFixture-\(UUID().uuidString)")! }
    override func object(forKey key: String) -> Any? { values[key] }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    override func synchronize() -> Bool { true }
}

@MainActor
private final class MockNetworkActivationReachability:
    NetworkReachabilityMonitoring {
    private let subject = CurrentValueSubject<Bool, Never>(true)
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    var isReachable: Bool { subject.value }
    var reachabilityPublisher: AnyPublisher<Bool, Never> {
        subject.removeDuplicates().dropFirst().eraseToAnyPublisher()
    }

    func start() {
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }

    func set(_ reachable: Bool) {
        subject.send(reachable)
    }
}

@MainActor
private final class MockNetworkActivationTorController: NetworkActivationTorControlling {
    private(set) var autoStartAllowedValues: [Bool] = []
    private(set) var startIfNeededCallCount = 0
    private(set) var shutdownCompletelyCallCount = 0

    func setAutoStartAllowed(_ allowed: Bool) {
        autoStartAllowedValues.append(allowed)
    }

    func startIfNeeded() {
        startIfNeededCallCount += 1
    }

    func shutdownCompletely() {
        shutdownCompletelyCallCount += 1
    }
}

@MainActor
struct NetworkActivationInternetOffTests {
    private func makeService() -> (NetworkActivationService, MockNetworkActivationRelayController, MockNetworkActivationReachability) {
        let relay = MockNetworkActivationRelayController()
        let reachability = MockNetworkActivationReachability()
        let service = NetworkActivationService(storage: GeographicNetworkMemoryDefaults(),
            reachabilityMonitor: reachability, torController: MockNetworkActivationTorController(),
            relayController: relay, proxyController: MockNetworkActivationProxyController())
        return (service, relay, reachability)
    }

    @Test
    func internetStaysOffUntilTheUserTurnsItOn() {
        let (service, relay, _) = makeService()
        defer { service.stopForPanic() }
        service.start()

        #expect(!service.userInternetEnabled)
        #expect(!service.activationAllowed)
        #expect(relay.connectCallCount == 0)
    }

    @Test
    func turningInternetOffDiscardsSendsWaitingForARelayButALostNetworkKeepsThem() async {
        let (service, relay, reachability) = makeService()
        defer { service.stopForPanic() }
        service.start()
        service.setUserInternetEnabled(true)

        // Losing the network keeps them: they leave when it comes back.
        reachability.set(false)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(!service.activationAllowed)
        reachability.set(true)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(service.activationAllowed)
        #expect(relay.discardCallCount == 0)

        service.setUserInternetEnabled(false)
        #expect(relay.discardCallCount == 1)
    }
}

@MainActor
private final class MockNetworkActivationRelayController: NetworkActivationRelayControlling {
    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var discardCallCount = 0

    func connect() {
        connectCallCount += 1
    }

    func disconnect() {
        disconnectCallCount += 1
    }

    func discardPendingSends() {
        discardCallCount += 1
    }
}

private final class MockNetworkActivationProxyController: NetworkActivationProxyControlling {
    private(set) var proxyModes: [Bool] = []

    func setProxyMode(useTor: Bool) {
        proxyModes.append(useTor)
    }
}
