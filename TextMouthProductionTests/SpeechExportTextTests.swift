import Foundation
import XCTest
@testable import TextMouth

/// The text a speech export speaks (FMT43): a book, or a range of its
/// headings, as the reader speaks it, split into a section for each heading
/// and one for the text before the first (`SpeechExportText`).
///
/// The oracle is the reader itself: for the whole book, each chapter's
/// pieces, joined in order, are exactly the speech the reader prepares for
/// that chapter, with every stage of the preparation in play. The other
/// tests prepare speech as the text is written (`asWritten`), so a piece is
/// a plain slice of a chapter's text and can be spelled out.
///
/// No test starts speech: the reader is only asked for its prepared text,
/// and its look-ahead renders wait in a stand-in queue that renders nothing.
@MainActor
final class SpeechExportTextTests: XCTestCase {

    // MARK: - The reader's speech

    /// For the whole book, each chapter's pieces, joined in order, are the
    /// speech the reader prepares for that chapter: text before the first
    /// heading, a level-2 heading, a heading on two lines, a skipped
    /// heading, a substitution rule, a run of a repeated symbol, and pause
    /// level 2 all shape it. The inputs the settings build for each chapter
    /// are the reader's own.
    func testTheWholeBookIsWhatTheReaderSpeaks() throws {
        let rule = SubstitutionRule(pattern: "towpath", replacement: "tow path")
        try withReader(skipping: ["Ice Days"], substitutions: [rule], pauseLevel: 2) { reader, book, defaults in
            let content = try XCTUnwrap(reader.content)
            let settings = SpeechPreparationSettings.current(substitutions: reader.substitutionService, defaults: defaults)
            let skipped = Set(book.skippedHeadingIDs ?? [])
            XCTAssertEqual(skipped.count, 1, "The ledger skips one heading.")

            let sections = try SpeechExportText.allSections(
                of: content,
                range: .wholeBook,
                skippedHeadingIDs: skipped,
                settings: settings,
                bookTitle: Self.bookTitle
            )
            var speech: [String] = []
            for chapterIndex in content.chapters.indices {
                let inputs = settings.inputs(
                    forChapterAt: chapterIndex,
                    of: content,
                    headings: content.allHeadings,
                    skippedHeadingIDs: skipped
                )
                XCTAssertEqual(inputs, reader.speechInputs(forChapterAt: chapterIndex), "Chapter \(chapterIndex)")
                let spoken = try XCTUnwrap(reader.preparedSpeech(forChapterAt: chapterIndex)?.text)
                XCTAssertEqual(Self.text(ofChapter: chapterIndex, in: sections), spoken, "Chapter \(chapterIndex)")
                speech.append(spoken)
            }

            // Every stage shaped the speech compared, so the comparison
            // covers each of them.
            let allSpeech = speech.joined()
            XCTAssertTrue(allSpeech.contains(".. "), "A sentence's end gets a pause at level 1 and up.")
            XCTAssertTrue(allSpeech.contains(",, "), "A comma gets a pause at level 2.")
            XCTAssertFalse(allSpeech.contains("No boat moved"), "The skipped section is left out.")
            XCTAssertFalse(allSpeech.contains("* * * *"), "The run of asterisks is read as a count.")
            XCTAssertTrue(allSpeech.contains("tow path"), "The substitution rule applies.")
        }
    }

