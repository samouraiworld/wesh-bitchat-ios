import Foundation

/// Local public-room policy only. Never pass private-message text to this policy.
/// Catalogue v1 recognises a few explicit FR/EN formulations, not every abusive
/// meaning, language or evasion. Quoted formulations can be false positives.
/// No networking, persistence, logging or rewriting of the original text.
enum WeshPublicContentPolicy {
    enum Category: String, CaseIterable, Sendable {
        case directedThreat, selfHarmEncouragement, childSexualExploitation, violentHate
    }

    struct Rule: Sendable {
        let language: String
        let category: Category
        /// Canonical space-separated tokens, portable to the Android catalogue.
        let phrase: String
        let tokens: [String]

        init(language: String, category: Category, phrase: String) {
            self.language = language
            self.category = category
            self.phrase = phrase
            self.tokens = phrase.split(separator: " ").map(String.init)
        }
    }

    static let catalogueVersion = 1
    /// Match the public wire cap; never truncate and accept only a prefix.
    static let maximumUTF8Bytes = 65_535

    static let catalogue: [Rule] = [
        Rule(language: "en", category: .directedThreat, phrase: "i will kill you"),
        Rule(language: "en", category: .directedThreat, phrase: "i ll kill you"),
        Rule(language: "en", category: .directedThreat, phrase: "i am going to kill you"),
        Rule(language: "en", category: .directedThreat, phrase: "i will rape you"),
        Rule(language: "fr", category: .directedThreat, phrase: "je vais te tuer"),
        Rule(language: "fr", category: .directedThreat, phrase: "je vais vous tuer"),
        Rule(language: "fr", category: .directedThreat, phrase: "je vais te violer"),
        Rule(language: "fr", category: .directedThreat, phrase: "je vais vous violer"),
        Rule(language: "en", category: .selfHarmEncouragement, phrase: "kill yourself"),
        Rule(language: "en", category: .selfHarmEncouragement, phrase: "go kill yourself"),
        Rule(language: "fr", category: .selfHarmEncouragement, phrase: "va te suicider"),
        Rule(language: "fr", category: .selfHarmEncouragement, phrase: "allez vous suicider"),
        Rule(language: "en", category: .childSexualExploitation, phrase: "send me child porn"),
        Rule(language: "en", category: .childSexualExploitation, phrase: "i sell child porn"),
        Rule(language: "en", category: .childSexualExploitation, phrase: "i buy child porn"),
        Rule(language: "fr", category: .childSexualExploitation, phrase: "envoie moi de la pornographie infantile"),
        Rule(language: "fr", category: .childSexualExploitation, phrase: "je vends de la pornographie infantile"),
        Rule(language: "fr", category: .childSexualExploitation, phrase: "j achete de la pornographie infantile"),
        Rule(language: "en", category: .violentHate, phrase: "kill all jews"),
        Rule(language: "en", category: .violentHate, phrase: "kill all muslims"),
        Rule(language: "en", category: .violentHate, phrase: "kill all black people"),
        Rule(language: "en", category: .violentHate, phrase: "kill all gay people"),
        Rule(language: "fr", category: .violentHate, phrase: "tuez tous les juifs"),
        Rule(language: "fr", category: .violentHate, phrase: "tuez tous les musulmans"),
        Rule(language: "fr", category: .violentHate, phrase: "tuez tous les noirs"),
        Rule(language: "fr", category: .violentHate, phrase: "tuez tous les homosexuels")
    ]
    private static let catalogueByStart = Dictionary(grouping: catalogue, by: { $0.tokens[0] })

    static func allows(_ publicText: String) -> Bool {
        guard publicText.utf8.count <= maximumUTF8Bytes else { return false }
        return detectedCategory(in: publicText) == nil
    }

    static func detectedCategory(in publicText: String) -> Category? {
        guard publicText.utf8.count <= maximumUTF8Bytes else { return nil }
        let normalized = publicText.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let clauses = normalized.components(separatedBy: CharacterSet(charactersIn: ".!?;\n\r"))
        for clause in clauses {
            let words = tokens(in: clause)
            guard let first = words.first else { continue }
            for rule in catalogueByStart[first] ?? [] where words.starts(with: rule.tokens) {
                return rule.category
            }
        }
        return nil
    }

    /// Ignore formatting controls for the decision, but never return a changed
    /// message. Match whole tokens at clause start, not ordinary word substrings.
    private static func tokens(in clause: String) -> [String] {
        let scalars = clause.unicodeScalars.filter { $0.properties.generalCategory != .format }
        let text = scalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
        return text.split(separator: " ").map(String.init)
    }
}
