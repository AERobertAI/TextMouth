import Foundation

/// Represents a parsed document ready for reading
struct DocumentContent {
    var title: String
    var author: String
    var chapters: [Chapter]
    let contentIndex: BookContentIndex
    /// For an audiobook with a transcript (FR05), the transcript's text,
    /// laid over `chapters`, which stay the audio's: what the reader shows
    /// while the book plays its audio. Nil for every other book.
    var transcript: TranscriptText? = nil
    /// The book's pages in book order, each break with its chapter's index in
    /// `chapters` (PG01), and a page after a chapter's last word moved to the
    /// next chapter's first (`pageBreaks(of:)`). Built once, here, because the
    /// status row asks for them often; `chapters` is never changed after
    /// `init` (nothing assigns it), so the pages cannot go stale.
    let pages: BookPages

    init(
        title: String,
        author: String,
        chapters: [Chapter],
        contentIndex: BookContentIndex? = nil
    ) {
        self.title = title
        self.author = author
        self.chapters = chapters
        pages = BookPages(breaks: Self.pageBreaks(of: chapters))
        self.contentIndex = contentIndex ?? BookContentIndex.build(
            fromChapters: chapters,
            format: .txt
        )
    }

    /// The pages `chapters` hold, each with its chapter's index. A page
    /// begins at its first word (PG01), so one that a marker puts after its
    /// chapter's last word, where a chapter's last page break often stands,
    /// begins at the first word of the next chapter that has words. The
    /// reader never rests at a chapter's very end, so it could not reach the
    /// page there: a move forward by page would land on the page before and
    /// find the same page again at every press. After the book's last word
    /// such a page stays where it is, a page without words, which a move by
    /// page passes over (`ReaderViewModel.nextPage()`).
    private static func pageBreaks(of chapters: [Chapter]) -> [PageBreak] {
        var breaks: [PageBreak] = []
        for (index, chapter) in chapters.enumerated() where !chapter.pages.isEmpty {
            let length = chapter.text.utf16Length
            // Looked for only when a page needs it.
            let next = chapter.pages.contains { $0.characterOffset >= length }
                ? firstWord(after: index, in: chapters)
                : nil
            for page in chapter.pages {
                if page.characterOffset >= length, let next {
                    breaks.append(PageBreak(label: page.label, chapterIndex: next.chapterIndex, characterOffset: next.offset))
                } else {
                    breaks.append(PageBreak(label: page.label, chapterIndex: index, characterOffset: page.characterOffset))
                }
            }
        }
        return breaks
    }

    /// Where the first word after chapter `index` of `chapters` begins: in the
    /// next chapter that has words, or nil when none does.
    private static func firstWord(after index: Int, in chapters: [Chapter]) -> (chapterIndex: Int, offset: Int)? {
        guard let later = chapters[(index + 1)...].firstIndex(where: { chapter in chapter.text.contains { !$0.isWhitespace } })
        else { return nil }
        return (later, PageBreak.firstWordStart(in: chapters[later].text, at: 0))
    }

    // MARK: - The Words a Page Holds

    /// Whether the page at `index` of `pages` holds a word of its own: a
    /// character that is not white space, which is a word here as it is to
    /// `firstWord(after:in:)` and to speech
    /// (`ReaderViewModel.hasSpeakableText(_:)`), from where the page begins
    /// up to where the next page begins, or to the book's end after the last
    /// page, and outside the ranges `excluded` gives for each chapter the
    /// page spans, in UTF-16 offsets of that chapter's text. False for an
    /// index of no page.
    ///
    /// With nothing excluded, a page without a word of its own is a blank
    /// page, which begins where the page after it does, or a last page that
    /// begins after the book's last word, and Go to Page says it "has no
    /// words" (PG03). With the ranges a book's skipped sections take out, a
    /// page without one has every word in a skipped section, which speech
    /// passes over.
    func pageHoldsWord(at index: Int, outside excluded: (_ chapterIndex: Int) -> [Range<Int>] = { _ in [] }) -> Bool {
        guard pages.breaks.indices.contains(index) else { return false }
        let page = pages.breaks[index]
        // The page ends where the next page begins, or at the book's end.
        let next = pages.breaks.indices.contains(index + 1) ? pages.breaks[index + 1] : nil
        let lastChapter = min(next?.chapterIndex ?? chapters.count - 1, chapters.count - 1)
        guard chapters.indices.contains(page.chapterIndex), page.chapterIndex <= lastChapter else { return false }
        for chapterIndex in page.chapterIndex...lastChapter {
            // The part of this chapter that belongs to the page.
            let text = chapters[chapterIndex].text
            let length = text.utf16Length
            let start = chapterIndex == page.chapterIndex ? min(max(page.characterOffset, 0), length) : 0
            var end = length
            if let next, next.chapterIndex == chapterIndex {
                end = min(max(next.characterOffset, start), length)
            }
            guard start < end else { continue }
            if Self.holdsWord(text, in: start..<end, outside: excluded(chapterIndex)) { return true }
        }
        return false
    }

