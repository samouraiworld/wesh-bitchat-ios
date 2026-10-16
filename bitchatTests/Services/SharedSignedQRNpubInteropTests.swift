import CryptoKit
import Foundation
import XCTest
@testable import bitchat

/// Same immutable synthetic fixtures as the Android tests:
/// `wesh-signed-qr-v1-npub.json` is `wesh-signed-qr-v1.json` with the existing
/// npub field filled, and `wesh-signed-qr-v1-npub-proof.json` adds the optional
/// `npubsig` (NPUB-PROOF). Proves the QR v1 format is only filled, never changed.
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

    /// The Android-authored proof fixture: proof fields on top of the npub fixture.
    private struct ProofFixture: Decodable {
        let canonicalHex: String
        let signatureHex: String
        let npub: String
        let nostrSecretHex: String
        let npubProofMessageHex: String
        let npubSigHex: String
        let timestamp: Int64
        let url: String
    }

    private func fixtureData(_ name: String) throws -> Data {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Self.self)
        #endif
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "json")
                ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Services/Fixtures")
        )
        return try Data(contentsOf: url)
    }

    private func proofFixture() throws -> ProofFixture {
        try JSONDecoder().decode(ProofFixture.self, from: fixtureData("wesh-signed-qr-v1-npub-proof"))
    }

    private func fixture(_ name: String) throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: fixtureData(name))
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

    func test_npubProofFixtureIsByteIdenticalAndProvesPossession() throws {
        let f = try proofFixture()
        let unproven = try fixture("wesh-signed-qr-v1-npub")
        let npub = f.npub
        let sigHex = f.npubSigHex
        XCTAssertEqual(unproven.npub, npub)
        XCTAssertEqual(f.canonicalHex, unproven.canonicalHex)
        var built = payload(unproven, npub: npub)
        built.npubSigHex = sigHex
        XCTAssertEqual(built.canonicalBytes().hexEncodedString(), unproven.canonicalHex, "the proof stays outside the canonical bytes")
        XCTAssertEqual(f.signatureHex, unproven.signatureHex)
        XCTAssertEqual(built.toURLString(), f.url)
        XCTAssertEqual(f.url, unproven.url + "&npubsig=" + sigHex)
        XCTAssertEqual(WeshQRNpub.proofMessage(canonicalBytes: built.canonicalBytes()).hexEncodedString(), f.npubProofMessageHex)

        let parsed = try XCTUnwrap(service().verifyScannedQR(f.url, now: Double(f.timestamp)))
        XCTAssertEqual(parsed.npubSigHex, sigHex)
        let xOnly = try XCTUnwrap(WeshQRNpub.xOnlyKey(fromNpub: npub))
        XCTAssertTrue(WeshQRNpub.verifyProof(sigHex, xOnlyKey: xOnly, canonicalBytes: parsed.canonicalBytes()))
        XCTAssertEqual(WeshQRNpub.enrollment(npub: parsed.npub, npubSigHex: parsed.npubSigHex,
                                             canonicalBytes: parsed.canonicalBytes(), noiseKeyHex: parsed.noiseKeyHex,
                                             ownedNpubs: [], contacts: []),
                       .bound(npub: npub, proven: true, unbinding: []))

        // A fresh proof by the documented secret also verifies (aux randomness differs).
        let nostr = try NostrIdentity(privateKeyData: try XCTUnwrap(Data(hexString: f.nostrSecretHex)))
        let fresh = try XCTUnwrap(WeshQRNpub.signProof(canonicalBytes: parsed.canonicalBytes(), identity: nostr))
        XCTAssertTrue(WeshQRNpub.verifyProof(fresh.hexEncodedString(), xOnlyKey: xOnly, canonicalBytes: parsed.canonicalBytes()))
    }

    func test_npubsigIsOptionalButMustBeWellFormedAndPaired() throws {
        let f = try proofFixture()
        let npub = f.npub
        let sigHex = f.npubSigHex
        func parses(_ url: String) throws -> Bool {
            VerificationService.VerificationQR.fromURL(try XCTUnwrap(URL(string: url))) != nil
        }
        XCTAssertTrue(try parses(f.url))
        XCTAssertFalse(try parses(f.url.replacingOccurrences(of: "&npub=" + npub, with: "")), "npubsig without npub")
        XCTAssertFalse(try parses(f.url.replacingOccurrences(of: sigHex, with: String(sigHex.dropLast(2)))))
        XCTAssertFalse(try parses(f.url + "&npubsig=" + sigHex), "duplicate npubsig")
        // A tampered proof still passes the Ed25519 check (outside the canonical
        // bytes) but fails at enrollment, leaving the contact Bluetooth-only.
        let tampered = f.url.replacingOccurrences(of: sigHex, with: "00" + sigHex.dropFirst(2))
        let parsed = try XCTUnwrap(service().verifyScannedQR(tampered, now: Double(f.timestamp)))
        XCTAssertEqual(WeshQRNpub.enrollment(npub: parsed.npub, npubSigHex: parsed.npubSigHex,
                                             canonicalBytes: parsed.canonicalBytes(), noiseKeyHex: parsed.noiseKeyHex,
                                             ownedNpubs: [], contacts: []),
                       .bluetoothOnly)
    }

    func test_emptyNpubOrNpubsigIsTreatedAsAbsent() throws {
        // Empty and absent npub sign the same bytes, so `&npub=` can be appended
        // to any signed QR: it must parse as no claim, never as an npub of "".
        let plain = try fixture("wesh-signed-qr-v1")
        let appended = try XCTUnwrap(service().verifyScannedQR(plain.url + "&npub=", now: Double(plain.timestamp)))
        XCTAssertNil(appended.npub)
        XCTAssertNil(appended.npubSigHex)
        XCTAssertEqual(WeshQRNpub.enrollment(npub: appended.npub, npubSigHex: appended.npubSigHex,
                                             canonicalBytes: appended.canonicalBytes(), noiseKeyHex: appended.noiseKeyHex,
                                             ownedNpubs: [], contacts: []),
                       .keep)
        let f = try proofFixture()
        XCTAssertNil(VerificationService.VerificationQR.fromURL(try XCTUnwrap(URL(string: plain.url + "&npub=&npubsig=" + f.npubSigHex))),
                     "npubsig with an empty npub is npubsig without npub")
        let unproven = try fixture("wesh-signed-qr-v1-npub")
        let emptySig = try XCTUnwrap(service().verifyScannedQR(unproven.url + "&npubsig=", now: Double(unproven.timestamp)))
        XCTAssertEqual(emptySig.npub, unproven.npub)
        XCTAssertNil(emptySig.npubSigHex)
    }

    func test_npubsigMustBeLowercaseHex() throws {
        let f = try proofFixture()
        let upper = f.url.replacingOccurrences(of: f.npubSigHex, with: f.npubSigHex.uppercased())
        XCTAssertNotEqual(upper, f.url)
        XCTAssertNil(VerificationService.VerificationQR.fromURL(try XCTUnwrap(URL(string: upper))))
    }

    func test_buildMyQRStringFallsBackToBluetoothOnlyWhenTheProofFails() throws {
        let builder = VerificationService()
        builder.configure(with: MockTransport())
        let nostr = try NostrIdentity.generate()
        let url = try XCTUnwrap(builder.buildMyQRString(nickname: "Nora", npub: nostr.npub, npubSigner: { _ in nil }))
        XCTAssertFalse(url.contains("npub"), "an unprovable npub is left out, not shown unproven")
        let parsed = try XCTUnwrap(builder.verifyScannedQR(url))
        XCTAssertNil(parsed.npub)
    }

    func test_buildMyQRStringSignsTheProofOverTheCanonicalBytes() throws {
        let transport = MockTransport()
        let builder = VerificationService()
        builder.configure(with: transport)
        let nostr = try NostrIdentity.generate()
        let url = try XCTUnwrap(builder.buildMyQRString(nickname: "Nora", npub: nostr.npub,
            npubSigner: { WeshQRNpub.signProof(canonicalBytes: $0, identity: nostr) }))
        let parsed = try XCTUnwrap(builder.verifyScannedQR(url))
        XCTAssertEqual(parsed.npub, nostr.npub)
        XCTAssertTrue(WeshQRNpub.verifyProof(try XCTUnwrap(parsed.npubSigHex), xOnlyKey: nostr.publicKey,
                                             canonicalBytes: parsed.canonicalBytes()))
        // Without a signer (or without an npub) there is no npubsig.
        let plain = try XCTUnwrap(builder.buildMyQRString(nickname: "Nora", npub: nil,
            npubSigner: { WeshQRNpub.signProof(canonicalBytes: $0, identity: nostr) }))
        XCTAssertFalse(plain.contains("npub"))
    }
}
