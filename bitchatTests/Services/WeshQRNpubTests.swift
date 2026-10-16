import Foundation
import Testing
@testable import bitchat

/// Enrollment-time npub checks: a failing npub enrolls the contact Bluetooth-only.
@MainActor
struct WeshQRNpubTests {
    private let fixtureNpub = "npub1r799vmpq2ceaq2gfgara9cv0gns9ny7a57jl3r6fvpuzqhm9devsg53zcr"
    private let noiseA = String(repeating: "a1", count: 32)
    private let noiseB = String(repeating: "b2", count: 32)

    @Test func validNpubDecodesToItsXOnlyKey() {
        #expect(WeshQRNpub.xOnlyKey(fromNpub: fixtureNpub)?.hexEncodedString()
                == "1f8a566c205633d029094747d2e18f44e05993dda7a5f88f496078205f656e59")
    }

    @Test func malformedNpubsAreRejected() {
        let badChecksum = String(fixtureNpub.dropLast()) + "q"
        let samples = [
            badChecksum,
            fixtureNpub.uppercased(),
            "nsec1r799vmpq2ceaq2gfgara9cv0gns9ny7a57jl3r6fvpuzqhm9devsyz6r7k", // right key, wrong prefix
            "npub1r799vmpq2ceaq2gfgara9cv0gns9ny7a57jl3r6fvpuzqhm9dc5lsswe",   // 31 bytes
            "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqzsfj2hcx", // x = 5: not on secp256k1
            "",
            "npub1"
        ]
        for sample in samples {
            #expect(WeshQRNpub.xOnlyKey(fromNpub: sample) == nil, "\(sample)")
        }
    }

    @Test func enrollmentKeepsOnlyAUniqueValidNpubThatIsNotMine() throws {
        let mine = try NostrIdentity.generate().npub
        #expect(WeshQRNpub.enrollable(fixtureNpub, noiseKeyHex: noiseA, ownNpub: mine, contacts: []) == fixtureNpub)
        #expect(WeshQRNpub.enrollable(nil, noiseKeyHex: noiseA, ownNpub: mine, contacts: []) == nil)
        #expect(WeshQRNpub.enrollable("", noiseKeyHex: noiseA, ownNpub: mine, contacts: []) == nil)
        #expect(WeshQRNpub.enrollable(mine, noiseKeyHex: noiseA, ownNpub: mine, contacts: []) == nil)
        // Fail closed: without my own npub the "not mine" rule cannot be checked.
        #expect(WeshQRNpub.enrollable(fixtureNpub, noiseKeyHex: noiseA, ownNpub: nil, contacts: []) == nil)

        let other = WeshQRTrust.Contact(noiseKeyHex: noiseB, nickname: "B", npub: fixtureNpub)
        #expect(WeshQRNpub.enrollable(fixtureNpub, noiseKeyHex: noiseA, ownNpub: mine, contacts: [other]) == nil)
        // Re-enrolling the same Noise identity with its own npub is not a duplicate.
        let same = WeshQRTrust.Contact(noiseKeyHex: noiseA.uppercased(), nickname: "A", npub: fixtureNpub)
        #expect(WeshQRNpub.enrollable(fixtureNpub, noiseKeyHex: noiseA, ownNpub: mine, contacts: [same]) == fixtureNpub)
    }

    @Test func legacyContactWithoutNpubDecodesAndNeedsRescan() throws {
        let legacy = Data(#"[{"noiseKeyHex":"\#(noiseA)","nickname":"Old"}]"#.utf8)
        let contacts = try JSONDecoder().decode([WeshQRTrust.Contact].self, from: legacy)
        #expect(contacts.first?.npub == nil)
        #expect(contacts.first?.requiresRescanForInternet == true)
        let enrolled = WeshQRTrust.Contact(noiseKeyHex: noiseA, nickname: "New", npub: fixtureNpub)
        #expect(!enrolled.requiresRescanForInternet)
        let roundTrip = try JSONDecoder().decode(WeshQRTrust.Contact.self, from: JSONEncoder().encode(enrolled))
        #expect(roundTrip.npub == fixtureNpub)
    }

    @Test func recordBindsTheNpubToTheNoiseKey() {
        let store = WeshQRTrust(defaults: UserDefaults(suiteName: "wesh.qr.npub.\(UUID().uuidString)")!)
        let key = Data(repeating: 0xA1, count: 32)
        store.record(sessionKey: key, nickname: "A", npub: fixtureNpub)
        #expect(store.contacts.first?.npub == fixtureNpub)
        // A later verified QR without an npub is the latest signed statement: Bluetooth-only again.
        store.record(sessionKey: key, nickname: "A")
        #expect(store.contacts.count == 1)
        #expect(store.contacts.first?.npub == nil)
    }
}
