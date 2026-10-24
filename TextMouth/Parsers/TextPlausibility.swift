import Foundation

// MARK: - Plausibility of a Reading

/// How much a text, one reading of a file's bytes, looks as if the bytes were
/// read in the wrong encoding (FMT16). `TextEncodingGuesser` reads the same
/// bytes in several encodings and compares what this finds in each: a
/// reading is better when fewer things in it are surprising.
///
/// Only the characters outside ASCII are judged, because they are the ones
/// an encoding decides: the ASCII characters read the same in every
/// encoding the guesser tries. Three kinds of surprise are counted:
/// - **Anomalies**, things real writing almost never holds: a control
///   character from the C1 range, a character no one assigned, a symbol
///   between two letters ("Za¹ó³æ"), an uppercase letter inside a lowercase
///   word ("CafÈ", the classic Mac Roman read as Windows-1252), a word that
///   mixes Latin letters with another script, a combining mark that does not
///   follow a letter of its own script, and symbols that text rarely holds
///   at all (box drawing, accents on their own).
/// - **Misfit letters**, the non-ASCII letters that fall outside the alphabet
///   of the one language they fit best. Real text is in one language, so a
///   reading with "õ" and "û" together ("főterén" read as Latin 1) fits no
///   language of the table, and one in which a language's every letter
///   belongs to it does.
/// - **Excess uppercase**, uppercase letters beyond about a third of the
///   cased ones. Text read in the wrong Cyrillic encoding swaps its lower
///   and upper case, which a language's alphabet cannot show.
///
/// The three counts add up to the reading's `surprise`, the number the
/// guesser compares.
struct TextPlausibility: Equatable, Sendable {

    /// The characters of the text outside ASCII.
    private(set) var nonASCIICharacters = 0
    /// The anomalies the text holds (see the type's description).
    private(set) var anomalies = 0
    /// The letters of the text outside ASCII.
    private(set) var nonASCIILetters = 0
    /// Non-ASCII letters outside the alphabet of the best-fitting language;
    /// for a text in a script with no alphabet table, the letters of any
    /// other script than the commonest.
    private(set) var misfitLetters = 0
    /// The non-ASCII cased letters that are uppercase.
    private(set) var uppercaseLetters = 0
    /// The non-ASCII cased letters that are lowercase.
    private(set) var lowercaseLetters = 0

    /// How many uppercase letters running text does not account for: those
    /// beyond a third of the cased non-ASCII letters, counted only once
    /// there are enough letters to tell.
    var excessUppercaseLetters: Int {
        let cased = uppercaseLetters + lowercaseLetters
        guard cased >= TextPlausibility.casedLettersNeeded else { return 0 }
        let allowed = Int((Double(cased) * TextPlausibility.uppercaseShareAllowed).rounded(.up))
        return max(0, uppercaseLetters - allowed)
    }

    /// How many surprising things the text holds: the count `TextEncodingGuesser`
    /// compares between readings of the same bytes.
    var surprise: Int { anomalies + misfitLetters + excessUppercaseLetters }

    /// Anomalies and excess uppercase: what a reading must be almost free of
    /// to be taken for the true one, whatever language it is in. (A text
    /// that mixes languages has misfit letters in the true reading too.)
    var disorder: Int { anomalies + excessUppercaseLetters }

    /// The fewest cased non-ASCII letters before uppercase is judged.
    private static let casedLettersNeeded = 8
    /// The share of the cased non-ASCII letters running text may have in
    /// uppercase: sentence capitals, names, and a few headings.
    private static let uppercaseShareAllowed = 0.35

    // MARK: Assessing

