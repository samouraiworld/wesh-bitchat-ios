import Foundation
import Testing
@testable import bitchat

/// The remote nickname rule, case by case. The shared vectors live in PaveDisplayNameVectorsTests.
@Suite("Pavé display name rule")
struct PaveDisplayNameTests {
    private func safe(_ raw: String?, _ reserved: [String] = []) -> String {
        PaveDisplayName.remote(raw, unnamed: "?", reserved: "!", reservedWords: reserved)
    }

    /// Builds strings from code points so no invisible character sits in this source file.
    private func cp(_ values: UInt32...) -> String {
        String(String.UnicodeScalarView(values.compactMap(Unicode.Scalar.init)))
    }

    private var rlo: String { cp(0x202E) }
    private var zwsp: String { cp(0x200B) }
    private var lri: String { cp(0x2066) }
    private var pdi: String { cp(0x2069) }
    private var acute: String { cp(0x0301) }

    @Test func keepsAnOrdinaryNickname() {
        #expect(safe("Renard 42") == "Renard 42")
        #expect(safe("Léo 17") == "Léo 17")
    }

    @Test func anInvisibleCharacterInsideTheNameHidesTheWholeName() {
        #expect(safe("Nora\(rlo)gpj.exe") == "?")
        #expect(safe("No\(zwsp)ra\(lri)\(pdi)") == "?")
        #expect(safe("Nora \(zwsp) Sami") == "?")
    }

    @Test func invisibleCharactersAtEitherEndAreStripped() {
        #expect(safe("\(lri)\(zwsp) Nora \(pdi)\(rlo)") == "Nora")
    }

    @Test func staysOnOneLineWithoutControlOrPrivateUseCharacters() {
        #expect(safe("Nora\nVérifiée") == "?")
        #expect(safe("Nora" + cp(0xE000) + "Sami") == "?")
        #expect(safe("\tNora Vérifiée\r\n" + cp(0x07, 0xE000)) == "Nora Vérifiée")
        #expect(safe("Nora" + cp(0x2028) + "Sami") == "Nora Sami")
        #expect(safe("  Nora " + cp(0x00A0, 0x3000) + " Sami  ") == "Nora Sami")
    }

    @Test func nfkcFoldsLookAlikeCompatibilityForms() {
        #expect(safe(cp(0xFF2E, 0xFF4F, 0xFF52, 0xFF41)) == "Nora")
        #expect(safe(cp(0xFB01)) == "fi")
        #expect(safe("Le\u{0301}o") == "Léo")
    }

    @Test func stackedCombiningMarksAreCappedAndALeadingMarkIsDropped() {
        // "x" has no precomposed accented form, so NFKC leaves the marks in place.
        #expect(safe("x" + String(repeating: acute, count: 6) + "ora") == "x\(acute)\(acute)ora")
        #expect(safe("\(acute)Nora") == "Nora")
    }

