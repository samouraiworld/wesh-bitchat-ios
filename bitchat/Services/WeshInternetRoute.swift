import BitFoundation
import Combine
import Foundation

/// Internet delivery to QR contacts. The npub comes only from the contact's
/// signed QR, bound over Noise at enrollment (WeshQRNpub): never from
/// favorites or a `[FAVORITED]` notice. Spec: docs/plan/INTERNET-MODE-SPEC.md §3.
enum WeshInternetRoute {
    /// The npub Internet delivery may use: none for a Bluetooth-only contact,
    /// and none while a conflict or a proof warning awaits the user's review.
    static func deliveryNpub(for contact: WeshQRTrust.Contact) -> String? {
        guard let npub = contact.npub, !contact.hasNpubConflict, !contact.hasNpubProofWarning,
              WeshQRNpub.xOnlyKey(fromNpub: npub) != nil else { return nil }
        return npub
    }

    /// Full Noise-key peer ID → npub, for every unblocked contact reachable over Internet.
    static func recipients(contacts: [WeshQRTrust.Contact], blockedFingerprints: Set<String>) -> [PeerID: String] {
        var result: [PeerID: String] = [:]
        for contact in contacts {
            guard let key = Data(hexString: contact.noiseKeyHex), key.count == 32,
                  !blockedFingerprints.contains(key.sha256Fingerprint()),
                  let npub = deliveryNpub(for: contact) else { continue }
            result[PeerID(hexData: key)] = npub
        }
        return result
    }

    /// Flushes once each time the mode turns On. `@Published` emits before the property
    /// changes, so the flush hops to the next main-queue turn: by then readers (the send
    /// policy) see `.on`, and messages queued while it was off really leave.
    @MainActor
    static func flushWhenOn<P: Publisher>(_ states: P, flush: @escaping @MainActor () -> Void) -> AnyCancellable
    where P.Output == WeshInternetState, P.Failure == Never {
        states
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .filter { $0 == .on }
            .sink { _ in MainActor.assumeIsolated { flush() } }
    }

    /// Inbound: the Noise key of the one unblocked contact whose bound npub is
    /// this sender's key (hex or npub). Nil means the event is dropped.
    static func senderNoiseKey(forNostrPubkey pubkey: String, contacts: [WeshQRTrust.Contact],
                               blockedFingerprints: Set<String>) -> Data? {
        let npub: String
        if pubkey.hasPrefix("npub") {
            npub = pubkey
        } else {
            guard let data = Data(hexString: pubkey.lowercased()), data.count == 32,
                  let encoded = try? Bech32.encode(hrp: "npub", data: data) else { return nil }
            npub = encoded
        }
        guard let contact = WeshQRNpub.inboundContact(forNpub: npub, in: contacts),
              deliveryNpub(for: contact) == npub,
              let key = Data(hexString: contact.noiseKeyHex), key.count == 32,
              !blockedFingerprints.contains(key.sha256Fingerprint()) else { return nil }
        return key
    }
}
