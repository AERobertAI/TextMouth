import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The spoken audio options of the Export dialog (FMT43): every word they
/// show or speak, the state behind them, and the view that draws them.
@MainActor
final class SpeechExportOptionsTests: XCTestCase {
    // MARK: - A Book and a Voice

    /// The book's first chapter.
    private let chapterOne = Heading(level: 1, text: "Chapter 1", chapterIndex: 0, characterOffset: 0)
    /// A section under the first chapter.
    private let notes = Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: 120)
    /// The book's second chapter.
    private let chapterTwo = Heading(level: 1, text: "Chapter 2", chapterIndex: 1, characterOffset: 0)

    /// The book's three headings, in reading order.
    private var headings: [Heading] {
        [chapterOne, notes, chapterTwo]
    }

    /// A voice that is not a Personal Voice, which the book is read with.
    private let moira = SpeechExportVoiceInfo(
        identifier: "com.apple.voice.compact.en-IE.Moira",
        name: "Moira",
        isPersonalVoice: false
    )

    /// The options for a book with `headings` (the three above unless
    /// others are given), of which those in `skipped` are skipped, read by
    /// Moira at `wordsPerMinute` and `pitch`, offering the formats a speech
    /// export can write.
    private func makeState(
        _ headings: [Heading]? = nil,
        skipped: Set<String> = [],
        wordsPerMinute: Double = 225,
        pitch: Double = 1.2
    ) -> SpeechExportOptionsState {
        SpeechExportOptionsState(
            headings: headings ?? self.headings,
            skippedHeadingIDs: skipped,
            voice: moira,
            settings: SpeechExportVoiceSettings(voiceIdentifier: moira.identifier, wordsPerMinute: wordsPerMinute, pitch: pitch)
        )
    }

    // MARK: - The Words

    /// Every label, hint, value, item, and line of the options, and the
    /// words a file's name is made of, exactly.
    func testEveryWordOfTheOptions() {
        XCTAssertEqual(SpeechExportWording.formatLabel, "Format")
        XCTAssertEqual(
            SpeechExportWording.formatHint,
            "The kind of audio file. M4B is an audiobook; M4A and MP3 play in more apps. Each has a chapter for each heading."
        )
        XCTAssertEqual(SpeechExportWording.fromLabel, "From")
        XCTAssertEqual(SpeechExportWording.fromHint, "Where the spoken audio begins: the beginning of the book, or a heading.")
        XCTAssertEqual(SpeechExportWording.beginningOfBook, "Beginning of the book")
        XCTAssertEqual(SpeechExportWording.throughLabel, "To")
        XCTAssertEqual(
            SpeechExportWording.throughHint,
            "The heading whose section ends the spoken audio, with any headings under it, or the end of the book."
        )
        XCTAssertEqual(SpeechExportWording.endOfBook, "End of the book")
        XCTAssertEqual(SpeechExportWording.noHeadings, "This book has no headings, so all of it is exported.")

        XCTAssertEqual(SpeechExportWording.rateLabel, "Rate")
        XCTAssertEqual(SpeechExportWording.rateValue(200), "200 words per minute")
        // A speed between whole words is spoken rounded, a half up.
        XCTAssertEqual(SpeechExportWording.rateValue(212.5), "213 words per minute")
        XCTAssertEqual(SpeechExportWording.rateHint, "How fast the voice speaks in the audio file. It starts at this book's speed.")
        XCTAssertEqual(SpeechExportWording.pitchLabel, "Pitch")
        XCTAssertEqual(SpeechExportWording.pitchValue(1), "Normal (1.0x)")
        XCTAssertEqual(SpeechExportWording.pitchValue(1.5), "1.5x")
        XCTAssertEqual(SpeechExportWording.pitchHint, "How high the voice sounds in the audio file. It starts at this book's pitch.")

        XCTAssertEqual(
            SpeechExportWording.licence,
            "Speech made with the Mac's voices is for your personal, non-commercial use, under Apple's licence."
        )
        XCTAssertEqual(SpeechExportWording.optionsLabel, "Spoken audio options")

        XCTAssertEqual(SpeechExportWording.wholeBookName, "Audio")
        XCTAssertEqual(SpeechExportWording.beginningName, "Beginning")
        XCTAssertEqual(SpeechExportWording.endName, "End")
        XCTAssertEqual(SpeechExportWording.fileName(stem: "Middlemarch", part: "Audio"), "Middlemarch - Audio")
        XCTAssertEqual(SpeechExportWording.rangeName(from: "Beginning", through: "Chapter 2"), "Beginning to Chapter 2")
    }

    /// A heading is listed in the words the headings panel speaks it with,
    /// on one line: a skipped one after "Skipped, ", and one written on two
    /// lines with each run of white space made one space.
    func testAHeadingIsListedInTheHeadingsPanelsWords() {
        let notes = Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: 120)
        XCTAssertEqual(SpeechExportWording.headingItem(notes, isSkipped: true), "Skipped, Notes - level 2")
        XCTAssertEqual(SpeechExportWording.headingItem(notes, isSkipped: false), "Notes - level 2")

        let twoLines = Heading(level: 1, text: "  Chapter 3\n\tThe Long  Way Round \n", chapterIndex: 2)
        XCTAssertEqual(SpeechExportWording.headingItem(twoLines, isSkipped: false), "Chapter 3 The Long Way Round - level 1")
        XCTAssertEqual(
            SpeechExportWording.headingItem(twoLines, isSkipped: true),
            HeadingNavigatorView.accessibilityDescription(text: "Chapter 3 The Long Way Round", level: 1, isSkipped: true)
        )
        XCTAssertEqual(SpeechExportWording.oneLine(" \n\t "), "")
    }

    /// The voice line names the voice; with no voice installed, or a
    /// Personal Voice, which macOS never records to a file, it says the
    /// export's own refusal instead.
    func testTheVoiceLineNamesTheVoiceOrSaysWhyItCannotSpeak() {
        XCTAssertEqual(SpeechExportWording.voiceLine(moira), "Voice: Moira")

        XCTAssertEqual(SpeechExportWording.voiceLine(nil), SpeechExportError.noVoice.errorDescription)
        XCTAssertEqual(
            SpeechExportWording.voiceLine(nil),
            "No voice is installed to speak it. Add a voice in System Settings, Accessibility, Spoken Content, then export again."
        )

        let personal = SpeechExportVoiceInfo(
            identifier: "com.apple.speech.personalvoice.test",
            name: "Evening Voice",
            isPersonalVoice: true
        )
        XCTAssertEqual(
            SpeechExportWording.voiceLine(personal),
            SpeechExportError.personalVoice(name: "Evening Voice").errorDescription
        )
        XCTAssertEqual(
            SpeechExportWording.voiceLine(personal),
            "\u{201C}Evening Voice\u{201D} is a Personal Voice, which macOS can't record to a file. "
                + "Choose another voice for this book with the Voice button in its reader, then export again."
        )
    }

    // MARK: - The State

    /// The options start at M4B, the whole book, and the book's own speed
    /// and pitch, offering the formats a speech export can write unless
    /// others are given, the first of them chosen.
    func testTheOptionsStartAtM4BTheWholeBookAndTheBooksSpeedAndPitch() {
        let state = makeState()
        XCTAssertEqual(state.formats, SpeechExportFormat.available)
        XCTAssertEqual(state.format, .m4b)
        XCTAssertNil(state.fromHeadingID)
        XCTAssertNil(state.throughHeadingID)
        XCTAssertEqual(state.fromTag, "")
        XCTAssertEqual(state.throughTag, "")
        XCTAssertEqual(state.wordsPerMinute, 225)
        XCTAssertEqual(state.pitch, 1.2)
        XCTAssertEqual(
            state.choices,
            SpeechExportOptionsState.Choices(format: .m4b, range: .wholeBook, wordsPerMinute: 225, pitch: 1.2)
        )
        XCTAssertEqual(state.headings, headings)
        XCTAssertEqual(state.voice, moira)

        let offered = SpeechExportOptionsState(
            headings: headings,
            skippedHeadingIDs: [],
            voice: nil,
            settings: SpeechExportVoiceSettings(voiceIdentifier: nil, wordsPerMinute: 225, pitch: 1.2),
            formats: [.mp3, .m4a]
        )
        XCTAssertEqual(offered.formats, [.mp3, .m4a])
        XCTAssertEqual(offered.format, .mp3)
        XCTAssertNil(offered.voice)
    }

    /// A speed or pitch outside the ones Settings offers is held to the
    /// nearer end, whether it is the book's own or set later; one that is no
    /// number becomes Settings' default; one inside is kept as it is.
    func testTheSpeedAndPitchAreHeldToTheOnesSettingsOffers() {
        let state = makeState(wordsPerMinute: 900, pitch: 0.1)
        XCTAssertEqual(state.wordsPerMinute, 650)
        XCTAssertEqual(state.pitch, 0.5)

        state.wordsPerMinute = 20
        state.pitch = 3
        XCTAssertEqual(state.wordsPerMinute, 50)
        XCTAssertEqual(state.pitch, 2)

        state.wordsPerMinute = 375
        state.pitch = 0.8
        XCTAssertEqual(state.wordsPerMinute, 375)
        XCTAssertEqual(state.pitch, 0.8)

        state.wordsPerMinute = .nan
        state.pitch = .infinity
        XCTAssertEqual(state.wordsPerMinute, SettingsPolicy.wordsPerMinute.defaultValue)
        XCTAssertEqual(state.pitch, SettingsPolicy.pitchMultiplier.defaultValue)
    }

    /// A From past the To moves the To to it, and a To before the From
    /// moves the From to it, so the range is then that one heading; a From
    /// before the To, or a To after the From, moves nothing else.
    func testTheRangeStaysInReadingOrder() {
        let state = makeState()
        state.setThrough(notes.id)
        state.setFrom(chapterOne.id)
        XCTAssertEqual(state.choices.range, SpeechExportRange(fromHeadingID: chapterOne.id, throughHeadingID: notes.id))

        // From the second chapter, past the To.
        state.setFrom(chapterTwo.id)
        XCTAssertEqual(state.fromHeadingID, chapterTwo.id)
        XCTAssertEqual(state.throughHeadingID, chapterTwo.id)

        // To the first chapter, before the From.
        state.setThrough(chapterOne.id)
        XCTAssertEqual(state.fromHeadingID, chapterOne.id)
        XCTAssertEqual(state.throughHeadingID, chapterOne.id)

        // To the second chapter, after the From.
        state.setThrough(chapterTwo.id)
        XCTAssertEqual(state.fromHeadingID, chapterOne.id)
        XCTAssertEqual(state.throughHeadingID, chapterTwo.id)
        XCTAssertEqual(state.fromTag, chapterOne.id)
        XCTAssertEqual(state.throughTag, chapterTwo.id)
    }

    /// The empty tag is the book's beginning in From and its end in To, and
    /// moves neither other end; a tag naming none of the book's headings
    /// changes nothing.
    func testTheEmptyTagIsTheBeginningOrTheEndAndAnUnknownOneChangesNothing() {
        let state = makeState()
        state.setFrom(notes.id)
        state.setThrough(notes.id)

        state.setFrom("no such heading")
        state.setThrough("no such heading")
        XCTAssertEqual(state.fromHeadingID, notes.id)
        XCTAssertEqual(state.throughHeadingID, notes.id)

        state.setFrom("")
        XCTAssertNil(state.fromHeadingID)
        XCTAssertEqual(state.throughHeadingID, notes.id)
        state.setThrough("")
        XCTAssertNil(state.throughHeadingID)
        XCTAssertEqual(state.choices.range, .wholeBook)
        XCTAssertEqual(state.fromTag, "")
        XCTAssertEqual(state.throughTag, "")
    }

    /// The choices carry the format, the range, the speed, and the pitch
    /// chosen.
    func testTheChoicesCarryEverythingChosen() {
        let state = makeState()
        state.format = .m4a
        state.setFrom(notes.id)
        state.setThrough(chapterTwo.id)
        state.wordsPerMinute = 300
        state.pitch = 0.9
        XCTAssertEqual(
            state.choices,
            SpeechExportOptionsState.Choices(
                format: .m4a,
                range: SpeechExportRange(fromHeadingID: notes.id, throughHeadingID: chapterTwo.id),
                wordsPerMinute: 300,
                pitch: 0.9
            )
        )
    }

    /// From lists the book's beginning and then each heading, and To each
    /// heading and then the book's end: a heading in the headings panel's
    /// words, tagged with its ID, and the beginning and end tagged "". Two
    /// headings that share an ID are listed once.
    func testThePopUpsListTheBeginningEachHeadingAndTheEnd() {
        let state = makeState(skipped: [notes.id])
        XCTAssertTrue(state.hasHeadings)
        XCTAssertEqual(state.skippedHeadingIDs, [notes.id])
        let headingTitles = ["Chapter 1 - level 1", "Skipped, Notes - level 2", "Chapter 2 - level 1"]
        XCTAssertEqual(state.fromItems.map(\.title), ["Beginning of the book"] + headingTitles)
        XCTAssertEqual(state.fromItems.map(\.tag), ["", chapterOne.id, notes.id, chapterTwo.id])
        XCTAssertEqual(state.throughItems.map(\.title), headingTitles + ["End of the book"])
        XCTAssertEqual(state.throughItems.map(\.tag), [chapterOne.id, notes.id, chapterTwo.id, ""])
        XCTAssertEqual(state.fromItems.map(\.id), state.fromItems.map(\.tag))

        let repeated = makeState([chapterOne, chapterOne, chapterTwo])
        XCTAssertEqual(repeated.fromItems.map(\.tag), ["", chapterOne.id, chapterTwo.id])
        XCTAssertEqual(repeated.throughItems.map(\.tag), [chapterOne.id, chapterTwo.id, ""])
    }

    /// A book without headings lists only its beginning and its end, and is
    /// exported whole whatever is asked.
    func testABookWithoutHeadingsIsExportedWhole() {
        let state = makeState([])
        XCTAssertFalse(state.hasHeadings)
        XCTAssertEqual(state.fromItems, [SpeechExportOptionsState.Item(tag: "", title: "Beginning of the book")])
        XCTAssertEqual(state.throughItems, [SpeechExportOptionsState.Item(tag: "", title: "End of the book")])
        state.setFrom(chapterOne.id)
        state.setThrough(chapterOne.id)
        XCTAssertEqual(state.choices.range, .wholeBook)
        XCTAssertEqual(state.fileTitle(bookTitle: "Middlemarch"), "Middlemarch - Audio")
    }

    // MARK: - The File's Name

    /// The file is named after the book and the part of it spoken: the
    /// whole book, one heading, a range, a range from the beginning, and a
    /// range to the end.
    func testTheFileIsNamedAfterTheBookAndThePartSpoken() {
        let state = makeState()
        XCTAssertEqual(state.fileTitle(bookTitle: "Middlemarch"), "Middlemarch - Audio")

        state.setFrom(notes.id)
        state.setThrough(notes.id)
        XCTAssertEqual(state.fileTitle(bookTitle: "Middlemarch"), "Middlemarch - Notes")

        state.setThrough(chapterTwo.id)
        XCTAssertEqual(state.fileTitle(bookTitle: "Middlemarch"), "Middlemarch - Notes to Chapter 2")

        state.setFrom("")
        XCTAssertEqual(state.fileTitle(bookTitle: "Middlemarch"), "Middlemarch - Beginning to Chapter 2")

        state.setFrom(chapterOne.id)
        state.setThrough("")
        XCTAssertEqual(state.fileTitle(bookTitle: "Middlemarch"), "Middlemarch - Chapter 1 to End")
    }

    /// The name is made safe as every export makes one: the book's title as
    /// every export names a book ("Untitled" for a blank one), a heading on
    /// one line, a slash or colon made a hyphen. A heading of blank text is
    /// named by the book's title, as its chapter in the file is.
    func testTheFilesNameIsMadeSafe() {
        let slashed = Heading(level: 1, text: "Act 1/Scene 2:\nThe Quarrel", chapterIndex: 0, characterOffset: 0)
        let blank = Heading(level: 2, text: " \n ", chapterIndex: 0, characterOffset: 40)
        let state = makeState([slashed, blank])
        state.setFrom(slashed.id)
        state.setThrough(slashed.id)
        XCTAssertEqual(state.fileTitle(bookTitle: "Plays: Volume 2"), "Plays- Volume 2 - Act 1-Scene 2- The Quarrel")
        XCTAssertEqual(state.fileTitle(bookTitle: "  "), "Untitled - Act 1-Scene 2- The Quarrel")

        state.setThrough(blank.id)
        XCTAssertEqual(state.fileTitle(bookTitle: "Plays"), "Plays - Act 1-Scene 2- The Quarrel to Plays")
        state.setFrom(blank.id)
        XCTAssertEqual(state.fileTitle(bookTitle: "Plays"), "Plays - Plays")
    }

    /// A name with a heading of 300 characters is cut to the 180 bytes an
    /// export's name may have, between characters: a letter of two bytes is
    /// never cut in half.
    func testALongHeadingsNameIsCutTo180Bytes() {
        let long = Heading(level: 1, text: String(repeating: "a", count: 300), chapterIndex: 0, characterOffset: 0)
        let accented = Heading(level: 1, text: String(repeating: "\u{E9}", count: 300), chapterIndex: 1, characterOffset: 0)
        let state = makeState([long, accented])
        state.setFrom(long.id)
        state.setThrough(long.id)
        let name = state.fileTitle(bookTitle: "Book")
        XCTAssertEqual(name, "Book - " + String(repeating: "a", count: 173))
        XCTAssertEqual(name.utf8.count, BookExportService.maximumStemByteCount)

        state.setThrough(accented.id)
        state.setFrom(accented.id)
        let accentedName = state.fileTitle(bookTitle: "Book")
        XCTAssertEqual(accentedName, "Book - " + String(repeating: "\u{E9}", count: 86))
        XCTAssertEqual(accentedName.utf8.count, 179)
    }

    // MARK: - Drawn

    /// The window the drawn options are hosted in: the Export dialog's
    /// narrowest width, and room for every option.
    private let hostSize = NSSize(width: 460, height: 420)

    /// Drawn for a book with three headings, the options show three pop-ups,
    /// in reading order: the formats, From's items, and To's items, at M4B
    /// and the whole book. And two sliders, the speed's and the pitch's,
    /// each standing where the book's speed or pitch stands among the ones
    /// Settings offers (SwiftUI may count a slider's values from 0 to 1, so
    /// each is read by where it stands between its ends; the next test
    /// moves each to its ends).
    func testTheOptionsDrawThreePopUpsAndTwoSliders() throws {
        let state = makeState()
        try withOptionsView(state, popUps: 3) { hosting in
            let popUps = descendants(of: hosting, as: NSPopUpButton.self)
            guard popUps.count == 3 else { return XCTFail("the options drew \(popUps.count) pop-ups") }
            let (format, from, through) = (popUps[0], popUps[1], popUps[2])
            XCTAssertEqual(format.itemTitles, state.formats.map(\.title))
            XCTAssertEqual(format.titleOfSelectedItem, SpeechExportFormat.m4b.title)
            XCTAssertEqual(from.itemTitles, state.fromItems.map(\.title))
            XCTAssertEqual(from.titleOfSelectedItem, SpeechExportWording.beginningOfBook)
            XCTAssertEqual(through.itemTitles, state.throughItems.map(\.title))
            XCTAssertEqual(through.titleOfSelectedItem, SpeechExportWording.endOfBook)

            let sliders = descendants(of: hosting, as: NSSlider.self)
            guard sliders.count == 2 else { return XCTFail("the options drew \(sliders.count) sliders") }
            let (rate, pitch) = (sliders[0], sliders[1])
            XCTAssertEqual(position(of: rate), position(of: 225, in: SettingsPolicy.wordsPerMinute.range), accuracy: 0.001)
            XCTAssertEqual(position(of: pitch), position(of: 1.2, in: SettingsPolicy.pitchMultiplier.range), accuracy: 0.001)
        }
    }

    /// Each slider runs over the speeds or pitches Settings offers: moved to
    /// its maximum, as a drag would, it sets the fastest speed or the
    /// highest pitch, and moved to its minimum, the slowest or the lowest.
    func testTheSlidersRunOverTheSpeedsAndPitchesSettingsOffers() throws {
        let state = makeState()
        try withOptionsView(state, popUps: 3) { hosting in
            let sliders = descendants(of: hosting, as: NSSlider.self)
            guard sliders.count == 2 else { return XCTFail("the options drew \(sliders.count) sliders") }
            let (rate, pitch) = (sliders[0], sliders[1])

            move(rate, to: rate.maxValue)
            move(pitch, to: pitch.maxValue)
            XCTAssertTrue(
                waitUntil { state.wordsPerMinute == 650 && abs(state.pitch - 2) < 0.000_1 },
                "the speed is \(state.wordsPerMinute) and the pitch \(state.pitch)"
            )

            move(rate, to: rate.minValue)
            move(pitch, to: pitch.minValue)
            XCTAssertTrue(
                waitUntil { state.wordsPerMinute == 50 && abs(state.pitch - 0.5) < 0.000_1 },
                "the speed is \(state.wordsPerMinute) and the pitch \(state.pitch)"
            )
        }
    }

    /// Choosing in the pop-ups sets the options: a format; a From past the
    /// To, the book's end, which leaves the To where it is; and a To before
    /// the From, which moves the From to it. The pop-ups then show what was
    /// chosen.
    func testThePopUpsSetTheOptions() throws {
        let state = makeState()
        try withOptionsView(state, popUps: 3) { hosting in
            // M4A, the second format.
            choose(item: 1, inPopUp: 0, of: hosting)
            XCTAssertTrue(waitUntil { state.format == .m4a }, "the format is \(state.format)")

            // From the second chapter, From's last item, before the book's end.
            choose(item: 3, inPopUp: 1, of: hosting)
            XCTAssertTrue(waitUntil { state.fromHeadingID == self.chapterTwo.id }, "the range is \(state.choices.range)")
            XCTAssertNil(state.throughHeadingID)

            // To the first chapter, To's first item, before the From.
            choose(item: 0, inPopUp: 2, of: hosting)
            XCTAssertTrue(
                waitUntil { state.throughHeadingID == self.chapterOne.id && state.fromHeadingID == self.chapterOne.id },
                "the range is \(state.choices.range)"
            )

            let shown = [SpeechExportFormat.m4a.title, "Chapter 1 - level 1", "Chapter 1 - level 1"]
            XCTAssertTrue(
                waitUntil {
                    hosting.layoutSubtreeIfNeeded()
                    return self.shownTitles(in: hosting) == shown
                },
                "the pop-ups show \(shownTitles(in: hosting))"
            )
        }
    }

    /// A step of a slider draws the options anew, but not the From and To
    /// pop-ups, whose menus can hold thousands of headings; choosing in one
    /// of them draws them.
    func testASliderStepLeavesTheRangePopUpsAsTheyAre() throws {
        let state = makeState()
        try withOptionsView(state, popUps: 3) { hosting in
            let name = "SpeechExportRangePicker"
            XCTAssertGreaterThan(ViewBodyCounter.count(of: name), 0, "the pop-ups never drew")
            settle(hosting)
            let before = ViewBodyCounter.count(of: name)
            let valueBefore = descendants(of: hosting, as: NSSlider.self).first?.doubleValue

            state.wordsPerMinute += ReaderViewModel.speechSpeedStep
            state.pitch += 0.1
            settle(hosting)

            XCTAssertNotEqual(
                descendants(of: hosting, as: NSSlider.self).first?.doubleValue,
                valueBefore,
                "the options were not drawn anew, so this shows nothing"
            )
            XCTAssertEqual(ViewBodyCounter.count(of: name), before, "a slider's step drew the pop-ups")

            choose(item: 3, inPopUp: 1, of: hosting)
            XCTAssertTrue(waitUntil {
                hosting.layoutSubtreeIfNeeded()
                return ViewBodyCounter.count(of: name) > before
            }, "choosing in a pop-up did not draw it")
        }
    }

    /// Without headings, the options draw the Format pop-up alone, a line
    /// saying the whole book is exported standing in for From and To, and
    /// both sliders.
    func testWithoutHeadingsTheOptionsDrawOnePopUp() throws {
        let state = makeState([])
        try withOptionsView(state, popUps: 1) { hosting in
            let popUps = descendants(of: hosting, as: NSPopUpButton.self)
            XCTAssertEqual(popUps.map(\.itemTitles), [state.formats.map(\.title)])
            XCTAssertEqual(descendants(of: hosting, as: NSSlider.self).count, 2)
        }
    }

    /// A heading of 300 characters, chosen as the From, leaves the options
    /// no wider than the dialog holds them: the From and To pop-ups shorten
    /// it, and the voice and licence lines wrap.
    func testALongHeadingLeavesTheOptionsNarrow() {
        let long = Heading(level: 1, text: String(repeating: "W", count: 300), chapterIndex: 0, characterOffset: 0)
        let state = makeState([long, chapterTwo])
        state.setFrom(long.id)
        let size = NSHostingView(rootView: SpeechExportOptionsView(state: state)).fittingSize
        XCTAssertLessThanOrEqual(size.width, 440)
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    /// VoiceOver hears each control's label, value, and hint: each pop-up
    /// with the item chosen, each slider with its value in words; and no
    /// label names the kind of control, which VoiceOver says itself.
    ///
    /// The controls sit in the options' group, an element SwiftUI builds
    /// for an accessibility client but never for a test reading the window
    /// in-process (`FeedDownloadProgressViewTests` meets the same), so the
    /// AppKit pop-ups and sliders are read themselves where the group keeps
    /// them out of the window's elements (`exposedControls(in:)`). Skipped
    /// where the session exposes no hosted control to accessibility, or
    /// where none of the controls shows any of its words.
    func testVoiceOverHearsEachControlsLabelValueAndHint() throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        let state = makeState()
        state.setFrom(notes.id)
        try withOptionsView(state, popUps: 3) { hosting in
            let labels = [
                SpeechExportWording.formatLabel, SpeechExportWording.fromLabel, SpeechExportWording.throughLabel,
                SpeechExportWording.rateLabel, SpeechExportWording.pitchLabel,
            ]
            _ = waitUntil { self.exposedControls(in: hosting).contains { labels.contains($0.label) } }
            let controls = exposedControls(in: hosting)
            guard controls.contains(where: { labels.contains($0.label) }) else {
                throw XCTSkip("SwiftUI exposed none of the options' controls to a test reading the window in-process")
            }

            let format = try control(labelled: SpeechExportWording.formatLabel, in: controls)
            XCTAssertEqual(format.element.accessibilityValue() as? String, SpeechExportFormat.m4b.title)
            XCTAssertEqual(format.hint, SpeechExportWording.formatHint)
            let from = try control(labelled: SpeechExportWording.fromLabel, in: controls)
            XCTAssertEqual(from.element.accessibilityValue() as? String, "Notes - level 2")
            XCTAssertEqual(from.hint, SpeechExportWording.fromHint)
            let through = try control(labelled: SpeechExportWording.throughLabel, in: controls)
            XCTAssertEqual(through.element.accessibilityValue() as? String, SpeechExportWording.endOfBook)
            XCTAssertEqual(through.hint, SpeechExportWording.throughHint)

            let rate = try control(labelled: SpeechExportWording.rateLabel, in: controls)
            XCTAssertEqual(rate.role, .slider)
            XCTAssertEqual(rate.valueDescription, "225 words per minute")
            XCTAssertEqual(rate.hint, SpeechExportWording.rateHint)
            let pitch = try control(labelled: SpeechExportWording.pitchLabel, in: controls)
            XCTAssertEqual(pitch.role, .slider)
            XCTAssertEqual(pitch.valueDescription, "1.2x")
            XCTAssertEqual(pitch.hint, SpeechExportWording.pitchHint)

            XCTAssertFalse(
                controls.contains {
                    $0.label.localizedCaseInsensitiveContains("slider") || $0.label.localizedCaseInsensitiveContains("pop-up")
                },
                "\(controls.map(\.label))"
            )
        }
    }

    // MARK: - Hosting

    /// Hosts the options of `state` in a window of `hostSize`, inside a frame
    /// of that size, as a hosted view must not outgrow its window
    /// (`withHostedView`), until they have drawn `popUps` pop-ups and their
    /// two sliders; then passes the hosting view to `body`.
    private func withOptionsView(_ state: SpeechExportOptionsState, popUps: Int, _ body: (NSView) throws -> Void) throws {
        let view = SpeechExportOptionsView(state: state).frame(width: hostSize.width, height: hostSize.height)
        try withHostedView(view, size: hostSize, until: {
            self.descendants(of: $0, as: NSPopUpButton.self).count == popUps
                && self.descendants(of: $0, as: NSSlider.self).count == 2
        }) { hosting in
            try body(hosting)
        }
    }

    /// Lets whatever drawing is queued in `hosting` finish: half a second of
    /// the main run loop, laying the view out as it goes.
    private func settle(_ hosting: NSView) {
        _ = waitUntil(timeout: 0.5) {
            hosting.layoutSubtreeIfNeeded()
            return false
        }
    }

    /// The options' controls as VoiceOver reads them (`accessibleControls`):
    /// those among the window's accessibility elements; or, where the
    /// options' group keeps them out of those for a test reading in-process,
    /// the AppKit pop-ups and sliders the options drew, read the same way.
    private func exposedControls(in hosting: NSView) -> [AccessibleControl] {
        let underTheWindow = accessibleControls(in: hosting)
        guard underTheWindow.isEmpty else { return underTheWindow }
        let popUps: [NSView] = descendants(of: hosting, as: NSPopUpButton.self)
        let sliders: [NSView] = descendants(of: hosting, as: NSSlider.self)
        return (popUps + sliders).flatMap { accessibleControls(in: $0) }
    }

    /// Where `slider` stands between its ends, from 0 at its minimum to 1 at
    /// its maximum, whatever numbers the slider counts its values in.
    private func position(of slider: NSSlider) -> Double {
        (slider.doubleValue - slider.minValue) / (slider.maxValue - slider.minValue)
    }

    /// Where `value` stands between the ends of `range`, from 0 to 1.
    private func position(of value: Double, in range: ClosedRange<Double>) -> Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    /// Moves `slider` to `value`, in its own numbers, and sends its action,
    /// as a drag that ends there does.
    private func move(_ slider: NSSlider, to value: Double) {
        slider.doubleValue = value
        slider.sendAction(slider.action, to: slider.target)
    }

    /// The titles of the items the pop-ups in `hosting` show, in order.
    private func shownTitles(in hosting: NSView) -> [String?] {
        descendants(of: hosting, as: NSPopUpButton.self).map(\.titleOfSelectedItem)
    }

    /// Chooses item `item` of pop-up number `number` (0 Format, 1 From,
    /// 2 To) of the options in `hosting`, as a click in its menu does. The
    /// pop-ups are found afresh, as SwiftUI may draw them anew after a
    /// change; a pop-up or an item the options lack fails the test.
    private func choose(item: Int, inPopUp number: Int, of hosting: NSView) {
        hosting.layoutSubtreeIfNeeded()
        let popUps = descendants(of: hosting, as: NSPopUpButton.self)
        guard popUps.indices.contains(number), let menu = popUps[number].menu, item < menu.numberOfItems else {
            return XCTFail("the options have no item \(item) in pop-up \(number): \(popUps.map(\.itemTitles))")
        }
        menu.performActionForItem(at: item)
    }
}
