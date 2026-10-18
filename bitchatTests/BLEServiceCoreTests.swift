//
// BLEServiceCoreTests.swift
// bitchatTests
//
// Focused BLEService tests for packet handling behavior.
//

import Testing
import Foundation
import CoreBluetooth
import BitFoundation
@testable import bitchat

struct BLEServiceCoreTests {
    @Test
    func gossipDelegateResumesAfterNormalStopButOldDelegateCannotCrossPanic() {
        let ble = makeService()
        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record
        let delegate = ble._test_makeGossipDelegate()
        let packet = BitchatPacket(type: MessageType.requestSync.rawValue,
            senderID: Data(hexString: ble.myPeerID.id) ?? Data(), recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1_000),
            payload: Data([1]), signature: nil, ttl: 0)
        delegate.sendPacket(packet)
        #expect(outbound.count(ofType: .requestSync) == 1)
        ble.stopServices()
        delegate.sendPacket(packet)
        #expect(outbound.count(ofType: .requestSync) == 1)
        ble.startServices()
        delegate.sendPacket(packet)
        #expect(outbound.count(ofType: .requestSync) == 2)
        #expect(delegate.signPacketForBroadcast(packet).signature != nil)
        ble.suspendForPanicReset()
        ble.completePanicReset(restartServices: true)
        delegate.sendPacket(packet)
        delegate.sendPacket(to: PeerID(str: "1020304050607080"), packet: packet)
        #expect(outbound.count(ofType: .requestSync) == 2)
        #expect(delegate.signPacketForBroadcast(packet).signature == nil)
        #expect(delegate.getConnectedPeers().isEmpty)
        let currentDelegate = ble._test_makeGossipDelegate()
        currentDelegate.sendPacket(packet)
        #expect(outbound.count(ofType: .requestSync) == 3)
        #expect(currentDelegate.signPacketForBroadcast(packet).signature != nil)
    }

    @Test @MainActor
    func unavailableIdentityEventsArriveOutsideTheClosedMessageIngressAndRetryFailure() async {
        let storage = MockKeychain()
        storage.simulatedReadError = .deviceLocked
        let ble = makeService(keychain: storage)
        let events = NoiseIdentityEventRecorder()
        ble.eventDelegate = events
        #expect(ble.noiseIdentityAvailability == .storageUnavailable)
        #expect(!ble._test_isPanicIngressOpen)
        #expect(await TestHelpers.waitUntil({ events.states.count >= 1 }, timeout: TestConstants.longTimeout))
        #expect(events.states.last == .storageUnavailable)
        let count = events.states.count
        ble.recoverNoiseIdentityForForeground()
        #expect(await TestHelpers.waitUntil({ events.states.count > count }, timeout: TestConstants.longTimeout))
        #expect(events.states.last == .storageUnavailable)
        #expect(storage.identitySaveCount == 0)
    }

    @Test @MainActor
    func failedPendingJournalDeletionLeavesOldIdentityInvalidatedUntilAnotherPanic() async {
        let storage = MockKeychain()
        let ble = makeService(keychain: storage)
        let original = ble.noiseIdentityFingerprint()
        let saves = storage.identitySaveCount
        storage.identityDeleteFault = { key, _ in key == "noiseIdentityPending.v1" ? false : nil }
        ble.suspendForPanicReset()
        ble.resetIdentityForPanic(currentNickname: "Synthetic", restartServices: false)
        ble.completePanicReset(restartServices: false)
        #expect(ble.noiseIdentityAvailability == .invalidated)
        #expect(ble.noiseStaticPublicKeyData().isEmpty)
        #expect(storage.identitySaveCount == saves)
        let restored = await withCheckedContinuation { continuation in
            ble.retryNoiseIdentityRecovery { result in continuation.resume(returning: result) }
        }
        #expect(!restored)
        #expect(storage.identitySaveCount == saves)
        #expect(!ble.isTransportTrafficAllowed)

        storage.identityDeleteFault = nil
        ble.suspendForPanicReset()
        ble.resetIdentityForPanic(currentNickname: "Synthetic", restartServices: false)
        ble.completePanicReset(restartServices: false)
        #expect(ble.noiseIdentityAvailability == .available)
        #expect(!ble.noiseIdentityFingerprint().isEmpty)
        #expect(ble.noiseIdentityFingerprint() != original)
        #expect(!ble.areServicesRequested)
        #expect(!ble.isTransportTrafficAllowed)
    }

    @Test
    func explicitStopDuringProtectedStorageRecoveryPreventsDeferredStartup() async {
        let storage = MockKeychain()
        storage.simulatedReadError = .deviceLocked
        let scheduler = BLEEngineManualScheduler()
        let ble = makeService(keychain: storage, engineScheduler: scheduler)
        let gate = NoiseIdentityStorageGate()
        defer { gate.release() }
        storage.simulatedReadError = nil
        storage.identitySaveFault = { key, _, _ in
            if key == "noiseIdentityPending.v1" { gate.block() }
            return nil
        }
        let startup = TestHelpers.onThread { ble.startServices() }
        #expect(await TestHelpers.waitUntil({ gate.hasBlocked }, timeout: TestConstants.longTimeout))
        let stopping = TestHelpers.onThread { ble.stopServices() }
        #expect(await TestHelpers.waitUntil({ !ble.areServicesRequested }, timeout: TestConstants.longTimeout))
        gate.release()
        await startup.value
        await stopping.value
        #expect(ble.noiseIdentityAvailability == .available)
        #expect(!ble.isTransportTrafficAllowed)
        #expect(scheduler.pendingCount == 0)
        #expect(ble.centralManager == nil && ble.peripheralManager == nil)
    }


    @Test
    func unavailableNoiseBlocksRadioIdentityAndOutboundPackets() async {
        let keychain = MockKeychain()
        keychain.simulatedReadError = .deviceLocked
        let ble = makeService(keychain: keychain)
        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record
        ble.startServices()
        ble.sendAnnounce(forceSend: true)
        ble.sendMessage("synthetic unavailable send")
        ble.broadcastNostrCarrier(Data([1]))
        await ble._test_drainNoiseMessagePipeline()

        #expect(!ble.isTransportIdentityAvailable)
        #expect(ble.noiseIdentityFingerprint().isEmpty)
        #expect(ble.noiseStaticPublicKeyData().isEmpty)
        #expect(ble.noiseSigningPublicKeyData().isEmpty)
        #expect(ble.myPeerID.id.isEmpty)
        #expect(ble.radioIsPanicSuspended())
        #expect(ble.centralManager == nil)
        #expect(ble.peripheralManager == nil)
        #expect(ble.getCurrentBluetoothState() == .unknown)
        #expect(outbound.snapshot().isEmpty)
        #expect(keychain.identitySaveCount == 0)
    }

    @Test
    func foregroundRecoveryPublishesOriginalPersistedIdentity() {
        let keychain = MockKeychain()
        let original = NoiseEncryptionService(keychain: keychain)
        let expectedKey = original.getStaticPublicKeyData()!
        let expectedFingerprint = original.getIdentityFingerprint()!
        let saves = keychain.identitySaveCount
        keychain.simulatedReadError = .deviceLocked
        let ble = makeService(keychain: keychain)
        #expect(ble.noiseStaticPublicKeyData().isEmpty)

        keychain.simulatedReadError = nil
        ble.recoverNoiseIdentityForForeground()
        #expect(ble.isTransportIdentityAvailable)
        #expect(ble.noiseStaticPublicKeyData() == expectedKey)
        #expect(ble.noiseIdentityFingerprint() == expectedFingerprint)
        #expect(ble.myPeerID == PeerID(publicKey: expectedKey))
        #expect(keychain.identitySaveCount == saves)
    }

    @Test
    func foregroundRecoveryDoesNotUndoExplicitStop() {
        let keychain = MockKeychain()
        keychain.simulatedReadError = .deviceLocked
        let scheduler = BLEEngineManualScheduler()
        let ble = makeService(keychain: keychain, engineScheduler: scheduler)
        ble.startServices()
        ble.stopServices()
        keychain.simulatedReadError = nil
        ble.recoverNoiseIdentityForForeground()

        #expect(!ble.areServicesRequested)
        #expect(!ble.isTransportIdentityAvailable)
        #expect(keychain.identitySaveCount == 0)
        #expect(scheduler.pendingCount == 0)
        ble.startServices()
        #expect(ble.areServicesRequested)
        #expect(ble.isTransportIdentityAvailable)
        #expect(keychain.identitySaveCount == 3)
    }


    @Test
    func explicitStopRejectsQueuedAndNewOutboundTrafficUntilRestart() async {
        let scheduler = BLEEngineManualScheduler()
        let ble = makeService(engineScheduler: scheduler)
        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record
        ble.startServices()
        ble.stopServices()
        ble.sendMessage("synthetic stopped message")
        ble.sendAnnounce(forceSend: true)
        ble.broadcastNostrCarrier(Data([1]))
        scheduler.advance(by: TransportConfig.bleInitialAnnounceDelaySeconds + 1)
        await ble._test_drainNoiseMessagePipeline()
        #expect(ble.isTransportIdentityAvailable)
        #expect(!ble.isTransportTrafficAllowed)
        #expect(outbound.snapshot().isEmpty)

        ble.startServices()
        ble.sendMessage("synthetic restarted message")
        await ble._test_drainNoiseMessagePipeline()
        #expect(ble.isTransportTrafficAllowed)
        #expect(outbound.count(ofType: .message) == 1)
    }

    @Test
    func restartDoesNotReviveAnOldDelayedInitialAnnouncement() async {
        let scheduler = BLEEngineManualScheduler()
        let ble = makeService(engineScheduler: scheduler)
        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record
        let delay = TransportConfig.bleInitialAnnounceDelaySeconds
        ble.startServices()
        scheduler.advance(by: delay / 2)
        ble.stopServices()
        ble.startServices()
        scheduler.advance(by: delay / 2 + 0.01)
        await ble._test_drainNoiseMessagePipeline()
        #expect(outbound.count(ofType: .announce) == 0)
        scheduler.advance(by: delay / 2)
        await ble._test_drainNoiseMessagePipeline()
        #expect(outbound.count(ofType: .announce) == 1)
    }

    @Test
    func panicCompletionWithoutRestartKeepsCallbacksAndForegroundStopped() async {
        let scheduler = BLEEngineManualScheduler()
        let ble = makeService(engineScheduler: scheduler)
        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record
        ble.suspendForPanicReset()
        ble.completePanicReset(restartServices: false)
        ble.recoverNoiseIdentityForForeground()
        ble.sendAnnounce(forceSend: true)
        ble.broadcastNostrCarrier(Data([1]))
        await ble._test_drainNoiseMessagePipeline()

        #expect(!ble.isPanicSuspended)
        #expect(ble.isTransportIdentityAvailable)
        #expect(!ble.areServicesRequested)
        #expect(!ble.isTransportTrafficAllowed)
        #expect(ble.radioIsPanicSuspended())
        #expect(scheduler.pendingCount == 0)
        #expect(outbound.snapshot().isEmpty)
        ble.startServices()
        #expect(ble.isTransportTrafficAllowed)
        #expect(!ble.radioIsPanicSuspended())
    }

    /// Records ping completions (delivered on the main actor) so the
    /// injected-clock test can assert from its own thread.
    private final class MeshPingResultCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [MeshPingResult?] = []
        var results: [MeshPingResult?] { lock.withLock { recorded } }
        func record(_ result: MeshPingResult?) {
            lock.withLock { recorded.append(result) }
        }
    }

    /// The ping deadline asserted on an injected clock: the real 10s
    /// product constant, no wall-clock in the loop. This is the pattern
    /// for every engine deadline — the timeout must not fire early, must
    /// fire exactly once at the deadline, and must stay consumed after.
    @Test
    func meshPingTimesOutOnTheInjectedClockExactlyOnce() async throws {
        let scheduler = BLEEngineManualScheduler()
        let ble = makeService(engineScheduler: scheduler)
        let peer = PeerID(str: "aabbccdd00112233")
        ble._test_seedConnectedPeer(peer, nickname: "Alice")

        let collector = MeshPingResultCollector()
        ble.sendMeshPing(to: peer) { result in
            collector.record(result)
        }
        // The probe registers and its deadline schedules on the engine;
        // fence that submission before touching the clock.
        await ble._test_drainNoiseMessagePipeline()
        #expect(scheduler.pendingCount == 1)

        // A hair before the deadline nothing may fire.
        scheduler.advance(by: TransportConfig.meshPingTimeoutSeconds - 0.01)
        await ble._test_drainNoiseMessagePipeline()
        #expect(collector.results.isEmpty)

        // Crossing the deadline expires the probe: nil, exactly once, on
        // the main actor.
        scheduler.advance(by: 0.02)
        let completed = await TestHelpers.waitUntil(
            { collector.results.count == 1 },
            timeout: TestConstants.longTimeout
        )
        #expect(completed)
        #expect(collector.results == [nil])

        // The deadline is consumed — more time cannot re-fire it.
        scheduler.advance(by: TransportConfig.meshPingTimeoutSeconds * 2)
        await ble._test_drainNoiseMessagePipeline()
        #expect(collector.results.count == 1)
    }

    @Test
    func duplicatePacket_isDeduped() async throws {
        let ble = makeService()
        let delegate = PublicCaptureDelegate()
        ble.delegate = delegate

        // Public messages must carry a valid signature from the claimed sender;
        // sign the packet and preseed the sender's signing key so the receiver
        // can verify it (production `sendMessage` signs public broadcasts too).
        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let sender = PeerID(str: "1122334455667788")
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let unsigned = makePublicPacket(content: "Hello", sender: sender, timestamp: timestamp)
        let packet = try #require(signer.signPacket(unsigned), "Failed to sign public message")
        let signingKey = signer.getSigningPublicKeyData()!

        ble._test_handlePacket(packet, fromPeerID: sender, signingPublicKey: signingKey)
        let receivedFirst = await TestHelpers.waitUntil(
            { delegate.publicMessagesSnapshot().count == 1 },
            timeout: TestConstants.longTimeout
        )
        #expect(receivedFirst)

        ble._test_handlePacket(packet, fromPeerID: sender, signingPublicKey: signingKey)
        let receivedDuplicate = await TestHelpers.waitUntil(
            { delegate.publicMessagesSnapshot().count > 1 },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!receivedDuplicate)

        let messages = delegate.publicMessagesSnapshot()
        #expect(messages.count == 1)
        #expect(messages.first?.content == "Hello")
    }

    @Test(arguments: [MessageType.message, .prekeyBundle])
    func solicitedFragmentedSyncUsesBoundResponder(type: MessageType) async throws {
        let manager = RequestSyncManager()
        let fixture = try makeFragmentedSyncFixture(type: type, manager: manager)
        manager.registerRequest(to: fixture.responder)
        #expect(manager.isValidResponse(from: fixture.responder, isRSR: true))
        #expect(!manager.isValidResponse(from: fixture.author, isRSR: true))

        for fragment in fixture.fragments {
            fixture.ble._test_ingestFrame(fragment, link: fixture.link)
        }
        await fixture.ble._test_drainFragmentPipeline()

        #expect(fixture.wasDelivered)
        #expect(fixture.publicMessages.publicMessagesSnapshot().first?.content == (type == .message ? fixture.content : nil))
    }

    @Test(arguments: [MessageType.message, .prekeyBundle])
    func unsolicitedFragmentedSyncCannotBorrowAuthorsRequest(type: MessageType) async throws {
        let manager = RequestSyncManager()
        let fixture = try makeFragmentedSyncFixture(type: type, manager: manager)
        // Only the actual bound responder may answer our request. A request
        // to the author does not authorize a different neighbor to replay it.
        manager.registerRequest(to: fixture.author)
        #expect(manager.isValidResponse(from: fixture.author, isRSR: true))
        for fragment in fixture.fragments {
            fixture.ble._test_ingestFrame(fragment, link: fixture.link)
        }
        await fixture.ble._test_drainFragmentPipeline()
        #expect(!fixture.wasDelivered)
    }

    @Test(arguments: [MessageType.message, .prekeyBundle])
    func fragmentedSyncExpiresBeforeLastFragment(type: MessageType) async throws {
        let clock = FragmentSyncClock()
        let manager = RequestSyncManager(responseWindow: 30, now: { clock.now })
        let fixture = try makeFragmentedSyncFixture(type: type, manager: manager)
        manager.registerRequest(to: fixture.responder)
        #expect(manager.isValidResponse(from: fixture.responder, isRSR: true))
        for fragment in fixture.fragments.dropLast() {
            fixture.ble._test_ingestFrame(fragment, link: fixture.link)
        }
        fixture.ble._test_fenceEngine()
        clock.advance(by: 31)
        fixture.ble._test_ingestFrame(try #require(fixture.fragments.last), link: fixture.link)
        await fixture.ble._test_drainFragmentPipeline()
        #expect(!fixture.wasDelivered)
    }

    @Test(arguments: [MessageType.message, .prekeyBundle])
    func innerSyncResponseRequiresRSRFragment(type: MessageType) async throws {
        let manager = RequestSyncManager()
        let fixture = try makeFragmentedSyncFixture(type: type, manager: manager)
        manager.registerRequest(to: fixture.responder)
        // Ordinary traffic cannot smuggle an RSR inner packet through an
        // open request window. Both envelopes must carry the response flag.
        for var fragment in fixture.fragments {
            fragment.isRSR = false
            fixture.ble._test_ingestFrame(fragment, link: fixture.link)
        }
        await fixture.ble._test_drainFragmentPipeline()
        #expect(!fixture.wasDelivered)
    }

    @Test(arguments: [MessageType.message, .prekeyBundle])
    func solicitedFragmentedSyncStillRequiresAuthorsSignature(type: MessageType) async throws {
        let manager = RequestSyncManager()
        let fixture = try makeFragmentedSyncFixture(type: type, manager: manager, corruptSignature: true)
        manager.registerRequest(to: fixture.responder)
        for fragment in fixture.fragments {
            fixture.ble._test_ingestFrame(fragment, link: fixture.link)
        }
        await fixture.ble._test_drainFragmentPipeline()
        #expect(!fixture.wasDelivered)
    }

    @Test
    func fragmentsFromAnotherAuthorCannotInjectUnsignedSelfMessage() async throws {
        let ble = makeService()
        let capture = PublicCaptureDelegate()
        ble.delegate = capture
        let remoteAuthor = PeerID(str: "1122334455667788")
        let remoteData = try #require(Data(hexString: remoteAuthor.id))
        let link = BLEIngressLinkID.central("synthetic-forged-self-message")
        ble._test_bindCentral("synthetic-forged-self-message", to: remoteAuthor)
        // An attacker wraps an unsigned message claiming our identity in
        // fragments that identify the attacker. No sync request exists.
        let content = String(decoding: Array(UInt8(33)...UInt8(96)), as: UTF8.self)
        let forgedInner = makePublicPacket(content: content, sender: ble.myPeerID,
                                          timestamp: UInt64(Date().timeIntervalSince1970 * 1_000))
        let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
            for: BLEOutboundFragmentTransferRequest(packet: forgedInner, pad: false, maxChunk: 64, directedPeer: nil),
            defaultChunkSize: TransportConfig.bleDefaultFragmentSize, bleMaxMTU: 512,
            fragmentID: Data([0x13, 0x25, 0x47, 0x69, 0x81, 0x93, 0x04, 0x16])
        ))
        #expect(plan.totalFragments > 1)
        for fragment in plan.fragmentPackets {
            let remoteFragment = BitchatPacket(
                type: fragment.type, senderID: remoteData, recipientID: fragment.recipientID,
                timestamp: fragment.timestamp, payload: fragment.payload, signature: nil,
                ttl: fragment.ttl, version: fragment.version, route: fragment.route, isRSR: false
            )
            ble._test_ingestFrame(remoteFragment, link: link)
        }
        await ble._test_drainFragmentPipeline()
        #expect(capture.publicMessagesSnapshot().isEmpty)
    }

    @Test
    func staleBroadcast_isIgnored() async {
        let ble = makeService()
        let delegate = PublicCaptureDelegate()
        ble.delegate = delegate

        let sender = PeerID(str: "A1B2C3D4E5F60708")
        let oldTimestamp = UInt64(Date().addingTimeInterval(-901).timeIntervalSince1970 * 1000)
        let packet = makePublicPacket(content: "Old", sender: sender, timestamp: oldTimestamp)

        ble._test_handlePacket(packet, fromPeerID: sender)

        let didReceive = await TestHelpers.waitUntil({ !delegate.publicMessagesSnapshot().isEmpty }, timeout: 0.3)
        #expect(!didReceive)
        #expect(delegate.publicMessagesSnapshot().isEmpty)
    }

    @Test
    func announceSenderMismatch_isRejected() async throws {
        let ble = makeService()

        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let announcement = AnnouncementPacket(
            nickname: "Spoof",
            noisePublicKey: signer.getStaticPublicKeyData()!,
            signingPublicKey: signer.getSigningPublicKeyData()!,
            directNeighbors: nil
        )
        let payload = try #require(announcement.encode(), "Failed to encode announcement")

        let derivedPeerID = PeerID(publicKey: announcement.noisePublicKey)
        let wrongFirst = derivedPeerID.bare.first == "0" ? "1" : "0"
        let wrongBare = String(wrongFirst) + String(derivedPeerID.bare.dropFirst())
        let wrongPeerID = PeerID(str: wrongBare)
        let packet = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: wrongPeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )
        let signed = try #require(signer.signPacket(packet), "Failed to sign announce packet")

        ble._test_handlePacket(signed, fromPeerID: wrongPeerID, preseedPeer: false)

        _ = await TestHelpers.waitUntil({ !ble.currentPeerSnapshots().isEmpty }, timeout: 0.3)
        #expect(ble.currentPeerSnapshots().isEmpty)
    }

    @Test
    func unsignedAndBadSignatureLeaveDoNotEvictOrRelayClaimedPeer() async throws {
        let ble = makeService()
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let mallory = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData()!)
        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record

        let unsigned = makeLeavePacket(sender: alicePeerID, marker: "unsigned")
        ble._test_handlePacket(
            unsigned,
            fromPeerID: alicePeerID,
            signingPublicKey: alice.getSigningPublicKeyData()!
        )

        let unsignedRelayed = await TestHelpers.waitUntil(
            { outbound.count(ofType: .leave) > 0 },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!unsignedRelayed)
        #expect(ble.currentPeerSnapshots().contains { $0.peerID == alicePeerID })

        let badSignature = try #require(
            mallory.signPacket(makeLeavePacket(sender: alicePeerID, marker: "bad-signature"))
        )
        ble._test_handlePacket(
            badSignature,
            fromPeerID: alicePeerID,
            signingPublicKey: alice.getSigningPublicKeyData()!
        )

        let badSignatureRelayed = await TestHelpers.waitUntil(
            { outbound.count(ofType: .leave) > 0 },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!badSignatureRelayed)
        #expect(ble.currentPeerSnapshots().contains { $0.peerID == alicePeerID })
    }

    @Test
    func groupBroadcastFromABitChatPeerIsNotRelayed() async {
        // Wesh has no groups: a BitChat group broadcast (0x25) used to be
        // relayed like any public packet. It must now stop at this node.
        let ble = makeService()
        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record
        let sender = PeerID(str: "5566778899aabbcc")
        let packet = BitchatPacket(
            type: MessageType.groupMessage.rawValue,
            senderID: Data(hexString: sender.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data(repeating: 0x42, count: 64),
            signature: nil,
            ttl: 7
        )

        ble._test_handlePacket(packet, fromPeerID: sender)

        let relayed = await TestHelpers.waitUntil(
            { outbound.count(ofType: .groupMessage) > 0 },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!relayed)
    }

    @Test
    func voiceFrameFromABitChatPeerIsNotRelayed() async throws {
        // Wesh has no live voice: a BitChat public voice frame (0x29) used to
        // be relayed once its signature checked out. Even a correctly signed
        // one from a known sender must now stop at this node.
        let ble = makeService()
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData()!)
        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record
        let packet = BitchatPacket(
            type: MessageType.voiceFrame.rawValue,
            senderID: Data(hexString: alicePeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data(repeating: 0x71, count: 210),
            signature: nil,
            ttl: 7
        )
        let signed = try #require(alice.signPacket(packet))

        ble._test_handlePacket(
            signed,
            fromPeerID: alicePeerID,
            signingPublicKey: alice.getSigningPublicKeyData()!
        )

        let relayed = await TestHelpers.waitUntil(
            { outbound.count(ofType: .voiceFrame) > 0 },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!relayed)
    }

    @Test @MainActor
    func fileTransferFromABitChatPeerIsNeitherRelayedNorDelivered() async throws {
        // Wesh has no media: a broadcast BitChat file (0x22), whole or
        // fragmented, or one addressed to us stops here with no event at all.
        // The V1 never spreads public files.
        let ble = makeService()
        let delegate = TransportEventCaptureDelegate()
        ble.eventDelegate = delegate
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData()!)
        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        for recipient in [nil, Data(hexString: ble.myPeerID.id)] as [Data?] {
            let packet = BitchatPacket(
                type: MessageType.fileTransfer.rawValue,
                senderID: Data(hexString: alicePeerID.id) ?? Data(),
                recipientID: recipient,
                timestamp: timestamp,
                payload: Data(repeating: 0x5A, count: 300),
                signature: nil,
                ttl: 7
            )
            let signed = try #require(alice.signPacket(packet))
            ble._test_handlePacket(signed, fromPeerID: alicePeerID, signingPublicKey: alice.getSigningPublicKeyData()!)
        }
        let file = BitchatPacket(
            type: MessageType.fileTransfer.rawValue,
            senderID: Data(hexString: alicePeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: timestamp + 1,
            // Incompressible, so the frame really spans several fragments.
            payload: Data((0..<1_200).map { _ in UInt8.random(in: 0...255) }),
            signature: nil,
            ttl: 7
        )
        let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
            for: BLEOutboundFragmentTransferRequest(packet: file, pad: false, maxChunk: 256, directedPeer: nil),
            defaultChunkSize: TransportConfig.bleDefaultFragmentSize,
            bleMaxMTU: 512
        ))
        #expect(plan.totalFragments > 1)
        for fragment in plan.fragmentPackets {
            ble._test_handlePacket(fragment, fromPeerID: alicePeerID)
        }

        let relayed = await TestHelpers.waitUntil(
            { outbound.count(ofType: .fileTransfer) + outbound.count(ofType: .fragment) > 0 },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!relayed)
        #expect(delegate.messageIDs.isEmpty)
        #expect(delegate.noisePayloadTypes.isEmpty)
    }

    @Test @MainActor
    func fileTransferForAnotherPeerIsStillRelayedButNeverDelivered() async throws {
        // A BitChat file between two other phones crosses Wesh as before,
        // whole or fragmented; nothing of it is handled here.
        let ble = makeService()
        let delegate = TransportEventCaptureDelegate()
        ble.eventDelegate = delegate
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData()!)
        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record
        let otherPeer = try #require(Data(hexString: "8899aabbccddeeff"))
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let whole = BitchatPacket(
            type: MessageType.fileTransfer.rawValue,
            senderID: Data(hexString: alicePeerID.id) ?? Data(),
            recipientID: otherPeer,
            timestamp: timestamp,
            payload: Data(repeating: 0x5A, count: 300),
            signature: nil,
            ttl: 7
        )
        let signed = try #require(alice.signPacket(whole))
        ble._test_handlePacket(signed, fromPeerID: alicePeerID, signingPublicKey: alice.getSigningPublicKeyData()!)
        let large = BitchatPacket(
            type: MessageType.fileTransfer.rawValue,
            senderID: Data(hexString: alicePeerID.id) ?? Data(),
            recipientID: otherPeer,
            timestamp: timestamp + 1,
            payload: Data((0..<1_200).map { _ in UInt8.random(in: 0...255) }),
            signature: nil,
            ttl: 7
        )
        let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
            for: BLEOutboundFragmentTransferRequest(packet: large, pad: false, maxChunk: 256, directedPeer: nil),
            defaultChunkSize: TransportConfig.bleDefaultFragmentSize,
            bleMaxMTU: 512
        ))
        #expect(plan.totalFragments > 1)
        for fragment in plan.fragmentPackets {
            ble._test_handlePacket(fragment, fromPeerID: alicePeerID)
        }

        let relayed = await TestHelpers.waitUntil(
            { outbound.count(ofType: .fileTransfer) >= 1 && outbound.count(ofType: .fragment) >= plan.totalFragments },
            timeout: TestConstants.longTimeout
        )
        #expect(relayed)
        #expect(outbound.snapshot().allSatisfy { $0.recipientID == otherPeer })
        #expect(delegate.messageIDs.isEmpty)
        #expect(delegate.noisePayloadTypes.isEmpty)
    }

    @Test
    func readReceiptForAMediaPlaceholderIsNeverSent() async throws {
        // The placeholder stands for a file this phone never received.
        let ble = makeService()
        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record
        let peer = PeerID(str: "8899aabbccddeeff")
        let placeholderID = UnsupportedPrivateMedia.messageID(
            payload: Data([0x01, 0x02]), senderPeerID: peer, recipientPeerID: ble.myPeerID
        )
        #expect(UnsupportedPrivateMedia.isPlaceholderID(placeholderID))
        ble.sendReadReceipt(
            ReadReceipt(originalMessageID: placeholderID, readerID: ble.myPeerID, readerNickname: "me"),
            to: peer
        )
        await ble._test_drainNoiseMessagePipeline()
        let sent = await TestHelpers.waitUntil({ !outbound.snapshot().isEmpty }, timeout: TestConstants.negativeWaitWindow)
        #expect(!sent)
        #expect(!UnsupportedPrivateMedia.isPlaceholderID(UUID().uuidString))
    }

    @Test
    func localAnnounceCarriesNoPrivateMediaCapability() async throws {
        let ble = makeService()
        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record
        ble._test_forceAnnounce()

        let announced = await TestHelpers.waitUntil(
            { outbound.count(ofType: .announce) > 0 },
            timeout: TestConstants.longTimeout
        )
        try #require(announced)
        let packet = try #require(outbound.snapshot().first { $0.type == MessageType.announce.rawValue })
        let announcement = try #require(AnnouncementPacket.decode(from: packet.payload))
        let capabilities = try #require(announcement.capabilities)
        #expect(!capabilities.contains(.privateMedia))
        #expect(!capabilities.contains(.privateMediaReceipts))
        #expect(capabilities.contains(.vouch))
    }

    @Test @MainActor
    func fragmentsOfRetiredTypesAreNeitherRelayedNorAssembled() async throws {
        // Rejecting the reassembled packet is not enough: each fragment of a
        // BitChat group message, voice frame or public file used to be
        // relayed (and gossip-stored) on its own. A file fragment for another
        // peer still crosses this node.
        let ble = makeService()
        let delegate = TransportEventCaptureDelegate()
        ble.eventDelegate = delegate
        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData()!)
        let sender = try #require(Data(hexString: alicePeerID.id))
        let otherPeer = try #require(Data(hexString: "8899aabbccddeeff"))
        let me = try #require(Data(hexString: ble.myPeerID.id))

        for (type, recipient) in [
            (MessageType.groupMessage, nil), (.groupMessage, otherPeer),
            (.voiceFrame, nil), (.fileTransfer, nil), (.fileTransfer, me)
        ] as [(MessageType, Data?)] {
            ble._test_handlePacket(
                retiredFragmentTestPacket(originalType: type, sender: sender, recipient: recipient),
                fromPeerID: alicePeerID
            )
        }
        let relayedRetired = await TestHelpers.waitUntil(
            { outbound.count(ofType: .fragment) > 0 },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!relayedRetired)

        // A whole file for another peer, every fragment delivered: relayed
        // fragment by fragment, never reassembled into a file here.
        let file = BitchatPacket(
            type: MessageType.fileTransfer.rawValue,
            senderID: sender,
            recipientID: otherPeer,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data((0..<1_200).map { _ in UInt8.random(in: 0...255) }),
            signature: nil,
            ttl: 7
        )
        let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
            for: BLEOutboundFragmentTransferRequest(packet: file, pad: false, maxChunk: 256, directedPeer: nil),
            defaultChunkSize: TransportConfig.bleDefaultFragmentSize,
            bleMaxMTU: 512
        ))
        #expect(plan.totalFragments > 1)
        for fragment in plan.fragmentPackets {
            ble._test_handlePacket(fragment, fromPeerID: alicePeerID)
        }
        let relayedForOther = await TestHelpers.waitUntil(
            { outbound.count(ofType: .fragment) >= plan.totalFragments },
            timeout: TestConstants.longTimeout
        )
        #expect(relayedForOther)
        #expect(outbound.snapshot().allSatisfy { $0.recipientID == otherPeer })
        #expect(outbound.count(ofType: .fileTransfer) == 0)
        #expect(delegate.messageIDs.isEmpty)
        #expect(delegate.noisePayloadTypes.isEmpty)
    }

    @Test
    func refusedFragmentsNeverEnterGossipSync() async throws {
        // A refused fragment is not stored for sync: a peer asking for every
        // fragment gets the kept one back, never the refused one.
        let ble = makeService()
        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData()!)
        let sender = try #require(Data(hexString: alicePeerID.id))
        let refused = retiredFragmentTestPacket(originalType: .groupMessage, sender: sender, recipient: nil)
        let kept = retiredFragmentTestPacket(originalType: .message, sender: sender, recipient: nil)
        ble._test_handlePacket(refused, fromPeerID: alicePeerID)
        ble._test_handlePacket(kept, fromPeerID: alicePeerID)
        await ble._test_drainFragmentPipeline()

        // REQUEST_SYNC must be signed by a known peer to be answered.
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let requester = PeerID(publicKey: bob.getStaticPublicKeyData()!)
        let unsignedRequest = BitchatPacket(
            type: MessageType.requestSync.rawValue,
            senderID: try #require(Data(hexString: requester.id)),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: RequestSyncPacket(p: 4, m: 1, data: Data(), types: .fragment).encode(),
            signature: nil,
            ttl: 0
        )
        let request = try #require(bob.signPacket(unsignedRequest))
        ble._test_handlePacket(request, fromPeerID: requester, signingPublicKey: bob.getSigningPublicKeyData()!)

        func served(_ fragment: BitchatPacket) -> Bool {
            outbound.snapshot().contains {
                $0.type == MessageType.fragment.rawValue && $0.ttl == 0 && $0.payload == fragment.payload
            }
        }
        let servedKept = await TestHelpers.waitUntil({ served(kept) }, timeout: TestConstants.longTimeout)
        #expect(servedKept)
        #expect(!outbound.snapshot().contains { $0.payload == refused.payload })
    }

    @Test
    func validSignedLeaveEvictsSessionAndRelays() async throws {
        let ble = makeService()
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData()!)

        // Establish a real session so the leave regression also verifies that
        // stale secure-delivery state is retired, not just the peer-list row.
        let message1 = try ble._test_noiseInitiateHandshake(with: alicePeerID)
        let message2 = try #require(
            try alice.processHandshakeMessage(from: ble.myPeerID, message: message1)
        )
        let message3 = try #require(
            try ble._test_noiseProcessHandshakeMessage(from: alicePeerID, message: message2)
        )
        _ = try alice.processHandshakeMessage(from: ble.myPeerID, message: message3)
        #expect(ble.canDeliverSecurely(to: alicePeerID))
        let centralUUID = "central-valid-leave"
        ble._test_bindCentral(centralUUID, to: alicePeerID)
        ble._test_markNoiseAuthenticatedCentral(centralUUID, to: alicePeerID)
        #expect(ble._test_isNoiseAuthenticatedCentral(centralUUID, for: alicePeerID))

        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record
        let signedLeave = try #require(
            alice.signPacket(makeLeavePacket(sender: alicePeerID, marker: "valid"))
        )
        ble._test_handlePacket(
            signedLeave,
            fromPeerID: alicePeerID,
            signingPublicKey: alice.getSigningPublicKeyData()!
        )

        let evicted = await TestHelpers.waitUntil(
            {
                !ble.currentPeerSnapshots().contains { $0.peerID == alicePeerID }
                    && !ble.canDeliverSecurely(to: alicePeerID)
                    && !ble._test_isNoiseAuthenticatedCentral(centralUUID, for: alicePeerID)
            },
            timeout: TestConstants.longTimeout
        )
        #expect(evicted)
        let relayed = await TestHelpers.waitUntil(
            { outbound.count(ofType: .leave) == 1 },
            timeout: TestConstants.longTimeout
        )
        #expect(relayed)
    }

    @Test
    func ingressAllowsRelayedSenderOnBoundLink() async throws {
        let ble = makeService()
        let boundPeer = PeerID(str: "1122334455667788")
        let relayedSender = PeerID(str: "8899aabbccddeeff")
        let packet = makePublicPacket(
            content: "Relayed",
            sender: relayedSender,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        #expect(ble._test_acceptsIngress(packet: packet, boundPeerID: boundPeer))
    }

    @Test
    func ingressAllowsDirectAnnounceThatConflictsWithBoundLink() async throws {
        // Peer-ID rotation heal: the announce must reach signature
        // verification, which decides whether the link rebinds.
        let ble = makeService()
        let boundPeer = PeerID(str: "1122334455667788")
        let claimedPeer = PeerID(str: "8899aabbccddeeff")
        let packet = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: claimedPeer.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data(),
            signature: nil,
            ttl: 7
        )

        #expect(ble._test_acceptsIngress(packet: packet, boundPeerID: boundPeer))
    }

    @Test
    func ingressRejectsRequestSyncThatConflictsWithBoundLink() async throws {
        let ble = makeService()
        let boundPeer = PeerID(str: "1122334455667788")
        let claimedPeer = PeerID(str: "8899aabbccddeeff")
        let packet = BitchatPacket(
            type: MessageType.requestSync.rawValue,
            senderID: Data(hexString: claimedPeer.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: Data(),
            signature: nil,
            ttl: 0
        )

        #expect(!ble._test_acceptsIngress(packet: packet, boundPeerID: boundPeer))
    }

    @Test
    func verifiedDirectAnnounceRebindsRotatedLinkAndRetiresOldPeer() async throws {
        let ble = makeService()
        let oldPeerID = PeerID(str: "1122334455667788")
        let centralUUID = "central-rotation"

        // A connected peer whose link binding predates its relaunch.
        ble._test_seedConnectedPeer(oldPeerID, nickname: "alice")
        ble._test_bindCentral(centralUUID, to: oldPeerID)

        // The relaunched device re-announces its rotated identity over the
        // still-open link.
        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let announcement = AnnouncementPacket(
            nickname: "alice",
            noisePublicKey: signer.getStaticPublicKeyData()!,
            signingPublicKey: signer.getSigningPublicKeyData()!,
            directNeighbors: nil
        )
        let payload = try #require(announcement.encode(), "Failed to encode announcement")
        let newPeerID = PeerID(publicKey: announcement.noisePublicKey)
        let unsigned = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: newPeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )
        let packet = try #require(signer.signPacket(unsigned), "Failed to sign announce packet")

        #expect(ble._test_recordIngressIfNew(packet: packet, linkID: centralUUID))
        ble._test_handlePacket(packet, fromPeerID: newPeerID, preseedPeer: false)

        let rebound = await TestHelpers.waitUntil(
            { ble._test_centralBinding(centralUUID) == newPeerID },
            timeout: TestConstants.longTimeout
        )
        #expect(rebound)

        let retired = await TestHelpers.waitUntil(
            {
                let peerIDs = ble.currentPeerSnapshots().map(\.peerID)
                return peerIDs.contains(newPeerID) && !peerIDs.contains(oldPeerID)
            },
            timeout: TestConstants.longTimeout
        )
        #expect(retired)
    }

    @Test
    func replayedDirectAnnounceCannotStealBoundIdentity() async throws {
        let ble = makeService()
        let attackerPeerID = PeerID(str: "1122334455667788")
        let victimLink = "central-victim"
        let attackerLink = "central-attacker"

        // The victim's identity, genuinely bound on its own link.
        let victimSigner = NoiseEncryptionService(keychain: MockKeychain())
        let announcement = AnnouncementPacket(
            nickname: "victim",
            noisePublicKey: victimSigner.getStaticPublicKeyData()!,
            signingPublicKey: victimSigner.getSigningPublicKeyData()!,
            directNeighbors: nil
        )
        let payload = try #require(announcement.encode(), "Failed to encode announcement")
        let victimPeerID = PeerID(publicKey: announcement.noisePublicKey)
        let courierStore = CourierStore(persistsToDisk: false)
        ble.courierStore = courierStore
        let carriedEnvelope = CourierEnvelope(
            recipientTag: CourierEnvelope.recipientTag(
                noiseStaticKey: announcement.noisePublicKey,
                epochDay: CourierEnvelope.epochDay(for: Date())
            ),
            expiry: UInt64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000),
            ciphertext: Data(repeating: 0xA5, count: 128)
        )
        #expect(courierStore.deposit(
            carriedEnvelope,
            from: Data(repeating: 0xC0, count: 32),
            tier: .favorite
        ))
        let sprayRecipientKey = Data(repeating: 0xB4, count: 32)
        let sprayEnvelope = CourierEnvelope(
            recipientTag: CourierEnvelope.recipientTag(
                noiseStaticKey: sprayRecipientKey,
                epochDay: CourierEnvelope.epochDay(for: Date())
            ),
            expiry: UInt64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000),
            ciphertext: Data(repeating: 0xB5, count: 128),
            copies: 4
        )
        #expect(courierStore.deposit(
            sprayEnvelope,
            from: Data(repeating: 0xC0, count: 32),
            tier: .favorite
        ))
        ble._test_seedConnectedPeer(victimPeerID, nickname: "victim")
        ble._test_bindCentral(victimLink, to: victimPeerID)
        ble._test_seedConnectedPeer(attackerPeerID, nickname: "attacker")
        ble._test_bindCentral(attackerLink, to: attackerPeerID)

        // Preserve the hard case: a valid victim session still exists on the
        // victim's own physical link when the announce is replayed elsewhere.
        let message1 = try ble._test_noiseInitiateHandshake(with: victimPeerID)
        let message2 = try #require(
            try victimSigner.processHandshakeMessage(from: ble.myPeerID, message: message1)
        )
        let message3 = try #require(
            try ble._test_noiseProcessHandshakeMessage(from: victimPeerID, message: message2)
        )
        _ = try victimSigner.processHandshakeMessage(from: ble.myPeerID, message: message3)
        #expect(ble.canDeliverSecurely(to: victimPeerID))
        ble._test_markNoiseAuthenticatedCentral(victimLink, to: victimPeerID)

        // The victim's fresh signed announce replayed on the attacker's bound
        // link with its direct TTL restored (TTL is excluded from signing, so
        // the signature still verifies).
        let unsigned = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: victimPeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )
        let packet = try #require(victimSigner.signPacket(unsigned), "Failed to sign announce packet")

        #expect(ble._test_recordIngressIfNew(packet: packet, linkID: attackerLink))
        ble._test_handlePacket(packet, fromPeerID: victimPeerID, preseedPeer: false)

        // The rebind must be refused: the identity already owns a live link.
        let stolen = await TestHelpers.waitUntil(
            { ble._test_centralBinding(attackerLink) == victimPeerID },
            timeout: 0.3
        )
        #expect(!stolen)
        #expect(ble._test_centralBinding(attackerLink) == attackerPeerID)
        #expect(ble._test_centralBinding(victimLink) == victimPeerID)
        // A valid signature authenticates the announce contents, not the
        // unsigned direct TTL. Without a Noise-authenticated session on the
        // ingress link, the replay must not retire mail or consume spray state.
        #expect(!courierStore.isEmpty)
        await Task.yield()
        await Task.yield()
        let stillEligibleForSpray = courierStore.takeSprayCopies(for: announcement.noisePublicKey)
        #expect(stillEligibleForSpray.map(\.copies) == [2])
        #expect(courierStore.takeEnvelopes(for: announcement.noisePublicKey) == [carriedEnvelope])
        #expect(ble.canDeliverSecurely(to: victimPeerID))
        // And the replay must not retire the link's real bound peer.
        #expect(ble.currentPeerSnapshots().map(\.peerID).contains(attackerPeerID))
    }

    @Test
    func replayedDirectAnnounceForAbsentPeerNeverYieldsSecureDelivery() async throws {
        // Residual heal-path gap: the victim has NO live link, so the
        // identity-owns-a-link containment cannot refuse the rebind. The
        // replay steals the link binding, and because a successful rebind
        // promotes its new owner to connected (a legitimate rotation heal
        // requires that), the absent victim may read as connected. That
        // forged presence is display-only and accepted — the invariant that
        // holds is that the stolen link can never produce an established
        // Noise session, so MessageRouter's canDeliverSecurely gate routes
        // DMs through retain + courier instead of trusting it outright.
        let ble = makeService()
        let attackerPeerID = PeerID(str: "1122334455667788")
        let attackerLink = "central-attacker-absent-victim"
        ble._test_seedConnectedPeer(attackerPeerID, nickname: "attacker")
        ble._test_bindCentral(attackerLink, to: attackerPeerID)

        // The absent victim's fresh signed announce, replayed on the
        // attacker's bound link with its direct TTL restored.
        let victimSigner = NoiseEncryptionService(keychain: MockKeychain())
        let announcement = AnnouncementPacket(
            nickname: "victim",
            noisePublicKey: victimSigner.getStaticPublicKeyData()!,
            signingPublicKey: victimSigner.getSigningPublicKeyData()!,
            directNeighbors: nil
        )
        let payload = try #require(announcement.encode(), "Failed to encode announcement")
        let victimPeerID = PeerID(publicKey: announcement.noisePublicKey)
        let unsigned = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: victimPeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )
        let packet = try #require(victimSigner.signPacket(unsigned), "Failed to sign announce packet")

        #expect(ble._test_recordIngressIfNew(packet: packet, linkID: attackerLink))
        ble._test_handlePacket(packet, fromPeerID: victimPeerID, preseedPeer: false)

        // The rebind steals the link (no live link owns the victim's
        // identity, so containment cannot refuse) …
        let rebound = await TestHelpers.waitUntil(
            { ble._test_centralBinding(attackerLink) == victimPeerID },
            timeout: TestConstants.longTimeout
        )
        #expect(rebound)
        // … and the promote marks the absent victim connected: the accepted,
        // display-only forged-presence residue (documented at
        // BLEAnnounceHandler's linkBoundToOtherPeer check) …
        let forgedPresence = await TestHelpers.waitUntil(
            { ble.isPeerConnected(victimPeerID) },
            timeout: TestConstants.longTimeout
        )
        #expect(forgedPresence)
        // … but secure delivery stays impossible — the DM gate holds, and
        // MessageRouter retains + couriers instead of trusting the link.
        #expect(!ble.canDeliverSecurely(to: victimPeerID))
    }

    @Test
    func replayedDirectAnnounceWithStaleVictimSessionCannotBridgeThroughForeignLink() async throws {
        let ble = makeService()
        // Keep announce handling out of the carried-mail path: the regression
        // is specifically BridgeCourierService's direct delivery preflight.
        ble.courierStore = CourierStore(persistsToDisk: false)
        let attackerPeerID = PeerID(str: "1122334455667788")
        let attackerLink = "central-attacker-stale-victim-session"
        ble._test_seedConnectedPeer(attackerPeerID, nickname: "attacker")
        ble._test_bindCentral(attackerLink, to: attackerPeerID)

        let victim = NoiseEncryptionService(keychain: MockKeychain())
        let announcement = AnnouncementPacket(
            nickname: "victim",
            noisePublicKey: victim.getStaticPublicKeyData()!,
            signingPublicKey: victim.getSigningPublicKeyData()!,
            directNeighbors: nil
        )
        let victimPeerID = PeerID(publicKey: announcement.noisePublicKey)

        // Establish a real peer-level victim session without associating it
        // with the attacker's physical link. This is the stale-session case
        // that a plain `canDeliverSecurely` check cannot distinguish.
        let message1 = try ble._test_noiseInitiateHandshake(with: victimPeerID)
        let message2 = try #require(
            try victim.processHandshakeMessage(from: ble.myPeerID, message: message1)
        )
        let message3 = try #require(
            try ble._test_noiseProcessHandshakeMessage(from: victimPeerID, message: message2)
        )
        _ = try victim.processHandshakeMessage(from: ble.myPeerID, message: message3)
        #expect(ble.canDeliverSecurely(to: victimPeerID))

        let payload = try #require(announcement.encode(), "Failed to encode announcement")
        let unsigned = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: victimPeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )
        let replay = try #require(victim.signPacket(unsigned), "Failed to sign replayed announce")
        #expect(ble._test_recordIngressIfNew(packet: replay, linkID: attackerLink))
        ble._test_handlePacket(replay, fromPeerID: victimPeerID, preseedPeer: false)

        // The rebind, its Noise-proof retirement, and the ordinary
        // reconnect preparation are one engine slot: no observer can see
        // the new binding while the victim's stale sending keys are still
        // available. Once the binding is visible, the keys must already be
        // gone.
        let rebound = await TestHelpers.waitUntil(
            { ble._test_centralBinding(attackerLink) == victimPeerID },
            timeout: TestConstants.longTimeout
        )
        try #require(rebound)
        #expect(!ble.canDeliverSecurely(to: victimPeerID))

        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = { outbound.record($0) }
        let envelope = CourierEnvelope(
            recipientTag: CourierEnvelope.recipientTag(
                noiseStaticKey: announcement.noisePublicKey,
                epochDay: CourierEnvelope.epochDay(for: Date())
            ),
            expiry: UInt64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000),
            ciphertext: Data(repeating: 0xA5, count: 128)
        )

        #expect(!ble.deliverBridgedEnvelope(envelope, to: victimPeerID))
        // Reject before even entering the outbound pipeline: otherwise a
        // real attacker CBCentral could accept the opaque courier packet and
        // cause the relay drop's persisted seen ID to be consumed forever.
        #expect(outbound.count(ofType: .courierEnvelope) == 0)
    }

    @Test
    func replacementXXMessageOneWithPayloadCannotAuthenticateIngressLink() async throws {
        let ble = makeService()
        let victim = NoiseEncryptionService(keychain: MockKeychain())
        let victimPeerID = PeerID(publicKey: victim.getStaticPublicKeyData()!)

        // Preserve a working victim session while an unauthenticated
        // replacement candidate arrives on a newly bound physical link.
        // Establish BLE as responder so the replacement candidate below is
        // not coalesced by the initiator-completion grace path.
        let message1 = try victim.initiateHandshake(with: ble.myPeerID)
        let message2 = try #require(
            try ble._test_noiseProcessHandshakeMessage(
                from: victimPeerID,
                message: message1
            )
        )
        let message3 = try #require(
            try victim.processHandshakeMessage(
                from: ble.myPeerID,
                message: message2
            )
        )
        _ = try ble._test_noiseProcessHandshakeMessage(
            from: victimPeerID,
            message: message3
        )
        await ble._test_drainNoiseMessagePipeline()
        #expect(ble.canDeliverSecurely(to: victimPeerID))

        let centralUUID = "central-replacement-xx-message-one"
        ble._test_bindCentral(centralUUID, to: victimPeerID)
        #expect(
            !ble._test_isNoiseAuthenticatedCentral(
                centralUUID,
                for: victimPeerID
            )
        )

        // XX message one may legally carry a payload, so its length is not a
        // reliable signal that the replacement handshake completed.
        let unauthenticatedInitiator = NoiseHandshakeState(
            role: .initiator,
            pattern: .XX,
            keychain: MockKeychain()
        )
        let replacementMessage1 = try unauthenticatedInitiator.writeMessage(
            payload: Data([0xA5])
        )
        #expect(
            replacementMessage1.count
                > NoiseSecurityConstants.xxInitialMessageSize
        )

        let packet = BitchatPacket(
            type: MessageType.noiseHandshake.rawValue,
            senderID: Data(hexString: victimPeerID.id) ?? Data(),
            recipientID: Data(hexString: ble.myPeerID.id),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: replacementMessage1,
            signature: nil,
            ttl: TransportConfig.messageTTLDefault
        )
        #expect(
            ble._test_recordIngressIfNew(
                packet: packet,
                linkID: centralUUID
            )
        )

        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record
        ble._test_handlePacket(
            packet,
            fromPeerID: victimPeerID,
            preseedPeer: false
        )

        // Waiting for the responder's message two proves the candidate was
        // processed before checking its exact authentication result.
        let candidateProcessed = await TestHelpers.waitUntil(
            { outbound.count(ofType: .noiseHandshake) == 1 },
            timeout: TestConstants.longTimeout
        )
        #expect(candidateProcessed)
        #expect(
            !ble._test_isNoiseAuthenticatedCentral(
                centralUUID,
                for: victimPeerID
            )
        )
        // Ordinary reconnect hardening quarantines the cached transport while
        // this candidate proves the claimed identity. It must be unavailable
        // for sending as well as unable to authenticate this ingress link.
        #expect(!ble.canDeliverSecurely(to: victimPeerID))
    }

    @Test
    func failedInboundReconnectRestoresAndDrainsWaitingWorkOnce() async throws {
        let ble = makeService()
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let mallory = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData()!)

        // Establish BLE as responder so the following inbound reconnect is
        // not intentionally coalesced by the initiator-completion grace path.
        let message1 = try alice.initiateHandshake(with: ble.myPeerID)
        let message2 = try #require(
            try ble._test_noiseProcessHandshakeMessage(
                from: alicePeerID,
                message: message1
            )
        )
        let message3 = try #require(
            try alice.processHandshakeMessage(
                from: ble.myPeerID,
                message: message2
            )
        )
        _ = try ble._test_noiseProcessHandshakeMessage(
            from: alicePeerID,
            message: message3
        )
        await ble._test_drainNoiseMessagePipeline()
        #expect(ble.canDeliverSecurely(to: alicePeerID))
        // The establishment transition enqueues its forced announce as a
        // separate serialized phase; drain again so it lands before the tap
        // and cannot masquerade as restore-driven announce traffic below.
        await ble._test_drainNoiseMessagePipeline()

        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record
        let forgedMessage1 = try mallory.initiateHandshake(with: ble.myPeerID)
        let firstPacket = BitchatPacket(
            type: MessageType.noiseHandshake.rawValue,
            senderID: Data(hexString: alicePeerID.id) ?? Data(),
            recipientID: Data(hexString: ble.myPeerID.id),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1_000),
            payload: forgedMessage1,
            signature: nil,
            ttl: 7
        )
        ble._test_handlePacket(firstPacket, fromPeerID: alicePeerID)

        let responseReady = await TestHelpers.waitUntil(
            {
                outbound.snapshot().contains {
                    $0.type == MessageType.noiseHandshake.rawValue
                        && PeerID(hexData: $0.senderID) == ble.myPeerID
                        && $0.payload.count
                            != NoiseSecurityConstants.xxInitialMessageSize
                }
            },
            timeout: TestConstants.longTimeout
        )
        try #require(responseReady)
        let forgedMessage2 = try #require(
            outbound.snapshot().first {
                $0.type == MessageType.noiseHandshake.rawValue
                    && PeerID(hexData: $0.senderID) == ble.myPeerID
                    && $0.payload.count
                        != NoiseSecurityConstants.xxInitialMessageSize
            }?.payload
        )
        #expect(!ble.canDeliverSecurely(to: alicePeerID))

        // Typed control traffic must queue behind the ordinary responder,
        // rather than attempting encryption and disappearing.
        let privateMessageID = "quarantine-pm-\(UUID().uuidString)"
        ble.sendPrivateMessage(
            "queued private message",
            to: alicePeerID,
            recipientNickname: "Alice",
            messageID: privateMessageID
        )
        ble.sendVouchAttestations(Data("queued-during-quarantine".utf8), to: alicePeerID)
        await ble._test_drainNoiseMessagePipeline()
        #expect(outbound.count(ofType: .noiseEncrypted) == 0)

        let forgedMessage3 = try #require(
            try mallory.processHandshakeMessage(
                from: ble.myPeerID,
                message: forgedMessage2
            )
        )
        let forgedEarlyPayload = try #require(
            BLENoisePayloadFactory.privateMessage(
                content: "forged early message",
                messageID: "forged-early"
            )
        )
        try #require(
            mallory.hasEstablishedSession(with: ble.myPeerID),
            "forged initiator did not establish after producing message three"
        )
        let forgedEarlyCiphertext = try mallory.encrypt(
            forgedEarlyPayload,
            for: ble.myPeerID
        )
        let earlyPacket = BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: Data(hexString: alicePeerID.id) ?? Data(),
            recipientID: Data(hexString: ble.myPeerID.id),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1_000) + 1,
            payload: forgedEarlyCiphertext,
            signature: nil,
            ttl: 7
        )
        ble._test_handlePacket(earlyPacket, fromPeerID: alicePeerID)
        await ble._test_drainNoiseMessagePipeline()

        let thirdPacket = BitchatPacket(
            type: MessageType.noiseHandshake.rawValue,
            senderID: Data(hexString: alicePeerID.id) ?? Data(),
            recipientID: Data(hexString: ble.myPeerID.id),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1_000) + 2,
            payload: forgedMessage3,
            signature: nil,
            ttl: 7
        )
        ble._test_handlePacket(thirdPacket, fromPeerID: alicePeerID)

        // Rollback restores the same generation. It retries the bounded early
        // ciphertext and drains both outbound queues, but must not repeat a
        // new-generation capability proof or forced announce.
        let drained = await TestHelpers.waitUntil(
            { outbound.count(ofType: .noiseEncrypted) >= 2 },
            timeout: TestConstants.longTimeout
        )
        try #require(drained)
        await ble._test_drainNoiseMessagePipeline()
        let plaintexts = try outbound.snapshot()
            .filter { $0.type == MessageType.noiseEncrypted.rawValue }
            .map { try alice.decrypt($0.payload, from: ble.myPeerID) }
        #expect(plaintexts.count == 2)
        #expect(
            plaintexts.filter {
                $0.first == NoisePayloadType.authenticatedPeerState.rawValue
            }.isEmpty
        )
        #expect(
            plaintexts.filter {
                $0.first == NoisePayloadType.privateMessage.rawValue
            }.count == 1
        )
        #expect(
            plaintexts.filter {
                $0.first == NoisePayloadType.vouch.rawValue
            }.count == 1
        )
        #expect(outbound.count(ofType: .announce) == 0)

        // A duplicate ready callback cannot replay either buffer.
        ble._test_reconcileCurrentNoiseSession(for: alicePeerID)
        await ble._test_drainNoiseMessagePipeline()
        #expect(outbound.count(ofType: .noiseEncrypted) == 2)
        #expect(outbound.count(ofType: .announce) == 0)
    }

    /// The message-loss interleaving behind a legitimate peer restart: the
    /// remote completes a replacement handshake (discarding the old keys)
    /// but its completion never arrives, so the local responder timeout
    /// restores the quarantined OLD generation and requests one convergence
    /// retry — both dispatched unordered. When the restore handler wins the
    /// race, it must NOT drain the pending private-message/typed-payload
    /// queues under the restored keys the remote no longer holds; the drain
    /// has to wait for the convergence handshake and use its new session.
    @Test
    func timeoutRestoredSessionDefersQueueDrainUntilConvergence() async throws {
        let ble = makeService(noiseResponderHandshakeTimeout: 0.3)
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let mallory = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(publicKey: alice.getStaticPublicKeyData()!)

        // Establish BLE as responder so the inbound reconnect below is not
        // coalesced by the initiator-completion grace path.
        let message1 = try alice.initiateHandshake(with: ble.myPeerID)
        let message2 = try #require(
            try ble._test_noiseProcessHandshakeMessage(
                from: alicePeerID,
                message: message1
            )
        )
        let message3 = try #require(
            try alice.processHandshakeMessage(
                from: ble.myPeerID,
                message: message2
            )
        )
        _ = try ble._test_noiseProcessHandshakeMessage(
            from: alicePeerID,
            message: message3
        )
        await ble._test_drainNoiseMessagePipeline()
        #expect(ble.canDeliverSecurely(to: alicePeerID))

        // The convergence retry only prepares for reachable peers.
        ble._test_seedConnectedPeer(alicePeerID, nickname: "Alice")

        let reconciled = SessionReconcileCounter()
        ble._test_onNoiseSessionReconciled = reconciled.record
        // Park the convergence-recovery callback on its global-queue thread
        // before it can enqueue onto messageQueue: the restore handler
        // deterministically wins the dispatch race this test exercises.
        let recoveryGate = HandshakeRecoveryEnqueueGate()
        defer { recoveryGate.release() }
        ble._test_beforeHandshakeRecoveryEnqueued = { _ in recoveryGate.pause() }
        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record

        // Park the traffic the race would lose directly in the pending
        // queues — the same place live sends land during quarantine — so no
        // assertion below depends on outrunning the responder deadline under
        // parallel test load. Nothing drains these queues while the current
        // session stays untouched.
        ble._test_enqueuePendingPrivateMessage(
            content: "deferred private message",
            messageID: "deferred-pm-\(UUID().uuidString)",
            for: alicePeerID
        )
        ble._test_enqueuePendingNoisePayload(
            NoisePayload(
                type: .vouch,
                data: Data("queued-during-quarantine".utf8)
            ).encode(),
            for: alicePeerID
        )

        // An unauthenticated message 1 quarantines the established transport.
        // Its message 3 never arrives, modeling the restarted peer whose
        // completion was lost after it already discarded the old keys.
        let reconnectMessage1 = try mallory.initiateHandshake(with: ble.myPeerID)
        let reconnectPacket = BitchatPacket(
            type: MessageType.noiseHandshake.rawValue,
            senderID: Data(hexString: alicePeerID.id) ?? Data(),
            recipientID: Data(hexString: ble.myPeerID.id),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1_000),
            payload: reconnectMessage1,
            signature: nil,
            ttl: 7
        )
        ble._test_handlePacket(reconnectPacket, fromPeerID: alicePeerID)
        // The responder's message 2 is a monotonic quarantine signal; the
        // secure-delivery dip itself only lasts until the responder deadline,
        // which parallel test load can outrun. (The recovery gate keeps the
        // convergence retry's message 1 out of the tap until released.)
        let responderReady = await TestHelpers.waitUntil(
            { outbound.count(ofType: .noiseHandshake) >= 1 },
            timeout: TestConstants.longTimeout
        )
        try #require(responderReady)
        #expect(outbound.count(ofType: .noiseEncrypted) == 0)

        // The responder timeout restores the quarantined generation; the
        // gate guarantees its handler runs before the convergence retry.
        let restoreRan = await TestHelpers.waitUntil(
            { reconciled.count(for: alicePeerID) == 1 },
            timeout: TestConstants.longTimeout
        )
        try #require(restoreRan)
        #expect(ble.canDeliverSecurely(to: alicePeerID))
        await ble._test_drainNoiseMessagePipeline()
        // The parked queues must not have been encrypted under the restored
        // old generation the remote may no longer be able to read.
        #expect(outbound.count(ofType: .noiseEncrypted) == 0)

        // Release the mandatory convergence retry: it retires the restored
        // session and starts a fresh XX exchange with the live peer.
        recoveryGate.release()
        let retryStarted = await TestHelpers.waitUntil(
            {
                outbound.snapshot().contains {
                    $0.type == MessageType.noiseHandshake.rawValue
                        && PeerID(hexData: $0.senderID) == ble.myPeerID
                        && $0.payload.count
                            == NoiseSecurityConstants.xxInitialMessageSize
                }
            },
            timeout: TestConstants.longTimeout
        )
        try #require(retryStarted)
        #expect(outbound.count(ofType: .noiseEncrypted) == 0)
        let retryMessage1 = try #require(
            outbound.snapshot().last {
                $0.type == MessageType.noiseHandshake.rawValue
                    && PeerID(hexData: $0.senderID) == ble.myPeerID
                    && $0.payload.count
                        == NoiseSecurityConstants.xxInitialMessageSize
            }?.payload
        )

        // Alice answers the retry as the restarted peer she models: her old
        // session is gone, so the retry is a fresh responder exchange (and
        // never the initiator-completion grace deferral, whose lower-peerID
        // arm would otherwise coalesce the retry for random key orderings).
        alice.clearSession(for: ble.myPeerID)
        let retryMessage2 = try #require(
            try alice.processHandshakeMessage(
                from: ble.myPeerID,
                message: retryMessage1
            )
        )
        let retryPacket = BitchatPacket(
            type: MessageType.noiseHandshake.rawValue,
            senderID: Data(hexString: alicePeerID.id) ?? Data(),
            recipientID: Data(hexString: ble.myPeerID.id),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1_000) + 1,
            payload: retryMessage2,
            signature: nil,
            ttl: 7
        )
        ble._test_handlePacket(retryPacket, fromPeerID: alicePeerID)
        let drained = await TestHelpers.waitUntil(
            { outbound.count(ofType: .noiseEncrypted) >= 3 },
            timeout: TestConstants.longTimeout
        )
        try #require(drained)
        await ble._test_drainNoiseMessagePipeline()

        // Alice completes with message 3, then must be able to decrypt every
        // drained payload — proving nothing left under the old generation.
        let retryMessage3 = try #require(
            outbound.snapshot().last {
                $0.type == MessageType.noiseHandshake.rawValue
                    && PeerID(hexData: $0.senderID) == ble.myPeerID
                    && $0.payload.count
                        != NoiseSecurityConstants.xxInitialMessageSize
            }?.payload
        )
        _ = try alice.processHandshakeMessage(
            from: ble.myPeerID,
            message: retryMessage3
        )
        let plaintexts = try outbound.snapshot()
            .filter { $0.type == MessageType.noiseEncrypted.rawValue }
            .map { try alice.decrypt($0.payload, from: ble.myPeerID) }
        #expect(plaintexts.count == 3)
        #expect(
            plaintexts.filter {
                $0.first == NoisePayloadType.authenticatedPeerState.rawValue
            }.count == 1
        )
        #expect(
            plaintexts.filter {
                $0.first == NoisePayloadType.privateMessage.rawValue
            }.count == 1
        )
        #expect(
            plaintexts.filter {
                $0.first == NoisePayloadType.vouch.rawValue
            }.count == 1
        )
    }

    /// A legitimate rotation announce necessarily arrives on a link still
    /// bound to the OLD ID, so its registry upsert stores the new peer
    /// disconnected. The successful rebind must promote it: a healed
    /// rotation with a live link has to read as connected again for routing
    /// and outbox flushes.
    @Test
    func rotationHealPromotesRotatedPeerToConnected() async throws {
        let ble = makeService()
        let oldPeerID = PeerID(str: "1122334455667788")
        let centralUUID = "central-rotation-promote"

        ble._test_seedConnectedPeer(oldPeerID, nickname: "alice")
        ble._test_bindCentral(centralUUID, to: oldPeerID)

        let signer = NoiseEncryptionService(keychain: MockKeychain())
        let announcement = AnnouncementPacket(
            nickname: "alice",
            noisePublicKey: signer.getStaticPublicKeyData()!,
            signingPublicKey: signer.getSigningPublicKeyData()!,
            directNeighbors: nil
        )
        let payload = try #require(announcement.encode(), "Failed to encode announcement")
        let newPeerID = PeerID(publicKey: announcement.noisePublicKey)
        let unsigned = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: newPeerID.id) ?? Data(),
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )
        let packet = try #require(signer.signPacket(unsigned), "Failed to sign announce packet")

        #expect(ble._test_recordIngressIfNew(packet: packet, linkID: centralUUID))
        ble._test_handlePacket(packet, fromPeerID: newPeerID, preseedPeer: false)

        let rebound = await TestHelpers.waitUntil(
            { ble._test_centralBinding(centralUUID) == newPeerID },
            timeout: TestConstants.longTimeout
        )
        #expect(rebound)

        let connected = await TestHelpers.waitUntil(
            { ble.isPeerConnected(newPeerID) },
            timeout: TestConstants.longTimeout
        )
        #expect(connected)
    }

    /// Noise sessions are keyed by the short wire ID, but routers may key
    /// sends by the full 64-hex Noise key (favorites resolution does). The
    /// secure-delivery gate must normalize like isPeerConnected, or an
    /// established session is misread as insecure and every DM needlessly
    /// retains + couriers until an ack.
    @Test
    func canDeliverSecurelyNormalizesFullNoiseKeyPeerIDs() async throws {
        let ble = makeService()
        let remote = NoiseEncryptionService(keychain: MockKeychain())
        let remoteKey = remote.getStaticPublicKeyData()!
        let shortID = PeerID(publicKey: remoteKey)
        let fullKeyID = PeerID(hexData: remoteKey)
        #expect(fullKeyID.toShort() == shortID)
        #expect(!ble.canDeliverSecurely(to: shortID))

        // Full XX handshake; the local side keys the session by the short
        // wire ID, exactly as packets present it in production.
        let m1 = try ble._test_noiseInitiateHandshake(with: shortID)
        let m2 = try #require(try remote.processHandshakeMessage(from: ble.myPeerID, message: m1))
        let m3 = try #require(try ble._test_noiseProcessHandshakeMessage(from: shortID, message: m2))
        _ = try remote.processHandshakeMessage(from: ble.myPeerID, message: m3)

        #expect(ble.canDeliverSecurely(to: shortID))
        #expect(ble.canDeliverSecurely(to: fullKeyID))
    }

    @Test
    func ingressRejectsSelfLoopbackBeforeSpoofChecks() async throws {
        let ble = makeService()
        let packet = makePublicPacket(
            content: "Loopback",
            sender: ble.myPeerID,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        #expect(!ble._test_acceptsIngress(packet: packet, boundPeerID: PeerID(str: "1122334455667788")))
    }

    @Test
    func ingressAllowsSelfAuthoredRSRWithTTLZeroFromBoundPeer() async throws {
        let ble = makeService()
        var packet = makePublicPacket(
            content: "Recovered by sync",
            sender: ble.myPeerID,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000)
        )
        packet.isRSR = true
        packet.ttl = 0

        #expect(ble._test_acceptsIngress(packet: packet, boundPeerID: PeerID(str: "1122334455667788")))
    }

    @Test
    func ingressRecordSuppressesSecondLinkDuplicate() async throws {
        let ble = makeService()
        let packet = makePublicPacket(
            content: "Duplicate link copy",
            sender: PeerID(str: "1122334455667788"),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        #expect(ble._test_recordIngressIfNew(packet: packet, linkID: "central-a"))
        #expect(!ble._test_recordIngressIfNew(packet: packet, linkID: "central-b"))
    }

    @Test
    func panicReset_rotatesPeerIDDerivedFromNewNoiseFingerprint() async throws {
        let ble = makeService()
        let originalPeerID = ble.myPeerID
        let originalFingerprint = ble.noiseIdentityFingerprint()
        #expect(originalPeerID == PeerID(str: originalFingerprint.prefix(16)))

        ble.resetIdentityForPanic(currentNickname: "anon")

        // The Noise identity is regenerated and the peer ID swaps with it
        // (atomically, behind a messageQueue barrier).
        let newFingerprint = ble.noiseIdentityFingerprint()
        #expect(newFingerprint != originalFingerprint)
        #expect(ble.myPeerID != originalPeerID)
        #expect(ble.myPeerID == PeerID(str: newFingerprint.prefix(16)))
    }

    @Test
    func panicSuspension_dropsLateOutboundWorkUntilCommit() async {
        let ble = makeService()
        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record
        let packet = makePublicPacket(
            content: "late callback",
            sender: ble.myPeerID,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000)
        )

        ble.suspendForPanicReset()
        ble.sendPacket(packet)
        #expect(outbound.count(ofType: .message) == 0)

        ble.completePanicReset(restartServices: false)
        // Resume this hermetic transport explicitly; Bluetooth managers remain disabled.
        ble.startServices()
        ble.sendPacket(packet)
        #expect(outbound.count(ofType: .message) == 1)
    }

    @Test @MainActor
    func panicSuspension_invalidatesQueuedMainActorIngress() async {
        let ble = makeService()
        let delegate = TransportEventCaptureDelegate()
        ble.eventDelegate = delegate
        let message = BitchatMessage(
            id: "pre-panic-ingress",
            sender: "Peer",
            content: "must not survive panic",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Me",
            senderPeerID: PeerID(str: "1122334455667788")
        )

        // The test already owns MainActor, so this task cannot run until the
        // synchronous panic boundary below has invalidated its generation.
        ble._test_emitTransportEvent(.messageReceived(message))
        ble.suspendForPanicReset()
        await Task.yield()
        #expect(delegate.messageIDs.isEmpty)

        ble.completePanicReset(restartServices: false)
        // Resume this hermetic transport explicitly; Bluetooth managers remain disabled.
        ble.startServices()
        ble._test_emitTransportEvent(.messageReceived(message))
        await Task.yield()
        #expect(delegate.messageIDs == [message.id])
    }

    @Test @MainActor
    func panicSuspension_rejectsPausedBLEReceiveBeforeMessageQueueHandoff() async {
        let ble = makeService()
        let gate = ReceivePacketHandoffGate()
        ble._test_beforeReceivePacketHandoff = gate.pause
        ble._test_onReceivePacketHandoff = gate.recordHandoff
        defer {
            gate.release()
            ble._test_beforeReceivePacketHandoff = nil
            ble._test_onReceivePacketHandoff = nil
        }

        let sender = PeerID(str: "1122334455667788")
        let packet = makePublicPacket(
            content: "must not cross panic",
            sender: sender,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000)
        )
        ble._test_handlePacketFromBLEQueue(packet, fromPeerID: sender)
        #expect(await TestHelpers.waitUntil(
            { gate.hasPaused },
            timeout: TestConstants.longTimeout
        ))

        // Panic closes the lifecycle before waiting for the paused bleQueue
        // callback. Releasing it afterward lets the callback enqueue its
        // messageQueue handoff, where the captured generation must be rejected
        // before packet processing starts.
        let panicIngressObserver = PanicIngressObserver(service: ble)
        let didObservePanicClosure = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let didObserveClosure = panicIngressObserver.waitUntilClosed(
                    timeout: TestConstants.settleTimeout
                )
                gate.release()
                continuation.resume(returning: didObserveClosure)
            }
            ble.suspendForPanicReset()
        }

        #expect(didObservePanicClosure)
        #expect(gate.handoffCount == 0)

        // A packet captured under the reopened lifecycle still crosses the
        // same handoff, proving the test did not merely disable the hook.
        ble.completePanicReset(restartServices: false)
        // Resume this hermetic transport explicitly; Bluetooth managers remain disabled.
        ble.startServices()
        ble._test_handlePacketFromBLEQueue(packet, fromPeerID: sender)
        #expect(await TestHelpers.waitUntil(
            { gate.handoffCount == 1 },
            timeout: TestConstants.longTimeout
        ))
    }

    @Test
    func modifiedServices_rediscoverWhenBitChatServiceIsInvalidated() async throws {
        let otherService = CBUUID(string: "0000180F-0000-1000-8000-00805F9B34FB")

        #expect(BLEService._test_shouldRediscoverBitChatService(
            invalidatedServiceUUIDs: [BLEService.serviceUUID],
            cachedServiceUUIDs: [otherService]
        ))
    }

    @Test
    func modifiedServices_rediscoverWhenCachedServicesNoLongerIncludeBitChat() async throws {
        let otherService = CBUUID(string: "0000180F-0000-1000-8000-00805F9B34FB")

        #expect(BLEService._test_shouldRediscoverBitChatService(
            invalidatedServiceUUIDs: [otherService],
            cachedServiceUUIDs: [otherService]
        ))
    }

    @Test
    func modifiedServices_ignoreUnrelatedInvalidationWhenBitChatIsStillCached() async throws {
        let otherService = CBUUID(string: "0000180F-0000-1000-8000-00805F9B34FB")

        #expect(!BLEService._test_shouldRediscoverBitChatService(
            invalidatedServiceUUIDs: [otherService],
            cachedServiceUUIDs: [BLEService.serviceUUID, otherService]
        ))
    }

    /// Pings are unsigned, so their claimed sender is attacker-controlled.
    /// The pong budget must be keyed on the ingress link (the directly
    /// connected peer that delivered the packet): rotating forged sender IDs
    /// over one link exhausts one budget instead of resetting it, so a single
    /// malicious link cannot turn /ping into an amplification primitive.
    @Test
    func meshPingResponseBudget_isPerIngressLinkNotClaimedSender() async throws {
        let ble = makeService()
        let outbound = OutboundPacketTap()
        ble._test_onOutboundPacket = outbound.record

        let link = PeerID(str: "1122334455667788")
        let budget = TransportConfig.meshPingInboundMaxPerLink
        let myRecipientData = try #require(Data(hexString: ble.myPeerID.id))

        for i in 0..<(budget * 2) {
            // A fresh forged sender for every ping, all arriving on one link.
            let forgedSender = PeerID(str: String(format: "%016x", 0xA0_0000 + i))
            var nonce = Data(repeating: 0, count: MeshPingPayload.nonceLength)
            nonce[0] = UInt8(i)
            let payload = try #require(MeshPingPayload(nonce: nonce, originTTL: 7))
            let packet = BitchatPacket(
                type: MessageType.ping.rawValue,
                senderID: Data(hexString: forgedSender.id) ?? Data(),
                recipientID: myRecipientData,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: payload.encode(),
                signature: nil,
                ttl: 7
            )
            ble._test_handlePacket(packet, fromPeerID: link, preseedPeer: false)
        }

        let reachedBudget = await TestHelpers.waitUntil(
            { outbound.count(ofType: .pong) >= budget },
            timeout: TestConstants.longTimeout
        )
        #expect(reachedBudget)
        // Give any over-budget pong a chance to surface, then confirm the
        // rotated sender IDs never bought a sixth response.
        let exceededBudget = await TestHelpers.waitUntil(
            { outbound.count(ofType: .pong) > budget },
            timeout: TestConstants.negativeWaitWindow
        )
        #expect(!exceededBudget)
        #expect(outbound.count(ofType: .pong) == budget)
    }
}

