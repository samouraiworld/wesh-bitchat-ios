import BitLogger
import Foundation
#if canImport(Network)
import Network
#endif

#if !canImport(Network)
private final class NWPathMonitor {
    var pathUpdateHandler: ((Any) -> Void)?

    func start(queue: DispatchQueue) {
        // Path monitoring is unavailable on this platform; nothing to do.
    }
}
#endif

// FFI declarations for Arti (Rust)
@_silgen_name("arti_start")
private func arti_start(_ dataDir: UnsafePointer<CChar>, _ socksPort: UInt16) -> Int32

@_silgen_name("arti_stop")
private func arti_stop() -> Int32

@_silgen_name("arti_is_running")
private func arti_is_running() -> Int32

@_silgen_name("arti_bootstrap_progress")
private func arti_bootstrap_progress() -> Int32

@_silgen_name("arti_bootstrap_summary")
private func arti_bootstrap_summary(_ buf: UnsafeMutablePointer<CChar>, _ len: Int32) -> Int32

/// The Arti calls `TorManager` makes, injectable so tests can start, kill and
/// probe a fake Arti without the Rust library touching the network.
struct ArtiBackend: Sendable {
    var start: @Sendable (_ dataDir: String, _ socksPort: UInt16) -> Int32
    var stop: @Sendable () -> Int32
    var isRunning: @Sendable () -> Bool
    var bootstrapProgress: @Sendable () -> Int
    var bootstrapSummary: @Sendable () -> String
    /// One TCP connect to the local SOCKS port; true if it accepted.
    var probeSocks: @Sendable (_ port: Int) async -> Bool

    static let live = ArtiBackend(
        start: { dataDir, socksPort in
            dataDir.withCString { arti_start($0, socksPort) }
        },
        stop: { arti_stop() },
        isRunning: { arti_is_running() != 0 },
        bootstrapProgress: { Int(arti_bootstrap_progress()) },
        bootstrapSummary: {
            var buf = [CChar](repeating: 0, count: 256)
            let len = arti_bootstrap_summary(&buf, Int32(buf.count))
            return len > 0 ? String(cString: buf) : ""
        },
        probeSocks: { port in await TorManager.probeLocalSocks(port: port) }
    )
}

/// Arti-based Tor integration for BitChat.
/// - Boots a local Arti client and exposes a SOCKS5 proxy
///   on 127.0.0.1:socksPort. All app networking should await readiness and
///   route via this proxy. Fails closed by default when Tor is unavailable.
@MainActor
public final class TorManager: ObservableObject {
    public static let shared = TorManager()

    // SOCKS endpoint where Arti listens
    let socksHost: String = "127.0.0.1"
    let socksPort: Int = 39050

    // State
    @Published private(set) public var isReady: Bool = false
    @Published private(set) var isStarting: Bool = false
    @Published private(set) var lastError: Error?
    @Published private(set) public var bootstrapProgress: Int = 0
    @Published private(set) var bootstrapSummary: String = ""
    /// True once a bootstrap attempt has spent its whole deadline without
    /// completing.
    ///
    /// This separates "still starting" from "not getting through", which are
    /// indistinguishable from `isStarting` alone. The second is what a network
    /// that blocks Tor looks like from inside the app, and without it the UI
    /// says "starting tor…" indefinitely while nothing is happening. Cleared on
    /// each new start attempt.
    @Published private(set) public var bootstrapDidStall: Bool = false
    /// True once Arti has exited (or its SOCKS listener vanished) without
    /// being asked to stop. Readiness drops with it, so nothing can be routed
    /// until an explicit restart; `.TorDidStopUnexpectedly` is posted once.
    /// Cleared on each new start attempt.
    @Published private(set) public var didStopUnexpectedly: Bool = false

    // Internal readiness trackers
    private var socksReady: Bool = false { didSet { recomputeReady() } }
    private var restarting: Bool = false

    // Whether the app must enforce Tor for all connections (fail-closed).
    public var torEnforced: Bool {
        #if BITCHAT_DEV_ALLOW_CLEARNET
        return false
        #else
        return true
        #endif
    }

