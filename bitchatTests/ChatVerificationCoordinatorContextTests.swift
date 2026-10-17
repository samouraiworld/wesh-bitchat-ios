//
// ChatVerificationCoordinatorContextTests.swift
// bitchatTests
//
// Exercises `ChatVerificationCoordinator` against a mock
// `ChatVerificationContext` — proving the coordinator works without a
// `ChatViewModel`, following the `ChatDeliveryCoordinatorContextTests` /
// `ChatPrivateConversationCoordinatorContextTests` exemplars.
//
// Scope note: `handleVerifyResponsePayload` requires a real Ed25519
// signature; it remains covered by the full view-model/integration tests.
// Challenge handling, QR kickoff, fingerprint verification, verified-set
// loading, and the mutual-verification notification (posted through the
// injected context) are covered here (`VerificationService.shared` is only
// used for pure payload build/parse).
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

// MARK: - Mock Context

/// Lightweight stand-in for `ChatVerificationContext` proving that
/// `ChatVerificationCoordinator` is testable without a `ChatViewModel`.
@MainActor
private final class MockChatVerificationContext: ChatVerificationContext {
    private(set) var announcedInternetKeys: [PeerID] = []
    func announceWeshInternetKey(to peerID: PeerID) { announcedInternetKeys.append(peerID) }
    // Fingerprints & verification state
    var isIdentityStateAvailable = true
    var hasPendingIdentityStateChanges = false
    var fingerprintsByPeerID: [PeerID: String] = [:]
    var verifiedFingerprints: Set<String> = []
    var persistedFingerprints: Set<String> = []
    private(set) var identityVerifiedCalls: [(fingerprint: String, verified: Bool)] = []
    private(set) var storedVerifiedCalls: [(fingerprint: String, verified: Bool)] = []
    private(set) var saveIdentityStateCount = 0

    func getFingerprint(for peerID: PeerID) -> String? { fingerprintsByPeerID[peerID] }
    func persistedVerifiedFingerprints() -> Set<String> { persistedFingerprints }

    func setIdentityVerified(fingerprint: String, verified: Bool) {
        identityVerifiedCalls.append((fingerprint, verified))
    }

    func setStoredVerified(_ fingerprint: String, verified: Bool) {
        storedVerifiedCalls.append((fingerprint, verified))
    }

    func isVerifiedFingerprint(_ fingerprint: String) -> Bool {
        verifiedFingerprints.contains(fingerprint)
    }

    func saveIdentityState() { saveIdentityStateCount += 1 }

    private(set) var vouchToConnectedVerifiedPeersCount = 0
    func vouchToConnectedVerifiedPeers() { vouchToConnectedVerifiedPeersCount += 1 }

    // Encryption status
    private(set) var encryptionStatuses: [PeerID: EncryptionStatus?] = [:]
    private(set) var updatedEncryptionStatusPeers: [PeerID] = []
    private(set) var invalidatedEncryptionCachePeers: [PeerID?] = []
    private(set) var notifyUIChangedCount = 0

    func setEncryptionStatus(_ status: EncryptionStatus?, for peerID: PeerID) {
        encryptionStatuses[peerID] = status
    }

    func updateEncryptionStatus(for peerID: PeerID) {
        updatedEncryptionStatusPeers.append(peerID)
    }

    func invalidateEncryptionCache(for peerID: PeerID?) {
        invalidatedEncryptionCachePeers.append(peerID)
    }

    func notifyUIChanged() { notifyUIChangedCount += 1 }

    // Peers
    var unifiedPeers: [BitchatPeer] = []
    var unifiedFavorites: [BitchatPeer] = []
    private(set) var stablePeerIDCache: [PeerID: PeerID] = [:]

    func unifiedPeer(for peerID: PeerID) -> BitchatPeer? {
        unifiedPeers.first { $0.peerID == peerID }
    }

    func unifiedFingerprint(for peerID: PeerID) -> String? { fingerprintsByPeerID[peerID] }
    func resolveNickname(for peerID: PeerID) -> String { "anon\(peerID.id.prefix(4))" }
    func cachedStablePeerID(for shortPeerID: PeerID) -> PeerID? { stablePeerIDCache[shortPeerID] }

    func cacheStablePeerID(_ stablePeerID: PeerID, for shortPeerID: PeerID) {
        stablePeerIDCache[shortPeerID] = stablePeerID
    }

    // Noise sessions & verification transport
    var myNoiseStaticKey = Data(repeating: 0x42, count: 32)
    var locallyOwnedNpubs: Set<String>? = []
    var establishedNoiseSessions: Set<PeerID> = []
    var noiseSessionKeysByPeerID: [PeerID: Data] = [:]
    private(set) var installedCallbacks: (onPeerAuthenticated: (PeerID, String) -> Void, onHandshakeRequired: (PeerID) -> Void)?
    private(set) var triggeredHandshakes: [PeerID] = []
    private(set) var securePrivateMessageRetryAliases: [[PeerID]] = []
    private(set) var sentChallenges: [(peerID: PeerID, noiseKeyHex: String, nonceA: Data)] = []
    private(set) var sentResponses: [(peerID: PeerID, noiseKeyHex: String, nonceA: Data)] = []

    func installNoiseSessionCallbacks(
        onPeerAuthenticated: @escaping (PeerID, String) -> Void,
        onHandshakeRequired: @escaping (PeerID) -> Void
    ) {
        installedCallbacks = (onPeerAuthenticated, onHandshakeRequired)
    }