    /// Judge `text`.
    init(reading text: String) {
        let scalars = Array(text.unicodeScalars)
        let kinds = scalars.map(Kind.init)
        // Counts of each non-ASCII letter (lowercased) and of each script.
        var letterCounts: [Unicode.Scalar: Int] = [:]
        var scriptCounts: [Script: Int] = [:]

        /// Whether the scalar at `index` is a letter of any script.
        func isLetter(_ index: Int) -> Bool {
            scalars.indices.contains(index) && kinds[index] == .letter
        }
        /// Whether the scalar at `index` is a letter of a script whose words
        /// are separated by spaces, so that a symbol between two such
        /// letters stands inside a word.
        func isSpacedLetter(_ index: Int) -> Bool {
            isLetter(index) && Script(of: scalars[index]).separatesWordsWithSpaces
        }

        for index in scalars.indices {
            let scalar = scalars[index]
            let isASCII = scalar.isASCII
            if !isASCII { nonASCIICharacters += 1 }
            let previous = index > 0 ? scalars[index - 1] : nil

            switch kinds[index] {
            case .control:
                // The controls of the C1 range are never text. (ASCII
                // controls read alike in every encoding, so the guesser
                // judges them on the bytes, before it reads anything.)
                if !isASCII { anomalies += 1 }
            case .unusable:
                anomalies += 1
            case .letter:
                if !isASCII {
                    nonASCIILetters += 1
                    letterCounts[scalar.lowercasedForAlphabet, default: 0] += 1
                    scriptCounts[Script(of: scalar), default: 0] += 1
                    if scalar.properties.isUppercase {
                        uppercaseLetters += 1
                    } else if scalar.properties.isLowercase {
                        lowercaseLetters += 1
                    }
                }
                if let previous, kinds[index - 1] == .letter {
                    // An uppercase letter directly after a lowercase one, when
                    // either is not ASCII ("CafÈ"; plain "iPhone" is not odd).
                    if scalar.properties.isUppercase, previous.properties.isLowercase, !isASCII || !previous.isASCII {
                        anomalies += 1
                    }
                    // A word that mixes Latin with another script.
                    if Script.mixesLatinWithAnother(Script(of: previous), Script(of: scalar)) {
                        anomalies += 1
                    }
                }
                // A capital no Western language writes as a word of its own,
                // standing alone: Mac Roman's dashes and quotation marks
                // read as Windows-1252 ("Ñ", "Ò", "Ó").
                if TextPlausibility.lonelyCapitals.contains(scalar.value), !isLetter(index - 1), !isLetter(index + 1) {
                    anomalies += 1
                }
            case .mark:
                // A combining mark belongs after a letter (or another mark) of
                // the script it marks: Hebrew points after an ASCII letter
                // are not text. Marks of no particular script (the combining
                // accents) follow any letter.
                let markScript = Script(of: scalar)
                var followsItsScript = false
                if let previous, kinds[index - 1] == .letter || kinds[index - 1] == .mark {
                    followsItsScript = markScript == .other || kinds[index - 1] == .mark || Script(of: previous) == markScript
                }
                if !followsItsScript { anomalies += 1 }
            case .symbol, .number, .modifier, .punctuation:
                guard !isASCII else { break }
                if isSpacedLetter(index - 1) && isSpacedLetter(index + 1) {
                    // Between two letters only apostrophes, hyphens, dashes,
                    // quotation marks and the like are ordinary.
                    if !TextPlausibility.ordinaryBetweenLetters.contains(scalar.value) { anomalies += 1 }
                } else if kinds[index] == .symbol && !TextPlausibility.ordinarySymbols.contains(scalar.value) {
                    // A symbol text rarely holds at all, wherever it stands.
                    anomalies += 1
                }
            case .other:
                break
            }
        }
        misfitLetters = TextPlausibility.misfit(of: letterCounts, scripts: scriptCounts)
    }

    // MARK: Fit to a Language

    /// How many of the non-ASCII letters, counted in `letterCounts`, fall
    /// outside the alphabet of the language they fit best. A text whose
    /// commonest script has no alphabets in the table (Hebrew, Arabic, Thai,
    /// Japanese, Chinese, Korean) counts the letters of any other script.
    private static func misfit(of letterCounts: [Unicode.Scalar: Int], scripts: [Script: Int]) -> Int {
        let total = letterCounts.values.reduce(0, +)
        guard total > 0, let dominant = scripts.max(by: { $0.value < $1.value })?.key else { return 0 }
        guard dominant.hasAlphabets else { return total - scripts[dominant, default: 0] }
        var fewestOutside = total
        for alphabet in alphabets {
            let inside = letterCounts.reduce(0) { sum, entry in
                alphabet.letters.contains(entry.key) ? sum + entry.value : sum
            }
            fewestOutside = min(fewestOutside, total - inside)
        }
        return fewestOutside
    }

