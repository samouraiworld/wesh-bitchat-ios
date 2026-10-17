import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct BLERetiredFragmentPolicyTests {
    private let local = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
    private let other = Data([0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
    private let broadcast = Data(repeating: 0xFF, count: 8)

    @Test
    func groupAndVoiceFragmentsAreRefusedWhateverTheRecipient() {
        for type in [MessageType.groupMessage, .voiceFrame] {
            for recipient in [nil, broadcast, local, other] as [Data?] {
                let packet = retiredFragmentTestPacket(originalType: type, recipient: recipient)
                #expect(BLERetiredFragmentPolicy.disposition(for: packet, localPeerIDData: local) == .refuse)
            }
        }
    }

    @Test
    func fileFragmentsAreRefusedUnlessForAnotherPeerWhichIsOnlyRelayed() {
        for recipient in [nil, broadcast, local] as [Data?] {
            let packet = retiredFragmentTestPacket(originalType: .fileTransfer, recipient: recipient)
            #expect(BLERetiredFragmentPolicy.disposition(for: packet, localPeerIDData: local) == .refuse)
        }
        let forAnotherPeer = retiredFragmentTestPacket(originalType: .fileTransfer, recipient: other)
        #expect(BLERetiredFragmentPolicy.disposition(for: forAnotherPeer, localPeerIDData: local) == .relayOnly)
    }

    @Test
    func fragmentsOfKeptTypesAndWholePacketsAreProcessed() {
        for type in [MessageType.message, .noiseEncrypted, .announce] {
            let packet = retiredFragmentTestPacket(originalType: type, recipient: nil)
            #expect(BLERetiredFragmentPolicy.disposition(for: packet, localPeerIDData: local) == .process)
        }
        let whole = BitchatPacket(
            type: MessageType.groupMessage.rawValue,
            senderID: other,
            recipientID: nil,
            timestamp: 0,
            payload: Data(repeating: 0x42, count: 64),
            signature: nil,
            ttl: 7
        )
        #expect(BLERetiredFragmentPolicy.disposition(for: whole, localPeerIDData: local) == .process)
    }

    @Test
    func reassembledRetiredTypesAreRecognized() {
        for type in [MessageType.groupMessage, .voiceFrame, .fileTransfer] {
            let packet = BitchatPacket(
                type: type.rawValue, senderID: other, recipientID: nil, timestamp: 0,
                payload: Data([0x01]), signature: nil, ttl: 0
            )
            #expect(BLERetiredFragmentPolicy.isRetired(reassembled: packet))
        }
        let message = BitchatPacket(
            type: MessageType.message.rawValue, senderID: other, recipientID: nil, timestamp: 0,
            payload: Data([0x01]), signature: nil, ttl: 0
        )
        #expect(!BLERetiredFragmentPolicy.isRetired(reassembled: message))
    }
}

/// A fragment as BitChat sends it: 8-byte ID, 2-byte index, 2-byte total,
/// 1-byte original type, then a chunk of the original packet.
func retiredFragmentTestPacket(
    originalType: MessageType,
    sender: Data = Data([0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC]),
    recipient: Data?,
    index: UInt16 = 0,
    total: UInt16 = 2,
    timestamp: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)
) -> BitchatPacket {
    var payload = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
    payload.append(contentsOf: [
        UInt8(index >> 8), UInt8(index & 0xFF),
        UInt8(total >> 8), UInt8(total & 0xFF),
        originalType.rawValue
    ])
    payload.append(Data(repeating: 0x42, count: 64))
    return BitchatPacket(
        type: MessageType.fragment.rawValue,
        senderID: sender,
        recipientID: recipient,
        timestamp: timestamp,
        payload: payload,
        signature: nil,
        ttl: 7
    )
}
