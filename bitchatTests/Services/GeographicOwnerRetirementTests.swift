import CoreLocation
import Foundation
import MapKit
import Testing
@testable import bitchat

/// All coordinates, names, preferences, clocks and network responses below
/// are invented fixture values; no platform location adapter is constructed.
@MainActor
struct GeographicOwnerRetirementTests {
    @Test
    func panicClearsRetainedLocationStateWithoutConstructingAnotherOwner() throws {
        let defaults = GeographicOwnerDefaults()
        defaults.set(try JSONEncoder().encode(ChannelID.location(GeohashChannel(level: .city, geohash: "00000"))),
                     forKey: "locationChannel.selected")
        defaults.set(try JSONEncoder().encode(["00000"]), forKey: "locationChannel.bookmarks")
        defaults.set(try JSONEncoder().encode(["00000": "Synthetic City"]), forKey: "locationChannel.bookmarkNames")
        defaults.set(1, forKey: "locationChannel.bookmarkNamesSchemaVersion")
        let manager = makeManager(defaults: defaults)
        #expect(manager.bookmarks == ["00000"])
        manager.panicWipe()

        #expect(manager.selectedChannel == .mesh)
        #expect(manager.bookmarks.isEmpty)
        #expect(manager.bookmarkNames.isEmpty)
        #expect(!manager.teleported)
    }

    @Test(arguments: [false, true])
    func retainedOwnerCannotRepopulateFromQueuedSelectionOrLateName(retire: Bool) async throws {
        let defaults = GeographicOwnerDefaults()
        let geocoder = SuspendedGeographyGeocoder()
        let manager = makeManager(defaults: defaults, geocoder: geocoder)
        manager.addBookmark("00000")
        #expect(geocoder.completions.count == 1, "The real name-resolution path must have started")
        manager.select(.location(GeohashChannel(level: .city, geohash: "00000")))
        if retire { manager.panicWipe() }
        let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                    addressDictionary: ["City": "Synthetic City"])
        geocoder.completions[0]([placemark], nil)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        if retire {
            #expect(manager.selectedChannel == .mesh)
            #expect(manager.bookmarks.isEmpty)
            #expect(manager.bookmarkNames.isEmpty)
            #expect(defaults.data(forKey: "locationChannel.selected") == nil)
            #expect(defaults.data(forKey: "locationChannel.bookmarkNames") == nil)
            manager.addBookmark("zzzzz")
            manager.markTeleported(for: "zzzzz", true)
            #expect(manager.bookmarks.isEmpty, "Retirement cannot be reversed by a retained UI owner")
            #expect(defaults.data(forKey: "locationChannel.teleportedSet") == nil)
        } else {
            #expect(manager.bookmarks == ["00000"])
            #expect(manager.bookmarkNames["00000"] == "Synthetic City")
            #expect(defaults.data(forKey: "locationChannel.bookmarkNames") != nil)
        }
    }

    @Test(arguments: [false, true])
    func directoryRetirementRejectsCancellationIgnoringLateSuccess(retire: Bool) async throws {
        let fixture = GeographicDirectoryFixture()
        let directory = GeoRelayDirectory(dependencies: fixture.dependencies)
        let deadline = Date().addingTimeInterval(TestConstants.settleTimeout)
        while !(await fixture.fetch.started), Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let started = await fixture.fetch.started
        #expect(started)
        // Always release the injected transport; it deliberately ignores cancellation.
        let completion = retire ? directory.retireForPanic() : directory.debugFetchTask
        await fixture.fetch.release()
        await completion?.value
        #expect(completion != nil, "The barrier must own the actual fetch task")
        if retire {
            #expect(directory.entries.isEmpty)
            #expect(fixture.writes.isEmpty)
            #expect(fixture.defaults.object(forKey: "georelay.lastFetchAt") == nil)
            #expect(directory.debugObserverCount == 0)
            let calls = fixture.fetchFactories
            directory.prefetchIfNeeded(force: true)
            fixture.center.post(name: .TorDidBecomeReady, object: nil)
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            #expect(fixture.fetchFactories == calls)
        } else {
            #expect(directory.entries.count == 1)
            #expect(fixture.writes.count == 1)
            #expect(fixture.defaults.object(forKey: "georelay.lastFetchAt") != nil)
        }
    }

    private func makeManager(defaults: GeographicOwnerDefaults,
                             geocoder: SuspendedGeographyGeocoder = SuspendedGeographyGeocoder()) -> LocationStateManager {
        LocationStateManager(storage: defaults, locationManager: InertGeographicLocationManager(),
            geocoder: geocoder, shouldInitializeCoreLocation: false)
    }
}

private final class GeographicOwnerDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "GeographicOwnerFixture-\(UUID().uuidString)")! }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    override func object(forKey key: String) -> Any? { values[key] }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    override func synchronize() -> Bool { true }
}

private final class InertGeographicLocationManager: LocationStateManaging {
    weak var delegate: CLLocationManagerDelegate?
    var desiredAccuracy: CLLocationAccuracy = 0
    var distanceFilter: CLLocationDistance = 0
    var authorizationStatus: CLAuthorizationStatus = .denied
    func requestWhenInUseAuthorization() {}
    func requestLocation() {}
    func startUpdatingLocation() {}
    func stopUpdatingLocation() {}
}

private final class SuspendedGeographyGeocoder: LocationStateGeocoding {
    var completions: [([CLPlacemark]?, Error?) -> Void] = []
    func cancelGeocode() {}
    func reverseGeocodeLocation(_ location: CLLocation, completionHandler: @escaping ([CLPlacemark]?, Error?) -> Void) {
        completions.append(completionHandler)
    }
}

@MainActor
private final class GeographicDirectoryFixture {
    let defaults = GeographicOwnerDefaults()
    let center = NotificationCenter()
    let fetch = SuspendedGeographicDirectoryFetch()
    var writes: [Data] = []
    var fetchFactories = 0
    var dependencies: GeoRelayDirectoryDependencies {
        GeoRelayDirectoryDependencies(userDefaults: defaults, notificationCenter: center,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            remoteURL: URL(string: "https://directory.invalid/synthetic.csv")!,
            fetchInterval: 60, refreshCheckInterval: 0, retryInitialSeconds: 5, retryMaxSeconds: 10,
            awaitTorReady: { true }, makeFetchData: {
                self.fetchFactories += 1
                let fetch = self.fetch
                return { _ in await fetch.response() }
            }, readData: { _ in nil }, writeData: { data, _ in self.writes.append(data) },
            cacheURL: { URL(fileURLWithPath: "/synthetic-never-accessed/georelays_cache_v2.csv") },
            bundledCSVURLs: { [] }, currentDirectoryPath: { nil }, retrySleep: { _ in },
            activeNotificationName: Notification.Name("syntheticGeographicActive"), autoStart: true,
            validationPolicy: GeoRelayDirectoryValidationPolicy(maximumBytes: 1_000, maximumRows: 10,
                maximumEntries: 10, minimumRemoteEntries: 1, minimumRetainedFraction: 0))
    }
}

private actor SuspendedGeographicDirectoryFetch {
    private(set) var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func response() async -> Data {
        started = true
        if !released { await withCheckedContinuation { continuation = $0 } }
        return Data("relay url,lat,lon\nsynthetic-relay.invalid,0,0\n".utf8)
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
