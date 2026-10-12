import XCTest
@testable import TextMouth

/// The rules the diff of an old text with a new one (T06, `PlaceRelocator`)
/// shares with the saved-words search (`TextAnchorFinder`): where a found
/// place lands (`BookWords.landing`), the rules that settle a place without
/// a search (`TextAnchorFinder.settled`), and the first search's one best
/// spot wherever it lies (`TextAnchorFinder.onlyBestSpot`). Pure: no window,
/// no file.
final class PlaceRelocatorSharedRuleTests: XCTestCase, MillBookReading {

    /// The first word's key of `word`.
    private func key(_ word: String, file: StaticString = #filePath, line: UInt = #line) throws -> UInt64 {
        try XCTUnwrap(FineWords.keys(in: word).first, file: file, line: line)
    }

    // MARK: - Where a Found Place Lands

    /// A place lands at the start of the word it stands before; past the
    /// book's last word, at the end of the book.
    func testAPlaceLandsAtTheStartOfItsWord() throws {
        let book = [millrace, wheel]
        let words = BookWords(texts: book)
        let oak = try Phrase.place(of: "oak", inChapter: 1, of: book)
        XCTAssertEqual(words.landing(beforeWord: words.word(at: oak)), oak)
        XCTAssertEqual(words.landing(beforeWord: words.count), words.endPlace)
    }

    /// A place that stood inside a word keeps how far into it it was when it
    /// lands before that same word, never past the word's end, and lands at
    /// the start of any other word.
    func testAPlaceInsideAWordKeepsHowFarIntoItItWas() throws {
        let book = [millrace, wheel]
        let words = BookWords(texts: book)
        let start = try Phrase.place(of: "Millrace", inChapter: 0, of: book)
        let word = words.word(at: start)
        let millraceKey = try key("Millrace")
        XCTAssertEqual(words.landing(beforeWord: word, inside: (millraceKey, 4)), TextPlace(chapter: 0, offset: start.offset + 4))
        XCTAssertEqual(words.landing(beforeWord: word, inside: (millraceKey, 40)), TextPlace(chapter: 0, offset: start.offset + 8), "never past the word's end")
        XCTAssertEqual(words.landing(beforeWord: word, inside: (try key("Sluice"), 4)), start, "another word: its start")
    }

    /// A place with no word after it in its chapter stands just after the
    /// word before the one it lands before: at the end of that word's
    /// chapter when the word begins another chapter or the book has no more
    /// words, and at the word's start within one chapter.
    func testAPlaceWithNothingAfterItStandsJustAfterTheWordBefore() throws {
        // A third chapter without words, as a book's last page can be.
        let book = [millrace, wheel, ""]
        let words = BookWords(texts: book)
        let wheelStart = try XCTUnwrap(words.chapterFirstWords.dropFirst().first)
        XCTAssertEqual(words.landing(beforeWord: wheelStart, nothingAfter: true), TextPlace(chapter: 0, offset: words.length(ofChapter: 0)))
        XCTAssertEqual(words.landing(beforeWord: words.count, nothingAfter: true), TextPlace(chapter: 1, offset: words.length(ofChapter: 1)),
                       "past the last word: the end of the last word's chapter, not the empty chapter after it")
        let oak = try Phrase.place(of: "oak", inChapter: 1, of: book)
        XCTAssertEqual(words.landing(beforeWord: words.word(at: oak), nothingAfter: true), oak, "within one chapter: the word's start")
        XCTAssertEqual(words.landing(beforeWord: 0, nothingAfter: true), TextPlace(chapter: 0, offset: 0), "no word before the first")
    }

    // MARK: - Rules That Need No Search

