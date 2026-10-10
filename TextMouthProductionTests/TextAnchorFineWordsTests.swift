import XCTest
@testable import TextMouth

/// Fine words (T06): the words a saved place is found again by. A word is
/// a run of letters or digits, split at anything else, between letters and
/// digits, and where a small letter meets a capital, compared in lower
/// case, so text an older extraction ran together reads as the same words
/// as the text a newer one spaces out. Also the layout of a book's words
/// (`BookWords`): which chapter each stands in, and where. Pure: no window,
/// no file.
final class TextAnchorFineWordsTests: XCTestCase {

    // MARK: - Helpers

    /// The fine words of `text`, as the text each covers.
    private func fineWords(_ text: String) -> [String] {
        let units = text as NSString
        return FineWords.words(in: text).map { units.substring(with: NSRange(location: $0.start, length: $0.end - $0.start)) }
    }

    // MARK: - Where Words End

    /// A word ends at spaces and at punctuation, an apostrophe and a hyphen
    /// included, and a run of punctuation alone is no word.
    func testAWordEndsAtSpacesAndPunctuation() {
        XCTAssertEqual(fineWords("A Caucus-Race and a Long Tale."), ["A", "Caucus", "Race", "and", "a", "Long", "Tale"])
        XCTAssertEqual(fineWords("“Curiouser and curiouser!” cried Alice"), ["Curiouser", "and", "curiouser", "cried", "Alice"])
        XCTAssertEqual(fineWords("don’t"), ["don", "t"])
        XCTAssertEqual(fineWords("* * * — …"), [])
        XCTAssertEqual(fineWords(""), [])
    }

    /// Letters and digits are separate words, so "likely993-1003Falling",
    /// a table's cells run together, is four words.
    func testLettersAndDigitsAreSeparateWords() {
        XCTAssertEqual(fineWords("likely993-1003Falling"), ["likely", "993", "1003", "Falling"])
        XCTAssertEqual(fineWords("3.0.7"), ["3", "0", "7"])
        XCTAssertEqual(fineWords("page12b"), ["page", "12", "b"])
    }

    /// A capital after a small letter begins a word; capitals followed by
    /// small letters stay one word.
    func testACapitalAfterASmallLetterBeginsAWord() {
        XCTAssertEqual(fineWords("TearsCHAPTER III.A Caucus"), ["Tears", "CHAPTER", "III", "A", "Caucus"])
        XCTAssertEqual(fineWords("McAllister"), ["Mc", "Allister"])
        XCTAssertEqual(fineWords("CHAPTERS Chapter iPhone"), ["CHAPTERS", "Chapter", "i", "Phone"])
    }

    /// Beyond ASCII the rule reads Unicode's properties: any scalar with a
    /// numeric value is a digit (an Arabic-Indic digit, a Roman numeral, and
    /// a Chinese numeral such as 京, ten quadrillion, which so splits a word
    /// of Chinese text), a letter without case joins the letters around it,
    /// and an accent written as a combining mark ends the word, as any mark
    /// does.
    func testScalarsBeyondASCII() {
        XCTAssertEqual(fineWords("٣٤abc"), ["٣٤", "abc"])
        XCTAssertEqual(fineWords("Ⅻ chapters"), ["Ⅻ", "chapters"])
        XCTAssertEqual(fineWords("ひらがな"), ["ひらがな"])
        XCTAssertEqual(fineWords("東京"), ["東", "京"])
        XCTAssertEqual(fineWords("café cafe\u{301}"), ["café", "cafe"])
    }

    /// Words compare in lower case, beyond ASCII too; different words have
    /// different keys.
    func testWordsCompareInLowerCase() {
        let chapter = FineWords.keys(in: "chapter")
        XCTAssertEqual(chapter.count, 1)
        XCTAssertEqual(FineWords.keys(in: "CHAPTER Chapter chapter"), chapter + chapter + chapter)
        XCTAssertEqual(FineWords.keys(in: "ÉTÉ Σοφία"), FineWords.keys(in: "été σοφία"))
        XCTAssertNotEqual(FineWords.keys(in: "chapter"), FineWords.keys(in: "chapters"))
        XCTAssertNotEqual(FineWords.keys(in: "ab"), FineWords.keys(in: "ba"))
    }

