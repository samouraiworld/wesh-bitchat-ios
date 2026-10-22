//
// BitchatMessageTransportLabelTests.swift
// BitFoundationTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
@testable import BitFoundation

@Suite("BitchatMessage transport label")
struct BitchatMessageTransportLabelTests {
    private func message(transport: MessageTransport?) -> BitchatMessage {
        BitchatMessage(
            id: "label",
            sender: "nora",
            content: "on my way",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "sam",
            senderPeerID: PeerID(str: "0102030405060708"),
            transport: transport
        )
    }

    @Test func labelSurvivesCodableRoundTrip() throws {
        for transport in [MessageTransport.bluetooth, .internet] {
            let data = try JSONEncoder().encode(message(transport: transport))
            let decoded = try JSONDecoder().decode(BitchatMessage.self, from: data)
            #expect(decoded.transport == transport)
            #expect(decoded == message(transport: transport))
        }
    }

    @Test func archiveWithoutTheLabelDecodesUnlabelled() throws {
        let data = try JSONEncoder().encode(message(transport: .internet))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["transport"] as? String == "internet")
        object.removeValue(forKey: "transport")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(BitchatMessage.self, from: legacy)
        #expect(decoded.transport == nil)
    }

    /// The label is this device's own record: the wire format never carries it.
    @Test func labelNeverGoesOnTheWire() throws {
        let labelled = try #require(message(transport: .internet).toBinaryPayload())
        let unlabelled = try #require(message(transport: nil).toBinaryPayload())
        #expect(labelled == unlabelled)
        #expect(try #require(BitchatMessage(labelled)).transport == nil)
    }
}