    /// The finder's first two rules settle a place without a search: words
    /// still standing around their numbers keep their place, and the end of
    /// the book stays the end; any other place is left to the search.
    func testSettledKeepsWordsThatStandAndTheEndOfTheBook() throws {
        let book = [millrace, wheel]
        let words = BookWords(texts: book)
        let finder = TextAnchorFinder(words: words)
        let oak = try Phrase.place(of: "oak", inChapter: 1, of: book)
        let anchor = try XCTUnwrap(TextAnchor(capturingAt: oak, in: words))
        XCTAssertEqual(finder.settled(anchor, savedAt: oak), TextAnchorFinder.Result(place: oak, finding: .unchanged))
        XCTAssertNil(finder.settled(anchor, savedAt: TextPlace(chapter: 1, offset: oak.offset + 1)))

        // The end of a book stays its end, and the end of a book the new
        // text lengthens is the new end.
        let end = try XCTUnwrap(TextAnchor(capturingAt: words.endPlace, in: words))
        XCTAssertTrue(end.marksEndOfBook)
        XCTAssertEqual(finder.settled(end, savedAt: words.endPlace), TextAnchorFinder.Result(place: words.endPlace, finding: .unchanged))
        let longer = TextAnchorFinder(texts: [millrace, wheel + " A carpenter came on Tuesdays to fit new ones."])
        XCTAssertEqual(longer.settled(end, savedAt: words.endPlace), TextAnchorFinder.Result(place: longer.words.endPlace, finding: .found(.endOfBook)))
    }

    /// `find` begins with the settling rules, so it agrees with them
    /// wherever they settle a place.
    func testFindAgreesWithTheSettlingRules() throws {
        let book = [millrace, wheel]
        let words = BookWords(texts: book)
        let finder = TextAnchorFinder(words: words)
        for (phrase, chapter) in [("volunteers", 0), ("pump", 0), ("eleven", 1), ("frost", 1)] {
            let saved = try Phrase.place(of: phrase, inChapter: chapter, of: book)
            let anchor = try XCTUnwrap(TextAnchor(capturingAt: saved, in: words))
            let settled = try XCTUnwrap(finder.settled(anchor, savedAt: saved), phrase)
            XCTAssertEqual(finder.find(anchor, savedAt: saved), settled, phrase)
        }
    }

    // MARK: - The End of a Book, and Where a Place Opens

    /// The end of a book and where a saved place opens are one rule each,
    /// which the book, the reader, and the relocator share: a place at or
    /// past the book's length rests at its end and one short of it does
    /// not; a place opens in its chapter held within it, a chapter before
    /// the first at the book's start, and a chapter past the last at the
    /// book's end only when its offset in the whole book rests at the end,
    /// else at the last chapter's start.
    func testTheEndOfABookAndWhereAPlaceOpensAreOneRule() {
        XCTAssertTrue(TextPlace.restsAtEnd(globalOffset: 280, bookLength: 280))
        XCTAssertTrue(TextPlace.restsAtEnd(globalOffset: 300, bookLength: 280))
        XCTAssertFalse(TextPlace.restsAtEnd(globalOffset: 279, bookLength: 280), "short of the end, however near")
        XCTAssertFalse(TextPlace.restsAtEnd(globalOffset: 0, bookLength: 0), "a book without text")

        let lengths = [100, 180]
        func opening(_ chapter: Int, _ offset: Int, global: Int? = nil) -> TextPlace {
            TextPlace(chapter: chapter, offset: offset).opening(savedGlobalOffset: global, chapterCount: lengths.count, bookLength: 280) { lengths[$0] }
        }
        XCTAssertEqual(opening(0, 37), TextPlace(chapter: 0, offset: 37))
        XCTAssertEqual(opening(0, 109), TextPlace(chapter: 0, offset: 100))
        XCTAssertEqual(opening(1, -3), TextPlace(chapter: 1, offset: 0))
        XCTAssertEqual(opening(-1, 50), TextPlace(chapter: 0, offset: 0))
        XCTAssertEqual(opening(4, 10, global: 280), TextPlace(chapter: 1, offset: 180))
        XCTAssertEqual(opening(4, 10, global: 279), TextPlace(chapter: 1, offset: 0))
        XCTAssertEqual(opening(4, 10), TextPlace(chapter: 1, offset: 0))
        XCTAssertEqual(TextPlace(chapter: 2, offset: 9).opening(savedGlobalOffset: 9, chapterCount: 0, bookLength: 0) { _ in 0 }, TextPlace(chapter: 0, offset: 0))
    }

