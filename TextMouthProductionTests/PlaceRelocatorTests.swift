import XCTest
@testable import TextMouth

/// Moving saved places from a book's old text to its new one by a diff
/// (T06, `PlaceRelocator`): each of the measured synthetic cases in
/// miniature (restored code, link text written twice, a chapter restored,
/// moved, merged, or removed, dense edits, rewritten sentences, a passage
/// printed twice, paragraphs moved), the slides, a place in removed text,
/// the end of the book, a place found first in an old text that reads
/// differently from the text it was saved in, and the rules' edges. Each
/// case knows exactly where every word went. Pure: no window, no file.
final class PlaceRelocatorTests: XCTestCase {

    // MARK: - A Book to Rebuild

    /// The shared book's chapters (`MillBook`).
    private let millrace = MillBook.millrace
    private let wheel = MillBook.wheel
    private let stones = MillBook.stones
    private let flour = MillBook.flour

    /// The four chapters as a book.
    private var mill: [String] { [millrace, wheel, stones, flour] }

    // MARK: - Helpers

    /// One edit of a chapter's text: `inserted` in place of `removed` UTF-16
    /// units at `at`.
    private struct Edit {
        let at: Int
        let inserted: String
        var removed = 0
    }

    /// A chapter's text with its edits made, and where each old offset went.
    private struct Rebuilt {
        /// The new text.
        let text: String
        /// Where old offset `offset` went: there, and where what replaced it
        /// ends when its text was removed or replaced (else the same).
        let map: (Int) -> (start: Int, end: Int)
    }

    /// `text` with `edits` made (none overlapping), and the exact map of its
    /// offsets, as the measured cases made theirs: an offset inside removed
    /// text goes where what replaced it begins, and an offset exactly where
    /// text was put in goes past that text, so a place keeps the words that
    /// follow it.
    private func rebuilding(_ text: String, _ edits: [Edit]) -> Rebuilt {
        let old = text as NSString
        var pieces: [String] = []
        var cursor = 0
        var shifts: [(at: Int, removedEnd: Int, before: Int, after: Int, insertedLength: Int)] = []
        var delta = 0
        for edit in edits.sorted(by: { $0.at < $1.at }) where edit.at >= cursor && edit.at + edit.removed <= old.length {
            pieces.append(old.substring(with: NSRange(location: cursor, length: edit.at - cursor)))
            pieces.append(edit.inserted)
            let insertedLength = edit.inserted.utf16.count
            let before = delta
            delta += insertedLength - edit.removed
            shifts.append((edit.at, edit.at + edit.removed, before, delta, insertedLength))
            cursor = edit.at + edit.removed
        }
        pieces.append(old.substring(from: cursor))
        return Rebuilt(text: pieces.joined()) { offset in
            var applied = 0
            for shift in shifts {
                if offset < shift.at { break }
                if offset < shift.removedEnd {
                    let start = shift.at + shift.before
                    return (start, start + shift.insertedLength)
                }
                applied = shift.after
            }
            return (offset + applied, offset + applied)
        }
    }

