import XCTest
@testable import TextMouth

/// What the encoding guesser finds surprising in a reading of a file's
/// bytes (FMT16): each kind of anomaly alone, the ordinary writing that must
/// not count as one, the fit of the letters to a language, and the case of
/// the letters.
final class TextPlausibilityTests: XCTestCase {

    private typealias Fixtures = TextEncodingFixtures

    /// The plausibility of `text`, as a rival reading unless it is said to be the Windows-1252 one.
    private func plausibility(of text: String, as judging: TextPlausibility.Judging = .rival) -> TextPlausibility {
        TextPlausibility(reading: text, judging: judging)
    }

    // MARK: - Writing That Is Not Surprising

    /// Ordinary writing in many scripts has no surprise: accented letters,
    /// apostrophes and quotation marks of every kind (the acute accent typed
    /// as an apostrophe too), dashes, the Catalan middle dot, currency and
    /// legal symbols, an accent combined with its letter, Cyrillic, Greek,
    /// Hebrew with its points, Japanese, Korean, and Thai.
    func testOrdinaryWritingHasNoSurprise() {
        let texts = [
            "Café au lait", "naïve", "Zürich", "don’t", "don´t", "col·legi", "A — B", "word—word", "«bonjour»", "„Guten Tag“",
            "Windows® and Office™ ©2024 £5 €5 ¥5 ¢5 25° ±2 3×4 6÷2", "e\u{0301}", "Привет, мир", "Καλημέρα κόσμε",
            "שָׁלוֹם עולם", "日本語のテキスト、これは文章です。", "안녕하세요", "สวัสดีครับ", "À la maison", "É un libro", "¿Qué?", "¡Olé!",
        ]
        for text in texts {
            let result = plausibility(of: text)
            XCTAssertEqual(result.anomalies, 0, text)
            XCTAssertEqual(result.surprise, 0, text)
        }
    }

    /// Letters and symbols in ASCII are never judged: they read alike in
    /// every encoding.
    func testASCIIIsNeverJudged() {
        let result = plausibility(of: "Hello, World! iPhone eBay JavaScript #1 @home 50% [done] ~tilde~ `tick`")
        XCTAssertEqual(result.nonASCIICharacters, 0)
        XCTAssertEqual(result.surprise, 0)
    }

    // MARK: - Anomalies

    /// An uppercase letter inside a lowercase word is an anomaly when either
    /// letter is not ASCII: Mac Roman's "é" read as Windows-1252's "Ž" ("CafŽ")
    /// and the apostrophe read as "Õ" ("donÕt"). A capital that starts a word
    /// or follows another capital is not.
    func testAnUppercaseLetterInsideALowercaseWordIsAnAnomaly() {
        XCTAssertEqual(plausibility(of: "CafŽ").anomalies, 1)
        XCTAssertEqual(plausibility(of: "donÕt").anomalies, 1)
        XCTAssertEqual(plausibility(of: "HomeïAbout").anomalies, 1)
        XCTAssertEqual(plausibility(of: "ZÜRICH ÉCOLE Éric").anomalies, 0)
    }

    /// A symbol, a number, or a mark of punctuation between two letters is an
    /// anomaly (Windows-1250's "ąłż" read as Windows-1252's "¹³¿"), unless it
    /// is an apostrophe, a hyphen, a dash, or a quotation mark.
    func testASymbolBetweenTwoLettersIsAnAnomaly() {
        XCTAssertEqual(plausibility(of: "Za¹ó³æ").anomalies, 2)
        XCTAssertEqual(plausibility(of: "na•ve").anomalies, 1)
        XCTAssertEqual(plausibility(of: "a†b").anomalies, 1)
        XCTAssertEqual(plausibility(of: "l’homme l·l a‑b").anomalies, 0)
    }

    /// A symbol text rarely holds is an anomaly wherever it stands (a run of
    /// box drawing, mathematical symbols), while currency, legal marks, and
    /// the like are not.
    func testASymbolTextRarelyHoldsIsAnAnomalyWhereverItStands() {
        XCTAssertEqual(plausibility(of: "┌──────┐").anomalies, 8)
        XCTAssertEqual(plausibility(of: "a ∞ b ≠ c").anomalies, 2)
        XCTAssertEqual(plausibility(of: "© ® ™ £ € ¥ ¢ ° ± × ÷").anomalies, 0)
    }

