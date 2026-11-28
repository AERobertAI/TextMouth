import XCTest
@testable import TextMouth

/// `PhoneReaderControls` and `PhoneControlDescription`: every reader
/// control's words and traits, for plain states, by the spec's sections
/// under "The reader".
@MainActor
final class PhoneReaderControlsTests: XCTestCase {
    // MARK: - Order

    /// The elements after Back and the title, in VoiceOver's order: Book
    /// content, Skip backward just before Play and Skip forward just after it
    /// (FR54), and the grid of three columns under Play, Book Actions in
    /// place of the four actions it gathers (FR51).
    func testTheControlsAreInTheSpecsOrder() {
        XCTAssertEqual(PhoneReaderControl.playRow, [.skipBackward, .play, .skipForward])
        XCTAssertEqual(PhoneReaderControl.screen(timerRuns: false), [
            .bookContent, .skipBackward, .play, .skipForward,
            .whereAmI, .navigationUnit, .speed,
            .previousHeading, .nextHeading, .addBookmark, .bookmarks, .headings,
            .searchInBook, .goTo, .returnToPlace, .bookActions,
        ])
        XCTAssertEqual(PhoneReaderControl.grid.count, 12)
        XCTAssertEqual(PhoneReaderControl.grid.first, .whereAmI)
        XCTAssertEqual(PhoneReaderControl.grid.last, .bookActions)
    }

    /// Book Actions holds Sleep Timer, Voice, Book Info, and Export this book,
    /// in that order, none of them on the screen as well; every control is on
    /// the screen or in the menu, never both (FR51).
    func testBookActionsGathersTheFourLessFrequentActions() {
        XCTAssertEqual(PhoneReaderControl.bookActionItems, [.sleepTimer, .voice, .bookInfo, .export])
        let screen = PhoneReaderControl.screen(timerRuns: false)
        XCTAssertTrue(Set(screen).isDisjoint(with: PhoneReaderControl.bookActionItems), "\(screen)")
        XCTAssertEqual(Set(screen).union(PhoneReaderControl.bookActionItems), Set(PhoneReaderControl.allCases))
        for item in PhoneReaderControl.bookActionItems {
            XCTAssertNotNil(item.sheet, "\(item) opens no sheet from the menu")
        }
        let actions = describe(.bookActions, in: state())
        XCTAssertEqual(actions.label, "Book Actions")
        XCTAssertEqual(actions.hint, "Sleep timer, voice, book information, and export.")
        XCTAssertEqual(actions.value, "")
        XCTAssertEqual(actions.traits, .button)
        XCTAssertNil(PhoneReaderControl.bookActions.sheet, "Book Actions opens a menu, not a sheet")
    }

    /// VoiceOver reaches Skip backward and Skip forward by default, around
    /// Play (FR54); with Settings' "Hide skip buttons from VoiceOver" on, it
    /// passes over them while it runs, and without VoiceOver every control on
    /// the screen is reachable either way. Play stays adjustable.
    func testVoiceOverReachesTheSkipsUnlessSettingsHideThem() {
        XCTAssertEqual(PhoneReaderControl.allCases.filter { $0.isHiddenFromVoiceOver(hidingSkips: false) }, [])
        let hidden = PhoneReaderControl.allCases.filter { $0.isHiddenFromVoiceOver(hidingSkips: true) }
        XCTAssertEqual(hidden, [.skipBackward, .skipForward])
        for timerRuns in [false, true] {
            let screen = PhoneReaderControl.screen(timerRuns: timerRuns)
            XCTAssertEqual(PhoneReaderControl.voiceOverOrder(timerRuns: timerRuns, voiceOverRuns: true, hidingSkips: false), screen)
            XCTAssertEqual(PhoneReaderControl.voiceOverOrder(timerRuns: timerRuns, voiceOverRuns: false, hidingSkips: true), screen)
            let withoutSkips = PhoneReaderControl.voiceOverOrder(timerRuns: timerRuns, voiceOverRuns: true, hidingSkips: true)
            XCTAssertEqual(withoutSkips, screen.filter { !hidden.contains($0) })
            XCTAssertEqual(Array(withoutSkips.prefix(2)), [.bookContent, .play], "\(withoutSkips)")
        }
        XCTAssertTrue(describe(.play, in: state()).traits.contains(.adjustable), "Play must still move back and forward")
    }

