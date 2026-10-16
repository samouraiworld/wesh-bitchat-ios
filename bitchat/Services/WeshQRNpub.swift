import CryptoKit
import Foundation
import P256K

/// The npub a scanned QR signs is checked at enrollment, never in the parser:
/// the QR v1 format and its canonical bytes stay exactly upstream's. A failing
/// npub leaves the contact enrolled Bluetooth-only. Proof of possession and
/// precedence rules: docs/plan/fixtures/NPUB-PROOF.md.
enum WeshQRNpub {
    /// What a verified scan does to the npub bindings.
    enum Outcome: Equatable {
        /// No usable npub: no npub, malformed, mine, failed proof, or my own
        /// npubs unknown (fail closed).
        case bluetoothOnly
        /// Bind to the scanned contact; `unbinding` lose the npub and are flagged.
        case bound(npub: String, proven: Bool, unbinding: Set<String>)
        /// Not bound and flagged; `unbinding` lose the npub and are flagged too.
        case conflict(unbinding: Set<String>)
    }

    static let proofDomain = "wesh-npub-proof-v1"

    /// Precedence for one npub claimed by several Noise identities: proven
    /// wins over unproven (the newest proven over an older proven one); two
    /// unproven claims unbind both. A losing claim is flagged, never dropped silently.
    static func enrollment(npub candidate: String?, npubSigHex: String?, canonicalBytes: Data,
                           noiseKeyHex: String, ownedNpubs: Set<String>?,
                           contacts: [WeshQRTrust.Contact]) -> Outcome {
        guard let candidate, let xOnly = xOnlyKey(fromNpub: candidate),
              let ownedNpubs, !ownedNpubs.contains(candidate) else { return .bluetoothOnly }
        var proven = false
        if let npubSigHex {
            // A proof that is present must verify; it is never downgraded to unproven.
            guard verifyProof(npubSigHex, xOnlyKey: xOnly, canonicalBytes: canonicalBytes) else { return .bluetoothOnly }
            proven = true
        }
        let hex = noiseKeyHex.lowercased()
        let holders = contacts.filter { $0.npub == candidate }
        // Re-enrolling the same identity without the proof keeps its proven binding.
        if holders.contains(where: { $0.noiseKeyHex.lowercased() == hex && $0.isNpubProven }) { proven = true }
        let others = holders.filter { $0.noiseKeyHex.lowercased() != hex }
        let otherKeys = Set(others.map { $0.noiseKeyHex.lowercased() })
        if others.isEmpty || proven { return .bound(npub: candidate, proven: proven, unbinding: otherKeys) }
        return .conflict(unbinding: others.contains(where: \.isNpubProven) ? [] : otherKeys)
    }

    /// Inbound Nostr sender resolution: the one contact bound to this npub.
    static func inboundContact(forNpub npub: String, in contacts: [WeshQRTrust.Contact]) -> WeshQRTrust.Contact? {
        let holders = contacts.filter { $0.npub == npub }
        return holders.count == 1 ? holders[0] : nil
    }

    /// My QR carries my npub only while Internet mode is on and the app is not
    /// panic-fenced, and only if a key already exists: never created here.
    static func identityForMyQR(internetEnabled: Bool, panicFenced: Bool,
                                storedIdentity: () -> NostrIdentity?) -> NostrIdentity? {
        guard internetEnabled, !panicFenced else { return nil }
        return storedIdentity()
    }

    /// SHA-256(UTF-8 "wesh-npub-proof-v1" || canonical bytes).
    static func proofMessage(canonicalBytes: Data) -> Data {
        Data(SHA256.hash(data: Data(proofDomain.utf8) + canonicalBytes))
    }

    static func signProof(canonicalBytes: Data, identity: NostrIdentity) -> Data? {
        var message = [UInt8](proofMessage(canonicalBytes: canonicalBytes))
        var aux = [UInt8](repeating: 0, count: 32)
        guard aux.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess,
              let key = try? identity.schnorrSigningKey(),
              let signature = try? key.signature(message: &message, auxiliaryRand: &aux) else { return nil }
        return signature.dataRepresentation
    }

    static func verifyProof(_ sigHex: String, xOnlyKey: Data, canonicalBytes: Data) -> Bool {
        guard let sigData = Data(hexString: sigHex), sigData.count == 64,
              let signature = try? P256K.Schnorr.SchnorrSignature(dataRepresentation: sigData) else { return false }
        var message = [UInt8](proofMessage(canonicalBytes: canonicalBytes))
        return P256K.Schnorr.XonlyKey(dataRepresentation: xOnlyKey).isValid(signature, for: &message)
    }

    /// Decodes a canonical lowercase `npub` to its 32-byte x-only key.
    static func xOnlyKey(fromNpub npub: String) -> Data? {
        guard npub.utf8.count <= 255,
              let decoded = try? Bech32.decode(npub), decoded.hrp == "npub", decoded.data.count == 32,
              // Re-encoding rejects mixed case and non-zero padding bits.
              (try? Bech32.encode(hrp: "npub", data: decoded.data)) == npub,
              // An x coordinate on the curve parses with either parity prefix.
              (try? P256K.KeyAgreement.PublicKey(dataRepresentation: Data([0x02]) + decoded.data,
                                                 format: .compressed)) != nil
        else { return nil }
        return decoded.data
    }
}

extension WeshQRTrust {
    /// Applies a verified scan's npub outcome.
    func enroll(sessionKey: Data, nickname: String, outcome: WeshQRNpub.Outcome) {
        switch outcome {
        case .bluetoothOnly:
            record(sessionKey: sessionKey, nickname: nickname)
        case let .bound(npub, proven, unbinding):
            flagNpubConflict(noiseKeysHex: unbinding)
            record(sessionKey: sessionKey, nickname: nickname, npub: npub, npubProven: proven)
        case .conflict(let unbinding):
            flagNpubConflict(noiseKeysHex: unbinding)
            record(sessionKey: sessionKey, nickname: nickname, npubConflict: true)
        }
    }
}

extension WeshQRTrust.Contact {
    var isNpubProven: Bool { npub != nil && npubProven == true }
    /// UI: the npub was claimed by another contact too; rescan to settle it.
    var hasNpubConflict: Bool { npubConflict == true }

    /// UI: « Rescannez son QR pour échanger par Internet ». Legacy contacts
    /// and QRs whose npub failed enrollment checks land here.
    var requiresRescanForInternet: Bool { npub == nil }
}