    /// A substitution that puts text before a chapter's first character (a
    /// regular expression matching the empty start of the text) is spoken at
    /// the start of the section that begins the chapter: the book's opening
    /// section keeps it, and so does a heading that opens a chapter. Each
    /// chapter's pieces are still its whole speech.
    func testTextPutBeforeAChaptersStartBeginsTheSectionThatBeginsTheChapter() throws {
        let service = TextSubstitutionService(rules: [SubstitutionRule(pattern: "^", replacement: "Entry: ", isRegex: true)])
        var settings = Self.asWritten
        settings.substitutions = service.substitutionPass
        let content = Self.ledger
        let sections = try SpeechExportText.allSections(
            of: content,
            range: .wholeBook,
            skippedHeadingIDs: [],
            settings: settings,
            bookTitle: Self.bookTitle
        )

        for chapterIndex in content.chapters.indices {
            let inputs = settings.inputs(forChapterAt: chapterIndex, of: content, headings: content.allHeadings, skippedHeadingIDs: [])
            let spoken = inputs.prepare().text
            XCTAssertTrue(spoken.hasPrefix("Entry: "), "Chapter \(chapterIndex)")
            XCTAssertEqual(Self.text(ofChapter: chapterIndex, in: sections), spoken, "Chapter \(chapterIndex)")
        }
        let opening = try XCTUnwrap(sections.first)
        XCTAssertEqual(opening.texts, ["Entry: \(Self.lead)\n\n"])
        let tolls = try XCTUnwrap(sections.first { $0.title == "Tolls and Fines" })
        XCTAssertEqual(tolls.texts.first?.hasPrefix("Entry: Tolls and\nFines"), true)
    }

    // MARK: - Sections and ranges

    /// The whole book is the text before its first heading, under the
    /// book's title, then a section for each heading, in reading order, each
    /// ending where the next begins.
    func testTheWholeBookIsItsOpeningThenASectionForEachHeading() throws {
        let content = Self.ledger
        let all = try sections(of: content)

        XCTAssertEqual(all.map(\.title), [Self.bookTitle] + Self.ledgerTitles)
        XCTAssertEqual(all.map(\.headingID), [nil] + content.allHeadings.map { Optional($0.id) })
        XCTAssertEqual(all.flatMap(\.texts).joined(), content.chapters.map(\.text).joined())
        XCTAssertEqual(try sections(of: content, spokenOnly: true).map(\.title), [Self.bookTitle] + Self.ledgerTitles)
    }

    /// A range through a heading takes its subheadings with it, up to the
    /// next heading of its level or above: through a level-1 heading, its
    /// level-2 and level-3 headings; through a level-2 heading, its level-3
    /// heading, and not the next heading of level 2 or level 1.
    func testARangeThroughAHeadingTakesItsSubheadings() throws {
        let content = Self.ledger

        let locks = try sections(of: content, range: range(from: "Locks", through: "Locks", in: content))
        XCTAssertEqual(locks.map(\.title), ["Locks", "The Upper Gate", "Hinges", "The Lower Gate"])
        let upperGate = try sections(of: content, range: range(from: "The Upper Gate", through: "The Upper Gate", in: content))
        XCTAssertEqual(upperGate.map(\.title), ["The Upper Gate", "Hinges"])
        let lowerGate = try sections(of: content, range: range(from: "The Lower Gate", through: "The Lower Gate", in: content))
        XCTAssertEqual(lowerGate.map(\.title), ["The Lower Gate"])
        let repairs = try sections(of: content, range: range(from: "Repairs", through: "Repairs", in: content))
        XCTAssertEqual(repairs.map(\.title), ["Repairs"])
    }

    /// A range of one heading is that heading's section, up to the next
    /// heading of any level; a range from a heading leaves out everything
    /// before it; a range from the beginning has the text before the first
    /// heading, under the book's title.
    func testARangeHoldsItsHeadingsSectionsAndTheOpeningOnlyFromTheBeginning() throws {
        let content = Self.ledger

        let hingesID = try headingID("Hinges", in: content)
        let hinges = try sections(of: content, range: range(from: "Hinges", through: "Hinges", in: content))
        XCTAssertEqual(hinges, [SpeechExportSection(
            title: "Hinges",
            headingID: hingesID,
            pieces: [.init(chapterIndex: 0, text: "Hinges\n\nThey wanted grease, and the clerk wrote so twice.\n\n")]
        )])

        let fromTolls = try sections(of: content, range: range(from: "Tolls and\nFines", in: content))
        XCTAssertEqual(fromTolls.map(\.title), ["Tolls and Fines", "Ice Days", "Repairs", "Closing"])
        XCTAssertEqual(fromTolls.flatMap(\.texts).joined(), content.chapters.dropFirst().map(\.text).joined())

        let throughLocks = try sections(of: content, range: range(through: "Locks", in: content))
        XCTAssertEqual(throughLocks.map(\.title), [Self.bookTitle, "Locks", "The Upper Gate", "Hinges", "The Lower Gate"])
        XCTAssertEqual(throughLocks.first, SpeechExportSection(
            title: Self.bookTitle,
            headingID: nil,
            pieces: [.init(chapterIndex: 0, text: "\(Self.lead)\n\n")]
        ))
        XCTAssertEqual(throughLocks.flatMap(\.texts).joined(), content.chapters.first?.text)
    }