    /// Whether `text` holds a character that is not white space in the
    /// UTF-16 range `span`, outside each of the ranges `excluded`, which may
    /// come in any order and overlap.
    private static func holdsWord(_ text: String, in span: Range<Int>, outside excluded: [Range<Int>]) -> Bool {
        // Each stretch of the span before an excluded range, in order, then
        // the stretch after the last of them.
        var start = span.lowerBound
        for range in excluded.sortedStably(by: { $0.lowerBound < $1.lowerBound }) {
            // A range that ends before what is left of the span changes
            // nothing; one that starts at or after the span's end, and every
            // range after it, changes nothing either.
            guard range.upperBound > start else { continue }
            guard range.lowerBound < span.upperBound else { break }
            if range.lowerBound > start, holdsWord(text, in: start..<range.lowerBound) { return true }
            start = range.upperBound
            guard start < span.upperBound else { return false }
        }
        return holdsWord(text, in: start..<span.upperBound)
    }

    /// Whether `text` holds a character that is not white space in the
    /// UTF-16 range `span`.
    private static func holdsWord(_ text: String, in span: Range<Int>) -> Bool {
        guard !span.isEmpty else { return false }
        let lower = text.index(atUTF16Offset: span.lowerBound)
        let upper = text.index(atUTF16Offset: span.upperBound)
        return text[lower..<upper].contains { !$0.isWhitespace }
    }

    var allText: String {
        chapters.map { $0.text }.joined(separator: "\n\n")
    }

    var totalWordCount: Int {
        contentIndex.totalWordCount
    }

    var allHeadings: [Heading] {
        contentIndex.allHeadings
    }

    /// Returns the total character count across all chapters
    var totalCharacterCount: Int {
        contentIndex.totalCharacterCount
    }

    /// Cumulative character offset for the start of each chapter.
    /// Returns 0 for chapter 0 or invalid indices.
    func chapterStartOffset(_ chapterIndex: Int) -> Int {
        guard chapterIndex > 0 else { return 0 }
        return contentIndex.chapterStartOffset(chapterIndex)
    }

    /// Global character offset for a position in (chapter, localOffset)
    func globalOffset(chapterIndex: Int, localOffset: Int) -> Int {
        chapterStartOffset(chapterIndex) + localOffset
    }

    /// Estimated reading time in seconds at a given WPM
    func estimatedReadingTime(wpm: Double) -> TimeInterval {
        guard wpm > 0 else { return 0 }
        return Double(totalWordCount) / wpm * 60.0
    }

    /// Estimated time to read from a given global character offset to the end
    func estimatedTimeRemaining(fromGlobalOffset offset: Int, wpm: Double) -> TimeInterval {
        guard wpm > 0, totalCharacterCount > 0 else { return 0 }
        let remainingFraction = Double(max(totalCharacterCount - offset, 0)) / Double(totalCharacterCount)
        return estimatedReadingTime(wpm: wpm) * remainingFraction
    }

    /// Percentage through the book for a given global offset
    func percentComplete(globalOffset: Int) -> Double {
        guard totalCharacterCount > 0 else { return 0 }
        return min(Double(globalOffset) / Double(totalCharacterCount) * 100.0, 100.0)
    }

    /// Reverse of `globalOffset(chapterIndex:localOffset:)` — given a
    /// global character offset, find which chapter contains it and the
    /// position within that chapter. Used by jump-to-percent and
    /// jump-to-time to translate a target into a (chapter, offset)
    /// pair the navigation system can act on.
    /// Clamps out-of-range inputs: a negative target returns
    /// (0, 0); a target past the end returns the last chapter's last
    /// position. An empty document returns (0, 0).
    func location(forGlobalOffset globalOffset: Int) -> (chapterIndex: Int, localOffset: Int) {
        contentIndex.location(forGlobalOffset: globalOffset)
    }
}

struct Chapter {
    var title: String
    var text: String
    var headings: [Heading]
    /// The pages that begin in this chapter, in reading order, as the parse
    /// found their markers (PG01). Their `chapterIndex` is 0, as the chapter's
    /// headings' is; `DocumentContent.pages` holds the book's, with each
    /// chapter's index.
    var pages: [PageBreak]