    @Test func longNamesAreElidedInTheMiddleOnWholeGraphemes() {
        let grapheme = "x\(acute)\(acute)"
        #expect(safe(String(repeating: grapheme, count: 40))
            == String(repeating: grapheme, count: 16) + "…" + String(repeating: grapheme, count: 15))
        #expect(safe("Nora la vraie qui ecrit trop longtemps ou pas") == "Nora la vraie qu…ongtemps ou pas")
        let exact = String(repeating: "a", count: PaveDisplayName.maximumGraphemes)
        #expect(safe(exact) == exact)
    }

    @Test func blankButAssignedCodePointsAreDropped() {
        #expect(safe(cp(0x3164)) == "?")
        #expect(safe(cp(0x2800)) == "?")
        #expect(safe(cp(0x1160)) == "?")
        #expect(safe(cp(0x115F, 0xFFA0, 0x17B4, 0x17B5, 0x180B, 0x180E, 0xFE00, 0xFE0F)) == "?")
        #expect(safe(cp(0x3164) + "Nora" + cp(0x2800)) == "Nora")
        #expect(safe("No" + cp(0x3164) + "ra") == "?")
    }

    @Test func aNameNeedsAtLeastOneVisibleCharacter() {
        #expect(safe(acute + acute) == "?")
        #expect(safe("-") == "-")
        #expect(safe(" 42 ") == "42")
    }

    @Test func emptyOrInvisibleNamesFallBack() {
        #expect(safe(nil) == "?")
        #expect(safe("") == "?")
        #expect(safe("   ") == "?")
        #expect(safe(rlo + zwsp + cp(0)) == "?")
    }

    @Test func lettersMixingConfusableScriptsHideTheName() {
        #expect(safe("N" + cp(0x043E) + "ra") == "?")
        #expect(safe(cp(0x0391) + "lex") == "?")
        #expect(safe("Вера 42") == "Вера 42")
        #expect(safe("小明 Lee") == "小明 Lee")
    }

    @Test func aNameReadingAsAReservedWordIsMasked() {
        let reserved = ["Vous", "Sans surnom", "You"]
        #expect(safe("v o u s", reserved) == "!")
        #expect(safe("Sans surnom Nora", reserved) == "!")
        #expect(safe("You Nora", reserved) == "You Nora")  // under 4 letters: only the whole name
        #expect(safe("Y0U", reserved) == "!")
        #expect(safe("Nora", reserved) == "Nora")
        #expect(safe("Vousseau", reserved) == "Vousseau")
        #expect(safe("Vous 42", reserved) == "!")
    }

    @Test func theElidedNameIsCheckedToo() {
        // In full, "zz" splits it into "vo zz us"; once elided, only "vo…us" is left.
        let name = "Vo" + String(repeating: ".", count: 15) + "zz" + String(repeating: ".", count: 15) + "us"
        #expect(safe(name) == "Vo" + String(repeating: ".", count: 14) + "…" + String(repeating: ".", count: 13) + "us")
        #expect(safe(name, ["Vous"]) == "!")
    }

    @Test func emojiKeepTheirJoinersAndPresentationSelectors() {
        let heart = cp(0x2764, 0xFE0F)
        let technologist = cp(0x1F469, 0x200D, 0x1F4BB)
        let keycapOne = cp(0x31, 0xFE0F, 0x20E3)
        #expect(safe("\(heart) Nora") == "\(heart) Nora")
        #expect(safe("Nora \(heart)") == "Nora \(heart)")
        #expect(safe("\(technologist) Nora") == "\(technologist) Nora")
        #expect(safe(keycapOne) == keycapOne)
        #expect(safe(cp(0x2764, 0xFE0E)) == cp(0x2764, 0xFE0E))
    }

    @Test func joinersAndSelectorsOutsideAnEmojiStayInvisible() {
        #expect(safe("No" + cp(0x200D) + "ra") == "?")
        #expect(safe("No" + cp(0xFE0F) + "ra") == "?")
        #expect(safe("Nora" + cp(0xFE0F)) == "Nora")
    }

    @Test func tagCharactersAreRefusedEvenInsideAnEmoji() {
        #expect(safe(cp(0x1F3F4, 0xE0067, 0xE0062, 0xE007F) + " Nora") == "?")
        #expect(safe("Nora" + cp(0xE0041, 0xE0042) + " Lee") == "?")
    }

    @Test func aHundredThousandCharacterNameIsHandledFast() {
        let huge = String(repeating: "a ", count: 50_000)
        let start = Date()
        #expect(safe(huge, ["Vous", "Sans surnom"]) == "a a a a a a a a…a a a a a a a a")
        #expect(safe("Vous " + huge, ["Vous"]) == "!")
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func onlyTheFirst256CodePointsOfTheRawNameCount() {
        let filler = String(repeating: "a ", count: 128)
        #expect(safe(String(filler.dropLast(6)) + "Vous", ["Vous"]) == "!")
        #expect(safe(filler + "Vous", ["Vous"]) == "a a a a a a a a…a a a a a a a a")
        #expect(safe(filler + "No" + cp(0x200B) + "ra") == "a a a a a a a a…a a a a a a a a")
    }

    @Test func defaultIgnorableCodePointsAreInvisibleNotMarks() {
        #expect(safe("Nora" + cp(0x034F) + "Lee") == "?")  // combining grapheme joiner
        #expect(safe("Nora" + cp(0xE0100) + "Lee") == "?")  // variation selector 17
        #expect(safe("Nora" + cp(0x180F) + "Lee") == "?")  // Mongolian free variation selector four
        #expect(safe("Nora" + cp(0xFFF0) + "Lee") == "?")  // reserved default-ignorable
        #expect(safe("Nora" + cp(0x034F, 0xE0100)) == "Nora")
    }

    @Test func capitalIAndSmallIReadLikeLOnBothSides() {
        let reserved = ["No nickname", "Not verified", "Failed"]
        #expect(safe("NO NICKNAME", reserved) == "!")
        #expect(safe("NOT VERIFIED", reserved) == "!")
        #expect(safe("FAILED", reserved) == "!")
        #expect(safe("Fa1led", reserved) == "!")
        #expect(safe("Lina", reserved) == "Lina")
    }

    @Test func emojiJoinersAndSelectorsAreKeptOnlyInTheirExactPlace() {
        let heart = cp(0x2764)
        let fire = cp(0x1F525)
        #expect(safe(heart + cp(0xFE0F, 0x200D) + fire) == heart + cp(0xFE0F, 0x200D) + fire)
        #expect(safe(cp(0x23, 0xFE0F, 0x20E3)) == cp(0x23, 0xFE0F, 0x20E3))
        #expect(safe(heart + cp(0xFE0F, 0xFE0F) + " Nora") == "?")  // doubled selector
        #expect(safe(heart + cp(0x200D) + " Nora") == "?")  // joiner not followed by a symbol
        #expect(safe(cp(0x1F469, 0x200D, 0x200D, 0x1F4BB) + " Nora") == "?")  // doubled joiner
        #expect(safe("Nora " + cp(0x200D) + heart) == "?")  // joiner not preceded by a symbol
        #expect(safe("A" + cp(0xFE0F, 0x20E3) + " Nora") == "?")  // keycap needs 0-9, # or *
    }

    @Test func keptSelectorsDoNotResetTheMarkBudget() {
        let heart = cp(0x2764, 0xFE0F)
        #expect(safe(heart + String(repeating: acute, count: 4)) == heart + acute + acute)
    }

    @Test func aSkinToneMaySitBetweenASymbolAndItsJoiner() {
        let coder = cp(0x1F469, 0x1F3FD, 0x200D, 0x1F4BB)
        #expect(safe("\(coder) Nora") == "\(coder) Nora")
        #expect(safe("Nora" + cp(0x1F3FD, 0x200D, 0x1F4BB)) == "?")  // tone without a symbol before it
    }

    @Test func aNameImitatingTheShortFingerprintIsMasked() {
        #expect(safe("Nora A1B2 C3D4") == "!")
        #expect(safe("a1b2c3d4") == "!")
        #expect(safe("A1B2-C3D4 Nora") == "!")
        #expect(safe("Nora 1010 1010") == "!")  // checked before 1 and 0 are folded to l and o
        #expect(safe("Nora 2024") == "Nora 2024")
        #expect(safe("OB5E 44D8") == "!")  // O reads as 0
        #expect(safe("Nora 0F3A 9lC2") == "!")  // l reads as 1
        #expect(safe("ABIE 4ID8") == "!")  // I reads as 1
        #expect(safe("Café 2024") == "Café 2024")  // each group needs a digit
        #expect(safe("dead beef") == "dead beef")
        #expect(safe("A1B2 Nora C3D4") == "A1B2 Nora C3D4")
    }

    @Test func latinMixesOnlyWithEastAsianScripts() {
        #expect(safe("小明 Lee") == "小明 Lee")
        let eastAsian = "Nora " + cp(0x3072, 0x30AB, 0xD55C, 0x3105)
        #expect(safe(eastAsian) == eastAsian)
        #expect(safe("Nora " + cp(0x0627, 0x0644, 0x0641)) == "?")  // Arabic
        #expect(safe(cp(0x0627, 0x0644, 0x0641)) == cp(0x0627, 0x0644, 0x0641))
        #expect(safe(cp(0x0412, 0x03B1)) == "?")  // Cyrillic with Greek
        #expect(safe(cp(0x0585) + cp(0x0391)) == "?")  // Armenian with Greek
    }

    @Test func rareLatinLookAlikeScriptsAreRefusedEvenAlone() {
        #expect(safe(cp(0xA4E6, 0xA4F3, 0xA4F4, 0xA4E2)) == "?")  // Lisu
        #expect(safe(cp(0x13A0, 0x13A1)) == "?")  // Cherokee
        #expect(safe(cp(0x2C80, 0x2C81)) == "?")  // Coptic
        #expect(safe(cp(0x1401, 0x1402)) == "?")  // Canadian syllabics
        #expect(safe(cp(0x2D30, 0x2D31)) == "?")  // Tifinagh
        #expect(safe(cp(0x10300, 0x10301)) == "?")  // Old Italic
        #expect(safe(cp(0x104B0, 0x104D8)) == "?")  // Osage
    }

    @Test func digitsThatLookLikeLettersAreFoldedForReservedWords() {
        #expect(safe("Vou5", ["Vous"]) == "!")
        #expect(safe("R3çu", ["Reçu"]) == "!")
        #expect(safe("8luetooth", ["Bluetooth"]) == "!")
    }

    @Test func otherScriptsStandAlone() {
        for name in ["שלום", "สมชาย", "राहुल", "ტატო", "Ἀλέξης"] {
            #expect(safe(name) == name.precomposedStringWithCompatibilityMapping, "\(name)")
        }
    }

    @Test func aLetterOfAScriptTheSystemDoesNotKnowIsRefused() {
        #expect(!PaveDisplayName.hasRefusedScripts("Nora"))
        // As on a system whose ICU predates a script: Latin missing from the known list.
        let older = PaveScriptClassifier(known: PaveDisplayName.unicodeScripts.filter { $0 != "Latin" })
        #expect(PaveDisplayName.hasRefusedScripts("Nora", classifier: older))
        #expect(!PaveDisplayName.hasRefusedScripts("42 !", classifier: older))
        // A name the system cannot compile is skipped, never trusted.
        let unknownName = PaveScriptClassifier(known: PaveDisplayName.unicodeScripts + ["Not_A_Script"])
        #expect(!unknownName.knows("Not_A_Script"))
        #expect(!PaveDisplayName.hasRefusedScripts("Nora", classifier: unknownName))
    }
}
