//
// BridgeWireFormatTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("Bridge wire formats")
struct BridgeWireFormatTests {
    // MARK: - Announce bridgeGeohash TLV

    @Test func announceRoundTripsBridgeGeohash() throws {
        let packet = AnnouncementPacket(
            nickname: "gw",
            noisePublicKey: Data(repeating: 1, count: 32),
            signingPublicKey: Data(repeating: 2, count: 32),
            directNeighbors: nil,
            capabilities: [.bridge, .gateway],
            bridgeGeohash: "u4pruy"
        )
        let encoded = try #require(packet.encode())
        let decoded = try #require(AnnouncementPacket.decode(from: encoded))
        #expect(decoded.bridgeGeohash == "u4pruy")
        #expect(decoded.capabilities?.contains(.bridge) == true)
    }

    @Test func announceWithoutBridgeCellDecodesNil() throws {
        let packet = AnnouncementPacket(
            nickname: "plain",
            noisePublicKey: Data(repeating: 1, count: 32),
            signingPublicKey: Data(repeating: 2, count: 32),
            directNeighbors: nil
        )
        let encoded = try #require(packet.encode())
        let decoded = try #require(AnnouncementPacket.decode(from: encoded))
        #expect(decoded.bridgeGeohash == nil)
    }

    @Test func announceRejectsOversizedBridgeCellAtEncode() throws {
        let packet = AnnouncementPacket(
            nickname: "gw",
            noisePublicKey: Data(repeating: 1, count: 32),
            signingPublicKey: Data(repeating: 2, count: 32),
            directNeighbors: nil,
            bridgeGeohash: String(repeating: "u", count: 13)
        )
        // Oversized cell is silently omitted, not a hard failure.
        let encoded = try #require(packet.encode())
        let decoded = try #require(AnnouncementPacket.decode(from: encoded))
        #expect(decoded.bridgeGeohash == nil)
    }

    // MARK: - BitchatMessage bridged flag
    // (Binary round-trip lives in BitFoundation's own tests —
    // `toBinaryPayload` is internal to the package.)

    @Test func bridgedFlagSurvivesCodableRoundTrip() throws {
        let message = BitchatMessage(
            sender: "far-friend",
            content: "hi",
            timestamp: Date(),
            isRelay: false,
            isBridged: true
        )
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(BitchatMessage.self, from: data)
        #expect(decoded.isBridged)
    }

    @Test func legacyJSONWithoutBridgedFlagDecodes() throws {
        let plain = BitchatMessage(
            sender: "old-client",
            content: "hi",
            timestamp: Date(),
            isRelay: false
        )
        let encoded = try JSONEncoder().encode(plain)
        var json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "isBridged")
        let decoded = try JSONDecoder().decode(BitchatMessage.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!decoded.isBridged)
    }

    @Test func bridgePeerIDParsesAndClassifies() {
        let peerID = PeerID(str: "bridge:deadbeefcafe0123")
        #expect(peerID.isBridge)
        #expect(peerID.bare == "deadbeefcafe0123")
        #expect(!peerID.isGeoChat)
    }
}

@Suite("Mesh message identity")
struct MeshMessageIdentityTests {
    @Test func stableIDIsDeterministicHex() {
        let id = MeshMessageIdentity.stableID(
            senderIDHex: "0011223344556677",
            timestampMs: 1_750_000_000_123,
            content: "hello mesh"
        )
        // Pinned vector: first 32 hex chars of
        // SHA256("0011223344556677|1750000000123|hello mesh"). Any drift
        // breaks cross-device (and cross-version) dedup.
        #expect(id == "b83f94d81dcdd1b0c0048f6645995dd4")
        #expect(id == MeshMessageIdentity.stableID(
            senderIDHex: "0011223344556677",
            timestampMs: 1_750_000_000_123,
            content: "hello mesh"
        ))
    }

    @Test func senderIDIsCaseInsensitive() {
        let lower = MeshMessageIdentity.stableID(senderIDHex: "aabbccdd00112233", timestampMs: 1, content: "x")
        let upper = MeshMessageIdentity.stableID(senderIDHex: "AABBCCDD00112233", timestampMs: 1, content: "x")
        #expect(lower == upper)
    }

    @Test func contentWhitespaceIsNormalized() {
        // Senders bridge the trimmed content while the radio carries the
        // original; both must derive the same key.
        let raw = MeshMessageIdentity.stableID(senderIDHex: "aabbccdd00112233", timestampMs: 1, content: "  hello mesh \n")
        let trimmed = MeshMessageIdentity.stableID(senderIDHex: "aabbccdd00112233", timestampMs: 1, content: "hello mesh")
        #expect(raw == trimmed)
    }

    @Test func anyCoordinateChangeChangesTheID() {
        let base = MeshMessageIdentity.stableID(senderIDHex: "aabbccdd00112233", timestampMs: 5, content: "x")
        #expect(base != MeshMessageIdentity.stableID(senderIDHex: "aabbccdd00112234", timestampMs: 5, content: "x"))
        #expect(base != MeshMessageIdentity.stableID(senderIDHex: "aabbccdd00112233", timestampMs: 6, content: "x"))
        #expect(base != MeshMessageIdentity.stableID(senderIDHex: "aabbccdd00112233", timestampMs: 5, content: "y"))
    }

    @Test func millisecondTimestampTruncatesLikeTheWire() {
        // Must match `BLEService.sendMessage`'s UInt64(seconds * 1000).
        #expect(MeshMessageIdentity.millisecondTimestamp(Date(timeIntervalSince1970: 1_000.9996)) == 1_000_999)
        #expect(MeshMessageIdentity.millisecondTimestamp(Date(timeIntervalSince1970: 1_000)) == 1_000_000)
    }
}
