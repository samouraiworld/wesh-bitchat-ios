import Combine
import CoreLocation
import XCTest
@testable import bitchat

/// The retained counter and pool cannot revive the retired notes transport.
/// Authorized-channel fixture cases remain disposable-CI-only: their legacy
/// delegate setup constructs a platform CLLocationManager argument.
@MainActor
final class NearbyNotesCounterTests: XCTestCase {
    func test_revealCannotOpenRetiredNotesSubscriptionOrProvideAnInboundHandler() async throws {
        let relays = SubscriptionRecorder()
        let settings = LocationNotesSettingsStub()
        let locationManager = try await makeAuthorizedLocationManager()
        let counter = NearbyNotesCounter(
            locationManager: locationManager,
            managerFactory: { LocationNotesManager(geohash: $0, dependencies: relays.dependencies) },
            releaseManager: { $0?.cancel() }, locationNotesEnabled: { settings.enabled },
            locationNotesSettings: settings.changes)
        counter.activate()
        await mainQueueFence()
        XCTAssertFalse(counter.revealed)
        XCTAssertEqual(relays.subscribeCount, 0)
        counter.reveal()
        await mainQueueFence()
        XCTAssertTrue(counter.revealed)
        XCTAssertEqual(relays.subscribeCount, 0)
        XCTAssertNil(relays.lastFilter)
        XCTAssertNil(relays.lastHandler)
        XCTAssertEqual(counter.noteCount, 0)
        counter.deactivate()
        XCTAssertEqual(relays.unsubscribeCount, 0)
    }

    func test_permissionRevocationCannotReviveRetiredNotesDespiteCachedChannels() async throws {
        let relays = SubscriptionRecorder()
        let settings = LocationNotesSettingsStub()
        let locationManager = try await makeAuthorizedLocationManager()
        let counter = NearbyNotesCounter(
            locationManager: locationManager,
            managerFactory: { LocationNotesManager(geohash: $0, dependencies: relays.dependencies) },
            releaseManager: { $0?.cancel() },
            locationNotesEnabled: { settings.enabled },
            locationNotesSettings: settings.changes
        )

        counter.activate()
        counter.reveal()
        XCTAssertEqual(relays.subscribeCount, 0)

        locationManager.locationManager(CLLocationManager(), didChangeAuthorization: .denied)

        let denied = await waitUntil { locationManager.permissionState == .denied }
        XCTAssertTrue(denied)
        await mainQueueFence()
        XCTAssertEqual(relays.unsubscribeCount, 0)
        XCTAssertTrue(
            locationManager.availableChannels.contains { $0.level == .building },
            "the privacy boundary must not depend on cached channels being cleared"
        )
        XCTAssertEqual(counter.noteCount, 0)

        counter.deactivate()
        XCTAssertEqual(relays.unsubscribeCount, 0)
    }

    func test_locationNotesKillSwitchCannotReviveRetiredNotes() async throws {
        let relays = SubscriptionRecorder()
        let settings = LocationNotesSettingsStub()
        let locationManager = try await makeAuthorizedLocationManager()
        let counter = NearbyNotesCounter(
            locationManager: locationManager,
            managerFactory: { LocationNotesManager(geohash: $0, dependencies: relays.dependencies) },
            releaseManager: { $0?.cancel() },
            locationNotesEnabled: { settings.enabled },
            locationNotesSettings: settings.changes
        )

        counter.activate()
        counter.reveal()
        XCTAssertEqual(relays.subscribeCount, 0)

        settings.setEnabled(false)

        await mainQueueFence()
        XCTAssertEqual(relays.unsubscribeCount, 0)
        XCTAssertEqual(counter.noteCount, 0)

        settings.setEnabled(true)

        await mainQueueFence()
        XCTAssertEqual(relays.subscribeCount, 0)
        counter.deactivate()
        XCTAssertEqual(relays.unsubscribeCount, 0)
    }

    func test_checkNotesHint_requiresAuthorizedLocationPermission() {
        let relays = SubscriptionRecorder()
        let settings = LocationNotesSettingsStub()
        let counter = NearbyNotesCounter(
            locationManager: makeBareLocationManager(),
            managerFactory: { LocationNotesManager(geohash: $0, dependencies: relays.dependencies) },
            releaseManager: { $0?.cancel() },
            locationNotesEnabled: { settings.enabled },
            locationNotesSettings: settings.changes
        )

        // An unauthorized install must never see the hint: the tap can't
        // subscribe (retarget requires authorization) and must not prompt,
        // so offering it would be a silent dead-end for the session.
        XCTAssertFalse(counter.offersRevealHint(permissionState: .notDetermined))
        XCTAssertFalse(counter.offersRevealHint(permissionState: .denied))
        XCTAssertFalse(counter.offersRevealHint(permissionState: .restricted))
        XCTAssertTrue(counter.offersRevealHint(permissionState: .authorized))

        // The app-info kill switch hides it too.
        settings.setEnabled(false)
        XCTAssertFalse(counter.offersRevealHint(permissionState: .authorized))
        settings.setEnabled(true)

        // Once revealed, the hint yields to the live strip and count.
        counter.reveal()
        XCTAssertFalse(counter.offersRevealHint(permissionState: .authorized))
        XCTAssertEqual(relays.subscribeCount, 0, "reveal without authorization must not open a REQ")
    }

