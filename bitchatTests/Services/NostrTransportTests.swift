//
// NostrTransportTests.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Combine
import Foundation
import Testing
import BitFoundation
@testable import bitchat

@Suite("NostrTransport Tests")
struct NostrTransportTests {
    typealias FavoriteRelationship = FavoritesPersistenceService.FavoriteRelationship

    @Test("Warm cache marks full and short IDs reachable")
    @MainActor
    func reachabilityCacheWarmsFromFavorites() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let recipient = try NostrIdentity.generate()
        let noiseKey = Data((0..<32).map(UInt8.init))
        let fullPeerID = PeerID(hexData: noiseKey)
        let shortPeerID = fullPeerID.toShort()
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Alice"
        )
        let favorites = [noiseKey: relationship]

        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            dependencies: makeDependencies(
                loadFavorites: { favorites },
                favoriteStatusForNoiseKey: { favorites[$0] },
                favoriteStatusForPeerID: { $0 == shortPeerID ? relationship : nil },
                currentIdentity: { nil }
            )
        )

        // Offline favorites are addressed by the full 64-hex noise key, so
        // both forms must resolve to the same reachability answer.
        #expect(transport.isPeerReachable(fullPeerID))
        #expect(transport.isPeerReachable(shortPeerID))
        #expect(!transport.isPeerReachable(PeerID(str: "feedfeedfeedfeed")))
    }

    @Test("Favorite status notification refreshes reachability cache")
    @MainActor
    func favoriteStatusNotificationRefreshesReachability() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let recipient = try NostrIdentity.generate()
        let noiseKey = Data((32..<64).map(UInt8.init))
        let peerID = PeerID(hexData: noiseKey).toShort()
        let notificationCenter = NotificationCenter()
        var favorites: [Data: FavoriteRelationship] = [:]

        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            dependencies: makeDependencies(
                notificationCenter: notificationCenter,
                loadFavorites: { favorites },
                favoriteStatusForNoiseKey: { favorites[$0] },
                favoriteStatusForPeerID: { _ in favorites.values.first },
                currentIdentity: { nil }
            )
        )

        #expect(!transport.isPeerReachable(peerID))

        favorites[noiseKey] = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Bob"
        )
        notificationCenter.post(name: .favoriteStatusChanged, object: nil)

        let didRefresh = await TestHelpers.waitUntil({ transport.isPeerReachable(peerID) }, timeout: 5.0)
        #expect(didRefresh)
    }

    @Test("Prompt delivery requires both a known npub and a relay connection")
    @MainActor
    func canDeliverPromptlyTracksRelayConnectivity() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let recipient = try NostrIdentity.generate()
        let noiseKey = Data((0..<32).map(UInt8.init))
        let peerID = PeerID(hexData: noiseKey)
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Alice"
        )
        let connectivity = CurrentValueSubject<Bool, Never>(false)

        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            dependencies: makeDependencies(
                loadFavorites: { [noiseKey: relationship] },
                relayConnectivity: { connectivity.eraseToAnyPublisher() }
            )
        )

        // Reachable (npub known) but relays down: the peer must not be
        // treated as promptly deliverable, or the router would skip the
        // courier and let the message rot in the Nostr send queue.
        #expect(transport.isPeerReachable(peerID))
        #expect(!transport.canDeliverPromptly(to: peerID))

        connectivity.send(true)
        let deliverable = await TestHelpers.waitUntil(
            { transport.canDeliverPromptly(to: peerID) },
            timeout: 5.0
        )
        #expect(deliverable)

        connectivity.send(false)
        let undeliverable = await TestHelpers.waitUntil(
            { !transport.canDeliverPromptly(to: peerID) },
            timeout: 5.0
        )
        #expect(undeliverable)
    }

    @Test("Private message resolves short peer ID and emits decryptable packet")
    @MainActor
    func sendPrivateMessageResolvesShortPeerID() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let noiseKey = Data((64..<96).map(UInt8.init))
        let shortPeerID = PeerID(hexData: noiseKey).toShort()
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Carol"
        )
        let probe = NostrTransportProbe()
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: { _ in nil },
                favoriteStatusForPeerID: { $0 == shortPeerID ? relationship : nil },
                currentIdentity: { sender },
                registerPendingGiftWrap: probe.recordPendingGiftWrap(id:),
                sendEvent: probe.record(event:),
                scheduleAfter: { delay, action in
                    probe.enqueueScheduledAction(delay: delay, action: action)
                }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        transport.sendPrivateMessage("hello over nostr", to: shortPeerID, recipientNickname: "Carol", messageID: "pm-1")

        let didSend = await TestHelpers.waitUntil({ probe.sentEvents.count == 1 }, timeout: TestConstants.settleTimeout)
        #expect(didSend)
        let result = try decodeEmbeddedPayload(from: probe.sentEvents[0], recipient: recipient)
        let privateMessage = try decodePrivateMessage(from: result.payload)

        #expect(result.senderPubkey == sender.publicKeyHex)
        #expect(privateMessage.messageID == "pm-1")
        #expect(privateMessage.content == "hello over nostr")
        #expect(result.packet.recipientID == shortPeerID.routingData)
        // Favorites DMs keep the mesh sender ID: the recipient already binds
        // this npub to our Noise key.
        #expect(result.packet.senderID == transport.senderPeerID.routingData)
        #expect(probe.pendingGiftWrapIDs.isEmpty)
    }

    @Test("Favorite notification embeds current npub")
    @MainActor
    func sendFavoriteNotificationEmbedsCurrentIdentity() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let noiseKey = Data((96..<128).map(UInt8.init))
        let fullPeerID = PeerID(hexData: noiseKey)
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Dan"
        )
        let probe = NostrTransportProbe()
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: { $0 == noiseKey ? relationship : nil },
                favoriteStatusForPeerID: { _ in nil },
                currentIdentity: { sender },
                registerPendingGiftWrap: probe.recordPendingGiftWrap(id:),
                sendEvent: probe.record(event:),
                scheduleAfter: { delay, action in
                    probe.enqueueScheduledAction(delay: delay, action: action)
                }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        transport.sendFavoriteNotification(to: fullPeerID, isFavorite: true)

        let didSend = await TestHelpers.waitUntil({ probe.sentEvents.count == 1 }, timeout: TestConstants.settleTimeout)
        #expect(didSend)
        let result = try decodeEmbeddedPayload(from: probe.sentEvents[0], recipient: recipient)
        let privateMessage = try decodePrivateMessage(from: result.payload)

        #expect(privateMessage.content == "[FAVORITED]:\(sender.npub)")
    }

    @Test("Delivery ACK encodes delivered payload type")
    @MainActor
    func sendDeliveryAckEmitsDeliveredAck() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let noiseKey = Data((128..<160).map(UInt8.init))
        let fullPeerID = PeerID(hexData: noiseKey)
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Eve"
        )
        let probe = NostrTransportProbe()
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: { $0 == noiseKey ? relationship : nil },
                favoriteStatusForPeerID: { _ in nil },
                currentIdentity: { sender },
                registerPendingGiftWrap: probe.recordPendingGiftWrap(id:),
                sendEvent: probe.record(event:),
                scheduleAfter: { delay, action in
                    probe.enqueueScheduledAction(delay: delay, action: action)
                }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        transport.sendDeliveryAck(for: "ack-1", to: fullPeerID)

        let didSend = await TestHelpers.waitUntil({ probe.sentEvents.count == 1 }, timeout: TestConstants.settleTimeout)
        #expect(didSend)
        let result = try decodeEmbeddedPayload(from: probe.sentEvents[0], recipient: recipient)

        #expect(result.payload.type == .delivered)
        #expect(String(data: result.payload.data, encoding: .utf8) == "ack-1")
        #expect(result.packet.recipientID == fullPeerID.toShort().routingData)
        #expect(result.packet.senderID == transport.senderPeerID.routingData)
    }

    @Test("Geohash private message registers pending gift wrap")
    @MainActor
    func sendPrivateMessageForNostrIdentityRegistersPendingGiftWrap() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let probe = NostrTransportProbe()
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            dependencies: makeDependencies(
                currentIdentity: { sender },
                registerPendingGiftWrap: probe.recordPendingGiftWrap(id:),
                sendEvent: probe.record(event:),
                scheduleAfter: { delay, action in
                    probe.enqueueScheduledAction(delay: delay, action: action)
                }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        transport.sendPrivateMessageForNostrIdentity(
            content: "geo hello",
            toRecipientHex: recipient.publicKeyHex,
            from: sender,
            messageID: "geo-1"
        )

        let didSend = await TestHelpers.waitUntil({ probe.sentEvents.count == 1 }, timeout: TestConstants.settleTimeout)
        #expect(didSend)
        let event = probe.sentEvents[0]
        let result = try decodeEmbeddedPayload(from: event, recipient: recipient)
        let privateMessage = try decodePrivateMessage(from: result.payload)

        #expect(privateMessage.messageID == "geo-1")
        #expect(privateMessage.content == "geo hello")
        #expect(result.packet.recipientID == nil)
        #expect(probe.pendingGiftWrapIDs == [event.id])
    }

    @Test("Geohash envelopes never carry the mesh peer ID")
    @MainActor
    func explicitIdentityEnvelopesNeverCarryMeshPeerID() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let probe = NostrTransportProbe()
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            dependencies: makeDependencies(
                currentIdentity: { sender },
                registerPendingGiftWrap: probe.recordPendingGiftWrap(id:),
                sendEvent: probe.record(event:),
                scheduleAfter: { delay, action in
                    probe.enqueueScheduledAction(delay: delay, action: action)
                }
            )
        )
        // Even a transport that knows the mesh peer ID must not embed it
        // under a geohash identity: whoever receives the envelope (including
        // the automatic DELIVERED ack) could link that persona to the device.
        let meshPeerID = PeerID(str: "0123456789abcdef")
        let meshIDBytes = try #require(meshPeerID.routingData)
        transport.senderPeerID = meshPeerID

        transport.sendPrivateMessageForNostrIdentity(
            content: "geo hello",
            toRecipientHex: recipient.publicKeyHex,
            from: sender,
            messageID: "geo-pm"
        )
        transport.sendDeliveryAckForNostrIdentity(for: "geo-delivered", toRecipientHex: recipient.publicKeyHex, from: sender)
        transport.sendReadReceiptForNostrIdentity("geo-read", toRecipientHex: recipient.publicKeyHex, from: sender)

        // The PM goes out directly; the two acks share the pacer, so the
        // second leaves only once the queued throttle action runs.
        let sentFirst = await TestHelpers.waitUntil(
            { probe.sentEvents.count == 2 && probe.scheduledActionCount == 1 },
            timeout: TestConstants.settleTimeout
        )
        try #require(sentFirst, "Expected the PM and the first paced ack")
        try #require(probe.runNextScheduledAction(), "Expected queued throttle action after first ack")
        let sentAll = await TestHelpers.waitUntil({ probe.sentEvents.count == 3 }, timeout: TestConstants.settleTimeout)
        try #require(sentAll, "Expected the second paced ack")

        let envelopes = try probe.sentEvents.map { try decodeEmbeddedPayload(from: $0, recipient: recipient) }
        #expect(Set(envelopes.map(\.payload.type)) == [.privateMessage, .delivered, .readReceipt])
        for envelope in envelopes {
            #expect(envelope.packet.recipientID == nil)
            #expect(envelope.packet.senderID.count == BinaryProtocol.senderIDSize)
            #expect(envelope.packet.senderID != meshIDBytes)
            #expect(envelope.packetData.range(of: meshIDBytes) == nil)
        }
        // Fresh random bytes per envelope, so the field can't tie two
        // envelopes (or two geohash identities) to one sender either.
        #expect(Set(envelopes.map(\.packet.senderID)).count == envelopes.count)
    }

    @Test("Read receipt queue sends in order and waits for scheduler")
    @MainActor
    func readReceiptQueueThrottlesSequentially() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let noiseKey = Data((160..<192).map(UInt8.init))
        let fullPeerID = PeerID(hexData: noiseKey)
        let relationship = makeRelationship(
            peerNoisePublicKey: noiseKey,
            peerNostrPublicKey: recipient.npub,
            peerNickname: "Frank"
        )
        let probe = NostrTransportProbe()
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: idBridge,
            dependencies: makeDependencies(
                favoriteStatusForNoiseKey: { $0 == noiseKey ? relationship : nil },
                favoriteStatusForPeerID: { _ in nil },
                currentIdentity: { sender },
                registerPendingGiftWrap: probe.recordPendingGiftWrap(id:),
                sendEvent: probe.record(event:),
                scheduleAfter: { delay, action in
                    probe.enqueueScheduledAction(delay: delay, action: action)
                }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        let first = ReadReceipt(originalMessageID: "read-1", readerID: transport.myPeerID, readerNickname: "Me")
        let second = ReadReceipt(originalMessageID: "read-2", readerID: transport.myPeerID, readerNickname: "Me")

        transport.sendReadReceipt(first, to: fullPeerID)
        transport.sendReadReceipt(second, to: fullPeerID)

        let readReceiptTimeout: TimeInterval = 5.0
        let sentFirst = await TestHelpers.waitUntil({ probe.sentEvents.count >= 1 }, timeout: readReceiptTimeout)
        try #require(sentFirst, "Expected first queued read receipt event")
        let scheduledThrottle = await TestHelpers.waitUntil({ probe.scheduledActionCount == 1 }, timeout: readReceiptTimeout)
        try #require(scheduledThrottle, "Expected queued throttle action after first read receipt")
        let firstEvent = try #require(probe.sentEvents.first, "Expected first queued read receipt event")
        let firstPayload = try decodeEmbeddedPayload(from: firstEvent, recipient: recipient).payload
        #expect(firstPayload.type == .readReceipt)
        #expect(String(data: firstPayload.data, encoding: .utf8) == "read-1")

        try #require(probe.runNextScheduledAction(), "Expected queued throttle action after first read receipt")

        let sentSecond = await TestHelpers.waitUntil({ probe.sentEvents.count >= 2 }, timeout: readReceiptTimeout)
        try #require(sentSecond, "Expected second read receipt after running throttle action")
        let secondEvent = try #require(probe.sentEvents.last, "Expected second queued read receipt event")
        let secondPayload = try decodeEmbeddedPayload(from: secondEvent, recipient: recipient).payload
        #expect(secondPayload.type == .readReceipt)
        #expect(String(data: secondPayload.data, encoding: .utf8) == "read-2")
        withExtendedLifetime(transport) {}
    }

    // These thread-safety tests must hammer from the dispatch pool
    // (concurrentPerform), NOT a task group: transport calls block in
    // queue.sync, and a 100-task group runs them on the Swift Concurrency
    // cooperative pool — one thread per core, just 3 on CI runners. Parking
    // every cooperative thread in a blocking sync violates the forward
    // progress contract and wedged dispatch on the CI runners' macOS,
    // deadlocking the whole app suite into the 15-minute job timeout
    // (watchdog stacks: NostrTransport.isPeerReachable syncs holding all
    // pool threads). Blocking is legal on dispatch worker threads.
    @Test("Concurrent read receipt enqueue does not crash")
    @MainActor
    func concurrentReadReceiptEnqueue() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let transport = NostrTransport(keychain: keychain, idBridge: idBridge)
        let iterations = 100

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                DispatchQueue.concurrentPerform(iterations: iterations) { i in
                    let receipt = ReadReceipt(
                        originalMessageID: UUID().uuidString,
                        readerID: PeerID(str: String(format: "%016x", i)),
                        readerNickname: "Reader\(i)"
                    )
                    let peerID = PeerID(str: String(format: "%016x", i))
                    transport.sendReadReceipt(receipt, to: peerID)
                }
                continuation.resume()
            }
        }
        withExtendedLifetime(transport) {}
    }

    @Test("isPeerReachable is thread safe")
    @MainActor
    func isPeerReachableThreadSafety() async throws {
        let keychain = MockKeychain()
        let idBridge = NostrIdentityBridge(keychain: keychain)
        let transport = NostrTransport(keychain: keychain, idBridge: idBridge)
        let iterations = 100

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                DispatchQueue.concurrentPerform(iterations: iterations) { i in
                    let peerID = PeerID(str: String(format: "%016x", i))
                    #expect(transport.isPeerReachable(peerID) == false)
                }
                continuation.resume()
            }
        }
        withExtendedLifetime(transport) {}
    }

    @Test("Wesh: only QR contacts with a bound npub, only while Internet is On, never favorites")
    @MainActor
    func weshReachabilityFollowsQRContactsAndInternetState() async throws {
        let keychain = MockKeychain()
        let sender = try NostrIdentity.generate()
        let contactNpub = try NostrIdentity.generate()
        let favoriteNpub = try NostrIdentity.generate()
        let contactKey = Data(repeating: 0x11, count: 32)
        let favoriteKey = Data(repeating: 0x22, count: 32)
        let contactPeer = PeerID(hexData: contactKey)
        let favoritePeer = PeerID(hexData: favoriteKey)
        let favorite = makeRelationship(peerNoisePublicKey: favoriteKey, peerNostrPublicKey: favoriteNpub.npub, peerNickname: "Fav")
        let recipients = CurrentValueSubject<[PeerID: String], Never>([contactPeer: contactNpub.npub])
        let online = CurrentValueSubject<Bool, Never>(false)
        final class Blocked { var keys: Set<Data> = [] }
        let blocked = Blocked()
        let probe = NostrTransportProbe()
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: keychain),
            dependencies: makeDependencies(
                loadFavorites: { [favoriteKey: favorite] },
                favoriteStatusForNoiseKey: { $0 == favoriteKey ? favorite : nil },
                currentIdentity: { sender },
                sendEvent: probe.record(event:),
                relayConnectivity: { Just(true).eraseToAnyPublisher() },
                weshRecipients: { recipients.eraseToAnyPublisher() },
                weshOnline: { online.eraseToAnyPublisher() },
                weshIsBlocked: { blocked.keys.contains($0) }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        // Fail closed while Internet mode is not On: nothing is reachable or sent.
        #expect(await TestHelpers.waitUntil({ !transport.isPeerReachable(contactPeer) }, timeout: TestConstants.settleTimeout))
        transport.sendPrivateMessage("too early", to: contactPeer, recipientNickname: "QR", messageID: "early")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(probe.sentEvents.isEmpty)

        online.send(true)
        #expect(await TestHelpers.waitUntil({ transport.isPeerReachable(contactPeer) }, timeout: TestConstants.settleTimeout))
        #expect(transport.isPeerReachable(contactPeer.toShort()))
        #expect(!transport.isPeerReachable(favoritePeer))

        transport.sendPrivateMessage("salut", to: contactPeer, recipientNickname: "QR", messageID: "pm-wesh")
        transport.sendPrivateMessage("nope", to: favoritePeer, recipientNickname: "Fav", messageID: "pm-fav")
        transport.sendFavoriteNotification(to: contactPeer, isFavorite: true)
        #expect(await TestHelpers.waitUntil({ probe.sentEvents.count == 1 }, timeout: TestConstants.settleTimeout))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(probe.sentEvents.count == 1)
        let result = try decodeEmbeddedPayload(from: probe.sentEvents[0], recipient: contactNpub)
        #expect(try decodePrivateMessage(from: result.payload).messageID == "pm-wesh")

        // A blocked contact is never sent anything, even if still in the map.
        blocked.keys = [contactKey]
        transport.sendPrivateMessage("blocked", to: contactPeer, recipientNickname: "QR", messageID: "pm-blocked")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(probe.sentEvents.count == 1)

        // A contact losing its npub (rescan, conflict) is no longer reachable.
        recipients.send([:])
        #expect(await TestHelpers.waitUntil({ !transport.isPeerReachable(contactPeer) }, timeout: TestConstants.settleTimeout))
    }

    @Test("Wesh: once Internet leaves On (as an erase forces), no message or ack is sent")
    @MainActor
    func weshSendsStopWhenInternetLeavesOn() async throws {
        let keychain = MockKeychain()
        let sender = try NostrIdentity.generate()
        let contactNpub = try NostrIdentity.generate()
        let contactPeer = PeerID(hexData: Data(repeating: 0x33, count: 32))
        let online = CurrentValueSubject<Bool, Never>(true)
        let probe = NostrTransportProbe()
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: keychain),
            dependencies: makeDependencies(
                currentIdentity: { sender },
                sendEvent: probe.record(event:),
                scheduleAfter: { delay, action in probe.enqueueScheduledAction(delay: delay, action: action) },
                relayConnectivity: { Just(true).eraseToAnyPublisher() },
                weshRecipients: { Just([contactPeer: contactNpub.npub]).eraseToAnyPublisher() },
                weshOnline: { online.eraseToAnyPublisher() },
                weshIsBlocked: { _ in false }
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")
        #expect(await TestHelpers.waitUntil({ transport.isPeerReachable(contactPeer) }, timeout: TestConstants.settleTimeout))
        transport.sendPrivateMessage("before", to: contactPeer, recipientNickname: "QR", messageID: "pm-before")
        #expect(await TestHelpers.waitUntil({ probe.sentEvents.count == 1 }, timeout: TestConstants.settleTimeout))

        online.send(false)
        #expect(await TestHelpers.waitUntil({ !transport.isPeerReachable(contactPeer) }, timeout: TestConstants.settleTimeout))
        transport.sendPrivateMessage("after", to: contactPeer, recipientNickname: "QR", messageID: "pm-after")
        transport.sendDeliveryAck(for: "ack-after", to: contactPeer)
        try await Task.sleep(nanoseconds: 100_000_000)
        while probe.runNextScheduledAction() {}
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(probe.sentEvents.count == 1)
    }

    @Test("A send captured before an erase is dropped when it runs")
    @MainActor
    func sendCapturedBeforeEraseIsDropped() async throws {
        let keychain = MockKeychain()
        let sender = try NostrIdentity.generate()
        let recipient = try NostrIdentity.generate()
        let probe = NostrTransportProbe()
        let pacer = NostrTransport.AckPacer(scheduleAfter: { delay, action in probe.enqueueScheduledAction(delay: delay, action: action) })
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: keychain),
            dependencies: makeDependencies(
                currentIdentity: { sender },
                sendEvent: probe.record(event:),
                ackPacer: pacer
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")

        // Still on the main actor: the send's Task has not run when the erase begins.
        transport.sendPrivateMessageForNostrIdentity(content: "before", toRecipientHex: recipient.publicKeyHex, from: sender, messageID: "pm-before")
        pacer.discardWorkBeforeErase()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(probe.sentEvents.isEmpty)

        transport.sendPrivateMessageForNostrIdentity(content: "after", toRecipientHex: recipient.publicKeyHex, from: sender, messageID: "pm-after")
        #expect(await TestHelpers.waitUntil({ probe.sentEvents.count == 1 }, timeout: TestConstants.settleTimeout))
    }

    @Test("Wesh PM: « Envoyé » only on relay OK; a retry republishes the same event until a refusal or an erase")
    @MainActor
    func privateMessageWrapIsReusedUntilRefusedOrErased() async throws {
        let keychain = MockKeychain()
        let sender = try NostrIdentity.generate()
        let contactNpub = try NostrIdentity.generate()
        let contactPeer = PeerID(hexData: Data(repeating: 0x44, count: 32))
        let relays = RelayAnswerProbe()
        let pacer = NostrTransport.AckPacer(scheduleAfter: { _, _ in })
        let transport = NostrTransport(
            keychain: keychain,
            idBridge: NostrIdentityBridge(keychain: keychain),
            dependencies: makeDependencies(
                currentIdentity: { sender },
                publishEvent: relays.publish,
                relayConnectivity: { Just(true).eraseToAnyPublisher() },
                weshRecipients: { Just([contactPeer: contactNpub.npub]).eraseToAnyPublisher() },
                weshOnline: { Just(true).eraseToAnyPublisher() },
                weshIsBlocked: { _ in false },
                ackPacer: pacer
            )
        )
        transport.senderPeerID = PeerID(str: "0123456789abcdef")
        var accepted: [String] = []
        transport.onPrivateMessageAccepted = { messageID, _ in accepted.append(messageID) }
        #expect(await TestHelpers.waitUntil({ transport.isPeerReachable(contactPeer) }, timeout: TestConstants.settleTimeout))

        func send() async -> NostrEvent? {
            let before = relays.events.count
            transport.sendPrivateMessage("salut", to: contactPeer, recipientNickname: "QR", messageID: "pm-1")
            guard await TestHelpers.waitUntil({ relays.events.count == before + 1 }, timeout: TestConstants.settleTimeout) else { return nil }
            return relays.events.last
        }

        // Handed to the relays, no answer yet, then a timeout: not « Envoyé », not refused.
        let first = try #require(await send())
        #expect(accepted.isEmpty)
        relays.answerLast(.unconfirmed)
        #expect(accepted.isEmpty)

        // The retry republishes the very same signed event.
        let retry = try #require(await send())
        #expect(retry.id == first.id)

        // An explicit refusal: the next retry signs a new wrap for the same message.
        relays.answerLast(.rejected)
        let rewrapped = try #require(await send())
        #expect(rewrapped.id != first.id)
        let payload = try decodeEmbeddedPayload(from: rewrapped, recipient: contactNpub).payload
        #expect(try decodePrivateMessage(from: payload).messageID == "pm-1")

        // A relay OK is what reports « Envoyé ».
        relays.answerLast(.accepted)
        #expect(accepted == ["pm-1"])

        // Once the router no longer holds the message, its wrap is forgotten.
        transport.retainPendingPrivateMessages([])
        let afterAck = try #require(await send())
        #expect(afterAck.id != rewrapped.id)

        // An erase makes the wrap unusable, and a late OK from before it reports nothing.
        pacer.discardWorkBeforeErase()
        relays.answerLast(.accepted)
        #expect(accepted == ["pm-1"])
        let afterErase = try #require(await send())
        #expect(afterErase.id != afterAck.id)
    }

    @Test("Wesh: the flush on On runs after the state really is On (Published emits in willSet)")
    @MainActor
    func weshFlushWhenOnSeesTheNewState() async {
        final class Mode: ObservableObject { @Published var state: WeshInternetState = .connecting(torProgress: 50) }
        final class Observed { var states: [WeshInternetState] = [] }
        let mode = Mode()
        let flushes = Observed()
        let cancellable = WeshInternetRoute.flushWhenOn(mode.$state) { flushes.states.append(mode.state) }
        mode.state = .on
        mode.state = .on
        #expect(await TestHelpers.waitUntil({ !flushes.states.isEmpty }, timeout: TestConstants.settleTimeout))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(flushes.states == [.on])
        mode.state = .connecting(torProgress: 10)
        mode.state = .on
        #expect(await TestHelpers.waitUntil({ flushes.states.count == 2 }, timeout: TestConstants.settleTimeout))
        withExtendedLifetime(cancellable) {}
    }

    @Test("Wesh route: conflicts, proof warnings, blocks and strangers never get an npub")
    func weshInternetRouteBindings() throws {
        let alice = try NostrIdentity.generate()
        let bob = try NostrIdentity.generate()
        let aliceKey = Data(repeating: 0x0a, count: 32)
        let bobKey = Data(repeating: 0x0b, count: 32)
        let contacts = [
            WeshQRTrust.Contact(noiseKeyHex: aliceKey.hexEncodedString(), nickname: "Alice", npub: alice.npub, npubProven: true),
            WeshQRTrust.Contact(noiseKeyHex: bobKey.hexEncodedString(), nickname: "Bob", npub: bob.npub, npubProofWarning: true)
        ]
        #expect(WeshInternetRoute.recipients(contacts: contacts, blockedFingerprints: []) == [PeerID(hexData: aliceKey): alice.npub])
        #expect(WeshInternetRoute.recipients(contacts: contacts, blockedFingerprints: [aliceKey.sha256Fingerprint()]).isEmpty)
        #expect(WeshInternetRoute.senderNoiseKey(forNostrPubkey: alice.publicKeyHex, contacts: contacts, blockedFingerprints: []) == aliceKey)
        #expect(WeshInternetRoute.senderNoiseKey(forNostrPubkey: alice.npub, contacts: contacts, blockedFingerprints: []) == aliceKey)
        #expect(WeshInternetRoute.senderNoiseKey(forNostrPubkey: bob.publicKeyHex, contacts: contacts, blockedFingerprints: []) == nil)
        #expect(WeshInternetRoute.senderNoiseKey(forNostrPubkey: alice.publicKeyHex, contacts: contacts,
                                                 blockedFingerprints: [aliceKey.sha256Fingerprint()]) == nil)
        #expect(WeshInternetRoute.senderNoiseKey(forNostrPubkey: try NostrIdentity.generate().publicKeyHex,
                                                 contacts: contacts, blockedFingerprints: []) == nil)
        var conflicted = contacts[0]
        conflicted.npubConflict = true
        #expect(WeshInternetRoute.deliveryNpub(for: conflicted) == nil)
        let twoHolders = [contacts[0], WeshQRTrust.Contact(noiseKeyHex: bobKey.hexEncodedString(), nickname: "Bob", npub: alice.npub)]
        #expect(WeshInternetRoute.senderNoiseKey(forNostrPubkey: alice.publicKeyHex, contacts: twoHolders, blockedFingerprints: []) == nil)
    }

    @MainActor
    private func makeDependencies(
        notificationCenter: NotificationCenter = NotificationCenter(),
        loadFavorites: @escaping @MainActor () -> [Data: FavoriteRelationship] = { [:] },
        favoriteStatusForNoiseKey: @escaping @MainActor (Data) -> FavoriteRelationship? = { _ in nil },
        favoriteStatusForPeerID: @escaping @MainActor (PeerID) -> FavoriteRelationship? = { _ in nil },
        currentIdentity: @escaping @MainActor () throws -> NostrIdentity? = { nil },
        registerPendingGiftWrap: @escaping @MainActor (String) -> Void = { _ in },
        sendEvent: @escaping @MainActor (NostrEvent) -> Void = { _ in },
        publishEvent: (@MainActor (NostrEvent, @escaping @MainActor (NostrPublishOutcome) -> Void) -> Void)? = nil,
        scheduleAfter: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = { _, _ in },
        relayConnectivity: @escaping @MainActor () -> AnyPublisher<Bool, Never> = { Just(false).eraseToAnyPublisher() },
        weshRecipients: (@MainActor () -> AnyPublisher<[PeerID: String], Never>)? = nil,
        weshOnline: (@MainActor () -> AnyPublisher<Bool, Never>)? = nil,
        weshIsBlocked: (@MainActor (Data) -> Bool)? = nil,
        ackPacer: NostrTransport.AckPacer? = nil
    ) -> NostrTransport.Dependencies {
        NostrTransport.Dependencies(
            notificationCenter: notificationCenter,
            loadFavorites: loadFavorites,
            favoriteStatusForNoiseKey: favoriteStatusForNoiseKey,
            favoriteStatusForPeerID: favoriteStatusForPeerID,
            currentIdentity: currentIdentity,
            registerPendingGiftWrap: registerPendingGiftWrap,
            sendEvent: sendEvent,
            // Private messages reach `sendEvent` too unless a test plays the relays' answers.
            publishEvent: publishEvent ?? { event, _ in sendEvent(event) },
            scheduleAfter: scheduleAfter,
            relayConnectivity: relayConnectivity,
            ackPacer: ackPacer,
            weshRecipients: weshRecipients,
            weshOnline: weshOnline,
            weshIsBlocked: weshIsBlocked
        )
    }

    private func makeRelationship(
        peerNoisePublicKey: Data,
        peerNostrPublicKey: String?,
        peerNickname: String
    ) -> FavoriteRelationship {
        FavoriteRelationship(
            peerNoisePublicKey: peerNoisePublicKey,
            peerNostrPublicKey: peerNostrPublicKey,
            peerNickname: peerNickname,
            isFavorite: true,
            theyFavoritedUs: true,
            favoritedAt: Date(timeIntervalSince1970: 1),
            lastUpdated: Date(timeIntervalSince1970: 2)
        )
    }

    private func decodeEmbeddedPayload(
        from event: NostrEvent,
        recipient: NostrIdentity
    ) throws -> (packet: BitchatPacket, payload: NoisePayload, senderPubkey: String, packetData: Data) {
        let (content, senderPubkey, _) = try NostrProtocol.decryptPrivateMessage(
            giftWrap: event,
            recipientIdentity: recipient
        )
        guard content.hasPrefix("bitchat1:") else {
            throw NostrTransportTestError.invalidEmbeddedContent
        }
        let encoded = String(content.dropFirst("bitchat1:".count))
        guard let packetData = base64URLDecode(encoded),
              let packet = BitchatPacket.from(packetData),
              let payload = NoisePayload.decode(packet.payload) else {
            throw NostrTransportTestError.invalidPacket
        }
        return (packet, payload, senderPubkey, packetData)
    }

    private func decodePrivateMessage(from payload: NoisePayload) throws -> PrivateMessagePacket {
        guard payload.type == .privateMessage,
              let message = PrivateMessagePacket.decode(from: payload.data) else {
            throw NostrTransportTestError.invalidPrivateMessage
        }
        return message
    }
}

