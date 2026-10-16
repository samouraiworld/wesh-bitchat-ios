import Foundation
import Testing
@testable import bitchat

/// Enrollment-time npub checks and precedence (docs/plan/fixtures/NPUB-PROOF.md).
@MainActor
struct WeshQRNpubTests {
    private typealias Contact = WeshQRTrust.Contact
    private let fixtureNpub = "npub1r799vmpq2ceaq2gfgara9cv0gns9ny7a57jl3r6fvpuzqhm9devsg53zcr"
    private let noiseA = String(repeating: "a1", count: 32)
    private let noiseB = String(repeating: "b2", count: 32)
    private let noiseC = String(repeating: "c3", count: 32)
    private let canonical = Data("canonical bytes".utf8)

    private func proof(_ identity: NostrIdentity, over bytes: Data? = nil) throws -> String {
        try #require(WeshQRNpub.signProof(canonicalBytes: bytes ?? canonical, identity: identity)).hexEncodedString()
    }

    private func enroll(_ npub: String?, proof: String? = nil, as noise: String? = nil,
                        owned: Set<String>? = [], contacts: [Contact] = []) -> WeshQRNpub.Outcome {
        WeshQRNpub.enrollment(npub: npub, npubSigHex: proof, canonicalBytes: canonical,
                              noiseKeyHex: noise ?? noiseA, ownedNpubs: owned, contacts: contacts)
    }

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
            #expect(enroll(sample) == .bluetoothOnly, "\(sample)")
        }
        #expect(enroll(nil) == .bluetoothOnly)
    }

    @Test func anyLocallyOwnedNpubIsRefusedAndAnUnknownSetFailsClosed() throws {
        let current = try NostrIdentity.generate().npub
        let derived = try NostrIdentity.generate().npub
        let owned: Set<String> = [current, derived]
        #expect(enroll(current, owned: owned) == .bluetoothOnly)
        #expect(enroll(derived, owned: owned) == .bluetoothOnly)
        #expect(enroll(fixtureNpub, owned: owned) == .bound(npub: fixtureNpub, proven: false, unbinding: []))
        #expect(enroll(fixtureNpub, owned: nil) == .bluetoothOnly)
    }

    @Test func presentProofMustVerifyAndIsNeverDowngraded() throws {
        let theirs = try NostrIdentity.generate()
        #expect(enroll(theirs.npub, proof: try proof(theirs)) == .bound(npub: theirs.npub, proven: true, unbinding: []))
        // Signed by another key, over other bytes, or garbage: Bluetooth-only, not "unproven".
        let other = try NostrIdentity.generate()
        #expect(enroll(theirs.npub, proof: try proof(other)) == .bluetoothOnly)
        #expect(enroll(theirs.npub, proof: try proof(theirs, over: Data("other".utf8))) == .bluetoothOnly)
        #expect(enroll(theirs.npub, proof: String(repeating: "00", count: 64)) == .bluetoothOnly)
        // No proof at all (official BitChat): accepted as unproven.
        #expect(enroll(theirs.npub) == .bound(npub: theirs.npub, proven: false, unbinding: []))
    }

    @Test func provenWinsAndUnprovenNeverDisplacesProven() throws {
        let theirs = try NostrIdentity.generate()
        let unprovenB = Contact(noiseKeyHex: noiseB, nickname: "B", npub: theirs.npub)
        let provenB = Contact(noiseKeyHex: noiseB, nickname: "B", npub: theirs.npub, npubProven: true)

        // Proven new claim takes the npub from an unproven holder, which is flagged.
        #expect(enroll(theirs.npub, proof: try proof(theirs), contacts: [unprovenB])
                == .bound(npub: theirs.npub, proven: true, unbinding: [noiseB]))
        // Unproven new claim against a proven holder: new contact flagged, holder untouched.
        #expect(enroll(theirs.npub, contacts: [provenB]) == .conflict(unbinding: []))
        // Two unproven claims: both unbound and flagged.
        #expect(enroll(theirs.npub, contacts: [unprovenB]) == .conflict(unbinding: [noiseB]))
        // The newest proven claim wins over an older proven one, which is flagged.
        #expect(enroll(theirs.npub, proof: try proof(theirs), contacts: [provenB])
                == .bound(npub: theirs.npub, proven: true, unbinding: [noiseB]))
        // Re-enrolling the same identity without the proof keeps it proven.
        let provenA = Contact(noiseKeyHex: noiseA.uppercased(), nickname: "A", npub: theirs.npub, npubProven: true)
        #expect(enroll(theirs.npub, contacts: [provenA]) == .bound(npub: theirs.npub, proven: true, unbinding: []))
    }

    @Test func storeAppliesOutcomesAndInboundResolvesOnlyAUniqueHolder() throws {
        let store = WeshQRTrust(defaults: UserDefaults(suiteName: "wesh.qr.npub.\(UUID().uuidString)")!)
        let theirs = try NostrIdentity.generate()
        let keyA = try #require(Data(hexString: noiseA))
        let keyB = try #require(Data(hexString: noiseB))
        let keyC = try #require(Data(hexString: noiseC))

        store.enroll(sessionKey: keyB, nickname: "B", outcome: enroll(theirs.npub, as: noiseB, contacts: store.contacts))
        #expect(WeshQRNpub.inboundContact(forNpub: theirs.npub, in: store.contacts)?.nickname == "B")

        // Unproven duplicate: both unbound, both flagged, inbound dropped.
        store.enroll(sessionKey: keyC, nickname: "C", outcome: enroll(theirs.npub, as: noiseC, contacts: store.contacts))
        #expect(store.contacts.allSatisfy { $0.npub == nil && $0.hasNpubConflict && $0.requiresRescanForInternet })
        #expect(WeshQRNpub.inboundContact(forNpub: theirs.npub, in: store.contacts) == nil)

        // A proven scan settles it.
        store.enroll(sessionKey: keyA, nickname: "A",
                     outcome: enroll(theirs.npub, proof: try proof(theirs), as: noiseA, contacts: store.contacts))
        let a = try #require(store.contacts.first { $0.noiseKeyHex == noiseA })
        #expect(a.isNpubProven && !a.hasNpubConflict)
        #expect(WeshQRNpub.inboundContact(forNpub: theirs.npub, in: store.contacts)?.nickname == "A")
        #expect(store.contacts.filter { $0.npub == theirs.npub }.count == 1)

        // A later verified QR without an npub is the latest signed statement: Bluetooth-only again.
        store.enroll(sessionKey: keyA, nickname: "A", outcome: .bluetoothOnly)
        #expect(store.contacts.first { $0.noiseKeyHex == noiseA }?.npub == nil)
    }

    @Test func legacyContactWithoutNpubDecodesAndNeedsRescan() throws {
        let legacy = Data(#"[{"noiseKeyHex":"\#(noiseA)","nickname":"Old"}]"#.utf8)
        let contacts = try JSONDecoder().decode([Contact].self, from: legacy)
        #expect(contacts.first?.npub == nil)
        #expect(contacts.first?.requiresRescanForInternet == true)
        #expect(contacts.first?.hasNpubConflict == false)
        let enrolled = Contact(noiseKeyHex: noiseA, nickname: "New", npub: fixtureNpub, npubProven: true)
        #expect(!enrolled.requiresRescanForInternet)
        let roundTrip = try JSONDecoder().decode(Contact.self, from: JSONEncoder().encode(enrolled))
        #expect(roundTrip.npub == fixtureNpub && roundTrip.isNpubProven)
    }

    @Test func myQRCarriesAnNpubOnlyWhileInternetIsOnAndUnfenced() throws {
        let stored = try NostrIdentity.generate()
        var reads = 0
        let read: () -> NostrIdentity? = { reads += 1; return stored }
        #expect(WeshQRNpub.identityForMyQR(internetEnabled: false, panicFenced: false, storedIdentity: read) == nil)
        #expect(WeshQRNpub.identityForMyQR(internetEnabled: true, panicFenced: true, storedIdentity: read) == nil)
        #expect(reads == 0)
        #expect(WeshQRNpub.identityForMyQR(internetEnabled: true, panicFenced: false, storedIdentity: read)?.npub == stored.npub)
        #expect(WeshQRNpub.identityForMyQR(internetEnabled: true, panicFenced: false, storedIdentity: { nil }) == nil)
    }
}
