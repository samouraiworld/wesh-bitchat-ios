import Foundation
import Testing
@testable import bitchat

@Suite("Limited local public-content catalogue v1")
struct WeshPublicContentPolicyTests {
    @Test func everyCatalogueEntryIsRecognisedInItsDeclaredCategory() {
        #expect(WeshPublicContentPolicy.catalogueVersion == 1)
        for category in WeshPublicContentPolicy.Category.allCases {
            for language in ["en", "fr"] {
                let rules = WeshPublicContentPolicy.catalogue.filter { $0.category == category && $0.language == language }
                #expect(!rules.isEmpty)
                for rule in rules {
                    #expect(WeshPublicContentPolicy.detectedCategory(in: rule.phrase) == category)
                    #expect(!WeshPublicContentPolicy.allows(rule.phrase + "!"))
                }
            }
        }
    }

    @Test func unicodeWhitespaceAndClauseBoundariesDoNotRewriteTheInput() {
        let examples = ["Ｉ ＷＩＬＬ ＫＩＬＬ ＹＯＵ", "I WILL ki\u{200B}ll you!", "Hello.\nJe vais te tuer demain.", "J’achète de la pornographie infantile"]
        for text in examples {
            let bytes = Array(text.utf8)
            #expect(!WeshPublicContentPolicy.allows(text))
            #expect(Array(text.utf8) == bytes)
        }
    }

    @Test func ordinaryWordsNegationsAndExplanatoryContextsAreNotSubstringBlocked() {
        for text in ["Kill all processes in the test", "I will kill your process", "Do not kill yourself", "Ne va pas te suicider : demande de l’aide", "The phrase i will kill you is a threat", "Nous combattons la pornographie infantile", "Aide et prévention du suicide", "Hello 👋", "/help"] {
            #expect(WeshPublicContentPolicy.allows(text))
        }
    }

    @Test func knownLimitsAreExplicitRatherThanClaimingSemanticUnderstanding() {
        // A quote that starts the clause can be blocked. A threat outside the
        // finite catalogue can pass. Neither result is an assertion of safety.
        #expect(!WeshPublicContentPolicy.allows("\"I will kill you\" is a threatening quotation"))
        #expect(WeshPublicContentPolicy.allows("Je vais te détruire"))
    }

    @Test func oversizedPublicInputIsRejectedRatherThanPrefixTruncated() {
        #expect(WeshPublicContentPolicy.allows(String(repeating: "a", count: WeshPublicContentPolicy.maximumUTF8Bytes)))
        #expect(!WeshPublicContentPolicy.allows(String(repeating: "a", count: WeshPublicContentPolicy.maximumUTF8Bytes + 1)))
    }
}
