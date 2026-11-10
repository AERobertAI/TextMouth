import XCTest
@testable import TextMouth

/// `PhoneReaderControls` and `PhoneControlDescription`: every reader
/// control's words and traits, for plain states, by the spec's sections
/// under "The reader".
@MainActor
final class PhoneReaderControlsTests: XCTestCase {
    // MARK: - Order

    /// The elements after Back and the title, in VoiceOver's order, and the
    /// grid of three columns under Play: five full rows, and a sixth holding
    /// the last control, since Search in Book follows Headings.
    func testTheControlsAreInTheSpecsOrder() {
        XCTAssertEqual(PhoneReaderControl.allCases, [
            .bookContent, .play, .whereAmI, .navigationUnit, .speed,
            .previousHeading, .nextHeading, .addBookmark, .bookmarks, .headings,
            .searchInBook, .goTo, .returnToPlace, .sleepTimer, .voice, .bookInfo,
            .skipBackward, .skipForward,
        ])
        XCTAssertEqual(PhoneReaderControl.grid.count, 16)
        XCTAssertEqual(PhoneReaderControl.grid.first, .whereAmI)
        XCTAssertEqual(PhoneReaderControl.grid.last, .skipForward)
    }

    /// The grid's rows hold the controls in the grid's order, at most three
    /// to a row, with each pair kept in one row: the headings, the skips, and
    /// Bookmarks with Headings.
    func testTheGridRowsKeepOrderAndPairs() {
        XCTAssertEqual(PhoneReaderControl.gridRows.flatMap { $0 }, PhoneReaderControl.grid, "The rows change VoiceOver's order")
        for row in PhoneReaderControl.gridRows {
            XCTAssertLessThanOrEqual(row.count, 3, "\(row)")
        }
        let together: [[PhoneReaderControl]] = [
            [.previousHeading, .nextHeading], [.skipBackward, .skipForward], [.bookmarks, .headings, .searchInBook],
        ]
        for group in together {
            XCTAssertTrue(
                PhoneReaderControl.gridRows.contains { row in group.allSatisfy { row.contains($0) } },
                "\(group) are split across rows: \(PhoneReaderControl.gridRows)"
            )
        }
        XCTAssertEqual(PhoneReaderControl.gridRows.last, [.skipBackward, .skipForward], "The skips aren't the last row")
    }

    /// Every control has a focus kind of its own, and every kind belongs to
    /// a control, so a landing on any control is the listener's.
    func testEveryControlHasItsOwnFocusKind() {
        let kinds = PhoneReaderControl.allCases.map(\.focusKind)
        XCTAssertEqual(Set(kinds).count, kinds.count)
        XCTAssertEqual(Set(kinds), Set(PhoneControlKind.allCases))
    }

    /// The controls that open a sheet name it; the others open none.
    func testTheControlsThatOpenASheet() {
        XCTAssertEqual(PhoneReaderControl.navigationUnit.sheet, .navigationUnit)
        XCTAssertEqual(PhoneReaderControl.headings.sheet, .headings)
        XCTAssertEqual(PhoneReaderControl.voice.sheet, .voice)
        XCTAssertEqual(PhoneReaderControl.searchInBook.sheet, .search)
        XCTAssertNil(PhoneReaderControl.play.sheet)
        XCTAssertNil(PhoneReaderControl.addBookmark.sheet)
        XCTAssertEqual(Set(PhoneReaderControl.allCases.compactMap(\.sheet)), Set(PhoneReaderSheet.allCases))
    }

    // MARK: - Search in Book

    /// Search in Book is the Mac's command, a button with a hint saying what
    /// it opens, no value, and no actions; it follows Headings and comes
    /// before Go To, in every state.
    func testSearchInBook() {
        let search = describe(.searchInBook, in: state())
        XCTAssertEqual(search.label, "Search in Book")
        XCTAssertEqual(search.value, "")
        XCTAssertEqual(search.hint, "Opens a search of the book's text.")
        XCTAssertEqual(search.traits, .button)
        XCTAssertEqual(search.actions, [])
        let order = PhoneReaderControl.allCases
        XCTAssertEqual(order.firstIndex(of: .searchInBook), order.firstIndex(of: .headings).map { $0 + 1 })
        XCTAssertEqual(order.firstIndex(of: .goTo), order.firstIndex(of: .searchInBook).map { $0 + 1 })
    }

    // MARK: - Play

