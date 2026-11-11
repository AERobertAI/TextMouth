import XCTest

/// The reader while the book plays, as XCUITest reads it in the simulator:
/// what Play reads before and after it is pressed (its label, value, and type,
/// which with the hint and the other traits are what VoiceOver would be
/// given), the skip buttons while the book plays, and the Sleep Timer's value
/// as a timer counts, stops at a place, and is cancelled (the spec, under
/// "Play", "What a move says", "Skip backward, Skip forward", and "Sleep
/// Timer").
///
/// Every test here presses Play, directly or by a sleep timer, so every test
/// runs only where sound is allowed, on a GitHub runner (see
/// `TextMouthUITestCase.requireSound`); on the development Mac each skips,
/// saying why, before it launches anything. The book is the public-domain
/// Alice's Adventures in Wonderland, an EPUB, so nothing is played through
/// Apple's players but the app's own speech.
final class PlaybackUITests: TextMouthUITestCase {
    /// The Play control's value, as a string: empty when it has none.
    private func value(of control: XCUIElement) -> String {
        (control.value as? String) ?? ""
    }

    /// How long a state is watched to see that it holds, in seconds: long
    /// enough for a failure of the speech (an alert, or a Pause that turns back
    /// into Play) to show.
    private static let holdSeconds: TimeInterval = 3

