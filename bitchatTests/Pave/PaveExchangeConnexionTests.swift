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

    @Test func theChatOpensOnceEvenOnADoubleTap() {
        var latch = PaveCompletionLatch()
        var opened = 0
        latch.fire { opened += 1 }  // « Ouvrir la discussion »
        latch.fire { opened += 1 }  // a second tap
        #expect(opened == 1)
    }

    @Test func nothingOpensTheChatButTheButton() throws {
        // No timer: in a crowd, the chat opens only on an explicit tap.
        let french = try PaveCatalogStrings.strings("fr")
        #expect(french["pave.exchange.autoOpen"] == nil)
        #expect(french["pave.exchange.openChat"] == "Ouvrir la discussion")
    }

    @Test func theScannerReadsOnlyInsideTheViewfinder() {
        #expect(PaveScanArea.viewfinder(in: CGSize(width: 300, height: 220))
            == CGRect(x: 75, y: 35, width: 150, height: 150))
        // A camera view smaller than the viewfinder: the whole view, never more.
        #expect(PaveScanArea.viewfinder(in: CGSize(width: 120, height: 100))
            == CGRect(x: 10, y: 0, width: 100, height: 100))
    }

    @Test func aFrameWithMoreThanOneCodeIsIgnored() {
        #expect(PaveScanArea.singleCode(["bitchat://verify?a"]) == "bitchat://verify?a")
        #expect(PaveScanArea.singleCode(["bitchat://verify?a", "bitchat://verify?b"]) == nil)
        #expect(PaveScanArea.singleCode(["bitchat://verify?a", nil]) == nil)
        #expect(PaveScanArea.singleCode([nil]) == nil)
        #expect(PaveScanArea.singleCode([]) == nil)
    }

    @Test func checksNeverCarryARemoteName() throws {
        let french = try PaveCatalogStrings.strings("fr")
        let english = try PaveCatalogStrings.strings("en")
        #expect(french["pave.exchange.theyScanned"] == "Son téléphone a répondu")
        #expect(french["pave.exchange.iScanned"] == "Son code est scanné")
        #expect(english["pave.exchange.theyScanned"] == "Their phone answered")
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
        #expect(PaveInternetStatus(.connecting(torProgress: 40)) == .connecting(torProgress: 40))
        #expect(PaveInternetStatus(.on) == .connected)
        #expect(PaveInternetStatus(.paused) == .paused)
        #expect(PaveInternetStatus(.error(.torBlocked)) == .failed)
        #expect(PaveInternetStatus(.error(.routeFault)) == .failed)
    }
}

@Suite("Pavé Internet status copy")
struct PaveInternetStatusCopyTests {
    private func resources(_ language: String) throws -> Bundle {
        let path = try #require(PaveCopy.bundle.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test func frenchLabelsAreTheSpecPill() throws {
        let bundle = try resources("fr")
        let locale = Locale(identifier: "fr_FR")
        func label(_ status: PaveInternetStatus) -> String { status.label(bundle: bundle, locale: locale) }
        #expect(label(.off) == "Bluetooth seulement")
        #expect(label(.connecting(torProgress: 42)) == "Connexion à Tor… 42\u{00A0}%")
        #expect(label(.connected) == "Internet actif")
        #expect(label(.paused) == "Internet en pause")
        #expect(label(.failed) == "Internet indisponible — Réessayer")
    }

    @Test func englishLabelsMatchTheFrenchOnes() throws {
        let bundle = try resources("en")
        let locale = Locale(identifier: "en_US")
        func label(_ status: PaveInternetStatus) -> String { status.label(bundle: bundle, locale: locale) }
        #expect(label(.off) == "Bluetooth only")
        #expect(label(.connecting(torProgress: 7)) == "Connecting to Tor… 7%")
        #expect(label(.connected) == "Internet on")
        #expect(label(.paused) == "Internet paused")
        #expect(label(.failed) == "Internet unavailable — Try again")
    }

    @Test func theTorPercentageIsTheRealOneAndStaysInRange() throws {
        let bundle = try resources("fr")
        let locale = Locale(identifier: "fr_FR")
        let mode = WeshInternetState.connecting(torProgress: 63)
        #expect(PaveInternetStatus(mode).label(bundle: bundle, locale: locale) == "Connexion à Tor… 63\u{00A0}%")
        #expect(PaveInternetStatus.connecting(torProgress: 0).label(bundle: bundle, locale: locale) == "Connexion à Tor… 0\u{00A0}%")
        #expect(PaveInternetStatus.connecting(torProgress: 140).label(bundle: bundle, locale: locale) == "Connexion à Tor… 100\u{00A0}%")
        #expect(PaveInternetStatus.connecting(torProgress: -5).label(bundle: bundle, locale: locale) == "Connexion à Tor… 0\u{00A0}%")
    }