    /// The letters, beyond ASCII and in lowercase, that a language writes:
    /// every language whose text a legacy encoding is likely to hold. A
    /// language missing from the table only means a text in it counts all
    /// its letters as misfits in every reading, which cannot make a wrong
    /// reading win over the default.
    private struct Alphabet: Sendable {
        let language: String
        let letters: Set<Unicode.Scalar>

        init(_ language: String, _ letters: String) {
            self.language = language
            self.letters = Set(letters.unicodeScalars)
        }
    }

    /// The alphabets, Western and Central European languages first, then
    /// Cyrillic, then Greek.
    private static let alphabets: [Alphabet] = [
        Alphabet("French", "àâæçéèêëîïôœùûüÿ"),
        Alphabet("German", "äöüß"),
        Alphabet("Spanish", "áéíóúüñ"),
        Alphabet("Portuguese", "àáâãçéêíóôõúü"),
        Alphabet("Italian", "àèéìíîòóùú"),
        Alphabet("Dutch", "áäçéèêëíïóôöúü"),
        Alphabet("Swedish", "åäöéü"),
        Alphabet("Danish and Norwegian", "æøåéèêóòôü"),
        Alphabet("Finnish", "äöåšžé"),
        Alphabet("Icelandic", "áðéíóúýþæö"),
        Alphabet("Catalan", "àçéèíïóòúü·"),
        Alphabet("Irish", "áéíóú"),
        Alphabet("Polish", "ąćęłńóśźż"),
        Alphabet("Czech", "áčďéěíňóřšťúůýž"),
        Alphabet("Slovak", "áäčďéíĺľňóôŕšťúýž"),
        Alphabet("Hungarian", "áéíóöőúüű"),
        Alphabet("Croatian and Slovenian", "čćđšž"),
        Alphabet("Romanian", "ăâîșțşţ"),
        Alphabet("Albanian", "çë"),
        Alphabet("Turkish", "çğıöşüâîû\u{130}"),
        Alphabet("Lithuanian", "ąčęėįšųūž"),
        Alphabet("Latvian", "āčēģīķļņšūž"),
        Alphabet("Estonian", "äöõüšž"),
        Alphabet("Russian", "абвгдежзийклмнопрстуфхцчшщъыьэюяё"),
        Alphabet("Ukrainian", "абвгдежзийклмнопрстуфхцчшщьюяіїєґ"),
        Alphabet("Belarusian", "абвгдежзійклмнопрстуўфхцчшыьэюяё"),
        Alphabet("Bulgarian", "абвгдежзийклмнопрстуфхцчшщъьюя"),
        Alphabet("Serbian", "абвгдђежзијклљмнњопрстћуфхцчџш"),
        Alphabet("Macedonian", "абвгдѓежзѕијклљмнњопрстќуфхцчџш"),
        Alphabet("Greek", "αβγδεζηθικλμνξοπρσςτυφχψωάέήίόύώϊϋΐΰ"),
    ]

    // MARK: Ordinary Characters

    /// What may stand between two letters without surprise: apostrophes (the
    /// acute accent typed as one included), hyphens and dashes, quotation
    /// marks, the soft hyphen, the ellipsis, and the Catalan middle dot.
    private static let ordinaryBetweenLetters: Set<UInt32> = [
        0x00AB, 0x00AD, 0x00B4, 0x00B7, 0x00BB, 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2018, 0x2019,
        0x201C, 0x201D, 0x201E, 0x2026, 0x2039, 0x203A,
    ]

    /// The symbols running text holds without a reason to doubt it: the cent,
    /// pound, and yen signs, the copyright and registered signs, the degree,
    /// plus-minus, the acute accent, the multiplication and division signs,
    /// the euro and trademark signs, and two arrows.
    private static let ordinarySymbols: Set<UInt32> = [
        0x00A2, 0x00A3, 0x00A5, 0x00A9, 0x00AE, 0x00B0, 0x00B1, 0x00B4, 0x00D7, 0x00F7, 0x20AC, 0x2122, 0x2190, 0x2192,
    ]