    /// Text an older extraction ran together reads as the same words as
    /// the text a newer one spaces out: alice.docx's contents list and
    /// test_book.docx's table, as 3.0.4 and 3.0.7 read them.
    func testTextRunTogetherReadsAsTheSameWordsAsTheTextSpacedOut() {
        XCTAssertEqual(
            FineWords.keys(in: "CHAPTER I.Down the Rabbit-HoleCHAPTER II.The Pool of TearsCHAPTER III.A Caucus-Race"),
            FineWords.keys(in: "CHAPTER I. Down the Rabbit-Hole\n\nCHAPTER II. The Pool of Tears\n\nCHAPTER III. A Caucus-Race")
        )
        XCTAssertEqual(
            FineWords.keys(in: "Reading (hPa)TrendExpected Conditions1013-1023SteadyFair weather, light winds"),
            FineWords.keys(in: "Reading (hPa) Trend Expected Conditions\n\n1013-1023 Steady Fair weather, light winds")
        )
    }

    /// A word's place counts UTF-16 units, as reading positions do: an
    /// emoji is two, and CR LF is two spaces.
    func testOffsetsCountUTF16Units() {
        let text = "go 😀 now\r\nend"
        let words = FineWords.words(in: text)
        XCTAssertEqual(fineWords(text), ["go", "now", "end"])
        XCTAssertEqual(words.map(\.start), [0, 6, 11])
        XCTAssertEqual(words.last?.end, text.utf16.count)
        XCTAssertEqual(FineWords.forEachWord(in: text) { _, _, _ in }, text.utf16.count, "it returns the text's length")
    }

    /// White space is Unicode's White_Space, by UTF-16 unit.
    func testWhiteSpaceIsUnicodesWhiteSpace() {
        for space in ["\t", "\n", "\r", " ", "\u{A0}", "\u{2003}", "\u{3000}"] {
            XCTAssertTrue(space.utf16.allSatisfy(FineWords.isSpace), "\(space.unicodeScalars.map(\.value))")
        }
        for other in ["a", "-", "\u{200B}", "\u{2019}"] {
            XCTAssertFalse(other.utf16.allSatisfy(FineWords.isSpace), "\(other.unicodeScalars.map(\.value))")
        }
    }

    // MARK: - A Book's Words

    /// A book's words stand in reading order through its chapters; an empty
    /// chapter holds none, and each word's chapter and place are known.
    func testABooksWordsAndWhereTheyStand() {
        let words = BookWords(texts: ["Alpha beta.", "", "Gamma delta"])
        XCTAssertEqual(words.count, 4)
        XCTAssertEqual(words.chapterCount, 3)
        XCTAssertEqual(words.chapterFirstWords, [0, 2, 2, 4])
        XCTAssertEqual(words.chapterStarts, [0, 11, 11, 22])
        XCTAssertEqual(words.totalLength, 22)
        XCTAssertEqual(words.keys, FineWords.keys(in: "alpha beta gamma delta"))

        XCTAssertEqual(words.chapter(ofWord: 1), 0)
        XCTAssertEqual(words.chapter(ofWord: 2), 2, "past the empty chapter")
        XCTAssertEqual(words.start(ofWord: 2), TextPlace(chapter: 2, offset: 0))
        XCTAssertEqual(words.start(ofWord: 3), TextPlace(chapter: 2, offset: 6))
        XCTAssertEqual(words.start(ofWord: 4), TextPlace(chapter: 2, offset: 11), "past the last word: the end of the book")
        XCTAssertEqual(words.globalStart(ofWord: 3), 17)

        XCTAssertEqual(words.word(at: TextPlace(chapter: 0, offset: 3)), 0, "inside a word")
        XCTAssertEqual(words.word(at: TextPlace(chapter: 0, offset: 5)), 1, "between words: the next")
        XCTAssertEqual(words.word(at: TextPlace(chapter: 0, offset: 11)), 2, "a chapter's end: the next chapter's first word")
        XCTAssertEqual(words.word(at: TextPlace(chapter: 2, offset: 11)), 4, "the book's end: past the last word")
        XCTAssertEqual(words.word(at: TextPlace(chapter: 7, offset: 0)), 4, "a chapter the book doesn't have")
    }

