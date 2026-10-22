import Foundation
import Testing
import BitFoundation
@testable import bitchat

/// Same immutable synthetic fixture as the Android tests: `wesh-nostr-embedded-v1.json` holds
/// the « bitchat1: » content a Wesh contact puts inside a Nostr gift wrap, for a private
/// message, a DELIVERED ack and a READ receipt. Both platforms decode it to the same fields
/// and encode the same bytes; only the 8 timestamp bytes (the send time) may differ.
struct NostrEmbeddedPayloadInteropTests {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            let name: String
            let noisePayloadType: UInt8
            let payloadHex: String
            let packetHex: String
            let embedded: String
        }

        let senderPeerID: String
        let recipientNoiseKeyHex: String
        let recipientPeerID: String
        let timestampMs: UInt64
        let messageID: String
        let content: String
        let cases: [Case]

        func named(_ name: String) throws -> Case {
            try #require(cases.first(where: { $0.name == name }))
        }
    }

    /// Version, type and TTL, then the 8-byte timestamp: the rest must match byte for byte.
    private static let timestampRange = 3..<11

    private func fixture() throws -> Fixture {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: MockKeychain.self)
        #endif
        let url = try #require(bundle.url(forResource: "wesh-nostr-embedded-v1", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func packetData(_ embedded: String) throws -> Data {
        #expect(embedded.hasPrefix("bitchat1:"))
        return try #require(Base64URLCoding.decode(String(embedded.dropFirst("bitchat1:".count))))
    }

    private func withoutTimestamp(_ data: Data) -> Data {
        var data = data
        data.replaceSubrange(Self.timestampRange, with: Data(count: Self.timestampRange.count))
        return data
    }

    @Test func recipientIDIsDerivedFromTheNoiseKey() throws {
        let f = try fixture()
        let noiseKey = try #require(Data(hexString: f.recipientNoiseKeyHex))
        #expect(PeerID(publicKey: noiseKey).id == f.recipientPeerID)
    }

    @Test func everyCaseDecodesToTheFixtureFields() throws {
        let f = try fixture()
        #expect(f.cases.map(\.name) == ["privateMessage", "delivered", "readReceipt"])
        for c in f.cases {
            let data = try packetData(c.embedded)
            #expect(data.hexEncodedString() == c.packetHex, "\(c.name)")
            let packet = try #require(BitchatPacket.from(data), "\(c.name)")
            #expect(packet.version == 1)
            #expect(packet.type == MessageType.noiseEncrypted.rawValue)
            #expect(packet.ttl == 7)
            #expect(packet.timestamp == f.timestampMs)
            #expect(packet.senderID.hexEncodedString() == f.senderPeerID)
            #expect(packet.recipientID?.hexEncodedString() == f.recipientPeerID)
            #expect(packet.signature == nil)
            #expect(packet.payload.hexEncodedString() == c.payloadHex, "\(c.name)")

            let payload = try #require(NoisePayload.decode(packet.payload), "\(c.name)")
            #expect(payload.type.rawValue == c.noisePayloadType)
            switch payload.type {
            case .privateMessage:
                let pm = try #require(PrivateMessagePacket.decode(from: payload.data))
                #expect(pm.messageID == f.messageID)
                #expect(pm.content == f.content)
            case .delivered, .readReceipt:
                #expect(String(data: payload.data, encoding: .utf8) == f.messageID)
            default:
                Issue.record("Unexpected payload type in \(c.name)")
            }
        }
    }

    /// The recipient may be given by its Noise key or its peer ID: same bytes either way.
    @Test func encodersProduceTheFixtureBytes() throws {
        let f = try fixture()
        let sender = PeerID(str: f.senderPeerID)
        for recipient in [PeerID(str: f.recipientNoiseKeyHex), PeerID(str: f.recipientPeerID)] {
            let encoded: [(String, String?)] = [
                ("privateMessage", NostrEmbeddedBitChat.encodePMForNostr(
                    content: f.content, messageID: f.messageID, recipientPeerID: recipient, senderPeerID: sender)),
                ("delivered", NostrEmbeddedBitChat.encodeAckForNostr(
                    type: .delivered, messageID: f.messageID, recipientPeerID: recipient, senderPeerID: sender)),
                ("readReceipt", NostrEmbeddedBitChat.encodeAckForNostr(
                    type: .readReceipt, messageID: f.messageID, recipientPeerID: recipient, senderPeerID: sender))
            ]
            for (name, embedded) in encoded {
                let expected = try packetData(f.named(name).embedded)
                let actual = try packetData(try #require(embedded, "\(name)"))
                #expect(withoutTimestamp(actual) == withoutTimestamp(expected), "\(name) for \(recipient.id)")
            }
        }
    }
}
