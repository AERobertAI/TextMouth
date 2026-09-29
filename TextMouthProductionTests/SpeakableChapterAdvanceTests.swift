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

    // MARK: - Starting playback

    /// A first chapter entirely inside a skipped heading section is passed
    /// over: speech starts at the top of the second chapter, and playback
    /// opens its listening session as usual.
    func testPlayStartsAfterAChapterEntirelyInsideASkippedSection() throws {
        try withReader(
            chapters: [
                chapter(sections: [("Front Matter", "Copyright notice.")]),
                Chapter(title: "One", text: "The story begins."),
            ],
            skipping: ["Front Matter"]
        ) { reader in
            reader.play()
            let startedSpeaking = reader.speechService.isSpeaking
            let openedSession = ReadingStatsService.shared.hasActiveSession
            silence(reader)

            XCTAssertTrue(startedSpeaking)
            XCTAssertTrue(openedSession)
            XCTAssertEqual(reader.currentChapterIndex, 1)
            XCTAssertEqual(reader.currentCharacterOffset, 0)
            XCTAssertEqual(reader.currentTransformation?.modifiedText, "The story begins.")
            XCTAssertNil(reader.lastAnnouncement)
        }
    }

    /// With every chapter skipped, Play ends the book through the configured
    /// Stop behavior at once. Nothing is spoken, the reader never shows
    /// Playing, no listening session starts, and the cursor stays put.
    func testPlayWithEveryChapterSkippedEndsTheBookWithoutPlaying() throws {
        try withReader(
            chapters: [
                chapter(sections: [("Foreword", "Praise.")]),
                chapter(sections: [("Notes", "Citations.")]),
            ],
            skipping: ["Foreword", "Notes"]
        ) { reader in
            reader.play()
            settle()

            assertEndedWithoutPlaying(reader, announcement: "Finished: Quiet Pages")
            XCTAssertEqual(reader.currentChapterIndex, 0)
            XCTAssertEqual(
                ReadingStatsService.shared.stats.finishedBooks.map(\.bookID),
                [reader.book.id.uuidString]
            )
        }
    }

    /// Continue to Next Book applies as configured: with no next book in the
    /// folder, a silent book ends with that behavior's own announcement.
    func testPlayOnASilentBookFollowsTheContinueBehavior() throws {
        try withReader(
            chapters: [chapter(sections: [("Notes", "Citations.")])],
            skipping: ["Notes"],
            endOfBook: .continueNext
        ) { reader in
            reader.play()
            settle()

            assertEndedWithoutPlaying(reader, announcement: "Finished: Quiet Pages. No more books in folder.")
        }
    }

    /// A substitution that deletes all of the book's text ends it exactly as
    /// skipping every section does.
    func testPlayEndsTheBookWhenSubstitutionsDeleteAllText() throws {
        try withReader(
            chapters: [
                Chapter(title: "Plate 1", text: "[Illustration: The harbour at dawn]"),
                Chapter(title: "Plate 2", text: "\n[Illustration]\n\n[Illustration: A map]\n"),
            ],
            substitutions: [Self.illustrationRemoval]
        ) { reader in
            reader.play()
            settle()

            assertEndedWithoutPlaying(reader, announcement: "Finished: Quiet Pages")
        }
    }

    /// Loop with nothing speakable anywhere ends in the stopped state after
    /// one pass over the book instead of restarting forever. Returning at
    /// all shows that it terminates.
    func testPlayWithLoopAndNothingSpeakableStopsAfterOnePass() throws {
        try withReader(
            chapters: [
                chapter(sections: [("Foreword", "Praise.")]),
                chapter(sections: [("Notes", "Citations.")]),
            ],
            skipping: ["Foreword", "Notes"],
            endOfBook: .loop
        ) { reader in
            reader.play()
            settle()

            assertEndedWithoutPlaying(reader, announcement: "Finished: Quiet Pages")
        }
    }

    /// When the rest of the book is silent but earlier text is not, Loop
    /// restarts and passes over the silent opening chapter to reach it.
    func testLoopRestartsAtTheFirstSpeakableChapter() throws {
        try withReader(
            chapters: [
                chapter(sections: [("Foreword", "Praise.")]),
                Chapter(title: "One", text: "The story begins."),
                chapter(sections: [("Notes", "Citations.")]),
            ],
            skipping: ["Foreword", "Notes"],
            endOfBook: .loop,
            at: ReadingPosition(chapterIndex: 2, characterOffset: 0)
        ) { reader in
            reader.play()
            let startedSpeaking = reader.speechService.isSpeaking
            silence(reader)

            XCTAssertTrue(startedSpeaking)
            XCTAssertEqual(reader.lastAnnouncement, "Restarting: Quiet Pages")
            XCTAssertEqual(reader.currentChapterIndex, 1)
            XCTAssertEqual(reader.currentTransformation?.modifiedText, "The story begins.")
        }
    }

    /// A cursor before a skipped section at the end of its chapter resumes
    /// in that chapter, at the cursor.
    func testCursorBeforeASkippedTailResumesInItsChapter() throws {
        let opening = chapter(sections: [("Opening", "First words."), ("Appendix", "Back matter.")])
        let firstWords = (opening.text as NSString).range(of: "First words.").location
        try withReader(
            chapters: [opening, Chapter(title: "Two", text: "Next chapter.")],
            skipping: ["Appendix"],
            at: ReadingPosition(chapterIndex: 0, characterOffset: firstWords)
        ) { reader in
            let start = try XCTUnwrap(reader.speechStartFromCursor())

            XCTAssertEqual(start.speech.chapterIndex, 0)
            XCTAssertEqual(start.offset, firstWords)
            XCTAssertEqual(start.speech.text, "Opening\n\nFirst words.\n\n")
        }
    }

    /// A cursor inside that skipped section has nothing left to say in its
    /// chapter, so speech resumes at the top of the next chapter.
    func testCursorInASkippedTailResumesAtTheNextChapter() throws {
        let opening = chapter(sections: [("Opening", "First words."), ("Appendix", "Back matter.")])
        let backMatter = (opening.text as NSString).range(of: "Back matter.").location
        try withReader(
            chapters: [opening, Chapter(title: "Two", text: "Next chapter.")],
            skipping: ["Appendix"],
            at: ReadingPosition(chapterIndex: 0, characterOffset: backMatter)
        ) { reader in
            let start = try XCTUnwrap(reader.speechStartFromCursor())

            XCTAssertEqual(start.speech.chapterIndex, 1)
            XCTAssertEqual(start.offset, 0)
            XCTAssertEqual(start.speech.text, "Next chapter.")
        }
    }

    /// A cursor in the last chapter's trailing blank lines has nothing left
    /// to say either, so the book ends instead of speaking blank lines.
    func testCursorInTrailingBlankLinesOfTheLastChapterEndsTheBook() throws {
        let text = "Final words.\n\n\n"
        try withReader(
            chapters: [Chapter(title: "Last", text: text)],
            at: ReadingPosition(chapterIndex: 0, characterOffset: text.utf16.count - 2)
        ) { reader in
            XCTAssertFalse(reader.speakCurrentChapter())
            settle()

            assertEndedWithoutPlaying(reader, announcement: "Finished: Quiet Pages")
        }
    }

    /// Resuming after an audio-route change restarts speech at the cursor.
    /// When the rest of the book was skipped while paused, the book ends
    /// instead, and Now Playing is not told that it is playing.
    func testResumeWithNothingLeftEndsTheBookWithoutClaimingPlayback() throws {
        try withReader(chapters: [chapter(sections: [("Only Section", "Brief text.")])]) { reader in
            reader.play()
            reader.pause()
            let pausedSpeech = reader.speechService.isPaused
            reader.toggleHeadingSkip(try XCTUnwrap(reader.headings.first))
            reader.invalidatePlaybackBackendForAudioRouteChange()

            reader.togglePlayPause()
            settle()

            XCTAssertTrue(pausedSpeech)
            assertEndedWithoutPlaying(reader, announcement: "Finished: Quiet Pages")
        }
    }

    // MARK: - End of book

    /// Reaching the end closes this book's listening session, and only this
    /// book's: a session that another window owns keeps running.
    func testEndOfBookClosesOnlyThisBooksListeningSession() throws {
        try withReader(chapters: [Chapter(title: "One", text: "Words.")]) { reader in
            let statistics = ReadingStatsService.shared
            statistics.startSession(bookID: reader.book.id)

            reader.handleEndOfBook()

            XCTAssertFalse(statistics.hasActiveSession)

            statistics.startSession(bookID: UUID())

            reader.handleEndOfBook()

            XCTAssertTrue(statistics.hasActiveSession)
        }
    }

    /// Looping a book with nothing speakable anywhere would end it again at
    /// once, forever. It stops instead, exactly as the Stop behavior does,
    /// leaving the cursor where the book ended.
    func testLoopWithNothingSpeakableStopsInsteadOfRestarting() throws {
        try withReader(
            chapters: [
                chapter(sections: [("Foreword", "Praise.")]),
                chapter(sections: [("Notes", "Citations.")]),
            ],
            skipping: ["Foreword", "Notes"],
            endOfBook: .loop,
            at: ReadingPosition(chapterIndex: 1, characterOffset: 3)
        ) { reader in
            reader.handleEndOfBook()

            XCTAssertEqual(reader.lastAnnouncement, "Finished: Quiet Pages")
            XCTAssertEqual(reader.currentChapterIndex, 1)
            XCTAssertEqual(reader.currentCharacterOffset, 3)
            XCTAssertFalse(reader.speechService.isSpeaking)
            XCTAssertFalse(reader.isCurrentlyPlaying)
            XCTAssertFalse(ReadingStatsService.shared.hasActiveSession)
            XCTAssertEqual(
                ReadingStatsService.shared.stats.finishedBooks.map(\.bookID),
                [reader.book.id.uuidString]
            )
        }
    }

    /// With anything speakable, looping still restarts from the beginning.
    func testLoopRestartsFromTheBeginningWhenAnythingIsSpeakable() throws {
        try withReader(
            chapters: [
                Chapter(title: "One", text: "Opening chapter."),
                chapter(sections: [("Notes", "Citations.")]),
            ],
            skipping: ["Notes"],
            endOfBook: .loop,
            at: ReadingPosition(chapterIndex: 1, characterOffset: 0)
        ) { reader in
            reader.handleEndOfBook()
            let startedSpeaking = reader.speechService.isSpeaking
            silence(reader)

            XCTAssertTrue(startedSpeaking)
            XCTAssertEqual(reader.lastAnnouncement, "Restarting: Quiet Pages")
            XCTAssertEqual(reader.currentChapterIndex, 0)
            XCTAssertEqual(reader.currentTransformation?.modifiedText, "Opening chapter.")
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

    /// Stop the reader's speech before the main run loop turns, so a test
    /// that starts speech is never audible. Advancing the playback
    /// generation also keeps a queued look-ahead render from starting.
    /// Record anything the test checks about the speech first.
    private func silence(_ reader: ReaderViewModel) {
        reader.stop()
        reader.chapterPlaybackGeneration += 1
    }

    /// Let queued main-queue work run. The reader mirrors the speech
    /// service's playing state asynchronously, so a Playing state that was
    /// wrongly set would only show after this.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// Check that the book ended with `announcement` without ever playing:
    /// nothing is speaking, the reader shows neither Playing nor Paused, no
    /// listening session is open or recorded, and Now Playing does not list
    /// this reader as playing.
    private func assertEndedWithoutPlaying(
        _ reader: ReaderViewModel,
        announcement: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let statistics = ReadingStatsService.shared
        XCTAssertEqual(reader.lastAnnouncement, announcement, file: file, line: line)
        XCTAssertFalse(reader.speechService.isSpeaking, "speaking", file: file, line: line)
        XCTAssertFalse(reader.isCurrentlyPlaying, "Playing state", file: file, line: line)
        XCTAssertFalse(reader.isCurrentlyPaused, "Paused state", file: file, line: line)
        XCTAssertFalse(statistics.hasActiveSession, "open listening session", file: file, line: line)
        XCTAssertEqual(statistics.stats.totalListeningSeconds, 0, "recorded listening", file: file, line: line)
        XCTAssertNotEqual(
            NowPlayingService.shared.playingOwnerID,
            reader.nowPlayingService.ownerID,
            "Now Playing claimed",
            file: file,
            line: line
        )
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