    /// Paused: "Play", adjustable, starting a media session, with the unit
    /// in its hint and no value.
    func testPlayWhilePaused() {
        let play = describe(.play, in: state())
        XCTAssertEqual(play.label, "Play")
        XCTAssertEqual(play.value, "")
        XCTAssertEqual(play.hint, "Moves back or forward by sentence.")
        XCTAssertEqual(play.traits, [.button, .adjustable, .startsMediaSession])
        XCTAssertEqual(play.actions, [])
    }

    /// Playing: "Pause", with an empty value, and without the media trait,
    /// so that VoiceOver saying "Play" after a pause confirms it.
    func testPlayWhilePlaying() {
        let play = describe(.play, in: state { $0.isPlaying = true; $0.moveWords = "Kept" })
        XCTAssertEqual(play.label, "Pause")
        XCTAssertEqual(play.value, "")
        XCTAssertEqual(play.traits, [.button, .adjustable])
    }

    /// After a paused move, Play's value is what the move said; while
    /// loading, "Loading".
    func testPlaysValueAfterAMoveAndWhileLoading() {
        XCTAssertEqual(describe(.play, in: state { $0.moveWords = "Heading: The Battle" }).value, "Heading: The Battle")
        XCTAssertEqual(describe(.play, in: state { $0.isLoading = true }).value, "Loading")
    }

    /// The hint names whatever unit is in force.
    func testPlaysHintNamesTheUnit() {
        XCTAssertEqual(describe(.play, in: state { $0.unit = .seconds30 }).hint, "Moves back or forward by 30 seconds.")
    }

    // MARK: - Where Am I?

    /// Where Am I?'s value is the place, computed when asked; it's a button
    /// starting a media session, with the Mac's two actions.
    func testWhereAmI() {
        let control = describe(.whereAmI, in: state())
        XCTAssertEqual(control.label, "Where Am I?")
        XCTAssertEqual(
            control.value,
            "The Battle, 12 minutes remaining in this heading, Page 112 of 300, 30 percent, 3 hours remaining"
        )
        XCTAssertEqual(control.hint, "")
        XCTAssertEqual(control.traits, [.button, .startsMediaSession])
        XCTAssertEqual(control.actions, [.whereAmIFullSummary, .copyReadingPosition])
        XCTAssertEqual(control.actions.map(\.name), ["Where Am I? Full Summary", "Copy Reading Position"])
    }

    /// While its announcement speaks, the Mac's stop label.
    func testWhereAmIWhileSpeaking() {
        XCTAssertEqual(
            describe(.whereAmI, in: state { $0.isWhereAmISpeaking = true }).label,
            "Stop Where Am I announcement"
        )
    }

    /// An audiobook adds its place in the recording; a book without pages or
    /// a heading leaves those out; a finished book says "Finished".
    func testWhereAmIsValueByKindOfBook() {
        var parts = whereAmIParts()
        parts.timeIntoRecording = 7_980
        XCTAssertEqual(
            PhoneReaderControls.whereAmIValue(parts),
            "The Battle, 12 minutes remaining in this heading, Page 112 of 300, 2 hours, 13 minutes in, 30 percent, 3 hours remaining"
        )

        parts = whereAmIParts()
        parts.heading = nil
        parts.remainingInHeading = nil
        parts.pageLabel = ""
        XCTAssertEqual(PhoneReaderControls.whereAmIValue(parts), "30 percent, 3 hours remaining")

        parts = whereAmIParts()
        parts.isFinished = true
        XCTAssertEqual(PhoneReaderControls.whereAmIValue(parts), "The Battle, Page 112 of 300, Finished")
    }

    /// With the setting that names the speed on, the time left says it, as
    /// the Mac's summary does.
    func testWhereAmINamesTheSpeedWhenTheSettingDoes() {
        var parts = whereAmIParts()
        parts.speed = .audio(2)
        XCTAssertTrue(PhoneReaderControls.whereAmIValue(parts).hasSuffix("3 hours remaining at 2.0 times speed"))
    }

    // MARK: - Navigation Unit and Speed

    /// Navigation unit: the Mac's label and the unit's name as its value,
    /// a button that's adjustable.
    func testNavigationUnit() {
        let control = describe(.navigationUnit, in: state { $0.unit = .bookmark })
        XCTAssertEqual(control.label, "Navigation unit")
        XCTAssertEqual(control.value, "Bookmark")
        XCTAssertEqual(control.hint, "Chooses what Play and the skip buttons move by.")
        XCTAssertEqual(control.traits, [.button, .adjustable])
    }

