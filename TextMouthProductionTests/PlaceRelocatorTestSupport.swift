import XCTest
@testable import TextMouth

/// The book the place relocator's tests rebuild (T06, `PlaceRelocator`): a
/// mill's restoration by volunteers, in chapters with words common to all
/// of them ("the", "CHAPTER") and words each holds once, as a book's text
/// has.
enum MillBook {
    /// Chapter I.
    static let millrace = "CHAPTER I. The Millrace\n\n"
        + "The volunteers met at the mill on the first dry Saturday of March, with spades, a borrowed pump, and a flask of soup that Hesketh guarded as if it were the parish silver. "
        + "The millrace had silted to the height of a boot, and frogspawn floated in the shallows by the sluice.\n\n"
        + "By noon they had cleared forty yards of channel. Nell measured the fall with a spirit level and a length of string, and wrote the figures on the back of a seed packet, which she lost by teatime."
    /// Chapter II.
    static let wheel = "CHAPTER II. The Wheel\n\n"
        + "The wheel itself was oak, eleven feet across, its paddles split where the frost had worked into them. "
        + "A carpenter from the valley came on Tuesdays to fit new ones, steaming each plank over a tin bath until it would bend.\n\n"
        + "He charged nothing, but asked to keep the offcuts, which he turned into spoons and sold at the Thursday market under a hand-painted sign."
    /// Chapter III.
    static let stones = "CHAPTER III. The Stones\n\n"
        + "Nobody knew where the upper millstone had gone. The parish records listed a pair of French burrs bought in 1871, "
        + "and a photograph from the war showed both of them leaning against the granary wall.\n\n"
        + "In June a farmer ploughing above the weir struck something that rang like a dropped pan. It was the missing stone, face down in the clay, with a hawthorn growing through its eye."
    /// Chapter IV.
    static let flour = "CHAPTER IV. First Flour\n\n"
        + "They ground their first sack of wheat on the longest day of the year. The flour came out warm and speckled, and Hesketh baked it into loaves as heavy as paving slabs, which were gone within the hour.\n\n"
        + "The miller's grandson, who was ninety, sat on an upturned crate by the hopper and told them, kindly, that they were running the stones too close."
    /// A chapter of several short paragraphs, for paragraphs moved.
    static let granary = "CHAPTER V. The Granary\n\n"
        + "The granary roof leaked in four places, and the volunteers set out buckets under each one before every meeting.\n\n"
        + "Odo, a retired surveyor, drew the floor plan on squared paper and marked the rotten joists in red ink.\n\n"
        + "Someone donated a dehumidifier that hummed so loudly the treasurer had to read the accounts twice over.\n\n"
        + "The bats in the eaves were protected, so every repair waited until the colony left for its winter roost.\n\n"
        + "By November the floor was sound enough to hold the cleaned millstones, which rested on pallets under a tarpaulin."

    /// Chapters I to IV.
    static var chapters: [String] { [millrace, wheel, stones, flour] }

    /// Chapters XVII to XIX of a later part of the book, as one chapter's
    /// text reads them: two chapters whose "CHAPTER" ends the text before
    /// the next, for text put in or removed between them.
    static let seventeen = "CHAPTER XVII.\n\nThe treasurer bought a second-hand anemometer for the roof, though nobody could say why a mill needed one.\n\n"
    /// See `seventeen`.
    static let eighteen = "CHAPTER XVIII.\n\nThe county archaeologist visited in a borrowed van and photographed the wheel pit from every side.\n\n"
    /// See `seventeen`.
    static let nineteen = "CHAPTER XIX.\n\nThe last job of the year was oiling the gears, which took two people, a ladder, and most of a Sunday."

    /// A long ledger of like lines, each with numbers of its own: text whose
    /// words stand many times, for saved words met by chance far away.
    static let ledger = (1...400).map { "Ledger line \($0) recorded \($0 * 3) sacks of barley." }.joined(separator: " ")

    /// The headings of a book whose chapters are `texts`: each chapter that
    /// begins "CHAPTER" has a heading of `level` at its start, labelled with
    /// its first line, as the app's readers make them.
    static func headings(of texts: [String], level: Int = 1) -> [Heading] {
        texts.enumerated().compactMap { index, text in
            guard text.hasPrefix("CHAPTER"), let label = text.components(separatedBy: "\n").first else { return nil }
            return Heading(level: level, text: label, chapterIndex: index, characterOffset: 0)
        }
    }

    /// The heading `headings(of:)` gives chapter `chapter` of `texts`.
    static func heading(ofChapter chapter: Int, in texts: [String], file: StaticString = #filePath, line: UInt = #line) throws -> Heading {
        try XCTUnwrap(headings(of: texts).first { $0.chapterIndex == chapter }, "no heading in chapter \(chapter)", file: file, line: line)
    }
}

/// A test that reads the mill book's chapters by their names (`MillBook`).
protocol MillBookReading {}

extension MillBookReading {
    /// Chapter I.
    var millrace: String { MillBook.millrace }
    /// Chapter II.
    var wheel: String { MillBook.wheel }
    /// Chapter III.
    var stones: String { MillBook.stones }
    /// Chapter IV.
    var flour: String { MillBook.flour }
    /// Chapters I to IV as a book.
    var mill: [String] { MillBook.chapters }
}