    // Returns true only when Tor is actually up (or dev fallback is compiled).
    var networkPermitted: Bool {
        if torEnforced { return isReady }
        return true
    }

    private var didStart = false
    // shutdownCompletely() resets `didStart` asynchronously (after Arti has
    // actually stopped). A startIfNeeded() arriving in that window must not be
    // dropped — it is recorded here and honored when the shutdown finishes.
    private var shutdownsInFlight = 0
    private var startPendingAfterShutdown = false
    private var bootstrapMonitorStarted = false
    // Fences the detached poll loop: shutdown, dormancy, and restart each bump
    // this, so a loop from a previous attempt cannot run out its deadline and
    // report a stall over state that a newer lifecycle event already owns.
    private var bootstrapGeneration = 0
    private var pathMonitor: NWPathMonitor?
    // Background until the app says otherwise: a background relaunch (BLE
    // restoration) with Internet on must not start Arti, and only a scene
    // that actually became active calls `setAppForeground(true)`.
    private var isAppForeground: Bool = false
    private var lastRestartAt: Date? = nil
    private var startedAt: Date? = nil  // Tracks initial startup time for grace period
    private(set) var allowAutoStart: Bool = false

    nonisolated private let backend: ArtiBackend
    private let dataDirectory: () -> URL?
    private let pollIntervalNanoseconds: UInt64
    private let livenessIntervalNanoseconds: UInt64
    private let usesPathMonitor: Bool

    private convenience init() {
        self.init(backend: .live)
    }

    init(
        backend: ArtiBackend,
        dataDirectory: @escaping () -> URL? = TorManager.defaultDataDirectory,
        pollIntervalNanoseconds: UInt64 = 1_000_000_000,
        livenessIntervalNanoseconds: UInt64 = 5_000_000_000,
        usesPathMonitor: Bool = true
    ) {
        self.backend = backend
        self.dataDirectory = dataDirectory
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.livenessIntervalNanoseconds = livenessIntervalNanoseconds
        self.usesPathMonitor = usesPathMonitor
    }

    // MARK: - Public API

    public func startIfNeeded() {
        guard allowAutoStart else { return }
        guard isAppForeground else { return }
        if shutdownsInFlight > 0 {
            SecureLogger.debug("TorManager: startIfNeeded() deferred - shutdown in flight", category: .session)
            startPendingAfterShutdown = true
            return
        }
        guard !didStart else { return }
        didStart = true
        isStarting = true
        bootstrapDidStall = false
        didStopUnexpectedly = false
        startedAt = Date()  // Track startup time for grace period
        SecureLogger.debug("TorManager: startIfNeeded() - startedAt set", category: .session)
        lastError = nil
        NotificationCenter.default.post(name: .TorWillStart, object: nil)
        ensureFilesystemLayout()
        startArti()
        startPathMonitorIfNeeded()
    }

    /// A start requested while in the background was dropped, so becoming
    /// foreground starts Arti if it is allowed and not already running.
    public func setAppForeground(_ foreground: Bool) {
        let becameForeground = foreground && !isAppForeground
        isAppForeground = foreground
        if becameForeground { startIfNeeded() }
    }

    public func isForeground() -> Bool { isAppForeground }