    /// Character ranges for each heading within this chapter's text
    var headingRanges: [(heading: Heading, range: Range<String.Index>)]

    /// The number of words in `text`: runs of Characters that are not
    /// whitespace (`Character.isWhitespace`), as
    /// `text.split(whereSeparator: \.isWhitespace).count` counts them.
    var wordCount: Int {
        Self.wordCount(of: text)
    }

    /// The number of runs of Characters in `text` that are not whitespace,
    /// counted without building a substring per word or reading every
    /// Character whole (PERF21: 64 ms per MB of reading text before).
    ///
    /// An ASCII byte followed by another ASCII byte, or by the end, is a
    /// whole Character: no ASCII scalar extends or prepends a grapheme
    /// cluster, and the one pair that forms one, CR LF, is whitespace like
    /// each of its halves. Such a byte is judged on its own: it is
    /// whitespace when it is a space or one of tab, line feed, vertical
    /// tab, form feed, and carriage return, the ASCII scalars with the
    /// Unicode White_Space property. Every other Character is read whole
    /// from its first byte, and is whitespace when its first scalar is, as
    /// `Character.isWhitespace` decides. Each step starts on a Character
    /// boundary, so the count is the one the split makes.
    static func wordCount(of text: String) -> Int {
        let bytes = text.utf8
        var count = 0
        var inWord = false
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            let next = bytes.index(after: index)
            let isWhitespace: Bool
            if byte < 0x80, next == bytes.endIndex || bytes[next] < 0x80 {
                isWhitespace = byte == 0x20 || (0x09...0x0D).contains(byte)
                // CR LF is one Character: step past both halves, so the
                // next step starts on a boundary.
                index = byte == 0x0D && next < bytes.endIndex && bytes[next] == 0x0A ? bytes.index(after: next) : next
            } else {
                isWhitespace = text[index].isWhitespace
                index = text.index(after: index)
            }
            if isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    init(
        title: String = "",
        text: String = "",
        headings: [Heading] = [],
        headingRanges: [(heading: Heading, range: Range<String.Index>)] = [],
        pages: [PageBreak] = []
    ) {
        self.title = title
        self.text = text
        self.headings = headings
        self.headingRanges = headingRanges
        self.pages = pages
    }
}

struct Heading: Identifiable, Hashable {
    /// Stable ID derived from content and position so SwiftUI/VoiceOver rotors
    /// don't see headings as new elements on every recompute.
    var id: String
    var level: Int  // 1-6
    var text: String
    var chapterIndex: Int
    var characterOffset: Int  // offset within the chapter text

    init(level: Int, text: String, chapterIndex: Int = 0, characterOffset: Int = 0) {
        self.level = level
        self.text = text
        self.chapterIndex = chapterIndex
        self.characterOffset = characterOffset
        self.id = "\(chapterIndex)-\(characterOffset)-\(level)-\(text)"
    }

    /// Whether this heading begins at or before a reading position. The last
    /// heading satisfying this contains the position; that single rule decides
    /// the current heading for the headings panel, the reader header, Where
    /// Am I, bookmark labels, and navigation announcements alike.
    func startsAtOrBefore(chapterIndex: Int, characterOffset: Int) -> Bool {
        self.chapterIndex < chapterIndex
            || (self.chapterIndex == chapterIndex && self.characterOffset <= characterOffset)
    }
}

extension String {
    /// This string, or nil when it holds only whitespace, so a blank title is
    /// left out of labels instead of being shown or spoken as an empty phrase.
    var nonBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

/// A reading position described by the book's headings — the same list the
/// headings panel shows. Internally a book is divided into content units
/// (EPUB spine documents, audio files, or one whole text file) whose count
/// rarely matches the headings a reader navigates, so every user-facing
/// location counts headings and never content units.
struct HeadingPosition: Equatable {
    /// The heading containing the position: the last heading that starts at
    /// or before it. Nil when the position precedes the first heading.
    let heading: Heading?
    /// 1-based number of `heading` within the book's heading list, or nil
    /// when the position precedes the first heading.
    let number: Int?
    /// Total number of headings in the book.
    let count: Int