/// Saved places for the relocator tests, with their words captured as this
/// build captures them.
enum SavedPlace {
    /// When the relocator tests move a book's places
    /// (`PlaceRelocator.relocate(_:movedAt:)`): a fixed time, later than any
    /// a test saves a place at.
    static let moveDate = Date(timeIntervalSince1970: 1_800_000_000)

    /// The anchor of `place` in the book whose chapters are `texts`.
    static func anchor(at place: TextPlace, in texts: [String], file: StaticString = #filePath, line: UInt = #line) throws -> TextAnchor {
        try XCTUnwrap(TextAnchor(capturingAt: place, in: BookWords(texts: texts)), "no chapter \(place.chapter)", file: file, line: line)
    }

    /// The skip of `heading`, with its anchor captured at its start in the
    /// book whose chapters are `texts`.
    static func skip(of heading: Heading, in texts: [String], file: StaticString = #filePath, line: UInt = #line) throws -> SkippedHeading {
        let start = TextPlace(chapter: heading.chapterIndex, offset: heading.characterOffset)
        return SkippedHeading(heading, anchor: try anchor(at: start, in: texts, file: file, line: line))
    }
}

/// Where phrases stand in the relocator tests' texts, found without a
/// subscript that could trap: a phrase not there is a test failure.
enum Phrase {
    /// Where the `occurrence`-th `phrase` (from 0) begins in `text`.
    static func offset(of phrase: String, in text: String, occurrence: Int = 0, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let string = text as NSString
        var searchFrom = 0
        var found: Int?
        for _ in 0...max(occurrence, 0) {
            let range = string.range(of: phrase, options: .literal, range: NSRange(location: searchFrom, length: string.length - searchFrom))
            guard range.location != NSNotFound else {
                found = nil
                break
            }
            found = range.location
            searchFrom = NSMaxRange(range)
        }
        return try XCTUnwrap(found, "\"\(phrase)\" (\(occurrence)) isn't in the text", file: file, line: line)
    }

    /// Where the `occurrence`-th `phrase` (from 0) begins in chapter
    /// `chapter` of `texts`.
    static func place(of phrase: String, inChapter chapter: Int, of texts: [String], occurrence: Int = 0, file: StaticString = #filePath, line: UInt = #line) throws -> TextPlace {
        let text = try XCTUnwrap(texts.indices.contains(chapter) ? texts[chapter] : nil, "no chapter \(chapter)", file: file, line: line)
        return TextPlace(chapter: chapter, offset: try offset(of: phrase, in: text, occurrence: occurrence, file: file, line: line))
    }
}

/// A small seeded source of common words, so a test's texts are the same on
/// every run.
struct SeededWords {
    /// The words drawn from: common ones, which stand many times, and a few
    /// rarer ones, which may stand once.
    private static let vocabulary = ["the", "and", "of", "a", "to", "in", "mill", "wheel", "stone", "flour", "sluice", "weir"]
    private var state: UInt64

    /// A source whose words follow from `seed`: the same seed gives the
    /// same words, in the same order, on every run.
    init(seed: UInt64) {
        state = seed
    }

    /// The next number below `bound` (SplitMix64).
    mutating func next(below bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Int(z % UInt64(max(1, bound)))
    }

    /// A word of the vocabulary.
    mutating func word() -> String {
        Self.vocabulary[next(below: Self.vocabulary.count)]
    }

    /// `count` words.
    mutating func words(count: Int) -> [String] {
        (0..<count).map { _ in word() }
    }
}

/// One chapter with two "Notes" sections: with the first removed, the
/// second slides into its numbers, so the new heading has the first one's
/// ID (REV15, V21), and a reader matching IDs would skip it for a skip of
/// the first.
struct NotesBook {
    /// The chapter's opening, before the first "Notes".
    let opening = "CHAPTER I. The Millrace\n\nThe volunteers met at the mill on the first dry Saturday of March, with spades and a flask.\n\n"
    /// The first "Notes" section.
    let first = "Notes\n\nThe pump belonged to the angling club and went back with a new washer.\n\n"
    /// The second "Notes" section.
    let second = "Notes\n\nA carpenter in the next village turned the offcuts into spoons for the market."
    /// A sentence put in at the chapter's end, an edit elsewhere.
    let ending = " The spoons sold out by the autumn fair."

    /// The text with both sections.
    var both: [String] { [opening + first + second] }
    /// The text without the first section.
    var withoutFirst: [String] { [opening + second] }
    /// The text without the first section, with a sentence added at its end.
    var edited: [String] { [opening + second + ending] }
    /// The first "Notes" heading, in the text with both.
    var firstHeading: Heading { Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: opening.utf16.count) }
    /// The second "Notes" heading, in the text with both.
    var secondHeading: Heading { Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: opening.utf16.count + first.utf16.count) }
    /// The only "Notes" heading of the texts without the first section;
    /// it has the first heading's ID.
    var slidHeading: Heading { Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: opening.utf16.count) }
}
