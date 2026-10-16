import Foundation

/// The remote nickname rule shared with Android (design system README, « Surnom distant », v1;
/// vectors in `wesh-display-name-v1.json`). Pavé components apply it themselves, through
/// `safe(_:)`, so a caller cannot forget it:
/// 1. The raw input is cut to `maximumRawScalars` code points, then NFKC. Nothing past that cap
///    is looked at, so an oversized name costs no more than a long one.
/// 2. Invisible characters (control, format such as bidi and zero-width, Default_Ignorable,
///    private-use, unassigned, blank glyphs) are stripped at both ends; one between visible
///    characters makes the whole name unnamed rather than being removed silently. Emoji keep their
///    joiner and presentation selectors, strictly in place; tags are refused everywhere.
/// 3. At most `maximumCombiningMarks` marks per character; one line.
/// 4. Scripts of the letters: Latin mixes only with `latinMayMixWith`; `neverMixTogether` never
///    mix with each other; any letter of `alwaysUnnamed`, or of a script this system cannot name,
///    makes it unnamed.
/// 5. At most `maximumGraphemes` graphemes, elided in the middle.
/// 6. A name whose skeleton reads as a reserved word, in full or elided, is masked as reserved;
///    so is one that imitates the short key fingerprint.
enum PaveDisplayName {
    static let maximumGraphemes = 32
    static let maximumCombiningMarks = 2
    static let maximumRawScalars = 256
    /// A reserved word this long or longer also masks names that start or end with it.
    static let minimumAffixLetters = 4

    private static let ellipsis = "…"
    private static let zeroWidthJoiner: UInt32 = 0x200D
    private static let textPresentation: UInt32 = 0xFE0E
    private static let emojiPresentation: UInt32 = 0xFE0F
    private static let combiningKeycap: UInt32 = 0x20E3

    /// Script groups of rule 4, by Unicode script name as in the shared vectors file.
    /// Common and Inherited letters are ignored.
    static let latinMayMixWith = ["Han", "Hiragana", "Katakana", "Hangul", "Bopomofo"]
    static let neverMixTogether = ["Latin", "Greek", "Cyrillic", "Armenian"]
    static let alwaysUnnamed = ["Cherokee", "Lisu", "Coptic", "Canadian_Aboriginal", "Old_Italic", "Tifinagh", "Osage"]

