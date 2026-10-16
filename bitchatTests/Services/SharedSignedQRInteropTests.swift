import CryptoKit
import Foundation
import XCTest
@testable import bitchat

/// Same immutable synthetic fixture as Android SharedSignedQRInteropTest.
/// This proves signed QR API compatibility, not a live Noise session or camera scan.
final class SharedSignedQRInteropTests: XCTestCase {
    private struct Fixture: Decodable {
        let seedHex: String
        let signKeyHex: String
        let noiseKeyHex: String
        let nickname: String
        let timestamp: Int64
        let nonceB64: String
        let signatureHex: String
        let canonicalHex: String
        let canonicalSHA256: String
        let url: String
    }

    private func fixture() throws -> Fixture {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Self.self)
        #endif
        let url = try XCTUnwrap(
            bundle.url(forResource: "wesh-signed-qr-v1", withExtension: "json")
                ?? bundle.url(forResource: "wesh-signed-qr-v1", withExtension: "json", subdirectory: "Services/Fixtures")
        )
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func service() -> VerificationService {
        let service = VerificationService()
        // MockTransport forwards verification to the real Noise encryption implementation.
        service.configure(with: MockTransport())
        return service
    }

    func test_sharedSignedURLPassesRealVerificationAndCanonicalEncoding() throws {
        let f = try fixture()
        let parsed = try XCTUnwrap(service().verifyScannedQR(f.url, now: Double(f.timestamp)))
        XCTAssertEqual(parsed.nickname, f.nickname)
        XCTAssertEqual(parsed.noiseKeyHex, f.noiseKeyHex)
        XCTAssertEqual(parsed.signKeyHex, f.signKeyHex)
        XCTAssertEqual(parsed.nonceB64, f.nonceB64)
        XCTAssertEqual(parsed.ts, f.timestamp)
        XCTAssertEqual(parsed.sigHex, f.signatureHex)
        XCTAssertEqual(parsed.canonicalBytes().hexEncodedString(), f.canonicalHex)
        XCTAssertEqual(Data(SHA256.hash(data: parsed.canonicalBytes())).hexEncodedString(), f.canonicalSHA256)
    }

    func test_publicSyntheticSeedAuthenticatesFixtureAndFreshSignature() throws {
        let f = try fixture()
        let seed = try XCTUnwrap(Data(hexString: f.seedHex))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let canonical = try XCTUnwrap(Data(hexString: f.canonicalHex))
        XCTAssertEqual(key.publicKey.rawRepresentation.hexEncodedString(), f.signKeyHex)
        let fixtureSignature = try XCTUnwrap(Data(hexString: f.signatureHex))
        XCTAssertTrue(key.publicKey.isValidSignature(fixtureSignature, for: canonical))
        // Signing APIs may randomize the nonce: valid signatures need not be byte-identical.
        let freshSignature = try key.signature(for: canonical)
        XCTAssertTrue(key.publicKey.isValidSignature(freshSignature, for: canonical))
    }

    func test_signatureNicknameNonceAndTimestampTamperingAreRejected() throws {
        let f = try fixture()
        let mutatedSignature = "0" + f.signatureHex.dropFirst()
        let variants = [
            f.url.replacingOccurrences(of: f.signatureHex, with: mutatedSignature),
            f.url.replacingOccurrences(of: "nick=Nora%20caf%C3%A9", with: "nick=Nora%20cafe"),
            f.url.replacingOccurrences(of: f.nonceB64, with: "AAECAwQFBgcICQoLDA0ODg"),
            f.url.replacingOccurrences(of: "ts=1700000000", with: "ts=1700000001")
        ]
        let verifier = service()
        for url in variants {
            XCTAssertNotEqual(url, f.url)
            // Parser-valid mutations isolate cryptographic rejection, not malformed input.
            XCTAssertNotNil(VerificationService.VerificationQR.fromURL(try XCTUnwrap(URL(string: url))))
            XCTAssertNil(verifier.verifyScannedQR(url, now: Double(f.timestamp)))
        }
    }

    func test_builderReproducesTheSharedFixtureURLExactly() throws {
        let f = try fixture()
        let qr = VerificationService.VerificationQR(
            v: 1, noiseKeyHex: f.noiseKeyHex, signKeyHex: f.signKeyHex, npub: nil, nickname: f.nickname,
            ts: f.timestamp, nonceB64: f.nonceB64, sigHex: f.signatureHex
        )
        XCTAssertEqual(qr.toURLString(), f.url)
    }

    /// Android's `Uri.getQueryParameter` decodes "+" as a space. A raw "+"
    /// in the signed nickname therefore broke verification across platforms.
    func test_reservedNicknameCharactersArePercentEncodedForBothDecoders() throws {
        let f = try fixture()
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: try XCTUnwrap(Data(hexString: f.seedHex)))
        let nickname = "Nora+café & co=1"
        var qr = VerificationService.VerificationQR(
            v: 1, noiseKeyHex: f.noiseKeyHex, signKeyHex: f.signKeyHex, npub: nil, nickname: nickname,
            ts: f.timestamp, nonceB64: f.nonceB64, sigHex: ""
        )
        qr.sigHex = try key.signature(for: qr.canonicalBytes()).hexEncodedString()
        let url = qr.toURLString()

        XCTAssertTrue(url.contains("nick=Nora%2Bcaf%C3%A9%20%26%20co%3D1&"), url)
        // Form-style decoding, as Android performs it.
        let rawNick = try XCTUnwrap(URLComponents(string: url)?.percentEncodedQueryItems?.first { $0.name == "nick" }?.value)
        XCTAssertEqual(rawNick.replacingOccurrences(of: "+", with: " ").removingPercentEncoding, nickname)
        // iOS decoding plus the real signature check.
        let parsed = try XCTUnwrap(service().verifyScannedQR(url, now: Double(f.timestamp)))
        XCTAssertEqual(parsed.nickname, nickname)
    }

    func test_sameSignedFixtureHasInclusiveSymmetricFreshnessBoundary() throws {
        let f = try fixture()
        let verifier = service()
        for offset: Int64 in [-301, -300, 0, 300, 301] {
            XCTAssertEqual(
                verifier.verifyScannedQR(f.url, now: Double(f.timestamp + offset)) != nil,
                abs(offset) <= 300,
                "Clock offset: \(offset)"
            )
        }
    }
}
