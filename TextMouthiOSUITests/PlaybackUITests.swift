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

    // MARK: - Play and Pause

    /// Before Play is pressed the control reads "Play", a button with no value;
    /// after, "Pause", with no value, and it goes on reading Pause; after Pause
    /// is pressed, "Play" again, still with no value, since nothing was moved.
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
    }

    /// Play can be pressed again after Pause, and the book plays again: the
    /// control reads Pause the second time too.
    func testPlayWorksAgainAfterPause() throws {
        try requireSound("Pressing Play")
        let app = try launchIntoTheReader()
        try pressPlay(in: app)
        try pressPause(in: app)
        try pressPlay(in: app)
        assertHolds(app.buttons["Pause"], what: "Pause after the second Play", in: app)
        try pressPause(in: app)
    }

    // MARK: - The skip buttons while the book plays

    /// Skipping forward by sentence while the book plays moves the place and
    /// leaves the book playing: the control still reads Pause, and once the
    /// book is paused, Book content starts at a sentence several sentences
    /// after the one it started at ("Skip forward" activates a move that, while
    /// playing, says nothing for a sentence: the book itself is heard from the
    /// new place).
    func testSkippingForwardWhilePlayingMovesTheBookAndKeepsItPlaying() throws {
        try requireSound("Pressing Play")
        let app = try launchIntoTheReader()
        let before = try bookContent(in: app)
        XCTAssertFalse(before.isEmpty, "Book content holds no text")

        try pressPlay(in: app)
        let skips = 6
        let skip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Skip forward")).firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: Self.patience), "No Skip forward:\n\(app.debugDescription)")
        for _ in 0..<skips {
            skip.tap()
        }
        // Skipping does not pause the book.
        XCTAssertTrue(app.buttons["Pause"].exists, "The book stopped after skipping:\n\(app.debugDescription)")
        assertHolds(app.buttons["Pause"], what: "Pause after the skips", in: app)

        try pressPause(in: app)
        // Pausing brings Book content to the sentence just spoken, a moment later: wait for it to change.
        var after = before
        let deadline = Date().addingTimeInterval(Self.patience)
        while Date() < deadline {
            after = try bookContent(in: app)
            if !after.isEmpty, !after.hasPrefix(String(before.prefix(40))) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertFalse(
            after.hasPrefix(String(before.prefix(40))),
            "Book content still begins where it began after \(skips) skips forward: \(after.prefix(120))"
        )
        // The book only moves forward: where the new passage lies in the old one, it is sentences on, not characters.
        if let range = before.range(of: String(after.prefix(40))) {
            let between = before[..<range.lowerBound]
            let sentences = between.filter { ".?!".contains($0) }.count
            XCTAssertGreaterThanOrEqual(
                sentences, skips - 2,
                "The passage moved only \(sentences) sentences on after \(skips) skips: now \(after.prefix(120))"
            )
        }
    }

    /// Skip backward at the start of the book while it plays moves nowhere and
    /// the book plays on: the spec says "No previous sentence." in that case, a
    /// notice and not a change of any control, so the control must keep
    /// reading Pause.
    func testSkippingBackwardAtTheStartLeavesTheBookPlaying() throws {
        try requireSound("Pressing Play")
        let app = try launchIntoTheReader()
        try pressPlay(in: app)
        let skip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Skip backward")).firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: Self.patience), "No Skip backward:\n\(app.debugDescription)")
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
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        let second = try secondsLeft(app)
        XCTAssertLessThan(second, first, "The timer did not count down while the book played (\(first), then \(second))")

        try pressPause(in: app)
        let paused = try secondsLeft(app)
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        XCTAssertEqual(try secondsLeft(app), paused, "The timer went on counting while the book was paused")
    }

    /// Stop At "End of heading" starts the book and reads as the place it waits
    /// for; Cancel Timer in the sheet ends it, and the control reads "Off".
    func testAnEndOfHeadingTimerNamesItsStopAndCancelEndsIt() throws {
        try requireSound("Setting a sleep timer, which starts the book playing")
        let app = try launchIntoTheReader()
        try startSleepTimer("Stop at the end of this heading and start playing", in: app)
        XCTAssertTrue(
            app.buttons["Pause"].waitForExistence(timeout: Self.patience),
            "The book did not start playing after the timer was set:\n\(app.debugDescription)"
        )
        let timer = app.buttons["Sleep Timer"]
        XCTAssertTrue(
            value(of: timer).localizedCaseInsensitiveContains("end of this heading"),
            "The timer's value: \"\(value(of: timer))\""
        )

        // The sheet shows the running timer, with Cancel Timer.
        let elements = try openReaderSheet("Sleep Timer", titled: "Sleep Timer", waitingFor: "Close", in: app)
        assertOrder(["Sleep Timer", "Close", "Current Timer", "Cancel Timer"], in: elements)
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
