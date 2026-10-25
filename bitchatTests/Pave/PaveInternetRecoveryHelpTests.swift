import AVFoundation
import Combine
import Foundation
import Testing
@testable import bitchat

@Suite("Pavé Internet recovery help")
struct PaveInternetRecoveryHelpTests {
    private let failures: [WeshInternetState.Failure] = [.torBlocked, .noNetwork, .relaysUnreachable, .routeFault, .torStopped]

    @Test func everyCauseKeepsItsOwnGuidanceInBothLanguages() throws {
        for language in ["fr", "en"] {
            let path = try #require(PaveCopy.bundle.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            let locale = Locale(identifier: language)
            let help = try failures.map { failure in
                try #require(PaveInternetStatus(.error(failure)).recoveryHelp(bundle: bundle, locale: locale))
            }
            #expect(Set(help).count == failures.count)
            #expect(help.allSatisfy { $0.contains(language == "fr" ? "Réessayer" : "Try again") })
            #expect(help[0].contains(language == "fr" ? "Tor n’a pas réussi" : "Tor could not connect"))
            #expect(help[1].contains("Wi-Fi"))
            #expect(help[3].contains(language == "fr" ? "tenter" : "attempt"))
            #expect(help[3].contains(language == "fr" ? "désactivez" : "turn Internet mode off"))
            #expect(help[4].contains(language == "fr" ? "inattendue" : "unexpectedly"))
            let preserved = PaveCopy.text("pave.internet.help.preserved", bundle: bundle, locale: locale)
            #expect(preserved.contains("Bluetooth"))
            #expect(preserved.contains(language == "fr" ? "ne sont pas confirmés" : "not confirmed"))
            #expect(!preserved.lowercased().contains(language == "fr" ? "brouillon" : "draft"))
        }
    }

    @Test func healthyStatesDoNotOfferRecoveryHelp() {
        for status in [PaveInternetStatus.off, .connecting(torProgress: 10), .connected, .paused] {
            #expect(status.recoveryHelp == nil)
            #expect(!status.offersRetry)
        }
        for failure in failures {
            #expect(PaveInternetStatus.failed(failure).offersRetry)
        }
    }

    @Test @MainActor func retryCanRemainBlockedByTheRealRouteFault() {
        let suite = "wesh.pave.recovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: WeshInternetSettings.enabledKey)
        defaults.set(true, forKey: WeshInternetSettings.disclosureAcceptedKey)
        var networkChanges: [Bool] = []
        var retryConnections = 0
        let mode = WeshInternetMode(defaults: defaults, dependencies: .init(
            forceTor: { false }, ensureNostrIdentity: { true },
            setNetworkEnabled: { networkChanges.append($0) },
            retryConnections: { retryConnections += 1 },
            stopTorAndWait: { true }, deleteArtiDirectory: { true },
            inputs: Empty().eraseToAnyPublisher(), scheduleAfter: { _, _ in }
        ), available: true)
        mode.start()
        #expect(mode.internetStatus == .failed(.routeFault))
        mode.retryInternet()
        #expect(mode.internetStatus == .failed(.routeFault))
        #expect(retryConnections == 0)
        #expect(networkChanges.last == false)
        #expect(mode.setInternetModeEnabled(false))
        #expect(mode.internetStatus == .off)
    }
}

@Suite("QR camera availability")
@MainActor
struct CameraScannerAvailabilityTests {
    @Test func missingHardwareNeverConsultsAuthorizationOrRequestsPermission() {
        var authorizationReads = 0
        var permissionRequests = 0
        let coordinator = CameraScannerCoordinator(
            cameraAvailable: { false },
            authorizationStatus: { authorizationReads += 1; return .notDetermined },
            requestAccess: { _ in permissionRequests += 1 }
        )
        coordinator.setup(previewLayer: AVCaptureVideoPreviewLayer(), onCode: { _ in })
        coordinator.setActive(true)
        coordinator.shutdown()
        #expect(authorizationReads == 0)
        #expect(permissionRequests == 0)
    }

    @Test func cameraRemovedWhilePermissionIsPendingNeverConfiguresAnInput() async throws {
        var available = true
        var permissionCompletion: ((Bool) -> Void)?
        var configurations = 0
        var unavailableReports = 0
        let layer = AVCaptureVideoPreviewLayer()
        let coordinator = CameraScannerCoordinator(
            cameraAvailable: { available },
            authorizationStatus: { .notDetermined },
            requestAccess: { permissionCompletion = $0 },
            configureSession: { configurations += 1; return false }
        )
        defer { coordinator.shutdown() }
        coordinator.setup(previewLayer: layer, onCode: { _ in }, onUnavailable: { unavailableReports += 1 })
        coordinator.setActive(true)
        let completePermission = try #require(permissionCompletion)
        available = false
        completePermission(true)
        // Drain the permission callback, then its queued unavailable report.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        #expect(configurations == 0)
        #expect(unavailableReports == 1)
        #expect(layer.session?.inputs.isEmpty == true)
        #expect(layer.session?.outputs.isEmpty == true)
    }
}