    /// The end of the book is its last chapter at its full length, where
    /// P07 rests a finished book; a place is exactly the end there, or at
    /// the end of the last chapter with text before empty ones. A place past
    /// the end points past the text, so it is not the end's place.
    func testTheEndOfTheBook() {
        let words = BookWords(texts: ["Alpha beta.", "Gamma delta", ""])
        XCTAssertEqual(words.endPlace, TextPlace(chapter: 2, offset: 0))
        XCTAssertTrue(words.isEnd(TextPlace(chapter: 2, offset: 0)))
        XCTAssertTrue(words.isEnd(TextPlace(chapter: 1, offset: 11)), "before nothing but an empty chapter")
        XCTAssertFalse(words.isEnd(TextPlace(chapter: 1, offset: 12)), "past the end of the text")
        XCTAssertFalse(words.isEnd(TextPlace(chapter: 1, offset: Int.max)))
        XCTAssertFalse(words.isEnd(TextPlace(chapter: 0, offset: 11)), "the end of a chapter before the last")
        XCTAssertFalse(words.isEnd(TextPlace(chapter: 1, offset: 10)))
        XCTAssertFalse(words.isEnd(TextPlace(chapter: 3, offset: 0)), "a chapter the book doesn't have")
        XCTAssertEqual(BookWords(texts: []).endPlace, TextPlace(chapter: 0, offset: 0))
        XCTAssertFalse(BookWords(texts: []).isEnd(TextPlace(chapter: 0, offset: 0)), "a book without chapters")
        XCTAssertFalse(BookWords(texts: ["", ""]).isEnd(TextPlace(chapter: 1, offset: 0)), "a book without text")
    }

    /// Offsets through the whole book map to places and back, held within
    /// the book.
    func testOffsetsThroughTheWholeBook() {
        let words = BookWords(texts: ["Alpha beta.", "", "Gamma delta"])
        XCTAssertEqual(words.globalOffset(of: TextPlace(chapter: 2, offset: 5)), 16)
        XCTAssertEqual(words.globalOffset(of: TextPlace(chapter: 0, offset: 99)), 11, "held within its chapter")
        XCTAssertEqual(words.globalOffset(of: TextPlace(chapter: -1, offset: 3)), 0)
        XCTAssertEqual(words.globalOffset(of: TextPlace(chapter: 9, offset: 3)), 22)
        XCTAssertEqual(words.place(atGlobalOffset: 4), TextPlace(chapter: 0, offset: 4))
        XCTAssertEqual(words.place(atGlobalOffset: 11), TextPlace(chapter: 2, offset: 0), "a chapter's end is the next chapter's start, past the empty one")
        XCTAssertEqual(words.place(atGlobalOffset: 22), TextPlace(chapter: 2, offset: 11))
        XCTAssertEqual(words.place(atGlobalOffset: 500), TextPlace(chapter: 2, offset: 11))
        XCTAssertEqual(words.place(atGlobalOffset: -3), TextPlace(chapter: 0, offset: 0))
        XCTAssertEqual(words.length(ofChapter: 2), 11)
        XCTAssertEqual(words.length(ofChapter: 3), 0)
        XCTAssertEqual(BookWords(texts: []).place(atGlobalOffset: 5), TextPlace(chapter: 0, offset: 0))
    }
}