/// Thread-safe capture of packets leaving the service under test.
private final class OutboundPacketTap {
    private let lock = NSLock()
    private var packets: [BitchatPacket] = []

    func record(_ packet: BitchatPacket) {
        lock.lock(); packets.append(packet); lock.unlock()
    }

    func count(ofType type: MessageType) -> Int {
        lock.lock(); defer { lock.unlock() }
        return packets.filter { $0.type == type.rawValue }.count
    }

    func snapshot() -> [BitchatPacket] {
        lock.lock(); defer { lock.unlock() }
        return packets
    }
}

/// Blocks the convergence-recovery callback on its global-queue thread so a
/// test can prove the quarantine-restore handler wins the messageQueue race.
private final class HandshakeRecoveryEnqueueGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false

    func pause() {
        condition.lock()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Thread-safe counter for `_test_onNoiseSessionReconciled` firings.
private final class SessionReconcileCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reconciles: [PeerID] = []

    func record(_ peerID: PeerID) {
        lock.lock()
        reconciles.append(peerID)
        lock.unlock()
    }

    func count(for peerID: PeerID) -> Int {
        lock.lock(); defer { lock.unlock() }
        return reconciles.filter { $0 == peerID }.count
    }
}

private final class ReceivePacketHandoffGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var released = false
    private var recordedHandoffCount = 0

    var hasPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused
    }

    var handoffCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return recordedHandoffCount
    }

    func pause() {
        condition.lock()
        paused = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func recordHandoff() {
        condition.lock()
        recordedHandoffCount += 1
        condition.unlock()
    }
}