    /// A section that runs on into later chapters has a piece for each
    /// chapter it spans in `allSections`, and only the pieces with something
    /// to speak in `sections`, which also leaves out a section with none.
    func testASectionSpanningChaptersHasAPieceForEachChapter() throws {
        let content = Self.content([
            Self.chapter(sections: [(1, "Survey", "Soundings were taken at every lock.")]),
            Chapter(title: "", text: "\n\n"),
            Self.chapter(lead: "The soundings follow.", sections: [(1, "Soundings", "Four feet at the sill.")]),
        ])

        let all = try sections(of: content)
        XCTAssertEqual(all.map(\.title), [Self.bookTitle, "Survey", "Soundings"])
        let survey = try XCTUnwrap(all.first { $0.title == "Survey" })
        XCTAssertEqual(survey.pieces, [
            .init(chapterIndex: 0, text: "Survey\n\nSoundings were taken at every lock."),
            .init(chapterIndex: 1, text: "\n\n"),
            .init(chapterIndex: 2, text: "The soundings follow.\n\n"),
        ])

        // The opening is empty, the book beginning with its first heading.
        let spoken = try sections(of: content, spokenOnly: true)
        XCTAssertEqual(spoken.map(\.title), ["Survey", "Soundings"])
        let spokenSurvey = try XCTUnwrap(spoken.first)
        XCTAssertEqual(spokenSurvey.pieces.map(\.chapterIndex), [0, 2])
        XCTAssertEqual(spokenSurvey.texts, ["Survey\n\nSoundings were taken at every lock.", "The soundings follow.\n\n"])
    }

    /// A skipped heading's section is not spoken: `allSections` keeps it,
    /// with nothing to speak, and `sections` leaves it out. The sections
    /// around it are as they were.
    func testASkippedHeadingsSectionIsNotSpoken() throws {
        let content = Self.ledger
        let iceDaysID = try headingID("Ice Days", in: content)

        let all = try sections(of: content, skipping: ["Ice Days"])
        let iceDays = try XCTUnwrap(all.first { $0.headingID == iceDaysID })
        XCTAssertEqual(iceDays.pieces, [.init(chapterIndex: 1, text: "")])
        XCTAssertFalse(iceDays.pieces.contains { ReaderViewModel.hasSpeakableText($0.text) })

        let spoken = try sections(of: content, skipping: ["Ice Days"], spokenOnly: true)
        XCTAssertEqual(spoken.map(\.title), [Self.bookTitle] + Self.ledgerTitles.filter { $0 != "Ice Days" })
        XCTAssertFalse(spoken.contains { $0.headingID == iceDaysID })
        let tolls = try XCTUnwrap(spoken.first { $0.title == "Tolls and Fines" })
        XCTAssertEqual(tolls.texts, ["Tolls and\nFines\n\nCoal paid by the ton, timber by the length.\n\n* * * * * * *\n\n"])
        let repairs = try XCTUnwrap(spoken.first { $0.title == "Repairs" })
        XCTAssertEqual(repairs.texts.first, "Repairs\n\nMasons relaid the towpath by the cafe\u{301} for twelve pounds.")
    }