    /// Locate a (content unit, character offset) position within `headings`.
    /// A linear scan keeps the result identical to the headings panel for any
    /// heading order; books hold at most a few thousand headings, so the cost
    /// is negligible even when the reader header re-renders during playback.
    init(in headings: [Heading], chapterIndex: Int, characterOffset: Int) {
        self.init(
            headings: headings,
            containingIndex: headings.lastIndex {
                $0.startsAtOrBefore(chapterIndex: chapterIndex, characterOffset: characterOffset)
            }
        )
    }

    /// Build a position from the list index of its containing heading, as
    /// found by the initializer above or by `HeadingSweep`.
    fileprivate init(headings: [Heading], containingIndex: Int?) {
        heading = containingIndex.map { headings[$0] }
        number = containingIndex.map { $0 + 1 }
        count = headings.count
    }

    /// The shared position label: "Heading N of M", "Before heading 1 of M"
    /// when the position precedes the first heading, or an empty string for a
    /// book without headings (callers drop empty parts rather than speak them).
    var label: String {
        guard count > 0 else { return "" }
        guard let number else { return "Before heading 1 of \(count)" }
        return "Heading \(number) of \(count)"
    }

    /// The containing heading's text, or nil before the first heading or when
    /// that heading's text is blank.
    var headingText: String? {
        heading?.text.nonBlank
    }

    /// Name for the position, or nil when nothing beyond `label` is worth
    /// saying. Normally this is the containing heading's text. Only a book with
    /// no headings at all falls back to its content unit's own title, and even
    /// then not when that title merely repeats the book title.
    func title(contentTitle: String?, bookTitle: String) -> String? {
        guard count == 0 else { return headingText }
        guard let contentTitle = contentTitle?.nonBlank,
              !Self.isSameTitle(contentTitle, bookTitle)
        else { return nil }
        return contentTitle
    }

    /// Compare titles the way a listener hears them: ignoring letter case and
    /// surrounding whitespace.
    private static func isSameTitle(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }
}

/// Locates a series of positions within one heading list. When positions
/// arrive in reading order, as book search results do, each heading is
/// visited once in total instead of once per position. Every answer equals
/// `HeadingPosition(in:chapterIndex:characterOffset:)` for the same list,
/// whatever order the list is in; a position earlier than the previous one
/// simply restarts the sweep.
struct HeadingSweep {
    private let headings: [Heading]
    /// List indices ordered by where each heading starts; ties keep list order.
    private let startOrder: [Int]
    /// How many leading entries of `startOrder` start at or before the last
    /// position located.
    private var passedCount = 0
    /// Greatest list index among those passed headings, which is exactly the
    /// index `HeadingPosition` would find with its backwards scan.
    private var containingIndex: Int?
    /// The previous position, to detect a move backwards.
    private var previousPosition: (Int, Int)?

    init(headings: [Heading]) {
        self.headings = headings
        startOrder = headings.indices.sortedStably { lhs, rhs in
            (headings[lhs].chapterIndex, headings[lhs].characterOffset, lhs)
                < (headings[rhs].chapterIndex, headings[rhs].characterOffset, rhs)
        }
    }

    /// Locate the next position, advancing past every heading that starts at
    /// or before it.
    mutating func position(chapterIndex: Int, characterOffset: Int) -> HeadingPosition {
        if let previousPosition, (chapterIndex, characterOffset) < previousPosition {
            passedCount = 0
            containingIndex = nil
        }
        previousPosition = (chapterIndex, characterOffset)

        while passedCount < startOrder.count {
            let index = startOrder[passedCount]
            guard headings[index].startsAtOrBefore(chapterIndex: chapterIndex, characterOffset: characterOffset)
            else { break }
            containingIndex = max(containingIndex ?? index, index)
            passedCount += 1
        }
        return HeadingPosition(headings: headings, containingIndex: containingIndex)
    }
}

/// What a sleep timer waits for before it pauses playback: a number of
/// minutes of listening, or a place the book reaches: the end of the
/// heading playing, or the end of the book.
///
/// The places are one concept, headings, for every kind of document, as
/// the user decided on October 6, 2026 ("I really want those two things to
/// be under one concept called Headings to not just apply to normal books
/// but to any document"). Every parser makes headings: an EPUB's h1 to h6
/// and the labels its navigation document gives chapters without one, a
/// Markdown or HTML file's headings, the headings a plain-text file's
/// structure gives it, a DAISY book's NCC, and in an audiobook one heading
/// at the start of each chapter, track, or marker segment
/// (`AudioBookParser`). So "the end of the heading" is the same place in a
/// novel, a Markdown file, and an audiobook: where the next heading of any
/// level begins, as Next Heading finds it, or where the book ends.
enum SleepTimerDuration: Hashable {
    case minutes(Int)
    /// The end of the heading current where the timer was set: where the
    /// next heading begins, of any level, or the end of the book after the
    /// last heading (finding #787). The reader that set it finds that place,
    /// and stops playback when its cursor gets there: within a chapter,
    /// where the next heading begins; at a chapter's end, when the next
    /// chapter opens with the next heading, as every audiobook chapter does;
    /// and at the book's end, which ends the last heading. It took the place
    /// of End of chapter (October 6, 2026), which a saved preference may
    /// still name (`SleepTimerService`). Where the two differed, the
    /// heading's meaning holds: a chapter with more than one heading stops
    /// at the next heading rather than at the chapter's end, and a next
    /// chapter that has text before its first heading, or no heading at all,
    /// goes on under the heading playing, so playback goes on into it
    /// (`ReaderViewModel.chapterEnding(beforeChapter:)`).
    case endOfHeading
    /// The end of the book: the end of its last chapter, before the book
    /// starts again or the next book starts, whatever its end-of-book
    /// behavior.
    case endOfBook

