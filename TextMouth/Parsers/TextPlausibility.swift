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
///   at all (box drawing, mathematical symbols). The characters Windows-1252
///   itself has ("¦", "¬", "¤", accents that stand alone, "ƒ", "µ", a
///   capital "Ñ" by itself) are not anomalies anywhere: Western text uses
///   them as it pleases, so they say nothing about the encoding.
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
/// guesser compares. That a reading has more surprise than a rival does not
/// make it wrong, though: Western text is full of ordinary characters that
/// look odd one by one (see `isGarbled(comparedTo:)`, which asks for proof).
struct TextPlausibility: Equatable, Sendable {

    /// The characters of the text outside ASCII.
    private(set) var nonASCIICharacters = 0
    /// The anomalies the text holds (see the type's description).
    private(set) var anomalies = 0
    /// The different characters the anomalies are of.
    private(set) var anomalyCharacters: Set<Unicode.Scalar> = []
    /// The anomalies that are an uppercase letter inside a lowercase word.
    private(set) var caseFlips = 0
    /// The letters of the text in ASCII.
    private(set) var asciiLetters = 0
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

    /// The surprises as a share of the non-ASCII characters: how thick they
    /// lie. Zero for a text with none.
    var surpriseShare: Double { share(surprise, of: nonASCIICharacters) }

    /// The non-ASCII letters as a share of all the letters: how much of the
    /// writing an encoding decides. Zero for a text with no letters.
    var nonASCIILetterShare: Double { share(nonASCIILetters, of: nonASCIILetters + asciiLetters) }

    /// The misfit letters as a share of the non-ASCII letters.
    var misfitShare: Double { share(misfitLetters, of: nonASCIILetters) }

    /// `part` of `whole`, or zero when there is no whole.
    private func share(_ part: Int, of whole: Int) -> Double {
        whole > 0 ? Double(part) / Double(whole) : 0
    }

    // MARK: Proof of a Wrong Reading

    /// Whether this text, the Windows-1252 reading of a file's bytes, shows
    /// itself to be a wrong reading, so that a rival reading with fewer
    /// surprises (`rival`) may replace it.
    ///
    /// More surprises than a rival is not enough. Western text is made of
    /// ordinary Windows-1252 characters, each standing singly in a plausible
    /// place, and the oddest of them ("ƒ/1.8", "File ¦ Edit", "Mu¨ller",
    /// "Ñ. García", "na hÉireann") are what the writer typed. A rival that
    /// reads such a character as a quotation mark or a letter looks cleaner
    /// without being right, and a wrong guess turns text that was right into
    /// text that is wrong, which the book then keeps. A missed guess only
    /// leaves a text as garbled as it always was. So the default stays,
    /// unless the text itself holds one of three things that Western writing
    /// does not:
    /// - **Anomalies of different characters**: three or more, of at least
    ///   two different characters. Undefined bytes read as controls, symbols
    ///   inside words, and the like come from a wrong reading of many
    ///   different bytes; a writer's habit repeats one character, and an odd
    ///   character or two is the writer's.
    /// - **Case flips**: five or more uppercase letters inside lowercase
    ///   words. Mac Roman's apostrophes, dashes, and accented letters read
    ///   as Windows-1252 make "ItÕs" and "CafŽ" again and again.
    /// - **Letters that fit no language, where the rival's fit one**: a
    ///   fifth or more of the non-ASCII letters fall outside the alphabet of
    ///   every language of the table ("Pøíliš žlu\u{9D}ouèký kùò" is Czech
    ///   read as Western), at least ten of them when the non-ASCII letters
    ///   are 8 in 100 of all the letters or more, and at least six when they
    ///   are half or more (text in a script of its own, such as a few lines
    ///   of Chinese read as Western, has hardly a letter of ASCII); and the
    ///   rival's letters fall outside one by no more than 2 in 100. Western
    ///   text that is dense with accents is in one language, whose letters
    ///   fit it.
    ///
    /// The limits were set on thousands of texts: real prose in 30 languages
    /// in the encodings each is written in, cut to many lengths, against
    /// thousands of Windows-1252 texts built to look odd (loanwords, curly
    /// quotation marks, and every strange Windows-1252 character).
    func isGarbled(comparedTo rival: TextPlausibility) -> Bool {
        if anomalies >= TextPlausibility.garblingAnomalies, anomalyCharacters.count >= TextPlausibility.garblingAnomalyCharacters {
            return true
        }
        if caseFlips >= TextPlausibility.garblingCaseFlips { return true }
        // Enough letters outside every language for how dense the non-ASCII letters are.
        let misfitsAreEnough = TextPlausibility.misfitLettersNeeded.contains {
            nonASCIILetterShare >= $0.letterShare && misfitLetters >= $0.misfitLetters
        }
        return misfitsAreEnough
            && misfitShare >= TextPlausibility.misfitShareNeeded
            && rival.misfitShare <= TextPlausibility.rivalMisfitShareAllowed
    }

    /// The fewest anomalies, and of how many characters, that prove a text garbled.
    private static let garblingAnomalies = 3
    private static let garblingAnomalyCharacters = 2
    /// The fewest case flips that prove a text garbled.
    private static let garblingCaseFlips = 5
    /// The fewest misfit letters that show garbling by their fit, for each
    /// share of all the letters that the non-ASCII letters may be: the
    /// denser they are, the fewer misfits are needed.
    private static let misfitLettersNeeded: [(letterShare: Double, misfitLetters: Int)] = [
        (letterShare: 0.5, misfitLetters: 6),
        (letterShare: 0.08, misfitLetters: 10),
    ]
    /// The share of the non-ASCII letters the misfit letters must be.
    private static let misfitShareNeeded = 0.2
    /// The most misfit letters, as a share of the non-ASCII letters, the
    /// rival reading may have: its letters fit a language.
    private static let rivalMisfitShareAllowed = 0.02

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
        /// Counts `scalar` as an anomaly, and as one of its kind of character.
        func flag(_ scalar: Unicode.Scalar) {
            anomalies += 1
            anomalyCharacters.insert(scalar)
        }

