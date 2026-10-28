import Foundation
import Testing

/// Pavé copy lives in its own catalog, in French and English only: every other locale
/// falls back to English. These checks keep that catalog and the code in step.
@Suite("Pavé string catalog")
struct PaveCatalogTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Pave
        .deletingLastPathComponent()  // bitchatTests
        .deletingLastPathComponent()  // repo root
    private static let paveDirectory = repoRoot.appendingPathComponent("bitchat/Views/Wesh/Pave")

    /// key -> locale -> every value (one per plural form)
    private static func load(_ name: String) throws -> [String: [String: [String]]] {
        let data = try Data(contentsOf: paveDirectory.appendingPathComponent(name))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: [String: Any]])
        var result: [String: [String: [String]]] = [:]
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            var perLocale: [String: [String]] = [:]
            for (locale, localization) in localizations {
                if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
                    perLocale[locale] = [value]
                } else if let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]] {
                    #expect(plural["one"] != nil && plural["other"] != nil, "\(key) \(locale) needs one and other")
                    perLocale[locale] = plural.values.compactMap { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
                }
            }
            result[key] = perLocale
        }
        return result
    }

    /// The Pavé screens, plus the Wesh views next to them that read Pavé copy (the root view).
    private static func sources() throws -> [(name: String, text: String)] {
        try [paveDirectory, paveDirectory.deletingLastPathComponent()].flatMap { directory in
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
                .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
        }
    }

    private static func formatSpecifiers(_ value: String) -> [String] {
        let pattern = try? NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|ld|d|@)"#)
        let range = NSRange(value.startIndex..., in: value)
        return (pattern?.matches(in: value, range: range) ?? []).compactMap { match in
            Range(match.range, in: value).map { String(value[$0]).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }
        }.sorted()
    }

    @Test func everyKeyHasFrenchAndEnglishWithMatchingPlaceholders() throws {
        let catalog = try Self.load("Pave.xcstrings")
        #expect(!catalog.isEmpty)
        for (key, locales) in catalog.sorted(by: { $0.key < $1.key }) {
            let french = try #require(locales["fr"], "\(key) has no French")
            let english = try #require(locales["en"], "\(key) has no English")
            #expect(!french.contains(where: \.isEmpty) && !english.contains(where: \.isEmpty), "\(key) has an empty value")
            let expected = Self.formatSpecifiers(english[0])
            for value in french + english {
                #expect(Self.formatSpecifiers(value) == expected, "\(key) placeholders differ: \(value)")
            }
        }
    }

    @Test func everyKeyWrittenInPaveCodeExistsInTheCatalog() throws {
        let keys = Set(try Self.load("Pave.xcstrings").keys)
        let pattern = try NSRegularExpression(pattern: #""(pave\.[A-Za-z0-9.]+)""#)
        var referenced: Set<String> = []
        for source in try Self.sources() {
            let range = NSRange(source.text.startIndex..., in: source.text)
            for match in pattern.matches(in: source.text, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source.text) else { continue }
                let key = String(source.text[keyRange])
                referenced.insert(key)
                #expect(keys.contains(key), "\(source.name) uses \(key), absent from Pave.xcstrings")
            }
        }
        #expect(!referenced.isEmpty)
        #expect(keys.subtracting(referenced).isEmpty, "unused keys: \(keys.subtracting(referenced).sorted())")
    }

    @Test func activeWeshViewsKeepLiteralUIStringsInTheCatalog() throws {
        let active = Set(["WeshRootView.swift", "WeshPrivacy.swift", "WeshRequests.swift", "WeshDesignSystem.swift"])
        let patterns = try [
            #"\b(?:Text|Label|Button|TextField|DatePicker|Section)\s*\(\s*"([^"]+)""#,
            #"\.(?:navigationTitle|accessibilityLabel|accessibilityHint)\s*\(\s*"([^"]+)""#
        ].map { try NSRegularExpression(pattern: $0) }
        for source in try Self.sources().filter({ active.contains($0.name) }) {
            for pattern in patterns {
                for match in pattern.matches(in: source.text, range: NSRange(source.text.startIndex..., in: source.text)) {
                    let range = try #require(Range(match.range(at: 1), in: source.text))
                    // The brand keeps its spelling in both languages; icons, storage keys and
                    // user content are outside these literal-copy call sites.
                    #expect(["Wesh", "wesh"].contains(String(source.text[range])),
                            "\(source.name) has a literal UI string outside the catalog")
                }
            }
        }
    }

    @Test func copyNeverPromisesAnonymityOrSecurity() throws {
        let banned = ["anonyme", "intraçable", "sécurisé", "anonymous", "untraceable", "secure"]
        for (key, locales) in try Self.load("Pave.xcstrings") {
            for value in locales.values.flatMap({ $0 }) {
                let lowered = value.lowercased()
                for word in banned {
                    #expect(!lowered.contains(word), "\(key) says « \(word) »")
                }
            }
        }
    }

    /// The app asks for nothing: donations live on the website only.
    @Test func copyNeverAsksForDonations() throws {
        let pattern = try NSRegularExpression(pattern: #"\b(?:dons|donations?|donate)\b"#, options: .caseInsensitive)
        for (key, locales) in try Self.load("Pave.xcstrings") {
            for value in locales.values.flatMap({ $0 }) {
                let range = NSRange(value.startIndex..., in: value)
                #expect(pattern.firstMatch(in: value, range: range) == nil, "\(key) asks for donations: \(value)")
            }
        }
        for source in try Self.sources() {
            #expect(!source.text.contains("/dons"), "\(source.name) links to the donation page")
        }
    }

    /// App Shortcut phrases use `AppShortcuts.strings`: the catalog form needs iOS 17.
    @Test func everySiriPhraseIsTranslated() throws {
        func phrases(_ locale: String) throws -> [String: String] {
            let url = Self.repoRoot.appendingPathComponent("bitchat/\(locale).lproj/AppShortcuts.strings")
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
            return try #require(plist as? [String: String])
        }
        let english = try phrases("en")
        let french = try phrases("fr")
        let source = try #require(try Self.sources().first { $0.name == "PaveEraseShortcut.swift" }?.text)
        let pattern = try NSRegularExpression(pattern: #""([^"\n]*\\\(\.applicationName\)[^"\n]*)""#)
        let range = NSRange(source.startIndex..., in: source)
        let codePhrases = pattern.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map {
                String(source[$0]).replacingOccurrences(of: #"\(.applicationName)"#, with: "${applicationName}")
            }
        }
        #expect(!codePhrases.isEmpty)
        for phrase in codePhrases {
            #expect(english[phrase] == phrase, "missing English phrase for « \(phrase) »")
            #expect(french[phrase]?.contains("${applicationName}") == true, "missing French phrase for « \(phrase) »")
        }
        #expect(Set(english.keys) == Set(codePhrases) && Set(french.keys) == Set(codePhrases))
    }
}
