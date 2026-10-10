import Foundation

/// What a saved place keeps of its book's text, so that it can be found
/// again when the text is read anew (T06): the text just before the place
/// and just after it, its share of the whole book, and what it was
/// measured in.
///
/// A saved place is otherwise a chapter and a count of UTF-16 units into
/// that chapter's reading text, which TextMouth makes from the book's
/// Markdown each time the book opens. When the Markdown changes, or the
/// way TextMouth reads it does, the count stays and the words under it
/// move: in the real extraction changes measured, today's numbers put 81%
/// of places on other words (TEXT-ANCHORS-RESEARCH-2026-10-10.md). With an
/// anchor, a place is its words, and the numbers are only a hint:
///
/// - used as they stand only when the anchor's text is still exactly
///   around them (`stands(at:in:)`, the direct check);
/// - otherwise the place is found again by its words (`TextAnchorFinder`).
///
/// Each quote holds up to `quoteLength` UTF-16 units and is cut on
/// composed-character boundaries (NSString's
/// `rangeOfComposedCharacterSequence(at:)`), so it never splits a
/// character, an emoji, or a letter from its accents. A quote is empty
/// only where the place is at its chapter's start (`before`) or end
/// (`after`): a single composed character longer than the whole quote,
/// which no real text holds, is kept whole rather than cut to nothing. A
/// place inside a composed character counts as at that character's start,
/// both when its anchor is captured and when it is checked, so the check
/// stays exact.
///
/// It is about 220 bytes of JSON for Latin text, in the row and the record
/// of each place that keeps one. Every field is decoded leniently, so an
/// older or a damaged file still loads.
struct TextAnchor: Codable, Hashable, Sendable {
    /// The most UTF-16 units each quote keeps. The first note measured 32,
    /// 64, and 96: 64 halves 32's unfound places for 66 more bytes a
    /// place, and 96 adds little (TEXT-ANCHORS-RESEARCH-2026-10-10.md,
    /// section 4).
    static let quoteLength = 64

    /// This build's anchor format, written into every anchor it captures.
    static let currentVersion = 1

    /// The text this build measures places in: its text cache's version and
    /// its content index's, "3.0.7/1.0.0". Nothing decides by it, since an
    /// anchor's own words say whether they still stand; it lets a later
    /// diagnosis count places measured in older text without inferring it
    /// from dates.
    static let currentMeasure = "\(MarkdownCacheService.currentCacheVersion)/\(BookContentIndex.currentVersion)"

    /// The chapter's reading text just before the place: up to
    /// `quoteLength` UTF-16 units, ending at the place.
    var before: String
    /// The chapter's reading text from the place on: up to `quoteLength`
    /// UTF-16 units.
    var after: String
    /// The place's share of the whole book, from 0 at its start to 1 at its
    /// end. It says which of two equally good spots is nearer where the
    /// place was, and marks the end of the book.
    var fraction: Double
    /// The text cache's and content index's versions the place was measured
    /// in (`currentMeasure`), when known.
    var measuredIn: String?
    /// The anchor's format (`currentVersion`).
    var version: Int

    /// An anchor of the given parts, as decoding or a test makes one. A
    /// share outside 0 to 1 is held within it.
    init(before: String, after: String, fraction: Double, measuredIn: String? = nil, version: Int = TextAnchor.currentVersion) {
        self.before = before
        self.after = after
        self.fraction = Self.share(fraction)
        self.measuredIn = measuredIn
        self.version = version
    }

    /// Captures the anchor of a place `offset` UTF-16 units into a chapter
    /// whose reading text is `chapterText`, which begins `chapterStart`
    /// units into a book `bookLength` units long. The quotes of an offset
    /// outside the chapter are taken at its edge, so a place past its
    /// chapter's end is quoted at that end. Its share counts the offset as
    /// given, as P07 measures a place: one whose chapter's start plus its
    /// offset reaches the book's length rests at the book's end
    /// (`Book.restsAtEnd`), and its anchor marks the end.
    init(
        capturingAt offset: Int,
        in chapterText: String,
        chapterStart: Int,
        bookLength: Int,
        measuredIn: String? = TextAnchor.currentMeasure
    ) {
        let text = chapterText as NSString
        let place = Self.characterStart(atOrBefore: min(max(offset, 0), text.length), in: text)
        self.before = text.substring(with: Self.beforeRange(endingAt: place, in: text))
        self.after = text.substring(with: Self.afterRange(startingAt: place, in: text))
        // In Double, so an offset as large as an Int can hold can't overflow.
        self.fraction = bookLength > 0 ? Self.share((Double(chapterStart) + Double(max(offset, 0))) / Double(bookLength)) : 0
        self.measuredIn = measuredIn
        self.version = Self.currentVersion
    }