    /// A range naming a heading the book lacks throws, whichever end names
    /// it; a range that ends before it begins holds nothing; a book without
    /// headings is one section named after the book; a book without chapters
    /// has no section.
    func testUnknownHeadingsReversedRangesAndBooksWithoutHeadingsOrChapters() throws {
        let content = Self.ledger
        let locksID = try headingID("Locks", in: content)
        let unknownEnds = [
            SpeechExportRange(fromHeadingID: "no-such-heading"),
            SpeechExportRange(throughHeadingID: "no-such-heading"),
            SpeechExportRange(fromHeadingID: locksID, throughHeadingID: "no-such-heading"),
        ]
        for unknown in unknownEnds {
            for spokenOnly in [false, true] {
                XCTAssertThrowsError(try sections(of: content, range: unknown, spokenOnly: spokenOnly)) { error in
                    XCTAssertEqual(error as? SpeechExportText.Failure, .headingNotFound("no-such-heading"))
                }
            }
        }

        let reversed = try range(from: "Closing", through: "Locks", in: content)
        XCTAssertEqual(try sections(of: content, range: reversed), [])
        XCTAssertEqual(try sections(of: content, range: reversed, spokenOnly: true), [])

        let unheaded = Self.content([
            Chapter(title: "One", text: "Nothing here is marked as a heading."),
            Chapter(title: "Two", text: "Nor here."),
        ])
        XCTAssertEqual(try sections(of: unheaded), [SpeechExportSection(
            title: Self.bookTitle,
            headingID: nil,
            pieces: [
                .init(chapterIndex: 0, text: "Nothing here is marked as a heading."),
                .init(chapterIndex: 1, text: "Nor here."),
            ]
        )])

        XCTAssertEqual(try sections(of: Self.content([])), [])
        XCTAssertEqual(try sections(of: Self.content([]), spokenOnly: true), [])
    }

    /// A section's title is one line: each run of white space in its
    /// heading's text, line breaks included, is one space, and none is left
    /// at either end. A heading with blank text, and the opening, take the
    /// book's title, on one line too.
    func testTitlesAreOneLineAndABlankHeadingTakesTheBooksTitle() throws {
        let content = Self.content([
            Self.chapter(sections: [
                (1, "  Sluice\t\tKeepers \r\n of the\u{2028}Lower Reach  ", "Two keepers shared one cottage."),
                (2, " \n\t ", "A heading with no words."),
            ]),
        ])

        let all = try sections(of: content, bookTitle: "The Canal\nLedger ")
        XCTAssertEqual(all.map(\.title), ["The Canal Ledger", "Sluice Keepers of the Lower Reach", "The Canal Ledger"])
    }

    /// A section's texts are its pieces' texts, in order; its UTF-16 length
    /// and word count are their totals, the length counting UTF-16 units,
    /// not characters.
    func testASectionsTextsLengthAndWordCountAreItsPiecesTotals() throws {
        let repairs = try XCTUnwrap(sections(of: Self.ledger).first { $0.title == "Repairs" })

        XCTAssertEqual(repairs.texts, [
            "Repairs\n\nMasons relaid the towpath by the cafe\u{301} for twelve pounds.",
            "Added later, in another hand.\n\n",
        ])
        // 66 units (65 characters, the accented e being two units) and 31.
        XCTAssertEqual(repairs.utf16Length, 97)
        // 11 words and 5.
        XCTAssertEqual(repairs.wordCount, 16)
    }

    /// The whole book's range names no heading; a range naming either end
    /// is not the whole book.
    func testOnlyARangeNamingNoHeadingIsTheWholeBook() {
        XCTAssertTrue(SpeechExportRange.wholeBook.isWholeBook)
        XCTAssertTrue(SpeechExportRange().isWholeBook)
        XCTAssertFalse(SpeechExportRange(fromHeadingID: "a").isWholeBook)
        XCTAssertFalse(SpeechExportRange(throughHeadingID: "b").isWholeBook)
    }

    // MARK: - The settings in force

