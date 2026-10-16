import CryptoKit
import Foundation
import Testing
@testable import bitchat

@Suite("Pavé reserved words")
struct PaveReservedWordsTests {
    /// Families of labels drawn next to a remote nickname. An entry matches its own key and every
    /// key that continues it after a dot. A new label in one of these families must join
    /// `PaveReservedWords`, or a peer could take it as a nickname.
    private let families = [
        "pave.bubble.you",  // « Vous »
        "pave.name",  // « Sans surnom », « Sans surnom (réservé) »
        "pave.inbox.verified", "pave.inbox.unverified",  // badges
        "pave.delivery", "pave.bubble.failedRetry", "pave.bubble.retryA11y",  // delivery states
        "pave.transport",  // transport
        "pave.inbox.publicTitle", "pave.inbox.publicFootnote",  // public room
        "pave.action.exchange", "pave.exchange.title",  // « Échanger »
        "pave.inbox.requests",  // « Demandes »
        "pave.fingerprint"  // « Empreinte de la clé », « Empreinte indisponible »
    ]

    private func inFamily(_ key: String) -> Bool {
        families.contains { key == $0 || key.hasPrefix($0 + ".") }
    }

    @Test func everyLabelOfTheReservedFamiliesIsInTheCentralList() throws {
        for language in PaveReservedWords.languages {
            let labels = try PaveCatalogStrings.strings(language).filter { inFamily($0.key) && !$0.value.contains("%") }
            #expect(!labels.isEmpty, "no reserved family found in \(language)")
            for key in labels.keys.sorted() {
                #expect(PaveReservedWords.keys.contains(key),
                        "\(language)/\(key) is shown next to nicknames but missing from PaveReservedWords")
            }
        }
    }

    @Test func everyReservedKeyExistsInFrenchAndEnglish() throws {
        #expect(PaveReservedWords.languages == ["fr", "en"])
        for language in PaveReservedWords.languages {
            let strings = try PaveCatalogStrings.strings(language)
            for key in PaveReservedWords.keys {
                #expect(strings[key] != nil, "\(key) is missing in \(language)")
            }
        }
        #expect(Set(PaveReservedWords.keys).count == PaveReservedWords.keys.count)
    }

    @Test func theListCarriesTheWordsTheRuleNames() {
        let words = Set(PaveCatalogStrings.reservedWords())
        for word in ["Vous", "You", "Sans surnom", "No nickname", "Sans surnom (réservé)", "No nickname (reserved)",
                     "Vérifié", "Non vérifié", "En attente", "Envoyé", "Reçu", "Échec", "via Internet", "Bluetooth",
                     "Salon public", "Public room", "Échanger", "Exchange", "Demandes", "Requests",
                     "Empreinte de la clé", "Key fingerprint", "Empreinte indisponible", "Fingerprint unavailable"] {
            #expect(words.contains(word), "\(word) is not reserved")
        }
    }

    @Test func theAppReadsBothLanguagesWhateverThePhoneLanguage() {
        let words = PaveReservedWords.all
        for word in ["Vous", "You", "Sans surnom", "No nickname", "Demandes", "Requests"] {
            #expect(words.contains(word), "\(word) is not reserved at run time")
        }
        #expect(PaveDisplayName.safe("Vous") == PaveCopy.text("pave.name.reserved"))
        #expect(PaveDisplayName.safe("You") == PaveCopy.text("pave.name.reserved"))
        #expect(PaveDisplayName.safe("Nora") == "Nora")
        #expect(PaveDisplayName.safe(nil) == PaveCopy.text("pave.name.unnamed"))
    }

    @Test func anEnglishPhoneStillMasksTheFrenchWords() throws {
        let reservedWords = PaveCatalogStrings.reservedWords()
        func shown(_ raw: String?, _ language: String) throws -> String {
            let strings = try PaveCatalogStrings.strings(language)
            return PaveDisplayName.remote(raw, unnamed: try #require(strings["pave.name.unnamed"]),
                                          reserved: try #require(strings["pave.name.reserved"]),
                                          reservedWords: reservedWords)
        }
        #expect(try shown("Vous", "en") == "No nickname (reserved)")
        #expect(try shown("Nora sans surnom", "en") == "No nickname (reserved)")
        #expect(try shown("You", "fr") == "Sans surnom (réservé)")
        #expect(try shown("Demandes", "en") == "No nickname (reserved)")
        #expect(try shown("Nora", "en") == "Nora")
        #expect(try shown(nil, "en") == "No nickname")
        #expect(try shown("No\u{200B}ra", "fr") == "Sans surnom")
    }
}

@Suite("Pavé short fingerprint")
struct PaveFingerprintTests {
    private let key = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 * 7) })

    @Test func isTheFirstFourGroupsOfTheKeySHA256Uppercase() throws {
        let digest = SHA256.hash(data: key).map { String(format: "%02X", $0) }.joined()
        let expected = stride(from: 0, to: 16, by: 4).map { offset -> String in
            let start = digest.index(digest.startIndex, offsetBy: offset)
            return String(digest[start..<digest.index(start, offsetBy: 4)])
        }.joined(separator: " ")
        let short = try #require(PaveFingerprint.short(key))
        #expect(short == expected)
        #expect(short.range(of: #"^[0-9A-F]{4}( [0-9A-F]{4}){3}$"#, options: .regularExpression) != nil)
    }

    @Test func differentKeysGiveDifferentFingerprints() {
        #expect(PaveFingerprint.short(key) != PaveFingerprint.short(Data(count: 32)))
    }

    @Test func noFingerprintWithoutAValidNoiseKey() {
        #expect(PaveFingerprint.short(nil) == nil)
        #expect(PaveFingerprint.short(Data(count: 31)) == nil)
        #expect(PaveFingerprint.short(Data(count: 33)) == nil)
    }

    @Test func voiceOverReadsItOneCharacterAtATime() {
        #expect(PaveFingerprint.spoken("7F3A 91C2") == "7 F 3 A, 9 1 C 2")
    }

    @Test func aRemoteNameCannotPassForAFingerprint() throws {
        let short = try #require(PaveFingerprint.short(key))
        #expect(PaveDisplayName.remote(short, unnamed: "?", reserved: "!", reservedWords: []) == "!")
    }
}