        /// Whether the accented capital at `index` begins an Irish word after
        /// the consonant that prefixes it: "na hÉireann", "i nÉirinn", "an
        /// tÓglach". (The consonant itself must begin its word.)
        func startsIrishPrefixedWord(at index: Int) -> Bool {
            TextPlausibility.irishPrefixedCapitals.contains(scalars[index].value)
                && TextPlausibility.irishPrefixConsonants.contains(scalars[index - 1].value)
                && !isLetter(index - 2)
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
                if !isASCII { flag(scalar) }
            case .unusable:
                flag(scalar)
            case .letter:
                if isASCII {
                    asciiLetters += 1
                } else {
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
                    // either is not ASCII ("CafÈ"; plain "iPhone" is not odd),
                    // unless it is an Irish accented capital after the prefix
                    // consonant of a word ("na hÉireann").
                    if scalar.properties.isUppercase, previous.properties.isLowercase, !isASCII || !previous.isASCII,
                       !startsIrishPrefixedWord(at: index) {
                        flag(scalar)
                        caseFlips += 1
                    }
                    // A word that mixes Latin with another script.
                    if Script.mixesLatinWithAnother(Script(of: previous), Script(of: scalar)) {
                        flag(scalar)
                    }
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
                if !followsItsScript { flag(scalar) }
            case .symbol, .number, .modifier, .punctuation:
                guard !isASCII else { break }
                if isSpacedLetter(index - 1) && isSpacedLetter(index + 1) {
                    // Between two letters only apostrophes, hyphens, dashes,
                    // quotation marks and the like are ordinary.
                    if !TextPlausibility.ordinaryBetweenLetters.contains(scalar.value) { flag(scalar) }
                } else if kinds[index] == .symbol && !TextPlausibility.ordinarySymbols.contains(scalar.value) {
                    // A symbol text rarely holds at all, wherever it stands.
                    flag(scalar)
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
    /// language missing from the table (Faroese, Welsh, Maltese) means that a
    /// text in it counts some of its letters as misfits even in its right
    /// reading, which can make a wrong reading look better than the right
    /// one; `isGarbled(comparedTo:)` is what keeps that from deciding.
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
    /// marks, the soft hyphen, the ellipsis, the Catalan middle dot, and the
    /// accents that stand on their own beside a letter in text that was
    /// typed on a keyboard without the letter or taken from a PDF ("Mu¨ller",
    /// "an˜o").
    private static let ordinaryBetweenLetters: Set<UInt32> = [
        0x00A8, 0x00AB, 0x00AD, 0x00AF, 0x00B4, 0x00B7, 0x00B8, 0x00BB, 0x02C6, 0x02DC, 0x2010, 0x2011, 0x2012, 0x2013, 0x2014,
        0x2015, 0x2018, 0x2019, 0x201C, 0x201D, 0x201E, 0x2026, 0x2039, 0x203A,
    ]

    /// The symbols running text holds without a reason to doubt it: the
    /// currency signs (the cent, pound, yen, euro, and the general currency
    /// sign), the broken bar, the copyright and registered signs, the not
    /// sign, the degree, plus-minus, the multiplication and division signs,
    /// the trademark sign, two arrows, and the accents that stand on their
    /// own (the diaeresis, macron, acute, cedilla, and small tilde). All of
    /// them are Windows-1252 characters, which Western text uses as it
    /// pleases: nothing in a reading with them is unlike the text the writer
    /// meant.
    private static let ordinarySymbols: Set<UInt32> = [
        0x00A2, 0x00A3, 0x00A4, 0x00A5, 0x00A6, 0x00A8, 0x00A9, 0x00AC, 0x00AE, 0x00AF, 0x00B0, 0x00B1, 0x00B4, 0x00B8, 0x00D7,
        0x00F7, 0x02DC, 0x20AC, 0x2122, 0x2190, 0x2192,
    ]

    /// The letters Western text uses as symbols: the florin sign and f-stop
    /// ("ƒ/2.8"), the micro sign ("5 µg"), and the ordinal indicators ("1º",
    /// "2ª"). Unicode calls them letters, but nothing about them tells which
    /// encoding a text is in, so they are not judged as letters.
    private static let lettersUsedAsSymbols: Set<UInt32> = [0x00AA, 0x00B5, 0x00BA, 0x0192]

    /// The accented capitals Irish writes after the consonant that prefixes a
    /// word beginning with a vowel: "na hÉireann", "i nÉirinn", "an tÁrd".
    private static let irishPrefixedCapitals: Set<UInt32> = [0x00C1, 0x00C9, 0x00CD, 0x00D3, 0x00DA]
    /// Those consonants: h, n, and t.
    private static let irishPrefixConsonants: Set<UInt32> = [0x68, 0x6E, 0x74]

    // MARK: Kinds of Characters

    /// What a character is, for the judging above.
    private enum Kind {
        case letter, mark, number, punctuation, symbol, modifier
        /// A control character other than white space.
        case control
        /// A character with no use in text: unassigned, private use, or half
        /// of a surrogate pair.
        case unusable
        /// White space, digits, format characters, and the letters Western
        /// text uses as symbols: judged by nothing.
        case other

        init(_ scalar: Unicode.Scalar) {
            if TextPlausibility.lettersUsedAsSymbols.contains(scalar.value) {
                self = .other
                return
            }
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