private enum NostrTransportTestError: Error {
    case invalidEmbeddedContent
    case invalidPacket
    case invalidPrivateMessage
}

private func base64URLDecode(_ string: String) -> Data? {
    var candidate = string
    let padding = (4 - (candidate.count % 4)) % 4
    if padding > 0 {
        candidate += String(repeating: "=", count: padding)
    }
    candidate = candidate
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    return Data(base64Encoded: candidate)
}

private final class NostrTransportProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var sentEventsStorage: [NostrEvent] = []
    private var pendingGiftWrapIDsStorage: [String] = []
    private var scheduledActionsStorage: [(@Sendable () -> Void)] = []

    var sentEvents: [NostrEvent] {
        lock.lock()
        defer { lock.unlock() }
        return sentEventsStorage
    }

    var pendingGiftWrapIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return pendingGiftWrapIDsStorage
    }

    var scheduledActionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return scheduledActionsStorage.count
    }

    func record(event: NostrEvent) {
        lock.lock()
        sentEventsStorage.append(event)
        lock.unlock()
    }

    func recordPendingGiftWrap(id: String) {
        lock.lock()
        pendingGiftWrapIDsStorage.append(id)
        lock.unlock()
    }

    func enqueueScheduledAction(delay: TimeInterval, action: @escaping @Sendable () -> Void) {
        _ = delay
        lock.lock()
        scheduledActionsStorage.append(action)
        lock.unlock()
    }

    @discardableResult
    func runNextScheduledAction() -> Bool {
        let action: (@Sendable () -> Void)?
        lock.lock()
        action = scheduledActionsStorage.isEmpty ? nil : scheduledActionsStorage.removeFirst()
        lock.unlock()
        guard let action else { return false }
        action()
        return true
    }
}

