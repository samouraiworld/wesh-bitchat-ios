import Combine
import Foundation
import Testing
@testable import bitchat

@Suite("Pavé Échanger")
struct PaveExchangeScreenLogicTests {
    @Test func yourFingerprintShowsAtOnceTheContactsOnlyOnSuccess() {
        let pending = PaveExchangeFingerprints(mine: "7F3A 91C2 0B5E 44D8", contact: "A1B2 C3D4 E5F6 0718",
                                               progress: PaveExchangeProgress(theyScannedMe: true, iScannedThem: false))
        #expect(pending.mine == "7F3A 91C2 0B5E 44D8")
        #expect(pending.contact == nil)
        let done = PaveExchangeFingerprints(mine: nil, contact: "A1B2 C3D4 E5F6 0718",
                                            progress: PaveExchangeProgress(theyScannedMe: true, iScannedThem: true))
        #expect(done.mine == nil)
        #expect(done.contact == "A1B2 C3D4 E5F6 0718")
    }

    @Test func theChatOpensOnceWhenTheButtonAndTheTimerBothFire() {
        var latch = PaveCompletionLatch()
        var opened = 0
        latch.fire { opened += 1 }  // « Ouvrir la discussion »
        latch.fire { opened += 1 }  // the 3 s timer
        #expect(opened == 1)
        #expect(PaveCompletionLatch.successHold == 3)
    }

    @Test func checksNeverCarryARemoteName() throws {
        let french = try PaveCatalogStrings.strings("fr")
        let english = try PaveCatalogStrings.strings("en")
        #expect(french["pave.exchange.theyScanned"] == "Votre code est scanné")
        #expect(french["pave.exchange.iScanned"] == "Son code est scanné")
        #expect(english["pave.exchange.theyScanned"] == "Your code was scanned")
        #expect(english["pave.exchange.iScanned"] == "Their code was scanned")
        #expect(french["pave.exchange.theyScannedNamed"] == nil && french["pave.exchange.iScannedNamed"] == nil)
        for check in PaveExchangeCheck.allCases {
            for done in [true, false] {
                #expect(!check.label(done: done).contains("%"))
            }
        }
    }

    @Test func fingerprintsAreComputedOffTheMainThread() async {
        let key = Data((0..<32).map { UInt8($0) })
        #expect(await PaveFingerprint.computed(key) == PaveFingerprint.short(key))
        #expect(await PaveFingerprint.computed(nil) == nil)
    }
}

@Suite("Pavé camera permission")
struct PaveCameraCardTests {
    @Test func theRationaleComesFirstAndSettingsOnlyAfterAPermanentRefusal() {
        #expect(PaveCameraCard(.notDetermined) == .rationale)
        #expect(PaveCameraCard(.authorized) == .scanner)
        #expect(PaveCameraCard(.denied) == .settings)
        #expect(PaveCameraCard(.restricted) == .settings)
    }

    @Test func rationaleCopyIsExact() throws {
        let french = try PaveCatalogStrings.strings("fr")
        #expect(french["pave.exchange.cameraRationale"]
            == "La caméra sert uniquement à lire le code de votre contact. Aucune image n'est enregistrée.")
        #expect(french["pave.exchange.cameraAllow"] == "Autoriser la caméra")
    }
}

@MainActor
@Suite("Pavé Internet switch", .serialized)
struct PaveInternetSwitchTests {
    static let disclosureFR = "Le mode Internet passe par Tor et par des relais Nostr publics que Wesh n'exploite pas. "
        + "Les relais ne voient ni votre adresse IP ni le contenu, mais voient la clé Internet du destinataire, "
        + "l'heure et la taille des messages, et peuvent relier vos envois à votre clé. Ils peuvent conserver les "
        + "messages chiffrés. Quiconque a votre QR connaît votre clé Internet. Désactivé par défaut ; "
        + "l'effacement d'urgence le désactive."