    func noiseSessionPublicKeyData(for peerID: PeerID) -> Data? { noiseSessionKeysByPeerID[peerID] }
    func noiseStaticPublicKeyData() -> Data { myNoiseStaticKey }
    func hasEstablishedNoiseSession(with peerID: PeerID) -> Bool {
        establishedNoiseSessions.contains(peerID)
    }
    func triggerHandshake(with peerID: PeerID) { triggeredHandshakes.append(peerID) }

    func retrySecurePrivateMessagesAfterAuthentication(for peerIDAliases: [PeerID]) {
        securePrivateMessageRetryAliases.append(peerIDAliases)
    }

    func sendVerifyChallenge(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {
        sentChallenges.append((peerID, noiseKeyHex, nonceA))
    }

    func sendVerifyResponse(to peerID: PeerID, noiseKeyHex: String, nonceA: Data) {
        sentResponses.append((peerID, noiseKeyHex, nonceA))
    }

    // Notifications
    private(set) var postedLocalNotifications: [(title: String, body: String, identifier: String)] = []

    func postLocalNotification(title: String, body: String, identifier: String) {
        postedLocalNotifications.append((title, body, identifier))
    }
}

// MARK: - Helpers

/// Builds the raw verify-challenge TLV as it arrives at the coordinator
/// (i.e. with the `NoisePayload` type byte already stripped).
private func makeVerifyChallengeTLV(noiseKeyHex: String, nonceA: Data) -> Data {
    var tlv = Data()
    tlv.append(0x01)
    tlv.append(UInt8(noiseKeyHex.count))
    tlv.append(Data(noiseKeyHex.utf8))
    tlv.append(0x02)
    tlv.append(UInt8(nonceA.count))
    tlv.append(nonceA)
    return tlv
}

private func makeVerificationQR(noiseKeyHex: String) -> VerificationService.VerificationQR {
    VerificationService.VerificationQR(
        v: 1,
        noiseKeyHex: noiseKeyHex,
        signKeyHex: "00" + String(repeating: "ab", count: 31),
        npub: nil,
        nickname: "alice",
        ts: 0,
        nonceB64: "",
        sigHex: ""
    )
}

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `ChatVerificationCoordinator` against
/// `MockChatVerificationContext` with no `ChatViewModel`.
@Suite(.serialized)
struct ChatVerificationCoordinatorContextTests {
    @Test @MainActor
    func unavailableLocalNoiseRefusesQRChallengeAndHandshake() {
        let context = MockChatVerificationContext()
        context.myNoiseStaticKey = Data()
        let peerID = PeerID(str: "1122334455667788")
        let key = Data(repeating: 0x73, count: 32)
        context.unifiedPeers = [BitchatPeer(peerID: peerID, noisePublicKey: key, nickname: "Synthetic")]
        let coordinator = ChatVerificationCoordinator(context: context, weshMode: true)
        #expect(!coordinator.beginQRVerification(with: makeVerificationQR(noiseKeyHex: key.hexEncodedString())))
        #expect(context.triggeredHandshakes.isEmpty)
        #expect(context.sentChallenges.isEmpty)
    }


    @Test @MainActor
    func unavailableIdentityStateRefusesManualVerificationAndQRStart() {
        let context = MockChatVerificationContext()
        context.isIdentityStateAvailable = false
        let peerID = PeerID(str: "1122334455667788")
        let key = Data(repeating: 0x73, count: 32)
        context.fingerprintsByPeerID[peerID] = key.sha256Fingerprint()
        context.unifiedPeers = [BitchatPeer(peerID: peerID, noisePublicKey: key, nickname: "Test")]
        let coordinator = ChatVerificationCoordinator(context: context, weshMode: true)
        coordinator.verifyFingerprint(for: peerID)
        coordinator.unverifyFingerprint(for: peerID)
        let qr = VerificationService.VerificationQR(v: 1, noiseKeyHex: key.hexEncodedString(),
            signKeyHex: String(repeating: "74", count: 32), npub: nil,
            nickname: "Test", ts: 0, nonceB64: "", sigHex: "")
        #expect(!coordinator.beginQRVerification(with: qr))
        #expect(coordinator.qrProgress(for: key) == .unavailable)
        #expect(context.identityVerifiedCalls.isEmpty)
        #expect(context.storedVerifiedCalls.isEmpty)
        #expect(context.triggeredHandshakes.isEmpty)
        #expect(context.sentChallenges.isEmpty)
    }

    @Test @MainActor
    func unconfirmedManualVerificationDoesNotPromoteTrustOrVouch() {
        let context = MockChatVerificationContext()
        context.hasPendingIdentityStateChanges = true
        let peerID = PeerID(str: "1122334455667788")
        context.fingerprintsByPeerID[peerID] = "synthetic-fingerprint"
        let coordinator = ChatVerificationCoordinator(context: context)
        coordinator.verifyFingerprint(for: peerID)
        #expect(context.identityVerifiedCalls.count == 1)
        #expect(context.storedVerifiedCalls.isEmpty)
        #expect(context.updatedEncryptionStatusPeers.isEmpty)
        #expect(context.vouchToConnectedVerifiedPeersCount == 0)
    }

