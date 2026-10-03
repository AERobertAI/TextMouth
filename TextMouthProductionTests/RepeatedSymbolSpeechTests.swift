import XCTest
@testable import TextMouth

/// Repeated symbols through the reader's real speech preparation: what a
/// chapter's speech says, how its offsets map back to the displayed text for
/// word highlighting, saved positions, and resuming, that a changed setting
/// applies to the next chapter prepared without reopening the book, and that
/// the displayed text never changes.
///
/// Look-ahead renders wait in a stand-in queue, and speech a test starts is
/// stopped before the main run loop turns, so nothing is heard.
@MainActor
final class RepeatedSymbolSpeechTests: XCTestCase {

    /// Two scenes with a spaced separator line of 7 asterisks between them.
    private static let sceneBreak = "The tide turned at dusk.\n\n* * * * * * *\n\nMorning came grey and still."

    /// The separator as written, in `sceneBreak`.
    private static let separator = "* * * * * * *"

    // MARK: - What speech says

    /// A separator line is spoken as a count, and the rest as written.
    func testASeparatorIsSpokenAsACount() throws {
        try withReader(chapters: [Chapter(title: "One", text: Self.sceneBreak)]) { reader in
            XCTAssertEqual(
                reader.preparedSpeech(forChapterAt: 0)?.text,
                "The tide turned at dusk.\n\n7 asterisks\n\nMorning came grey and still."
            )
        }
    }

    /// Each setting changed while the book is open applies to the next
    /// chapter prepared: the style, the threshold (inclusive, and -1), and
    /// the symbol set.
    func testEachSettingAppliesToTheNextChapterPrepared() throws {
        try withReader(chapters: [Chapter(title: "One", text: Self.sceneBreak)]) { reader in
            let service = reader.substitutionService
            let spoken = { reader.preparedSpeech(forChapterAt: 0)?.text }

            service.repeatedSymbolStyle = .leaveOut
            XCTAssertEqual(spoken(), "The tide turned at dusk.\n\n.\n\nMorning came grey and still.")

            service.repeatedSymbolStyle = .sayCount
            service.repeatedSymbolThreshold = 8
            XCTAssertEqual(spoken(), Self.sceneBreak, "7 symbols are fewer than 8")
            service.repeatedSymbolThreshold = 7
            XCTAssertEqual(spoken(), "The tide turned at dusk.\n\n7 asterisks\n\nMorning came grey and still.")
            service.repeatedSymbolThreshold = -1
            XCTAssertEqual(spoken(), Self.sceneBreak, "never collapse")

            service.repeatedSymbolThreshold = 4
            service.repeatedSymbolSet = "-="
            XCTAssertEqual(spoken(), Self.sceneBreak, "asterisks left out of the set")
            service.repeatedSymbolSet = "*"
            service.repeatedSymbolStyle = .repeatEach
            XCTAssertEqual(spoken(), Self.sceneBreak)
        }
    }

    /// Runs are counted before the punctuation pauses add their marks: with
    /// periods added to the set, "...." is 4 periods, not the 5 the pause
    /// after it would make.
    func testRunsAreCountedBeforePunctuationPausesLengthenThem() throws {
        try withReader(
            chapters: [Chapter(title: "One", text: "It ended.... Then dawn.")],
            punctuationPauseLevel: 1
        ) { reader in
            reader.substitutionService.repeatedSymbolSet = "."
            XCTAssertEqual(reader.preparedSpeech(forChapterAt: 0)?.text, "It ended 4 periods Then dawn.")
        }
    }

    /// A chapter holding nothing but separators has nothing to say once they
    /// are left out, so playback passes over it like an empty chapter.
    func testAChapterOfSeparatorsLeftOutIsPassedOver() throws {
        try withReader(chapters: [
            Chapter(title: "One", text: "First scene."),
            Chapter(title: "Break", text: "* * * * *\n\n= = = = ="),
            Chapter(title: "Three", text: "Second scene."),
        ]) { reader in
            XCTAssertEqual(reader.nextSpeakableChapterSpeech(from: 1)?.chapterIndex, 1, "a count is speech")

            reader.substitutionService.repeatedSymbolStyle = .leaveOut

            XCTAssertEqual(reader.nextSpeakableChapterSpeech(from: 1)?.chapterIndex, 2)
        }
    }

    // MARK: - Offsets