/// Lets a dedicated dispatch worker observe the lock-protected panic gate
/// without treating the full BLE service as generally Sendable.
private final class PanicIngressObserver: @unchecked Sendable {
    private let service: BLEService

    init(service: BLEService) {
        self.service = service
    }

    func waitUntilClosed(timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeout * 1_000_000_000)
        while service._test_isPanicIngressOpen,
              DispatchTime.now().uptimeNanoseconds < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        return !service._test_isPanicIngressOpen
    }
}

private func makeService(
    keychain: MockKeychain = MockKeychain(),
    noiseResponderHandshakeTimeout: TimeInterval =
        NoiseSecurityConstants.ordinaryResponderHandshakeTimeout,
    engineScheduler: BLEEngineScheduling = BLEEngineDispatchScheduler(),
    requestSyncManager: RequestSyncManager = RequestSyncManager()
) -> BLEService {
    let identityManager = MockIdentityManager(keychain)
    let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
    return BLEService(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: identityManager,
        initializeBluetoothManagers: false,
        noiseResponderHandshakeTimeout: noiseResponderHandshakeTimeout,
        engineScheduler: engineScheduler,
        requestSyncManager: requestSyncManager
    )
}

/// Three identities: a local requester, a bound relay, and the original
/// author. Frames enter through the same link attribution as CoreBluetooth.
private struct FragmentedSyncFixture {
    let ble: BLEService
    let author: PeerID
    let responder = PeerID(str: "1122334455667788")
    let link = BLEIngressLinkID.central("fragment-sync-responder")
    let publicMessages: PublicCaptureDelegate
    let fragments: [BitchatPacket]
    let content: String
    let type: MessageType

