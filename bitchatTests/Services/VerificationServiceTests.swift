import XCTest
@testable import bitchat

final class VerificationServiceTests: XCTestCase {
    func test_unavailableNoiseCannotBuildOrReuseQRCode() throws {
        let keychain = MockKeychain()
        let transport = BLEService(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychain()),
            identityManager: MockIdentityManager(keychain),
            initializeBluetoothManagers: false
        )
        let service = VerificationService()
        service.configure(with: transport)
        let nickname = "synthetic-noise-unavailable-\(UUID().uuidString)"
        _ = try XCTUnwrap(service.buildMyQRString(nickname: nickname, npub: nil))
        transport.suspendForPanicReset()
        XCTAssertNil(service.buildMyQRString(nickname: nickname, npub: nil))
    }

    func test_lockedNoiseRefusesQRCodeAndRecoversPersistedKeys() throws {
        let keychain = MockKeychain()
        let original = NoiseEncryptionService(keychain: keychain)
        let expectedKey = try XCTUnwrap(original.getStaticPublicKeyData())
        keychain.simulatedReadError = .deviceLocked
        let transport = BLEService(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: MockKeychain()),
            identityManager: MockIdentityManager(keychain),
            initializeBluetoothManagers: false
        )
        let service = VerificationService()
        service.configure(with: transport)
        XCTAssertNil(service.buildMyQRString(nickname: "synthetic recovery", npub: nil))
        keychain.simulatedReadError = nil
        XCTAssertTrue(transport.retryNoiseIdentityPersistence())
        let encoded = try XCTUnwrap(service.buildMyQRString(nickname: "synthetic recovery", npub: nil))
        let parsed = try XCTUnwrap(service.verifyScannedQR(encoded))
        XCTAssertEqual(parsed.noiseKeyHex, expectedKey.hexEncodedString())
    }

    func test_buildMyQRString_roundTripsSuccessfully() throws {
        let (service, noise) = makeService()
        let nickname = "alice-\(UUID().uuidString)"
        let npub = "npub1testvalue"

        let qrString = try XCTUnwrap(service.buildMyQRString(nickname: nickname, npub: npub))
        let parsed = try XCTUnwrap(service.verifyScannedQR(qrString))

        XCTAssertEqual(parsed.nickname, nickname)
        XCTAssertEqual(parsed.npub, npub)
        XCTAssertEqual(parsed.noiseKeyHex, noise.getStaticPublicKeyData()!.hexEncodedString())
        XCTAssertEqual(parsed.signKeyHex, noise.getSigningPublicKeyData()!.hexEncodedString())
    }

    func test_buildMyQRString_returnsCachedValueForSameInputs() throws {
        let (service, _) = makeService()
        let nickname = "cache-\(UUID().uuidString)"

        let first = try XCTUnwrap(service.buildMyQRString(nickname: nickname, npub: nil))
        let second = try XCTUnwrap(service.buildMyQRString(nickname: nickname, npub: nil))

        XCTAssertEqual(first, second)
    }

    func test_verifyScannedQR_rejectsExpiredPayload() throws {
        let (service, noise) = makeService()
        let oldTimestamp = Int64(Date().addingTimeInterval(-3600).timeIntervalSince1970)
        let qrString = try makeSignedQR(
            noise: noise,
            nickname: "expired-\(UUID().uuidString)",
            npub: nil,
            ts: oldTimestamp
        )

        XCTAssertNil(service.verifyScannedQR(qrString, maxAge: 60))
    }

    func test_verifyScannedQR_rejectsFutureDatedPayload() throws {
        let (service, noise) = makeService()
        let futureTimestamp = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let qrString = try makeSignedQR(
            noise: noise,
            nickname: "future-\(UUID().uuidString)",
            npub: nil,
            ts: futureTimestamp
        )

        XCTAssertNil(service.verifyScannedQR(qrString, maxAge: 60))
    }

    func test_verifyScannedQR_rejectsTamperedSignature() throws {
        let (service, noise) = makeService()
        let badSignature = Data(repeating: 0xAA, count: 64)
        let qrString = try makeSignedQR(
            noise: noise,
            nickname: "tampered-\(UUID().uuidString)",
            npub: nil,
            ts: Int64(Date().timeIntervalSince1970),
            signatureOverride: badSignature
        )

        XCTAssertNil(service.verifyScannedQR(qrString))
    }

    func test_buildVerifyChallenge_roundTripsThroughNoisePayload() throws {
        let (service, _) = makeService()
        let noiseKeyHex = String(repeating: "ab", count: 32)
        let nonce = Data([0x01, 0x02, 0x03, 0x04])

        let encoded = service.buildVerifyChallenge(noiseKeyHex: noiseKeyHex, nonceA: nonce)
        let payload = try XCTUnwrap(NoisePayload.decode(encoded))
        let parsed = try XCTUnwrap(service.parseVerifyChallenge(payload.data))

        XCTAssertEqual(payload.type, .verifyChallenge)
        XCTAssertEqual(parsed.noiseKeyHex, noiseKeyHex)
        XCTAssertEqual(parsed.nonceA, nonce)
    }

    func test_buildVerifyResponse_roundTripsAndVerifiesSignature() throws {
        let (service, noise) = makeService()
        let noiseKeyHex = String(repeating: "cd", count: 32)
        let nonce = Data([0x10, 0x20, 0x30, 0x40, 0x50])

        let encoded = try XCTUnwrap(service.buildVerifyResponse(noiseKeyHex: noiseKeyHex, nonceA: nonce))
        let payload = try XCTUnwrap(NoisePayload.decode(encoded))
        let parsed = try XCTUnwrap(service.parseVerifyResponse(payload.data))

        XCTAssertEqual(payload.type, .verifyResponse)
        XCTAssertEqual(parsed.noiseKeyHex, noiseKeyHex)
        XCTAssertEqual(parsed.nonceA, nonce)
        XCTAssertTrue(
            service.verifyResponseSignature(
                noiseKeyHex: parsed.noiseKeyHex,
                nonceA: parsed.nonceA,
                signature: parsed.signature,
                signerPublicKeyHex: noise.getSigningPublicKeyData()!.hexEncodedString()
            )
        )
        XCTAssertFalse(
            service.verifyResponseSignature(
                noiseKeyHex: parsed.noiseKeyHex,
                nonceA: Data([0xFF]),
                signature: parsed.signature,
                signerPublicKeyHex: noise.getSigningPublicKeyData()!.hexEncodedString()
            )
        )
    }

    func test_freshnessBoundariesAreSymmetric() throws {
        let (service, noise) = makeService()
        for offset: Int64 in [-301, -300, 300, 301] {
            let qr = try makeSignedQR(noise: noise, nickname: "Nora", npub: nil, ts: 1700000000 + offset)
            XCTAssertEqual(service.verifyScannedQR(qr, now: 1700000000) != nil, abs(offset) <= 300)
        }
    }

    func test_cacheIsBoundToLocalIdentity() throws {
        let (first, _) = makeService()
        let (second, _) = makeService()
        let name = "rotation-\(UUID().uuidString)"
        let before = try XCTUnwrap(first.buildMyQRString(nickname: name, npub: nil))
        let after = try XCTUnwrap(second.buildMyQRString(nickname: name, npub: nil))
        XCTAssertNotEqual(before, after)
    }

    func test_builderRejectsOversizeUTF8Fields() {
        let (service, _) = makeService()
        XCTAssertNil(service.buildMyQRString(nickname: String(repeating: "é", count: 128), npub: nil))
        XCTAssertNil(service.buildMyQRString(nickname: "Nora", npub: String(repeating: "a", count: 256)))
    }

    private func makeService() -> (VerificationService, NoiseEncryptionService) {
        // The service consumes Noise identity operations through the
        // Transport's narrow noise* wrappers; the mock transport's backing
        // encryption service is returned for direct assertions.
        let transport = MockTransport()
        let service = VerificationService()
        service.configure(with: transport)
        return (service, transport.mockNoiseService)
    }

    private func makeSignedQR(
        noise: NoiseEncryptionService,
        nickname: String,
        npub: String?,
        ts: Int64,
        signatureOverride: Data? = nil
    ) throws -> String {
        var payload = VerificationService.VerificationQR(
            v: 1,
            noiseKeyHex: noise.getStaticPublicKeyData()!.hexEncodedString(),
            signKeyHex: noise.getSigningPublicKeyData()!.hexEncodedString(),
            npub: npub,
            nickname: nickname,
            ts: ts,
            nonceB64: Data((0..<16).map(UInt8.init)).base64EncodedString().replacingOccurrences(of: "=", with: ""),
            sigHex: ""
        )
        let signature = try XCTUnwrap(signatureOverride ?? noise.signData(payload.canonicalBytes()))
        payload.sigHex = signature.hexEncodedString()
        return payload.toURLString()
    }
}