    /// A text book's Speed in words per minute, stepping by 25.
    func testSpeedForATextBook() {
        let control = describe(.speed, in: state { $0.wordsPerMinute = 200 })
        XCTAssertEqual(control.label, "Speed")
        XCTAssertEqual(control.value, "200 words per minute")
        XCTAssertEqual(control.hint, "Changes the speed in steps of 25 words per minute.")
        XCTAssertEqual(control.traits, .adjustable)
    }

    /// An audiobook's Audio speed as a multiple, stepping by 0.1.
    func testSpeedForAnAudiobook() {
        let control = describe(.speed, in: state { $0.isAudioBook = true; $0.audioSpeed = 1.25 })
        XCTAssertEqual(control.label, "Audio speed")
        XCTAssertEqual(control.value, "1.25 times speed")
        XCTAssertEqual(control.hint, "Changes the speed in steps of 0.1 times")
        XCTAssertEqual(control.traits, .adjustable)
    }

    // MARK: - The Grid's Buttons

    /// The heading buttons: the Mac's menu words and the spec's hints.
    func testTheHeadingButtons() {
        XCTAssertEqual(describe(.previousHeading, in: state()).label, "Previous Heading")
        XCTAssertEqual(describe(.nextHeading, in: state()).label, "Next Heading")
        XCTAssertEqual(
            describe(.nextHeading, in: state()).hint,
            "Moves to the next heading, leaving the navigation unit as it is."
        )
        XCTAssertEqual(describe(.previousHeading, in: state()).traits, .button)
    }

    /// Add bookmark becomes Remove bookmark near a bookmark.
    func testAddBookmark() {
        XCTAssertEqual(describe(.addBookmark, in: state()).label, "Add bookmark")
        XCTAssertEqual(describe(.addBookmark, in: state { $0.isNearBookmark = true }).label, "Remove bookmark")
    }

    /// Bookmarks' value is the count, left out at none.
    func testBookmarksCount() {
        XCTAssertEqual(describe(.bookmarks, in: state()).value, "")
        XCTAssertEqual(describe(.bookmarks, in: state { $0.bookmarkCount = 1 }).value, "1 bookmark")
        XCTAssertEqual(describe(.bookmarks, in: state { $0.bookmarkCount = 3 }).value, "3 bookmarks")
        XCTAssertEqual(describe(.bookmarks, in: state()).hint, "Opens the list of bookmarks.")
    }

    /// Headings' value is the heading and its place.
    func testHeadingsValue() {
        let control = describe(.headings, in: state())
        XCTAssertEqual(control.label, "Headings")
        XCTAssertEqual(control.value, "The Battle, 2 of 3")
        XCTAssertEqual(control.hint, "Opens the list of headings.")
    }

    /// Go To, Return, Book Info: their words.
    func testGoToReturnAndBookInfo() {
        XCTAssertEqual(describe(.goTo, in: state()).label, "Go To")
        XCTAssertEqual(describe(.goTo, in: state()).hint, "Goes to a page, a percent, or a time.")
        XCTAssertEqual(describe(.returnToPlace, in: state()).label, "Return to previous reading position")
        XCTAssertEqual(describe(.returnToPlace, in: state()).hint, "Goes back to where the last jump began.")
        XCTAssertEqual(describe(.bookInfo, in: state()).label, "Book Info")
        XCTAssertEqual(describe(.bookInfo, in: state()).hint, "Show book information")
    }

    /// Sleep Timer says "Off", or the Mac's spoken status.
    func testSleepTimerValue() {
        XCTAssertEqual(describe(.sleepTimer, in: state()).value, "Off")
        XCTAssertEqual(
            describe(.sleepTimer, in: state { $0.sleepTimerStatus = "stops at the end of this heading" }).value,
            "stops at the end of this heading"
        )
        XCTAssertEqual(describe(.sleepTimer, in: state()).hint, "Opens the sleep timer.")
    }

    /// Voice for a text book, with the Mac's label as its hint; Audio
    /// Settings for an audiobook, with no hint repeating its label.
    func testVoice() {
        let text = describe(.voice, in: state())
        XCTAssertEqual(text.label, "Voice")
        XCTAssertEqual(text.hint, "Change voice for this book")
        let audio = describe(.voice, in: state { $0.isAudioBook = true })
        XCTAssertEqual(audio.label, "Audio Settings")
        XCTAssertEqual(audio.hint, "")
    }

