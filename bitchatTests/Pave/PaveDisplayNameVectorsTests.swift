import Foundation
import Testing
@testable import bitchat

/// Same shared vectors as Android PaveDisplayNameVectorsTest:
/// docs/plan/fixtures/wesh-display-name-v1.json, copied byte for byte into Pave/Fixtures.
@Suite("Pavé display name shared vectors")
struct PaveDisplayNameVectorsTests {
    private final class BundleToken {}

    private struct Vector: Decodable {
        let input: String
        let expect: String
        let display: String?
    }

    private struct Scripts: Decodable {
        let latinMayMixWith: [String]
        let neverMixTogether: [String]
        let alwaysUnnamed: [String]
    }

    private struct Fixture: Decodable {
        let confusables: [String: String]
        let afterLowercase: [String: String]
        let fingerprintCanonical: [String: String]
        let scripts: Scripts
        let reservedForTest: [String]
        let vectors: [Vector]
    }

    private func fixture() throws -> Fixture {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: BundleToken.self)
        #endif
        let url = try #require(
            bundle.url(forResource: "wesh-display-name-v1", withExtension: "json")
                ?? bundle.url(forResource: "wesh-display-name-v1", withExtension: "json", subdirectory: "Pave/Fixtures")
        )
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func strings(_ table: [Unicode.Scalar: Unicode.Scalar]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: table.map { (String($0.key), String($0.value)) })
    }

    @Test func confusablesTableMatchesTheSharedFixture() throws {
        #expect(strings(PaveDisplayName.confusables) == (try fixture().confusables))
    }

    @Test func afterLowercaseTableMatchesTheSharedFixture() throws {
        #expect(strings(PaveDisplayName.afterLowercase) == (try fixture().afterLowercase))
    }

    @Test func fingerprintCanonicalTableMatchesTheSharedFixture() throws {
        #expect(strings(PaveDisplayName.fingerprintCanonical) == (try fixture().fingerprintCanonical))
    }

    @Test func scriptGroupsMatchTheSharedFixtureAndAreKnownScripts() throws {
        let scripts = try fixture().scripts
        #expect(PaveDisplayName.latinMayMixWith == scripts.latinMayMixWith)
        #expect(PaveDisplayName.neverMixTogether == scripts.neverMixTogether)
        #expect(PaveDisplayName.alwaysUnnamed == scripts.alwaysUnnamed)
        for name in scripts.latinMayMixWith + scripts.neverMixTogether + scripts.alwaysUnnamed {
            #expect(PaveDisplayName.unicodeScripts.contains(name), "\(name) is not in the script list")
            #expect(PaveScriptClassifier.current.knows(name), "\(name) is not a script this ICU knows")
        }
    }

    @Test func everySharedVectorGivesTheExpectedOutcomeInFrenchAndEnglish() throws {
        let fixture = try fixture()
        #expect(fixture.vectors.count == 53)
        let reservedWords = fixture.reservedForTest + PaveCatalogStrings.reservedWords()
        for language in PaveReservedWords.languages {
            let strings = try PaveCatalogStrings.strings(language)
            let unnamed = try #require(strings["pave.name.unnamed"])
            let reserved = try #require(strings["pave.name.reserved"])
            for vector in fixture.vectors {
                let expected: String
                switch vector.expect {
                case "display": expected = try #require(vector.display)
                case "unnamed": expected = unnamed
                case "reserved": expected = reserved
                default: Issue.record("unknown outcome \(vector.expect)"); continue
                }
                let label = vector.input.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
                let shown = PaveDisplayName.remote(vector.input, unnamed: unnamed, reserved: reserved,
                                                   reservedWords: reservedWords)
                #expect(shown == expected, "\(language): \(label)")
            }
        }
    }
}

/// Pavé strings read straight from the catalog source, in each language, whatever the test
/// host's language or bundle layout.
enum PaveCatalogStrings {
    static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Pave
        .deletingLastPathComponent()  // bitchatTests
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("bitchat/Views/Wesh/Pave/Pave.xcstrings")

    /// Singular strings of `language` (plural entries are left out).
    static func strings(_ language: String) throws -> [String: String] {
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let entries = try #require(root["strings"] as? [String: [String: Any]])
        var result: [String: String] = [:]
        for (key, entry) in entries {
            let localization = (entry["localizations"] as? [String: Any])?[language] as? [String: Any]
            if let value = (localization?["stringUnit"] as? [String: Any])?["value"] as? String {
                result[key] = value
            }
        }
        return result
    }

    /// The reserved words as the app reads them, in French and English, from the catalog source.
    static func reservedWords() -> [String] {
        let tables = PaveReservedWords.languages.compactMap { try? strings($0) }
        return Array(PaveReservedWords.words(from: tables) { table, key in table[key] })
    }
}