    func test_pool_sharesOneManagerPerGeohash_andCancelsOnLastRelease() {
        let relays = SubscriptionRecorder()
        let pool = LocationNotesPool(
            makeManager: { LocationNotesManager(geohash: $0, dependencies: relays.dependencies) }
        )

        let first = pool.acquire("u4pruydq")
        let second = pool.acquire("U4PRUYDQ")

        XCTAssertTrue(first === second, "same geohash (case-insensitive) must share one manager")
        XCTAssertEqual(relays.subscribeCount, 0)

        pool.release(first)

        XCTAssertEqual(relays.unsubscribeCount, 0, "retired managers never open a REQ")
        XCTAssertEqual(first.state, .idle)

        pool.release(second)

        XCTAssertEqual(relays.unsubscribeCount, 0)
        XCTAssertEqual(first.state, .idle)

        // An instance the pool never owned (test-injected) degrades to cancel.
        let stray = LocationNotesManager(geohash: "u4pruydp", dependencies: relays.dependencies)
        pool.release(stray)
        XCTAssertEqual(relays.unsubscribeCount, 0)
        XCTAssertEqual(stray.state, .idle)
    }

    func test_pool_reacquireAfterFullRelease_keepsRetiredManagerIdle() {
        let relays = SubscriptionRecorder()
        let pool = LocationNotesPool(
            makeManager: { LocationNotesManager(geohash: $0, dependencies: relays.dependencies) }
        )

        // Releasing and reacquiring a retained UI model cannot reopen transport.
        let first = pool.acquire("u4pruydq")
        XCTAssertEqual(relays.subscribeCount, 0)

        pool.release(first)
        XCTAssertEqual(relays.unsubscribeCount, 0)
        XCTAssertEqual(first.state, .idle)

        let second = pool.acquire("u4pruydq")
        XCTAssertEqual(relays.subscribeCount, 0)
        XCTAssertEqual(second.state, .idle)

        // Dismissal also leaves the network boundary untouched.
        pool.release(second)
        XCTAssertEqual(relays.unsubscribeCount, 0)
    }

    // MARK: - Helpers

    /// A LocationStateManager that never touches CoreLocation; for tests
    /// that don't need channels or authorization.
    private func makeBareLocationManager() -> LocationStateManager {
        let suiteName = "NearbyNotesCounterTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        storage.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            storage.removePersistentDomain(forName: suiteName)
        }
        return LocationStateManager(
            storage: storage,
            locationManager: MockLocationManager(authorizationStatus: .denied),
            geocoder: MockLocationGeocoder(),
            shouldInitializeCoreLocation: false
        )
    }

    /// An authorized LocationStateManager whose availableChannels carry a
    /// real building-level geohash (Honolulu), built over CoreLocation mocks.
    private func makeAuthorizedLocationManager() async throws -> LocationStateManager {
        let suiteName = "NearbyNotesCounterTests-\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: suiteName)!
        storage.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            storage.removePersistentDomain(forName: suiteName)
        }

        let manager = LocationStateManager(
            storage: storage,
            locationManager: MockLocationManager(authorizationStatus: .authorizedAlways),
            geocoder: MockLocationGeocoder(),
            shouldInitializeCoreLocation: true
        )
        let authorized = await waitUntil { manager.permissionState == .authorized }
        XCTAssertTrue(authorized)

        manager.locationManager(
            CLLocationManager(),
            didUpdateLocations: [CLLocation(latitude: 21.2850, longitude: -157.8357)]
        )
        let channelsLoaded = await waitUntil {
            manager.availableChannels.contains { $0.level == .building }
        }
        XCTAssertTrue(channelsLoaded)
        return manager
    }

    private func mainQueueFence() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func waitUntil(
        timeout: TimeInterval = TestConstants.settleTimeout,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}

@MainActor
private final class LocationNotesSettingsStub {
    private let changesSubject = PassthroughSubject<Void, Never>()
    private(set) var enabled = true

    var changes: AnyPublisher<Void, Never> {
        changesSubject.eraseToAnyPublisher()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        changesSubject.send(())
    }
}

/// Stub relay layer: counts REQs, captures the last filter/handler, and never
/// touches the network.
@MainActor
private final class SubscriptionRecorder {
    private(set) var subscribeCount = 0
    private(set) var unsubscribeCount = 0
    private(set) var lastFilter: NostrFilter?
    private(set) var lastHandler: ((NostrEvent) -> Void)?

    var dependencies: LocationNotesDependencies {
        LocationNotesDependencies(
            relayLookup: { _, _ in ["wss://relay.one"] },
            subscribe: { [weak self] filter, _, _, handler, _ in
                self?.subscribeCount += 1
                self?.lastFilter = filter
                self?.lastHandler = handler
            },
            unsubscribe: { [weak self] _ in
                self?.unsubscribeCount += 1
            },
            sendEvent: { _, _ in },
            deriveIdentity: { _ in try NostrIdentity.generate() },
            now: { Date() }
        )
    }
}

private final class MockLocationManager: LocationStateManaging {
    weak var delegate: CLLocationManagerDelegate?
    var desiredAccuracy: CLLocationAccuracy = 0
    var distanceFilter: CLLocationDistance = 0
    var authorizationStatus: CLAuthorizationStatus

    init(authorizationStatus: CLAuthorizationStatus) {
        self.authorizationStatus = authorizationStatus
    }

    func requestWhenInUseAuthorization() {}
    func requestLocation() {}
    func startUpdatingLocation() {}
    func stopUpdatingLocation() {}
}

private final class MockLocationGeocoder: LocationStateGeocoding {
    func cancelGeocode() {}

    func reverseGeocodeLocation(
        _ location: CLLocation,
        completionHandler: @escaping ([CLPlacemark]?, Error?) -> Void
    ) {
        completionHandler(nil, nil)
    }
}
