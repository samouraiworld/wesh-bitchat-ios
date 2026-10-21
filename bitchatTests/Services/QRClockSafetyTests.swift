import BitFoundation
import Foundation
import Testing
@testable import bitchat

/// Only signed mock-transport QR payloads, an injected clock, a RAM-only
/// contact list and a recording context. No application graph is constructed.
@Suite(.serialized)
@MainActor
struct QRClockSafetyTests {
    @Test
    func reopenedCachedSignedCodeCannotOutliveItsSignedIssuanceOnScreen() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let service = service(currentDate: { now })
        let original = try #require(service.buildMyQRString(nickname: "Synthetic cached QR", npub: nil))
        now += 59
        let reopened = try #require(service.buildMyQRString(nickname: "Synthetic cached QR", npub: nil))
        #expect(reopened == original)
        let displayed = try #require(PaveQRRefreshClock.forDisplayedPayload(reopened, at: now))

        now = Date(timeIntervalSince1970: 1_301)

        #expect(service.verifyScannedQR(reopened, now: now.timeIntervalSince1970) == nil)
        #expect(displayed.isExpired(at: now))
    }

    @Test
    func freshDisplaySamplesTimeAfterSigningCrossesAWholeSecond() throws {
        var now = Date(timeIntervalSince1970: 1_000.999)
        let service = service(currentDate: { now })
        let refreshed = PaveQRRefreshClock.refresh(makePayload: {
            now = Date(timeIntervalSince1970: 1_001.001)
            return service.buildMyQRString(nickname: "Synthetic signing boundary", npub: nil) ?? ""
        }, currentDate: { now })
        let parsed = try #require(service.verifyScannedQR(refreshed.payload, now: now.timeIntervalSince1970))
        #expect(parsed.ts == 1_001)
        let displayed = try #require(refreshed.clock)
        #expect(!displayed.isExpired(at: refreshed.sampledAt))
        #expect(displayed.remainingMinutes(at: refreshed.sampledAt) == 5)
    }

    @Test
    func backwardClockCannotReuseAFutureCachedCodeThatTheScannerRefuses() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let service = service(currentDate: { now })
        let original = try #require(service.buildMyQRString(nickname: "Synthetic rollback QR", npub: nil))
        #expect(service.verifyScannedQR(original, now: now.timeIntervalSince1970) != nil)
        now -= 601
        #expect(service.verifyScannedQR(original, now: now.timeIntervalSince1970) == nil)

        let renewed = try #require(service.buildMyQRString(nickname: "Synthetic rollback QR", npub: nil))

        #expect(renewed != original)
        #expect(service.verifyScannedQR(renewed, now: now.timeIntervalSince1970) != nil)
    }

    @Test
    func backwardDisplayClockMustExpireInsteadOfExtendingTheCountdown() {
        let issued = Date(timeIntervalSince1970: 1_000)
        let clock = PaveQRRefreshClock(issuedAt: issued)

        #expect(clock.isExpired(at: issued - 1))
        #expect(clock.remainingMinutes(at: issued - 1) <= 5)
    }

    @Test
    func unknownPayloadCannotAcquireAFreshDisplayLifetime() {
        let now = Date(timeIntervalSince1970: 1_000)

        #expect(PaveQRRefreshClock.forDisplayedPayload("Synthetic invalid QR", at: now) == nil)
        #expect(PaveQRRefreshClock.forDisplayedPayload("", at: now) == nil)
    }

    @Test
    func backwardClockCannotRetainThePeerResponseIndicator() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let context = ClockVerificationContext()
        let coordinator = ChatVerificationCoordinator(context: context, qrTrust: WeshQRTrust(), now: { now })
        let opened = now
        now += 5
        try receiveChallenge(coordinator, context: context)
        #expect(coordinator.scannedMyCode(noiseKey: context.peerKey, since: opened))
        #expect(context.responseCount == 1)
        now -= 1

        #expect(!coordinator.scannedMyCode(noiseKey: context.peerKey, since: opened))
        #expect(context.verifiedFingerprints.isEmpty)
        #expect(context.verificationWrites == 0)
    }

    @Test
    func ordinaryCacheStillReusesBeforeSixtySecondsAndRenewsAtTheBoundary() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let service = service(currentDate: { now })
        let original = try #require(service.buildMyQRString(nickname: "Synthetic normal cache", npub: nil))
        now += 59
        #expect(service.buildMyQRString(nickname: "Synthetic normal cache", npub: nil) == original)
        now += 1
        let renewed = try #require(service.buildMyQRString(nickname: "Synthetic normal cache", npub: nil))
        let parsed = try #require(service.verifyScannedQR(renewed, now: now.timeIntervalSince1970))
        #expect(renewed != original)
        #expect(parsed.ts == 1_060)
        #expect(parsed.nonceB64.count == 22)
    }

    @Test
    func signedScannerFreshnessRemainsSymmetricAtFiveMinutes() throws {
        let issued = Date(timeIntervalSince1970: 1_000)
        let service = service(currentDate: { issued })
        let payload = try #require(service.buildMyQRString(nickname: "Synthetic freshness", npub: nil))
        for offset in [-301, -300, 0, 300, 301] {
            #expect((service.verifyScannedQR(payload, now: issued.timeIntervalSince1970 + Double(offset)) != nil)
                == (abs(offset) <= 300))
        }
    }

    @Test
    func freshDisplayKeepsItsExistingFiveMinuteBoundary() throws {
        let issued = Date(timeIntervalSince1970: 1_000)
        let service = service(currentDate: { issued })
        let payload = try #require(service.buildMyQRString(nickname: "Synthetic displayed boundary", npub: nil))
        let clock = try #require(PaveQRRefreshClock.forDisplayedPayload(payload, at: issued))
        #expect(clock.remainingMinutes(at: issued) == 5)
        #expect(clock.remainingMinutes(at: issued + 299) == 1)
        #expect(!clock.isExpired(at: issued + 299))
        #expect(clock.isExpired(at: issued + 300))
    }

    @Test
    func peerResponseIndicatorRemainsBoundToTheProvenKeyAndFreshWindow() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let context = ClockVerificationContext()
        let coordinator = ChatVerificationCoordinator(context: context, qrTrust: WeshQRTrust(), now: { now })
        let opened = now
        now += 5
        try receiveChallenge(coordinator, context: context)
        #expect(coordinator.scannedMyCode(noiseKey: context.peerKey, since: opened))
        #expect(!coordinator.scannedMyCode(noiseKey: Data(repeating: 0x43, count: 32), since: opened))
        #expect(!coordinator.scannedMyCode(noiseKey: context.peerKey, since: now + 1))
        now += ChatVerificationCoordinator.scannedMyCodeLifetime
        #expect(coordinator.scannedMyCode(noiseKey: context.peerKey, since: opened))
        now += 1
        #expect(!coordinator.scannedMyCode(noiseKey: context.peerKey, since: opened))
        #expect(context.verificationWrites == 0)
    }

    @Test
    func cachedPayloadStillBelongsToItsSigningAndNoiseIdentity() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let first = service(currentDate: { now })
        let second = service(currentDate: { now })
        let original = try #require(first.buildMyQRString(nickname: "Synthetic identity cache", npub: nil))
        let replacement = try #require(second.buildMyQRString(nickname: "Synthetic identity cache", npub: nil))
        let a = try #require(first.verifyScannedQR(original, now: now.timeIntervalSince1970))
        let b = try #require(second.verifyScannedQR(replacement, now: now.timeIntervalSince1970))
        #expect(a.noiseKeyHex != b.noiseKeyHex)
        #expect(a.signKeyHex != b.signKeyHex)
    }

    private func service(currentDate: @escaping () -> Date) -> VerificationService {
        let service = VerificationService(currentDate: currentDate)
        service.configure(with: MockTransport())
        return service
    }

    private func receiveChallenge(_ coordinator: ChatVerificationCoordinator, context: ClockVerificationContext) throws {
        let service = VerificationService()
        let encoded = service.buildVerifyChallenge(noiseKeyHex: context.myKey.hexEncodedString(),
                                                   nonceA: Data(repeating: 0x07, count: 16))
        let payload = try #require(NoisePayload.decode(encoded))
        coordinator.handleVerifyChallengePayload(from: context.peerID, payload: payload.data)
    }
}

