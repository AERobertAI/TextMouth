import Foundation

// MARK: - Preparation Settings

/// The three settings a chapter's speech is prepared with besides the
/// chapter itself, as `ChapterSpeechInputs` takes them: how runs of a
/// repeated symbol are read, the punctuation pause level, and the
/// substitution rules (FMT43).
///
/// A speech export reads them once, on the main actor, as it is asked for
/// (`current(substitutions:defaults:)`), then prepares every chapter with
/// them, off the main actor if it likes: being values, they cannot change
/// under an export that is running, so every chapter of one file is spoken
/// alike.
struct SpeechPreparationSettings: Equatable, Sendable {
    /// How runs of a repeated symbol are read.
    var repeatedSymbolRule: RepeatedSymbolRule
    /// The punctuation pause level, 0 for none.
    var punctuationPauseLevel: Double
    /// The substitution rules in force.
    var substitutions: SubstitutionPass

    /// The settings in force now, read as the reader reads them
    /// (`ReaderViewModel.speechInputs(forChapterAt:)`): the repeated-symbol
    /// rule and the substitution rules from `service`, and the punctuation
    /// pause level stored in `defaults`, validated by the rule the Settings
    /// model validates it with, so a value out of range is clamped and a
    /// missing one is the default.
    ///
    /// - Parameters:
    ///   - service: The substitution service, which also keeps the
    ///     repeated-symbol settings; the app's own unless a test gives one.
    ///   - defaults: The preferences store holding the pause level; the
    ///     app's own unless a test gives a sandboxed one.
    @MainActor
    static func current(
        substitutions service: TextSubstitutionService = .shared,
        defaults: UserDefaults = .standard
    ) -> SpeechPreparationSettings {
        SpeechPreparationSettings(
            repeatedSymbolRule: service.repeatedSymbolRule,
            punctuationPauseLevel: SettingsPolicy.punctuationPauseLevel.storedValue(in: defaults),
            substitutions: service.substitutionPass
        )
    }

    /// What chapter `index` of `content` is prepared from with these
    /// settings, built exactly as the reader builds it
    /// (`ReaderViewModel.speechInputs(forChapterAt:)`): the chapter's text,
    /// and the chapter's headings only while some heading of the book is
    /// skipped.
    ///
    /// - Parameters:
    ///   - index: The chapter's index; the caller makes sure the book has it.
    ///   - content: The book.
    ///   - headings: `content.allHeadings`, which the caller builds once
    ///     rather than once for each chapter.
    ///   - skippedHeadingIDs: The IDs of the book's skipped headings.
    func inputs(
        forChapterAt index: Int,
        of content: DocumentContent,
        headings: [Heading],
        skippedHeadingIDs: Set<String>
    ) -> ChapterSpeechInputs {
        // Most books skip nothing, and then no heading shapes the speech.
        let chapterHeadings = skippedHeadingIDs.isEmpty ? [] : headings.filter { $0.chapterIndex == index }
        return ChapterSpeechInputs(
            chapterIndex: index,
            text: content.chapters[index].text,
            chapterHeadings: chapterHeadings,
            bookSkippedHeadingIDs: skippedHeadingIDs,
            repeatedSymbolRule: repeatedSymbolRule,
            punctuationPauseLevel: punctuationPauseLevel,
            substitutions: substitutions
        )
    }
}

// MARK: - Range

/// The part of a book a speech export reads (FMT43): from one heading
/// through another, either end of the book standing in for a heading.
struct SpeechExportRange: Equatable, Sendable {
    /// The `Heading.id` of the first heading read; nil for the book's
    /// beginning, with any text before its first heading.
    var fromHeadingID: String?
    /// The `Heading.id` of the last heading read, whose section takes its
    /// subheadings with it; nil for the book's end.
    var throughHeadingID: String?

    /// The whole book, from its beginning to its end.
    static let wholeBook = SpeechExportRange(fromHeadingID: nil, throughHeadingID: nil)