    @Test func copyMatchesTheSpec() throws {
        let french = try PaveCatalogStrings.strings("fr")
        let english = try PaveCatalogStrings.strings("en")
        #expect(french["pave.internet.disclosureFull"] == Self.disclosureFR)
        #expect(english["pave.internet.disclosureFull"]?.hasPrefix("Internet mode goes through Tor") == true)
        #expect(french["pave.connexion.internetDisclosure"]
            == "Passe par Tor et par des relais publics. Désactivé par défaut.")
        #expect(french["pave.onboarding.noLocation"] == "Wesh n'utilise pas votre position.")
    }

    @Test func theFirstSwitchOnShowsTheDisclosureFirst() {
        let fake = PaveInternetModeStub()
        #expect(PaveInternetToggle.toggle(fake, on: true) == .needsDisclosure)
        #expect(fake.internetStatus == .off)
        #expect(!fake.disclosureAccepted)
        #expect(PaveInternetToggle.confirmDisclosure(fake) == .changed)
        #expect(fake.disclosureAccepted)
        #expect(fake.internetStatus.isEnabled)
        #expect(PaveInternetToggle.toggle(fake, on: false) == .changed)
        #expect(fake.internetStatus == .off)
        #expect(PaveInternetToggle.toggle(fake, on: true) == .changed)
    }

    @Test func aRefusedSwitchIsReported() {
        let fake = PaveInternetModeStub(disclosureAccepted: true, refusesEnabling: true)
        #expect(PaveInternetToggle.toggle(fake, on: true) == .refused)
        #expect(fake.internetStatus == .off)
    }

    private func realMode(torForcible: Bool) -> WeshInternetMode {
        let suite = "wesh.pave.internet.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return WeshInternetMode(defaults: defaults, dependencies: .init(
            forceTor: { torForcible },
            ensureNostrIdentity: { true },
            setNetworkEnabled: { _ in },
            retryConnections: {},
            stopTorAndWait: { true },
            deleteArtiDirectory: { true },
            inputs: Empty().eraseToAnyPublisher(),
            scheduleAfter: { _, _ in }
        ))
    }

    @Test func theSwitchDrivesTheRealInternetModeOffByDefault() {
        let mode = realMode(torForcible: true)
        #expect(mode.internetStatus == .off)
        #expect(PaveInternetToggle.toggle(mode, on: true) == .needsDisclosure)
        #expect(!mode.isEnabled)
        #expect(PaveInternetToggle.confirmDisclosure(mode) == .changed)
        #expect(mode.isEnabled)
        #expect(mode.internetStatus.isEnabled)
        #expect(PaveInternetToggle.toggle(mode, on: false) == .changed)
        #expect(mode.internetStatus == .off)
    }

    @Test func theRealModeRefusesWhenTorCannotBeForced() {
        let mode = realMode(torForcible: false)
        #expect(PaveInternetToggle.confirmDisclosure(mode) == .refused)
        #expect(!mode.isEnabled)
        #expect(mode.internetStatus == .off)
    }

    @Test func statesMapToWhatTheSheetShows() {
        #expect(PaveInternetStatus(.off) == .off)
        #expect(PaveInternetStatus(.connecting(torProgress: 40)) == .connecting)
        #expect(PaveInternetStatus(.on) == .connected(relayCount: nil))
        #expect(PaveInternetStatus(.paused) == .paused)
        #expect(PaveInternetStatus(.error(.torBlocked)) == .failed)
    }
}

@Suite("Pavé review fixes")
struct PaveReviewFixTests {
    @Test func closingBeforeTheTimerKeepsTheChatClosed() {
        var latch = PaveCompletionLatch()
        var opened = 0
        latch.close()  // « Fermer » within the 3 s hold
        latch.fire { opened += 1 }  // the timer, if it still ran
        #expect(opened == 0)
        #expect(latch.fired)
    }

    @Test @MainActor func theShortcutWorksAgainAfterTheScreenCloses() {
        let request = PaveEraseRequest()
        #expect(!request.isPresented)
        request.request()
        #expect(request.isPresented)
        #expect(request.requestCount == 1)
        request.request()  // a second run while the screen is up: still one screen
        #expect(request.isPresented)
        #expect(request.requestCount == 2)
        request.close()
        #expect(!request.isPresented)
        request.request()
        #expect(request.isPresented)
    }

    @Test func settingsShowTheSameOutcomeAsTheEraseScreen() {
        #expect(PaveEraseScreen.Outcome(erased: true) == .erased)
        #expect(PaveEraseScreen.Outcome(erased: false) == .failed)
    }
}
