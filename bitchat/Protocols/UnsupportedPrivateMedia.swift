import BitFoundation
import Foundation

/// Wesh has no media. A BitChat private file (`NoisePayloadType.privateFile`)
/// from an admitted contact becomes one placeholder line, and nothing of the
/// file is kept.
///
/// The line takes the ID a BitChat sender derives for the same file from
/// fields already on the wire (sender, recipient and an entropy-bearing file
/// name), so the sender's retries collapse into that one line. No delivery
/// or read receipt is ever sent for it: the file was never received. Files
/// without such a name (Android, older iOS) get an ID derived from their
/// bytes, which still collapses a byte-identical resend.
enum UnsupportedPrivateMedia {
    private static let domain = Data("bitchat-private-media-message-v1".utf8)
    private static let payloadDomain = Data("wesh-unsupported-private-media-v1".utf8)
    private static let idPrefix = "media-"
    private static let digestHexLength = 32
    /// TLV tags of the BitChat file payload: name, then content.
    private static let fileNameTag: UInt8 = 0x01
    private static let contentTag: UInt8 = 0x04

    /// True for the ID of a placeholder line, which gets no read receipt.
    static func isPlaceholderID(_ messageID: String) -> Bool {
        messageID.hasPrefix(idPrefix)
    }

    static func messageID(payload: Data, senderPeerID: PeerID, recipientPeerID: PeerID) -> String {
        let sender = Data(senderPeerID.toShort().bare.utf8)
        let recipient = Data(recipientPeerID.toShort().bare.utf8)
        if let leafName = entropyBearingFileName(in: payload),
           let id = digestID(domain: domain, fields: [sender, recipient, Data(leafName.utf8)]) {
            return id
        }
        return digestID(domain: payloadDomain, fields: [sender, recipient, payload])
            ?? "\(idPrefix)\(payload.sha256Hex().prefix(digestHexLength))"
    }

    /// The file name, when it carries the UUID or voice-burst entropy BitChat
    /// relies on for a stable ID.
    private static func entropyBearingFileName(in payload: Data) -> String? {
        guard let fileName = fileName(in: payload), !fileName.isEmpty else { return nil }
        let leafName = (fileName as NSString).lastPathComponent
        guard leafName == fileName else { return nil }

        let path = leafName as NSString
        let stem = path.deletingPathExtension
        let fileExtension = path.pathExtension.lowercased()
        switch true {
        case stem.hasPrefix("img_"):
            guard fileExtension == "jpg" || fileExtension == "jpeg" else { return nil }
        case stem.hasPrefix("voice_"):
            guard fileExtension == "m4a" else { return nil }
        default:
            return nil
        }
        let entropyToken = stem.split(separator: "_").last.map(String.init)
        let hasUUIDEntropy = entropyToken.flatMap(UUID.init(uuidString:)) != nil
        let voiceBurstID = stem.hasPrefix("voice_")
            ? String(stem.dropFirst("voice_".count))
            : ""
        let hasBurstEntropy = voiceBurstID.count == 16
            && voiceBurstID.allSatisfy(\.isHexDigit)
        return hasUUIDEntropy || hasBurstEntropy ? leafName : nil
    }

    /// Reads only the name TLV. Content uses a 4-byte length (2 bytes in
    /// legacy encodings); every other field uses 2 bytes.
    private static func fileName(in payload: Data) -> String? {
        var cursor = payload.startIndex
        let end = payload.endIndex

        func readLength(bytes: Int) -> Int? {
            guard payload.distance(from: cursor, to: end) >= bytes else { return nil }
            var value = 0
            for _ in 0..<bytes {
                value = (value << 8) | Int(payload[cursor])
                cursor = payload.index(after: cursor)
            }
            return value
        }

        while cursor < end {
            let tag = payload[cursor]
            cursor = payload.index(after: cursor)
            let length: Int?
            if tag == contentTag {
                let snapshot = cursor
                if let canonical = readLength(bytes: 4),
                   canonical <= payload.distance(from: cursor, to: end) {
                    length = canonical
                } else {
                    cursor = snapshot
                    length = readLength(bytes: 2)
                }
            } else {
                length = readLength(bytes: 2)
            }
            guard let length, payload.distance(from: cursor, to: end) >= length else { return nil }
            let valueStart = cursor
            cursor = payload.index(cursor, offsetBy: length)
            if tag == fileNameTag {
                return String(data: Data(payload[valueStart..<cursor]), encoding: .utf8)
            }
        }
        return nil
    }

    private static func digestID(domain: Data, fields: [Data]) -> String? {
        var input = domain
        for field in fields {
            guard let length = UInt32(exactly: field.count) else { return nil }
            var bigEndianLength = length.bigEndian
            withUnsafeBytes(of: &bigEndianLength) {
                input.append(contentsOf: $0)
            }
            input.append(field)
        }
        return "\(idPrefix)\(input.sha256Hex().prefix(digestHexLength))"
    }
}
