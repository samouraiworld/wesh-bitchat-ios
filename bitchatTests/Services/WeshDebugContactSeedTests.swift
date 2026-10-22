#if DEBUG
import Foundation
import Testing
import BitFoundation
@testable import bitchat

/// The Debug-only contact seed used for M4 on simulators (the iOS side of Android #104).
@MainActor
struct WeshDebugContactSeedTests {
    private let fixtureNpub = "npub1r799vmpq2ceaq2gfgara9cv0gns9ny7a57jl3r6fvpuzqhm9devsg53zcr"
    private let noiseA = String(repeating: "a1", count: 32)
    private let noiseB = String(repeating: "b2", count: 32)

    @Test func launchVariableParsesNoiseKeyNpubAndOptionalNickname() throws {
        let full = try #require(WeshDebugContactSeed.request(from: ["WESH_DEBUG_SEED_CONTACT": "\(noiseA.uppercased()), \(fixtureNpub), Nora café"]))
        #expect(full.noiseKeyHex == noiseA)
        #expect(full.npub == fixtureNpub)
        #expect(full.nickname == "Nora café")
        #expect(try #require(WeshDebugContactSeed.request(from: ["WESH_DEBUG_SEED_CONTACT": "\(noiseA),\(fixtureNpub)"])).nickname == "Contact")
        #expect(WeshDebugContactSeed.request(from: ["WESH_DEBUG_SEED_CONTACT": noiseA]) == nil)
        #expect(WeshDebugContactSeed.request(from: [:]) == nil)
    }

    @Test func seededContactIsReachableOverInternetWithAProvenNpub() throws {
        let trust = WeshQRTrust()
        var verified: [String] = []
        let request = WeshDebugContactSeed.Request(noiseKeyHex: noiseA, npub: fixtureNpub, nickname: "Nora")
        #expect(WeshDebugContactSeed.seed(request, into: trust, ownedNpubs: []) { verified.append($0) })

        let key = try #require(Data(hexString: noiseA))
        let contact = try #require(trust.contacts.first)
        #expect(contact.noiseKeyHex == noiseA)
        #expect(contact.nickname == "Nora")
        #expect(contact.isNpubProven)
        #expect(trust.fingerprints == [key.sha256Fingerprint()])
        #expect(verified == [key.sha256Fingerprint()])
        #expect(WeshInternetRoute.recipients(contacts: trust.contacts, blockedFingerprints: []) == [PeerID(hexData: key): fixtureNpub])
    }

    /// Same enrollment checks as a scanned QR: a bad key or npub, my own npub, another contact's
    /// npub, or my npubs unknown are all refused, and nothing is recorded or verified.
    @Test func badKeysAndNpubsAreRefused() throws {
        let mine = try NostrIdentity.generate().npub
        let holder = WeshQRTrust()
        #expect(holder.record(sessionKey: try #require(Data(hexString: noiseB)), nickname: "B", npub: fixtureNpub, npubProven: true))
        let cases: [(WeshDebugContactSeed.Request, Set<String>?, WeshQRTrust)] = [
            (.init(noiseKeyHex: "a1a1", npub: fixtureNpub, nickname: "short key"), [], WeshQRTrust()),
            (.init(noiseKeyHex: noiseA, npub: String(fixtureNpub.dropLast()) + "q", nickname: "bad checksum"), [], WeshQRTrust()),
            (.init(noiseKeyHex: noiseA, npub: mine, nickname: "mine"), [mine], WeshQRTrust()),
            (.init(noiseKeyHex: noiseA, npub: fixtureNpub, nickname: "unknown owned"), nil, WeshQRTrust()),
            (.init(noiseKeyHex: noiseA, npub: fixtureNpub, nickname: "taken"), [], holder)
        ]
        for (request, owned, trust) in cases {
            let before = trust.contacts
            var verified: [String] = []
            #expect(!WeshDebugContactSeed.seed(request, into: trust, ownedNpubs: owned) { verified.append($0) }, "\(request.nickname)")
            #expect(trust.contacts == before, "\(request.nickname)")
            #expect(verified.isEmpty, "\(request.nickname)")
        }
    }

    /// Release builds have no seed entry point: the hook's file is all `#if DEBUG`, and every
    /// other mention of it in the app sources sits inside an `#if DEBUG` block.
    @Test func releaseBuildsContainNoSeedEntryPoint() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // bitchatTests
            .deletingLastPathComponent()  // repo root
        let hookFile = root.appendingPathComponent("bitchat/Services/WeshDebugContactSeed.swift")
        let hookLines = try String(contentsOf: hookFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        #expect(hookLines.first == "#if DEBUG")
        #expect(hookLines.last == "#endif")

        let markers = ["WeshDebugContactSeed", "applyWeshDebugHooks", "WESH_DEBUG_"]
        var mentions = 0
        let sources = try #require(FileManager.default.enumerator(at: root.appendingPathComponent("bitchat"), includingPropertiesForKeys: nil))
        for case let url as URL in sources where url.pathExtension == "swift" && url.lastPathComponent != hookFile.lastPathComponent {
            var conditions: [Bool] = []
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#if ") {
                    conditions.append(trimmed == "#if DEBUG")
                } else if trimmed.hasPrefix("#else") || trimmed.hasPrefix("#elseif"), !conditions.isEmpty {
                    conditions[conditions.count - 1] = false
                } else if trimmed.hasPrefix("#endif"), !conditions.isEmpty {
                    conditions.removeLast()
                } else if markers.contains(where: trimmed.contains) {
                    mentions += 1
                    #expect(conditions.contains(true), "\(url.lastPathComponent): \(trimmed)")
                }
            }
        }
        #expect(mentions > 0, "the startup call site must exist")
    }
}
#endif
