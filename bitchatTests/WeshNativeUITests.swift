import BitFoundation
import CryptoKit
import Foundation
import Testing
@testable import bitchat

@Suite("Wesh native trust and public separation")
struct WeshNativeUITests {
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

    @Test func receiptsDoNotConflateQueuedCarriedAndDelivered() {
        #expect(WeshDelivery.publicLabel(.notSentYet) == "En attente de diffusion")
        #expect(WeshDelivery.publicLabel(.failed(reason: "offline")) == "Échec de diffusion")
        #expect(WeshDelivery.publicLabel(.read(by: "Nora", at: Date())).contains("non confirmée"))
        #expect(WeshDelivery.label(.notSentYet) != WeshDelivery.label(.sent))
        #expect(WeshDelivery.label(.carried).contains("non confirmée"))
        #expect(WeshDelivery.label(.delivered(to: "Nora", at: Date())) == "Réception confirmée")
        #expect(WeshDelivery.label(.read(by: "Nora", at: Date())) == "Lu")
    }
}