    /// Every symbol Windows-1252 has is ordinary wherever it stands in its
    /// own reading, since Western text uses them as it pleases ("File ¦ Edit",
    /// "Assume ¬p", "3,50 ¤"): the broken bar, the not sign, the currency
    /// sign, and the accents that stand alone.
    func testTheSymbolsWindows1252HasAreOrdinaryInItsOwnReading() {
        for text in ["File ¦ Edit ¦ View ¦ Help", "Assume ¬p and ¬q", "a ¤ b", "a ¨ b ¸ c ¯ d ˜ e",
                     "© ® ™ £ € ¥ ¢ ° ± × ÷ ¤ ¦ ¨ ¬ ¯ ¸ ˜", "The trip is ˜5 km, ˜2 hours"] {
            XCTAssertEqual(plausibility(of: text, as: .windows1252).anomalies, 0, text)
        }
    }

    /// The accents that stand on their own may sit beside a letter in the
    /// Windows-1252 reading, in text typed without the letter or taken from a
    /// PDF: "Mu¨ller", "fac¸ade", "cafe´", "an˜o".
    func testAnAccentStandingBesideALetterIsOrdinaryInWindows1252() {
        for text in ["Mu¨ller", "fac¸ade", "cafe´", "an˜o", "a¯b", "caˆfe"] {
            XCTAssertEqual(plausibility(of: text, as: .windows1252).anomalies, 0, text)
        }
    }

    /// The florin sign and f-stop ("ƒ/1.8"), the micro sign ("5 µg", "100µF"),
    /// and the ordinal indicators ("1º", "Nº 5") are letters to Unicode but
    /// symbols to Western text: the Windows-1252 reading does not judge them
    /// as letters, so they are no misfit and no lowercase letter that an
    /// uppercase one may not follow.
    func testLettersWesternTextUsesAsSymbolsAreNotJudgedInWindows1252() {
        for text in ["ƒ/1.8 and ƒ 1,20", "5 µg, 10 µM, 100µF", "1º maggio, 2ª vez, Nº 5"] {
            let result = plausibility(of: text, as: .windows1252)
            XCTAssertEqual(result.surprise, 0, text)
            XCTAssertEqual(result.nonASCIILetters, 0, text)
            XCTAssertGreaterThan(result.nonASCIICharacters, 0, text)
        }
    }

    /// None of that leniency is given to a rival reading, where these
    /// characters are what decoding made of other bytes: Mac Roman reads the
    /// "Ü" of "zeigeÜbersicht" as "‹", an "Ä" as "ƒ", and a "ü" as "¸", and a
    /// rival with them looked as clean as the right reading once they were
    /// ordinary there too. A rival holds them as anomalies (and "ƒ", "µ",
    /// "ª", "º" as letters, which fit the alphabet of no language).
    func testAnythingWindows1252IsLenientAboutIsStrictInARival() {
        for text in ["Mu¨ller", "fac¸ade", "an˜o", "a¯b", "caˆfe", "zeige‹bersicht", "zeige›bersicht", "zeige«bersicht",
                     "zeige»bersicht", "haal…ducatie", "wort“wort", "wort”wort", "wort„wort", "enregistrer‘ter", "a ¤ b", "Assume ¬p"] {
            XCTAssertEqual(plausibility(of: text).anomalies, 1, text)
            XCTAssertEqual(plausibility(of: text, as: .windows1252).anomalies, 0, text)
        }
        XCTAssertEqual(plausibility(of: "File ¦ Edit ¦ View").anomalies, 2)
        for text in ["ƒ/1.8", "5 µg", "1º maggio"] {
            XCTAssertEqual(plausibility(of: text).nonASCIILetters, 1, text)
            XCTAssertEqual(plausibility(of: text, as: .windows1252).nonASCIILetters, 0, text)
        }
        // The florin sign fits the alphabet of no language.
        XCTAssertEqual(plausibility(of: "ƒ/1.8").misfitLetters, 1)
        // "µ" is lowercase in a rival too, so an uppercase letter after it is a flip.
        XCTAssertEqual(plausibility(of: "10 µM").caseFlips, 1)
        XCTAssertEqual(plausibility(of: "10 µM", as: .windows1252).caseFlips, 0)
        XCTAssertEqual(plausibility(of: "na hÉireann").caseFlips, 1)
        XCTAssertEqual(plausibility(of: "na hÉireann", as: .windows1252).caseFlips, 0)
    }

