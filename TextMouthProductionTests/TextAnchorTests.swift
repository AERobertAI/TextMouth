import XCTest
@testable import TextMouth

/// A saved place's anchor (T06): the text just before the place and just
/// after it, up to 64 UTF-16 units each and cut on composed-character
/// boundaries, its share of the book, and what it was measured in; the
/// direct check that tells an unchanged place; and its JSON, which decodes
/// leniently. Pure: no window, no file.
final class TextAnchorTests: XCTestCase {

    /// Latin prose longer than two quotes, for captures away from a
    /// chapter's edges.
    private let prose = "The night shift at the depot began when the last tram rolled in from the river line. "
        + "Odile chalked its number on the board beside the sand hopper, then walked the length of the shed "
        + "with a lamp, counting wheels, while Bram swore softly at a brake shoe worn to a sliver."

    /// The anchor of the place `offset` units into `text`, as the only
    /// chapter of its book.
    private func anchor(at offset: Int, in text: String) -> TextAnchor {
        TextAnchor(capturingAt: offset, in: text, chapterStart: 0, bookLength: text.utf16.count, measuredIn: "3.0.7/1.0.0")
    }

    // MARK: - Capture

    /// An anchor in Latin text keeps 64 UTF-16 units each side, the text
    /// just before the place and from it on, and encodes in about 200 bytes
    /// of JSON, as library.json and bookInfo.json write it.
    func testAnAnchorInLatinTextKeeps64UnitsEachSideInAbout200Bytes() throws {
        let offset = 100
        let anchor = anchor(at: offset, in: prose)
        XCTAssertEqual(anchor.before.utf16.count, 64)
        XCTAssertEqual(anchor.after.utf16.count, 64)
        let units = prose as NSString
        XCTAssertEqual(anchor.before, units.substring(with: NSRange(location: offset - 64, length: 64)))
        XCTAssertEqual(anchor.after, units.substring(with: NSRange(location: offset, length: 64)))
        XCTAssertEqual(anchor.version, 1)
        XCTAssertEqual(anchor.measuredIn, "3.0.7/1.0.0")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let size = try encoder.encode(anchor).count
        XCTAssertGreaterThan(size, 200)
        XCTAssertLessThanOrEqual(size, 230, "an anchor's quotes, share, measure, and format in Latin text")
    }

    /// This build stamps its text cache's and content index's versions.
    func testAnAnchorIsStampedWithTheTextItWasMeasuredIn() {
        XCTAssertEqual(TextAnchor.currentMeasure, "\(MarkdownCacheService.currentCacheVersion)/\(BookContentIndex.currentVersion)")
        let stamped = TextAnchor(capturingAt: 3, in: prose, chapterStart: 0, bookLength: 1_000)
        XCTAssertEqual(stamped.measuredIn, TextAnchor.currentMeasure)
    }

    /// Near a chapter's start the quote before is the text there; at its
    /// start it is empty, and at its end the quote after is empty. An
    /// offset outside the chapter is captured at its edge.
    func testCaptureNearAChaptersEdges() {
        let text = "Short chapter."
        XCTAssertEqual(anchor(at: 6, in: text).before, "Short ")
        XCTAssertEqual(anchor(at: 6, in: text).after, "chapter.")
        XCTAssertEqual(anchor(at: 0, in: text).before, "")
        XCTAssertEqual(anchor(at: 14, in: text).after, "")
        XCTAssertEqual(anchor(at: 14, in: text).before, text)
        XCTAssertEqual(anchor(at: 99, in: text), anchor(at: 14, in: text), "past the end: at the end")
        XCTAssertEqual(anchor(at: -4, in: text), anchor(at: 0, in: text), "before the start: at the start")
        let empty = anchor(at: 0, in: "")
        XCTAssertEqual(empty.before, "")
        XCTAssertEqual(empty.after, "")
    }

    /// A cut never splits an emoji: one the 64-unit cut falls inside is
    /// left out of the quote whole.
    func testACutNeverSplitsAnEmoji() {
        let emoji = "👩‍🔬"  // a woman scientist: three scalars, five UTF-16 units
        XCTAssertEqual(emoji.utf16.count, 5)
        let head = String(repeating: "a", count: 61)
        // The emoji takes units 63 to 67.
        let text = "x " + head + emoji + " tail" + String(repeating: "b", count: 61)
        // The quote after the place at 2 would end at 66, inside the emoji,
        // so it ends before it.
        let after = anchor(at: 2, in: text).after
        XCTAssertEqual(after, head)
        // The quote before the place at 129 would begin at 65, inside the
        // emoji, so it begins after it.
        let before = anchor(at: 129, in: text).before
        XCTAssertEqual(before, " tail" + String(repeating: "b", count: 56))
    }