    /// Capital letters no Western language writes as a word of its own,
    /// unlike "À" and "É": Ç Ê Ë Ì Î Ï Ð Ñ Ò Ô Õ Ù Û Ý Þ.
    private static let lonelyCapitals: Set<UInt32> = [
        0x00C7, 0x00CA, 0x00CB, 0x00CC, 0x00CE, 0x00CF, 0x00D0, 0x00D1, 0x00D2, 0x00D4, 0x00D5, 0x00D9, 0x00DB, 0x00DD, 0x00DE,
    ]

    // MARK: Kinds of Characters

    /// What a character is, for the judging above.
    private enum Kind {
        case letter, mark, number, punctuation, symbol, modifier
        /// A control character other than white space.
        case control
        /// A character with no use in text: unassigned, private use, or half
        /// of a surrogate pair.
        case unusable
        /// White space, digits, and format characters: judged by nothing.
        case other

        init(_ scalar: Unicode.Scalar) {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter: self = .letter
            case .modifierLetter: self = .modifier
            case .nonspacingMark, .spacingMark, .enclosingMark: self = .mark
            case .letterNumber, .otherNumber: self = .number
            case .control:
                // Tab, line feed, vertical tab, form feed, and carriage return are white space.
                self = (0x09...0x0D).contains(scalar.value) ? .other : .control
            case .surrogate, .privateUse, .unassigned: self = .unusable
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
                 .finalPunctuation, .otherPunctuation: self = .punctuation
            case .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: self = .symbol
            case .decimalNumber, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator: self = .other
            @unknown default: self = .unusable
            }
        }
    }

    // MARK: Scripts

    /// The writing system of a letter, as far as the judging needs it.
    private enum Script: Hashable, Sendable {
        case latin, cyrillic, greek, hebrew, arabic, thai
        /// Han, kana, Hangul, and the full-width forms CJK text uses.
        case cjk
        /// Every other script, and characters that belong to none.
        case other

        init(of scalar: Unicode.Scalar) {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x2FF, 0x1E00...0x1EFF: self = .latin
            case 0x370...0x3FF, 0x1F00...0x1FFF: self = .greek
            case 0x400...0x52F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F: self = .cyrillic
            case 0x590...0x5FF: self = .hebrew
            case 0x600...0x6FF, 0x750...0x77F: self = .arabic
            case 0xE00...0xE7F: self = .thai
            case 0x1100...0x11FF, 0x3000...0x30FF, 0x3100...0x318F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF,
                 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
                self = .cjk
            default: self = .other
            }
        }

        /// Whether the script puts spaces between its words, so that a symbol
        /// between two of its letters is odd (Thai and CJK text has none).
        var separatesWordsWithSpaces: Bool {
            switch self {
            case .latin, .cyrillic, .greek, .hebrew, .arabic: return true
            case .thai, .cjk, .other: return false
            }
        }

        /// Whether the table of alphabets has languages in the script.
        var hasAlphabets: Bool {
            switch self {
            case .latin, .cyrillic, .greek: return true
            case .hebrew, .arabic, .thai, .cjk, .other: return false
            }
        }

        /// Whether letters of the two scripts side by side mix Latin with
        /// another script that is known.
        static func mixesLatinWithAnother(_ first: Script, _ second: Script) -> Bool {
            first != second && first != .other && second != .other && (first == .latin || second == .latin)
        }
    }
}

// MARK: - Letters for Alphabets

private extension Unicode.Scalar {
    /// The scalar a letter counts as in the table of alphabets: its lowercase
    /// form when that is one scalar, and itself otherwise (the Turkish dotted
    /// capital I lowercases to two).
    var lowercasedForAlphabet: Unicode.Scalar {
        let lowered = properties.lowercaseMapping.unicodeScalars
        guard lowered.count == 1, let single = lowered.first else { return self }
        return single
    }
}
