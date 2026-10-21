/// Decode-time ceilings for BitChat file transfers. Wesh sends no media, but
/// a peer's file (0x22, or private media inside Noise) must still be bounded
/// before it is dropped.
public enum FileTransferLimits {
    /// Absolute ceiling enforced for any file payload (voice, image, other).
    public static let maxPayloadBytes: Int = 1 * 1024 * 1024 // 1 MiB
    /// Worst-case size once TLV metadata and binary packet framing are included for the largest payloads.
    public static let maxFramedFileBytes: Int = {
        let maxMetadataBytes = Int(UInt16.max) * 2 // fileName + mimeType TLVs
        let tlvEnvelopeOverhead = 18 + maxMetadataBytes // TLV tags + lengths + metadata bytes
        let binaryEnvelopeOverhead = BinaryProtocol.v2HeaderSize
            + BinaryProtocol.senderIDSize
            + BinaryProtocol.recipientIDSize
            + BinaryProtocol.signatureSize
        return maxPayloadBytes + tlvEnvelopeOverhead + binaryEnvelopeOverhead
    }()
}