    /// Fails unless `control` keeps existing for `holdSeconds`, naming `what`.
    private func assertHolds(_ control: XCUIElement, what: String, in app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(Self.holdSeconds)
        while Date() < deadline {
            XCTAssertTrue(control.exists, "\(what) did not hold:\n\(app.debugDescription)")
            if !control.exists { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
    }

    /// `text` with every run of white space (spaces, tabs, line breaks, a Gutenberg file's carriage returns) made one space,
    /// so that two readings of the same words are alike wherever one lays them out differently: the first run that looked
    /// for the new passage inside the opening one (fixphone4, 42986107227) did not find "org/ebooks/11" and what follows it.
    private func squeezed(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Book content once it no longer begins as `passage` does, waiting up to the patience (pausing brings it to the
    /// sentence just spoken a moment later); the last text read when it never changes.
    private func waitForBookContent(movingFrom passage: String, in app: XCUIApplication) throws -> String {
        var now = passage
        let deadline = Date().addingTimeInterval(Self.patience)
        while Date() < deadline {
            now = try bookContent(in: app)
            if !now.isEmpty, !now.hasPrefix(String(passage.prefix(40))) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return now
    }

    // MARK: - Play and Pause

    /// Before Play is pressed the control reads "Play", a button with no value;
    /// after, "Pause", with no value, and it goes on reading Pause; after Pause
    /// is pressed, "Play" again, still with no value, since nothing was moved.
    /// Then Play is pressed again, three sentences are skipped, and the book is
    /// paused, played, and paused once more: the second Play resumes from where
    /// the book was paused, and does not start it over.
    func testPlayBecomesPauseAndPauseBecomesPlay() throws {
        try requireSound("Pressing Play")
        let app = try launchIntoTheReader()

        let play = app.buttons["Play"]
        XCTAssertEqual(play.label, "Play")
        XCTAssertEqual(play.elementType, .button)
        XCTAssertTrue(play.isEnabled, "Play is dimmed")
        XCTAssertEqual(value(of: play), "", "Play's value before it is pressed")

        try pressPlay(in: app)
        let pause = app.buttons["Pause"]
        XCTAssertEqual(pause.label, "Pause")
        XCTAssertEqual(pause.elementType, .button)
        XCTAssertEqual(value(of: pause), "", "Pause's value while the book plays")
        XCTAssertFalse(app.buttons["Play"].exists, "Both Play and Pause are on the screen")
        // The book plays on by itself: a speech that failed would put an alert up or turn Pause back into Play.
        assertHolds(app.buttons["Pause"], what: "Pause while the book plays", in: app)
        keepScreenshot(of: app, named: "Reader, playing")

        try pressPause(in: app)
        XCTAssertEqual(app.buttons["Play"].label, "Play")
        XCTAssertEqual(app.buttons["Play"].elementType, .button)
        XCTAssertEqual(value(of: app.buttons["Play"]), "", "Play's value after Pause, with nothing moved")
        XCTAssertFalse(app.buttons["Pause"].exists, "Both Play and Pause are on the screen")
        keepScreenshot(of: app, named: "Reader, paused")

        // Play again, move on three sentences while playing, and pause: Book content is then where the book stopped (C1).
        let opening = try bookContent(in: app)
        try pressPlay(in: app)
        let skip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Skip forward")).firstMatch
        for _ in 0..<3 {
            skip.tap()
        }
        assertHolds(app.buttons["Pause"], what: "Pause after the second Play", in: app)
        try pressPause(in: app)
        let stopped = try waitForBookContent(movingFrom: opening, in: app)
        XCTAssertFalse(stopped.hasPrefix(String(opening.prefix(40))), "Three skips left Book content where it began")

        // Resume: the book plays from there, so it is paused again at C1 or later in the same passage, never at the start.
        try pressPlay(in: app)
        assertHolds(app.buttons["Pause"], what: "Pause after the third Play", in: app)
        try pressPause(in: app)
        let resumed = try bookContent(in: app)
        XCTAssertFalse(resumed.hasPrefix(String(opening.prefix(40))), "Play started the book over: Book content is at its opening again")
        XCTAssertNotNil(
            squeezed(stopped).range(of: String(squeezed(resumed).prefix(40))),
            "Play did not resume from where the book was paused. Paused at: \(stopped.prefix(120)). Resumed to: \(resumed.prefix(120))"
        )
    }

    // MARK: - The skip buttons while the book plays

    /// Skipping forward by sentence while the book plays moves the place six
    /// sentences on and leaves the book playing. The sentences are learned first,
    /// silently: paused, each Skip forward puts the sentence at its new place in
    /// Play's value (the spec: "the whole sentence at the new place"), so six
    /// presses give the sentences one to six from the opening. Skipping back six
    /// returns to the opening. Then the book plays and the same six presses are
    /// made while it plays: the control still reads Pause, and once the book is
    /// paused Book content begins at the sixth sentence or a later one (speech
    /// moves it on a little), never at the opening or the first five. The passage
    /// is not searched for in the opening one, which is a short title page
    /// (run 42986107227: the new place was in a later chapter).
    func testSkippingForwardWhilePlayingMovesTheBookAndKeepsItPlaying() throws {
        try requireSound("Pressing Play")
        let app = try launchIntoTheReader()
        let opening = try bookContent(in: app)
        XCTAssertFalse(opening.isEmpty, "Book content holds no text")
        let skips = 6
        let skipForward = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Skip forward")).firstMatch
        let skipBackward = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Skip backward")).firstMatch
        XCTAssertTrue(skipForward.waitForExistence(timeout: Self.patience), "No Skip forward:\n\(app.debugDescription)")

        // The first words of each sentence the six presses reach, as Play says them while paused. Eighty characters: some
        // sentences begin alike for 25 (run 42995929013). The first press reaches the sentence Book content shows as the
        // opening, since the reading place is the silent cover and Book content shows the first chapter with words (run
        // 43001624484), so the opening is kept apart and is not counted among them.
        func firstWords(_ text: String) -> String { String(squeezed(text).prefix(80)) }
        let openingWords = firstWords(opening)
        var starts: [String] = []
        var previous = squeezed(value(of: app.buttons["Play"]))
        for number in 1...skips {
            skipForward.tap()
            let deadline = Date().addingTimeInterval(Self.patience)
            var now = previous
            while now == previous, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                now = squeezed(value(of: app.buttons["Play"]))
            }
            XCTAssertFalse(now.isEmpty || now == previous, "Skip forward number \(number) put no new sentence in Play's value:\n\(app.debugDescription)")
            previous = now
            starts.append(firstWords(now))
        }
        XCTAssertEqual(Set(starts).count, skips, "Six skips did not reach six different sentences: \(starts)")
        for _ in 0..<skips {
            skipBackward.tap()
        }
        // Moving while paused brings Book content to the new place; wait for the opening to come back.
        var back = ""
        let returning = Date().addingTimeInterval(Self.patience)
        while Date() < returning {
            back = try bookContent(in: app)
            if firstWords(back) == openingWords { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertEqual(firstWords(back), openingWords, "Six skips back did not return Book content to the opening: \(back.prefix(120))")

        try pressPlay(in: app)
        for _ in 0..<skips {
            skipForward.tap()
        }
        // Skipping does not pause the book.
        XCTAssertTrue(app.buttons["Pause"].exists, "The book stopped after skipping:\n\(app.debugDescription)")
        assertHolds(app.buttons["Pause"], what: "Pause after the skips", in: app)

        try pressPause(in: app)
        // Pausing brings Book content to the sentence just spoken, a moment later: wait for it to change.
        let after = try waitForBookContent(movingFrom: opening, in: app)
        let landed = firstWords(after)
        if let reached = starts.dropLast().firstIndex(of: landed) {
            XCTFail("\(skips) skips forward while playing reached only sentence \(reached + 1): Book content begins \(after.prefix(120))")
        }
        XCTAssertNotEqual(landed, openingWords, "\(skips) skips forward while playing left Book content at the opening")
    }

    /// Skip backward at the start of the book moves nowhere. Paused, a move that
    /// goes nowhere answers in Play's value, in the spec's words ("No previous
    /// sentence.", or the Mac's, when it says one), and Book content stays
    /// where it was. Then, with the book playing, the same press leaves it
    /// playing: the control keeps reading Pause.
    func testSkippingBackwardAtTheStartSaysSoAndLeavesTheBookPlaying() throws {
        try requireSound("Pressing Play")
        let app = try launchIntoTheReader()
        let opening = try bookContent(in: app)
        let skip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Skip backward")).firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: Self.patience), "No Skip backward:\n\(app.debugDescription)")
        skip.tap()
        let answered = NSPredicate(format: "value != nil AND value != %@", "")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: answered, object: app.buttons["Play"])], timeout: Self.patience),
            .completed,
            "Skipping back at the start put nothing in Play's value:\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            value(of: app.buttons["Play"]).localizedCaseInsensitiveContains("previous")
                || value(of: app.buttons["Play"]).localizedCaseInsensitiveContains("start")
                || value(of: app.buttons["Play"]).localizedCaseInsensitiveContains("beginning"),
            "Play's value after skipping back at the start: \"\(value(of: app.buttons["Play"]))\""
        )
        XCTAssertEqual(try bookContent(in: app), opening, "Skipping back at the start moved Book content")

        try pressPlay(in: app)
        skip.tap()
        assertHolds(app.buttons["Pause"], what: "Pause after skipping back at the start", in: app)
        try pressPause(in: app)
    }

    // MARK: - The Sleep Timer

    /// A preset starts the timer and the book: Play reads Pause, and the Sleep
    /// Timer reads the time left, a little under the preset. It counts down
    /// while the book plays and stands still while it is paused (the spec's
    /// "the countdown halts when the book pauses").
    func testASleepTimerCountsDownWhileTheBookPlaysAndStopsWhenItPauses() throws {
        try requireSound("Setting a sleep timer, which starts the book playing")
        let app = try launchIntoTheReader()
        let timer = app.buttons["Sleep Timer"]
        XCTAssertEqual(value(of: timer), "Off", "The timer before one is set")

        try startSleepTimer("Set timer for 10 minutes and start playing", in: app)
        XCTAssertTrue(
            app.buttons["Pause"].waitForExistence(timeout: Self.patience),
            "The book did not start playing after the timer was set:\n\(app.debugDescription)"
        )
        let first = try secondsLeft(app)
        XCTAssertTrue((540...600).contains(first), "A 10-minute timer just set has \(first) seconds left")
        // The value changes within a second or two of playing; wait for that, not for a fixed four seconds.
        var second = first
        let deadline = Date().addingTimeInterval(15)
        while second >= first, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            second = try secondsLeft(app)
        }
        XCTAssertLessThan(second, first, "The timer did not count down while the book played (\(first), then \(second))")

        try pressPause(in: app)
        let paused = try secondsLeft(app)
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        XCTAssertEqual(try secondsLeft(app), paused, "The timer went on counting while the book was paused")
    }

    /// Stop At "End of heading", set at the book's opening, starts the book and
    /// keeps it playing, and the Sleep Timer reads as the place it waits for.
    ///
    /// The book opens at its cover, an image with nothing to read, and Play
    /// starts past it, at the first heading with words. Until version 0.4.6 the
    /// timer took the heading after the cursor instead, which was that very
    /// heading, so it ran out at once: the book stopped, said the timer had
    /// expired, and the control read "Off" (the first GitHub run that tried it,
    /// run 42948545901, saw the book not playing and "Off"; the cause was found
    /// on November 11, 2026). The timer now waits for the heading Play starts
    /// in. Three things are checked, each of which that fault breaks: the book
    /// plays; it is still playing a few seconds later (a timer that had run out
    /// pauses the book at once, and the control turns back into Play); and the
    /// Sleep Timer's value names the end of the heading, not "Off".
    func testAnEndOfHeadingTimerSetAtTheCoverPlaysOnAndNamesItsStop() throws {
        try requireSound("Setting a sleep timer, which starts the book playing")
        let app = try launchIntoTheReader()
        XCTAssertEqual(value(of: app.buttons["Sleep Timer"]), "Off", "The timer before one is set")
        try startSleepTimer("Stop at the end of this heading and start playing", in: app)
        XCTAssertTrue(
            app.buttons["Pause"].waitForExistence(timeout: Self.patience),
            "The book did not start playing after the End of heading timer was set at the cover. The control reads "
                + "\"\(app.buttons["Play"].label)\", and the Sleep Timer reads \"\(value(of: app.buttons["Sleep Timer"]))\":\n\(app.debugDescription)"
        )
        // The value is read first, the moment the book plays: it is what a listener hears on the control.
        let timer = app.buttons["Sleep Timer"]
        XCTAssertTrue(
            value(of: timer).localizedCaseInsensitiveContains("end of this heading"),
            "The timer's value after it was set at the cover: \"\(value(of: timer))\" (\"Off\" means it ran out at once)"
        )
        // A timer that ran out at once pauses the book a moment after it started: hold, for a few seconds, that it plays on.
        assertHolds(app.buttons["Pause"], what: "Pause after an End of heading timer was set at the cover", in: app)
        try pressPauseIfPlaying(app)
    }

    /// Stop At "End of the book" starts the book and reads as the place it
    /// waits for; Cancel Timer in the sheet ends it, and the control reads
    /// "Off". (The End of heading timer at the cover has a test of its own,
    /// above.)
    func testAnEndOfBookTimerNamesItsStopAndCancelEndsIt() throws {
        try requireSound("Setting a sleep timer, which starts the book playing")
        let app = try launchIntoTheReader()
        try startSleepTimer("Stop at the end of the book and start playing", in: app)
        XCTAssertTrue(
            app.buttons["Pause"].waitForExistence(timeout: 20),
            "The book did not start playing after the timer was set. The control reads "
                + "\"\(app.buttons["Play"].label)\", and the Sleep Timer reads \"\(value(of: app.buttons["Sleep Timer"]))\":\n\(app.debugDescription)"
        )
        let timer = app.buttons["Sleep Timer"]
        XCTAssertTrue(
            value(of: timer).localizedCaseInsensitiveContains("end of the book"),
            "The timer's value: \"\(value(of: timer))\""
        )

        // The sheet shows the running timer, with Reset Timer and Cancel Timer before New Timer. Its "Current Timer"
        // heading and its status line are not asked for: the sheet opens with the list scrolled to the last timer
        // used, End of the book, at the bottom (the spec: "Focus lands on the last timer used"), and the list, being
        // lazy, leaves the rows above out of the tree (run 42955357534: Close, Reset Timer, Cancel Timer, New Timer).
        let elements = try openReaderSheet("Sleep Timer", titled: "Sleep Timer", waitingFor: "Close", in: app)
        assertOrder(["Sleep Timer", "Reset Timer", "Cancel Timer", "New Timer"], in: elements)
        app.buttons["Cancel Timer"].tap()
        XCTAssertTrue(
            app.buttons["Cancel Timer"].waitForNonExistence(timeout: Self.patience),
            "Cancel Timer stayed after it was pressed:\n\(app.debugDescription)"
        )
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Sleep Timer"].waitForExistence(timeout: Self.patience), "No Sleep Timer back on the reader")
        XCTAssertEqual(value(of: app.buttons["Sleep Timer"]), "Off", "The timer after Cancel Timer")
        try pressPauseIfPlaying(app)
    }

    // MARK: - Helpers

    /// The seconds the Sleep Timer's value says are left, from "9:57 remaining".
    private func secondsLeft(_ app: XCUIApplication) throws -> Int {
        let text = value(of: app.buttons["Sleep Timer"])
        let clock = text.replacingOccurrences(of: " remaining", with: "").split(separator: ":")
        guard text.hasSuffix(" remaining"), clock.count == 2, let minutes = Int(clock[0]), let seconds = Int(clock[1]) else {
            XCTFail("The timer's value is not a time left: \"\(text)\"")
            return 0
        }
        return minutes * 60 + seconds
    }

    /// Pauses the book if it is playing (a timer that was cancelled leaves it
    /// playing), so a test ends in silence.
    private func pressPauseIfPlaying(_ app: XCUIApplication) throws {
        if app.buttons["Pause"].exists {
            try pressPause(in: app)
        }
    }
}
