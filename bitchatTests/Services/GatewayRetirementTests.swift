import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite(.serialized)
struct GatewayRetirementTests {
    @Test(arguments: [UInt8(2), UInt8(4)])
    func signedCarrierBroadcastCannotReachRadio(direction: UInt8) async throws {
        try await assertCarrierIsNotForwarded(direction: direction, sourceRoute: false, fragmented: false)
    }

    @Test(arguments: [false, true])
    func directedCarrierCannotReachRadio(sourceRoute: Bool) async throws {
        try await assertCarrierIsNotForwarded(direction: 1, sourceRoute: sourceRoute, fragmented: false)
    }

    @Test(arguments: [false, true])
    func carrierFragmentTrainCannotReachRadio(directed: Bool) async throws {
        try await assertCarrierIsNotForwarded(direction: directed ? 3 : 4, sourceRoute: directed, fragmented: true)
    }

    @Test(arguments: [false, true], [false, true])
    func carrierIsRefusedBeforeIngressAccounting(fragmented: Bool, directedToUs: Bool) async throws {
        let scheduler = BLEEngineManualScheduler()
        let service = makeService(scheduler: scheduler)
        defer { service.stopServices() }
        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let packet = try carrier(signer: signer, direction: directedToUs ? 1 : 2,
            recipient: directedToUs ? service.myPeerID : nil)
        let first: BitchatPacket
        if fragmented {
            let carrierFragments = try fragments(of: packet)
            first = try #require(carrierFragments.first)
        } else {
            first = packet
        }
        let peer = PeerID(hexData: packet.senderID)
        let link = "synthetic-carrier-ingress"
        service._test_bindCentral(link, to: peer)

        service._test_ingestFrame(first, link: .central(link))
        await drain(service, scheduler: scheduler)

        // This exact frame remains unseen when retirement precedes attribution.
        // Reusing the real accounting operation avoids observing a test-only counter.
        #expect(service._test_recordIngressIfNew(packet: first, linkID: link))
    }