    // MARK: - The One Best Spot

    /// The first search's one best spot is found wherever it lies, however
    /// far from where the place was, with the word the place stands before
    /// there: the diff's question about moved text.
    func testTheOneBestSpotIsFoundWhereverItLies() throws {
        let book = [millrace, wheel]
        let saved = try Phrase.place(of: "eleven feet", inChapter: 1, of: book)
        let anchor = try XCTUnwrap(TextAnchor(capturingAt: saved, in: BookWords(texts: book)))
        // The wheel's chapter moved to the end of a long book, far from the
        // place's share of the book, which the locality rule would heed.
        let ledger = MillBook.ledger
        let moved = [millrace, ledger, wheel]
        let finder = TextAnchorFinder(texts: moved)
        let spot = try XCTUnwrap(finder.onlyBestSpot(for: anchor))
        XCTAssertEqual(spot.place, try Phrase.place(of: "eleven feet", inChapter: 2, of: moved))
        XCTAssertEqual(spot.word, finder.words.word(at: spot.place))
    }

    /// Two spots that score alike, or none that scores enough, give no one
    /// best spot.
    func testNoOneBestSpotAmongEqualsOrNone() throws {
        let book = [millrace, wheel]
        let saved = try Phrase.place(of: "eleven feet", inChapter: 1, of: book)
        let anchor = try XCTUnwrap(TextAnchor(capturingAt: saved, in: BookWords(texts: book)))
        XCTAssertNil(TextAnchorFinder(texts: [wheel, wheel]).onlyBestSpot(for: anchor), "two copies alike")
        XCTAssertNil(TextAnchorFinder(texts: [millrace]).onlyBestSpot(for: anchor), "its words stand nowhere")
        XCTAssertNil(TextAnchorFinder(texts: []).onlyBestSpot(for: anchor), "a book without text")

        // Only six of its words before it stand there, and none after: a
        // score of 6, under the 8 a spot needs.
        let noon = try Phrase.place(of: "By noon", inChapter: 0, of: book)
        let weak = try XCTUnwrap(TextAnchor(capturingAt: noon, in: BookWords(texts: book)))
        XCTAssertNil(TextAnchorFinder(texts: ["A storm drain runs in the shallows by the sluice.\n\nThen the talk turned to money."]).onlyBestSpot(for: weak),
                     "a spot whose words fit too weakly")
    }

    /// A spot that only the words before a place score is not the place's
    /// one best spot (REV15, finding 5): the words before say where the text
    /// before it went, not that the place's own text is there. A word
    /// replaced ("frogspawn" became "duckweed") leaves the words before it
    /// scoring well and its own words nowhere.
    func testAPlacesOwnWordsMustStandAtItsOneBestSpot() throws {
        let book = [millrace]
        let saved = try Phrase.place(of: "frogspawn", inChapter: 0, of: book)
        let anchor = try XCTUnwrap(TextAnchor(capturingAt: saved, in: BookWords(texts: book)))
        XCTAssertNil(TextAnchorFinder(texts: [millrace.replacingOccurrences(of: "frogspawn", with: "duckweed")]).onlyBestSpot(for: anchor))
        let spot = try XCTUnwrap(TextAnchorFinder(texts: [wheel, millrace]).onlyBestSpot(for: anchor), "its own words stand there")
        XCTAssertEqual(spot.place, try Phrase.place(of: "frogspawn", inChapter: 1, of: [wheel, millrace]))
    }
}
