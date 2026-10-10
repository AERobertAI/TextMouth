import XCTest
@testable import TextMouth

/// Finding saved places again by their words when a book's text is read
/// anew (T06, `TextAnchorFinder`): the direct check; restored code before,
/// inside, and at a place; link text no longer written twice; rewrapped
/// lines; a restored chapter, merged chapters, and a moved boundary; a
/// passage printed twice with one copy edited; places at a chapter's start
/// and end; text an older extraction ran together; a refrain; the end of
/// the book; the tolerant second search; the last guess; and skipped
/// headings by level, label, and words. Real pairs are kept as strings
/// from two versions' readings (`TextAnchorRealReadings`). Pure: no
/// window, no file.
final class TextAnchorFinderTests: XCTestCase {

    // MARK: - A Book to Change

    /// Three chapters of a tram depot's night shift.
    private let depotOne = "CHAPTER ONE\n\n"
        + "The night shift at the depot began when the last tram rolled in from the river line. "
        + "Odile chalked its number on the board beside the sand hopper, then walked the length of the shed with a lamp, counting wheels.\n\n"
        + "Bram was already under car nineteen, cursing a brake shoe worn to a sliver. "
        + "He asked for the long spanner without looking up, and she slid it across the pit floor with her boot."
    private let depotTwo = "CHAPTER TWO\n\n"
        + "At two o'clock the foreman came through with the overtime sheets and a paper bag of pastries from the bakery on Fenwick Street. "
        + "Nobody signed anything until the pastries were gone.\n\n"
        + "The radio on the workbench picked up a dispatcher from the next depot reading out the cars that would not run in the morning, one number at a time."
    private let depotThree = "CHAPTER THREE\n\n"
        + "By five the sky over the gasworks had gone the colour of weak tea. "
        + "Odile signed the last car out of the shed herself, watched it nose into the street, and only then noticed that her hands were black to the wrist.\n\n"
        + "She washed at the trough by the gate, folded the chalk list into her coat, and walked home past the shuttered fish market."

    /// The three chapters as a book.
    private var depot: [String] { [depotOne, depotTwo, depotThree] }

    /// `count` sentences of a quarry's ledger, each different from every
    /// other, to stand between two passages and set them far apart.
    private func ledger(_ count: Int) -> String {
        (1...count).map { "Ledger entry \($0): \($0 * 7 % 50 + 3) crates of slate weighed at the quarry scales went north by barge." }
            .joined(separator: " ")
    }

    // MARK: - Helpers