    /// The skip buttons name the unit in force, and have no value or hint.
    func testTheSkipButtons() {
        let backward = describe(.skipBackward, in: state { $0.unit = .heading })
        XCTAssertEqual(backward.label, "Skip backward: Heading")
        XCTAssertEqual(backward.value, "")
        XCTAssertEqual(backward.hint, "")
        XCTAssertEqual(backward.traits, .button)
        XCTAssertEqual(describe(.skipForward, in: state()).label, "Skip forward: Sentence")
    }

    /// No control but Where Am I? has actions, so VoiceOver never says
    /// "Actions available" after one that has none to offer; none but Play
    /// and Where Am I? start a media session.
    func testOnlyWhereAmIHasActionsAndOnlyPlayAndWhereAmIStartMedia() {
        for control in PhoneReaderControl.allCases {
            let description = describe(control, in: state())
            if control != .whereAmI {
                XCTAssertEqual(description.actions, [], "\(control)")
            }
            if control != .play && control != .whereAmI {
                XCTAssertFalse(description.traits.contains(.startsMediaSession), "\(control)")
            }
            XCTAssertFalse(description.label.isEmpty, "\(control)")
        }
    }

    // MARK: - Book Content

    /// Book content: the Mac's label, static text, and a hint by the state.
    func testBookContent() {
        let paused = describe(.bookContent, in: state())
        XCTAssertEqual(paused.label, "Book content")
        XCTAssertEqual(paused.hint, "Plays from here.")
        XCTAssertEqual(paused.traits, .staticText)
        XCTAssertEqual(paused.actions, [])
        XCTAssertEqual(
            describe(.bookContent, in: state { $0.isPlaying = true }).hint,
            "Brings the text to the sentence being spoken."
        )
    }

    /// While loading, Book content reads "Loading" and the title; an
    /// audiobook without a transcript says it has no text, and its heading.
    func testBookContentsStandIns() {
        XCTAssertEqual(PhoneReaderControls.bookContentStandIn(in: state { $0.isLoading = true }), "Loading Moby-Dick")
        XCTAssertEqual(
            PhoneReaderControls.bookContentStandIn(in: state { $0.isAudioBook = true }),
            "This audiobook has no text. The Battle."
        )
        XCTAssertNil(PhoneReaderControls.bookContentStandIn(in: state { $0.isAudioBook = true; $0.hasTranscript = true }))
        XCTAssertNil(PhoneReaderControls.bookContentStandIn(in: state()))
    }

    // MARK: - Helpers

    /// What `control` says in `state`.
    private func describe(_ control: PhoneReaderControl, in state: PhoneReaderState) -> PhoneControlDescription {
        PhoneReaderControls.description(of: control, in: state)
    }

    /// A paused text book at "The Battle", the second of three headings,
    /// moving by sentence, changed as `change` says.
    private func state(_ change: (inout PhoneReaderState) -> Void = { _ in }) -> PhoneReaderState {
        let headings = [
            Heading(level: 1, text: "Prologue", chapterIndex: 0, characterOffset: 0),
            Heading(level: 1, text: "The Battle", chapterIndex: 1, characterOffset: 0),
            Heading(level: 1, text: "Coda", chapterIndex: 2, characterOffset: 0),
        ]
        var state = PhoneReaderState(
            bookTitle: "Moby-Dick",
            isLoading: false,
            loadFailure: nil,
            isPlaying: false,
            isAudioBook: false,
            hasTranscript: false,
            unit: .sentence,
            moveWords: nil,
            isWhereAmISpeaking: false,
            whereAmI: whereAmIParts(),
            wordsPerMinute: 200,
            audioSpeed: 1,
            isNearBookmark: false,
            bookmarkCount: 0,
            headingPosition: HeadingPosition(in: headings, chapterIndex: 1, characterOffset: 40),
            sleepTimerStatus: ""
        )
        change(&state)
        return state
    }

    /// The spec's example place: "The Battle, 12 minutes remaining in this
    /// heading, Page 112 of 300, 30 percent, 3 hours remaining".
    private func whereAmIParts() -> PhoneWhereAmIParts {
        PhoneWhereAmIParts(
            heading: "The Battle",
            remainingInHeading: 720,
            pageLabel: "Page 112 of 300",
            timeIntoRecording: nil,
            percentComplete: 30,
            timeRemaining: 10_800,
            speed: nil,
            isFinished: false
        )
    }
}