    /// Captures the anchor of `place` in the book `words` reads, or nil
    /// when the book has no such chapter.
    init?(capturingAt place: TextPlace, in words: BookWords, measuredIn: String? = TextAnchor.currentMeasure) {
        guard place.chapter >= 0, place.chapter < words.chapterCount else { return nil }
        self.init(
            capturingAt: place.offset,
            in: words.texts[place.chapter],
            chapterStart: words.chapterStarts[place.chapter],
            bookLength: words.totalLength,
            measuredIn: measuredIn
        )
    }

    /// Whether the anchor marks the end of the book: nothing after it in its
    /// chapter, and its share the whole book. Such a place stays at the end
    /// of the book whatever is added or removed there (P07's finished book;
    /// TEXT-ANCHORS-ADDENDUM-2026-10-10.md, section 9).
    var marksEndOfBook: Bool {
        after.isEmpty && fraction >= 1
    }

    // MARK: - The Direct Check

    /// Whether the anchor's text stands exactly around `place` in the book
    /// whose chapters' reading texts are `texts`: the direct check. When it
    /// does, nothing before the place changed and the place stays.
    func stands(at place: TextPlace, in texts: [String]) -> Bool {
        guard place.chapter >= 0, place.chapter < texts.count else { return false }
        return stands(atOffset: place.offset, in: texts[place.chapter])
    }

    /// Whether `before` ends and `after` begins exactly at `offset` in
    /// `chapterText`, compared unit for unit. An offset inside a composed
    /// character is checked at that character's start, as it was captured.
    func stands(atOffset offset: Int, in chapterText: String) -> Bool {
        let text = chapterText as NSString
        guard offset >= 0, offset <= text.length else { return false }
        let place = Self.characterStart(atOrBefore: offset, in: text)
        let beforeLength = before.utf16.count
        let afterLength = after.utf16.count
        guard place - beforeLength >= 0, place + afterLength <= text.length else { return false }
        return text.compare(before, options: .literal, range: NSRange(location: place - beforeLength, length: beforeLength)) == .orderedSame
            && text.compare(after, options: .literal, range: NSRange(location: place, length: afterLength)) == .orderedSame
    }

    // MARK: - Cutting the Quotes

    /// `offset`, or the start of the composed character it falls inside.
    /// `offset` must be within `text`.
    private static func characterStart(atOrBefore offset: Int, in text: NSString) -> Int {
        guard offset > 0, offset < text.length else { return offset }
        return text.rangeOfComposedCharacterSequence(at: offset).location
    }

    /// The text the quote before a place at `place` (a character boundary)
    /// keeps: up to `quoteLength` units ending there, starting on a
    /// character boundary, but at least the whole character just before
    /// the place.
    private static func beforeRange(endingAt place: Int, in text: NSString) -> NSRange {
        guard place > 0 else { return NSRange(location: 0, length: 0) }
        var start = max(0, place - quoteLength)
        if start > 0 {
            // A cut inside a character moves forward past it: the quote
            // keeps no part of a character it can't keep whole.
            let cut = text.rangeOfComposedCharacterSequence(at: start)
            if cut.location < start { start = NSMaxRange(cut) }
        }
        start = min(start, text.rangeOfComposedCharacterSequence(at: place - 1).location)
        return NSRange(location: start, length: place - start)
    }

    /// The text the quote after a place at `place` (a character boundary)
    /// keeps: up to `quoteLength` units starting there, ending on a
    /// character boundary, but at least the whole character just after the
    /// place.
    private static func afterRange(startingAt place: Int, in text: NSString) -> NSRange {
        guard place < text.length else { return NSRange(location: place, length: 0) }
        var end = min(text.length, place + quoteLength)
        if end < text.length {
            // A cut inside a character moves back before it.
            let cut = text.rangeOfComposedCharacterSequence(at: end)
            if cut.location < end { end = cut.location }
        }
        end = max(end, NSMaxRange(text.rangeOfComposedCharacterSequence(at: place)))
        return NSRange(location: place, length: end - place)
    }

    /// `value` held within 0 to 1, a share of the book; 0 for a value that
    /// is not a number.
    private static func share(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case before, after, fraction, measuredIn, version
    }

    /// Decodes an anchor leniently: each field missing or of the wrong
    /// type takes its empty value (no quote, a share of 0, no measure,
    /// format 1), so an older or a damaged file loads rather than failing
    /// the book. An anchor whose quotes are both empty (a place in a
    /// chapter without text, or a damaged anchor) holds no words: it stands
    /// at any place within its chapter, so such a place keeps its numbers,
    /// and it is found nowhere else.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        before = (try? container.decodeIfPresent(String.self, forKey: .before)) ?? ""
        after = (try? container.decodeIfPresent(String.self, forKey: .after)) ?? ""
        fraction = Self.share((try? container.decodeIfPresent(Double.self, forKey: .fraction)) ?? 0)
        measuredIn = try? container.decodeIfPresent(String.self, forKey: .measuredIn)
        version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
    }
}