    /// Every Unicode script name (PropertyValueAliases, Unicode 16). Swift has no script property,
    /// so letters are placed with ICU `\p{Script=…}` classes; a letter in none of them, such as one
    /// of a script newer than the system's ICU, is refused (see `PaveScriptClassifier`).
    static let unicodeScripts = [
        "Adlam", "Ahom", "Anatolian_Hieroglyphs", "Arabic", "Armenian", "Avestan", "Balinese", "Bamum",
        "Bassa_Vah", "Batak", "Bengali", "Bhaiksuki", "Bopomofo", "Brahmi", "Braille", "Buginese", "Buhid",
        "Canadian_Aboriginal", "Carian", "Caucasian_Albanian", "Chakma", "Cham", "Cherokee", "Chorasmian",
        "Common", "Coptic", "Cuneiform", "Cypriot", "Cypro_Minoan", "Cyrillic", "Deseret", "Devanagari",
        "Dives_Akuru", "Dogra", "Duployan", "Egyptian_Hieroglyphs", "Elbasan", "Elymaic", "Ethiopic", "Garay",
        "Georgian", "Glagolitic", "Gothic", "Grantha", "Greek", "Gujarati", "Gunjala_Gondi", "Gurmukhi",
        "Gurung_Khema", "Han", "Hangul", "Hanifi_Rohingya", "Hanunoo", "Hatran", "Hebrew", "Hiragana",
        "Imperial_Aramaic", "Inherited", "Inscriptional_Pahlavi", "Inscriptional_Parthian", "Javanese", "Kaithi",
        "Kannada", "Katakana", "Kawi", "Kayah_Li", "Kharoshthi", "Khitan_Small_Script", "Khmer", "Khojki",
        "Khudawadi", "Kirat_Rai", "Lao", "Latin", "Lepcha", "Limbu", "Linear_A", "Linear_B", "Lisu", "Lycian",
        "Lydian", "Mahajani", "Makasar", "Malayalam", "Mandaic", "Manichaean", "Marchen", "Masaram_Gondi",
        "Medefaidrin", "Meetei_Mayek", "Mende_Kikakui", "Meroitic_Cursive", "Meroitic_Hieroglyphs", "Miao", "Modi",
        "Mongolian", "Mro", "Multani", "Myanmar", "Nabataean", "Nag_Mundari", "Nandinagari", "New_Tai_Lue", "Newa",
        "Nko", "Nushu", "Nyiakeng_Puachue_Hmong", "Ogham", "Ol_Chiki", "Ol_Onal", "Old_Hungarian", "Old_Italic",
        "Old_North_Arabian", "Old_Permic", "Old_Persian", "Old_Sogdian", "Old_South_Arabian", "Old_Turkic",
        "Old_Uyghur", "Oriya", "Osage", "Osmanya", "Pahawh_Hmong", "Palmyrene", "Pau_Cin_Hau", "Phags_Pa",
        "Phoenician", "Psalter_Pahlavi", "Rejang", "Runic", "Samaritan", "Saurashtra", "Sharada", "Shavian",
        "Siddham", "SignWriting", "Sinhala", "Sogdian", "Sora_Sompeng", "Soyombo", "Sundanese", "Sunuwar",
        "Syloti_Nagri", "Syriac", "Tagalog", "Tagbanwa", "Tai_Le", "Tai_Tham", "Tai_Viet", "Takri", "Tamil",
        "Tangsa", "Tangut", "Telugu", "Thaana", "Thai", "Tibetan", "Tifinagh", "Tirhuta", "Todhri", "Toto",
        "Tulu_Tigalari", "Ugaritic", "Vai", "Vithkuqi", "Wancho", "Warang_Citi", "Yezidi", "Yi", "Zanabazar_Square"
    ]

    /// Look-alikes (Cyrillic, Greek, Armenian, Latin small capitals, dotless i) folded before
    /// lowercasing when comparing with reserved words. Same table as the shared vectors file;
    /// PaveDisplayNameVectorsTests keeps the two equal.
    static let confusables: [Unicode.Scalar: Unicode.Scalar] = [
        "\u{0410}": "a", "\u{0412}": "b", "\u{0415}": "e", "\u{041A}": "k", "\u{041C}": "m", "\u{041D}": "h",
        "\u{041E}": "o", "\u{0420}": "p", "\u{0421}": "c", "\u{0422}": "t", "\u{0425}": "x", "\u{0423}": "y",
        "\u{0430}": "a", "\u{0435}": "e", "\u{043E}": "o", "\u{0440}": "p", "\u{0441}": "c", "\u{0443}": "y",
        "\u{0445}": "x", "\u{0456}": "i", "\u{0458}": "j", "\u{0455}": "s", "\u{0501}": "d", "\u{04BB}": "h",
        "\u{04CF}": "l", "\u{04C0}": "l", "\u{0406}": "i", "\u{0408}": "j", "\u{0405}": "s", "\u{051B}": "q",
        "\u{051D}": "w",
        "\u{0391}": "a", "\u{0392}": "b", "\u{0395}": "e", "\u{0396}": "z", "\u{0397}": "h", "\u{0399}": "i",
        "\u{039A}": "k", "\u{039C}": "m", "\u{039D}": "n", "\u{039F}": "o", "\u{03A1}": "p", "\u{03A4}": "t",
        "\u{03A5}": "y", "\u{03A7}": "x", "\u{03B1}": "a", "\u{03B9}": "i", "\u{03BA}": "k", "\u{03BD}": "v",
        "\u{03BF}": "o", "\u{03C1}": "p", "\u{03C5}": "u",
        "\u{1D00}": "a", "\u{0299}": "b", "\u{1D04}": "c", "\u{1D05}": "d", "\u{1D07}": "e", "\u{A730}": "f",
        "\u{0262}": "g", "\u{029C}": "h", "\u{026A}": "i", "\u{1D0A}": "j", "\u{1D0B}": "k", "\u{029F}": "l",
        "\u{1D0D}": "m", "\u{0274}": "n", "\u{1D0F}": "o", "\u{1D18}": "p", "\u{0280}": "r", "\u{A731}": "s",
        "\u{1D1B}": "t", "\u{1D1C}": "u", "\u{1D20}": "v", "\u{1D21}": "w", "\u{028F}": "y", "\u{1D22}": "z",
        "\u{0131}": "i",
        "\u{0585}": "o", "\u{057D}": "u", "\u{0578}": "n", "\u{0570}": "h", "\u{0581}": "g", "\u{0566}": "q"
    ]

