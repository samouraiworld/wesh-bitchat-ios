import BitFoundation
import Foundation
import Testing
@testable import bitchat

/// The ID of the placeholder line shown for a BitChat private file.
struct UnsupportedPrivateMediaTests {
    private let alice = PeerID(str: "0011223344556677")
    private let bob = PeerID(str: "8899aabbccddeeff")

    /// The BitChat file TLV: name, size, MIME type, content.
    private func filePayload(name: String?, content: Data = Data([0xFF, 0xD8, 0xFF, 0xD9])) -> Data {
        var payload = Data()
        if let name {
            let bytes = Data(name.utf8)
            payload.append(0x01)
            payload.append(contentsOf: [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)])
            payload.append(bytes)
        }
        payload.append(contentsOf: [0x02, 0x00, 0x04])
        payload.append(contentsOf: withUnsafeBytes(of: UInt32(content.count).bigEndian) { Array($0) })
        let mime = Data("image/jpeg".utf8)
        payload.append(0x03)
        payload.append(contentsOf: [0x00, UInt8(mime.count)])
        payload.append(mime)
        payload.append(0x04)
        payload.append(contentsOf: withUnsafeBytes(of: UInt32(content.count).bigEndian) { Array($0) })
        payload.append(content)
        return payload
    }

    @Test func entropyBearingNameGivesTheIDTheBitChatSenderDerives() {
        // Version-one vector shared with BitChat: its read receipt for the
        // placeholder names the media the sender knows.
        let payload = filePayload(name: "img_20260725_105708_1CC2760D-76AA-40C3-8013-C7FAA6C2EF99.jpg")
        #expect(UnsupportedPrivateMedia.messageID(payload: payload, senderPeerID: alice, recipientPeerID: bob)
            == "media-910bd42c65060ab76bb6406f220c4516")
        // Short and full Noise-key peer IDs converge.
        let fullSender = PeerID(hexData: Data(repeating: 0x11, count: 32))
        #expect(UnsupportedPrivateMedia.messageID(payload: payload, senderPeerID: fullSender, recipientPeerID: bob)
            == UnsupportedPrivateMedia.messageID(payload: payload, senderPeerID: fullSender.toShort(), recipientPeerID: bob))
    }

    @Test func sameFileCollapsesWhileDirectionAndContentSeparate() {
        for name in ["photo.jpg", "voice_0011223344556677.m4a", nil] as [String?] {
            let payload = filePayload(name: name)
            let id = UnsupportedPrivateMedia.messageID(payload: payload, senderPeerID: alice, recipientPeerID: bob)
            #expect(id.hasPrefix("media-") && id.count == 38)
            #expect(id == UnsupportedPrivateMedia.messageID(payload: payload, senderPeerID: alice, recipientPeerID: bob))
            #expect(id != UnsupportedPrivateMedia.messageID(payload: payload, senderPeerID: bob, recipientPeerID: alice))
        }
        let first = filePayload(name: "photo.jpg", content: Data([0xFF, 0xD8, 0x01]))
        let second = filePayload(name: "photo.jpg", content: Data([0xFF, 0xD8, 0x02]))
        #expect(UnsupportedPrivateMedia.messageID(payload: first, senderPeerID: alice, recipientPeerID: bob)
            != UnsupportedPrivateMedia.messageID(payload: second, senderPeerID: alice, recipientPeerID: bob))
    }

    @Test func malformedPayloadStillGetsAnID() {
        for payload in [Data(), Data([0x01, 0xFF]), Data([0x04, 0x00, 0x00, 0x00, 0x09, 0x01])] {
            #expect(UnsupportedPrivateMedia.messageID(payload: payload, senderPeerID: alice, recipientPeerID: bob)
                .hasPrefix("media-"))
        }
    }
}
