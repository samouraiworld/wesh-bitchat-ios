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
            "npub1"
        ]
        for sample in samples {
            #expect(WeshQRNpub.xOnlyKey(fromNpub: sample) == nil, "\(sample)")
            #expect(enroll(sample) == .bluetoothOnly, "\(sample)")
        }
        #expect(enroll(nil) == .keep, "a QR without npub makes no claim")
        // Empty signs the same bytes as absent, so it is no claim either.
        #expect(WeshQRNpub.xOnlyKey(fromNpub: "") == nil)
        #expect(enroll("") == .keep)
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

    @Test func onlyAProofDisplacesAndNeverAProvenIncumbent() throws {
        let theirs = try NostrIdentity.generate()
        let unprovenB = Contact(noiseKeyHex: noiseB, nickname: "B", npub: theirs.npub)
        let provenB = Contact(noiseKeyHex: noiseB, nickname: "B", npub: theirs.npub, npubProven: true)

        // A verified proof takes the npub from an unproven incumbent, which is flagged.
        #expect(enroll(theirs.npub, proof: try proof(theirs), contacts: [unprovenB])
                == .bound(npub: theirs.npub, proven: true, unbinding: [noiseB]))
        // An unproven claim never unbinds an incumbent, proven or not.
        #expect(enroll(theirs.npub, contacts: [unprovenB]) == .conflict)
        #expect(enroll(theirs.npub, contacts: [provenB]) == .conflict)
        // Not even a proof displaces a proven incumbent.
        #expect(enroll(theirs.npub, proof: try proof(theirs), contacts: [provenB]) == .conflict)
    }

    @Test func aPreviouslyProvenPeerIsNeverSilentlyDowngraded() throws {
        let theirs = try NostrIdentity.generate()
        let provenA = Contact(noiseKeyHex: noiseA.uppercased(), nickname: "A", npub: theirs.npub, npubProven: true)
        // `npubsig` stripped from a shared link, a bad proof, or an unproven other npub.
        #expect(enroll(theirs.npub, contacts: [provenA]) == .keepProven)
        #expect(enroll(theirs.npub, proof: String(repeating: "00", count: 64), contacts: [provenA]) == .keepProven)
        #expect(enroll(try NostrIdentity.generate().npub, contacts: [provenA]) == .keepProven)
        #expect(enroll("npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqzsfj2hcx", contacts: [provenA]) == .keepProven)
        // A new verified proof by the same peer is a fresh proven binding.
        let rotated = try NostrIdentity.generate()
        #expect(enroll(rotated.npub, proof: try proof(rotated), contacts: [provenA])
                == .bound(npub: rotated.npub, proven: true, unbinding: []))
        // A QR without npub makes no claim.
        #expect(enroll(nil, contacts: [provenA]) == .keep)
    }

    @Test func storeAppliesOutcomesAndInboundResolvesOnlyAUniqueHolder() throws {
        let store = WeshQRTrust()
        let theirs = try NostrIdentity.generate()
        let keyA = try #require(Data(hexString: noiseA))
        let keyB = try #require(Data(hexString: noiseB))
        let keyC = try #require(Data(hexString: noiseC))
        func contact(_ hex: String) -> Contact? { store.contacts.first { $0.noiseKeyHex == hex } }

        store.enroll(sessionKey: keyB, nickname: "B", outcome: enroll(theirs.npub, as: noiseB, contacts: store.contacts))
        #expect(WeshQRNpub.inboundContact(forNpub: theirs.npub, in: store.contacts)?.nickname == "B")

        // Unproven duplicate: refused and flagged; the incumbent keeps it.
        store.enroll(sessionKey: keyC, nickname: "C", outcome: enroll(theirs.npub, as: noiseC, contacts: store.contacts))
        #expect(contact(noiseC)?.npub == nil && contact(noiseC)?.hasNpubConflict == true)
        #expect(contact(noiseB)?.npub == theirs.npub && contact(noiseB)?.hasNpubConflict == false)
        #expect(WeshQRNpub.inboundContact(forNpub: theirs.npub, in: store.contacts)?.nickname == "B")

        // A verified proof evicts the unproven incumbent, which is flagged for review.
        store.enroll(sessionKey: keyA, nickname: "A",
                     outcome: enroll(theirs.npub, proof: try proof(theirs), as: noiseA, contacts: store.contacts))
        #expect(contact(noiseA)?.isNpubProven == true)
        #expect(contact(noiseB)?.npub == nil && contact(noiseB)?.hasNpubConflict == true)
        #expect(WeshQRNpub.inboundContact(forNpub: theirs.npub, in: store.contacts)?.nickname == "A")

        // The same peer later shows a stripped QR: binding kept, warning shown.
        store.enroll(sessionKey: keyA, nickname: "A", outcome: enroll(theirs.npub, as: noiseA, contacts: store.contacts))
        #expect(contact(noiseA)?.isNpubProven == true && contact(noiseA)?.hasNpubProofWarning == true)
        // A QR with no npub keeps the binding as is.
        store.enroll(sessionKey: keyA, nickname: "A2", outcome: .keep)
        #expect(contact(noiseA)?.npub == theirs.npub && contact(noiseA)?.nickname == "A2")
        #expect(store.contacts.filter { $0.npub == theirs.npub }.count == 1)
    }

    @Test func reviewFlagsSurviveLaterScansUntilSettled() throws {
        let store = WeshQRTrust()
        let theirs = try NostrIdentity.generate()
        let keyA = try #require(Data(hexString: noiseA))
        func a() -> Contact? { store.contacts.first { $0.noiseKeyHex == noiseA } }

        store.enroll(sessionKey: keyA, nickname: "A", outcome: .bound(npub: theirs.npub, proven: true, unbinding: []))
        store.enroll(sessionKey: keyA, nickname: "A", outcome: .keepProven)
        #expect(a()?.hasNpubProofWarning == true && a()?.hasNpubConflict == false)
        // A conflict keeps the pending warning.
        store.enroll(sessionKey: keyA, nickname: "A", outcome: .conflict)
        #expect(a()?.hasNpubProofWarning == true && a()?.hasNpubConflict == true)
        #expect(a()?.isNpubProven == true)
        // A later stripped QR keeps the pending conflict.
        store.enroll(sessionKey: keyA, nickname: "A", outcome: .keepProven)
        #expect(a()?.hasNpubProofWarning == true && a()?.hasNpubConflict == true)
        // A fresh binding or a refused claim does not settle them either.
        let rotated = try NostrIdentity.generate()
        store.enroll(sessionKey: keyA, nickname: "A", outcome: .bound(npub: rotated.npub, proven: true, unbinding: []))
        #expect(a()?.npub == rotated.npub && a()?.hasNpubProofWarning == true && a()?.hasNpubConflict == true)
        store.enroll(sessionKey: keyA, nickname: "A", outcome: .bluetoothOnly)
        #expect(a()?.npub == nil && a()?.hasNpubProofWarning == true && a()?.hasNpubConflict == true)
    }

    @Test func anEmptyNpubIsNeverRecorded() throws {
        let store = WeshQRTrust()
        store.record(sessionKey: try #require(Data(hexString: noiseA)), nickname: "A", npub: "", npubProven: true)
        #expect(store.contacts.first?.npub == nil)
        #expect(store.contacts.first?.isNpubProven == false)
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
