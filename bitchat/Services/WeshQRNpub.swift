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
        /// The QR makes no npub claim: the contact's binding is unchanged.
        case keep
        /// The claim is unusable (malformed, mine, failed proof, or my own
        /// npubs unknown): no binding.
        case bluetoothOnly
        /// Bind to the scanned contact. `unbinding` are unproven incumbents a
        /// verified proof displaced; they lose the npub and are flagged for review.
        case bound(npub: String, proven: Bool, unbinding: Set<String>)
        /// A claim to an npub another contact holds that it may not take
        /// (unproven, or the incumbent is proven): refused, the incumbent is
        /// kept, and this contact is flagged for review.
        case conflict
        /// This contact was proven before and the new QR does not prove its
        /// claim (e.g. `npubsig` stripped from a shared link): the proven
        /// binding is kept and a warning shown, never silently downgraded.
        case keepProven
    }

    static let proofDomain = "wesh-npub-proof-v1"

    /// Only a verified proof may unbind an incumbent, and only an unproven
    /// one; nothing displaces a proven incumbent. See NPUB-PROOF.md.
    static func enrollment(npub candidate: String?, npubSigHex: String?, canonicalBytes: Data,
                           noiseKeyHex: String, ownedNpubs: Set<String>?,
                           contacts: [WeshQRTrust.Contact]) -> Outcome {
        // Empty signs the same canonical bytes as absent: no claim.
        guard let candidate, !candidate.isEmpty else { return .keep }
        let hex = noiseKeyHex.lowercased()
        let wasProven = contacts.contains { $0.noiseKeyHex.lowercased() == hex && $0.isNpubProven }
        let refused: Outcome = wasProven ? .keepProven : .bluetoothOnly
        guard let xOnly = xOnlyKey(fromNpub: candidate),
              let ownedNpubs, !ownedNpubs.contains(candidate) else { return refused }
        let others = contacts.filter { $0.npub == candidate && $0.noiseKeyHex.lowercased() != hex }
        if let npubSigHex {
            // A proof that is present must verify; it is never downgraded to unproven.
            guard verifyProof(npubSigHex, xOnlyKey: xOnly, canonicalBytes: canonicalBytes) else { return refused }
            if others.contains(where: \.isNpubProven) { return .conflict }
            return .bound(npub: candidate, proven: true, unbinding: Set(others.map { $0.noiseKeyHex.lowercased() }))
        }
        if wasProven { return .keepProven }
        return others.isEmpty ? .bound(npub: candidate, proven: false, unbinding: []) : .conflict
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
        let hex = sessionKey.hexEncodedString()
        let current = contacts.first { $0.noiseKeyHex.lowercased() == hex }
        // Review flags stay pending until the user settles them; a later scan never clears them.
        let conflict = current?.hasNpubConflict ?? false
        let warning = current?.hasNpubProofWarning ?? false
        switch outcome {
        case .keep:
            record(sessionKey: sessionKey, nickname: nickname, npub: current?.npub,
                   npubProven: current?.isNpubProven ?? false, npubConflict: conflict, npubProofWarning: warning)
        case .bluetoothOnly:
            record(sessionKey: sessionKey, nickname: nickname, npubConflict: conflict, npubProofWarning: warning)
        case let .bound(npub, proven, unbinding):
            flagNpubConflict(noiseKeysHex: unbinding)
            record(sessionKey: sessionKey, nickname: nickname, npub: npub, npubProven: proven,
                   npubConflict: conflict, npubProofWarning: warning)
        case .conflict:
            // This contact's earlier binding, if any, is not another's claim: keep it.
            record(sessionKey: sessionKey, nickname: nickname, npub: current?.npub,
                   npubProven: current?.isNpubProven ?? false, npubConflict: true, npubProofWarning: warning)
        case .keepProven:
            record(sessionKey: sessionKey, nickname: nickname, npub: current?.npub,
                   npubProven: true, npubConflict: conflict, npubProofWarning: true)
        }
    }
}

extension WeshQRTrust.Contact {
    var isNpubProven: Bool { npub != nil && npubProven == true }
    /// UI: another contact holds or claimed the same npub; for review.
    var hasNpubConflict: Bool { npubConflict == true }
    /// UI: proven before, but the last QR did not prove its npub; binding kept.
    var hasNpubProofWarning: Bool { npubProofWarning == true }

    /// UI: « Rescannez son QR pour échanger par Internet ». Legacy contacts
    /// and QRs whose npub failed enrollment checks land here.
    var requiresRescanForInternet: Bool { npub == nil }
}