    var wasDelivered: Bool {
        type == .message
            ? publicMessages.publicMessagesSnapshot().count == 1
            : ble._test_hasGossipPrekeyBundle(for: author)
    }
}

private func makeFragmentedSyncFixture(
    type: MessageType,
    manager: RequestSyncManager,
    corruptSignature: Bool = false
) throws -> FragmentedSyncFixture {
    let ble = makeService(requestSyncManager: manager)
    ble.prekeyBundleStore = PrekeyBundleStore(persistsToDisk: false)
    let capture = PublicCaptureDelegate()
    ble.delegate = capture
    let author = NoiseEncryptionService(keychain: MockKeychain())
    let noiseKey = try #require(author.getStaticPublicKeyData())
    let signingKey = try #require(author.getSigningPublicKeyData())
    let authorID = PeerID(publicKey: noiseKey)
    let authorData = try #require(Data(hexString: authorID.id))
    let responder = PeerID(str: "1122334455667788")
    ble._test_bindCentral("fragment-sync-responder", to: responder)
    let nowMs = UInt64(Date().timeIntervalSince1970 * 1_000)
    // Pin the author's verified identity without scheduling an unrelated
    // initial sync to that author, which could mask the responder defect.
    ble._test_seedConnectedPeer(authorID, nickname: "Synthetic author",
                               noisePublicKey: noiseKey,
                               signingPublicKey: signingKey)

    // Fixed pseudorandom text stays incompressible enough to span several
    // fragments without a probabilistic fixture or external data.
    var state: UInt64 = 0x6a09e667f3bcc909
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789 ")
    let content = String((0..<1_200).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return alphabet[Int((state >> 32) % UInt64(alphabet.count))]
    })
    let payload: Data
    if type == .message {
        payload = Data(content.utf8)
    } else {
        let bundle = try #require(author.currentPrekeyBundle())
        payload = try #require(bundle.encode())
    }
    var packet = try #require(author.signPacket(BitchatPacket(
        type: type.rawValue, senderID: authorData,
        recipientID: nil, timestamp: nowMs, payload: payload, signature: nil, ttl: 0
    )))
    // Gossip preserves the author's signature and marks the replay as RSR.
    packet.isRSR = true
    if corruptSignature { packet.signature = Data(repeating: 0, count: 64) }
    let plan = try #require(BLEOutboundFragmentPlanner.makePlan(
        for: BLEOutboundFragmentTransferRequest(packet: packet, pad: false, maxChunk: 128, directedPeer: ble.myPeerID),
        defaultChunkSize: TransportConfig.bleDefaultFragmentSize, bleMaxMTU: 512,
        fragmentID: Data([0x43, 0x37, 0x98, 0x21, 0x14, 0x65, 0x72, 0x08])
    ))
    #expect(plan.totalFragments > 1)
    #expect(plan.fragmentPackets.allSatisfy { $0.isRSR && $0.ttl == 0 && $0.recipientID == Data(hexString: ble.myPeerID.id) })
    return FragmentedSyncFixture(ble: ble, author: authorID, publicMessages: capture,
                                 fragments: plan.fragmentPackets, content: content, type: type)
}