    /// Every word outside the separator maps exactly between the displayed
    /// and the spoken text, both ways; the count's words map into the
    /// separator, and every offset of the separator into the count.
    func testSpokenWordsMapBackToTheDisplayedText() throws {
        try withReader(chapters: [Chapter(title: "One", text: Self.sceneBreak)]) { reader in
            let speech = try XCTUnwrap(reader.preparedSpeech(forChapterAt: 0))
            let map = speech.offsetMap

            for word in ["The", "dusk", "Morning", "still"] {
                let displayed = try utf16Range(of: word, in: Self.sceneBreak).lowerBound
                let spoken = try utf16Range(of: word, in: speech.text).lowerBound
                XCTAssertEqual(map.toOriginal(spoken), displayed, word)
                XCTAssertEqual(map.toModified(displayed), spoken, word)
            }
            let separator = try utf16Range(of: Self.separator, in: Self.sceneBreak)
            let count = try utf16Range(of: "7 asterisks", in: speech.text)
            for spoken in count {
                XCTAssertTrue(separator.lowerBound...separator.upperBound ~= map.toOriginal(spoken), "spoken \(spoken)")
            }
            for displayed in separator {
                XCTAssertTrue(count.lowerBound...count.upperBound ~= map.toModified(displayed), "displayed \(displayed)")
            }
        }
    }

    /// The symbol stage composes with every other stage: a skipped section
    /// before it, the pause marks after it, and a substitution rule last.
    /// Words after all of them still map exactly.
    func testOffsetsComposeWithSkippedSectionsPausesAndSubstitutions() throws {
        let chapter = Self.chapter(sections: [
            ("Prologue", "Gulls, terns, and rain."),
            ("Shore", "The tide turned at dusk.\n\n- - - - -\n\nMorning, grey and still."),
        ])
        try withReader(
            chapters: [chapter],
            skipping: ["Prologue"],
            punctuationPauseLevel: 2,
            substitutions: [SubstitutionRule(pattern: "dusk", replacement: "nightfall")]
        ) { reader in
            let speech = try XCTUnwrap(reader.preparedSpeech(forChapterAt: 0))

            XCTAssertEqual(speech.text, "Shore\n\nThe tide turned at nightfall.\n\n5 hyphens\n\nMorning,, grey and still.")
            for word in ["Shore", "tide", "Morning", "grey", "still"] {
                let displayed = try utf16Range(of: word, in: chapter.text).lowerBound
                let spoken = try utf16Range(of: word, in: speech.text).lowerBound
                XCTAssertEqual(speech.offsetMap.toOriginal(spoken), displayed, word)
                XCTAssertEqual(speech.offsetMap.toModified(displayed), spoken, word)
            }
        }
    }

    /// Resuming from a saved position inside a separator starts speech
    /// inside its count, never in the scene after it, however deep in the
    /// separator the position is.
    func testResumingInsideASeparatorStartsInItsCount() throws {
        try withReader(chapters: [Chapter(title: "One", text: Self.sceneBreak)]) { reader in
            let separator = try utf16Range(of: Self.separator, in: Self.sceneBreak)
            let spoken = try XCTUnwrap(reader.preparedSpeech(forChapterAt: 0)).text
            let count = try utf16Range(of: "7 asterisks", in: spoken)

            for position in separator {
                reader.currentCharacterOffset = position
                let start = try XCTUnwrap(reader.speechStartFromCursor(), "position \(position)")
                XCTAssertEqual(start.speech.chapterIndex, 0)
                XCTAssertTrue(count.lowerBound...count.upperBound ~= start.offset, "position \(position) starts at \(start.offset)")
            }
            reader.currentCharacterOffset = separator.lowerBound
            XCTAssertEqual(reader.speechStartFromCursor()?.offset, count.lowerBound, "the start of the separator reads the whole count")
        }
    }

    /// Resuming inside a separator that closes its chapter and is left out
    /// moves on to the next chapter, as resuming in trailing blank lines does.
    func testResumingInsideAClosingSeparatorLeftOutMovesOn() throws {
        let closing = "The last line.\n\n* * * * *"
        try withReader(chapters: [
            Chapter(title: "One", text: closing),
            Chapter(title: "Two", text: "Next chapter."),
        ]) { reader in
            reader.substitutionService.repeatedSymbolStyle = .leaveOut
            reader.currentCharacterOffset = try utf16Range(of: "* * *", in: closing).lowerBound + 3

            XCTAssertEqual(reader.speechStartFromCursor()?.speech.chapterIndex, 1)
        }
    }

    /// While speech plays, each word the synthesizer reports moves the
    /// reading cursor to that word in the displayed text, so highlighting
    /// and the saved position follow the page: a word after the separator
    /// exactly, a word of the count onto the separator.
    func testSpokenWordsMoveTheCursorThroughTheDisplayedText() throws {
        try withReader(chapters: [Chapter(title: "One", text: Self.sceneBreak)]) { reader in
            reader.play()
            let spoken = try XCTUnwrap(reader.currentTransformation?.modifiedText)
            let separator = try utf16Range(of: Self.separator, in: Self.sceneBreak)

            let asterisks = try utf16Range(of: "asterisks", in: spoken)
            reader.speechService.onWordSpoken?(NSRange(asterisks), "asterisks")
            let cursorOnCount = reader.currentCharacterOffset
            let morning = try utf16Range(of: "Morning", in: spoken)
            reader.speechService.onWordSpoken?(NSRange(morning), "Morning")
            let cursorOnMorning = reader.currentCharacterOffset
            reader.savePosition()
            silence(reader)

            XCTAssertTrue(separator ~= cursorOnCount, "cursor \(cursorOnCount)")
            XCTAssertEqual(cursorOnMorning, try utf16Range(of: "Morning", in: Self.sceneBreak).lowerBound)
            XCTAssertEqual(reader.libraryViewModel.bookByID(reader.book.id)?.readingPosition?.characterOffset, cursorOnMorning)
        }
    }

