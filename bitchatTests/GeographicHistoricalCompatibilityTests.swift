import Foundation
import Testing
import BitFoundation
@testable import bitchat

struct GeographicHistoricalCompatibilityTests {
    @Test
    func historicalChannelEncodingAndPeerPrefixesRemainDecodable() throws {
        let historical = Data(#"{"location":{"_0":{"level":"city","geohash":"00000"}}}"#.utf8)
        let channel = try JSONDecoder().decode(ChannelID.self, from: historical)
        #expect(channel == .location(GeohashChannel(level: .city, geohash: "00000")))
        #expect(try JSONDecoder().decode(ChannelID.self, from: Data(#"{"mesh":{}}"#.utf8)) == .mesh)
        #expect(try JSONDecoder().decode(GeohashChannelLevel.self, from: Data(#""country""#.utf8)) == .region)
        #expect(try JSONDecoder().decode(GeohashChannelLevel.self, from: Data(#""region""#.utf8)) == .province)
        #expect(PeerID(str: "nostr_0011223344556677").id == "nostr_0011223344556677")
        #expect(PeerID(str: "nostr:00112233").id == "nostr:00112233")
    }

    @Test
    func oldURLPayloadsAndEventNumbersRemainReservedWithoutBecomingDeepLinks() throws {
        let payload = try #require(URL(string: "bitchat://geohash/00000"))
        #expect(payload.host == "geohash")
        #expect(payload.path == "/00000")
        #expect(!WeshDeepLinks.isInternal(payload))
        #expect(!WeshDeepLinks.isInternal(try #require(URL(string: "wesh://geohash/00000"))))
        #expect(WeshDeepLinks.isInternal(try #require(URL(string: "wesh://share"))))
        #expect(NostrProtocol.EventKind.ephemeralEvent.rawValue == 20000)
        #expect(NostrProtocol.EventKind.geohashPresence.rawValue == 20001)
        #expect(NostrProtocol.EventKind.giftWrap.rawValue == 1059)
    }

    @Test
    func retainedLegacySeedStillPreventsAnIncompleteOwnedIdentityClaim() throws {
        let keychain = MockKeychain()
        let bridge = NostrIdentityBridge(keychain: keychain)
        #expect(try bridge.locallyOwnedNpubs().isEmpty)
        let seed = Data(repeating: 0x39, count: 32)
        keychain.save(key: "nostr-device-seed", data: seed, service: "chat.bitchat.nostr", accessible: nil)
        #expect(throws: NostrIdentityBridge.StorageError.derivedIdentitiesNotEnumerable) {
            try bridge.locallyOwnedNpubs()
        }
        #expect(keychain.load(key: "nostr-device-seed", service: "chat.bitchat.nostr") == seed)
        #expect(try bridge.storedNostrIdentity() == nil)
    }
}