    /// The settings in force read the pause level stored in the preferences
    /// given, validated (none stored is 0, 1 is 1, 99 is clamped to 3), and
    /// the repeated-symbol rule and substitution rules of the service given;
    /// a service with substitutions off has none.
    func testTheCurrentSettingsReadThePauseLevelAndTheServicesRules() {
        let rule = SubstitutionRule(pattern: "towpath", replacement: "tow path")
        let service = TextSubstitutionService(rules: [rule])
        service.repeatedSymbolStyle = .leaveOut
        let defaults = makeSandboxedPreferences("speech-export-text-current")
        let key = SettingsPolicy.punctuationPauseLevel.key

        XCTAssertEqual(SpeechPreparationSettings.current(substitutions: service, defaults: defaults).punctuationPauseLevel, 0)
        defaults.set(1.0, forKey: key)
        let settings = SpeechPreparationSettings.current(substitutions: service, defaults: defaults)
        XCTAssertEqual(settings.punctuationPauseLevel, 1)
        XCTAssertEqual(settings.repeatedSymbolRule, service.repeatedSymbolRule)
        XCTAssertEqual(settings.repeatedSymbolRule.style, .leaveOut)
        XCTAssertEqual(settings.substitutions, service.substitutionPass)
        XCTAssertEqual(settings.substitutions.rules.map(\.rule), [rule])
        defaults.set(99.0, forKey: key)
        XCTAssertEqual(SpeechPreparationSettings.current(substitutions: service, defaults: defaults).punctuationPauseLevel, 3)

        let switchedOff = TextSubstitutionService(rules: [rule], isEnabled: false)
        XCTAssertEqual(SpeechPreparationSettings.current(substitutions: switchedOff, defaults: defaults).substitutions, SubstitutionPass.none)
    }

    // MARK: - Fixtures

    /// The title of every test book, which names the text before its first
    /// heading.
    private static let bookTitle = "The Canal Ledger"

    /// The ledger's first chapter's text before its first heading.
    private static let lead = "Copied by hand from the canal company's ledger; spellings vary."

    /// A canal company's ledger in three chapters: text before the first
    /// heading; headings of levels 1, 2, and 3; a heading on two lines; a
    /// run of asterisks; and a section that runs on into the next chapter's
    /// text before its first heading.
    private static let ledger = content([
        chapter(lead: lead, sections: [
            (1, "Locks", "The first lock opened at six. Barges waited two abreast for the bell."),
            (2, "The Upper Gate", "It wanted new oak by spring."),
            (3, "Hinges", "They wanted grease, and the clerk wrote so twice."),
            (2, "The Lower Gate", "It leaked at the sill all summer."),
        ]),
        chapter(sections: [
            (1, "Tolls and\nFines", "Coal paid by the ton, timber by the length.\n\n* * * * * * *"),
            (1, "Ice Days", "No boat moved for nine days in January."),
            (2, "Repairs", "Masons relaid the towpath by the cafe\u{301} for twelve pounds."),
        ]),
        chapter(lead: "Added later, in another hand.", sections: [
            (1, "Closing", "The ledger stops partway down a page."),
        ]),
    ])

    /// The ledger's sections' titles, in reading order, after its opening.
    private static let ledgerTitles = [
        "Locks", "The Upper Gate", "Hinges", "The Lower Gate", "Tolls and Fines", "Ice Days", "Repairs", "Closing",
    ]

    /// Settings that prepare speech as the text is written: runs of a symbol
    /// read as written, no pauses, and no substitutions, so a chapter's
    /// speech is its text with only the skipped sections taken out.
    private static let asWritten = SpeechPreparationSettings(
        repeatedSymbolRule: RepeatedSymbolRule(
            style: .repeatEach,
            threshold: SettingsPolicy.repeatedSymbolThreshold.defaultValue,
            symbols: SettingsPolicy.repeatedSymbolSet.defaultValue
        ),
        punctuationPauseLevel: 0,
        substitutions: .none
    )

    /// A book titled `bookTitle` made of `chapters`.
    private static func content(_ chapters: [Chapter]) -> DocumentContent {
        DocumentContent(title: bookTitle, author: "Test Author", chapters: chapters)
    }

    /// A chapter of `lead`, its text before its first heading (none when
    /// empty), then each section: its heading, of its level, on a paragraph
    /// of its own, then its body, the paragraphs apart by a blank line. Each
    /// heading's offset is measured from the assembled text, as a parse
    /// records it.
    private static func chapter(lead: String = "", sections: [(level: Int, heading: String, body: String)]) -> Chapter {
        var text = lead
        var headings: [Heading] = []
        for section in sections {
            if !text.isEmpty { text += "\n\n" }
            headings.append(Heading(level: section.level, text: section.heading, characterOffset: text.utf16.count))
            text += "\(section.heading)\n\n\(section.body)"
        }
        return Chapter(title: sections.first?.heading ?? "", text: text, headings: headings)
    }