    /// Applied after lowercasing, to names and reserved words alike, so "NO NICKNAME", "N0 nickname"
    /// and "no nickname" share one skeleton. Same table as the shared vectors file.
    static let afterLowercase: [Unicode.Scalar: Unicode.Scalar] = [
        "i": "l", "l": "l", "1": "l", "0": "o", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b"
    ]

    /// Letters read as the digits they resemble before looking for a fingerprint; same table as
    /// the shared vectors file.
    static let fingerprintCanonical: [Unicode.Scalar: Unicode.Scalar] = ["o": "0", "i": "1", "l": "1"]

    /// Two groups of 4 hex characters, each with at least one digit, joined or one space apart.
    private static let fingerprintLike = try? NSRegularExpression(
        pattern: "(?=[0-9a-f]{0,3}[0-9])[0-9a-f]{4} ?(?=[0-9a-f]{0,3}[0-9])[0-9a-f]{4}")

    // MARK: Entry points

    /// A name that came from another phone, ready to draw: the central reserved words in French
    /// and English, the fallbacks in the phone language.
    static func safe(_ raw: String?) -> String {
        remote(raw, unnamed: PaveCopy.text("pave.name.unnamed"), reserved: PaveCopy.text("pave.name.reserved"),
               reservedWords: PaveReservedWords.all)
    }

    /// The name to draw, `unnamed` when nothing safe is left, or `reserved` when it reads as one of
    /// `reservedWords` (see `PaveReservedWords`) or as a key fingerprint.
    static func remote<Words: Collection>(_ raw: String?, unnamed: String, reserved: String,
                                          reservedWords: Words) -> String where Words.Element == String {
        guard let name = clean(raw) else { return unnamed }
        let elided = elideMiddle(name)
        return readsAsReserved(name, elided: elided, reservedWords: reservedWords) ? reserved : elided
    }

    // MARK: Rules 1 to 4

    /// Rules 1 to 4; nil when the name must show as unnamed.
    private static func clean(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let clamped = String(String.UnicodeScalarView(raw.unicodeScalars.prefix(maximumRawScalars)))
        let scalars = Array(clamped.precomposedStringWithCompatibilityMapping.unicodeScalars)
        let hidden = scalars.indices.map { isInvisible(scalars[$0]) && !isKeptEmojiJoiner(scalars, $0) }
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, hidden[start] || isSpace(scalars[start]) { start += 1 }
        while end > start, hidden[end - 1] || isSpace(scalars[end - 1]) { end -= 1 }
        var out = String.UnicodeScalarView()
        var marks = 0
        for index in start..<end {
            let scalar = scalars[index]
            if hidden[index] { return nil }
            if isInvisible(scalar) {
                // A kept emoji joiner or selector: neither a mark nor a reset of the mark count.
                out.append(scalar)
                continue
            }
            if isMark(scalar) {
                guard let last = out.last, last != " " else { continue }
                marks += 1
                if marks > maximumCombiningMarks { continue }
            } else {
                marks = 0
            }
            if isSpace(scalar) {
                if let last = out.last, last != " " { out.append(" ") }
            } else {
                out.append(scalar)
            }
        }
        let cleaned = String(out).trimmingCharacters(in: .whitespaces)
        guard cleaned.unicodeScalars.contains(where: isVisible), !hasRefusedScripts(cleaned) else { return nil }
        return cleaned
    }

