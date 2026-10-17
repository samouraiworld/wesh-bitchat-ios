import Foundation
import Testing
import BitFoundation
@testable import bitchat

struct BLENoisePayloadFactoryTests {
    @Test
    func privateMessagePayloadPrefixesTLVWithNoiseType() throws {
        let payload = try #require(BLENoisePayloadFactory.privateMessage(content: "secret", messageID: "pm-1"))

        #expect(payload.first == NoisePayloadType.privateMessage.rawValue)

        let packet = try #require(PrivateMessagePacket.decode(from: Data(payload.dropFirst())))
        #expect(packet.messageID == "pm-1")
        #expect(packet.content == "secret")
    }

    @Test
    func receiptPayloadsUseMessageIDBytes() {
        let read = BLENoisePayloadFactory.readReceipt(originalMessageID: "read-id")
        let delivered = BLENoisePayloadFactory.delivered(messageID: "delivered-id")

        #expect(read.first == NoisePayloadType.readReceipt.rawValue)
        #expect(String(data: Data(read.dropFirst()), encoding: .utf8) == "read-id")
        #expect(delivered.first == NoisePayloadType.delivered.rawValue)
        #expect(String(data: Data(delivered.dropFirst()), encoding: .utf8) == "delivered-id")
    }

    @Test
    func typedPayloadKeepsOpaqueDataUnchanged() {
        let payload = BLENoisePayloadFactory.typedPayload(.verifyChallenge, payload: Data([0xCA, 0xFE]))

        #expect(payload == Data([NoisePayloadType.verifyChallenge.rawValue, 0xCA, 0xFE]))
    }

    @Test
    func androidB7f0b33PrivateFileStillDecodesAsAPrivateFile() throws {
        // Runtime-emitted by Android commit b7f0b33d from
        // BitchatFilePacket("a.txt", 3, "text/plain", [01, 02, 03]) and
        // NoisePayload(type = FILE_TRANSFER, data = file.encode()).encode().
        // Wesh keeps none of the file but must still recognize the type, so
        // an admitted contact's file becomes a placeholder line.
        let fixtureHex = "20010005612e7478740200040000000303000a746578742f706c61696e0400000003010203"
        let fixture = try #require(Data(hexString: fixtureHex))

        let typed = try #require(NoisePayload.decode(fixture))
        #expect(typed.type == .privateFile)
        let id = UnsupportedPrivateMedia.messageID(
            payload: typed.data,
            senderPeerID: PeerID(str: "0011223344556677"),
            recipientPeerID: PeerID(str: "8899aabbccddeeff")
        )
        #expect(id.hasPrefix("media-"))
    }

    @Test
    func prereleasePrivateFileTypeCanonicalizesOnDecode() throws {
        let encoded = Data([NoisePayloadType.prereleasePrivateFileRawValue, 0xCA, 0xFE])
        let decoded = try #require(NoisePayload.decode(encoded))

        #expect(decoded.type == .privateFile)
        #expect(decoded.data == Data([0xCA, 0xFE]))
        #expect(decoded.encode().first == 0x20)
    }

    @Test
    func authenticatedPeerStateUsesPermanent0x21Type() throws {
        let state = AuthenticatedPeerStatePacket(
            capabilities: .privateMedia,
            signingPublicKey: Data(repeating: 0x77, count: 32)
        )
        let encoded = try #require(BLENoisePayloadFactory.authenticatedPeerState(state))

        #expect(encoded.first == 0x21)
        #expect(AuthenticatedPeerStatePacket.decode(from: Data(encoded.dropFirst())) == state)
    }
}
