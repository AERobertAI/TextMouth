import XCTest
@testable import TextMouth

/// What the encoding guesser finds surprising in a reading of a file's
/// bytes (FMT16): each kind of anomaly alone, the ordinary writing that must
/// not count as one, the fit of the letters to a language, and the case of
/// the letters.
final class TextPlausibilityTests: XCTestCase {

    /// The plausibility of `text`.
    private func plausibility(of text: String) -> TextPlausibility {
        TextPlausibility(reading: text)
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
    /// box drawing, an accent on its own), while currency, legal marks, and
    /// the like are not.
    func testASymbolTextRarelyHoldsIsAnAnomalyWhereverItStands() {
        XCTAssertEqual(plausibility(of: "┌──────┐").anomalies, 8)
        XCTAssertEqual(plausibility(of: "a ¨ b ¸ c").anomalies, 2)
        XCTAssertEqual(plausibility(of: "© ® ™ £ € ¥ ¢ ° ± × ÷").anomalies, 0)
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

    /// A capital no Western language writes as a word of its own is an
    /// anomaly standing alone ("Ñ" is Mac Roman's em dash read as
    /// Windows-1252); "À" and "É" are words, and are not.
    func testACapitalNoLanguageWritesAloneIsAnAnomalyStandingAlone() {
        XCTAssertEqual(plausibility(of: "word Ñ word").anomalies, 1)
        XCTAssertEqual(plausibility(of: "word Ò").anomalies, 1)
        XCTAssertEqual(plausibility(of: "Ñandú").anomalies, 0)
        XCTAssertEqual(plausibility(of: "À demain, É tarde").anomalies, 0)
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

    // MARK: - Case

    /// Uppercase beyond a third of the cased non-ASCII letters is excess,
    /// counted once there are enough letters to tell: Cyrillic text read in
    /// the wrong encoding has its cases swapped.
    func testUppercaseBeyondAThirdOfTheLettersIsExcess() {
        let capitals = plausibility(of: "ПРИВЕТ МИР ПРИВЕТ МИР")
        XCTAssertEqual(capitals.uppercaseLetters, 18)
        // A third of 18 letters rounds up to 7, so 11 are beyond what text holds.
        XCTAssertEqual(capitals.excessUppercaseLetters, 11)
        let sentence = plausibility(of: "Привет, мир! Привет, мир, как дела у тебя сегодня?")
        XCTAssertEqual(sentence.excessUppercaseLetters, 0)
        // Too few letters to tell.
        XCTAssertEqual(plausibility(of: "ПРИВЕТ").excessUppercaseLetters, 0)
        // Uppercase in ASCII is not counted: only the letters an encoding decides.
        XCTAssertEqual(plausibility(of: "HELLO WORLD").excessUppercaseLetters, 0)
    }

    // MARK: - Totals

    /// The surprise adds the anomalies, the misfit letters, and the excess
    /// uppercase letters; the disorder leaves out the misfit.
    func testTheTotalsAddUpTheKinds() {
        let reading = plausibility(of: "CafŽ ПРИВЕТ МИР ПРИВЕТ МИР")
        XCTAssertEqual(reading.surprise, reading.anomalies + reading.misfitLetters + reading.excessUppercaseLetters)
        XCTAssertEqual(reading.disorder, reading.anomalies + reading.excessUppercaseLetters)
        XCTAssertGreaterThan(reading.surprise, reading.disorder)
        // One "Ž" and 18 Cyrillic capitals.
        XCTAssertEqual(reading.nonASCIICharacters, 19)
    }
}