    /// Assigned code points that still draw nothing: Hangul fillers, Braille blank, Khmer inherent
    /// vowels, Mongolian variation selectors and vowel separator, variation selectors.
    private static func isBlankGlyph(_ value: UInt32) -> Bool {
        value == 0x115F || value == 0x1160 || value == 0x3164 || value == 0xFFA0 || value == 0x2800 ||
            value == 0x17B4 || value == 0x17B5 || (0x180B...0x180E).contains(value) ||
            (0xFE00...0xFE0F).contains(value)
    }

    /// Unicode Default_Ignorable_Code_Point (DerivedCoreProperties), as on Android: never drawn,
    /// never a mark. Swift exposes no such property, hence the list.
    private static let defaultIgnorable: [ClosedRange<UInt32>] = [
        0x00AD...0x00AD, 0x034F...0x034F, 0x061C...0x061C, 0x115F...0x1160, 0x17B4...0x17B5,
        0x180B...0x180F, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F, 0x3164...0x3164,
        0xFE00...0xFE0F, 0xFEFF...0xFEFF, 0xFFA0...0xFFA0, 0xFFF0...0xFFF8, 0x1BCA0...0x1BCA3,
        0x1D173...0x1D17A, 0xE0000...0xE0FFF
    ]

    static func isDefaultIgnorable(_ scalar: Unicode.Scalar) -> Bool {
        defaultIgnorable.contains { $0.contains(scalar.value) }
    }

    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        if isBlankGlyph(scalar.value) || isDefaultIgnorable(scalar) { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned: return true
        default: return false
        }
    }

    private static func isSymbol(_ scalar: Unicode.Scalar?) -> Bool {
        scalar?.properties.generalCategory == .otherSymbol
    }

    /// A presentation selector or a skin tone (U+1F3FB–U+1F3FF), allowed between a symbol and its joiner.
    private static func isEmojiModifier(_ scalar: Unicode.Scalar?) -> Bool {
        guard let value = scalar?.value else { return false }
        return value == textPresentation || value == emojiPresentation || (0x1F3FB...0x1F3FF).contains(value)
    }

    private static func isKeycapBase(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        return ("0"..."9").contains(scalar) || scalar == "#" || scalar == "*"
    }

    /// The only invisible code points kept, so "❤️", "👩‍💻" and "1️⃣" survive: a presentation selector
    /// once, right after a symbol (So) or after 0-9, # or * followed by the keycap mark; a zero-width
    /// joiner between two symbols, the first one possibly with its selector or skin tone. A doubled,
    /// leading or trailing joiner or selector stays invisible.
    private static func isKeptEmojiJoiner(_ scalars: [Unicode.Scalar], _ index: Int) -> Bool {
        func at(_ offset: Int) -> Unicode.Scalar? {
            scalars.indices.contains(index + offset) ? scalars[index + offset] : nil
        }
        switch scalars[index].value {
        case textPresentation, emojiPresentation:
            return isSymbol(at(-1)) || (isKeycapBase(at(-1)) && at(1)?.value == combiningKeycap)
        case zeroWidthJoiner:
            return isSymbol(at(1)) && (isSymbol(at(-1)) || (isEmojiModifier(at(-1)) && isSymbol(at(-2))))
        default:
            return false
        }
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
        default: return scalar.properties.isWhitespace
        }
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// A letter, number, symbol or punctuation mark: something that draws.
    private static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
             .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    /// Rule 4: whether the scripts of the letters of `text` make it unnamed.
    static func hasRefusedScripts(_ text: String, classifier: PaveScriptClassifier = .current) -> Bool {
        let letters = String(String.UnicodeScalarView(text.unicodeScalars.filter(isLetter)))
        guard !letters.isEmpty else { return false }
        if classifier.hasUnknownLetter(letters) { return true }
        if alwaysUnnamed.contains(where: { classifier.contains($0, in: letters) }) { return true }
        if neverMixTogether.filter({ classifier.contains($0, in: letters) }).count > 1 { return true }
        return classifier.contains("Latin", in: letters) && classifier.hasLetterLatinMayNotMixWith(letters)
    }

    // MARK: Rule 5

    /// At most `maximumGraphemes` graphemes, ellipsis included. A long name keeps its start and its
    /// end ("Nora la vraie qu…ongtemps ou pas"), so a suffix cannot hide behind a trusted prefix.
    static func elideMiddle(_ text: String) -> String {
        // Walk forward only until the name is known to be too long.
        guard let limit = text.index(text.startIndex, offsetBy: maximumGraphemes, limitedBy: text.endIndex),
              limit != text.endIndex else { return text }
        let tail = (maximumGraphemes - 1) / 2
        let head = maximumGraphemes - 1 - tail
        let headEnd = text.index(text.startIndex, offsetBy: head)
        let tailStart = text.index(text.endIndex, offsetBy: -tail)
        var start = text[..<headEnd]
        while start.last == " " { start.removeLast() }
        return String(start) + ellipsis + String(text[tailStart...].drop(while: { $0 == " " }))
    }

    // MARK: Rule 6

    private static func readsAsReserved<Words: Collection>(_ name: String, elided: String,
                                                           reservedWords: Words) -> Bool where Words.Element == String {
        var whole = Set<String>()
        var affixes = Set<String>()
        for word in reservedWords {
            let skeleton = skeletonWords(word).joined()
            guard !skeleton.isEmpty else { continue }
            whole.insert(skeleton)
            if skeleton.unicodeScalars.count >= minimumAffixLetters { affixes.insert(skeleton) }
        }
        let reversedAffixes = Set(affixes.map { String(String.UnicodeScalarView($0.unicodeScalars.reversed())) })
        let longest = affixes.map(\.unicodeScalars.count).max() ?? 0
        return Set([name, elided]).contains { candidate in
            let words = skeletonWords(candidate)
            return whole.contains(words.joined())
                || joinsIntoAffix(words, affixes: affixes, longest: longest)
                || joinsIntoAffix(words.reversed().map { String(String.UnicodeScalarView($0.unicodeScalars.reversed())) },
                                  affixes: reversedAffixes, longest: longest)
                || imitatesFingerprint(candidate)
        }
    }

    /// Whether whole leading `words` join into one of `affixes`; trailing words are passed
    /// reversed, against reversed affixes, so each step only appends. Stops once the joined text is
    /// longer than the `longest` affix.
    private static func joinsIntoAffix(_ words: [String], affixes: Set<String>, longest: Int) -> Bool {
        var joined = String.UnicodeScalarView()
        var length = 0
        for word in words {
            joined.append(contentsOf: word.unicodeScalars)
            length += word.unicodeScalars.count
            if length > longest { return false }
            if affixes.contains(String(joined)) { return true }
        }
        return false
    }

    /// A name like "A1B2 C3D4" would pass for the short key fingerprint. Matched on the lowercase
    /// skeleton without `afterLowercase`, after `fingerprintCanonical` ("OB5E 44D8" is 0b5e 44d8),
    /// before counting digits.
    private static func imitatesFingerprint(_ text: String) -> Bool {
        let skeleton = skeletonWords(text, afterLowercase: false).joined(separator: " ")
        let canonical = String(String.UnicodeScalarView(skeleton.unicodeScalars.map { fingerprintCanonical[$0] ?? $0 }))
        let range = NSRange(canonical.startIndex..., in: canonical)
        return fingerprintLike?.firstMatch(in: canonical, range: range) != nil
    }

    /// Words of `text` as skeletons: NFKD, `confusables`, lowercase, `afterLowercase` unless
    /// `afterLowercase` is false, marks dropped, letters and digits only. Anything that is not a
    /// letter, digit or mark separates words: "V.ó-us" is v, o, us.
    static func skeletonWords(_ text: String, afterLowercase: Bool = true) -> [String] {
        var words: [String] = []
        var word = String.UnicodeScalarView()
        for scalar in text.decomposedStringWithCompatibilityMapping.unicodeScalars {
            for folded in fold(scalar, afterLowercase: afterLowercase) {
                if isLetter(folded) || folded.properties.generalCategory == .decimalNumber {
                    word.append(folded)
                } else if isMark(folded) {
                    continue
                } else if !word.isEmpty {
                    words.append(String(word))
                    word = String.UnicodeScalarView()
                }
            }
        }
        if !word.isEmpty { words.append(String(word)) }
        return words
    }

    private static func fold(_ scalar: Unicode.Scalar, afterLowercase applyAfter: Bool) -> [Unicode.Scalar] {
        let lower = (confusables[scalar] ?? scalar).properties.lowercaseMapping.unicodeScalars
        guard applyAfter else { return Array(lower) }
        return lower.map { afterLowercase[$0] ?? $0 }
    }
}