    /// The timer's name, as its preset button, its announcements ("Timer
    /// set for 1 minute."), and the reader's status show it: its minutes
    /// counted (TODO A10; it said "1 minutes"), or the place it stops at.
    var displayName: String {
        switch self {
        case .minutes(let m): return CountWording.minutes(m)
        case .endOfHeading: return "End of heading"
        case .endOfBook: return "End of book"
        }
    }

    /// What a timer set for a place in the book does, as VoiceOver reads it
    /// after "Sleep timer:" ("stops at the end of this heading"); nil for a
    /// timer counting minutes, which is read as the time it has left.
    var spokenStop: String? {
        switch self {
        case .minutes: return nil
        case .endOfHeading: return "stops at the end of this heading"
        case .endOfBook: return "stops at the end of the book"
        }
    }

    /// Whether a timer set for this stops playback where a chapter ends,
    /// before anything after that chapter plays (TODO P01). End of heading
    /// stops there when the heading it waits for ends there too, as when the
    /// next chapter begins with the next heading, which every audiobook
    /// chapter does, and where the book ends, which ends the last heading
    /// (finding #787); End of book only at the end of the book's last
    /// chapter; a timer counting minutes stops at no chapter's end.
    ///
    /// - Parameters:
    ///   - endingTheHeading: Whether the heading an End of heading timer
    ///     waits for ends where the chapter does.
    ///   - endingTheBook: Whether the chapter ending is the book's last, with
    ///     nothing after it to play, so that its end is the book's.
    func stopsPlaybackAtChapterEnd(endingTheHeading: Bool, endingTheBook: Bool) -> Bool {
        switch self {
        case .endOfHeading:
            return endingTheHeading || endingTheBook
        case .endOfBook:
            return endingTheBook
        case .minutes:
            return false
        }
    }

    /// What the sleep timer sheet offers: its minute presets, then the
    /// timers of its Stop At section, End of heading before End of book.
    static let presets: [SleepTimerDuration] = [
        .minutes(10), .minutes(15), .minutes(30),
        .minutes(45), .minutes(60),
        .endOfHeading, .endOfBook
    ]
}

// MARK: - Time Formatting Helper

enum TimeFormatting {
    /// Format seconds to h:mm:ss or m:ss (for visual display)
    static func format(_ seconds: TimeInterval) -> String {
        guard let totalSeconds = wholeSeconds(seconds) else { return "Unknown" }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return "\(hours):" + String(format: "%02d:%02d", minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Format seconds as spoken words for VoiceOver (e.g. "1 hour, 3 minutes, 45 seconds").
    /// Omits zero-valued leading fields so "0:54:35" becomes "54 minutes, 35 seconds".
    static func spoken(_ seconds: TimeInterval) -> String {
        guard let totalSeconds = wholeSeconds(seconds) else { return "Unknown duration" }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        var parts: [String] = []
        if hours > 0 {
            parts.append(CountWording.hours(hours))
        }
        if minutes > 0 {
            parts.append(CountWording.minutes(minutes))
        }
        if secs > 0 || parts.isEmpty {
            parts.append(CountWording.seconds(secs))
        }
        return parts.joined(separator: ", ")
    }

    /// External metadata and estimates can contain invalid or enormous values.
    /// Use a failable conversion so rendering a label never traps the app.
    private static func wholeSeconds(_ seconds: TimeInterval) -> Int? {
        guard seconds.isFinite else { return nil }
        return Int(exactly: max(seconds, 0).rounded(.towardZero))
    }
}