    /// While a timer runs, the Sleep Timer shows under Play as well as in the
    /// menu, its value the time left; with none it is only in the menu.
    func testTheSleepTimerShowsUnderPlayOnlyWhileATimerRuns() {
        let running = PhoneReaderControl.screen(timerRuns: true)
        XCTAssertEqual(Array(running.prefix(5)), [.bookContent, .skipBackward, .play, .skipForward, .sleepTimer])
        XCTAssertEqual(Array(running.dropFirst(5)), PhoneReaderControl.grid)
        XCTAssertFalse(PhoneReaderControl.screen(timerRuns: false).contains(.sleepTimer))
    }

    /// Focus goes back to the Sleep Timer under Play while a timer still runs,
    /// and to Play once it has gone (turned off in its sheet, or run out under
    /// VoiceOver's focus), never to a control no longer on the screen. Every
    /// other control on the screen gets focus back itself.
    func testFocusReturnsToPlayWhenTheSleepTimerHasGone() {
        XCTAssertEqual(PhoneReaderControl.focusTarget(returningTo: .sleepTimer, timerRuns: true), .sleepTimer)
        XCTAssertEqual(PhoneReaderControl.focusTarget(returningTo: .sleepTimer, timerRuns: false), .play)
        for timerRuns in [false, true] {
            for control in PhoneReaderControl.screen(timerRuns: timerRuns) {
                XCTAssertEqual(PhoneReaderControl.focusTarget(returningTo: control, timerRuns: timerRuns), control)
            }
            // The menu's items have no button on the screen but the timer's.
            XCTAssertEqual(PhoneReaderControl.focusTarget(returningTo: .voice, timerRuns: timerRuns), .play)
        }
    }