    @Test
    func validSelfAuthoredSyncReplayCannotRestoreCarrierIngress() async throws {
        let scheduler = BLEEngineManualScheduler()
        let service = makeService(scheduler: scheduler)
        defer { service.stopServices() }
        let responder = PeerID(str: "1020304050607080")
        let link = "synthetic-carrier-sync-responder"
        service._test_bindCentral(link, to: responder)
        // Open the real manager's response window without starting Bluetooth,
        // timers or a network request. Only synthetic test state is inspected.
        let requests = try #require(Mirror(reflecting: service).children.first {
            $0.label == "requestSyncManager"
        }?.value as? RequestSyncManager)
        requests.registerRequest(to: responder)
        #expect(requests.isValidResponse(from: responder, isRSR: true))
        let payload = try GatewayRetirementFixture.payload(direction: 2)
        var packet = BitchatPacket(type: MessageType.nostrCarrier.rawValue,
            senderID: try #require(Data(hexString: service.myPeerID.id)), recipientID: nil,
            timestamp: nowMilliseconds(), payload: payload, signature: nil, ttl: 0, isRSR: true)
        packet = service.signPacketForBroadcast(packet)
        try #require(packet.signature)

        service._test_ingestFrame(packet, link: .central(link))
        await drain(service, scheduler: scheduler)

        #expect(service._test_recordIngressIfNew(packet: packet, linkID: link))
    }

    @Test
    func gossipCannotRetainCarrierFragmentsButStillServesPublicFragments() throws {
        let local = PeerID(str: "0102030405060708")
        let remote = PeerID(str: "1020304050607080")
        let manager = GossipSyncManager(myPeerID: local, requestSyncManager: RequestSyncManager())
        let outbound = GatewayRetirementPacketRecorder()
        manager.delegate = outbound
        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let packet = try carrier(signer: signer, direction: 4)
        let carrierFragments = try fragments(of: packet)
        for fragment in carrierFragments { manager.onPublicPacketSeen(fragment) }
        let first = try #require(carrierFragments.first)
        var publicPayload = first.payload
        publicPayload[12] = MessageType.message.rawValue
        let publicFragment = BitchatPacket(type: first.type, senderID: first.senderID,
            recipientID: nil, timestamp: first.timestamp, payload: publicPayload,
            signature: first.signature, ttl: first.ttl, version: first.version)
        manager.onPublicPacketSeen(publicFragment)
        manager.handleRequestSync(from: remote,
            request: RequestSyncPacket(p: 4, m: 1, data: Data(), types: .fragment))

        // The production queue fence includes both insertion and the sync reply.
        #expect(manager._messageCount(for: remote) == 0)
        #expect(outbound.packets.map(\.payload) == [publicFragment.payload])
    }

    @Test(arguments: [false, true])
    func genericOutboundPathCannotRestoreCarrier(directed: Bool) async throws {
        let scheduler = BLEEngineManualScheduler()
        let service = makeService(scheduler: scheduler)
        defer { service.stopServices() }
        let outbound = GatewayRetirementPacketRecorder()
        service._test_onOutboundPacket = outbound.record
        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let destination = PeerID(str: "1020304050607080")
        let packet = try carrier(signer: signer, direction: directed ? 1 : 2,
            recipient: directed ? destination : nil)

        if directed { service.sendPacket(to: destination, packet: packet) }
        else { service.sendPacket(packet) }
        await drain(service, scheduler: scheduler)

        #expect(outbound.packets.filter { $0.type == MessageType.nostrCarrier.rawValue }.isEmpty)
    }

    @Test
    func ordinarySignedCourierStillRelaysTowardItsRecipient() async throws {
        let scheduler = BLEEngineManualScheduler()
        let service = makeService(scheduler: scheduler)
        defer { service.stopServices() }
        let outbound = GatewayRetirementPacketRecorder()
        service._test_onOutboundPacket = outbound.record
        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let recipient = NoiseEncryptionService(keychain: MockKeychain())
        let recipientKey = try #require(recipient.getStaticPublicKeyData())
        let ciphertext = try signer.sealCourierPayload(Data("Synthetic courier control".utf8),
            recipientStaticKey: recipientKey)
        let envelope = CourierEnvelope(recipientTag: CourierEnvelope.recipientTag(
            noiseStaticKey: recipientKey, epochDay: CourierEnvelope.epochDay(for: Date())),
            expiry: nowMilliseconds() + 3_600_000, ciphertext: ciphertext)
        let sender = PeerID(publicKey: try #require(signer.getStaticPublicKeyData()))
        let packet = BitchatPacket(type: MessageType.courierEnvelope.rawValue,
            senderID: try #require(Data(hexString: sender.id)),
            recipientID: try #require(Data(hexString: PeerID(publicKey: recipientKey).id)),
            timestamp: nowMilliseconds(), payload: try #require(envelope.encode()), signature: nil, ttl: 3)
        let signed = try #require(signer.signPacket(packet))

        let link = "synthetic-ordinary-courier-ingress"
        service._test_bindCentral(link, to: sender)
        service._test_ingestFrame(signed, link: .central(link))
        await drain(service, scheduler: scheduler)

        #expect(!service._test_recordIngressIfNew(packet: signed, linkID: link))
        let relayed = outbound.packets.filter { $0.type == MessageType.courierEnvelope.rawValue }
        #expect(relayed.count == 1)
        #expect(relayed.first?.payload == signed.payload)
        #expect(relayed.first?.ttl == 2)
    }

    @Test
    func signedLegacyFixtureHasValidOuterAndInnerSignatures() throws {
        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let packet = try carrier(signer: signer, direction: 2)
        #expect(signer.verifyPacketSignature(packet,
            publicKey: try #require(signer.getSigningPublicKeyData())))
        // The frozen layout outlives removal of the production carrier codec.
        let eventLength = Int(packet.payload[14]) << 8 | Int(packet.payload[15])
        try #require(packet.payload.count == 16 + eventLength)
        let eventData = packet.payload.subdata(in: 16..<(16 + eventLength))
        let object = try #require(JSONSerialization.jsonObject(with: eventData) as? [String: Any])
        let event = try NostrEvent(from: object)
        #expect(event.isValidSignature())
    }

    @Test
    func ordinaryAnnounceKeepsPrekeysWithoutGatewayOrVouchRoles() async throws {
        let scheduler = BLEEngineManualScheduler()
        let service = makeService(scheduler: scheduler)
        defer { service.stopServices() }
        let outbound = GatewayRetirementPacketRecorder()
        service._test_onOutboundPacket = outbound.record

        service._test_forceAnnounce()
        await drain(service, scheduler: scheduler)

        let packet = try #require(outbound.packets.first { $0.type == MessageType.announce.rawValue })
        let announce = try #require(AnnouncementPacket.decode(from: packet.payload))
        let capabilities = try #require(announce.capabilities)
        #expect(capabilities.contains(.prekeys))
        #expect(!capabilities.contains(.vouch))
        #expect(!capabilities.contains(.gateway))
        #expect(!capabilities.contains(.bridge))
        #expect(announce.bridgeGeohash == nil)
    }

    private func assertCarrierIsNotForwarded(direction: UInt8, sourceRoute: Bool, fragmented: Bool) async throws {
        let scheduler = BLEEngineManualScheduler()
        let service = makeService(scheduler: scheduler)
        defer { service.stopServices() }
        let outbound = GatewayRetirementPacketRecorder()
        service._test_onOutboundPacket = outbound.record
        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let recipient = direction == 1 || direction == 3 ? PeerID(str: "1020304050607080") : nil
        let packet = try carrier(signer: signer, direction: direction, recipient: recipient,
            route: sourceRoute ? [try #require(Data(hexString: service.myPeerID.id))] : nil)
        let sender = PeerID(hexData: packet.senderID)
        if sourceRoute, let recipient {
            // The final source-route hop must be reachable, otherwise the
            // policy falls back to flooding and would not exercise routing.
            service._test_seedConnectedPeer(recipient, nickname: "Synthetic destination")
        }
        if fragmented {
            for fragment in try fragments(of: packet) {
                service._test_handlePacket(fragment, fromPeerID: sender)
            }
        } else {
            service._test_handlePacket(packet, fromPeerID: sender,
                signingPublicKey: try #require(signer.getSigningPublicKeyData()))
        }
        await drain(service, scheduler: scheduler)

        #expect(outbound.packets.filter {
            $0.type == MessageType.nostrCarrier.rawValue || $0.type == MessageType.fragment.rawValue
        }.isEmpty)
    }

    private func carrier(signer: NoiseEncryptionService, direction: UInt8,
                         recipient: PeerID? = nil, route: [Data]? = nil) throws -> BitchatPacket {
        let sender = PeerID(publicKey: try #require(signer.getStaticPublicKeyData()))
        let packet = BitchatPacket(type: MessageType.nostrCarrier.rawValue,
            senderID: try #require(Data(hexString: sender.id)),
            recipientID: recipient.flatMap { Data(hexString: $0.id) },
            timestamp: nowMilliseconds(), payload: try GatewayRetirementFixture.payload(direction: direction),
            signature: nil, ttl: 3, version: route == nil ? 1 : 2, route: route)
        return try #require(signer.signPacket(packet))
    }

    private func fragments(of packet: BitchatPacket) throws -> [BitchatPacket] {
        let plan = try #require(BLEOutboundFragmentPlanner.makePlan(for:
            BLEOutboundFragmentTransferRequest(packet: packet, pad: false, maxChunk: 64, directedPeer: nil),
            defaultChunkSize: TransportConfig.bleDefaultFragmentSize, bleMaxMTU: 512,
            fragmentID: Data(repeating: 0xA7, count: 8)))
        try #require(plan.totalFragments > 1)
        return plan.fragmentPackets
    }

    private func makeService(scheduler: BLEEngineManualScheduler) -> BLEService {
        let keychain = MockKeychain()
        let service = BLEService(keychain: keychain, idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
            identityManager: MockIdentityManager(keychain), initializeBluetoothManagers: false, engineScheduler: scheduler)
        service.courierStore = CourierStore(persistsToDisk: false)
        return service
    }

    private func drain(_ service: BLEService, scheduler: BLEEngineManualScheduler) async {
        await service._test_drainFragmentPipeline()
        await service._test_drainNoiseMessagePipeline()
        scheduler.advance(by: 1)
        await service._test_drainNoiseMessagePipeline()
    }

    private func nowMilliseconds() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1_000) }
}