    @Test @MainActor
    func qrNpubIsBoundToTheNoiseKeyOnlyAfterTheChallenge() throws {
        let previousContacts = WeshQRTrust.shared.contacts
        defer { restoreQRContacts(previousContacts) }
        WeshQRTrust.shared.clear()
        let transport = MockTransport()
        VerificationService.shared.configure(with: transport)
        let key = transport.noiseStaticPublicKeyData()
        let peerID = PeerID(str: "1122334455667788")
        let context = MockChatVerificationContext()
        let mine = try NostrIdentity.generate().npub
        context.locallyOwnedNpubs = [mine]
        context.unifiedPeers = [BitchatPeer(peerID: peerID, noisePublicKey: key, nickname: "Nora")]
        context.establishedNoiseSessions = [peerID]
        context.noiseSessionKeysByPeerID[peerID] = key
        context.fingerprintsByPeerID[peerID] = key.sha256Fingerprint()
        // The mock does not persist the verified flag the coordinator sets.
        context.verifiedFingerprints.insert(key.sha256Fingerprint())
        let coordinator = ChatVerificationCoordinator(context: context, weshMode: true)
        func enroll(npub: String?, prover: NostrIdentity? = nil) throws {
            var qr = VerificationService.VerificationQR(v: 1, noiseKeyHex: key.hexEncodedString(),
                signKeyHex: transport.noiseSigningPublicKeyData().hexEncodedString(), npub: npub,
                nickname: "Nora", ts: 0, nonceB64: "", sigHex: "")
            if let prover {
                qr.npubSigHex = try #require(WeshQRNpub.signProof(canonicalBytes: qr.canonicalBytes(), identity: prover)).hexEncodedString()
            }
            let before = WeshQRTrust.shared.contacts.first?.npub
            #expect(coordinator.beginQRVerification(with: qr))
            let nonce = try #require(coordinator.qrAttemptNonce(for: key))
            // Scanning alone binds nothing: the Noise challenge must answer first.
            #expect(WeshQRTrust.shared.contacts.first?.npub == before)
            let encoded = try #require(VerificationService.shared.buildVerifyResponse(noiseKeyHex: qr.noiseKeyHex, nonceA: nonce))
            coordinator.handleVerifyResponsePayload(from: peerID, payload: try #require(NoisePayload.decode(encoded)).data)
            #expect(coordinator.qrProgress(for: key, attemptNonce: nonce) == .verified)
        }

        let theirs = try NostrIdentity.generate()
        try enroll(npub: theirs.npub)
        #expect(WeshQRTrust.shared.contacts.map(\.npub) == [theirs.npub])
        #expect(WeshQRTrust.shared.contacts.first?.isNpubProven == false)
        #expect(WeshQRTrust.shared.contacts.first?.noiseKeyHex == key.hexEncodedString())

        // The proof travels from the scan to the enrollment.
        try enroll(npub: theirs.npub, prover: theirs)
        #expect(WeshQRTrust.shared.contacts.first?.isNpubProven == true)
        // A proof by another key cannot downgrade the proven binding: kept, with a warning.
        try enroll(npub: theirs.npub, prover: try NostrIdentity.generate())
        #expect(WeshQRTrust.shared.contacts.first?.isNpubProven == true)
        #expect(WeshQRTrust.shared.contacts.first?.hasNpubProofWarning == true)

        // From a Bluetooth-only start, each refusal leaves the contact Bluetooth-only.
        WeshQRTrust.shared.clear()
        context.locallyOwnedNpubs = nil
        try enroll(npub: theirs.npub)
        #expect(WeshQRTrust.shared.contacts.first?.npub == nil, "unknown own npubs fail closed")
        context.locallyOwnedNpubs = [mine]
        try enroll(npub: mine)
        #expect(WeshQRTrust.shared.contacts.count == 1)
        #expect(WeshQRTrust.shared.contacts.first?.npub == nil)
        #expect(WeshQRTrust.shared.contacts.first?.requiresRescanForInternet == true)
        try enroll(npub: "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqzsfj2hcx")
        #expect(WeshQRTrust.shared.contacts.first?.npub == nil)
        try enroll(npub: theirs.npub, prover: try NostrIdentity.generate())
        #expect(WeshQRTrust.shared.contacts.first?.npub == nil, "a present proof must verify")
        #expect(WeshQRTrust.shared.fingerprints.contains(key.sha256Fingerprint()))
    }

    @Test @MainActor
    func unconfirmedQRWriteRetainsAttemptWithoutEnrollmentAndCanRetry() throws {
        let previousContacts = WeshQRTrust.shared.contacts
        defer { restoreQRContacts(previousContacts) }
        WeshQRTrust.shared.clear()
        let transport = MockTransport()
        VerificationService.shared.configure(with: transport)
        let key = transport.noiseStaticPublicKeyData()
        let peerID = PeerID(str: "1122334455667788")
        let context = MockChatVerificationContext()
        context.hasPendingIdentityStateChanges = true
        context.unifiedPeers = [BitchatPeer(peerID: peerID, noisePublicKey: key, nickname: "Test")]
        context.establishedNoiseSessions = [peerID]
        context.noiseSessionKeysByPeerID[peerID] = key
        context.fingerprintsByPeerID[peerID] = key.sha256Fingerprint()
        let coordinator = ChatVerificationCoordinator(context: context, weshMode: true)
        let qr = VerificationService.VerificationQR(v: 1, noiseKeyHex: key.hexEncodedString(),
            signKeyHex: transport.noiseSigningPublicKeyData().hexEncodedString(), npub: nil,
            nickname: "Test", ts: 0, nonceB64: "", sigHex: "")
        #expect(coordinator.beginQRVerification(with: qr))
        let nonce = try #require(context.sentChallenges.first?.nonceA)
        let encoded = try #require(VerificationService.shared.buildVerifyResponse(noiseKeyHex: qr.noiseKeyHex, nonceA: nonce))
        let response = try #require(NoisePayload.decode(encoded))
        coordinator.handleVerifyResponsePayload(from: peerID, payload: response.data)
        #expect(context.storedVerifiedCalls.isEmpty)
        #expect(context.postedLocalNotifications.isEmpty)
        #expect(WeshQRTrust.shared.contacts.isEmpty)
        #expect(coordinator.qrProgress(for: key, attemptNonce: nonce) == .pending)

        context.hasPendingIdentityStateChanges = false
        coordinator.handleVerifyResponsePayload(from: peerID, payload: response.data)
        #expect(context.storedVerifiedCalls.map(\.verified) == [true])
        #expect(WeshQRTrust.shared.fingerprints.contains(key.sha256Fingerprint()))
        #expect(context.postedLocalNotifications.filter { $0.title == "Contact verified" }.count == 1)
        #expect(context.sentChallenges.count == 1)
    }

    @Test @MainActor
    func scanCompletingAfterTheContactStoreUnlocksKeepsExistingReviewFlags() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wesh-qr-locked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = MockKeychain()
        func store() -> WeshSealedStore {
            WeshSealedStore(keychain: keychain, fileURL: root.appendingPathComponent("contacts.enc"),
                            keyName: "contacts.test", context: "wesh.contacts.test")
        }
        let transport = MockTransport()
        VerificationService.shared.configure(with: transport)
        let key = transport.noiseStaticPublicKeyData()
        #expect(WeshQRTrust(storage: store()).record(sessionKey: key, nickname: "Test", npubConflict: true))

        // The list was unreadable when this owner loaded it, then the phone unlocks.
        keychain.simulatedReadError = .deviceLocked
        let trust = WeshQRTrust(storage: store())
        #expect(trust.storageState == .unavailable && trust.contacts.isEmpty)
        let peerID = PeerID(str: "1122334455667788")
        let context = MockChatVerificationContext()
        context.unifiedPeers = [BitchatPeer(peerID: peerID, noisePublicKey: key, nickname: "Test")]
        context.establishedNoiseSessions = [peerID]
        context.noiseSessionKeysByPeerID[peerID] = key
        context.fingerprintsByPeerID[peerID] = key.sha256Fingerprint()
        let coordinator = ChatVerificationCoordinator(context: context, weshMode: true, qrTrust: trust)
        let qr = VerificationService.VerificationQR(v: 1, noiseKeyHex: key.hexEncodedString(),
            signKeyHex: transport.noiseSigningPublicKeyData().hexEncodedString(), npub: nil,
            nickname: "Test", ts: 0, nonceB64: "", sigHex: "")
        func respond(to nonce: Data) throws {
            let encoded = try #require(VerificationService.shared.buildVerifyResponse(noiseKeyHex: qr.noiseKeyHex, nonceA: nonce))
            coordinator.handleVerifyResponsePayload(from: peerID, payload: try #require(NoisePayload.decode(encoded)).data)
        }

        // Still locked: no enrollment from an empty list.
        #expect(coordinator.beginQRVerification(with: qr))
        let lockedNonce = try #require(context.sentChallenges.last?.nonceA)
        try respond(to: lockedNonce)
        #expect(coordinator.qrProgress(for: key, attemptNonce: lockedNonce) == .notSaved)
        #expect(!context.postedLocalNotifications.contains { $0.identifier.hasPrefix("verify-success") })

        keychain.simulatedReadError = nil
        #expect(coordinator.beginQRVerification(with: qr))
        try respond(to: try #require(context.sentChallenges.last?.nonceA))
        #expect(trust.contacts.first?.hasNpubConflict == true)
        #expect(context.postedLocalNotifications.filter { $0.identifier.hasPrefix("verify-success") }.count == 1)
    }

    @Test @MainActor
    func unconfirmedContactWriteReportsNotSavedWithoutSuccessAndRescanEnrolls() throws {
        var failWrites = true
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wesh-qr-unsaved-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = ComposerDraftPersistence.FileAccess.live
        let files = ComposerDraftPersistence.FileAccess(read: live.read, write: { data, url in
            if failWrites { throw CocoaError(.fileWriteNoPermission) }
            try live.write(data, url)
        }, remove: live.remove)
        let trust = WeshQRTrust(storage: WeshSealedStore(keychain: MockKeychain(),
            fileURL: root.appendingPathComponent("contacts.enc"), keyName: "contacts.test",
            context: "wesh.contacts.test", files: files))
        let transport = MockTransport()
        VerificationService.shared.configure(with: transport)
        let key = transport.noiseStaticPublicKeyData()
        let peerID = PeerID(str: "1122334455667788")
        let context = MockChatVerificationContext()
        context.unifiedPeers = [BitchatPeer(peerID: peerID, noisePublicKey: key, nickname: "Test")]
        context.establishedNoiseSessions = [peerID]
        context.noiseSessionKeysByPeerID[peerID] = key
        context.fingerprintsByPeerID[peerID] = key.sha256Fingerprint()
        let coordinator = ChatVerificationCoordinator(context: context, weshMode: true, qrTrust: trust)
        let qr = VerificationService.VerificationQR(v: 1, noiseKeyHex: key.hexEncodedString(),
            signKeyHex: transport.noiseSigningPublicKeyData().hexEncodedString(), npub: nil,
            nickname: "Test", ts: 0, nonceB64: "", sigHex: "")
        func respond(to nonce: Data) throws {
            let encoded = try #require(VerificationService.shared.buildVerifyResponse(noiseKeyHex: qr.noiseKeyHex, nonceA: nonce))
            coordinator.handleVerifyResponsePayload(from: peerID, payload: try #require(NoisePayload.decode(encoded)).data)
        }

        #expect(coordinator.beginQRVerification(with: qr))
        let nonce = try #require(context.sentChallenges.last?.nonceA)
        try respond(to: nonce)
        #expect(trust.contacts.isEmpty)
        #expect(context.storedVerifiedCalls.isEmpty)
        #expect(!context.postedLocalNotifications.contains { $0.identifier.hasPrefix("verify-success") })
        #expect(coordinator.qrProgress(for: key, attemptNonce: nonce) == .notSaved)
        #expect(coordinator.qrAttemptNonce(for: key) == nonce)
        // A contact that was not saved is never told my npub.
        #expect(context.announcedInternetKeys.isEmpty)

        // Rescanning the same QR starts a fresh challenge instead of reusing the failed one.
        failWrites = false
        #expect(coordinator.beginQRVerification(with: qr))
        #expect(context.sentChallenges.count == 2)
        let retryNonce = try #require(context.sentChallenges.last?.nonceA)
        #expect(retryNonce != nonce)
        try respond(to: retryNonce)
        #expect(trust.fingerprints.contains(key.sha256Fingerprint()))
        #expect(context.storedVerifiedCalls.map(\.verified) == [true])
        #expect(context.postedLocalNotifications.filter { $0.identifier.hasPrefix("verify-success") }.count == 1)
        #expect(context.announcedInternetKeys == [peerID])
        context.verifiedFingerprints.insert(key.sha256Fingerprint())
        #expect(coordinator.qrProgress(for: key, attemptNonce: retryNonce) == .verified)
    }

    @Test @MainActor
    func verifyAndUnverifyFingerprint_updateBothStoresAndStatus() async {
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")

        // Unknown fingerprint: nothing happens.
        coordinator.verifyFingerprint(for: peerID)
        #expect(context.identityVerifiedCalls.isEmpty)

        context.fingerprintsByPeerID[peerID] = "fp"
        coordinator.verifyFingerprint(for: peerID)
        coordinator.unverifyFingerprint(for: peerID)

        #expect(context.identityVerifiedCalls.map(\.fingerprint) == ["fp", "fp"])
        #expect(context.identityVerifiedCalls.map(\.verified) == [true, false])
        #expect(context.storedVerifiedCalls.map(\.verified) == [true, false])
        #expect(context.saveIdentityStateCount == 2)
        #expect(context.updatedEncryptionStatusPeers == [peerID, peerID])
    }

    @Test @MainActor
    func signedQRResponseMustMatchActualSessionAndSuppressesMutualClaims() throws {
        let previousContacts = WeshQRTrust.shared.contacts
        defer { restoreQRContacts(previousContacts) }
        WeshQRTrust.shared.clear()
        let transport = MockTransport()
        VerificationService.shared.configure(with: transport)
        let key = transport.noiseStaticPublicKeyData()
        let peerID = PeerID(str: "1122334455667788")
        let qr = VerificationService.VerificationQR(v: 1, noiseKeyHex: key.hexEncodedString(),
            signKeyHex: transport.noiseSigningPublicKeyData().hexEncodedString(), npub: nil,
            nickname: "Nora", ts: 0, nonceB64: "", sigHex: "")
        for matching in [false, true] {
            let context = MockChatVerificationContext()
            context.unifiedPeers = [BitchatPeer(peerID: peerID, noisePublicKey: key, nickname: "Nora")]
            context.establishedNoiseSessions = [peerID]
            context.noiseSessionKeysByPeerID[peerID] = key
            context.fingerprintsByPeerID[peerID] = key.sha256Fingerprint()
            let coordinator = ChatVerificationCoordinator(context: context, weshMode: true)
            #expect(coordinator.beginQRVerification(with: qr))
            let nonce = try #require(context.sentChallenges.first?.nonceA)
            if !matching { context.noiseSessionKeysByPeerID[peerID] = Data(repeating: 2, count: 32) }
            let encoded = try #require(VerificationService.shared.buildVerifyResponse(noiseKeyHex: qr.noiseKeyHex, nonceA: nonce))
            let response = try #require(NoisePayload.decode(encoded))
            coordinator.handleVerifyResponsePayload(from: peerID, payload: response.data)
            #expect(context.identityVerifiedCalls.count == (matching ? 1 : 0))
            #expect(context.vouchToConnectedVerifiedPeersCount == 0)
            #expect(!context.postedLocalNotifications.contains { $0.title == "Mutual verification" })
            coordinator.handleVerifyResponsePayload(from: peerID, payload: response.data)
            #expect(context.identityVerifiedCalls.count == (matching ? 1 : 0))
        }
    }

    @Test @MainActor
    func cancelledContactCannotReturnFromDelayedSignedResponse() throws {
        let previousContacts = WeshQRTrust.shared.contacts
        defer { restoreQRContacts(previousContacts) }
        WeshQRTrust.shared.clear()
        let transport = MockTransport()
        VerificationService.shared.configure(with: transport)
        let firstKey = transport.noiseStaticPublicKeyData()
        let secondKey = Data(repeating: 23, count: 32)
        let firstPeer = PeerID(str: "1122334455667788")
        let secondPeer = PeerID(str: "8877665544332211")
        let context = MockChatVerificationContext()
        context.unifiedPeers = [BitchatPeer(peerID: firstPeer, noisePublicKey: firstKey, nickname: "Test"),
                                BitchatPeer(peerID: secondPeer, noisePublicKey: secondKey, nickname: "Test")]
        context.establishedNoiseSessions = [firstPeer, secondPeer]
        context.noiseSessionKeysByPeerID = [firstPeer: firstKey, secondPeer: secondKey]
        context.fingerprintsByPeerID = [firstPeer: firstKey.sha256Fingerprint(), secondPeer: secondKey.sha256Fingerprint()]
        let coordinator = ChatVerificationCoordinator(context: context, weshMode: true)
        let firstQR = VerificationService.VerificationQR(v: 1, noiseKeyHex: firstKey.hexEncodedString(),
            signKeyHex: transport.noiseSigningPublicKeyData().hexEncodedString(), npub: nil,
            nickname: "Test", ts: 0, nonceB64: "", sigHex: "")
        #expect(coordinator.beginQRVerification(with: firstQR))
        #expect(coordinator.beginQRVerification(with: makeVerificationQR(noiseKeyHex: secondKey.hexEncodedString())))
        let nonce = try #require(context.sentChallenges.first?.nonceA)
        let encoded = try #require(VerificationService.shared.buildVerifyResponse(noiseKeyHex: firstQR.noiseKeyHex, nonceA: nonce))
        let response = try #require(NoisePayload.decode(encoded))
        coordinator.cancelQRVerification(for: firstKey)
        #expect(coordinator.qrProgress(for: firstKey) == .unavailable)
        #expect(coordinator.qrProgress(for: secondKey) == .pending)
        coordinator.handleVerifyResponsePayload(from: firstPeer, payload: response.data)
        #expect(context.identityVerifiedCalls.isEmpty)
        #expect(WeshQRTrust.shared.contacts.isEmpty)
        coordinator.cancelAllQRVerifications()
        #expect(coordinator.qrProgress(for: secondKey) == .unavailable)
        #expect(coordinator.beginQRVerification(with: firstQR))
        coordinator.handleVerifyResponsePayload(from: firstPeer, payload: response.data)
        #expect(context.identityVerifiedCalls.isEmpty)
        #expect(WeshQRTrust.shared.contacts.isEmpty)
    }

    @Test @MainActor
    func expiredOrChangedSigningIdentityReplacesPendingChallenge() {
        let previousContacts = WeshQRTrust.shared.contacts
        defer { restoreQRContacts(previousContacts) }
        WeshQRTrust.shared.clear()
        let context = MockChatVerificationContext()
        let key = Data(repeating: 1, count: 32)
        let peer = PeerID(str: "1122334455667788")
        context.unifiedPeers = [BitchatPeer(peerID: peer, noisePublicKey: key, nickname: "Nora")]
        context.establishedNoiseSessions = [peer]
        context.noiseSessionKeysByPeerID[peer] = key
        var clock = Date(timeIntervalSince1970: 1700000000)
        let coordinator = ChatVerificationCoordinator(context: context, weshMode: true, now: { clock })
        let original = makeVerificationQR(noiseKeyHex: key.hexEncodedString())
        #expect(coordinator.beginQRVerification(with: original))
        #expect(coordinator.qrProgress(for: key) == .pending)
        let nonce = context.sentChallenges.first?.nonceA
        #expect(coordinator.beginQRVerification(with: original))
        #expect(context.sentChallenges.count == 1)
        clock = clock.addingTimeInterval(60)
        #expect(coordinator.qrProgress(for: key) == .pending)
        clock = clock.addingTimeInterval(1)
        #expect(coordinator.qrProgress(for: key) == .expired)
        #expect(context.identityVerifiedCalls.isEmpty)
        #expect(coordinator.beginQRVerification(with: original))
        #expect(coordinator.qrProgress(for: key) == .pending)
        #expect(context.sentChallenges.count == 2)
        #expect(context.sentChallenges.last?.nonceA != nonce)
        let changed = VerificationService.VerificationQR(v: 1, noiseKeyHex: original.noiseKeyHex,
            signKeyHex: String(repeating: "ff", count: 32), npub: nil, nickname: "Nora", ts: 0, nonceB64: "", sigHex: "")
        #expect(coordinator.beginQRVerification(with: changed))
        #expect(context.sentChallenges.count == 3)
        #expect(coordinator.qrProgress(for: Data(repeating: 3, count: 32)) == .unavailable)
        context.verifiedFingerprints.insert(key.sha256Fingerprint())
        WeshQRTrust.shared.record(sessionKey: key)
        clock = clock.addingTimeInterval(61)
        #expect(coordinator.qrProgress(for: key) == .expired)
    }

    @MainActor private func restoreQRContacts(_ contacts: [WeshQRTrust.Contact]) {
        WeshQRTrust.shared.clear()
        for contact in contacts {
            if let key = Data(hexString: contact.noiseKeyHex) {
                WeshQRTrust.shared.record(sessionKey: key, nickname: contact.nickname, npub: contact.npub,
                                          npubProven: contact.isNpubProven)
            }
        }
        // Hosted tests share the simulator app's preferences. Flush cleanup
        // before XCTest terminates the host so synthetic contacts cannot linger.
        UserDefaults.standard.synchronize()
    }

    @Test @MainActor
    func qrAnnouncementCannotAuthorizeDifferentSession() {
        let context = MockChatVerificationContext()
        let peerID = PeerID(str: "1122334455667788")
        let scanned = Data(repeating: 1, count: 32)
        context.unifiedPeers = [BitchatPeer(peerID: peerID, noisePublicKey: scanned, nickname: "Nora")]
        context.establishedNoiseSessions = [peerID]
        context.noiseSessionKeysByPeerID[peerID] = Data(repeating: 2, count: 32)
        let coordinator = ChatVerificationCoordinator(context: context, weshMode: true)
        #expect(!coordinator.beginQRVerification(with: makeVerificationQR(noiseKeyHex: scanned.hexEncodedString())))
        #expect(context.sentChallenges.isEmpty)
        #expect(context.identityVerifiedCalls.isEmpty)
    }

    @Test @MainActor
    func beginQRVerification_sendsChallengeOrTriggersHandshake() async {
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(context: context)
        let noiseKey = Data(repeating: 0xCD, count: 32)
        let peerID = PeerID(str: "1122334455667788")
        let qr = makeVerificationQR(noiseKeyHex: noiseKey.hexEncodedString())

        // No matching peer -> not started.
        #expect(!coordinator.beginQRVerification(with: qr))

        // Matching peer without an established session -> handshake first.
        context.unifiedPeers = [BitchatPeer(peerID: peerID, noisePublicKey: noiseKey, nickname: "alice")]
        #expect(coordinator.beginQRVerification(with: qr))
        #expect(context.triggeredHandshakes == [peerID])
        #expect(context.sentChallenges.isEmpty)

        // Already pending -> short-circuits without re-triggering.
        #expect(coordinator.beginQRVerification(with: qr))
        #expect(context.triggeredHandshakes == [peerID])

        // Fresh coordinator with an established session -> immediate challenge.
        let context2 = MockChatVerificationContext()
        context2.unifiedPeers = [BitchatPeer(peerID: peerID, noisePublicKey: noiseKey, nickname: "alice")]
        context2.establishedNoiseSessions = [peerID]
        context2.noiseSessionKeysByPeerID[peerID] = noiseKey
        let coordinator2 = ChatVerificationCoordinator(context: context2)
        #expect(coordinator2.beginQRVerification(with: qr))
        #expect(context2.sentChallenges.count == 1)
        #expect(context2.sentChallenges.first?.noiseKeyHex == qr.noiseKeyHex)
        #expect(context2.triggeredHandshakes.isEmpty)
    }

    @Test @MainActor
    func handleVerifyChallengePayload_respondsOncePerNonceForOurKeyOnly() async {
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        let myHex = context.myNoiseStaticKey.hexEncodedString()
        let nonce = Data(repeating: 0x07, count: 16)
        let payload = makeVerifyChallengeTLV(noiseKeyHex: myHex, nonceA: nonce)

        coordinator.handleVerifyChallengePayload(from: peerID, payload: payload)
        #expect(context.sentResponses.count == 1)
        #expect(context.sentResponses.first?.noiseKeyHex.lowercased() == myHex)
        #expect(context.sentResponses.first?.nonceA == nonce)

        // Same nonce again: deduplicated, no second response.
        coordinator.handleVerifyChallengePayload(from: peerID, payload: payload)
        #expect(context.sentResponses.count == 1)

        // A challenge for someone else's key is ignored.
        let otherHex = Data(repeating: 0x99, count: 32).hexEncodedString()
        let otherPayload = makeVerifyChallengeTLV(
            noiseKeyHex: otherHex,
            nonceA: Data(repeating: 0x08, count: 16)
        )
        coordinator.handleVerifyChallengePayload(from: peerID, payload: otherPayload)
        #expect(context.sentResponses.count == 1)
    }

    @Test @MainActor
    func loadVerifiedFingerprints_syncsPersistedSetAndRefreshesUI() async {
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(context: context)
        context.persistedFingerprints = ["fp1", "fp2"]

        coordinator.loadVerifiedFingerprints()

        #expect(context.verifiedFingerprints == ["fp1", "fp2"])
        #expect(context.invalidatedEncryptionCachePeers == [nil])
        #expect(context.notifyUIChangedCount == 1)
    }

    @Test @MainActor
    func installedNoiseCallbacks_publishStatusAndStableIDs() async {
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        let noiseKey = Data(repeating: 0x33, count: 32)
        context.noiseSessionKeysByPeerID[peerID] = noiseKey
        context.cacheStablePeerID(
            PeerID(hexData: Data(repeating: 0x44, count: 32)),
            for: peerID
        )
        context.verifiedFingerprints = ["fp-verified"]

        coordinator.setupNoiseCallbacks()
        let callbacks = context.installedCallbacks

        // Authenticated with a verified fingerprint -> verified status and a
        // cached stable peer ID derived from the session key.
        callbacks?.onPeerAuthenticated(peerID, "fp-verified")
        await waitForMainQueue()
        #expect(context.encryptionStatuses[peerID] == .noiseVerified)
        let stablePeerID = PeerID(hexData: noiseKey)
        #expect(context.stablePeerIDCache[peerID] == stablePeerID)
        #expect(context.invalidatedEncryptionCachePeers.contains(peerID))
        #expect(context.securePrivateMessageRetryAliases == [[peerID, stablePeerID]])

        // Handshake required -> handshaking status.
        callbacks?.onHandshakeRequired(peerID)
        await waitForMainQueue()
        #expect(context.encryptionStatuses[peerID] == .noiseHandshaking)
    }

    @Test @MainActor
    func handleVerifyChallengePayload_postsMutualVerificationToastOncePerMinute() async {
        let context = MockChatVerificationContext()
        let coordinator = ChatVerificationCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        let myHex = context.myNoiseStaticKey.hexEncodedString()
        context.fingerprintsByPeerID[peerID] = "fp-mutual"
        context.verifiedFingerprints = ["fp-mutual"]

        coordinator.handleVerifyChallengePayload(
            from: peerID,
            payload: makeVerifyChallengeTLV(noiseKeyHex: myHex, nonceA: Data(repeating: 0x07, count: 16))
        )

        // Already-verified peer challenging us: mutual-verification toast.
        #expect(context.postedLocalNotifications.count == 1)
        #expect(context.postedLocalNotifications.first?.title == "Mutual verification")
        #expect(context.postedLocalNotifications.first?.body.hasSuffix("verified each other") == true)
        #expect(context.postedLocalNotifications.first?.identifier.hasPrefix("verify-mutual-") == true)

        // A fresh nonce inside the per-fingerprint toast cooldown stays silent.
        coordinator.handleVerifyChallengePayload(
            from: peerID,
            payload: makeVerifyChallengeTLV(noiseKeyHex: myHex, nonceA: Data(repeating: 0x08, count: 16))
        )
        #expect(context.postedLocalNotifications.count == 1)
        #expect(context.sentResponses.count == 2)
    }
    @Test @MainActor
    func rescanCannotBorrowOldTrustAndProgressIsBoundToItsChallenge() throws {
        let previousContacts = WeshQRTrust.shared.contacts
        defer { restoreQRContacts(previousContacts) }
        WeshQRTrust.shared.clear()
        let transport = MockTransport()
        let otherSigner = MockTransport()
        VerificationService.shared.configure(with: transport)
        let key = transport.noiseStaticPublicKeyData()
        let peer = PeerID(str: "1122334455667788")
        let context = MockChatVerificationContext()
        context.unifiedPeers = [BitchatPeer(peerID: peer, noisePublicKey: key, nickname: "Nora")]
        context.establishedNoiseSessions = [peer]
        context.noiseSessionKeysByPeerID[peer] = key
        context.fingerprintsByPeerID[peer] = key.sha256Fingerprint()
        context.verifiedFingerprints.insert(key.sha256Fingerprint())
        WeshQRTrust.shared.record(sessionKey: key, nickname: "Nora")
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = ChatVerificationCoordinator(context: context, weshMode: true, now: { clock })
        func qr(signer: MockTransport, nickname: String, nonce: UInt8) throws -> VerificationService.VerificationQR {
            var payload = VerificationService.VerificationQR(v: 1, noiseKeyHex: key.hexEncodedString(),
                signKeyHex: signer.noiseSigningPublicKeyData().hexEncodedString(), npub: nil,
                nickname: nickname, ts: Int64(clock.timeIntervalSince1970),
                nonceB64: Data(repeating: nonce, count: 16).base64EncodedString().replacingOccurrences(of: "=", with: ""), sigHex: "")
            payload.sigHex = try #require(signer.noiseSignData(payload.canonicalBytes())).hexEncodedString()
            return try #require(VerificationService.shared.verifyScannedQR(payload.toURLString(), now: clock.timeIntervalSince1970))
        }
        func response(_ nonce: Data) throws -> Data {
            let encoded = try #require(VerificationService.shared.buildVerifyResponse(noiseKeyHex: key.hexEncodedString(), nonceA: nonce))
            return try #require(NoisePayload.decode(encoded)).data
        }
        let original = try qr(signer: transport, nickname: "Nora", nonce: 1)
        #expect(coordinator.beginQRVerification(with: original))
        let firstNonce = try #require(coordinator.qrAttemptNonce(for: key))
        let firstResponse = try response(firstNonce)
        #expect(coordinator.qrProgress(for: key, attemptNonce: firstNonce) == .pending)
        coordinator.handleVerifyResponsePayload(from: peer, payload: firstResponse)
        #expect(coordinator.qrProgress(for: key, attemptNonce: firstNonce) == .verified)

        let claimedByOtherSigner = try qr(signer: otherSigner, nickname: "Someone else", nonce: 2)
        #expect(coordinator.beginQRVerification(with: claimedByOtherSigner))
        let secondNonce = try #require(coordinator.qrAttemptNonce(for: key))
        #expect(secondNonce != firstNonce)
        #expect(coordinator.qrProgress(for: key, attemptNonce: secondNonce) == .pending)
        #expect(coordinator.qrProgress(for: key, attemptNonce: firstNonce) == .unavailable)
        coordinator.handleVerifyResponsePayload(from: peer, payload: firstResponse)
        coordinator.handleVerifyResponsePayload(from: peer, payload: try response(secondNonce))
        #expect(coordinator.qrProgress(for: key, attemptNonce: secondNonce) == .pending)
        #expect(WeshQRTrust.shared.contacts.first?.nickname == "Nora")
        clock = clock.addingTimeInterval(61)
        #expect(coordinator.qrProgress(for: key, attemptNonce: secondNonce) == .expired)
        #expect(WeshQRTrust.shared.fingerprints.contains(key.sha256Fingerprint()))

        let renewed = try qr(signer: transport, nickname: "Nora renewed", nonce: 3)
        #expect(coordinator.beginQRVerification(with: renewed))
        let thirdNonce = try #require(coordinator.qrAttemptNonce(for: key))
        #expect(coordinator.beginQRVerification(with: renewed))
        #expect(coordinator.qrAttemptNonce(for: key) == thirdNonce)
        coordinator.handleVerifyResponsePayload(from: peer, payload: try response(thirdNonce))
        #expect(coordinator.qrProgress(for: key, attemptNonce: thirdNonce) == .verified)
        #expect(coordinator.qrProgress(for: key, attemptNonce: secondNonce) == .unavailable)
        #expect(WeshQRTrust.shared.contacts.first?.nickname == "Nora renewed")
        let freshSameSigner = try qr(signer: transport, nickname: "Nora renewed", nonce: 4)
        #expect(coordinator.beginQRVerification(with: freshSameSigner))
        #expect(coordinator.qrAttemptNonce(for: key) != thirdNonce)
        #expect(coordinator.qrProgress(for: key, attemptNonce: thirdNonce) == .unavailable)
        coordinator.cancelQRVerification(for: key)
        #expect(coordinator.qrProgress(for: key) == .unavailable)
    }

}

/// The installed callbacks hop through `DispatchQueue.main.async`; tests must
/// let that queue drain before asserting.
@MainActor
private func waitForMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}
