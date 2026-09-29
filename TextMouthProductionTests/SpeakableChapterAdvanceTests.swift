import XCTest
@testable import TextMouth

/// Playback passes over chapters whose prepared speech has nothing to say
/// (every section skipped, or all text deleted by substitutions) exactly as
/// it passes over empty chapters.
@MainActor
final class SpeakableChapterAdvanceTests: XCTestCase {

    // MARK: - Speakable text

    /// Whitespace and line breaks of every kind give the synthesizer nothing
    /// to say, including the no-break and wide spaces documents often carry.
    func testWhitespaceAndLineBreaksAloneAreNotSpeakable() {
        let silentTexts = [
            "", " ", "\n\n", "\t \r\n",
            "\u{00A0}\u{2003}\u{3000}",  // No-break, em, and ideographic spaces.
            "\u{2028}\u{2029}\u{0085}",  // Line and paragraph separators, next line.
        ]
        for text in silentTexts {
            XCTAssertFalse(ReaderViewModel.hasSpeakableText(text), text.debugDescription)
        }
    }

    /// Any other character counts, including punctuation, emoji, and
    /// non-Latin digits; a substring is judged exactly like a string.
    func testAnyOtherCharacterIsSpeakable() {
        for text in ["a", "  word  ", "\n.\n", "🎙️", "٣"] {
            XCTAssertTrue(ReaderViewModel.hasSpeakableText(text), text.debugDescription)
        }
        let sentence = "Spoken words.\n\n"
        XCTAssertTrue(ReaderViewModel.hasSpeakableText(sentence.prefix(6)))
        XCTAssertFalse(ReaderViewModel.hasSpeakableText(sentence.suffix(2)))
    }

    /// Pause marks never make blank text speakable: whitespace alone comes
    /// back unchanged, with no offset shifts, at every pause level, while
    /// text with words still gets its paragraph pause.
    func testPunctuationPausesLeaveBlankTextUnchanged() {
        let blank = " \n\n\t\n\n "
        for level in [1.0, 2, 3] {
            let result = ReaderViewModel.applyPunctuationPauses(blank, level: level)
            XCTAssertEqual(result.text, blank, "level \(level)")
            XCTAssertFalse(result.offsetMap.hasChanges, "level \(level)")
        }
        XCTAssertEqual(ReaderViewModel.applyPunctuationPauses("One\n\nTwo", level: 3).text, "One\n\n.\n\nTwo")
    }

    // MARK: - Next speakable chapter search

    /// A speakable starting chapter is found without looking further.
    func testSearchReturnsASpeakableStartingChapter() {
        var asked: [Int] = []
        let found = ReaderViewModel.nextSpeakableChapterIndex(from: 2, chapterCount: 5) { index in
            asked.append(index)
            return true
        }

        XCTAssertEqual(found, 2)
        XCTAssertEqual(asked, [2])
    }

    /// Silent chapters are passed over in order until a speakable one.
    func testSearchPassesOverSilentChapters() {
        let speakable = [false, false, false, true, true]
        var asked: [Int] = []
        let found = ReaderViewModel.nextSpeakableChapterIndex(from: 0, chapterCount: speakable.count) { index in
            asked.append(index)
            return speakable[index]
        }

        XCTAssertEqual(found, 3)
        XCTAssertEqual(asked, [0, 1, 2, 3])
    }

    /// When every remaining chapter is silent the search reports none,
    /// having asked about each remaining chapter exactly once.
    func testSearchAsksAboutEachRemainingChapterOnceThenReportsNone() {
        var asked: [Int] = []
        let found = ReaderViewModel.nextSpeakableChapterIndex(from: 1, chapterCount: 5) { index in
            asked.append(index)
            return false
        }

        XCTAssertNil(found)
        XCTAssertEqual(asked, [1, 2, 3, 4])
    }

    /// Speakable chapters before the start are never reached: the search
    /// does not wrap around to the beginning of the book.
    func testSearchNeverWrapsToEarlierChapters() {
        let speakable = [true, true, false, false]
        let found = ReaderViewModel.nextSpeakableChapterIndex(from: 2, chapterCount: speakable.count) {
            speakable[$0]
        }

        XCTAssertNil(found)
    }