/// The coordinator's dependency is entirely RAM and records only synthetic events.
@MainActor
private final class ClockVerificationContext: ChatVerificationContext {
    let myKey = Data(repeating: 0x42, count: 32)
    let peerKey = Data(repeating: 0x44, count: 32)
    let peerID = PeerID(str: "1122334455667788")
    var verifiedFingerprints: Set<String> = []
    private(set) var verificationWrites = 0
    private(set) var responseCount = 0
    var unifiedPeers: [BitchatPeer] { [] }
    var unifiedFavorites: [BitchatPeer] { [] }
    var locallyOwnedNpubs: Set<String>? { [] }
    func getFingerprint(for peerID: PeerID) -> String? { nil }
    func persistedVerifiedFingerprints() -> Set<String> { [] }
    func setIdentityVerified(fingerprint: String, verified: Bool) { verificationWrites += 1 }
    func setStoredVerified(_ fingerprint: String, verified: Bool) { verificationWrites += 1 }
    func isVerifiedFingerprint(_ fingerprint: String) -> Bool { false }
    func saveIdentityState() { verificationWrites += 1 }
    func vouchToConnectedVerifiedPeers() {}
    func setEncryptionStatus(_ status: EncryptionStatus?, for peerID: PeerID) {}
    func updateEncryptionStatus(for peerID: PeerID) {}
    func invalidateEncryptionCache(for peerID: PeerID?) {}
    func notifyUIChanged() {}
    func unifiedPeer(for peerID: PeerID) -> BitchatPeer? { nil }
    func unifiedFingerprint(for peerID: PeerID) -> String? { nil }
    func resolveNickname(for peerID: PeerID) -> String { "Synthetic peer" }
    func cachedStablePeerID(for shortPeerID: PeerID) -> PeerID? { nil }
    func cacheStablePeerID(_ stablePeerID: PeerID, for shortPeerID: PeerID) {}
    func installNoiseSessionCallbacks(
        onPeerAuthenticated: @escaping (PeerID, String) -> Void,
        onHandshakeRequired: @escaping (PeerID) -> Void
    ) {}
    func noiseSessionPublicKeyData(for peerID: PeerID) -> Data? { peerID == self.peerID ? peerKey : nil }
    func noiseStaticPublicKeyData() -> Data { myKey }
    func hasEstablishedNoiseSession(with peerID: PeerID) -> Bool { true }
    func triggerHandshake(with peerID: PeerID) {}
    func retrySecurePrivateMessagesAfterAuthentication(for peerIDAliases: [PeerID]) {}
    func sendVerifyChallenge(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {}
    func sendVerifyResponse(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) { responseCount += 1 }
    func postLocalNotification(title: String, body: String, identifier: String) {}
}