    /// German identifiers read as Mac Roman are not a clean reading: "Ü" is
    /// "‹", "Ä" is "ƒ", "ü" is "¸", "ö" is "ˆ", "ß" is "ﬂ". Judged as a
    /// rival, the reading holds four anomalies (the "‹" between "e" and "b",
    /// the "¸" of "prüft" and "Grüße", and the "ˆ" of "schöne"), against the
    /// two case flips the Windows-1252 reading holds, so it does not win.
    func testMacRomansReadingOfGermanIdentifiersIsNotClean() throws {
        let german = "zeigeÜbersicht prüft die Größe, speichereÄnderung, schöne Grüße"
        let bytes = try XCTUnwrap(german.data(using: .windowsCP1252))
        let macRoman = try XCTUnwrap(TextFileDecoder.decodedText(bytes, in: .macOSRoman))
        XCTAssertTrue(macRoman.contains("zeige‹bersicht"), macRoman)
        XCTAssertEqual(plausibility(of: macRoman).anomalies, 4)
        XCTAssertEqual(plausibility(of: german, as: .windows1252).caseFlips, 2)
    }

    /// What a rival may hold between two letters is what writing holds there
    /// in any reading: the apostrophe, hyphens and dashes, the soft hyphen,
    /// and the Catalan middle dot.
    func testARivalMayHoldAnApostropheADashAndAHyphenBetweenLetters() {
        for text in ["don’t", "l’homme", "word—word", "word–word", "a‑b", "col·legi", "don´t", "soft\u{00AD}hyphen"] {
            XCTAssertEqual(plausibility(of: text).anomalies, 0, text)
        }
    }

    /// A control character from the C1 range, a character nobody assigned, and
    /// one for private use are anomalies. (A control character in ASCII is
    /// judged on the bytes, before anything is read.)
    func testControlAndUnassignedCharactersAreAnomalies() {
        XCTAssertEqual(plausibility(of: "a\u{0081}b").anomalies, 1)
        XCTAssertEqual(plausibility(of: "a\u{008F}\u{009D}b").anomalies, 2)
        XCTAssertEqual(plausibility(of: "a\u{E000}b").anomalies, 1)
        XCTAssertEqual(plausibility(of: "a\u{0378}b").anomalies, 1)
        XCTAssertEqual(plausibility(of: "a\u{0001}b\tc\nd").anomalies, 0)
    }

    /// A word that mixes Latin letters with another script is an anomaly
    /// where the script changes: Windows-1251's "й" read after Latin "Caf".
    func testAWordMixingScriptsIsAnAnomaly() {
        XCTAssertEqual(plausibility(of: "Cafй").anomalies, 1)
        XCTAssertEqual(plausibility(of: "Caf й").anomalies, 0)
        XCTAssertEqual(plausibility(of: "αβγa").anomalies, 1)
    }

    /// A combining mark must follow a letter of its own script: Hebrew
    /// points after an ASCII letter are an anomaly, and after a Hebrew letter
    /// are not; an accent follows a letter of any script.
    func testACombiningMarkMustFollowALetterOfItsScript() {
        XCTAssertEqual(plausibility(of: "a\u{05B5}b").anomalies, 1)
        XCTAssertEqual(plausibility(of: "\u{05B5}").anomalies, 1)
        XCTAssertEqual(plausibility(of: "ש\u{05B5}").anomalies, 0)
        XCTAssertEqual(plausibility(of: "e\u{0301}ж\u{0301}").anomalies, 0)
        XCTAssertEqual(plausibility(of: "1\u{0301}").anomalies, 1)
    }

    /// A capital by itself is no anomaly, whatever it is: an initial ("Ñ.
    /// García"), a letter of the alphabet ("La letra Ñ"), an interjection
    /// ("Ô meu Deus!"), a letter named in a sentence ("Ç és una lletra").
    /// Mac Roman's dashes and quotation marks read as Windows-1252 look like
    /// these ("Ñ", "Ò", "Ó"), but so do those, and only text that holds
    /// more than one such oddity is shown to be wrong (see `isGarbled`).
    func testACapitalByItselfIsNoAnomaly() {
        for text in ["word Ñ word", "Ò", "Ñ. García", "La letra Ñ", "Ô meu Deus! Ç és una lletra.", "À demain, É tarde"] {
            XCTAssertEqual(plausibility(of: text).anomalies, 0, text)
            XCTAssertEqual(plausibility(of: text, as: .windows1252).anomalies, 0, text)
        }
    }