    /// Where a place saved at `saved` in the book `old` goes in the book
    /// `new`: its anchor captured in `old`, then moved by a relocator from
    /// `old` (or from `snapshot`, the old text as a newer build reads it).
    private func relocate(_ saved: TextPlace, from old: [String], to new: [String], snapshot: [String]? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> PlaceRelocator.Result {
        let anchor = try XCTUnwrap(TextAnchor(capturingAt: saved, in: BookWords(texts: old)), file: file, line: line)
        return PlaceRelocator(oldTexts: snapshot ?? old, newTexts: new).relocate(anchor, savedAt: saved)
    }

    /// How the places of a case landed: how each was found, and how many
    /// landed a few words off.
    private struct Landings {
        var findings: [PlaceRelocator.Finding] = []
        var near = 0
    }

    /// Asserts that a place at the start of every word of `old` lands, at a
    /// word's start, on the word of `new` where `truth` says the word went,
    /// or inside what replaced it (`truth` gives the start and end of where
    /// the place's text went; nil skips the word), and that none lands by a
    /// guess unless `guessesAllowed`. With `nearAllowed`, a place may land a
    /// few words off (five at most, in the same paragraph), as the measured
    /// rules do in dense edits; the result counts them.
    @discardableResult
    private func assertEveryWordLands(
        from old: [String],
        to new: [String],
        guessesAllowed: Bool = false,
        nearAllowed: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ truth: (TextPlace) -> (start: TextPlace, end: TextPlace)?
    ) -> Landings {
        let oldWords = BookWords(texts: old)
        let relocator = PlaceRelocator(old: oldWords, new: BookWords(texts: new))
        let newWords = relocator.new
        var landings = Landings()
        for word in 0..<oldWords.count {
            let saved = oldWords.start(ofWord: word)
            guard let expected = truth(saved) else { continue }
            guard let anchor = TextAnchor(capturingAt: saved, in: oldWords) else {
                XCTFail("no anchor for word \(word)", file: file, line: line)
                continue
            }
            let result = relocator.relocate(anchor, savedAt: saved)
            let landed = newWords.word(at: result.place)
            let low = newWords.word(at: expected.start)
            let high = max(low, newWords.word(at: expected.end))
            let off = landed < low ? low - landed : max(0, landed - high)
            if off > 0, nearAllowed, off <= 5, inOneParagraph(result.place, expected.start, of: newWords) {
                landings.near += 1
            } else {
                XCTAssertEqual(off, 0, "word \(word) at \(saved) landed on word \(landed), not \(low)...\(high): \(result.finding)", file: file, line: line)
            }
            XCTAssertEqual(result.place, newWords.start(ofWord: landed), "word \(word) lands at a word's start", file: file, line: line)
            if !guessesAllowed {
                XCTAssertFalse(result.finding.isGuess, "word \(word) was a guess: \(result.finding)", file: file, line: line)
            }
            landings.findings.append(result.finding)
        }
        XCTAssertFalse(landings.findings.isEmpty, "no word was checked", file: file, line: line)
        return landings
    }

    /// Whether two places stand in one chapter with no paragraph break
    /// between them.
    private func inOneParagraph(_ a: TextPlace, _ b: TextPlace, of words: BookWords) -> Bool {
        guard a.chapter == b.chapter, words.texts.indices.contains(a.chapter) else { return false }
        let text = words.texts[a.chapter] as NSString
        let low = max(0, min(a.offset, b.offset, text.length))
        let high = min(text.length, max(a.offset, b.offset))
        return high <= low || text.range(of: "\n\n", options: .literal, range: NSRange(location: low, length: high - low)).location == NSNotFound
    }

    /// The truth for chapters each rebuilt on its own: the same chapter, at
    /// the offsets each one's map gives.
    private func truth(of rebuilt: [Rebuilt]) -> (TextPlace) -> (start: TextPlace, end: TextPlace)? {
        { place in
            guard rebuilt.indices.contains(place.chapter) else { return nil }
            let went = rebuilt[place.chapter].map(place.offset)
            return (TextPlace(chapter: place.chapter, offset: went.start), TextPlace(chapter: place.chapter, offset: went.end))
        }
    }

    /// The truth for chapters whose texts kept their words but moved between
    /// chapters: `map` gives each old place's new place exactly.
    private func exactly(_ map: @escaping (TextPlace) -> TextPlace) -> (TextPlace) -> (start: TextPlace, end: TextPlace)? {
        { place in
            let went = map(place)
            return (went, went)
        }
    }

    // MARK: - Reading the Books

    /// A relocator reads a loaded book's old and new texts, chapter by
    /// chapter.
    func testARelocatorReadsLoadedBooks() {
        let loaded = { (texts: [String]) in
            DocumentContent(title: "The Mill", author: "The Mill Society", chapters: texts.map { Chapter(title: "", text: $0) })
        }
        let new = [millrace, wheel, stones]
        let relocator = PlaceRelocator(old: loaded(mill), new: loaded(new))
        XCTAssertEqual(relocator.old.texts, mill)
        XCTAssertEqual(relocator.new.texts, new)
    }

    // MARK: - Restored Code

    /// Code an older extraction left out, restored: a block before a
    /// paragraph and a span inside the words that follow a place. Every
    /// place stays on its own word, past the code put in before it.
    func testRestoredCodeEveryPlaceOnItsOwnWord() throws {
        let block = "let paddles = wheel.paddles.filter { $0.isSplit }\nprint(paddles.count)\n\n"
        let one = rebuilding(millrace, [Edit(at: try Phrase.offset(of: "a borrowed pump", in: millrace), inserted: "pumpRate(at:) ")])
        let two = rebuilding(wheel, [Edit(at: try Phrase.offset(of: "He charged", in: wheel), inserted: block)])
        let three = rebuilding(stones, [])
        let four = rebuilding(flour, [])
        let findings = assertEveryWordLands(from: mill, to: [one.text, two.text, three.text, four.text], truth(of: [one, two, three, four])).findings
        XCTAssertTrue(findings.allSatisfy { $0 == .unchanged || $0 == .movedByTheDiff(.linedUp) }, "\(Set(findings.map { "\($0)" }))")
    }

    // MARK: - Link Text Written Twice

    /// Link text an older extraction wrote twice ("the granary wall the
    /// granary wall"), written once. Either copy may be the one the diff
    /// finds removed: a place in the removed copy keeps the words that follow
    /// it, which now stand in the copy kept, so it lands there, word for
    /// word, a few words before where the removed text was (the measured
    /// rules' "near" for link text). Every other place stays on its own word.
    func testLinkTextNoLongerWrittenTwice() throws {
        let copy = "the granary wall"
        let wall = try Phrase.offset(of: "granary wall", in: stones) + "granary wall".utf16.count
        let doubled = rebuilding(stones, [Edit(at: wall, inserted: " " + copy)])
        let old = [millrace, wheel, doubled.text, flour]
        let removedCopy = try Phrase.offset(of: copy, in: doubled.text, occurrence: 1)
        let keptCopy = try Phrase.place(of: copy, inChapter: 2, of: mill)
        assertEveryWordLands(from: old, to: mill) { place in
            guard place.chapter == 2, place.offset >= wall else { return (place, place) }
            let went = place.offset < removedCopy + copy.utf16.count
                ? TextPlace(chapter: 2, offset: keptCopy.offset + place.offset - removedCopy)
                : TextPlace(chapter: 2, offset: place.offset - copy.utf16.count - 1)
            return (went, went)
        }
        let first = try relocate(TextPlace(chapter: 2, offset: removedCopy), from: old, to: mill)
        XCTAssertEqual(first, PlaceRelocator.Result(place: keptCopy, finding: .movedByTheDiff(.linedUp)))
    }

    /// alice.docx's licence as 3.0.2 read it ("www.gutenberg.orgwww.gutenberg.org")
    /// and as 3.0.3 reads it: every place outside the link stays on its own
    /// word, and every place in the link stays in the link.
    func testARealLinkWrittenTwiceKeepsItsPlacesInTheLink() throws {
        let old = [TextAnchorRealReadings.linkedParagraph302]
        let new = [TextAnchorRealReadings.linkedParagraph303]
        let linkStart = try Phrase.offset(of: "www.gutenberg.org", in: old[0])
        let linkEnd = try Phrase.offset(of: ". If you", in: old[0])
        let newLinkStart = TextPlace(chapter: 0, offset: try Phrase.offset(of: "www.gutenberg.org", in: new[0]))
        let newLinkEnd = TextPlace(chapter: 0, offset: try Phrase.offset(of: ". If you", in: new[0]))
        let after = (try Phrase.offset(of: ". If you", in: new[0])) - linkEnd
        assertEveryWordLands(from: old, to: new) { place in
            if place.offset < linkStart { return (place, place) }
            if place.offset < linkEnd { return (newLinkStart, newLinkEnd) }
            let went = TextPlace(chapter: 0, offset: place.offset + after)
            return (went, went)
        }
    }

    // MARK: - Chapters Restored, Moved, Merged, and Removed

    /// A chapter an older extraction dropped, restored: every place after it
    /// moves to its own chapter, and the place at "CHAPTER IV." stays with
    /// the words that follow it rather than going to the "CHAPTER" that now
    /// begins chapter III.
    func testARestoredChapterEveryPlaceOnItsOwnWord() throws {
        let old = [millrace, wheel, flour]
        let findings = assertEveryWordLands(from: old, to: mill, exactly { place in
            TextPlace(chapter: place.chapter >= 2 ? place.chapter + 1 : place.chapter, offset: place.offset)
        }).findings
        XCTAssertTrue(findings.allSatisfy { $0 == .unchanged || $0 == .movedByTheDiff(.linedUp) })
        let chapterFour = try relocate(TextPlace(chapter: 2, offset: 0), from: old, to: mill)
        XCTAssertEqual(chapterFour, PlaceRelocator.Result(place: TextPlace(chapter: 3, offset: 0), finding: .movedByTheDiff(.linedUp)))
    }

    /// A chapter boundary an older extraction put a paragraph too late (the
    /// next chapter's heading and first paragraph ran on in the chapter
    /// before), corrected: every place moves to its own chapter.
    func testAMovedChapterBoundaryEveryPlaceOnItsOwnWord() throws {
        let cut = try Phrase.offset(of: "In June", in: stones)
        let movedPart = (stones as NSString).substring(to: cut).trimmingCharacters(in: .newlines)
        let joint = wheel.utf16.count + 2
        let old = [millrace, wheel + "\n\n" + movedPart, (stones as NSString).substring(from: cut), flour]
        assertEveryWordLands(from: old, to: mill, exactly { place in
            switch place.chapter {
            case 1 where place.offset >= joint: return TextPlace(chapter: 2, offset: place.offset - joint)
            case 2: return TextPlace(chapter: 2, offset: place.offset + cut)
            default: return place
            }
        })
    }

    /// Two chapters an older extraction ran together, read apart: every
    /// place moves to its own chapter.
    func testMergedChaptersEveryPlaceOnItsOwnWord() throws {
        let joint = wheel.utf16.count + 2
        let old = [millrace, wheel + "\n\n" + stones, flour]
        assertEveryWordLands(from: old, to: mill, exactly { place in
            switch place.chapter {
            case 1 where place.offset >= joint: return TextPlace(chapter: 2, offset: place.offset - joint)
            case 2: return TextPlace(chapter: 3, offset: place.offset)
            default: return place
            }
        })
    }

    /// A chapter the new text leaves out: a place in it goes where the text
    /// after it begins, the start of "CHAPTER IV.", slid back over the
    /// "CHAPTER" that both the removed chapter and the text before it end
    /// with (the diff keeps the first copy and drops the second); every other
    /// place stays on its own word.
    func testARemovedChapterSendsItsPlacesWhereTheTextAfterItBegins() throws {
        let new = [millrace, wheel, flour]
        let findings = assertEveryWordLands(from: mill, to: new, exactly { place in
            switch place.chapter {
            case 2: return TextPlace(chapter: 2, offset: 0)
            case 3: return TextPlace(chapter: 2, offset: place.offset)
            default: return place
            }
        }).findings
        XCTAssertTrue(findings.contains(.movedByTheDiff(.passageRemoved)))
        let inRemoved = try relocate(try Phrase.place(of: "photograph", inChapter: 2, of: mill), from: mill, to: new)
        XCTAssertEqual(inRemoved, PlaceRelocator.Result(place: TextPlace(chapter: 2, offset: 0), finding: .movedByTheDiff(.passageRemoved)))
    }

    // MARK: - Edits

    /// An edit pass as dense as one word in ten (replaced, removed, or
    /// followed by a new word), as Edit Text or a corrected scan makes:
    /// nearly every place stays on its own word, or lands where what
    /// replaced it begins, and none lands more than a few words off in its
    /// paragraph. (The measured rules put 130 of 24,446 places a few words
    /// off in this case: a removed "the" keeps the words after it by an
    /// earlier "the" a few words back, and the book's last words, with an
    /// edit among them and no solid match after, are a guess.)
    func testDenseEditsEveryPlaceOnItsOwnWordOrWhatReplacedIt() throws {
        let fresh = ["quiddle", "brannock", "fettle", "osier", "pellucid", "gimbal", "tamarack", "wainscot"]
        let rebuilt = mill.enumerated().map { chapter, text -> Rebuilt in
            var edits: [Edit] = []
            var index = 0
            // Each run between spaces after the heading, one in ten edited.
            let words = (text as NSString).components(separatedBy: " ")
            var at = 0
            for word in words {
                defer { at += word.utf16.count + 1 }
                index += 1
                guard index > 4, index % 10 == chapter % 10, !word.contains("\n") else { continue }
                let new = fresh[index % fresh.count]
                switch index / 10 % 3 {
                case 0: edits.append(Edit(at: at, inserted: new, removed: word.utf16.count))
                case 1: edits.append(Edit(at: at, inserted: "", removed: word.utf16.count + 1))
                default: edits.append(Edit(at: at + word.utf16.count, inserted: " " + new))
                }
            }
            return rebuilding(text, edits)
        }
        let landings = assertEveryWordLands(from: mill, to: rebuilt.map(\.text), guessesAllowed: true, nearAllowed: true, truth(of: rebuilt))
        XCTAssertTrue(landings.findings.contains(.movedByTheDiff(.wordReplaced)), "some words were replaced or dropped")
        XCTAssertLessThanOrEqual(landings.near * 20, landings.findings.count, "at most one place in twenty a few words off")
    }

    /// Sentences rewritten, a run of words replaced by as many new ones: a
    /// place in the rewritten run lands where its replacement begins, and
    /// every other place stays on its own word.
    func testRewrittenSentencesEveryPlaceOnItsOwnWordOrItsReplacement() throws {
        let photograph = "a photograph from the war showed both of them leaning against the granary wall"
        let ninety = "who was ninety, sat on an upturned crate by the hopper"
        let three = rebuilding(stones, [Edit(at: try Phrase.offset(of: photograph, in: stones), inserted: "a dealer in Ludlow claimed he had sold one of them to a garden centre near the bypass", removed: photograph.utf16.count)])
        let four = rebuilding(flour, [Edit(at: try Phrase.offset(of: ninety, in: flour), inserted: "whose knees would not let him crouch, leaned on the doorframe with his stick", removed: ninety.utf16.count)])
        let findings = assertEveryWordLands(from: mill, to: [millrace, wheel, three.text, four.text], truth(of: [rebuilding(millrace, []), rebuilding(wheel, []), three, four])).findings
        XCTAssertTrue(findings.contains(.movedByTheDiff(.wordReplaced)) || findings.contains(.movedByTheDiff(.passageRemoved)))
    }

    // MARK: - A Passage Printed Twice

    /// A passage the book prints twice, as a licence at both ends, with one
    /// copy edited: each place stays in its own copy, the edited one or the
    /// one left alone, never the other.
    func testAPassagePrintedTwiceWithOneCopyEditedKeepsEachPlaceInItsCopy() throws {
        let edits = try ["cleared", "spirit", "string", "packet"].map { word in
            Edit(at: try Phrase.offset(of: word, in: millrace), inserted: "osier", removed: word.utf16.count)
        }
        let edited = rebuilding(millrace, edits)
        let old = mill + [millrace]
        let new = [edited.text, wheel, stones, flour, millrace]
        assertEveryWordLands(from: old, to: new) { place in
            if place.chapter == 0 {
                let went = edited.map(place.offset)
                return (TextPlace(chapter: 0, offset: went.start), TextPlace(chapter: 0, offset: went.end))
            }
            return (place, place)
        }
    }

    // MARK: - Paragraphs Moved

    /// The shared book's chapter of short paragraphs.
    private let granary = MillBook.granary

    /// Paragraphs moved elsewhere in their chapter, as a corrected extraction
    /// might move a footnote: a place in them follows its words, which the
    /// diff sees as removed there and put in here.
    func testMovedParagraphsAreFollowedIntoTheTextPutIn() throws {
        let moved = "Odo, a retired surveyor, drew the floor plan on squared paper and marked the rotten joists in red ink.\n\n"
        let start = try Phrase.offset(of: moved, in: granary)
        let removed = rebuilding(granary, [Edit(at: start, inserted: "", removed: moved.utf16.count)])
        let new = removed.text + "\n\n" + moved.trimmingCharacters(in: .newlines)
        let movedTo = removed.text.utf16.count + 2
        let findings = assertEveryWordLands(from: [granary], to: [new]) { place in
            if place.offset >= start, place.offset < start + moved.utf16.count {
                let went = TextPlace(chapter: 0, offset: movedTo + place.offset - start)
                return (went, went)
            }
            let went = TextPlace(chapter: 0, offset: removed.map(place.offset).start)
            return (went, went)
        }.findings
        XCTAssertTrue(findings.contains(.movedByTheDiff(.followedMovedText)))
    }

    /// A place whose words are gone from their spot is never followed to a
    /// copy of them the diff kept: a notice printed in two places, one of
    /// them removed, sends its places where the removed copy was.
    func testMovedTextIsNeverFollowedToACopyTheDiffKept() throws {
        let notice = "Volunteers are asked to wipe their boots on the sacking before they climb the granary ladder.\n\n"
        let marker = try Phrase.offset(of: "The bats", in: granary)
        let old = granary + "\n\n" + notice.trimmingCharacters(in: .newlines)
        let withNotice = (old as NSString).replacingCharacters(in: NSRange(location: marker, length: 0), with: notice)
        let new = old
        let noticeStart = try Phrase.place(of: "Volunteers are asked", inChapter: 0, of: [withNotice])
        let result = try relocate(TextPlace(chapter: 0, offset: noticeStart.offset + "Volunteers are ".utf16.count), from: [withNotice], to: [new])
        XCTAssertEqual(result.place, try Phrase.place(of: "The bats", inChapter: 0, of: [new]), "where the removed copy was, not in the copy kept")
        XCTAssertEqual(result.finding, .movedByTheDiff(.passageRemoved))
    }

    /// A word replaced in place is replaced, not moved (REV15, finding 5):
    /// the words before it still stand, but its own words ("frogspawn
    /// floated") stand nowhere now, so the moved-text rule does not follow
    /// the words before it.
    func testAWordReplacedInPlaceIsNotFollowedAsMovedText() throws {
        let new = [millrace.replacingOccurrences(of: "frogspawn", with: "duckweed"), wheel, stones, flour]
        let result = try relocate(try Phrase.place(of: "frogspawn", inChapter: 0, of: mill), from: mill, to: new)
        XCTAssertEqual(result, PlaceRelocator.Result(place: try Phrase.place(of: "duckweed", inChapter: 0, of: new), finding: .movedByTheDiff(.wordReplaced)))
    }

    /// A word the diff pairs by chance is no solid match: a paragraph moved
    /// to its chapter's end, with a short note left in its place that shares
    /// one of its words ("the"), is followed word for word, the "the" the
    /// diff paired with the note's among them.
    func testAWordPairedByChanceIsNoSolidMatch() throws {
        let moved = "Odo, a retired surveyor, drew the floor plan on squared paper and marked the rotten joists in red ink.\n\n"
        let note = "See the note.\n\n"
        let start = try Phrase.offset(of: moved, in: granary)
        let replaced = rebuilding(granary, [Edit(at: start, inserted: note, removed: moved.utf16.count)])
        let new = replaced.text + "\n\n" + moved.trimmingCharacters(in: .newlines)
        let movedTo = replaced.text.utf16.count + 2
        let findings = assertEveryWordLands(from: [granary], to: [new]) { place in
            if place.offset >= start, place.offset < start + moved.utf16.count {
                let went = TextPlace(chapter: 0, offset: movedTo + place.offset - start)
                return (went, went)
            }
            let went = TextPlace(chapter: 0, offset: replaced.map(place.offset).start)
            return (went, went)
        }.findings
        XCTAssertTrue(findings.contains(.movedByTheDiff(.followedMovedText)))
    }

    // MARK: - The Slides

    /// Text put in before a place that begins with the place's own words
    /// does not take it: "CHAPTER" before "CHAPTER XIX." when chapter XVIII
    /// comes back, within one chapter's text.
    func testTextPutInThatBeginsWithAPlacesWordsDoesNotTakeIt() throws {
        let seventeen = "CHAPTER XVII.\n\nThe treasurer bought a second-hand anemometer for the roof, though nobody could say why a mill needed one.\n\n"
        let eighteen = "CHAPTER XVIII.\n\nThe county archaeologist visited in a borrowed van and photographed the wheel pit from every side.\n\n"
        let nineteen = "CHAPTER XIX.\n\nThe last job of the year was oiling the gears, which took two people, a ladder, and most of a Sunday."
        let old = [seventeen + nineteen]
        let new = [seventeen + eighteen + nineteen]
        let result = try relocate(try Phrase.place(of: "CHAPTER XIX.", inChapter: 0, of: old), from: old, to: new)
        XCTAssertEqual(result, PlaceRelocator.Result(place: try Phrase.place(of: "CHAPTER XIX.", inChapter: 0, of: new), finding: .movedByTheDiff(.linedUp)))
        let inserted = seventeen.utf16.count
        assertEveryWordLands(from: old, to: new, exactly { place in
            TextPlace(chapter: 0, offset: place.offset < inserted ? place.offset : place.offset + eighteen.utf16.count)
        })
    }

    /// Text put in before a place that begins with two or more of the
    /// place's words does not take it either, though the diff lines those
    /// words up with the text put in (REV15, finding 7): "BOOK ONE. CHAPTER
    /// II." restored before "BOOK ONE. CHAPTER III.", within one chapter's
    /// text and as a chapter of its own, and a sentence beginning "The
    /// captain" put in before "The captain waved once".
    func testTextPutInThatBeginsWithSeveralOfAPlacesWordsDoesNotTakeIt() throws {
        let one = "BOOK ONE. CHAPTER I. The Press\n\nThe shop on Tanner Lane had printed handbills for forty years before Ottilie bought it with her brother's insurance money. She kept the old platen press and learned to set type by candlelight when the landlord cut the gas."
        let two = "BOOK ONE. CHAPTER II. The Apprentice\n\nDesmond arrived in March with a cardboard suitcase and a letter from the parish clerk. He could read upside down and backwards, which in a print shop is worth more than a diploma."
        let three = "BOOK ONE. CHAPTER III. The Strike\n\nWhen the dockers walked out in August, every union hall in the city wanted leaflets by morning. Ottilie ran the press for nineteen hours straight."
        let four = "BOOK ONE. CHAPTER IV. Proofs\n\nThe police came on the third day, polite and unhurried, and asked to see the proofs. She showed them a stack of church bulletins."
        let joined = { (chapters: [String]) in [chapters.joined(separator: "\n\n")] }
        let oneText = joined([one, three, four])
        let oneTextRestored = joined([one, two, three, four])
        let result = try relocate(try Phrase.place(of: "BOOK ONE. CHAPTER III.", inChapter: 0, of: oneText), from: oneText, to: oneTextRestored)
        XCTAssertEqual(result, PlaceRelocator.Result(place: try Phrase.place(of: "BOOK ONE. CHAPTER III.", inChapter: 0, of: oneTextRestored), finding: .movedByTheDiff(.linedUp)))
        let chapters = try relocate(TextPlace(chapter: 1, offset: 0), from: [one, three, four], to: [one, two, three, four])
        XCTAssertEqual(chapters, PlaceRelocator.Result(place: TextPlace(chapter: 2, offset: 0), finding: .movedByTheDiff(.linedUp)))
        let insertedAt = one.utf16.count + 2
        assertEveryWordLands(from: oneText, to: oneTextRestored, exactly { place in
            TextPlace(chapter: 0, offset: place.offset < insertedAt ? place.offset : place.offset + two.utf16.count + 2)
        })

        let before = "The ferry left the pier at half past six, loaded with crates of onions and two bicycles. "
        let sentence = "The captain waved once from the wheelhouse and then ignored everyone until the island showed itself. "
        let after = "By then the onions had begun to smell, and the bicycles had fallen over twice."
        for inserted in [
            "The captain kept a terrier that slept on the coiled ropes and growled at anyone wearing a hat. ",
            "The captain waved his cap at the harbour wall as if someone there owed him money. ",
        ] {
            let old = [before + sentence + after]
            let new = [before + inserted + sentence + after]
            let moved = try relocate(try Phrase.place(of: "The captain waved once", inChapter: 0, of: old), from: old, to: new)
            XCTAssertEqual(moved.place, try Phrase.place(of: "The captain waved once", inChapter: 0, of: new), inserted)
            XCTAssertEqual(moved.finding, .movedByTheDiff(.linedUp), inserted)
        }
    }

    /// A kept place never jumps back across a solid match to an earlier copy
    /// of its words (REV15, V15): a place in the second of two copies of a
    /// line, which the new text removes, goes where the text after the
    /// removal begins, not to the first copy; and a place in a chapter's
    /// opening line that repeats the last line of the chapter before, which
    /// the new text removes, stays in its own chapter.
    func testAKeptPlaceNeverJumpsBackAcrossASolidMatch() throws {
        let lead = "The ferry from the island was forty minutes late, and the harbourmaster came out at last with a clipboard pressed to his chest. "
        let twenty = "\"Twenty minutes,\" he said."
        let tail = "A woman with a crate of laying hens laughed out loud and sat down on the crate."
        let old = [lead + twenty + " Nobody in the queue moved. " + twenty + " " + tail]
        let new = [lead + twenty + " Nobody in the queue moved. " + tail]
        let womanStart = try Phrase.place(of: "A woman", inChapter: 0, of: new)
        let removedCopy = try Phrase.offset(of: twenty, in: old[0], occurrence: 1)
        for phrase in ["\"Twenty", "Twenty", "minutes", "he said", "said"] {
            let saved = TextPlace(chapter: 0, offset: removedCopy + (try Phrase.offset(of: phrase, in: twenty)))
            let result = try relocate(saved, from: old, to: new)
            XCTAssertEqual(result.place, womanStart, phrase)
            XCTAssertFalse(result.finding.isGuess, phrase)
        }

        let chapterOne = "CHAPTER ONE. The Barge Fair\n\nShe bolted the scullery door, pinched out the candle, and stood a long time at the window watching the barges tie up below the lock. \"Tomorrow, then,\" she said."
        let heading = "CHAPTER TWO. Low Water\n\n"
        let body = "The river had dropped in the night, and the barges lay canted in the mud like boots kicked off at a door."
        let repeated = [chapterOne, heading + "\"Tomorrow, then,\" she said. " + body]
        let removed = [chapterOne, heading + body]
        for phrase in ["Tomorrow", "she said"] {
            let result = try relocate(try Phrase.place(of: phrase, inChapter: 1, of: repeated), from: repeated, to: removed)
            XCTAssertEqual(result.place, TextPlace(chapter: 1, offset: heading.utf16.count), phrase)
        }
    }

    /// A removal ending as the text before it ends ("CHAPTER" ends both the
    /// text before chapter XVIII and the chapter removed) slides back: a
    /// place in the removed chapter goes to "CHAPTER XIX.", not a word into
    /// it.
    func testARemovalEndingAsTheTextBeforeItEndsSlidesBack() throws {
        let seventeen = "CHAPTER XVII.\n\nThe treasurer bought a second-hand anemometer for the roof, though nobody could say why a mill needed one.\n\n"
        let eighteen = "CHAPTER XVIII.\n\nThe county archaeologist visited in a borrowed van and photographed the wheel pit from every side.\n\n"
        let nineteen = "CHAPTER XIX.\n\nThe last job of the year was oiling the gears, which took two people, a ladder, and most of a Sunday."
        let old = [seventeen + eighteen + nineteen]
        let new = [seventeen + nineteen]
        let nineteenStart = try Phrase.place(of: "CHAPTER XIX.", inChapter: 0, of: new)
        for phrase in ["CHAPTER XVIII.", "archaeologist", "every side", "CHAPTER XIX."] {
            let result = try relocate(try Phrase.place(of: phrase, inChapter: 0, of: old), from: old, to: new)
            XCTAssertEqual(result.place, nineteenStart, phrase)
            XCTAssertFalse(result.finding.isGuess, phrase)
        }
    }

    // MARK: - The End of the Book

    /// A place at the end of the book stays at the end of the new text,
    /// whatever was added or removed at the end (P07's finished book).
    func testTheEndOfTheBookStaysTheEnd() throws {
        let end = TextPlace(chapter: 3, offset: flour.utf16.count)
        let epilogue = mill + ["EPILOGUE\n\nThe mill opens to visitors on the first Sunday of each month, flood permitting."]
        let longer = try relocate(end, from: mill, to: epilogue)
        XCTAssertEqual(longer, PlaceRelocator.Result(place: TextPlace(chapter: 4, offset: epilogue.last?.utf16.count ?? -1), finding: .movedByTheDiff(.endOfBook)))

        let lastParagraph = try Phrase.offset(of: "\n\nThe miller's grandson", in: flour)
        let shorter = [millrace, wheel, stones, (flour as NSString).substring(to: lastParagraph)]
        let cut = try relocate(end, from: mill, to: shorter)
        XCTAssertEqual(cut, PlaceRelocator.Result(place: TextPlace(chapter: 3, offset: lastParagraph), finding: .movedByTheDiff(.endOfBook)))

        XCTAssertEqual(try relocate(end, from: mill, to: mill), PlaceRelocator.Result(place: end, finding: .unchanged))
    }

    /// A place with no word after it in the old text (before the closing
    /// full stop) is at the end of the book: when the text around it
    /// changes, it goes to the end of the new text.
    func testAPlaceAfterTheLastWordGoesToTheNewEnd() throws {
        let beforeStop = TextPlace(chapter: 3, offset: try Phrase.offset(of: "too close.", in: flour) + "too close".utf16.count)
        XCTAssertEqual((flour as NSString).substring(from: beforeStop.offset), ".", "the closing full stop")
        let changed = [millrace, wheel, stones, flour.replacingOccurrences(of: "too close.", with: "too close together.")]
        let result = try relocate(beforeStop, from: mill, to: changed)
        XCTAssertEqual(result, PlaceRelocator.Result(place: TextPlace(chapter: 3, offset: changed.last?.utf16.count ?? -1), finding: .movedByTheDiff(.endOfBook)))
    }

    /// A place at the end of an earlier chapter stands just after that
    /// chapter's last word: with a chapter restored after it, it stays at
    /// its chapter's end rather than going to the restored chapter's end or
    /// the next chapter's start; with text added at its chapter's end, it
    /// stays before what was added.
    func testAPlaceAtItsChaptersEndStaysJustAfterItsLastWord() throws {
        // The chapter's last words change too, so the place's words no longer
        // stand at its numbers and the diff carries it.
        let edited = wheel.replacingOccurrences(of: "He charged nothing", with: "He never charged")
        let old = [millrace, wheel, flour]
        let end = TextPlace(chapter: 1, offset: wheel.utf16.count)
        let restored = try relocate(end, from: old, to: [millrace, edited, stones, flour])
        XCTAssertEqual(restored, PlaceRelocator.Result(place: TextPlace(chapter: 1, offset: edited.utf16.count), finding: .movedByTheDiff(.linedUp)))

        let added = edited + " The spoons outsold the jam."
        let extended = try relocate(end, from: old, to: [millrace, added, flour])
        XCTAssertEqual(extended, PlaceRelocator.Result(place: TextPlace(chapter: 1, offset: try Phrase.offset(of: "The spoons", in: added)), finding: .movedByTheDiff(.linedUp)))
    }

    // MARK: - The Old Text

    /// A place whose old text, as this build reads it, differs from the text
    /// it was saved in (an older build ran a contents list together) is
    /// found there by its words first, and then carried by the diff.
    func testAPlaceSavedInAnotherReadingIsFoundInTheOldTextFirst() throws {
        let savedIn = [TextAnchorRealReadings.contents304]
        let oldReading = [TextAnchorRealReadings.contents307]
        let new = [TextAnchorRealReadings.contents307.replacingOccurrences(of: "Contents\n\n", with: "Contents\n\nA list of the twelve chapters.\n\n")]
        let saved = try Phrase.place(of: "A Caucus-Race", inChapter: 0, of: savedIn)
        let result = try relocate(saved, from: savedIn, to: new, snapshot: oldReading)
        XCTAssertEqual(result, PlaceRelocator.Result(place: try Phrase.place(of: "A Caucus-Race", inChapter: 0, of: new), finding: .movedByTheDiff(.linedUp)))
    }

    /// A place saved without words is taken to stand at its numbers in the
    /// old text; its words are read there, and the diff carries it.
    func testAPlaceSavedWithoutWordsIsReadAtItsNumbersInTheOldText() throws {
        let old = [millrace, wheel, flour]
        let saved = try Phrase.place(of: "frost", inChapter: 1, of: old)
        let relocator = PlaceRelocator(oldTexts: old, newTexts: mill.map { $0.replacingOccurrences(of: "eleven feet", with: "twelve feet") })
        let result = relocator.relocate(nil, savedAt: saved)
        XCTAssertEqual(result, PlaceRelocator.Result(place: try Phrase.place(of: "frost", inChapter: 1, of: relocator.new.texts), finding: .movedByTheDiff(.linedUp)))
    }

    /// A place inside a word keeps how far into the word it was.
    func testAPlaceInsideAWordKeepsItsPlaceInTheWord() throws {
        let saved = try Phrase.place(of: "millstone", inChapter: 2, of: mill)
        let inside = TextPlace(chapter: 2, offset: saved.offset + 4)
        let new = [millrace, wheel, stones.replacingOccurrences(of: "Nobody knew", with: "For a whole season nobody knew"), flour]
        let result = try relocate(inside, from: mill, to: new)
        let moved = try Phrase.place(of: "millstone", inChapter: 2, of: new)
        XCTAssertEqual(result, PlaceRelocator.Result(place: TextPlace(chapter: 2, offset: moved.offset + 4), finding: .movedByTheDiff(.linedUp)))
    }

    // MARK: - When the Diff Is Unsure

    /// Where the diff is unsure (a removal at the start of the book, with
    /// solid matches after it only) and the saved words find only a weak
    /// match far from its answer, the diff's answer is the guess: a place in
    /// a removed foreword goes to the start of what follows, not to a ledger
    /// line that happens to share its words.
    func testAWeakMatchFarAwayDoesNotOverruleTheDiffsUnsureAnswer() throws {
        let ledger = (1...400).map { "Ledger line \($0) recorded \($0 * 3) sacks of barley." }.joined(separator: " ")
        let foreword = "A NOTE ON THE LEDGER\n\nThe last page of the old ledger, kept in the vestry, reads: Ledger line 300 recorded 900 sacks of barley. Nobody has found the page that came before it."
        let old = [foreword] + mill + [ledger]
        let new = mill + [ledger]
        let result = try relocate(try Phrase.place(of: "Ledger line 300", inChapter: 0, of: old), from: old, to: new)
        XCTAssertEqual(result, PlaceRelocator.Result(place: TextPlace(chapter: 0, offset: 0), finding: .guessed(.diffUnsure)))
    }

    // MARK: - Odd Input

    /// Places and texts no book holds never trap: negative numbers, a
    /// chapter past the end, an offset past its chapter, an empty anchor,
    /// and old or new texts without chapters or without words.
    func testOddInputNeverTraps() {
        let empty = TextAnchor(before: "", after: "", fraction: 0)
        let anchor = TextAnchor(before: "with spades, ", after: "a borrowed pump", fraction: 0.1)
        let places = [TextPlace(chapter: -1, offset: -5), TextPlace(chapter: 9, offset: 3), TextPlace(chapter: 0, offset: 99_999), TextPlace(chapter: 1, offset: 4)]
        let books: [[String]] = [[], [""], ["", ""], ["🙂 é", ""], mill]
        for old in books {
            for new in books {
                let relocator = PlaceRelocator(oldTexts: old, newTexts: new)
                for saved in places {
                    for anchor in [nil, empty, anchor] {
                        let result = relocator.relocate(anchor, savedAt: saved)
                        if relocator.new.chapterCount > 0 {
                            XCTAssertTrue((0..<relocator.new.chapterCount).contains(result.place.chapter) || result.finding == .unchanged)
                        }
                    }
                }
            }
        }
    }
}
