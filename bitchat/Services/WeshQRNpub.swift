import Foundation
import P256K

/// The npub a scanned QR signs is checked at enrollment, never in the parser:
/// the QR v1 format and its canonical bytes stay exactly upstream's. A failing
/// npub leaves the contact enrolled Bluetooth-only.
enum WeshQRNpub {
    /// The npub to bind to `noiseKeyHex`, or nil. It must be a canonical
    /// bech32 `npub` of a valid secp256k1 x-only key, differ from my own npub
    /// (fail closed when mine is unknown) and from every other contact's.
    static func enrollable(_ candidate: String?, noiseKeyHex: String, ownNpub: String?,
                           contacts: [WeshQRTrust.Contact]) -> String? {
        guard let candidate, xOnlyKey(fromNpub: candidate) != nil,
              let ownNpub, ownNpub != candidate else { return nil }
        let hex = noiseKeyHex.lowercased()
        guard !contacts.contains(where: { $0.npub == candidate && $0.noiseKeyHex.lowercased() != hex }) else { return nil }
        return candidate
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

extension WeshQRTrust.Contact {
    /// UI: « Rescannez son QR pour échanger par Internet ». Legacy contacts
    /// and QRs whose npub failed enrollment checks land here.
    var requiresRescanForInternet: Bool { npub == nil }
}