    /// Whether this is the whole book: neither end names a heading.
    var isWholeBook: Bool {
        fromHeadingID == nil && throughHeadingID == nil
    }
}

// MARK: - Section

/// One chapter of an exported audio file (FMT43): the section of the book
/// that one heading begins, or the text before the first heading, as the
/// reader speaks it.
struct SpeechExportSection: Equatable, Sendable {
    /// The part of one of the book's chapters (content units) that a section
    /// holds.
    struct Piece: Equatable, Sendable {
        /// The index of the book's chapter the text is from.
        let chapterIndex: Int
        /// An exact slice of that chapter's prepared speech
        /// (`ChapterSpeechInputs.prepare()`).
        let text: String
    }

    /// The chapter marker's title: the heading's text on one line, or the
    /// book's title on one line for the text before the first heading and
    /// for a heading whose text is blank.
    let title: String
    /// The heading's `Heading.id`; nil for the text before the first heading.
    let headingID: String?
    /// One piece for each of the book's chapters the section spans, in
    /// reading order.
    let pieces: [Piece]

    /// The pieces' texts, in order.
    var texts: [String] {
        pieces.map(\.text)
    }

    /// The pieces' total length, in UTF-16 units.
    var utf16Length: Int {
        pieces.reduce(0) { $0 + $1.text.utf16Length }
    }

    /// The pieces' total number of words, each piece's counted as a
    /// chapter's are (`Chapter.wordCount(of:)`).
    var wordCount: Int {
        pieces.reduce(0) { $0 + Chapter.wordCount(of: $1.text) }
    }
}

// MARK: - Text

/// The text a speech export speaks (FMT43): a book, or a range of its
/// headings, as the reader would speak it, split into the chapters the
/// audio file has: one for each heading, and one for any text before the
/// first heading when the range starts at the book's beginning.
///
/// The text is the reader's own speech, never a copy of its preparation:
/// each of the book's chapters (content units) is prepared as the reader
/// prepares it (`ChapterSpeechInputs.prepare()`), skipped sections left
/// out, runs of a repeated symbol rewritten, punctuation pauses added, and
/// the substitution rules applied, then cut where the headings fall in it.
/// A section ends where the next one begins, so the whole book's pieces of
/// one chapter, joined in order, are that chapter's prepared speech,
/// character for character.
///
/// Pure: it reads nothing but its arguments, so an export may call it off
/// the main actor.
enum SpeechExportText {
    /// Why the sections of a range cannot be made.
    enum Failure: Error, Equatable {
        /// The range names a heading the book does not have, by its
        /// `Heading.id`: the book was read again with other headings since
        /// the range was chosen.
        case headingNotFound(String)
    }

    /// Every section of `range` in `content`, in reading order, each with a
    /// piece for every chapter it spans, even one with nothing to speak (a
    /// section the skipped headings emptied keeps its empty piece), so that
    /// the pieces can be compared with the reader's speech.
    ///
    /// - Parameters:
    ///   - content: The book, as the reader reads it.
    ///   - range: The headings to read.
    ///   - skippedHeadingIDs: The IDs of the book's skipped headings.
    ///   - settings: The settings each chapter's speech is prepared with.
    ///   - bookTitle: The book's title, which names the text before the
    ///     first heading, and a heading with blank text.
    /// - Returns: No section for a book with no chapters, or for a range
    ///   that ends before it begins.
    /// - Throws: `Failure.headingNotFound` when either end of `range` names
    ///   a heading `content` does not have.
    static func allSections(
        of content: DocumentContent,
        range: SpeechExportRange,
        skippedHeadingIDs: Set<String>,
        settings: SpeechPreparationSettings,
        bookTitle: String
    ) throws -> [SpeechExportSection] {
        guard !content.chapters.isEmpty else { return [] }
        let headings = content.allHeadings
        var speech = SpeechCutter(
            content: content,
            headings: headings,
            skippedHeadingIDs: skippedHeadingIDs,
            settings: settings
        )
        return try spans(of: range, in: content, headings: headings, bookTitle: bookTitle).map { span in
            SpeechExportSection(
                title: span.title,
                headingID: span.headingID,
                pieces: speech.pieces(from: span.start, to: span.end)
            )
        }
    }

