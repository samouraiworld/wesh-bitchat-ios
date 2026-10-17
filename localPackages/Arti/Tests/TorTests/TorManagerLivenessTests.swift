import XCTest
@testable import Tor

/// A stand-in for the Rust library: starts instantly, bootstraps to 100 and
/// can be killed or have its SOCKS listener vanish on demand.
private final class FakeArti: @unchecked Sendable {
    private let lock = NSLock()
    private var _running = false
    private var _socksAlive = true
    private var _startCalls = 0
    private var _stopCalls = 0

    var running: Bool {
        get { lock.withLock { _running } }
        set { lock.withLock { _running = newValue } }
    }
    var socksAlive: Bool {
        get { lock.withLock { _socksAlive } }
        set { lock.withLock { _socksAlive = newValue } }
    }
    var startCalls: Int { lock.withLock { _startCalls } }
    var stopCalls: Int { lock.withLock { _stopCalls } }

    var backend: ArtiBackend {
        ArtiBackend(
            start: { [self] _, _ in
                lock.withLock {
                    _startCalls += 1
                    _running = true
                }
                return 0
            },
            stop: { [self] in
                lock.withLock {
                    _stopCalls += 1
                    _running = false
                }
                return 0
            },
            isRunning: { [self] in running },
            bootstrapProgress: { [self] in running ? 100 : 0 },
            bootstrapSummary: { "" },
            probeSocks: { [self] _ in running && socksAlive }
        )
    }
}

@MainActor
final class TorManagerLivenessTests: XCTestCase {
    private var stateDirectory: URL!

    override func setUp() async throws {
        stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tor-liveness-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: stateDirectory)
    }

    private func makeManager(_ arti: FakeArti) -> TorManager {
        let directory = stateDirectory
        return TorManager(
            backend: arti.backend,
            dataDirectory: { directory },
            pollIntervalNanoseconds: 5_000_000,
            livenessIntervalNanoseconds: 5_000_000,
            usesPathMonitor: false
        )
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private func startReady(_ manager: TorManager) async {
        manager.setAutoStartAllowed(true)
        manager.setAppForeground(true)
        manager.startIfNeeded()
        let ready = await waitUntil { manager.isReady }
        XCTAssertTrue(ready, "fake Arti should bootstrap")
    }

    // MARK: - Background relaunch

    func test_backgroundLaunch_doesNotStartArtiUntilForeground() async {
        let arti = FakeArti()
        let manager = makeManager(arti)
        manager.setAutoStartAllowed(true)

        manager.startIfNeeded()
        _ = await manager.awaitReady(timeout: 0.05)

        XCTAssertEqual(arti.startCalls, 0, "a background relaunch must not boot Arti")
        XCTAssertFalse(manager.isForeground())

        manager.setAppForeground(true)

        XCTAssertEqual(arti.startCalls, 1, "becoming foreground starts the allowed, dropped start")
    }

    func test_foreground_withoutAutoStartAllowed_doesNotStartArti() {
        let arti = FakeArti()
        let manager = makeManager(arti)

        manager.setAppForeground(true)

        XCTAssertEqual(arti.startCalls, 0)
    }

    // MARK: - Arti dying mid-session

    func test_artiExitAfterBootstrap_dropsReadinessAndReportsUnexpectedStop() async {
        let arti = FakeArti()
        let manager = makeManager(arti)
        let center = NotificationCenter.default
        var posted = 0
        let observer = center.addObserver(forName: .TorDidStopUnexpectedly, object: nil, queue: nil) { _ in posted += 1 }
        defer { center.removeObserver(observer) }
        await startReady(manager)
        XCTAssertFalse(manager.didStopUnexpectedly)

        arti.running = false

        let detected = await waitUntil { !manager.isReady && manager.didStopUnexpectedly }
        XCTAssertTrue(detected, "Arti exiting must drop readiness")
        XCTAssertEqual(manager.bootstrapProgress, 0)
        XCTAssertFalse(manager.networkPermitted)
        XCTAssertEqual(posted, 1)
        XCTAssertEqual(arti.startCalls, 1, "no silent restart: recovery is an explicit retry")
        let permitted = await manager.awaitReady(timeout: 0.05)
        XCTAssertFalse(permitted)
        XCTAssertEqual(arti.startCalls, 1, "awaiting readiness must not restart a dead Arti")
    }

    func test_socksListenerGone_dropsReadinessAndStopsTheRuntime() async {
        let arti = FakeArti()
        let manager = makeManager(arti)
        await startReady(manager)

        arti.socksAlive = false

        let detected = await waitUntil { !manager.isReady && manager.didStopUnexpectedly }
        XCTAssertTrue(detected, "a dead SOCKS listener must drop readiness")
        XCTAssertFalse(arti.running, "the broken runtime is stopped so a retry boots a fresh one")
    }

    func test_artiExitDuringBootstrap_isReportedAsUnexpectedStop() async {
        let arti = FakeArti()
        var backend = arti.backend
        backend.bootstrapProgress = { 40 }
        let directory = stateDirectory
        let manager = TorManager(
            backend: backend,
            dataDirectory: { directory },
            pollIntervalNanoseconds: 5_000_000,
            livenessIntervalNanoseconds: 5_000_000,
            usesPathMonitor: false
        )
        manager.setAutoStartAllowed(true)
        manager.setAppForeground(true)

        arti.running = false

        let detected = await waitUntil { manager.didStopUnexpectedly }
        XCTAssertTrue(detected)
        XCTAssertFalse(manager.isReady)
        XCTAssertFalse(manager.bootstrapDidStall, "an exit is not a stall")
    }

    func test_deliberateStop_isNotReportedAsUnexpected() async {
        let arti = FakeArti()
        let manager = makeManager(arti)
        await startReady(manager)

        XCTAssertTrue(manager.stopSynchronously(timeout: 1))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(manager.didStopUnexpectedly)
        XCTAssertFalse(manager.isReady)
    }

    func test_shutdownCompletely_isNotReportedAsUnexpected() async {
        let arti = FakeArti()
        let manager = makeManager(arti)
        await startReady(manager)

        manager.shutdownCompletely()
        let stopped = await waitUntil { !manager.isReady && !arti.running }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(stopped)
        XCTAssertFalse(manager.didStopUnexpectedly)
    }

    func test_explicitRestartAfterUnexpectedStop_bootsAgainAndClearsTheFlag() async {
        let arti = FakeArti()
        let manager = makeManager(arti)
        await startReady(manager)
        arti.running = false
        _ = await waitUntil { manager.didStopUnexpectedly }

        manager.startIfNeeded()
        XCTAssertEqual(arti.startCalls, 1, "an implicit start does not revive a dead Arti")

        manager.ensureRunningOnForeground()

        let ready = await waitUntil { manager.isReady }
        XCTAssertTrue(ready)
        XCTAssertEqual(arti.startCalls, 2)
        XCTAssertFalse(manager.didStopUnexpectedly)
    }

    func test_shutdownAfterUnexpectedStop_allowsTheNextStart() async {
        let arti = FakeArti()
        let manager = makeManager(arti)
        await startReady(manager)
        arti.running = false
        _ = await waitUntil { manager.didStopUnexpectedly }

        manager.shutdownCompletely()
        manager.startIfNeeded()

        let ready = await waitUntil { manager.isReady }
        XCTAssertTrue(ready, "the start deferred during shutdown boots a fresh Arti")
        XCTAssertEqual(arti.startCalls, 2)
    }
}