    /// A negative start searches from the first chapter, and a start at or
    /// past the end (including an empty book) finds nothing without asking.
    func testSearchKeepsItsStartInsideTheBook() {
        XCTAssertEqual(ReaderViewModel.nextSpeakableChapterIndex(from: -3, chapterCount: 2) { _ in true }, 0)

        for (start, count) in [(2, 2), (7, 2), (0, 0), (-1, 0)] {
            var wasAsked = false
            let found = ReaderViewModel.nextSpeakableChapterIndex(from: start, chapterCount: count) { _ in
                wasAsked = true
                return true
            }
            XCTAssertNil(found, "start \(start) of \(count)")
            XCTAssertFalse(wasAsked, "start \(start) of \(count)")
        }
    }

    // MARK: - Speakable chapters in a reader

    /// A chapter entirely inside a skipped heading section is passed over,
    /// and the speech found is the next chapter's full text.
    func testChapterEntirelyInsideASkippedSectionIsPassedOver() throws {
        try withReader(
            chapters: [
                chapter(sections: [("Front Matter", "Copyright notice.")]),
                Chapter(title: "One", text: "The story begins."),
            ],
            skipping: ["Front Matter"]
        ) { reader in
            let speech = try XCTUnwrap(reader.nextSpeakableChapterSpeech(from: 0))

            XCTAssertEqual(speech.chapterIndex, 1)
            XCTAssertEqual(speech.text, "The story begins.")
        }
    }

    /// Skipping one of a chapter's sections leaves the rest speakable.
    func testPartlySkippedChapterStaysSpeakable() throws {
        try withReader(
            chapters: [chapter(sections: [("Prologue", "Opening words."), ("Acknowledgments", "Thanks.")])],
            skipping: ["Acknowledgments"]
        ) { reader in
            let speech = try XCTUnwrap(reader.nextSpeakableChapterSpeech(from: 0))

            XCTAssertEqual(speech.chapterIndex, 0)
            XCTAssertEqual(speech.text, "Prologue\n\nOpening words.\n\n")
        }
    }

    /// A substitution that deletes all of a chapter's text, such as
    /// removing illustration markers from a plate-only chapter, silences it.
    func testSubstitutionThatDeletesAllTextSilencesAChapter() throws {
        try withReader(
            chapters: [
                Chapter(title: "Plate", text: "[Illustration: The harbour at dawn]\n"),
                Chapter(title: "Two", text: "Words remain here."),
            ],
            substitutions: [Self.illustrationRemoval]
        ) { reader in
            let speech = try XCTUnwrap(reader.nextSpeakableChapterSpeech(from: 0))

            XCTAssertEqual(speech.chapterIndex, 1)
            XCTAssertNil(reader.nextSpeakableChapterSpeech(from: 2))
        }
    }

    /// Blank lines left in front of a skipped heading are not speakable, so
    /// the chapter counts as silent.
    func testBlankLinesBeforeASkippedSectionAreNotSpeakable() throws {
        try withReader(
            chapters: [chapterWithBlankLines(before: "Appendix", body: "Tables.")],
            skipping: ["Appendix"]
        ) { reader in
            XCTAssertEqual(reader.preparedSpeech(forChapterAt: 0)?.text, "\n\n")
            XCTAssertNil(reader.nextSpeakableChapterSpeech(from: 0))
        }
    }

    /// Heavy punctuation pauses do not turn those blank lines into a
    /// speakable pause mark, so the next chapter is still the one found.
    func testHeavyPausesLeaveASkippedChapterSilent() throws {
        try withReader(
            chapters: [
                chapterWithBlankLines(before: "Appendix", body: "Tables."),
                Chapter(title: "Index", text: "Entries follow."),
            ],
            skipping: ["Appendix"],
            punctuationPauseLevel: 3
        ) { reader in
            XCTAssertEqual(reader.preparedSpeech(forChapterAt: 0)?.text, "\n\n")
            XCTAssertEqual(reader.nextSpeakableChapterSpeech(from: 0)?.chapterIndex, 1)
        }
    }