    /// What an export of `range` in `content` speaks: `allSections` with
    /// each piece that holds nothing speakable taken out
    /// (`ReaderViewModel.hasSpeakableText`), as playback passes over such
    /// text, then each section left with no piece taken out. A skipped
    /// heading's section is therefore not a chapter of the file.
    ///
    /// The parameters, the result, and the errors are those of
    /// `allSections(of:range:skippedHeadingIDs:settings:bookTitle:)`.
    static func sections(
        of content: DocumentContent,
        range: SpeechExportRange,
        skippedHeadingIDs: Set<String>,
        settings: SpeechPreparationSettings,
        bookTitle: String
    ) throws -> [SpeechExportSection] {
        try allSections(
            of: content,
            range: range,
            skippedHeadingIDs: skippedHeadingIDs,
            settings: settings,
            bookTitle: bookTitle
        ).compactMap { section in
            let speakable = section.pieces.filter { ReaderViewModel.hasSpeakableText($0.text) }
            guard !speakable.isEmpty else { return nil }
            return SpeechExportSection(title: section.title, headingID: section.headingID, pieces: speakable)
        }
    }

    // MARK: Where Sections Begin and End

    /// A place in a book's text: a chapter, and a UTF-16 offset in that
    /// chapter's text as the book holds it, before any preparation.
    private struct Place: Comparable {
        /// The chapter's index in the book.
        let chapterIndex: Int
        /// The UTF-16 offset in the chapter's text.
        let offset: Int

        /// Reading order: by chapter, then by offset in the chapter.
        static func < (lhs: Place, rhs: Place) -> Bool {
            (lhs.chapterIndex, lhs.offset) < (rhs.chapterIndex, rhs.offset)
        }
    }

    /// A section before its speech is cut: its title, its heading's ID, and
    /// where it begins and ends in the book's text.
    private struct Span {
        /// The section's title (`SpeechExportSection.title`).
        let title: String
        /// The section's heading's ID; nil for the text before the first
        /// heading.
        let headingID: String?
        /// Where the section begins.
        let start: Place
        /// Where the section ends, and the next one begins.
        let end: Place
    }