    /// The texts of the pieces of `sections` from chapter `chapterIndex`,
    /// joined in order.
    private static func text(ofChapter chapterIndex: Int, in sections: [SpeechExportSection]) -> String {
        sections.flatMap(\.pieces).filter { $0.chapterIndex == chapterIndex }.map(\.text).joined()
    }

    /// The ID of the heading of `content` whose text is `text`.
    private func headingID(_ text: String, in content: DocumentContent) throws -> String {
        try XCTUnwrap(content.allHeadings.first { $0.text == text }?.id, "No heading \(text)")
    }

    /// The range of `content` from the heading whose text is `from` through
    /// the one whose text is `through`, nil standing for the book's
    /// beginning or end.
    private func range(from: String? = nil, through: String? = nil, in content: DocumentContent) throws -> SpeechExportRange {
        try SpeechExportRange(
            fromHeadingID: from.map { try headingID($0, in: content) },
            throughHeadingID: through.map { try headingID($0, in: content) }
        )
    }

    /// What `SpeechExportText` makes of `range` in `content`, its speech
    /// prepared as written, with the headings whose texts are in `skipped`
    /// skipped: every section (`allSections`), or only what an export speaks
    /// (`sections`) when `spokenOnly` is set.
    ///
    /// - Parameter bookTitle: The book's title; the test books' when nil.
    private func sections(
        of content: DocumentContent,
        range: SpeechExportRange = .wholeBook,
        skipping skipped: Set<String> = [],
        bookTitle: String? = nil,
        spokenOnly: Bool = false
    ) throws -> [SpeechExportSection] {
        let skippedIDs = Set(content.allHeadings.filter { skipped.contains($0.text) }.map(\.id))
        let title = bookTitle ?? Self.bookTitle
        if spokenOnly {
            return try SpeechExportText.sections(
                of: content,
                range: range,
                skippedHeadingIDs: skippedIDs,
                settings: Self.asWritten,
                bookTitle: title
            )
        }
        return try SpeechExportText.allSections(
            of: content,
            range: range,
            skippedHeadingIDs: skippedIDs,
            settings: Self.asWritten,
            bookTitle: title
        )
    }

    /// Run `body` with a reader holding the ledger, then close it. Shaped
    /// like `SpeechPreparationCacheTests`' reader: its own substitution
    /// service with `substitutions` and no store, so a test's rules reach
    /// nothing else; preferences in a private sandboxed store, holding
    /// `pauseLevel`; its own notification centers; look-ahead renders held
    /// in a queue that renders nothing; and VoiceOver announcements recorded
    /// instead of spoken.
    ///
    /// - Parameters:
    ///   - skippedHeadings: Text of every heading whose section is skipped.
    ///   - substitutions: The reader's text substitution rules.
    ///   - pauseLevel: The punctuation pause level stored in the preferences.
    ///   - body: Given the reader, its book (with the skipped headings'
    ///     IDs), and its preferences.
    private func withReader(
        skipping skippedHeadings: Set<String>,
        substitutions: [SubstitutionRule],
        pauseLevel: Double,
        _ body: (ReaderViewModel, Book, UserDefaults) throws -> Void
    ) throws {
        let defaults = makeSandboxedPreferences("speech-export-text")
        defaults.set(pauseLevel, forKey: SettingsPolicy.punctuationPauseLevel.key)
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: defaults
        )

        let content = Self.ledger
        // A unique missing path keeps the reader's own loader from replacing
        // this content or sharing persisted state with another fixture.
        var book = Book(
            title: Self.bookTitle,
            format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-canal-ledger.txt",
            md5Hash: UUID().uuidString
        )
        book.skippedHeadingIDs = content.allHeadings
            .filter { skippedHeadings.contains($0.text) }
            .map(\.id)
        let library = LibraryViewModel()
        library.library = Library(books: [book])

        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: settings,
            substitutionService: TextSubstitutionService(rules: substitutions),
            notificationCenter: NotificationCenter(),
            renderScheduler: HeldRenderQueue()
        )
        reader.content = content
        reader.isLoading = false
        defer { reader.close() }
        try recordingAnnouncements {
            try body(reader, book, defaults)
        }
    }
}