    /// The grid's rows hold the controls in the grid's order, at most three
    /// to a row, with each pair kept in one row: the headings, and Bookmarks
    /// with Headings. The skips have left the grid for Play's row (FR54).
    func testTheGridRowsKeepOrderAndPairs() {
        XCTAssertEqual(PhoneReaderControl.gridRows.flatMap { $0 }, PhoneReaderControl.grid, "The rows change VoiceOver's order")
        for row in PhoneReaderControl.gridRows {
            XCTAssertLessThanOrEqual(row.count, 3, "\(row)")
        }
        let together: [[PhoneReaderControl]] = [
            [.previousHeading, .nextHeading], [.bookmarks, .headings, .searchInBook],
        ]
        for group in together {
            XCTAssertTrue(
                PhoneReaderControl.gridRows.contains { row in group.allSatisfy { row.contains($0) } },
                "\(group) are split across rows: \(PhoneReaderControl.gridRows)"
            )
        }
        XCTAssertFalse(PhoneReaderControl.grid.contains { $0.isSkip }, "A skip is still in the grid")
        // Book Actions ends the last row (FR51).
        XCTAssertEqual(PhoneReaderControl.gridRows.count, 4, "The grid changed its shape")
        XCTAssertEqual(PhoneReaderControl.gridRows.last, [.goTo, .returnToPlace, .bookActions])
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
        XCTAssertEqual(PhoneReaderControl.export.sheet, .export)
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

    /// Play has no actions in any state (FR55, replacing FR52's Sleep Timer
    /// action): a swipe up or down moves and a double tap plays or pauses, so
    /// VoiceOver never says "Actions available" on it.
    func testPlayHasNoActions() {
        let changes: [(inout PhoneReaderState) -> Void] = [
            { _ in }, { $0.isPlaying = true }, { $0.isLoading = true }, { $0.sleepTimerStatus = "9:57 remaining" },
        ]
        for change in changes {
            XCTAssertEqual(describe(.play, in: state(change)).actions, [])
        }
    }

    /// The three adjustable controls, and what a swipe up or down on each
    /// does: Play moves, Navigation unit and Speed step. Each says it is
    /// adjustable, and no other control does: not the Sleep Timer under Play,
    /// whose swipes pick its actions (the user's correction to FR55).
    func testWhatAdjustingEachControlDoes() {
        let adjustable: [PhoneReaderControl: PhoneControlAdjustment] = [
            .play: .move, .navigationUnit: .unit, .speed: .speed,
        ]
        for control in PhoneReaderControl.allCases {
            XCTAssertEqual(control.adjustment, adjustable[control], "\(control)")
            XCTAssertEqual(
                describe(control, in: state()).traits.contains(.adjustable), adjustable[control] != nil,
                "\(control)'s adjustable trait and its adjustment disagree"
            )
        }
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
            "Moves to the next heading, keeping the navigation unit."
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

    /// Book content keeps its twelve lines while they fit in 55 percent of the
    /// screen, and is cut to that share at the largest text sizes, so Play
    /// still shows under it; an unmeasured screen leaves the twelve lines.
    func testBookContentLeavesRoomForPlayAtTheLargestTextSizes() {
        // The default size on the smallest iPhone: 300 points of 560 fits.
        XCTAssertEqual(PhoneReaderControls.bookContentHeight(scaled: 300, visible: 560), 300)
        // The largest accessibility size, about 3.1 times the body's: cut.
        XCTAssertEqual(PhoneReaderControls.bookContentHeight(scaled: 935, visible: 750), 412.5, accuracy: 0.001)
        XCTAssertEqual(PhoneReaderControls.bookContentHeight(scaled: 300, visible: 0), 300)
    }

    /// Go To's value is the place, as the sheet's Page and Time fields start:
    /// the page and the time, the page left out in a book without pages, and
    /// nothing while loading (FR50). It is no button's visible title: Go To
    /// shows its name alone.
    func testGoToSaysThePageAndTheTime() {
        let place = state { $0.goToPage = "Page 112 of 300"; $0.goToTime = "1:02:03" }
        XCTAssertEqual(describe(.goTo, in: place).value, "Page 112 of 300, 1:02:03")
        XCTAssertEqual(describe(.goTo, in: state { $0.goToTime = "0:05:00" }).value, "0:05:00")
        XCTAssertEqual(describe(.goTo, in: state()).value, "")
        var loading = place
        loading.isLoading = true
        XCTAssertEqual(describe(.goTo, in: loading).value, "")
        XCTAssertEqual(describe(.goTo, in: place).label, "Go To", "The place belongs in the value, after the name")
    }

    /// Export this book is the Mac's toolbar button: its spoken label, its drawn
    /// title "Export", and its hint, a button with no value and no actions; it
    /// follows Book Info and comes before the skips.
    func testExportThisBook() {
        let export = describe(.export, in: state())
        XCTAssertEqual(export.label, "Export this book")
        XCTAssertEqual(export.visibleTitle, "Export")
        XCTAssertEqual(export.value, "")
        XCTAssertEqual(export.hint, "Opens the Export dialog: the book's audio, its text, or its own file.")
        XCTAssertEqual(export.traits, .button)
        XCTAssertEqual(export.actions, [])
        let order = PhoneReaderControl.allCases
        XCTAssertEqual(order.firstIndex(of: .export), order.firstIndex(of: .bookInfo).map { $0 + 1 })
        XCTAssertEqual(order.firstIndex(of: .skipBackward), order.firstIndex(of: .export).map { $0 + 1 })
        for control in PhoneReaderControl.allCases where control != .export {
            XCTAssertNil(describe(control, in: state()).visibleTitle, "\(control) draws words other than its label")
        }
    }

    /// Sleep Timer says "Off", or the Mac's spoken status; it is a button,
    /// not adjustable, that opens the sheet, with the sheet's Reset Timer and
    /// Cancel Timer as its actions, by the Mac's names (FR55).
    func testSleepTimerValue() {
        XCTAssertEqual(describe(.sleepTimer, in: state()).value, "Off")
        XCTAssertEqual(
            describe(.sleepTimer, in: state { $0.sleepTimerStatus = "stops at the end of this heading" }).value,
            "stops at the end of this heading"
        )
        let timer = describe(.sleepTimer, in: state { $0.sleepTimerStatus = "9:57 remaining" })
        XCTAssertEqual(timer.label, "Sleep Timer")
        XCTAssertEqual(timer.value, "9:57 remaining")
        XCTAssertEqual(timer.hint, "Opens the sleep timer.")
        XCTAssertEqual(timer.traits, .button)
        XCTAssertEqual(timer.actions, [.resetSleepTimer, .cancelSleepTimer])
        XCTAssertEqual(timer.actions.map(\.name), ["Reset Timer", "Cancel Timer"])
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

    /// No control but Where Am I? and the Sleep Timer has actions (Play lost
    /// its Sleep Timer action, FR55), so VoiceOver never says "Actions
    /// available" after one that has none to offer; none but Play and Where
    /// Am I? start a media session.
    func testOnlyWhereAmIAndTheTimerHaveActionsAndOnlyPlayAndWhereAmIStartMedia() {
        for control in PhoneReaderControl.allCases {
            let description = describe(control, in: state())
            if control != .whereAmI && control != .sleepTimer {
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