    /// Irish writes an accented capital after the consonant that prefixes a
    /// word ("na hÉireann", "i nÉirinn", "an tÓglach"): not a case flip when
    /// the consonant begins its word, and one when it does not ("ahÉ").
    func testAnIrishCapitalAfterAPrefixConsonantIsNoCaseFlipInWindows1252() {
        for text in ["na hÉireann", "i nÉirinn", "an tÉireannach", "na hÁrainn", "tÉ", "nÓ"] {
            XCTAssertEqual(plausibility(of: text, as: .windows1252).caseFlips, 0, text)
            XCTAssertEqual(plausibility(of: text, as: .windows1252).anomalies, 0, text)
        }
        XCTAssertEqual(plausibility(of: "ahÉ", as: .windows1252).caseFlips, 1)
        XCTAssertEqual(plausibility(of: "caféÉ", as: .windows1252).caseFlips, 1)
    }

    /// Case flips are counted among the anomalies, and so are the different
    /// characters the anomalies are of.
    func testCaseFlipsAndTheirCharactersAreCounted() {
        let flips = plausibility(of: "CafŽ donÕt HomeïAbout CafŽ")
        XCTAssertEqual(flips.caseFlips, 4)
        XCTAssertEqual(flips.anomalies, 4)
        XCTAssertEqual(flips.anomalyCharacters.count, 3, "Ž, Õ, and A")
    }

    // MARK: - Fit to a Language

    /// The non-ASCII letters of a text in one language belong to that
    /// language's alphabet; a mixture no language writes does not fit.
    func testLettersThatBelongToOneLanguageHaveNoMisfit() {
        XCTAssertEqual(plausibility(of: "ação, órgão, coração").misfitLetters, 0)
        XCTAssertEqual(plausibility(of: "főterén szűk").misfitLetters, 0)
        XCTAssertEqual(plausibility(of: "żółć gęślą").misfitLetters, 0)
        XCTAssertEqual(plausibility(of: "İstanbul'un çığlık").misfitLetters, 0)
        XCTAssertEqual(plausibility(of: "тест").misfitLetters, 0)
        // Hungarian's "ő" and "ű" read as Latin 1's "õ" and "û": no language has both.
        XCTAssertGreaterThan(plausibility(of: "fõterén szûk").misfitLetters, 0)
        // Czech and Polish letters in one text: only one of them can be the language.
        let mixed = plausibility(of: "příliš žluťoučký zażółć gęślą")
        XCTAssertGreaterThan(mixed.misfitLetters, 0)
    }

    /// A script with no alphabets in the table counts the letters of other
    /// scripts as misfits, and none otherwise.
    func testAScriptWithoutAlphabetsCountsLettersOfOtherScripts() {
        XCTAssertEqual(plausibility(of: "שלום עולם").misfitLetters, 0)
        XCTAssertEqual(plausibility(of: "日本語のテキスト").misfitLetters, 0)
        XCTAssertEqual(plausibility(of: "שלום עולם ж").misfitLetters, 1)
    }

    /// The script with the most letters decides how the letters are judged,
    /// and of scripts with as many the first in the fixed order does, never
    /// the one a dictionary happens to list first: a text with one Latin and
    /// one other letter was judged one way in some launches and the other in
    /// the rest. Dictionaries made with many capacities list the same keys
    /// in many orders, so every one must give the same script.
    func testTheDominantScriptOfATieDoesNotDependOnTheOrderOfADictionary() {
        typealias Script = TextPlausibility.Script
        XCTAssertNil(TextPlausibility.dominantScript(in: [:]))
        XCTAssertEqual(TextPlausibility.dominantScript(in: [.cjk: 4, .latin: 3]), .cjk)
        XCTAssertEqual(TextPlausibility.dominantScript(in: [.latin: 1, .cyrillic: 5, .other: 2]), .cyrillic)
        for capacity in 1...64 {
            var allTied = Dictionary<Script, Int>(minimumCapacity: capacity)
            for script in Script.allCases.reversed() { allTied[script] = 3 }
            XCTAssertEqual(TextPlausibility.dominantScript(in: allTied), .latin, "all tied, capacity \(capacity)")

            var someTied = Dictionary<Script, Int>(minimumCapacity: capacity)
            for script in [Script.other, .cjk, .thai, .hebrew] { someTied[script] = 2 }
            XCTAssertEqual(TextPlausibility.dominantScript(in: someTied), .hebrew, "some tied, capacity \(capacity)")
        }
    }