    @Test func onlyAFailureRetriesAndTheHomePillWaitsForInternetMode() {
        let all: [PaveInternetStatus] = [.off, .connecting(torProgress: 10), .connected, .paused, .failed]
        #expect(all.filter(\.offersRetry) == [.failed])
        #expect(all.filter { !$0.showsHomePill } == [.off])
    }

    @Test @MainActor func aTouchOnTheFailedStatusRetries() {
        let stub = PaveInternetModeStub(internetStatus: .failed, disclosureAccepted: true)
        stub.retryInternet()
        #expect(stub.internetStatus == .connecting(torProgress: 0))
    }
}

@Suite("Pavé contact Internet badge")
struct PaveContactInternetBadgeTests {
    private typealias Contact = WeshQRTrust.Contact
    private let noise = String(repeating: "a1", count: 32)
    private let npub = "npub1r799vmpq2ceaq2gfgara9cv0gns9ny7a57jl3r6fvpuzqhm9devsg53zcr"

    @Test func enrolledContactsAreReachableAndLegacyOnesNeedARescan() {
        let enrolled = Contact(noiseKeyHex: noise, nickname: "Nora", npub: npub, npubProven: true)
        let legacy = Contact(noiseKeyHex: noise, nickname: "Sam")
        for status in [PaveInternetStatus.connecting(torProgress: 30), .connected, .paused, .failed] {
            #expect(PaveContactInternetBadge(contact: enrolled, internet: status) == .reachable)
            #expect(PaveContactInternetBadge(contact: legacy, internet: status) == .rescanRequired)
        }
    }

    @Test func noBadgeWhileInternetIsOff() {
        let enrolled = Contact(noiseKeyHex: noise, nickname: "Nora", npub: npub, npubProven: true)
        let legacy = Contact(noiseKeyHex: noise, nickname: "Sam")
        #expect(PaveContactInternetBadge(contact: enrolled, internet: .off) == nil)
        #expect(PaveContactInternetBadge(contact: legacy, internet: .off) == nil)
    }

    @Test func aBindingUnderReviewIsNeverShownAsReachable() {
        let conflict = Contact(noiseKeyHex: noise, nickname: "Nora", npub: npub, npubConflict: true)
        let warning = Contact(noiseKeyHex: noise, nickname: "Nora", npub: npub, npubProven: true, npubProofWarning: true)
        let malformed = Contact(noiseKeyHex: noise, nickname: "Nora", npub: "npub1")
        for contact in [conflict, warning, malformed] {
            #expect(PaveContactInternetBadge(contact: contact, internet: .connected) == nil)
        }
    }

    @Test func badgeCopyInFrenchAndEnglish() throws {
        let fr = try #require(PaveCopy.bundle.path(forResource: "fr", ofType: "lproj").flatMap(Bundle.init(path:)))
        let en = try #require(PaveCopy.bundle.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        let french = Locale(identifier: "fr_FR"), english = Locale(identifier: "en_US")
        #expect(PaveContactInternetBadge.reachable.label(bundle: fr, locale: french) == "Joignable par Internet")
        #expect(PaveContactInternetBadge.rescanRequired.label(bundle: fr, locale: french) == "Rescan requis")
        #expect(PaveContactInternetBadge.reachable.label(bundle: en, locale: english) == "Reachable over the Internet")
        #expect(PaveContactInternetBadge.rescanRequired.label(bundle: en, locale: english) == "Rescan required")
    }
}

@Suite("Pavé review fixes")
struct PaveReviewFixTests {
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

@Suite("Pavé erase overlay window")
struct PaveEraseOverlayOrderTests {
    private final class Window {}

    @Test func closingTheOverlayGivesKeyStatusBackToTheAppWindow() {
        let app = Window(), other = Window(), overlay = Window()
        #expect(PaveWindowOrder.keyAfterOverlay(previous: app, overlay: overlay, windows: [app, other, overlay]) === app)
        // The previous key window went away meanwhile: the first other window of the scene.
        #expect(PaveWindowOrder.keyAfterOverlay(previous: nil, overlay: overlay, windows: [overlay, other]) === other)
        #expect(PaveWindowOrder.keyAfterOverlay(previous: app, overlay: overlay, windows: [overlay, other]) === other)
        // Never the overlay itself.
        #expect(PaveWindowOrder.keyAfterOverlay(previous: overlay, overlay: overlay, windows: [overlay]) == nil)
    }
}