    nonisolated
    // Default matches the bootstrap monitor deadline (75s); a shorter wait here
    // reports "not ready" while Arti is still legitimately bootstrapping.
    public func awaitReady(timeout: TimeInterval = 75.0) async -> Bool {
        await MainActor.run {
            if self.isAppForeground { self.startIfNeeded() }
        }
        let deadline = Date().addingTimeInterval(timeout)
        if await MainActor.run(body: { self.networkPermitted }) { return true }
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if await MainActor.run(body: { self.networkPermitted }) { return true }
        }
        return await MainActor.run(body: { self.networkPermitted })
    }

    // MARK: - Filesystem

    func dataDirectoryURL() -> URL? { dataDirectory() }

    nonisolated static func defaultDataDirectory() -> URL? {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = base.appendingPathComponent("bitchat/arti", isDirectory: true)
            return dir
        } catch {
            return nil
        }
    }

    private func ensureFilesystemLayout() {
        guard let dir = dataDirectoryURL() else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            // Non-fatal; Arti will surface errors during start if paths are missing
        }
    }

    // MARK: - Arti Integration

    private func startArti() {
        guard let dir = dataDirectoryURL()?.path else {
            isStarting = false
            lastError = NSError(domain: "TorManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data directory"])
            return
        }

        // Check if already running
        if backend.isRunning() {
            SecureLogger.info("TorManager: Arti already running", category: .session)
            startBootstrapMonitor()
            return
        }

        let result = backend.start(dir, UInt16(socksPort))

        if result != 0 {
            SecureLogger.error("TorManager: arti_start failed rc=\(result)", category: .session)
            isStarting = false
            lastError = NSError(domain: "TorManager", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "Arti start failed"])
            return
        }

        SecureLogger.info("TorManager: arti_start OK (SOCKS \(socksHost):\(socksPort))", category: .session)
        startBootstrapMonitor()

        // Start SOCKS readiness probe
        let generation = bootstrapGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let ready = await self.waitForSocksReady(timeout: 60.0)
            await MainActor.run {
                // A stop or an unexpected exit since this probe began owns the state now.
                guard generation == self.bootstrapGeneration else { return }
                self.socksReady = ready
                if ready {
                    SecureLogger.info("TorManager: SOCKS ready at \(self.socksHost):\(self.socksPort)", category: .session)
                } else {
                    self.lastError = NSError(domain: "TorManager", code: -14, userInfo: [NSLocalizedDescriptionKey: "SOCKS not reachable"])
                    SecureLogger.error("TorManager: SOCKS not reachable (timeout)", category: .session)
                }
            }
        }
    }

    private func waitForSocksReady(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await backend.probeSocks(socksPort) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    nonisolated static func probeLocalSocks(port socksPort: Int) async -> Bool {
        #if canImport(Network)
        await withCheckedContinuation { cont in
            let params = NWParameters.tcp
            let host = NWEndpoint.Host.ipv4(.loopback)
            guard let port = NWEndpoint.Port(rawValue: UInt16(socksPort)) else {
                cont.resume(returning: false)
                return
            }
            let endpoint = NWEndpoint.hostPort(host: host, port: port)
            let conn = NWConnection(to: endpoint, using: params)

            var resumed = false
            let resumeOnce: (Bool) -> Void = { value in
                if !resumed {
                    resumed = true
                    cont.resume(returning: value)
                }
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(true)
                    conn.cancel()
                case .failed, .cancelled:
                    resumeOnce(false)
                    conn.cancel()
                default:
                    break
                }
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
                resumeOnce(false)
                conn.cancel()
            }

            conn.start(queue: DispatchQueue.global(qos: .utility))
        }
        #else
        return false
        #endif
    }

    // MARK: - Bootstrap Monitoring

    private func startBootstrapMonitor() {
        guard !bootstrapMonitorStarted else { return }
        bootstrapMonitorStarted = true
        bootstrapGeneration += 1
        let generation = bootstrapGeneration
        Task.detached(priority: .utility) { [weak self] in
            await self?.bootstrapPollLoop(generation: generation)
        }
    }

    private func bootstrapPollLoop(generation: Int) async {
        let deadline = Date().addingTimeInterval(75)
        var didComplete = false
        while Date() < deadline {
            guard generation == bootstrapGeneration else { return }
            guard backend.isRunning() else {
                handleUnexpectedStop(reason: "Arti exited during bootstrap")
                return
            }
            let progress = backend.bootstrapProgress()
            let summary = backend.bootstrapSummary()

            self.bootstrapProgress = progress
            self.bootstrapSummary = summary
            if progress >= 100 { self.isStarting = false }
            self.recomputeReady()

            if progress >= 100 {
                didComplete = true
                break
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        // Running out the deadline is a reportable outcome, not silence. The
        // loop previously just ended, leaving `isStarting` true forever, so a
        // blocked network was indistinguishable from a slow one. A deliberate
        // shutdown mid-bootstrap is not a stall, hence the generation check.
        if !didComplete {
            guard generation == bootstrapGeneration else { return }
            self.isStarting = false
            self.bootstrapDidStall = true
            SecureLogger.warning(
                "TorManager: bootstrap did not complete within its deadline (progress=\(self.bootstrapProgress)); network may be blocking Tor",
                category: .session
            )
            NotificationCenter.default.post(name: .TorBootstrapDidStall, object: nil)
            return
        }

        await livenessLoop(generation: generation)
    }

    /// Watches a bootstrapped Arti until a deliberate stop, dormancy or
    /// restart bumps the generation. Arti exiting on its own, or its SOCKS
    /// listener failing two probes in a row, drops readiness at once so no
    /// caller keeps routing to a dead proxy.
    private func livenessLoop(generation: Int) async {
        var failedProbes = 0
        while generation == bootstrapGeneration {
            try? await Task.sleep(nanoseconds: livenessIntervalNanoseconds)
            guard generation == bootstrapGeneration else { return }
            guard backend.isRunning() else {
                handleUnexpectedStop(reason: "Arti exited")
                return
            }
            guard socksReady else { continue }
            let socksAlive = await backend.probeSocks(socksPort)
            guard generation == bootstrapGeneration else { return }
            failedProbes = socksAlive ? 0 : failedProbes + 1
            if failedProbes >= 2 {
                handleUnexpectedStop(reason: "SOCKS listener stopped answering")
                return
            }
        }
    }

    private func handleUnexpectedStop(reason: String) {
        SecureLogger.error("TorManager: \(reason) without a stop request; Tor is down", category: .session)
        bootstrapGeneration += 1
        // A runtime whose SOCKS listener is gone is stopped too, so the next
        // start boots a fresh one instead of adopting the broken one.
        if backend.isRunning() { _ = backend.stop() }
        socksReady = false
        bootstrapProgress = 0
        bootstrapSummary = ""
        isStarting = false
        isReady = false
        // `didStart` stays set so `startIfNeeded()` (awaitReady, relay
        // queues) cannot bring Arti back behind the app's back; a shutdown
        // or an explicit restart clears it.
        bootstrapMonitorStarted = false
        lastError = NSError(domain: "TorManager", code: -20, userInfo: [NSLocalizedDescriptionKey: reason])
        didStopUnexpectedly = true
        NotificationCenter.default.post(name: .TorDidStopUnexpectedly, object: nil)
    }

    // MARK: - Foreground/Background

    public func ensureRunningOnForeground() {
        if !allowAutoStart { return }
        SecureLogger.debug("TorManager: ensureRunningOnForeground() started", category: .session)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let claimed: Bool = await MainActor.run {
                if self.isStarting || self.restarting { return false }
                self.restarting = true
                return true
            }
            if !claimed { return }

            // Check if already ready
            let alreadyReady = await MainActor.run { self.isReady }
            if alreadyReady {
                await MainActor.run { self.restarting = false }
                return
            }

            // Arti doesn't support dormant/wake (it's a no-op stub), so always do full restart
            await self.restartArti()
            await MainActor.run { self.restarting = false }
        }
    }

    public func goDormantOnBackground() {
        // Arti doesn't support real dormant mode, so just mark as not ready.
        // iOS will suspend the runtime anyway. On foreground we do a full restart.
        // Clear isStarting so foreground recovery can proceed if bootstrap was interrupted.
        SecureLogger.debug("TorManager: goDormantOnBackground() called", category: .session)
        Task { @MainActor in
            self.bootstrapGeneration += 1
            self.isReady = false
            self.socksReady = false
            self.isStarting = false
        }
    }

    public func shutdownCompletely() {
        SecureLogger.debug("TorManager: shutdownCompletely() called", category: .session)
        startPendingAfterShutdown = false
        bootstrapGeneration += 1
        shutdownsInFlight += 1
        Task.detached { [weak self] in
            guard let self = self else { return }
            _ = self.backend.stop()

            // Wait for shutdown
            var waited = 0
            while self.backend.isRunning() && waited < 50 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }

            await MainActor.run {
                self.isReady = false
                self.socksReady = false
                self.bootstrapProgress = 0
                self.bootstrapSummary = ""
                self.isStarting = false
                self.didStart = false
                self.restarting = false
                self.bootstrapMonitorStarted = false
                // Note: Don't clear startedAt here - it will be set fresh on next startIfNeeded()
                // Clearing it here races with startup and defeats the grace period
                self.shutdownsInFlight -= 1
                if self.shutdownsInFlight == 0 && self.startPendingAfterShutdown {
                    self.startPendingAfterShutdown = false
                    SecureLogger.debug("TorManager: honoring start deferred during shutdown", category: .session)
                    self.startIfNeeded()
                }
            }
        }
    }

    /// Panic: stops Arti and blocks (bounded) until it has exited, so its
    /// state directory can be deleted with nothing left writing to it.
    /// Returns false if Arti is still running at the deadline.
    @discardableResult
    public func stopSynchronously(timeout: TimeInterval = 3.0) -> Bool {
        allowAutoStart = false
        startPendingAfterShutdown = false
        bootstrapGeneration += 1
        _ = backend.stop()
        let deadline = Date().addingTimeInterval(timeout)
        while backend.isRunning() && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        isReady = false
        socksReady = false
        bootstrapProgress = 0
        bootstrapSummary = ""
        isStarting = false
        didStart = false
        restarting = false
        bootstrapMonitorStarted = false
        return !backend.isRunning()
    }

    private func restartArti() async {
        SecureLogger.debug("TorManager: restartArti() starting", category: .session)
        await MainActor.run {
            NotificationCenter.default.post(name: .TorWillRestart, object: nil)
            self.bootstrapGeneration += 1
            self.isReady = false
            self.socksReady = false
            self.bootstrapProgress = 0
            self.bootstrapSummary = ""
            self.isStarting = true
            self.bootstrapDidStall = false
            self.lastRestartAt = Date()
        }

        _ = backend.stop()

        // Wait for stop
        var waited = 0
        while backend.isRunning() && waited < 40 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }

        await MainActor.run {
            self.bootstrapMonitorStarted = false
            self.didStart = false
        }

        await MainActor.run { self.startIfNeeded() }
    }

    private func recomputeReady() {
        let ready = socksReady && bootstrapProgress >= 100
        if ready != isReady {
            if !ready {
                SecureLogger.debug("TorManager: isReady -> false (socksReady=\(socksReady), bootstrap=\(bootstrapProgress))", category: .session)
            }
            isReady = ready
            if ready {
                NotificationCenter.default.post(name: .TorDidBecomeReady, object: nil)
            }
        }
    }

    private func startPathMonitorIfNeeded() {
        #if canImport(Network)
        guard usesPathMonitor, pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        let queue = DispatchQueue(label: "TorPathMonitor")
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.isAppForeground {
                    self.pokeTorOnPathChange()
                }
            }
        }
        monitor.start(queue: queue)
        #endif
    }

    private func pokeTorOnPathChange() {
        // Skip if we recently restarted
        if let last = lastRestartAt, Date().timeIntervalSince(last) < 3.0 {
            SecureLogger.debug("TorManager: pokeTorOnPathChange() skipped - recent restart", category: .session)
            return
        }
        // Skip during initial startup grace period (15s) to avoid race conditions
        if let started = startedAt, Date().timeIntervalSince(started) < 15.0 {
            SecureLogger.debug("TorManager: pokeTorOnPathChange() skipped - startup grace period (\(Int(Date().timeIntervalSince(started)))s)", category: .session)
            return
        }
        if isStarting || restarting {
            SecureLogger.debug("TorManager: pokeTorOnPathChange() skipped - isStarting=\(isStarting) restarting=\(restarting)", category: .session)
            return
        }
        if isReady { return }
        SecureLogger.debug("TorManager: pokeTorOnPathChange() - Arti not ready, initiating recovery", category: .session)
        ensureRunningOnForeground()
    }
}

// MARK: - Start policy configuration
extension TorManager {
    @MainActor
    public func setAutoStartAllowed(_ allow: Bool) {
        allowAutoStart = allow
    }

    @MainActor
    public func isAutoStartAllowed() -> Bool { allowAutoStart }
}