    /// Where the `occurrence`-th `phrase` (from 0) begins in chapter
    /// `chapter` of `texts`.
    private func place(
        of phrase: String,
        inChapter chapter: Int = 0,
        of texts: [String],
        occurrence: Int = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> TextPlace {
        let text = try XCTUnwrap(texts.indices.contains(chapter) ? texts[chapter] : nil, "no chapter \(chapter)", file: file, line: line) as NSString
        var searchFrom = 0
        var found: Int?
        for _ in 0...occurrence {
            let range = text.range(of: phrase, options: .literal, range: NSRange(location: searchFrom, length: text.length - searchFrom))
            guard range.location != NSNotFound else {
                found = nil
                break
            }
            found = range.location
            searchFrom = NSMaxRange(range)
        }
        let offset = try XCTUnwrap(found, "\"\(phrase)\" (\(occurrence)) isn't in chapter \(chapter)", file: file, line: line)
        return TextPlace(chapter: chapter, offset: offset)
    }

    /// Where a place saved at `saved` in the book `old` goes in the book
    /// `new`: its anchor captured in `old`, then found in `new`.
    private func find(
        _ saved: TextPlace,
        from old: [String],
        in new: [String],
        savedChapterLength: Int? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> TextAnchorFinder.Result {
        let anchor = try XCTUnwrap(TextAnchor(capturingAt: saved, in: BookWords(texts: old)), file: file, line: line)
        return TextAnchorFinder(texts: new).find(anchor, savedAt: saved, savedChapterLength: savedChapterLength)
    }

    /// Asserts that the place at the start of every word of `old` lands on
    /// the start of the word of `new` that `counterpart` names for it (by
    /// their indices in each book's words), or, where `counterpart` gives a
    /// range, on a word inside it; a word `counterpart` gives nil for is not
    /// checked. Also asserts that no place lands by a guess unless
    /// `guessesAllowed`.
    private func assertEveryWordLands(
        from old: [String],
        in new: [String],
        guessesAllowed: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ counterpart: (Int) -> ClosedRange<Int>?
    ) {
        let oldWords = BookWords(texts: old)
        let finder = TextAnchorFinder(texts: new)
        var checked = 0
        for word in 0..<oldWords.count {
            guard let expected = counterpart(word) else { continue }
            let saved = oldWords.start(ofWord: word)
            guard let anchor = TextAnchor(capturingAt: saved, in: oldWords) else {
                XCTFail("no anchor for word \(word)", file: file, line: line)
                continue
            }
            let result = finder.find(anchor, savedAt: saved)
            let landed = finder.words.word(at: result.place)
            XCTAssertTrue(expected.contains(landed), "word \(word) landed on \(landed), not \(expected)", file: file, line: line)
            XCTAssertEqual(result.place, finder.words.start(ofWord: landed), "word \(word) lands at a word's start", file: file, line: line)
            if !guessesAllowed {
                XCTAssertFalse(result.isGuess, "word \(word) was a guess: \(result.finding)", file: file, line: line)
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, file: file, line: line)
    }

    /// The index of the word `place` stands at in `texts`.
    private func wordIndex(at place: TextPlace, in texts: [String]) -> Int {
        BookWords(texts: texts).word(at: place)
    }

    /// The item at `index` of `items`, or a test failure, never a trap.
    private func item<Item>(_ items: [Item], _ index: Int, file: StaticString = #filePath, line: UInt = #line) throws -> Item {
        try XCTUnwrap(items.indices.contains(index) ? items[index] : nil, "no item \(index)", file: file, line: line)
    }

    // MARK: - The Saved Words, as the Search Reads Them

    /// A quote's words leave out a word the 64-unit cut may have split: the
    /// first run between spaces of the quote before, and the last of the
    /// quote after, whole (as the measured rule does), unless a space bounds
    /// them. A place inside a word reads that whole word as the first after
    /// it, and remembers how far into it the place was.
    func testTheQuotesWordsLeaveOutWordsACutMaySplit() {
        let cut = TextAnchorFinder.Quote(TextAnchor(before: "ht shift at the depot", after: " began when the last tra", fraction: 0.1))
        XCTAssertEqual(cut.before, FineWords.keys(in: "shift at the depot"))
        XCTAssertEqual(cut.after, FineWords.keys(in: "began when the last"))
        XCTAssertNil(cut.inside)

        let bounded = TextAnchorFinder.Quote(TextAnchor(before: " night shift ", after: "began ", fraction: 0.1))
        XCTAssertEqual(bounded.before, FineWords.keys(in: "night shift"))
        XCTAssertEqual(bounded.after, FineWords.keys(in: "began"))

        let run = TextAnchorFinder.Quote(TextAnchor(before: "ucus-Race and a", after: " Long Tale", fraction: 0.1))
        XCTAssertEqual(run.before, FineWords.keys(in: "and a"), "the whole first run, both its words")
        XCTAssertEqual(run.after, FineWords.keys(in: "Long"))

        let midWord = TextAnchorFinder.Quote(TextAnchor(before: "the long spa", after: "nner without looking", fraction: 0.1))
        XCTAssertEqual(midWord.before, FineWords.keys(in: "long"))
        XCTAssertEqual(midWord.after, FineWords.keys(in: "spanner without"))
        XCTAssertEqual(midWord.inside?.key, FineWords.keys(in: "spanner").first)
        XCTAssertEqual(midWord.inside?.offset, 3)
    }

    // MARK: - The Direct Check

    /// A place whose words still stand around its numbers stays, even when
    /// the text changed beyond its quotes.
    func testAPlaceWhoseWordsStillStandIsUnchanged() throws {
        let saved = try place(of: "Nobody signed", inChapter: 1, of: depot)
        let unchanged = try find(saved, from: depot, in: depot)
        XCTAssertEqual(unchanged, TextAnchorFinder.Result(place: saved, finding: .unchanged))

        let changedElsewhere = [depotOne + " A line added to the first chapter.", depotTwo + " And one at the end.", depotThree]
        XCTAssertEqual(try find(saved, from: depot, in: changedElsewhere).finding, .unchanged)
    }

    // MARK: - Restored Code

    /// A code block restored earlier in the chapter moves the numbers;
    /// the place is found on its own words.
    func testRestoredCodeBeforeAPlace() throws {
        let saved = try place(of: "without looking up", of: depot)
        let withCode = depotOne.replacingOccurrences(of: "Bram was already", with: "let wheels = cars.reduce(0) { $0 + $1.axles }\n\nBram was already")
        let new = [withCode, depotTwo, depotThree]
        let result = try find(saved, from: depot, in: new)
        XCTAssertEqual(result.place, try place(of: "without looking up", of: new))
        guard case .found(.savedWords) = result.finding else {
            return XCTFail("found by its words, not \(result.finding)")
        }
    }

    /// Inline code restored inside the words after a place leaves its
    /// words before it and the first few after it to find it by.
    func testRestoredCodeInsideAPlacesWords() throws {
        let saved = try place(of: "the long spanner", of: depot)
        let withCode = depotOne.replacingOccurrences(of: "long spanner without", with: "long spanner `torque(19)` without")
        let new = [withCode, depotTwo, depotThree]
        let result = try find(saved, from: depot, in: new)
        XCTAssertEqual(result.place, try place(of: "the long spanner", of: new))
        XCTAssertFalse(result.isGuess)
    }

    /// Code restored exactly at a place goes before it: the words after a
    /// place count double, because they are what the listener was about to
    /// hear, so the place stays before its own words.
    func testRestoredCodeExactlyAtAPlace() throws {
        let saved = try place(of: "Bram was already", of: depot)
        let withCode = depotOne.replacingOccurrences(of: "Bram was already", with: "let wheels = cars.count * 6\n\nBram was already")
        let new = [withCode, depotTwo, depotThree]
        let result = try find(saved, from: depot, in: new)
        XCTAssertEqual(result.place, try place(of: "Bram was already", of: new))
        XCTAssertFalse(result.isGuess)
    }

    /// The words after a place count double, so a place with more words
    /// before it than after it (though fewer than twice as many) still
    /// stays before its own words when code goes in exactly there: counted
    /// alike, the words before would win, and the place would land at the
    /// code's start.
    func testWordsAfterAPlaceCountDouble() throws {
        let text = "At the far end of the yard, by the old water tower, the men sat on upturned crates and ate. "
            + "Afterwards, lunchtime talk invariably returned to pensions, overtime, timetables, and grievances."
        let saved = try place(of: "Afterwards", of: [text])
        let anchor = try XCTUnwrap(TextAnchor(capturingAt: saved, in: BookWords(texts: [text])))
        let quote = TextAnchorFinder.Quote(anchor)
        XCTAssertGreaterThan(quote.before.count, quote.after.count)
        XCTAssertLessThan(quote.before.count, 2 * quote.after.count)

        let new = [text.replacingOccurrences(of: "ate. Afterwards", with: "ate. `lunch.start()` Afterwards")]
        let result = try find(saved, from: [text], in: new)
        XCTAssertEqual(result.place, try place(of: "Afterwards", of: new))
        XCTAssertFalse(result.isGuess)
    }

    /// The real step that restored code (sample.md, 3.0.2 to 3.0.3: "It
    /// even handled  with grace." became "It even handled inline code with
    /// grace."): every place lands on its own word, and the one where the
    /// code went in stays before its own words.
    func testSampleMarkdownsRestoredCodeEveryPlaceOnItsOwnWord() throws {
        let old = [TextAnchorRealReadings.sampleMarkdown302]
        let new = [TextAnchorRealReadings.sampleMarkdown303]
        let inserted = wordIndex(at: try place(of: "with grace", of: old), in: old)
        assertEveryWordLands(from: old, in: new) { word in
            let counterpart = word < inserted ? word : word + 2
            return counterpart...counterpart
        }
    }

    // MARK: - Link Text Written Once

    /// The real step that wrote a link's text once (alice.docx, 3.0.2 to
    /// 3.0.3: "www.gutenberg.orgwww.gutenberg.org" became
    /// "www.gutenberg.org"): every place before and after the link lands on
    /// its own word, and one in the text written twice lands in the link.
    func testLinkTextWrittenOnceEveryPlaceOnItsOwnWord() throws {
        let old = [TextAnchorRealReadings.linkedParagraph302]
        let new = [TextAnchorRealReadings.linkedParagraph303]
        // "orgwww" is one word: the first copy's last word run into the
        // second copy's first. The second copy's other words follow it.
        let runTogether = wordIndex(at: try place(of: "orgwww", of: old), in: old)
        let link = (runTogether - 2)...(runTogether + 1)  // www, gutenberg, org, and If after them
        assertEveryWordLands(from: old, in: new) { word in
            if word < runTogether { return word...word }
            if word <= runTogether + 2 { return link }
            return (word - 2)...(word - 2)
        }
    }

    // MARK: - Rewrapped Lines

    /// Lines broken anew (plain text read with its line breaks as spaces,
    /// as 3.0.6 changed it) leave every word where it was in the words:
    /// each place lands on its own word.
    func testRewrappedLinesEveryPlaceOnItsOwnWord() {
        let paragraph = "The ferry to the island left at nine and came back at four, "
            + "and in the hours between, the harbour belonged to the gulls and to the "
            + "men who mended nets on the slipway, talking about nothing in particular."
        let hardWrapped = paragraph.replacingOccurrences(of: "four, ", with: "four,\n")
            .replacingOccurrences(of: "to the ", with: "to the\n")
        let new = [paragraph]
        let old = [hardWrapped]
        XCTAssertNotEqual(old, new)
        assertEveryWordLands(from: old, in: new) { $0...$0 }
    }

    // MARK: - Chapters Restored, Merged, and Moved

    /// A chapter an older extraction left out comes back before a place:
    /// the place is found in the chapter after it, on its own words.
    func testARestoredChapter() throws {
        let old = [depotOne, depotThree]
        let saved = try place(of: "walked home past", inChapter: 1, of: old)
        let result = try find(saved, from: old, in: depot)
        XCTAssertEqual(result.place, try place(of: "walked home past", inChapter: 2, of: depot))
        XCTAssertFalse(result.isGuess)
    }

    /// Two chapters run together: a place in the second is found in the
    /// one they became.
    func testMergedChapters() throws {
        let new = [depotOne, depotTwo + "\n\n" + depotThree]
        let saved = try place(of: "walked home past", inChapter: 2, of: depot)
        let result = try find(saved, from: depot, in: new)
        XCTAssertEqual(result.place, try place(of: "walked home past", inChapter: 1, of: new))
        XCTAssertFalse(result.isGuess)
    }

    /// A chapter's heading and first paragraph moved to the end of the
    /// chapter before (a corrected boundary): a place in the paragraph
    /// moved follows it there, and one in the paragraph left follows that.
    func testAMovedChapterBoundary() throws {
        let firstParagraph = "CHAPTER TWO\n\nAt two o'clock the foreman came through with the overtime sheets and a paper bag of pastries from the bakery on Fenwick Street. Nobody signed anything until the pastries were gone.\n\n"
        XCTAssertTrue(depotTwo.hasPrefix(firstParagraph))
        let new = [depotOne + "\n\n" + firstParagraph, String(depotTwo.dropFirst(firstParagraph.count)), depotThree]

        let moved = try find(try place(of: "Nobody signed", inChapter: 1, of: depot), from: depot, in: new)
        XCTAssertEqual(moved.place, try place(of: "Nobody signed", inChapter: 0, of: new))
        let left = try find(try place(of: "one number at a time", inChapter: 1, of: depot), from: depot, in: new)
        XCTAssertEqual(left.place, try place(of: "one number at a time", inChapter: 1, of: new))
    }

    // MARK: - A Passage Printed Twice

    /// A passage the book prints twice, with words edited in the copy a
    /// place was in: the far copy fits its saved words better, but the
    /// place stays in its own copy, near where it was, as a best guess
    /// (the tolerant search finds it there). It never jumps to the far copy.
    func testAPassagePrintedTwiceWithOneCopyEditedKeepsThePlaceInItsCopy() throws {
        let passage = "Tickets bought on the platform are valid for one journey only and must be shown to the conductor on request. "
            + "Lost tickets cannot be replaced, and fares are not refunded once a car has left the depot."
        let old = [passage + "\n\n" + ledger(40) + "\n\n" + passage]
        let saved = try place(of: "and must be shown", of: old)
        // The second word before the place and the second after it, edited
        // in the first copy only.
        let editedCopy = passage.replacingOccurrences(of: "one journey only and must", with: "one trip only and should")
        let new = [editedCopy + "\n\n" + ledger(40) + "\n\n" + passage]

        let result = try find(saved, from: old, in: new)
        XCTAssertEqual(result.place, try place(of: "and should be shown", of: new))
        XCTAssertEqual(result.finding, .guessed(.nearWhereItWas))
    }

    /// A weak match far away (a common phrase the place's next words share)
    /// doesn't take a place from where its words before it still stand: a
    /// spot near where it was, scoring enough, is the best guess.
    func testAWeakMatchFarAwayDoesNotTakeAPlaceFromItsWordsBefore() throws {
        let platform = "The porters stacked the trunks on the platform while the stationmaster checked his watch"
        let far = "\n\n" + ledger(40) + "\n\nYears later the porters remembered how the bell rang twice and then the train left without a whistle."
        let old = [platform + " and then the train left at noon for the coast, carrying the summer visitors home." + far]
        let saved = try place(of: "and then the train left at noon", of: old)
        // The words after the place rewritten, and one word of the nine
        // before it.
        let new = [platform.replacingOccurrences(of: "trunks on the", with: "trunks beside the")
            + " as the clock struck twelve the carriages rolled out toward the sea." + far]

        let result = try find(saved, from: old, in: new)
        XCTAssertEqual(result.place, try place(of: "as the clock struck", of: new))
        XCTAssertEqual(result.finding, .guessed(.nearWhereItWas))
    }

    // MARK: - A Chapter's Start and End

    /// A place at a chapter's start stays while that chapter's opening is
    /// unchanged, and follows its words when a line is put in before them.
    func testAPlaceAtAChaptersStart() throws {
        let saved = TextPlace(chapter: 1, offset: 0)
        let earlierChapterChanged = [depotOne + " A line added.", depotTwo, depotThree]
        XCTAssertEqual(try find(saved, from: depot, in: earlierChapterChanged).finding, .unchanged)

        let lineAdded = [depotOne, "Part Two\n\n" + depotTwo, depotThree]
        let result = try find(saved, from: depot, in: lineAdded)
        XCTAssertEqual(result.place, TextPlace(chapter: 1, offset: 10))
        XCTAssertFalse(result.isGuess)
    }

    /// A place at a chapter's end, whose chapter changed before it, is
    /// found just after its words: still at its chapter's end, not at the
    /// next chapter's start. Text added after it is no different from text
    /// added after any place: the place stays after its own words.
    func testAPlaceAtAChaptersEnd() throws {
        let saved = TextPlace(chapter: 1, offset: depotTwo.utf16.count)
        let changedTwo = depotTwo.replacingOccurrences(of: "At two o'clock", with: "At a quarter past two")
        let changedBefore = [depotOne, changedTwo, depotThree]
        let result = try find(saved, from: depot, in: changedBefore)
        XCTAssertEqual(result.place, TextPlace(chapter: 1, offset: changedTwo.utf16.count))
        XCTAssertFalse(result.isGuess)

        let addedAfter = [depotOne, depotTwo + " Then the line went quiet.", depotThree]
        XCTAssertEqual(try find(saved, from: depot, in: addedAfter), TextAnchorFinder.Result(place: saved, finding: .unchanged))
    }

    // MARK: - Text Run Together

    /// alice.docx's contents list, its entries run together as 3.0.4 read
    /// it ("…Rabbit-HoleCHAPTER II.The Pool of Tears…"), and one entry a
    /// paragraph as 3.0.7 reads it: split finely, the words are the same,
    /// so every place lands on its own word.
    func testAContentsListRunTogetherEveryPlaceOnItsOwnWord() {
        let old = [TextAnchorRealReadings.contents304]
        let new = [TextAnchorRealReadings.contents307]
        XCTAssertEqual(BookWords(texts: old).keys, BookWords(texts: new).keys)
        assertEveryWordLands(from: old, in: new) { $0...$0 }
    }

    /// test_book.docx's table, its cells run together as 3.0.4 read it
    /// ("…rain likely993-1003Falling rapidlyStorm…"), and a row a paragraph
    /// as 3.0.7 reads it: every place lands on its own word.
    func testATableRunTogetherEveryPlaceOnItsOwnWord() {
        let old = [TextAnchorRealReadings.table304]
        let new = [TextAnchorRealReadings.table307]
        XCTAssertEqual(BookWords(texts: old).keys, BookWords(texts: new).keys)
        assertEveryWordLands(from: old, in: new) { $0...$0 }
    }

    // MARK: - A Refrain

    /// A refrain sung twice (alice.epub's Lobster Quadrille): a place in it
    /// whose 128 saved units stand alike in both verses goes, as a best
    /// guess, to the verse nearer its share of the book. That is the verse
    /// it was in while the book's length barely changes. When the text
    /// after the song shrinks enough, the other verse is nearer, and the
    /// saved words alone can't tell the verses apart: the addendum's two
    /// misses in the real steps were such a place (the diff at a rebuild,
    /// T06's branch C, places it).
    func testARefrainGoesToTheVerseNearerItsShareOfTheBook() throws {
        let song = TextAnchorRealReadings.quadrille307
        let refrain = "Will you, won’t you, will you, won’t you, won’t you join the dance?"
        let saved = try place(of: refrain, of: [song], occurrence: 1)

        let headed = ["The Lobster Quadrille\n\n" + song]
        let nearer = try find(saved, from: [song], in: headed)
        XCTAssertEqual(nearer.place, try place(of: refrain, of: headed, occurrence: 1))
        XCTAssertEqual(nearer.finding, .guessed(.nearestOfEqualSpots))

        let afterward = "\n\n" + String(repeating: "The Gryphon and the Mock Turtle sat silent a long while, looking at Alice. ", count: 12)
        let longer = [song + afterward]
        let savedInLonger = try place(of: refrain, of: longer, occurrence: 1)
        let otherVerse = try find(savedInLonger, from: longer, in: headed)
        XCTAssertEqual(otherVerse.place, try place(of: refrain, of: headed, occurrence: 0))
        XCTAssertEqual(otherVerse.finding, .guessed(.nearestOfEqualSpots))
    }

    // MARK: - The End of the Book

    /// A place at the end of the book stays at the end of the book whatever
    /// is added or removed there (P07's finished book), and is unchanged
    /// while it is exactly there.
    func testTheEndOfTheBookStaysTheEnd() throws {
        let saved = TextPlace(chapter: 2, offset: depotThree.utf16.count)
        XCTAssertEqual(try find(saved, from: depot, in: depot), TextAnchorFinder.Result(place: saved, finding: .unchanged))

        let longerThree = depotThree + "\n\nA postscript, added in a later edition."
        XCTAssertEqual(
            try find(saved, from: depot, in: [depotOne, depotTwo, longerThree]),
            TextAnchorFinder.Result(place: TextPlace(chapter: 2, offset: longerThree.utf16.count), finding: .found(.endOfBook))
        )
        let shorterThree = depotThree.components(separatedBy: "\n\n").dropLast().joined(separator: "\n\n")
        XCTAssertFalse(shorterThree.isEmpty)
        XCTAssertEqual(
            try find(saved, from: depot, in: [depotOne, depotTwo, shorterThree]),
            TextAnchorFinder.Result(place: TextPlace(chapter: 2, offset: shorterThree.utf16.count), finding: .found(.endOfBook))
        )
        let fourth = "CHAPTER FOUR\n\nThe day shift came in at six."
        XCTAssertEqual(try find(saved, from: depot, in: depot + [fourth]).place, TextPlace(chapter: 3, offset: fourth.utf16.count))

        // A place saved past the end of the text rests at the end as P07
        // counts it (`Book.restsAtEnd`), so its anchor marks the end; its
        // numbers point past the text, so it goes to the end itself.
        let pastTheEnd = TextPlace(chapter: 2, offset: depotThree.utf16.count + 40)
        XCTAssertEqual(try find(pastTheEnd, from: depot, in: depot), TextAnchorFinder.Result(place: saved, finding: .found(.endOfBook)))
    }

    /// The end of a chapter before the last is not the end of the book.
    func testTheEndOfAnEarlierChapterIsNotTheEndOfTheBook() throws {
        let anchor = try XCTUnwrap(TextAnchor(capturingAt: TextPlace(chapter: 0, offset: depotOne.utf16.count), in: BookWords(texts: depot)))
        XCTAssertFalse(anchor.marksEndOfBook)
    }

    // MARK: - The Tolerant Second Search

    /// With a word edited on each side of a place, neither the four words
    /// after it nor the four before stand together anywhere, so the first
    /// search finds nothing; the tolerant search lines the quote up with
    /// the text and finds the place on its own word.
    func testTheTolerantSearchFindsAPlaceWithAWordEditedOnEachSide() throws {
        let saved = try place(of: "without looking up", of: depot)
        let edited = depotOne.replacingOccurrences(of: "the long spanner without looking up", with: "the heavy spanner without glancing up")
        let new = [edited, depotTwo, depotThree]
        let result = try find(saved, from: depot, in: new)
        XCTAssertEqual(result.place, try place(of: "without glancing up", of: new))
        guard case .found(.savedWords(let score)) = result.finding else {
            return XCTFail("found by its words, not \(result.finding)")
        }
        XCTAssertGreaterThanOrEqual(score, TextAnchorFinder.tolerantMinimumScore)
    }

    // MARK: - Places Inside Words and Characters

    /// A place inside a word (as a bookmark nudged clear of another can be)
    /// is found by that whole word and keeps how far into it it was.
    func testAPlaceInsideAWordKeepsItsPlaceInTheWord() throws {
        let saved = try place(of: "nner without", of: depot)  // three units into "spanner"
        let new = ["A note before the chapter.\n\n" + depotOne, depotTwo, depotThree]
        let result = try find(saved, from: depot, in: new)
        XCTAssertEqual(result.place, try place(of: "nner without", of: new))
        XCTAssertFalse(result.isGuess)
    }

    /// A place inside an emoji stands unchanged where it is.
    func testAPlaceInsideAnEmojiStandsUnchanged() throws {
        let text = ["The lamp went out 🕯️ and the shed went dark."]
        let saved = TextPlace(chapter: 0, offset: 19)  // inside the candle's two units
        XCTAssertEqual(try find(saved, from: text, in: text), TextAnchorFinder.Result(place: saved, finding: .unchanged))
    }

    // MARK: - The Last Guess

    /// A place whose words are found nowhere (its paragraph rewritten) goes
    /// to the same share of its chapter when the chapter's old length is
    /// known, else to its saved offset held within the chapter, at a word
    /// start; for a chapter the book no longer has, to the same share of
    /// the book.
    func testAPlaceWhoseWordsAreGoneIsGuessedAtTheSameShare() throws {
        let rewritten = "A completely different account of that morning: rain, a stalled lorry, and a dog asleep on the pavement outside the canteen."
        let new = [depotOne, rewritten, depotThree]
        let saved = try place(of: "pastries were gone", inChapter: 1, of: depot)

        let byShare = try find(saved, from: depot, in: new, savedChapterLength: depotTwo.utf16.count)
        let share = Double(saved.offset) / Double(depotTwo.utf16.count)
        let target = Int(share * Double(rewritten.utf16.count))
        XCTAssertEqual(byShare.place, TextPlace(chapter: 1, offset: ReaderViewModel.snappedWordStart(in: rewritten, at: target)))
        XCTAssertEqual(byShare.finding, .guessed(.sameShare))

        let byOffset = try find(saved, from: depot, in: new)
        let held = min(saved.offset, rewritten.utf16.count)
        XCTAssertEqual(byOffset.place, TextPlace(chapter: 1, offset: ReaderViewModel.snappedWordStart(in: rewritten, at: held)))
        XCTAssertEqual(byOffset.finding, .guessed(.sameShare))

        let anchor = try XCTUnwrap(TextAnchor(capturingAt: saved, in: BookWords(texts: depot)))
        let shorter = [rewritten]
        let chapterGone = TextAnchorFinder(texts: shorter).find(anchor, savedAt: saved)
        let shareOfBook = Int(anchor.fraction * Double(rewritten.utf16.count))
        XCTAssertEqual(chapterGone.place, TextPlace(chapter: 0, offset: ReaderViewModel.snappedWordStart(in: rewritten, at: shareOfBook)))
        XCTAssertEqual(chapterGone.finding, .guessed(.sameShare))
    }

    /// Odd input never traps: an empty book, places out of range, an anchor
    /// with no words.
    func testOddInputNeverTraps() throws {
        let anchor = TextAnchor(before: "some words before", after: "and some after", fraction: 0.5)
        XCTAssertEqual(TextAnchorFinder(texts: []).find(anchor, savedAt: TextPlace(chapter: 0, offset: 0)).place, TextPlace(chapter: 0, offset: 0))
        XCTAssertEqual(TextAnchorFinder(texts: [""]).find(anchor, savedAt: TextPlace(chapter: 3, offset: -9)).place, TextPlace(chapter: 0, offset: 0))
        let finder = TextAnchorFinder(texts: depot)
        for saved in [TextPlace(chapter: -1, offset: 0), TextPlace(chapter: 9, offset: 9), TextPlace(chapter: 1, offset: Int.max), TextPlace(chapter: 1, offset: -5)] {
            let result = finder.find(anchor, savedAt: saved)
            XCTAssertTrue(finder.words.texts.indices.contains(result.place.chapter))
            XCTAssertTrue((0...finder.words.length(ofChapter: result.place.chapter)).contains(result.place.offset))
        }
        let empty = TextAnchor(before: "", after: "", fraction: 0.2)
        XCTAssertEqual(finder.find(empty, savedAt: TextPlace(chapter: 1, offset: 4)).finding, .unchanged, "no words to check: the numbers stand")
        XCTAssertNil(finder.findHeading(level: 1, label: "Cover", anchor: empty, savedAt: TextPlace(chapter: 0, offset: 0)), "a book without headings")
    }

    // MARK: - Skipped Headings

    /// alice.epub's cover and first two chapters as 3.0.4 read them, with
    /// their headings, and as 3.0.7 reads them, which relabelled the
    /// chapters' headings.
    private var aliceOld: (texts: [String], headings: [Heading]) {
        (["", TextAnchorRealReadings.chapterOneOpening304, TextAnchorRealReadings.chapterTwoOpening304],
         [Heading(level: 1, text: "\"Cover\"", chapterIndex: 0, characterOffset: 0),
          Heading(level: 2, text: "[]CHAPTER I.", chapterIndex: 1, characterOffset: 0),
          Heading(level: 2, text: "[]CHAPTER II.", chapterIndex: 2, characterOffset: 0)])
    }

    /// The same book as 3.0.7 reads it.
    private var aliceNew: (texts: [String], headings: [Heading]) {
        (["", TextAnchorRealReadings.chapterOneOpening307, TextAnchorRealReadings.chapterTwoOpening307],
         [Heading(level: 1, text: "\"Cover\"", chapterIndex: 0, characterOffset: 0),
          Heading(level: 2, text: "CHAPTER I. Down the Rabbit-Hole", chapterIndex: 1, characterOffset: 0),
          Heading(level: 2, text: "CHAPTER II. The Pool of Tears", chapterIndex: 2, characterOffset: 0)])
    }

    /// The skip of `heading` in the book whose chapters' reading texts are
    /// `texts`: its anchor, captured at the heading's start, and that start.
    private func skip(_ heading: Heading, in texts: [String], file: StaticString = #filePath, line: UInt = #line) throws -> (anchor: TextAnchor, saved: TextPlace) {
        let saved = TextPlace(chapter: heading.chapterIndex, offset: heading.characterOffset)
        return (try XCTUnwrap(TextAnchor(capturingAt: saved, in: BookWords(texts: texts)), file: file, line: line), saved)
    }

    /// A skipped heading still where it was, with its label, is unchanged.
    func testASkippedHeadingStillWhereItWasIsUnchanged() throws {
        let book = aliceOld
        let heading = try XCTUnwrap(book.headings.last)
        let skipped = try skip(heading, in: book.texts)
        let result = TextAnchorFinder(texts: book.texts, headings: book.headings)
            .findHeading(level: heading.level, label: heading.text, anchor: skipped.anchor, savedAt: skipped.saved)
        XCTAssertEqual(result, TextAnchorFinder.HeadingResult(heading: heading, finding: .unchanged))
    }

    /// A skipped heading relabelled by a newer extraction ("[]CHAPTER I."
    /// became "CHAPTER I. Down the Rabbit-Hole" on October 3) is found by
    /// its words and takes its new label; today's ID would have lost it.
    func testARelabelledSkippedHeadingIsFoundAndTakesItsNewLabel() throws {
        let old = aliceOld
        let new = aliceNew
        let heading = try item(old.headings, 1)
        let skipped = try skip(heading, in: old.texts)
        let result = try XCTUnwrap(TextAnchorFinder(texts: new.texts, headings: new.headings)
            .findHeading(level: heading.level, label: heading.text, anchor: skipped.anchor, savedAt: skipped.saved))
        XCTAssertEqual(result.heading, try item(new.headings, 1))
        XCTAssertEqual(result.heading.text, "CHAPTER I. Down the Rabbit-Hole")
        guard case .found(.savedWords) = result.finding else {
            return XCTFail("found by its words, not \(result.finding)")
        }
        XCTAssertFalse(new.headings.contains { $0.id == heading.id }, "the old ID names no heading now")
    }

    /// A real step's skipped heading moves with its text: sample.md's
    /// "Section 1.1: Lists" after the restored code, 11 units on.
    func testASkippedHeadingFollowsItsText() throws {
        let old = [TextAnchorRealReadings.sampleMarkdown302]
        let new = [TextAnchorRealReadings.sampleMarkdown303]
        let oldHeading = Heading(level: 3, text: "Section 1.1: Lists", chapterIndex: 0, characterOffset: try place(of: "Section 1.1", of: old).offset)
        let newHeading = Heading(level: 3, text: "Section 1.1: Lists", chapterIndex: 0, characterOffset: try place(of: "Section 1.1", of: new).offset)
        XCTAssertEqual(newHeading.characterOffset, oldHeading.characterOffset + 11)
        let decoy = Heading(level: 3, text: "Section 2.1: Special Characters", chapterIndex: 0, characterOffset: try place(of: "Section 2.1", of: new).offset)
        let skipped = try skip(oldHeading, in: old)
        let result = TextAnchorFinder(texts: new, headings: [newHeading, decoy])
            .findHeading(level: 3, label: oldHeading.text, anchor: skipped.anchor, savedAt: skipped.saved)
        XCTAssertEqual(result?.heading, newHeading)
        XCTAssertEqual(result?.isGuess, false)
    }

    /// A cover has no words to find it by: its skip finds the one heading
    /// of its level with its label, even when a title page put in where it
    /// was has a heading of the same level.
    func testACoversSkippedHeadingIsTheOneHeadingOfItsLevelWithItsLabel() throws {
        let old = aliceOld
        let cover = try item(old.headings, 0)
        let skipped = try skip(cover, in: old.texts)
        XCTAssertEqual(skipped.anchor.before + skipped.anchor.after, "", "a cover holds no text")

        let unchanged = TextAnchorFinder(texts: old.texts, headings: old.headings)
            .findHeading(level: 1, label: cover.text, anchor: skipped.anchor, savedAt: skipped.saved)
        XCTAssertEqual(unchanged, TextAnchorFinder.HeadingResult(heading: cover, finding: .unchanged))

        let titlePage = Heading(level: 1, text: "Title Page", chapterIndex: 0, characterOffset: 0)
        let movedCover = Heading(level: 1, text: cover.text, chapterIndex: 1, characterOffset: 0)
        let texts = ["Alice’s Adventures in Wonderland, a title page.", ""] + Array(old.texts.dropFirst())
        let result = TextAnchorFinder(texts: texts, headings: [titlePage, movedCover])
            .findHeading(level: 1, label: cover.text, anchor: skipped.anchor, savedAt: skipped.saved)
        XCTAssertEqual(result, TextAnchorFinder.HeadingResult(heading: movedCover, finding: .found(.onlyHeadingWithItsLabel)))
    }

    /// Two headings of a level whose label and words stand alike (two acts
    /// that end alike and open their intervals alike): the saved words
    /// can't choose, so the skip goes, as a best guess, to the one with its
    /// label nearest where it was.
    func testHeadingsAlikeAreAGuessAtTheNearestWithItsLabel() throws {
        let close = "The house lights dimmed, the conductor lifted his baton, and the hall went quiet at last."
        let interval = "Intermission\n\nThe orchestra tuned again while the stagehands carried the painted forest off and a painted harbour on."
        let actOne = "Act one, in the town square. " + close + "\n\n" + interval
        let actTwo = "Act two, a week later, at the harbour. " + close + "\n\n" + interval
        let old = [actOne, actTwo]
        let second = Heading(level: 2, text: "Intermission", chapterIndex: 1, characterOffset: try place(of: "Intermission", inChapter: 1, of: old).offset)
        let skipped = try skip(second, in: old)

        let new = [actOne, "A line put in.\n\n" + actTwo]
        let newFirst = Heading(level: 2, text: "Intermission", chapterIndex: 0, characterOffset: try place(of: "Intermission", inChapter: 0, of: new).offset)
        let newSecond = Heading(level: 2, text: "Intermission", chapterIndex: 1, characterOffset: try place(of: "Intermission", inChapter: 1, of: new).offset)
        let result = TextAnchorFinder(texts: new, headings: [newFirst, newSecond])
            .findHeading(level: 2, label: "Intermission", anchor: skipped.anchor, savedAt: skipped.saved)
        XCTAssertEqual(result, TextAnchorFinder.HeadingResult(heading: newSecond, finding: .guessed(.nearestHeadingWithItsLabel)))
    }

    /// Two headings of a level standing on the same words (two parts that
    /// open with one epigraph, under labels their book's navigation gives):
    /// the unchanged label settles it, so the skip is found, not guessed.
    func testAnUnchangedLabelSettlesHeadingsOnTheSameWords() throws {
        let epigraph = "“Every journey on the river line ends at the depot, and every depot keeps a lamp lit for the last car.”"
        let old = [epigraph + "\n\nThe first part opens in March.", epigraph + "\n\nThe second part opens in October."]
        let skippedPart = Heading(level: 1, text: "Part Two", chapterIndex: 1, characterOffset: 0)
        let skipped = try skip(skippedPart, in: old)

        let new = [try item(old, 0), "Second part.\n\n" + (try item(old, 1))]
        let partOne = Heading(level: 1, text: "Part One", chapterIndex: 0, characterOffset: 0)
        let partTwo = Heading(level: 1, text: "Part Two", chapterIndex: 1, characterOffset: 14)
        let result = try XCTUnwrap(TextAnchorFinder(texts: new, headings: [partOne, partTwo])
            .findHeading(level: 1, label: "Part Two", anchor: skipped.anchor, savedAt: skipped.saved))
        XCTAssertEqual(result.heading, partTwo)
        guard case .found(.savedWords) = result.finding else {
            return XCTFail("found by its words and label, not \(result.finding)")
        }
    }

    /// A skipped heading with no heading of its level left, or whose words
    /// and label are both gone, waits: it names no heading, rather than
    /// skip another section and hide text meant to be heard.
    func testASkippedHeadingWithNothingToNameWaits() throws {
        let old = aliceOld
        let cover = try item(old.headings, 0)
        let heading = try item(old.headings, 2)
        let skipped = try skip(heading, in: old.texts)
        let noLevelTwo = TextAnchorFinder(texts: old.texts, headings: [cover])
        XCTAssertNil(noLevelTwo.findHeading(level: 2, label: heading.text, anchor: skipped.anchor, savedAt: skipped.saved))

        let rewritten = ["", TextAnchorRealReadings.chapterOneOpening307, "CHAPTER II. Something Else Entirely\n\nA wholly new opening, with none of the old words in it at all."]
        let headings = [cover, Heading(level: 2, text: "CHAPTER I. Down the Rabbit-Hole", chapterIndex: 1, characterOffset: 0),
                        Heading(level: 2, text: "CHAPTER II. Something Else Entirely", chapterIndex: 2, characterOffset: 0)]
        XCTAssertNil(TextAnchorFinder(texts: rewritten, headings: headings)
            .findHeading(level: 2, label: heading.text, anchor: skipped.anchor, savedAt: skipped.saved))
    }

    /// The finder reads a loaded book's chapters and headings.
    func testAFinderReadsALoadedBook() throws {
        let chapters = aliceNew.texts.enumerated().map { index, text in
            Chapter(title: "", text: text, headings: aliceNew.headings.filter { $0.chapterIndex == index })
        }
        let finder = TextAnchorFinder(content: DocumentContent(title: "Alice", author: "Lewis Carroll", chapters: chapters))
        XCTAssertEqual(finder.words.texts, aliceNew.texts)
        XCTAssertEqual(finder.headings.map(\.text), aliceNew.headings.map(\.text))
    }
}