private final class FragmentSyncClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_000
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(by interval: TimeInterval) { lock.lock(); defer { lock.unlock() }; value += interval }
}

private func makePublicPacket(content: String, sender: PeerID, timestamp: UInt64) -> BitchatPacket {
    BitchatPacket(
        type: MessageType.message.rawValue,
        senderID: Data(hexString: sender.id) ?? Data(),
        recipientID: nil,
        timestamp: timestamp,
        payload: Data(content.utf8),
        signature: nil,
        ttl: 3
    )
}

private func makeLeavePacket(sender: PeerID, marker: String) -> BitchatPacket {
    BitchatPacket(
        type: MessageType.leave.rawValue,
        senderID: Data(hexString: sender.id) ?? Data(),
        recipientID: nil,
        timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
        payload: Data(marker.utf8),
        signature: nil,
        ttl: TransportConfig.messageTTLDefault
    )
}

private final class PublicCaptureDelegate: BitchatDelegate {
    private let lock = NSLock()
    private(set) var publicMessages: [BitchatMessage] = []

    func didReceivePublicMessage(from peerID: PeerID, nickname: String, content: String, timestamp: Date, messageID: String?) {
        let message = BitchatMessage(
            id: messageID,
            sender: nickname,
            content: content,
            timestamp: timestamp,
            isRelay: false,
            originalSender: nil,
            isPrivate: false,
            recipientNickname: nil,
            senderPeerID: peerID,
            mentions: nil
        )
        lock.lock()
        publicMessages.append(message)
        lock.unlock()
    }

