import BitFoundation
import CryptoKit
import Foundation
import Testing
@testable import bitchat

@Suite(.serialized)
struct BoardRetirementTests {
    @Test
    func signedBoardBroadcastCannotReachTheRadio() async throws {
        try await assertBoardIsNotForwarded(nonce: 1, directed: false, fragmented: false)
    }

    @Test
    func directedSourceRouteCannotRestoreBoardForwarding() async throws {
        try await assertBoardIsNotForwarded(nonce: 2, directed: true, fragmented: false)
    }

    @Test
    func boardFragmentsCannotReachTheRadio() async throws {
        try await assertBoardIsNotForwarded(nonce: 3, directed: false, fragmented: true)
    }

    @Test
    func retiredBoardSyncBitHasNoServableType() throws {
        let flags = try #require(SyncTypeFlags.decode(Data([0x00, 0x01])))
        #expect(flags.toMessageTypes().isEmpty)
        #expect(!flags.contains(.boardPost))
    }

    @Test
    func mixedSyncFlagsPreserveMessagesWithoutRestoringBoard() throws {
        let flags = try #require(SyncTypeFlags.decode(Data([0x02, 0x01])))
        #expect(flags.toMessageTypes() == [.message])
    }

    @Test
    func ordinaryAndExtendedSyncBitsRemainCompatible() throws {
        let flags = try #require(SyncTypeFlags.decode(Data([0x03, 0x02])))
        #expect(Set(flags.toMessageTypes()) == Set([.announce, .message, .prekeyBundle]))
        #expect(flags.toData() == Data([0x03, 0x02]))
    }

    @Test
    func publicMessagesStillReachTheRadio() async throws {
        let scheduler = BLEEngineManualScheduler()
        let service = makeService(scheduler: scheduler)
        defer { service.stopServices() }
        let outbound = BoardRetirementPacketRecorder()
        service._test_onOutboundPacket = outbound.record
        let sender = NoiseEncryptionService(keychain: MockKeychain())
        let peer = PeerID(publicKey: try #require(sender.getStaticPublicKeyData()))
        let packet = BitchatPacket(type: MessageType.message.rawValue,
            senderID: try #require(Data(hexString: peer.id)), recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1_000),
            payload: Data("Synthetic public relay control".utf8), signature: nil, ttl: 3)
        service._test_handlePacket(try #require(sender.signPacket(packet)), fromPeerID: peer,
            signingPublicKey: try #require(sender.getSigningPublicKeyData()))
        await service._test_drainNoiseMessagePipeline()
        scheduler.advance(by: 1)
        await service._test_drainNoiseMessagePipeline()
        #expect(outbound.packets.filter { $0.type == MessageType.message.rawValue }.count == 1)
    }

    @Test
    func aBoardOnlySyncRequestDoesNotBroadenIntoPublicHistory() throws {
        let local = PeerID(str: "0102030405060708")
        let remote = PeerID(str: "1020304050607080")
        let manager = GossipSyncManager(myPeerID: local, requestSyncManager: RequestSyncManager())
        let outbound = BoardRetirementPacketRecorder()
        manager.delegate = outbound
        let packet = BitchatPacket(type: MessageType.message.rawValue,
            senderID: try #require(Data(hexString: remote.id)), recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1_000),
            payload: Data("Synthetic history control".utf8), signature: nil, ttl: 3)
        manager.onPublicPacketSeen(packet)
        let flags = try #require(SyncTypeFlags.decode(Data([0x00, 0x01])))
        manager.handleRequestSync(from: remote, request: RequestSyncPacket(p: 4, m: 1, data: Data(), types: flags))
        manager.handleRequestSync(from: remote, request: RequestSyncPacket(p: 4, m: 1, data: Data(), types: .publicMessages))
        // This production queue fence covers both requests, so a missing response cannot
        // be mistaken for work that simply has not run yet.
        #expect(manager._messageCount(for: remote) == 1)
        #expect(outbound.packets.map(\.type) == [MessageType.message.rawValue])
    }

    @Test
    func boardFragmentsCannotEnterGossipSync() throws {
        let local = PeerID(str: "0102030405060708")
        let remote = PeerID(str: "1020304050607080")
        let manager = GossipSyncManager(myPeerID: local, requestSyncManager: RequestSyncManager())
        let outbound = BoardRetirementPacketRecorder()
        manager.delegate = outbound
        let board = BitchatPacket(type: MessageType.boardPost.rawValue,
            senderID: try #require(Data(hexString: remote.id)), recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1_000),
            payload: try BoardRetirementFixture.payload(nonce: 4), signature: nil, ttl: 7)
        let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
            for: BLEOutboundFragmentTransferRequest(packet: board, pad: false, maxChunk: 64, directedPeer: nil),
            defaultChunkSize: TransportConfig.bleDefaultFragmentSize, bleMaxMTU: 512))
        for fragment in plan.fragmentPackets { manager.onPublicPacketSeen(fragment) }
        let fragment = try #require(plan.fragmentPackets.first)
        var payload = fragment.payload
        payload[12] = MessageType.message.rawValue
        let publicFragment = BitchatPacket(type: fragment.type, senderID: fragment.senderID,
            recipientID: fragment.recipientID, timestamp: fragment.timestamp,
            payload: payload, signature: fragment.signature, ttl: fragment.ttl, version: fragment.version)
        manager.onPublicPacketSeen(publicFragment)
        manager.handleRequestSync(from: remote, request: RequestSyncPacket(p: 4, m: 1, data: Data(), types: .fragment))
        #expect(manager._messageCount(for: remote) == 0) // Same-queue fence, including sync.
        #expect(outbound.packets.map(\.payload) == [publicFragment.payload])
    }