    /// A cut never splits a letter from its accents: one the cut falls
    /// inside is left out whole, and one a cut falls just before is kept
    /// whole.
    func testACutNeverSplitsALetterFromItsAccents() {
        let accented = "e\u{301}\u{302}"  // e with acute and circumflex: three units
        let accentedLast = String(repeating: "a", count: 63) + accented + "z"
        XCTAssertEqual(anchor(at: 0, in: accentedLast).after, String(repeating: "a", count: 63))
        let accentedFirst = "z" + accented + String(repeating: "a", count: 63)
        XCTAssertEqual(anchor(at: accentedFirst.utf16.count, in: accentedFirst).before, String(repeating: "a", count: 63))
        XCTAssertEqual(anchor(at: 64, in: accentedFirst).before, "z" + accented + String(repeating: "a", count: 60))
    }

    /// NSString counts CR and LF as two characters, so a cut between them
    /// keeps one: the quote is still cut on a character boundary.
    func testACutBetweenCRAndLFKeepsOne() {
        let text = String(repeating: "a", count: 63) + "\r\n" + "next line"
        let after = anchor(at: 0, in: text).after
        XCTAssertEqual(after.utf16.count, 64)
        XCTAssertTrue(after.hasSuffix("\r"))
        XCTAssertTrue(anchor(at: 0, in: text).stands(atOffset: 0, in: text))
    }

    /// A place inside a composed character (as a bookmark nudged clear of
    /// another can be) is captured and checked at that character's start,
    /// so it stands unchanged where it is.
    func testAPlaceInsideACharacterStandsAtItsStart() {
        let text = "see 👩‍🔬 here"
        let inside = 6  // between the emoji's scalars
        let anchor = anchor(at: inside, in: text)
        XCTAssertEqual(anchor.before, "see ")
        XCTAssertEqual(anchor.after, "👩‍🔬 here")
        XCTAssertTrue(anchor.stands(atOffset: inside, in: text))
        XCTAssertTrue(anchor.stands(atOffset: 4, in: text), "the character's start")
    }

    /// A single character longer than a whole quote is kept whole, so a
    /// quote is empty only at its chapter's edge.
    func testAQuoteIsEmptyOnlyAtItsChaptersEdge() {
        let marks = String(repeating: "\u{301}", count: 70)
        let text = "a" + marks + "b"
        let after = anchor(at: 0, in: text).after
        XCTAssertEqual(after.utf16.count, 71, "the letter and its seventy marks, whole")
        let before = anchor(at: 71, in: text).before
        XCTAssertEqual(before.utf16.count, 71)
    }

    /// The share is the place's offset through the whole book: 1 at the
    /// end of the book, which an empty quote after marks as the end.
    func testTheShareOfTheBookAndTheEndOfTheBook() {
        let middle = TextAnchor(capturingAt: 50, in: prose, chapterStart: 150, bookLength: 1_000)
        XCTAssertEqual(middle.fraction, 0.2, accuracy: 1e-12)
        XCTAssertFalse(middle.marksEndOfBook)

        let text = "The last line."
        let end = TextAnchor(capturingAt: 14, in: text, chapterStart: 986, bookLength: 1_000)
        XCTAssertEqual(end.fraction, 1)
        XCTAssertTrue(end.marksEndOfBook)

        let chapterEnd = TextAnchor(capturingAt: 14, in: text, chapterStart: 500, bookLength: 1_000)
        XCTAssertFalse(chapterEnd.marksEndOfBook, "the end of a chapter before the book's end")
        XCTAssertEqual(TextAnchor(capturingAt: 0, in: "", chapterStart: 0, bookLength: 0).fraction, 0, "an empty book")

        // The share counts the offset as given, as P07 measures a place: one
        // past its chapter's end that reaches the book's length rests at the
        // end (`Book.restsAtEnd`), and is quoted at its chapter's end.
        let pastTheEnd = TextAnchor(capturingAt: 600, in: text, chapterStart: 500, bookLength: 1_000)
        XCTAssertEqual(pastTheEnd.after, "")
        XCTAssertEqual(pastTheEnd.before, text)
        XCTAssertTrue(pastTheEnd.marksEndOfBook)
        let pastItsChapter = TextAnchor(capturingAt: 20, in: text, chapterStart: 500, bookLength: 1_000)
        XCTAssertEqual(pastItsChapter.fraction, 0.52, accuracy: 1e-12)
        XCTAssertFalse(pastItsChapter.marksEndOfBook, "past its chapter's end, short of the book's")
        XCTAssertEqual(TextAnchor(capturingAt: Int.max, in: text, chapterStart: 500, bookLength: 1_000).fraction, 1, "no overflow")
    }