    func didReceiveMessage(_ message: BitchatMessage) {}
    func didConnectToPeer(_ peerID: PeerID) {}
    func didDisconnectFromPeer(_ peerID: PeerID) {}
    func didUpdatePeerList(_ peers: [PeerID]) {}
    func didUpdateBluetoothState(_ state: CBManagerState) {}

    func publicMessagesSnapshot() -> [BitchatMessage] {
        lock.lock()
        defer { lock.unlock() }
        return publicMessages
    }

}

@MainActor
private final class TransportEventCaptureDelegate: TransportEventDelegate {
    private(set) var messageIDs: [String] = []
    private(set) var noisePayloadTypes: [NoisePayloadType] = []

    func didReceiveTransportEvent(_ event: TransportEvent) {
        switch event {
        case .messageReceived(let message):
            messageIDs.append(message.id)
        case let .noisePayloadReceived(_, type, _, _):
            noisePayloadTypes.append(type)
        default:
            break
        }
    }
}

@MainActor
private final class NoiseIdentityEventRecorder: TransportEventDelegate {
    private(set) var states: [NoiseIdentityAvailability] = []
    func didReceiveTransportEvent(_ event: TransportEvent) {
        if case .noiseIdentityAvailabilityUpdated(let state) = event { states.append(state) }
    }
}

private final class NoiseIdentityStorageGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    var hasBlocked: Bool {
        condition.lock(); defer { condition.unlock() }
        return entered
    }
    func block() {
        condition.lock(); defer { condition.unlock() }
        entered = true
        condition.broadcast()
        while !released { condition.wait() }
    }
    func release() {
        condition.lock(); defer { condition.unlock() }
        released = true
        condition.broadcast()
    }
}