/// An erase must not leave acks queued under the old Nostr key: once the pacer is reset,
/// nothing that was waiting for its turn is sent, even when the interval elapses later.
struct NostrAckPacerResetTests {
    private final class HeldScheduler: @unchecked Sendable {
        private let lock = NSLock()
        private var actions: [@Sendable () -> Void] = []
        func hold(_ action: @escaping @Sendable () -> Void) { lock.withLock { actions.append(action) } }
        func releaseAll() {
            let pending = lock.withLock { () -> [@Sendable () -> Void] in
                defer { actions.removeAll() }
                return actions
            }
            pending.forEach { $0() }
        }
    }

    private final class SentLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Int] = []
        func record(_ item: Int) { lock.withLock { items.append(item) } }
        var all: [Int] { lock.withLock { items } }
    }

    @Test
    func resetDropsAcksStillWaitingForTheirTurn() async throws {
        let scheduler = HeldScheduler()
        let sent = SentLog()
        let pacer = NostrTransport.AckPacer(scheduleAfter: { _, action in scheduler.hold(action) })

        for item in 1...3 { pacer.enqueue { sent.record(item) } }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(sent.all == [1])

        pacer.discardWorkBeforeErase()
        for _ in 0..<3 {
            scheduler.releaseAll()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(sent.all == [1])

        // Still usable afterwards, for the new identity.
        pacer.enqueue { sent.record(4) }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(sent.all == [1, 4])
    }
}

/// Plays the relays: records each publication and lets the test answer it.
@MainActor
private final class RelayAnswerProbe {
    private(set) var events: [NostrEvent] = []
    private var answers: [@MainActor (NostrPublishOutcome) -> Void] = []

    func publish(_ event: NostrEvent, _ answer: @escaping @MainActor (NostrPublishOutcome) -> Void) {
        events.append(event)
        answers.append(answer)
    }

    func answerLast(_ outcome: NostrPublishOutcome) {
        answers.last?(outcome)
    }
}