    /// An anchor is captured in a book's words at a place, or not at all
    /// for a chapter the book doesn't have.
    func testCaptureInABooksWords() throws {
        let words = BookWords(texts: ["First chapter.", prose])
        let anchor = try XCTUnwrap(TextAnchor(capturingAt: TextPlace(chapter: 1, offset: 10), in: words))
        XCTAssertEqual(anchor.before, "The night ")
        XCTAssertEqual(anchor.fraction, Double(14 + 10) / Double(words.totalLength), accuracy: 1e-12)
        XCTAssertNil(TextAnchor(capturingAt: TextPlace(chapter: 2, offset: 0), in: words))
        XCTAssertNil(TextAnchor(capturingAt: TextPlace(chapter: -1, offset: 0), in: words))
    }

    // MARK: - The Direct Check

    /// An anchor stands at its place in the text it was captured in, and
    /// still does when only text beyond its quotes changed; any change
    /// inside its quotes, or a place out of range, fails it.
    func testTheDirectCheck() {
        let offset = 100
        let anchor = anchor(at: offset, in: prose)
        XCTAssertTrue(anchor.stands(atOffset: offset, in: prose))
        XCTAssertTrue(anchor.stands(at: TextPlace(chapter: 1, offset: offset), in: ["Other.", prose]))

        let changedFarAfter = prose + " A sentence added at the end."
        XCTAssertTrue(anchor.stands(atOffset: offset, in: changedFarAfter))
        let changedBefore = "Note. " + prose
        XCTAssertFalse(anchor.stands(atOffset: offset, in: changedBefore))
        XCTAssertTrue(anchor.stands(atOffset: offset + 6, in: changedBefore), "the same words, six units on")
        let changedInsideTheQuote = prose.replacingOccurrences(of: "sand hopper", with: "sand bin")
        XCTAssertFalse(anchor.stands(atOffset: offset, in: changedInsideTheQuote))

        XCTAssertFalse(anchor.stands(atOffset: -1, in: prose))
        XCTAssertFalse(anchor.stands(atOffset: prose.utf16.count + 1, in: prose))
        XCTAssertFalse(anchor.stands(at: TextPlace(chapter: 2, offset: offset), in: [prose]))
        XCTAssertFalse(anchor.stands(at: TextPlace(chapter: -1, offset: offset), in: [prose]))
    }

    /// The check compares unit for unit: the same letters spelled another
    /// way, which Swift's string equality would call equal (an accent
    /// precomposed in one place and combining in another), are a change.
    func testTheDirectCheckComparesUnitForUnit() {
        let text = "x\u{E9}e\u{301}y"
        let respelled = "xe\u{301}\u{E9}y"
        XCTAssertEqual(text, respelled, "canonically equivalent")
        let anchor = anchor(at: 4, in: text)
        XCTAssertTrue(anchor.stands(atOffset: 4, in: text))
        XCTAssertFalse(anchor.stands(atOffset: 4, in: respelled))
    }

    // MARK: - JSON

    /// An anchor survives JSON as it was.
    func testAnAnchorRoundTripsThroughJSON() throws {
        let anchor = anchor(at: 100, in: prose)
        let decoded = try JSONDecoder().decode(TextAnchor.self, from: JSONEncoder().encode(anchor))
        XCTAssertEqual(decoded, anchor)
    }

    /// An anchor decodes leniently: a field missing or of the wrong type
    /// takes its empty value, and a share outside 0 to 1 is held within
    /// it, so an older or a damaged file still loads.
    func testAnAnchorDecodesLeniently() throws {
        let decoder = JSONDecoder()
        let empty = try decoder.decode(TextAnchor.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, TextAnchor(before: "", after: "", fraction: 0, measuredIn: nil, version: 1))

        let damaged = try decoder.decode(
            TextAnchor.self,
            from: Data(#"{"before": 5, "after": "kept", "fraction": "high", "measuredIn": 3, "version": "two"}"#.utf8)
        )
        XCTAssertEqual(damaged, TextAnchor(before: "", after: "kept", fraction: 0, measuredIn: nil, version: 1))

        XCTAssertEqual(try decoder.decode(TextAnchor.self, from: Data(#"{"fraction": 7}"#.utf8)).fraction, 1)
        XCTAssertEqual(try decoder.decode(TextAnchor.self, from: Data(#"{"fraction": -2}"#.utf8)).fraction, 0)
        XCTAssertEqual(try decoder.decode(TextAnchor.self, from: Data(#"{"version": 2}"#.utf8)).version, 2, "a later format is kept")
    }
}