/// Frozen legacy TLVs: direction, synthetic rendezvous cell, signed event JSON.
private enum GatewayRetirementFixture {
    static func payload(direction: UInt8) throws -> Data {
        let identity = try NostrIdentity.generate()
        let event = try NostrEvent(pubkey: identity.publicKeyHex, createdAt: Date(), kind: .ephemeralEvent,
            tags: [["g", "000000"]], content: "Synthetic retired carrier fixture")
            .sign(with: identity.schnorrSigningKey())
        return tlv(1, Data([direction])) + tlv(2, Data("000000".utf8)) + tlv(3, Data(try event.jsonString().utf8))
    }

    private static func tlv(_ type: UInt8, _ value: Data) -> Data {
        Data([type, UInt8(value.count >> 8), UInt8(value.count & 255)]) + value
    }
}

private final class GatewayRetirementPacketRecorder: GossipSyncManager.Delegate {
    private let lock = NSLock()
    private var recorded: [BitchatPacket] = []
    var packets: [BitchatPacket] { lock.withLock { recorded } }
    func record(_ packet: BitchatPacket) { lock.withLock { recorded.append(packet) } }
    func sendPacket(_ packet: BitchatPacket) { record(packet) }
    func sendPacket(to peerID: PeerID, packet: BitchatPacket) { record(packet) }
    func signPacketForBroadcast(_ packet: BitchatPacket) -> BitchatPacket { packet }
    func getConnectedPeers() -> [PeerID] { [] }
}