    /// A book with no chapters has nothing to speak.
    func testEmptyBookHasNoSpeakableChapter() throws {
        try withReader(chapters: []) { reader in
            XCTAssertNil(reader.nextSpeakableChapterSpeech(from: 0))
        }
    }

    // MARK: - Fixtures

    /// Deletes every illustration marker, the kind of rule a listener adds
    /// for scanned books whose plates are captioned in brackets.
    private static let illustrationRemoval = SubstitutionRule(
        name: "Illustrations",
        pattern: "\\[Illustration[^\\]]*\\]",
        replacement: "",
        isRegex: true
    )

    /// A chapter made of sections that each start with a level-one heading.
    /// Heading offsets are measured from the assembled text, so a fixture's
    /// headings always sit exactly where its text says they do.
    private func chapter(sections: [(heading: String, body: String)]) -> Chapter {
        var text = ""
        var headings: [Heading] = []
        for section in sections {
            if !text.isEmpty { text += "\n\n" }
            headings.append(Heading(level: 1, text: section.heading, characterOffset: text.utf16.count))
            text += "\(section.heading)\n\n\(section.body)"
        }
        return Chapter(title: sections.first?.heading ?? "", text: text, headings: headings)
    }

    /// A chapter whose only section follows two blank lines, as converted
    /// documents often begin; skipping the section leaves just those lines.
    private func chapterWithBlankLines(before heading: String, body: String) -> Chapter {
        Chapter(
            title: heading,
            text: "\n\n\(heading)\n\n\(body)",
            headings: [Heading(level: 1, text: heading, characterOffset: 2)]
        )
    }

    /// Run `body` with a loaded, in-memory text reader over `chapters`, then
    /// close it and put back everything the reader could have changed.
    ///
    /// Preferences live in a private suite, written before the settings
    /// model reads them, so neither the user's settings nor the shared
    /// config file are touched. Substitution rules are the reader's own.
    /// Listening statistics are process-wide, so each run starts from empty
    /// statistics with no open session and restores the user's afterwards.
    ///
    /// - Parameters:
    ///   - chapters: The book's chapters, in reading order.
    ///   - skippedHeadings: Text of every heading whose section is skipped.
    ///   - endOfBook: The global end-of-book behavior.
    ///   - punctuationPauseLevel: The global punctuation pause level.
    ///   - substitutions: The reader's text substitution rules.
    ///   - position: The saved reading position the reader opens at.
    private func withReader(
        chapters: [Chapter],
        skipping skippedHeadings: Set<String> = [],
        endOfBook: EndOfBookBehavior = .stop,
        punctuationPauseLevel: Double = 0,
        substitutions: [SubstitutionRule] = [],
        at position: ReadingPosition? = nil,
        _ body: (ReaderViewModel) throws -> Void
    ) throws {
        let suiteName = "com.textmouth.tests.speakable-chapters.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(endOfBook.rawValue, forKey: SettingsPolicy.endOfBookBehavior.key)
        defaults.set(punctuationPauseLevel, forKey: SettingsPolicy.punctuationPauseLevel.key)
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: defaults
        )

        let content = DocumentContent(title: "Quiet Pages", author: "Test Author", chapters: chapters)
        // A unique missing path keeps the reader's own loader from replacing
        // this content or sharing persisted state with another fixture.
        var book = Book(
            title: "Quiet Pages",
            format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-quiet-pages.txt",
            md5Hash: UUID().uuidString,
            readingPosition: position
        )
        book.skippedHeadingIDs = content.allHeadings
            .filter { skippedHeadings.contains($0.text) }
            .map(\.id)
        let library = LibraryViewModel()
        library.library = Library(books: [book])

        let statistics = ReadingStatsService.shared
        let savedStatistics = statistics.stats
        statistics.endSession()
        statistics.stats = ReadingStats()

        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: settings,
            substitutionService: TextSubstitutionService(rules: substitutions)
        )
        reader.content = content
        reader.isLoading = false
        defer {
            reader.close()
            statistics.endSession()
            statistics.stats = savedStatistics
            statistics.save()
            defaults.removePersistentDomain(forName: suiteName)
        }
        try body(reader)
    }
}
