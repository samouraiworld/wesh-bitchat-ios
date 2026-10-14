import BitFoundation
import CryptoKit
import CoreBluetooth
import Foundation
import Testing
@testable import bitchat

@Suite("Wesh native trust and public separation", .serialized)
struct WeshNativeUITests {
    @Test func timelineUsesCalendarDaysAcrossMidnightAndDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute)))
        }
        let beforeMidnight = try date(28, 23, 59)
        let afterMidnight = try date(29, 0, 1)
        #expect(WeshTimeline.startsDay(at: beforeMidnight, after: nil, calendar: calendar))
        #expect(WeshTimeline.startsDay(at: afterMidnight, after: beforeMidnight, calendar: calendar))
        #expect(!WeshTimeline.startsDay(at: try date(29, 23), after: afterMidnight, calendar: calendar))
        #expect(!WeshTimeline.startsDay(at: try date(29, 3), after: try date(29, 1), calendar: calendar))
    }

    @Test @MainActor func unavailableBluetoothPreservesPublicDraftAndPreventsDispatch() {
        let consentKey = "wesh.publicDisclosureAccepted.v1"
        let previous = UserDefaults.standard.object(forKey: consentKey)
        UserDefaults.standard.set(true, forKey: consentKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: consentKey) }
            else { UserDefaults.standard.removeObject(forKey: consentKey) }
        }
        let keychain = MockKeychain()
        let transport = MockTransport()
        let vm = ChatViewModel(keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain), transport: transport,
            weshPrivatePolicyEnabled: true)
        let unavailableStates: [CBManagerState] = [.unknown, .resetting, .poweredOff, .unauthorized, .unsupported]
        for state in unavailableStates {
            vm.bluetoothState = state
            var draft = "Essai local — brouillon"
            #expect(!vm.canSendWeshPublic)
            #expect(!vm.sendWeshDraft(&draft, to: nil))
            #expect(draft == "Essai local — brouillon")
            #expect(transport.sentMessages.isEmpty)
        }
        vm.bluetoothState = .poweredOn
        var draft = "Essai local — brouillon"
        #expect(vm.canSendWeshPublic)
        #expect(vm.sendWeshDraft(&draft, to: nil))
        #expect(draft.isEmpty)
        #expect(transport.sentMessages.count == 1)
    }
    @Test @MainActor func notificationWaveRequiresDisclosureAndAvailableBluetooth() {
        let consentKey = "wesh.publicDisclosureAccepted.v1"
        let previous = UserDefaults.standard.object(forKey: consentKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: consentKey) }
            else { UserDefaults.standard.removeObject(forKey: consentKey) }
        }
        let keychain = MockKeychain()
        let transport = MockTransport()
        let vm = ChatViewModel(keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain), transport: transport,
            weshPrivatePolicyEnabled: true)

        vm.bluetoothState = .poweredOn
        UserDefaults.standard.set(false, forKey: consentKey)
        vm.sendMeshWave()
        #expect(transport.sentMessages.isEmpty)

        UserDefaults.standard.set(true, forKey: consentKey)
        vm.bluetoothState = .poweredOff
        vm.sendMeshWave()
        #expect(transport.sentMessages.isEmpty)

        vm.bluetoothState = .poweredOn
        vm.sendMeshWave()
        #expect(transport.sentMessages.count == 1)
    }

    @Test @MainActor func sharedDraftRequiresExactCurrentUnblockedEnrollment() {
        let key = Data(repeating: 41, count: 32)
        let otherKey = Data(repeating: 42, count: 32)
        let peer = PeerID(hexData: key)
        let other = PeerID(hexData: otherKey)
        let contacts = [WeshQRTrust.Contact(noiseKeyHex: key.hexEncodedString(), nickname: "Contact test")]
        let enrolled: Set<String> = [key.sha256Fingerprint(), otherKey.sha256Fingerprint()]
        #expect(WeshQRTrust.canPrepareDraft(to: peer, contacts: contacts, qrFingerprints: enrolled, blockedFingerprints: []))
        #expect(!WeshQRTrust.canPrepareDraft(to: peer.toShort(), contacts: contacts, qrFingerprints: enrolled, blockedFingerprints: []))
        #expect(!WeshQRTrust.canPrepareDraft(to: other, contacts: contacts, qrFingerprints: enrolled, blockedFingerprints: []))
        #expect(!WeshQRTrust.canPrepareDraft(to: peer, contacts: [], qrFingerprints: enrolled, blockedFingerprints: []))
        #expect(!WeshQRTrust.canPrepareDraft(to: peer, contacts: contacts, qrFingerprints: [], blockedFingerprints: []))
        #expect(!WeshQRTrust.canPrepareDraft(to: peer, contacts: contacts, qrFingerprints: enrolled, blockedFingerprints: [key.sha256Fingerprint()]))
    }

    private var vector: VerificationService.VerificationQR {
        .init(v: 1, noiseKeyHex: "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a",
              signKeyHex: "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
              npub: nil, nickname: "Nora café", ts: 1700000000, nonceB64: "AAECAwQFBgcICQoLDA0ODw", sigHex: String(repeating: "ab", count: 64))
    }

    @Test func crossPlatformCanonicalVector() {
        #expect(vector.canonicalBytes().count == 196)
        #expect(Data(SHA256.hash(data: vector.canonicalBytes())).hexEncodedString() == "54177f15665e6a07bcad135c1889fb40b2e932e301cb9da2529c672a945d4b3c")
        #expect(VerificationService.VerificationQR.fromURL(URL(string: vector.toURLString())!) != nil)
    }

    @Test func parserRejectsAmbiguousOrMalformedQR() {
        let good = vector.toURLString()
        let invalid = [good + "&v=1", good + "&unknown=1", good + "#fragment",
                       good.replacingOccurrences(of: "v=1", with: "v=2"),
                       good.replacingOccurrences(of: vector.noiseKeyHex, with: "aa"),
                       good.replacingOccurrences(of: vector.signKeyHex, with: String(repeating: "g", count: 64)),
                       good.replacingOccurrences(of: vector.sigHex, with: "ab"),
                       good.replacingOccurrences(of: vector.nonceB64, with: vector.nonceB64 + "=="),
                       good.replacingOccurrences(of: "bitchat://verify", with: "bitchat://verify/extra"),
                       good.replacingOccurrences(of: "bitchat://verify", with: "bitchat://user@verify"),
                       good.replacingOccurrences(of: "bitchat://verify", with: "bitchat://verify:443")]
        for value in invalid { #expect(VerificationService.VerificationQR.fromURL(URL(string: value)!) == nil) }
        let tooLong = VerificationService.VerificationQR(v: 1, noiseKeyHex: vector.noiseKeyHex, signKeyHex: vector.signKeyHex,
            npub: nil, nickname: String(repeating: "é", count: 128), ts: vector.ts, nonceB64: vector.nonceB64, sigHex: vector.sigHex)
        #expect(VerificationService.VerificationQR.fromURL(URL(string: tooLong.toURLString())!) == nil)
    }

    @Test @MainActor func privateSendRequiresQRAndCurrentSession() {
        let old = Data(repeating: 1, count: 32)
        let rotated = Data(repeating: 2, count: 32)
        let verified: Set<String> = [old.sha256Fingerprint()]
        #expect(WeshQRTrust.canSend(sessionKey: old, qrFingerprints: verified, locallyVerified: true))
        #expect(!WeshQRTrust.canSend(sessionKey: rotated, qrFingerprints: verified, locallyVerified: true))
        let bothVerified = verified.union([rotated.sha256Fingerprint()])
        #expect(!WeshQRTrust.canSend(sessionKey: rotated, qrFingerprints: bothVerified, locallyVerified: true, requestedKey: old))
        #expect(WeshQRTrust.canSend(sessionKey: old, qrFingerprints: bothVerified, locallyVerified: true, requestedKey: old))
        #expect(!WeshQRTrust.canSend(sessionKey: nil, qrFingerprints: verified, locallyVerified: true))
        #expect(!WeshQRTrust.canSend(sessionKey: old, qrFingerprints: [], locallyVerified: true))
        #expect(!WeshQRTrust.canSend(sessionKey: old, qrFingerprints: verified, locallyVerified: false))
    }

    @Test func historicalMessageBlockUsesPinnedIdentityAndRejectsShortAlias() {
        let first = PeerID(hexData: Data(repeating: 31, count: 32))
        let second = PeerID(hexData: Data(repeating: 32, count: 32))
        let staleAlias = PeerID(str: "1122334455667788")
        #expect(WeshMessageActions.blockIdentity(messageSender: staleAlias, pinnedConversation: first) == first)
        #expect(WeshMessageActions.blockIdentity(messageSender: second, pinnedConversation: first) == first)
        #expect(WeshMessageActions.blockIdentity(messageSender: staleAlias, pinnedConversation: nil) == nil)
        #expect(WeshMessageActions.blockIdentity(messageSender: second, pinnedConversation: nil) == second)
        #expect(WeshMessageActions.blockIdentity(messageSender: first, pinnedConversation: staleAlias) == nil)
    }

    @Test @MainActor func contactRemovalRevokesOnlyExactKeyAndPersists() throws {
        let suite = "wesh-contact-removal-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let trust = WeshQRTrust(defaults: defaults)
        let first = Data(repeating: 11, count: 32)
        let second = Data(repeating: 12, count: 32)
        trust.record(sessionKey: first, nickname: "Même surnom")
        trust.record(sessionKey: second, nickname: "Même surnom")
        #expect(!trust.remove(sessionKey: Data(repeating: 11, count: 31)))
        #expect(!trust.remove(sessionKey: Data(repeating: 13, count: 32)))
        #expect(trust.contacts.count == 2)
        #expect(trust.remove(sessionKey: first))
        let reloaded = WeshQRTrust(defaults: defaults)
        #expect(reloaded.contacts.map(\.noiseKeyHex) == [second.hexEncodedString()])
        #expect(!WeshQRTrust.canSend(sessionKey: first, qrFingerprints: reloaded.fingerprints, locallyVerified: true))
        #expect(WeshQRTrust.canSend(sessionKey: second, qrFingerprints: reloaded.fingerprints, locallyVerified: true))
        #expect(!reloaded.remove(sessionKey: first))
    }

    @Test func receiptsDoNotConflateQueuedCarriedAndDelivered() {
        #expect(WeshDelivery.publicLabel(.notSentYet) == "En attente de diffusion")
        #expect(WeshDelivery.publicLabel(.failed(reason: "offline")) == "Échec de diffusion")
        #expect(WeshDelivery.publicLabel(.read(by: "Nora", at: Date())).contains("non confirmée"))
        #expect(WeshDelivery.label(.notSentYet) != WeshDelivery.label(.sent))
        #expect(WeshDelivery.label(.sent).contains("non confirmée"))
        #expect(WeshDelivery.label(.carried).contains("non confirmée"))
        #expect(WeshDelivery.label(.delivered(to: "Nora", at: Date())) == "Réception confirmée")
        #expect(WeshDelivery.label(.read(by: "Nora", at: Date())) == "Lu")
    }
}