    /// The sections of `range` in `content`, in reading order, before their
    /// speech is cut: the text before the first heading when `range` starts
    /// at the book's beginning, then one section for each heading from the
    /// "From" heading through the "To" heading and its subheadings, each
    /// running to the next heading of any level, or to the book's end.
    ///
    /// - Parameters:
    ///   - range: The headings to read.
    ///   - content: The book, which has at least one chapter.
    ///   - headings: `content.allHeadings`, in reading order.
    ///   - bookTitle: The book's title.
    /// - Throws: `Failure.headingNotFound` for a heading `headings` lacks.
    private static func spans(
        of range: SpeechExportRange,
        in content: DocumentContent,
        headings: [Heading],
        bookTitle: String
    ) throws -> [Span] {
        let bookEnd = end(of: content)
        /// Where heading `index` begins, and the book's end for the index
        /// past the last heading.
        func start(ofHeadingAt index: Int) -> Place {
            headings.indices.contains(index) ? place(of: headings[index], in: content) : bookEnd
        }

        var spans: [Span] = []
        // The first heading read. From the book's beginning, the text before
        // the first heading comes first, under the book's title: up to that
        // heading, or the whole book when it has no headings.
        let first: Int
        if let id = range.fromHeadingID {
            guard let index = headings.firstIndex(where: { $0.id == id }) else { throw Failure.headingNotFound(id) }
            first = index
        } else {
            first = 0
            spans.append(Span(
                title: title(of: nil, bookTitle: bookTitle),
                headingID: nil,
                start: Place(chapterIndex: 0, offset: 0),
                end: start(ofHeadingAt: 0)
            ))
        }

        // The heading after the last one read. The "To" heading's section
        // takes its subheadings with it, up to the next heading of its level
        // or above, so a range from a chapter to the same chapter is the
        // whole chapter. Should two headings share an ID (the same text,
        // level, and place), the range starts at the first and runs through
        // the last, so neither one's text is left out.
        let pastLast: Int
        if let id = range.throughHeadingID {
            guard let last = headings.lastIndex(where: { $0.id == id }) else { throw Failure.headingNotFound(id) }
            // A range that ends before it begins holds nothing. Only a range
            // naming both ends can, and the Export dialog never asks for one.
            guard first <= last else { return [] }
            let level = headings[last].level
            pastLast = headings[(last + 1)...].firstIndex { $0.level <= level } ?? headings.count
        } else {
            pastLast = headings.count
        }

        for index in first..<pastLast {
            spans.append(Span(
                title: title(of: headings[index], bookTitle: bookTitle),
                headingID: headings[index].id,
                start: start(ofHeadingAt: index),
                end: start(ofHeadingAt: index + 1)
            ))
        }
        return spans
    }

    /// The book's end: the end of its last chapter's text. The book has a
    /// chapter.
    private static func end(of content: DocumentContent) -> Place {
        let last = content.chapters.count - 1
        return Place(chapterIndex: last, offset: content.chapters[last].text.utf16Length)
    }

    /// Where `heading` begins: its chapter, and its offset clamped into that
    /// chapter's text. A heading of a chapter the book does not have, which
    /// only a content index made for other chapters could give, is placed
    /// at the book's nearer end, so no chapter the book lacks is ever read.
    private static func place(of heading: Heading, in content: DocumentContent) -> Place {
        guard heading.chapterIndex >= 0 else { return Place(chapterIndex: 0, offset: 0) }
        guard heading.chapterIndex < content.chapters.count else { return end(of: content) }
        let length = content.chapters[heading.chapterIndex].text.utf16Length
        return Place(chapterIndex: heading.chapterIndex, offset: min(max(0, heading.characterOffset), length))
    }

    /// The title of `heading`'s section, or of the text before the first
    /// heading when `heading` is nil: the heading's text on one line, or the
    /// book's title on one line when there is no heading or its text is
    /// blank; empty only when the book's title is blank too.
    private static func title(of heading: Heading?, bookTitle: String) -> String {
        heading.flatMap { oneLine($0.text) } ?? oneLine(bookTitle) ?? ""
    }

    /// `text` on one line, as a chapter marker shows it
    /// (`SpeechExportWording.oneLine(_:)`); nil when nothing but white space
    /// is left.
    private static func oneLine(_ text: String) -> String? {
        let line = SpeechExportWording.oneLine(text)
        return line.isEmpty ? nil : line
    }

    // MARK: Cutting the Speech

    /// The prepared speech of a book's chapters, cut into sections' pieces.
    ///
    /// Each chapter is prepared the first time a section needs it, and kept
    /// only while sections can still need it: sections come in reading
    /// order, so once one begins in a later chapter, no section after it
    /// needs an earlier one, and that speech is let go. Every chapter is
    /// therefore prepared at most once for all the sections, and no more
    /// chapters are held than the section being cut spans.
    private struct SpeechCutter {
        /// The book.
        let content: DocumentContent
        /// `content.allHeadings`.
        let headings: [Heading]
        /// The IDs of the book's skipped headings.
        let skippedHeadingIDs: Set<String>
        /// The settings each chapter is prepared with.
        let settings: SpeechPreparationSettings
        /// The prepared speech of the chapters from the current section's
        /// first on, by chapter index.
        private var prepared: [Int: ReaderViewModel.ChapterSpeech] = [:]