    @Test
    func retiredOnlyFlagsStayPresentWhenDecodedFromARequest() throws {
        // A present retired-only TLV means no types, not the absent-TLV
        // compatibility default that would serve public history.
        var wire = RequestSyncPacket(p: 4, m: 1, data: Data()).encode()
        wire.append(contentsOf: [0x04, 0x00, 0x02, 0x00, 0x01])
        let request = try #require(RequestSyncPacket.decode(from: wire))
        let types = try #require(request.types)
        #expect(types.isEmpty)
    }

    private func assertBoardIsNotForwarded(nonce: UInt8, directed: Bool, fragmented: Bool) async throws {
        let scheduler = BLEEngineManualScheduler()
        let service = makeService(scheduler: scheduler)
        defer { service.stopServices() }
        let outbound = BoardRetirementPacketRecorder()
        service._test_onOutboundPacket = outbound.record
        let sender = NoiseEncryptionService(keychain: MockKeychain())
        let peer = PeerID(publicKey: try #require(sender.getStaticPublicKeyData()))
        var packet = BitchatPacket(type: MessageType.boardPost.rawValue,
            senderID: try #require(Data(hexString: peer.id)),
            recipientID: directed ? try #require(Data(hexString: "1020304050607080")) : nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1_000),
            payload: try BoardRetirementFixture.payload(nonce: nonce), signature: nil, ttl: 7, version: directed ? 2 : 1)
        if directed {
            packet.route = [try #require(Data(hexString: service.myPeerID.id))]
        }
        packet = try #require(sender.signPacket(packet))
        if fragmented {
            let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
                for: BLEOutboundFragmentTransferRequest(packet: packet, pad: false, maxChunk: 64, directedPeer: nil),
                defaultChunkSize: TransportConfig.bleDefaultFragmentSize, bleMaxMTU: 512))
            #expect(plan.totalFragments > 1)
            for fragment in plan.fragmentPackets { service._test_handlePacket(fragment, fromPeerID: peer) }
            await service._test_drainFragmentPipeline()
        } else {
            service._test_handlePacket(packet, fromPeerID: peer,
                signingPublicKey: try #require(sender.getSigningPublicKeyData()))
        }
        await service._test_drainNoiseMessagePipeline()
        scheduler.advance(by: 1)
        await service._test_drainNoiseMessagePipeline()
        #expect(outbound.packets.filter {
            $0.type == MessageType.boardPost.rawValue || $0.type == MessageType.fragment.rawValue
        }.isEmpty)
    }

    private func makeService(scheduler: BLEEngineManualScheduler) -> BLEService {
        let keychain = MockKeychain()
        return BLEService(keychain: keychain, idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain), initializeBluetoothManagers: false, engineScheduler: scheduler)
    }
}

/// Independent legacy wire fixture: keeping the frozen TLV/signing layout here
/// lets refusal tests outlive removal of the retired production Board codec.
enum BoardRetirementFixture {
    static func payload(nonce: UInt8) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x5A, count: 32))
        let postID = Data(repeating: nonce, count: 16)
        let content = Data("Synthetic retired board fixture".utf8)
        let nickname = Data("Synthetic author".utf8)
        let created = integer(UInt64(Date().timeIntervalSince1970 * 1_000))
        let expires = integer(UInt64(Date().timeIntervalSince1970 * 1_000) + 86_400_000)
        let publicKey = key.publicKey.rawRepresentation
        let domain = Data("bitchat-board-v1".utf8)
        var signed = Data([UInt8(domain.count)]) + domain + postID
        signed += length(Data()) + length(content) + publicKey + length(nickname) + created + expires + Data([1])
        let signature = try key.signature(for: signed)
        return tlv(1, Data([1])) + tlv(2, postID) + tlv(3, Data()) + tlv(4, content) +
            tlv(5, publicKey) + tlv(6, nickname) + tlv(7, created) + tlv(8, expires) + tlv(9, Data([1])) + tlv(10, signature)
    }

    private static func integer(_ value: UInt64) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func length(_ data: Data) -> Data {
        Data([UInt8(data.count >> 8), UInt8(data.count & 255)]) + data
    }

    private static func tlv(_ type: UInt8, _ data: Data) -> Data { Data([type]) + length(data) }
}

private final class BoardRetirementPacketRecorder: GossipSyncManager.Delegate {
    private let lock = NSLock()
    private var recorded: [BitchatPacket] = []
    var packets: [BitchatPacket] { lock.withLock { recorded } }
    func record(_ packet: BitchatPacket) { lock.withLock { recorded.append(packet) } }
    func sendPacket(_ packet: BitchatPacket) { record(packet) }
    func sendPacket(to peerID: PeerID, packet: BitchatPacket) { record(packet) }
    func signPacketForBroadcast(_ packet: BitchatPacket) -> BitchatPacket { packet }
    func getConnectedPeers() -> [PeerID] { [] }
}