/// Places letters in Unicode scripts with ICU `\p{Script=…}` classes, Swift having no script
/// property. A script name the system's ICU cannot compile is left out, so its letters count as
/// unknown and are refused: conservative, like Android's UNKNOWN script.
struct PaveScriptClassifier {
    static let current = PaveScriptClassifier(known: PaveDisplayName.unicodeScripts)

    private let classes: [String: NSRegularExpression]
    /// A letter in none of the known scripts.
    private let unknownLetter: NSRegularExpression?
    /// A letter in a script Latin may not mix with.
    private let notLatinPartnerLetter: NSRegularExpression?

    init(known: [String]) {
        var classes: [String: NSRegularExpression] = [:]
        for name in known {
            classes[name] = try? NSRegularExpression(pattern: "\\p{Script=\(name)}")
        }
        self.classes = classes
        unknownLetter = Self.letter(outside: Array(classes.keys))
        let partners = ["Latin", "Common", "Inherited"] + PaveDisplayName.latinMayMixWith
        notLatinPartnerLetter = Self.letter(outside: partners.filter { classes[$0] != nil })
    }

    func knows(_ script: String) -> Bool { classes[script] != nil }

    /// Whether some letter of `letters` belongs to `script`.
    func contains(_ script: String, in letters: String) -> Bool {
        Self.matches(classes[script], letters)
    }

    /// Whether a letter belongs to none of the scripts this system knows.
    func hasUnknownLetter(_ letters: String) -> Bool {
        unknownLetter.map { Self.matches($0, letters) } ?? true
    }

    /// Whether a letter belongs to a script other than Latin, its partners, Common and Inherited.
    func hasLetterLatinMayNotMixWith(_ letters: String) -> Bool {
        notLatinPartnerLetter.map { Self.matches($0, letters) } ?? true
    }

    private static func letter(outside scripts: [String]) -> NSRegularExpression? {
        guard !scripts.isEmpty else { return nil }
        let excluded = scripts.sorted().map { "\\p{Script=\($0)}" }.joined()
        return try? NSRegularExpression(pattern: "[^\(excluded)]")
    }

    private static func matches(_ expression: NSRegularExpression?, _ text: String) -> Bool {
        expression?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
