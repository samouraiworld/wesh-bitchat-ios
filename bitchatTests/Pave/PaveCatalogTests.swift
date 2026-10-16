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

    private static func sources() throws -> [(name: String, text: String)] {
        try FileManager.default.contentsOfDirectory(at: paveDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
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
}
