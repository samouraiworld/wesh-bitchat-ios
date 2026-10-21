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
    private var _endpoints: [SocksEndpoint] = []

    var running: Bool {
        get { lock.withLock { _running } }
        set { lock.withLock { _running = newValue } }
    }
    var socksAlive: Bool {
        get { lock.withLock { _socksAlive } }
        set { lock.withLock { _socksAlive = newValue } }
    }
    var startCalls: Int { lock.withLock { _startCalls } }
    var endpoints: [SocksEndpoint] { lock.withLock { _endpoints } }
    var stopCalls: Int { lock.withLock { _stopCalls } }

    var backend: ArtiBackend {
        ArtiBackend(
            start: { [self] _, socks in
                lock.withLock {
                    _startCalls += 1
                    _endpoints.append(socks)
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

/// Holds one fake connect attempt until the test releases it or its task is cancelled.
/// Later attempts finish immediately so a failing regression cannot leave a 60 s loop.
private final class ControlledSocksProbe: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Controlled SOCKS probe entered")
    let cancelled = XCTestExpectation(description: "In-flight SOCKS probe cancelled")
    let laterAttempt = XCTestExpectation(description: "Another SOCKS probe attempted")
    let nativeStopped = XCTestExpectation(description: "Fake native stop completed")
    private let lock = NSLock()
    private let heldAttempt: Int
    private var calls = 0
    private var continuation: CheckedContinuation<Bool, Never>?
    private var cancellationObserved = false
    private var stopObserved = false
    private var laterAttemptReported = false

    init(heldAttempt: Int = 1) { self.heldAttempt = heldAttempt }

    var attempts: Int { lock.withLock { calls } }

    func attempt() async -> Bool {
        let index = lock.withLock { calls += 1; return calls }
        guard index == heldAttempt else {
            let report = lock.withLock {
                guard index > heldAttempt, !laterAttemptReported else { return false }
                laterAttemptReported = true
                return true
            }
            if report { laterAttempt.fulfill() }
            return true
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { pending in
                let alreadyCancelled = lock.withLock {
                    if cancellationObserved { return true }
                    continuation = pending
                    return false
                }
                entered.fulfill()
                if alreadyCancelled { pending.resume(returning: false) }
            }
        } onCancel: {
            let (pending, report) = self.lock.withLock {
                let report = !self.cancellationObserved
                self.cancellationObserved = true
                let pending = self.continuation
                self.continuation = nil
                return (pending, report)
            }
            pending?.resume(returning: false)
            if report { self.cancelled.fulfill() }
        }
    }

    func release() {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(returning: false)
    }

    func recordNativeStop() {
        let report = lock.withLock {
            guard !stopObserved else { return false }
            stopObserved = true
            return true
        }
        if report { nativeStopped.fulfill() }
    }
}

private final class ProbeTransportState: @unchecked Sendable {
    private let lock = NSLock()
    private var startCount = 0
    private var cancelCount = 0
    var starts: Int { lock.withLock { startCount } }
    var cancels: Int { lock.withLock { cancelCount } }
    func start() { lock.withLock { startCount += 1 } }
    func cancel() { lock.withLock { cancelCount += 1 } }
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

    private func makeProbeManager(heldAttempt: Int = 1, progress: Int = 40) -> (TorManager, ControlledSocksProbe) {
        let arti = FakeArti()
        let probe = ControlledSocksProbe(heldAttempt: heldAttempt)
        var backend = arti.backend
        let nativeStop = backend.stop
        backend.stop = {
            let result = nativeStop()
            probe.recordNativeStop()
            return result
        }
        backend.bootstrapProgress = { progress }
        backend.probeSocks = { _ in await probe.attempt() }
        let directory = stateDirectory
        let manager = TorManager(
            backend: backend,
            dataDirectory: { directory },
            pollIntervalNanoseconds: 5_000_000,
            livenessIntervalNanoseconds: 5_000_000,
            usesPathMonitor: false
        )
        return (manager, probe)
    }

    private func assertExplicitStopCancelsProbe(synchronously: Bool, heldAttempt: Int = 1, progress: Int = 40) async {
        let (manager, probe) = makeProbeManager(heldAttempt: heldAttempt, progress: progress)
        probe.laterAttempt.isInverted = true
        defer {
            probe.release()
            _ = manager.stopSynchronously(timeout: 1)
        }
        manager.setAutoStartAllowed(true)
        manager.setAppForeground(true)
        await fulfillment(of: [probe.entered], timeout: 1)

        if synchronously {
            XCTAssertTrue(manager.stopSynchronously(timeout: 1))
        } else {
            manager.shutdownCompletely()
        }
        await fulfillment(of: [probe.nativeStopped], timeout: 1)
        // Release a non-cancelled fake too: old code then retries after stop,
        // while the cancellation-aware path must leave the probe count fixed.
        probe.release()
        await fulfillment(of: [probe.cancelled, probe.laterAttempt], timeout: 1)

        XCTAssertEqual(probe.attempts, heldAttempt,
                       "explicit stop must close its in-flight probe and prevent another connect")
        XCTAssertFalse(manager.isReady)
    }

    // MARK: - SOCKS probe ownership

    func test_probeCancellationBeforeInstallationDoesNotStartTransport() async {
        let attempt = SocksProbeAttempt()
        let transport = ProbeTransportState()
        // This is the cancellation-handler path winning before install runs.
        attempt.complete(false)

        let ready = await attempt.run(start: { transport.start() }, cancel: { transport.cancel() })

        XCTAssertFalse(ready)
        XCTAssertEqual(transport.starts, 0)
        XCTAssertEqual(transport.cancels, 1)
    }

    func test_probeImmediateReadyClosesTransportExactlyOnce() async {
        let attempt = SocksProbeAttempt()
        let transport = ProbeTransportState()

        let ready = await attempt.run(start: {
            transport.start()
            attempt.complete(true)
        }, cancel: { transport.cancel() })
        attempt.complete(false)

        XCTAssertTrue(ready)
        XCTAssertEqual(transport.starts, 1)
        XCTAssertEqual(transport.cancels, 1)
    }

    func test_probeTaskCancellationClosesInFlightTransport() async {
        let attempt = SocksProbeAttempt()
        let transport = ProbeTransportState()
        let entered = expectation(description: "Probe transport started")
        let closed = expectation(description: "Probe transport cancelled")
        let task = Task {
            await attempt.run(start: {
                transport.start()
                entered.fulfill()
            }, cancel: {
                transport.cancel()
                closed.fulfill()
            })
        }
        await fulfillment(of: [entered], timeout: 1)

        task.cancel()
        await fulfillment(of: [closed], timeout: 1)
        let cancelledBeforeRescue = transport.cancels
        // Keep a broken cancellation handler from leaving the test suspended.
        attempt.complete(false)
        let ready = await task.value

        XCTAssertFalse(ready)
        XCTAssertEqual(cancelledBeforeRescue, 1)
    }

    func test_probeCallbacksTimeoutAndCancellationCompleteOnce() async {
        let attempt = SocksProbeAttempt()
        let transport = ProbeTransportState()
        let entered = expectation(description: "Probe transport started")
        let task = Task {
            await attempt.run(start: {
                transport.start()
                entered.fulfill()
            }, cancel: { transport.cancel() })
        }
        await fulfillment(of: [entered], timeout: 1)

        DispatchQueue.concurrentPerform(iterations: 30) { index in
            switch index % 3 {
            case 0: attempt.complete(true)
            case 1: attempt.complete(false)
            default: task.cancel()
            }
        }
        _ = await task.value

        XCTAssertEqual(transport.starts, 1)
        XCTAssertEqual(transport.cancels, 1)
    }

    func test_readinessProbeRetriesWhileTheSessionIsAllowed() async {
        let (manager, probe) = makeProbeManager()
        defer {
            probe.release()
            _ = manager.stopSynchronously(timeout: 1)
        }
        manager.setAutoStartAllowed(true)
        manager.setAppForeground(true)
        await fulfillment(of: [probe.entered], timeout: 1)

        probe.release()
        await fulfillment(of: [probe.laterAttempt], timeout: 1)

        XCTAssertEqual(probe.attempts, 2)
    }

    func test_synchronousStopCancelsReadinessProbeAndPreventsFurtherAttempts() async {
        await assertExplicitStopCancelsProbe(synchronously: true)
    }

    func test_completeShutdownCancelsReadinessProbeAndPreventsFurtherAttempts() async {
        await assertExplicitStopCancelsProbe(synchronously: false)
    }

    func test_synchronousStopCancelsAnInFlightLivenessProbe() async {
        await assertExplicitStopCancelsProbe(synchronously: true, heldAttempt: 2, progress: 100)
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

    // MARK: - SOCKS endpoint

    func test_eachStartGivesArtiAndTheSessionANewSocksPortAndLogin() async {
        let arti = FakeArti()
        let urlSession = TorURLSession()
        let directory = stateDirectory
        let manager = TorManager(
            backend: arti.backend, urlSession: urlSession, dataDirectory: { directory },
            pollIntervalNanoseconds: 5_000_000, livenessIntervalNanoseconds: 5_000_000, usesPathMonitor: false
        )
        let unused = urlSession.endpoint

        await startReady(manager)
        XCTAssertTrue(manager.stopSynchronously(timeout: 1))
        await startReady(manager)
        defer { manager.shutdownCompletely() }

        let starts = arti.endpoints
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts.last, urlSession.endpoint, "the session must use the login Arti was started with")
        XCTAssertFalse(starts.contains(unused), "the endpoint known before any start is never used")
        XCTAssertNotEqual(starts[0].username, starts[1].username)
        XCTAssertNotEqual(starts[0].password, starts[1].password)
        for socks in starts {
            XCTAssertEqual(socks.host, "127.0.0.1")
            XCTAssertTrue(SocksEndpoint.portRange.contains(socks.port))
            XCTAssertEqual(socks.username.count, 32)
            XCTAssertEqual(socks.password.count, 32)
        }
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