    // MARK: - Case

    /// Uppercase beyond 35 in 100 of the cased non-ASCII letters is excess,
    /// counted once there are enough letters to tell: Cyrillic text read in
    /// the wrong encoding has its cases swapped.
    func testUppercaseBeyondThirtyFivePercentOfTheLettersIsExcess() {
        let capitals = plausibility(of: "ПРИВЕТ МИР ПРИВЕТ МИР")
        XCTAssertEqual(capitals.uppercaseLetters, 18)
        // 35 in 100 of 18 letters is 6.3, which rounds up to 7, so 11 are beyond what text holds.
        XCTAssertEqual(capitals.excessUppercaseLetters, 11)
        let sentence = plausibility(of: "Привет, мир! Привет, мир, как дела у тебя сегодня?")
        XCTAssertEqual(sentence.excessUppercaseLetters, 0)
        // Too few letters to tell.
        XCTAssertEqual(plausibility(of: "ПРИВЕТ").excessUppercaseLetters, 0)
        // Uppercase in ASCII is not counted: only the letters an encoding decides.
        XCTAssertEqual(plausibility(of: "HELLO WORLD").excessUppercaseLetters, 0)
    }

    /// Excess uppercase is counted in the surprise of a rival only. In the
    /// Windows-1252 reading capitals beyond the usual share are headings in
    /// capitals, names, and identifiers such as "zeigeÜbersicht", and say
    /// nothing about the encoding; a Cyrillic text read in the wrong
    /// encoding has its cases swapped, which only a rival can show.
    func testExcessUppercaseCountsAgainstARivalOnly() {
        let capitals = "ПРИВЕТ МИР ПРИВЕТ МИР"
        XCTAssertEqual(plausibility(of: capitals).excessUppercaseLetters, 11)
        XCTAssertEqual(plausibility(of: capitals).surprise, 11)
        XCTAssertEqual(plausibility(of: capitals, as: .windows1252).excessUppercaseLetters, 11)
        XCTAssertEqual(plausibility(of: capitals, as: .windows1252).surprise, 0)
        // The disorder a rival must be nearly free of includes it either way.
        XCTAssertEqual(plausibility(of: capitals, as: .windows1252).disorder, 11)
    }

    // MARK: - Proof of a Wrong Reading

    /// The Windows-1252 reading of `text` as the bytes of a file in the
    /// encoding named `name`, and the reading in that encoding: the two
    /// readings a guesser compares.
    private func readings(of text: String, writtenIn name: String) throws -> (western: TextPlausibility, rival: TextPlausibility) {
        let (bytes, written) = try Fixtures.file(text, inEncodingNamed: name)
        return (plausibility(of: TextFileDecoder.windows1252Text(bytes), as: .windows1252), plausibility(of: written))
    }

    /// Whether the text, taken as a Windows-1252 reading, is shown wrong
    /// against a rival reading that is perfectly plausible.
    private func isGarbled(_ text: String) -> Bool {
        plausibility(of: text, as: .windows1252).isGarbled(comparedTo: plausibility(of: ""))
    }

    /// Three anomalies of at least two different characters show a wrong
    /// reading; one character repeated does not, however often, and neither
    /// do two anomalies. (Undefined bytes read as C1 controls are anomalies.)
    func testSeveralAnomaliesOfDifferentCharactersShowAWrongReading() {
        XCTAssertTrue(isGarbled("a\u{81}b\u{8D}c\u{81}"))
        XCTAssertTrue(isGarbled("a\u{81}b\u{8D}c\u{8F}"))
        XCTAssertFalse(isGarbled("a\u{81}b\u{81}c\u{81}"))
        XCTAssertFalse(isGarbled("a\u{81}b\u{81}c\u{81} d\u{81}e\u{81}f\u{81}"))
        XCTAssertFalse(isGarbled("a\u{81}b\u{8D}c"))
        XCTAssertFalse(isGarbled("test\u{9D} of the system’s files\u{9D} and they’re fine\u{9D}."))
    }