    // MARK: - The displayed text

    /// Only speech changes: the book's text and the reader's visible text,
    /// which VoiceOver and a braille display read, keep the separator as
    /// written while it is spoken as a count.
    func testTheDisplayedTextKeepsTheSeparator() throws {
        try withReader(chapters: [Chapter(title: "One", text: Self.sceneBreak)]) { reader in
            reader.play()
            let spoken = reader.currentTransformation?.modifiedText
            silence(reader)
            reader.currentCharacterOffset = try utf16Range(of: Self.separator, in: Self.sceneBreak).lowerBound

            XCTAssertEqual(spoken?.contains("7 asterisks"), true)
            XCTAssertEqual(reader.content?.chapters.first?.text, Self.sceneBreak)
            XCTAssertTrue(
                waitUntil { reader.displayVisibleTextWindow.contains(Self.separator) },
                "visible text: \(reader.displayVisibleTextWindow.debugDescription)"
            )
            XCTAssertFalse(reader.displayVisibleTextWindow.contains("asterisks"))
        }
    }

    // MARK: - Helpers

    /// The UTF-16 offsets of the first `text` in `string`.
    private func utf16Range(of text: String, in string: String) throws -> Range<Int> {
        let range = try XCTUnwrap(string.range(of: text), text)
        return string.utf16Offset(of: range.lowerBound)..<string.utf16Offset(of: range.upperBound)
    }

    /// A chapter made of sections that each start with a level-one heading,
    /// with heading offsets measured from the assembled text.
    private static func chapter(sections: [(heading: String, body: String)]) -> Chapter {
        var text = ""
        var headings: [Heading] = []
        for section in sections {
            if !text.isEmpty { text += "\n\n" }
            headings.append(Heading(level: 1, text: section.heading, characterOffset: text.utf16.count))
            text += "\(section.heading)\n\n\(section.body)"
        }
        return Chapter(title: sections.first?.heading ?? "", text: text, headings: headings)
    }

    /// Stop the reader's speech before the main run loop turns, so a test
    /// that starts speech is never audible. Advancing the playback
    /// generation also keeps a queued look-ahead render from starting.
    private func silence(_ reader: ReaderViewModel) {
        reader.stop()
        reader.chapterPlaybackGeneration += 1
    }

    /// Run `body` with a loaded, in-memory text reader over `chapters`, then
    /// close it and put the reading statistics back as they were.
    ///
    /// The reader has a substitution service of its own, with no store, so
    /// its repeated-symbol settings start standard and a test's changes
    /// reach nothing else. Preferences live in a private sandboxed store,
    /// the reader posts on its own notification center, and look-ahead
    /// renders wait in a stand-in queue that never renders.
    ///
    /// - Parameters:
    ///   - chapters: The book's chapters, in reading order.
    ///   - skippedHeadings: Text of every heading whose section is skipped.
    ///   - punctuationPauseLevel: The global punctuation pause level.
    ///   - substitutions: The reader's text substitution rules.
    private func withReader(
        chapters: [Chapter],
        skipping skippedHeadings: Set<String> = [],
        punctuationPauseLevel: Double = 0,
        substitutions: [SubstitutionRule] = [],
        _ body: (ReaderViewModel) throws -> Void
    ) throws {
        let defaults = makeSandboxedPreferences("repeated-symbol-speech")
        defaults.set(punctuationPauseLevel, forKey: SettingsPolicy.punctuationPauseLevel.key)
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: defaults
        )

        let content = DocumentContent(title: "Scene Breaks", author: "Test Author", chapters: chapters)
        // A unique missing path keeps the reader's own loader from replacing
        // this content or sharing persisted state with another fixture.
        var book = Book(
            title: "Scene Breaks",
            format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-scene-breaks.txt",
            md5Hash: UUID().uuidString
        )
        book.skippedHeadingIDs = content.allHeadings
            .filter { skippedHeadings.contains($0.text) }
            .map(\.id)
        let library = LibraryViewModel()
        library.library = Library(books: [book])

        // Playing starts a listening session; keep it out of the statistics.
        let statistics = ReadingStatsService.shared
        let savedStatistics = statistics.stats
        statistics.endSession()
        statistics.stats = ReadingStats()

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
        defer {
            reader.close()
            statistics.endSession()
            statistics.stats = savedStatistics
            statistics.save()
        }
        try recordingAnnouncements {
            try body(reader)
        }
    }
}
