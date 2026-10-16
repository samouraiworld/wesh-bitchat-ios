import CryptoKit
import Foundation
import XCTest
@testable import bitchat

/// Same immutable synthetic fixtures as Android SharedSignedQRNpubInteropTest:
/// `wesh-signed-qr-v1-npub.json` is `wesh-signed-qr-v1.json` with the existing
/// npub field filled. Proves the QR v1 format is only filled, never changed.
final class SharedSignedQRNpubInteropTests: XCTestCase {
    private struct Fixture: Decodable {
        let seedHex: String
        let signKeyHex: String
        let noiseKeyHex: String
        let nostrSecretHex: String?
        let nostrXOnlyPublicKeyHex: String?
        let npub: String?
        let nickname: String
        let timestamp: Int64
        let nonceB64: String
        let signatureHex: String
        let canonicalHex: String
        let canonicalSHA256: String
        let url: String
    }

    private func fixture(_ name: String) throws -> Fixture {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "json")
                ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Services/Fixtures")
        )
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func service() -> VerificationService {
        let service = VerificationService()
        service.configure(with: MockTransport())
        return service
    }

    private func payload(_ f: Fixture, npub: String?) -> VerificationService.VerificationQR {
        VerificationService.VerificationQR(v: 1, noiseKeyHex: f.noiseKeyHex, signKeyHex: f.signKeyHex, npub: npub,
                                           nickname: f.nickname, ts: f.timestamp, nonceB64: f.nonceB64,
                                           sigHex: f.signatureHex)
    }

    func test_emptyNpubCanonicalBytesAndURLAreUnchanged() throws {
        let f = try fixture("wesh-signed-qr-v1")
        let qr = payload(f, npub: nil)
        XCTAssertEqual(qr.canonicalBytes().hexEncodedString(), f.canonicalHex)
        XCTAssertEqual(qr.toURLString(), f.url)
        // An absent and an empty npub sign the same bytes, as upstream BitChat does.
        XCTAssertEqual(payload(f, npub: "").canonicalBytes(), qr.canonicalBytes())
    }

    func test_npubFixtureIsByteIdenticalAndPassesRealVerification() throws {
        let f = try fixture("wesh-signed-qr-v1-npub")
        let npub = try XCTUnwrap(f.npub)
        let built = payload(f, npub: npub)
        XCTAssertEqual(built.canonicalBytes().hexEncodedString(), f.canonicalHex)
        XCTAssertEqual(Data(SHA256.hash(data: built.canonicalBytes())).hexEncodedString(), f.canonicalSHA256)
        XCTAssertEqual(built.toURLString(), f.url)
        XCTAssertTrue(f.url.hasSuffix("&npub=" + npub), "npub stays the last query parameter")

        let parsed = try XCTUnwrap(service().verifyScannedQR(f.url, now: Double(f.timestamp)))
        XCTAssertEqual(parsed.npub, npub)
        XCTAssertEqual(parsed.canonicalBytes().hexEncodedString(), f.canonicalHex)
        XCTAssertEqual(parsed.toURLString(), f.url)
    }

    func test_npubFixtureKeysAreTheDocumentedSyntheticMaterial() throws {
        let f = try fixture("wesh-signed-qr-v1-npub")
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: try XCTUnwrap(Data(hexString: f.seedHex)))
        XCTAssertEqual(signing.publicKey.rawRepresentation.hexEncodedString(), f.signKeyHex)
        XCTAssertTrue(signing.publicKey.isValidSignature(try XCTUnwrap(Data(hexString: f.signatureHex)),
                                                         for: try XCTUnwrap(Data(hexString: f.canonicalHex))))
        let nostr = try NostrIdentity(privateKeyData: try XCTUnwrap(Data(hexString: try XCTUnwrap(f.nostrSecretHex))))
        XCTAssertEqual(nostr.npub, f.npub)
        XCTAssertEqual(nostr.publicKeyHex, f.nostrXOnlyPublicKeyHex)
        XCTAssertEqual(WeshQRNpub.xOnlyKey(fromNpub: try XCTUnwrap(f.npub))?.hexEncodedString(), f.nostrXOnlyPublicKeyHex)
    }

    func test_strippingOrSwappingTheSignedNpubIsRejected() throws {
        let f = try fixture("wesh-signed-qr-v1-npub")
        let npub = try XCTUnwrap(f.npub)
        let other = try NostrIdentity.generate().npub
        let verifier = service()
        for url in [f.url.replacingOccurrences(of: "&npub=" + npub, with: ""),
                    f.url.replacingOccurrences(of: npub, with: other)] {
            XCTAssertNotEqual(url, f.url)
            XCTAssertNotNil(VerificationService.VerificationQR.fromURL(try XCTUnwrap(URL(string: url))))
            XCTAssertNil(verifier.verifyScannedQR(url, now: Double(f.timestamp)))
        }
    }
}