    /// Five case flips show a wrong reading, and four do not.
    func testFiveCaseFlipsShowAWrongReading() {
        XCTAssertTrue(isGarbled("CafŽ CafŽ CafŽ CafŽ CafŽ"))
        XCTAssertFalse(isGarbled("CafŽ CafŽ CafŽ CafŽ"))
        XCTAssertFalse(isGarbled("na hÉireann, i nÉirinn, an tÉireannach, na hÁrainn, an tÓglach, i nÓrdán"))
    }

    /// Text in the wrong encoding is shown wrong when the rival reads it
    /// right: Mac Roman English and French, Windows-1250 Czech, Latin 2
    /// Polish, the Cyrillic encodings, Greek, Hebrew, Thai, and the East
    /// Asian ones, each by something different (case flips, symbols inside
    /// words, letters that fit no language).
    func testTextInTheWrongEncodingIsShownWrongWhenTheRivalReadsItRight() throws {
        let cases: [(language: String, encoding: String)] = [
            ("English", "macintosh"), ("French", "macintosh"), ("German", "macintosh"), ("Czech", "windows-1250"),
            ("Polish", "iso-8859-2"), ("Russian", "windows-1251"), ("Russian", "koi8-r"), ("Russian", "cp866"),
            ("Ukrainian", "koi8-u"), ("Greek", "windows-1253"), ("Hebrew", "windows-1255"), ("Thai", "windows-874"),
            ("Japanese", "shift_jis"), ("Simplified Chinese", "gbk"), ("Korean", "euc-kr"),
        ]
        for (language, encoding) in cases {
            let (western, rival) = try readings(of: Fixtures.paragraph(in: language), writtenIn: encoding)
            XCTAssertTrue(western.isGarbled(comparedTo: rival), "\(language) in \(encoding)")
        }
    }

    /// Hungarian's "ő" and "ű" read as "õ" and "û", and Latin 9 French's
    /// "œ" and "€" read as "½" and "¤", are too little to show a wrong
    /// reading: a few letters off in text that otherwise reads well.
    func testAFewLettersOffAreNotEnoughToShowAWrongReading() throws {
        for (language, encoding) in [("Hungarian", "windows-1250"), ("Hungarian", "iso-8859-2"), ("French in Latin 9", "iso-8859-15")] {
            let (western, rival) = try readings(of: Fixtures.paragraph(in: language), writtenIn: encoding)
            XCTAssertFalse(western.isGarbled(comparedTo: rival), "\(language) in \(encoding)")
        }
    }

    /// Letters that fit no language show a wrong reading only when the rival
    /// reading's letters fit one: the same Czech text against a rival that
    /// is just as unfit is not shown wrong.
    func testLettersThatFitNoLanguageNeedARivalThatFitsOne() throws {
        let (western, rival) = try readings(of: Fixtures.paragraph(in: "Czech"), writtenIn: "windows-1250")
        XCTAssertTrue(western.isGarbled(comparedTo: rival))
        XCTAssertFalse(western.isGarbled(comparedTo: western))
    }

    /// The Windows-1252 texts built to look odd show nothing, whatever the
    /// rival reading is.
    func testWindows1252TextsBuiltToLookOddShowNothing() {
        for (name, text) in Fixtures.windows1252Texts {
            XCTAssertFalse(isGarbled(text), name)
        }
    }

    /// Identifiers with an accented capital after a lowercase word do show
    /// case flips, and three flips of two letters would be proof against a
    /// clean rival. What keeps such text is that its rival is not clean: Mac
    /// Roman, which reads these capitals as quotation marks and symbols
    /// ("zeige‹bersicht"), holds anomalies of its own, which judged as a
    /// rival it must not hold, while a rival that read Windows-1252's own
    /// characters as ordinary would have looked as clean as the right reading.
    func testIdentifiersShowCaseFlipsAndTheirMacRomanRivalIsNotClean() throws {
        for (name, text) in Fixtures.windows1252IdentifierTexts {
            let bytes = try XCTUnwrap(text.data(using: .windowsCP1252), name)
            let western = plausibility(of: TextFileDecoder.windows1252Text(bytes), as: .windows1252)
            XCTAssertGreaterThan(western.caseFlips, 0, name)
            let macRoman = try XCTUnwrap(TextFileDecoder.decodedText(bytes, in: .macOSRoman), name)
            XCTAssertGreaterThan(plausibility(of: macRoman).disorder, 0, "\(name): \(macRoman.prefix(40))")
        }
    }
}