        /// A cutter that has prepared nothing yet.
        init(
            content: DocumentContent,
            headings: [Heading],
            skippedHeadingIDs: Set<String>,
            settings: SpeechPreparationSettings
        ) {
            self.content = content
            self.headings = headings
            self.skippedHeadingIDs = skippedHeadingIDs
            self.settings = settings
        }

        /// The pieces of the section from `start` to `end`: one for each
        /// chapter from `start`'s through `end`'s, each the slice of that
        /// chapter's speech the section covers, from its start in the first
        /// chapter (from the speech's start in every other) to its end in
        /// the last (to the speech's end in every other). An `end` before
        /// `start` is taken as `start`, an empty section.
        mutating func pieces(from start: Place, to end: Place) -> [SpeechExportSection.Piece] {
            let end = max(start, end)
            // No later section needs a chapter before this one's first.
            prepared = prepared.filter { $0.key >= start.chapterIndex }

            var pieces: [SpeechExportSection.Piece] = []
            for chapterIndex in start.chapterIndex...end.chapterIndex {
                let speech = preparedSpeech(ofChapterAt: chapterIndex)
                let lower = chapterIndex == start.chapterIndex ? Self.spokenOffset(of: start.offset, in: speech) : 0
                let upper = chapterIndex == end.chapterIndex
                    ? Self.spokenOffset(of: end.offset, in: speech)
                    : speech.text.utf16Length
                pieces.append(SpeechExportSection.Piece(
                    chapterIndex: chapterIndex,
                    text: Self.slice(of: speech.text, from: lower, to: upper)
                ))
            }
            return pieces
        }

        /// Chapter `index`'s prepared speech, prepared now unless it is kept
        /// already.
        private mutating func preparedSpeech(ofChapterAt index: Int) -> ReaderViewModel.ChapterSpeech {
            if let speech = prepared[index] { return speech }
            let speech = settings.inputs(
                forChapterAt: index,
                of: content,
                headings: headings,
                skippedHeadingIDs: skippedHeadingIDs
            ).prepare()
            prepared[index] = speech
            return speech
        }

        /// Where `offset`, in a chapter's text as the book holds it, falls in
        /// that chapter's prepared `speech`: the chapter's start and end are
        /// its speech's start and end, and any other offset is mapped through
        /// every stage of the preparation (`ComposedOffsetMap.toModified`).
        ///
        /// The start is not mapped because a substitution may put text before
        /// the chapter's first character (a rule matching the empty start of
        /// the text): mapped, the start would fall after that text, and the
        /// book's first section would leave it out. Taken as the speech's
        /// start, that text begins the section that begins the chapter, as it
        /// begins the chapter's speech. The end maps to the speech's end
        /// through every stage already; it is taken as such for symmetry, and
        /// so that no stage could ever drop the speech's last words.
        private static func spokenOffset(of offset: Int, in speech: ReaderViewModel.ChapterSpeech) -> Int {
            if offset <= 0 { return 0 }
            if offset >= speech.inputs.text.utf16Length { return speech.text.utf16Length }
            return speech.offsetMap.toModified(offset)
        }

        /// The part of `text` between UTF-16 offsets `lower` and `upper`, each
        /// clamped into the text and `upper` to no less than `lower`, cut
        /// where `index(atUTF16Offset:)` places them: on a character's
        /// boundary, so a piece that ends inside a character ends before it,
        /// and the next piece, which begins at the same offset, begins with
        /// it.
        private static func slice(of text: String, from lower: Int, to upper: Int) -> String {
            let length = text.utf16Length
            let start = min(max(0, lower), length)
            let end = min(max(start, upper), length)
            return String(text[text.index(atUTF16Offset: start)..<text.index(atUTF16Offset: end)])
        }
    }
}
