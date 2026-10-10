import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import TextMouth

// The wording and behavior TODO A10's audit fixed, one class for each kind
// of fix: what VoiceOver and a braille display are given, pinned in words.

// MARK: - The Capture-Group Hint

/// The substitution rule editor's replacement field tells VoiceOver how a
/// regular expression puts back what a group of its pattern matched: a
/// dollar sign and the group's number, which `NSRegularExpression` reads.
/// It used to say "backslash 1", which gives a plain digit.
@MainActor
final class SubstitutionCaptureGroupHintTests: XCTestCase {
    /// The hint names the dollar sign in words, since VoiceOver speaks "$1"
    /// as "one dollar", and shows it as typed, for a braille display.
    func testTheReplacementHintNamesTheDollarSign() {
        XCTAssertEqual(
            SubstitutionRuleEditorView.replacementHint,
            "In a regular expression, a dollar sign and a group's number, as in $1 or $2, put back what that group matched."
        )
    }

    /// What the hint says is what a regular-expression rule does: "$1" and
    /// "$2" put back their groups, and "\1" gives a plain "1".
    func testADollarSignAndANumberPutBackTheGroup() {
        let dollars = SubstitutionRule(pattern: "(\\w+)@(\\w+)", replacement: "$2 at $1", isRegex: true)
        XCTAssertEqual(SubstitutionRuleEditorView.testResult(of: dollars, on: "me@home"), "home at me")

        let backslash = SubstitutionRule(pattern: "(\\w+)@", replacement: "\\1 at", isRegex: true)
        XCTAssertEqual(SubstitutionRuleEditorView.testResult(of: backslash, on: "me@"), "1 at")
    }
}

// MARK: - One Way Out of Edit Mode

/// The Library's edit bar has no Done of its own: it did exactly what the
/// window's toolbar button, "Exit edit mode", does, and Command-E does too,
/// so VoiceOver met one command twice.
@MainActor
final class EditModeBarExitTests: XCTestCase {
    /// Hosted, the bar's buttons reach accessibility without an "Exit edit
    /// mode" among them; skipped where SwiftUI exposes no buttons to a
    /// hosted window, as the edit bar's other tests are.
    func testTheEditBarHasNoExitButtonOfItsOwn() throws {
        let bar = EditModeBar(
            selectedCount: 1,
            totalCount: 3,
            removalPreferences: RemovalPreferences(confirmsFirst: true, movesToTrash: true),
            onSelectAll: {},
            onDeselectAll: {},
            onMove: {},
            onRemove: {}
        )
        try withHostedControls(bar) { controls in
            let labels = controls.filter { $0.role == .button }.map(\.label)
            guard !labels.isEmpty else {
                throw XCTSkip("SwiftUI exposed no AppKit button to accessibility in this run")
            }
            XCTAssertFalse(labels.contains("Exit edit mode"), "\(labels)")
            XCTAssertFalse(labels.contains("Done"), "\(labels)")
        }
    }
}

// MARK: - Read Once, Read Right

/// Each value is read once and with its unit, and no label names the kind
/// of control, which VoiceOver says itself. The captions above the sliders
/// and steppers that repeated their values are hidden from VoiceOver; SwiftUI
/// builds no accessibility element for text in a hosted window, so those are
/// read from the code, and these tests read the controls.
@MainActor
final class ReadOnceTests: XCTestCase {
    /// The Voice tab's sliders, the Miscellaneous tab's, and the reader's
    /// voice sheet's are labelled by their setting alone, with their values
    /// in words.
    func testSlidersAreLabelledByTheirSettingAlone() throws {
        let settings = try makeA10Settings()
        settings.bluetoothMonitoringEnabled = true
        settings.restartTimerGestureEnabled = true

        try withA10HostedControls(VoiceSettingsView().environmentObject(settings)) { controls in
            let sliders = controls.filter { $0.role == .slider }
            XCTAssertEqual(sliders.map(\.label), ["Default speed", "Default pitch"])
            XCTAssertEqual(
                sliders.map(\.valueDescription),
                ["\(Int(settings.wordsPerMinute)) words per minute", SpeechService.pitchLabel(settings.pitchMultiplier)]
            )
        }
        try withA10HostedControls(MiscellaneousSettingsView().environmentObject(settings)) { controls in
            XCTAssertEqual(
                controls.filter { $0.role == .slider }.map(\.label),
                ["Bluetooth disconnect delay", "Gesture time window"]
            )
        }
        let reader = makeA10TextReader()
        defer { reader.close() }
        try withA10HostedControls(BookVoicePickerView(viewModel: reader)) { controls in
            let sliders = controls.filter { $0.role == .slider }
            XCTAssertEqual(sliders.map(\.label), ["Speed", "Pitch"])
            XCTAssertFalse(controls.contains { $0.label.localizedCaseInsensitiveContains("slider") }, "\(controls.map(\.label))")
        }
    }

    /// The custom sleep timer's stepper says its minutes with their unit,
    /// as the field beside it does: "30 minutes", not "30".
    func testTheCustomTimerStepperSaysItsUnit() throws {
        let reader = makeA10TextReader()
        defer { reader.close() }
        let sheet = SleepTimerView(
            viewModel: reader,
            sleepTimerService: SleepTimerService(userDefaults: makeSandboxedPreferences("a10-sleep-timer")),
            onClose: {},
            autoClose: false
        )
        try withA10HostedControls(sheet) { controls in
            let stepper = try XCTUnwrap(controls.first { $0.role == .incrementor }, "\(controls.map(\.label))")
            XCTAssertEqual(stepper.label, SleepTimerView.adjustMinutesLabel)
            XCTAssertEqual(stepper.valueDescription, "30 minutes")
        }
    }

    /// A bookmark's row shows the day it was added, and its label, which
    /// the row and the Bookmarks rotor speak, ends with the same words.
    func testABookmarksLabelEndsWithTheDayItsRowShows() throws {
        let day = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12)))
        let bookmark = Bookmark(number: 2, chapterIndex: 0, characterOffset: 0, label: "Ferry times", dateCreated: day)
        XCTAssertEqual(bookmark.dateText, day.formatted(date: .long, time: .omitted))
        XCTAssertTrue(bookmark.dateText.contains("2026"), bookmark.dateText)
        XCTAssertEqual(
            BookmarkRow(bookmark: bookmark, headingText: "Harbour").bookmarkAccessibilityLabel,
            "Bookmark 2, Harbour, Note: Ferry times, added \(bookmark.dateText)"
        )
    }
}

// MARK: - Hints That Say What Happens

/// Each hint the audit found naming a gesture, a click, a menu to open, or
/// a fixed key says what happens instead, as Apple's guidance for hints
/// asks: VoiceOver, a braille display's keys, and the keyboard each do the
/// thing their own way. Keys are named only where they are the input
/// itself, and then in words, which a braille display shows as words.
@MainActor
final class ResultHintTests: XCTestCase {
    /// The Library's rows say what activating them does: a folder's opens
    /// it, and a book's opens it, or in edit mode selects or deselects it.
    func testLibraryRowsSayWhatTheyDo() {
        XCTAssertEqual(FolderRow.accessibilityHint, "Opens the folder.")
        XCTAssertEqual(BookRow.accessibilityHint(isEditMode: false, isEditSelected: false), "Opens the book.")
        XCTAssertEqual(BookRow.accessibilityHint(isEditMode: false, isEditSelected: true), "Opens the book.")
        XCTAssertEqual(BookRow.accessibilityHint(isEditMode: true, isEditSelected: false), "Selects this book.")
        XCTAssertEqual(BookRow.accessibilityHint(isEditMode: true, isEditSelected: true), "Deselects this book.")
    }

    /// The toolbar's Edit button says what pressing it does: enters edit
    /// mode, or leaves it, with the books selected counted.
    func testTheEditButtonSaysWhatItDoes() {
        XCTAssertEqual(
            LibraryView.editModeButtonHint(isEditMode: false, selectedCount: 0),
            "Enters edit mode, for selecting several books to move or remove."
        )
        XCTAssertEqual(LibraryView.editModeButtonHint(isEditMode: true, selectedCount: 2), "Exits edit mode. 2 books selected.")
    }

    /// The reader's bookmark and heading rows say where they go, and that
    /// the list closes.
    func testTheReadersListRowsSayWhatTheyDo() {
        let bookmark = BookmarkRow(bookmark: Bookmark(number: 1, chapterIndex: 0, characterOffset: 0), headingText: nil)
        XCTAssertEqual(bookmark.accessibilityHintText, "Goes to this bookmark and closes the list.")
        let heading = HeadingRow(heading: Heading(level: 1, text: "One"), isCurrent: false, infoText: "")
        XCTAssertEqual(heading.accessibilityHintText, "Goes to this heading and closes the list.")
    }

    /// A heading's row offers its commands as VoiceOver actions under the
    /// names its context menu gives them: Go To, and Skip Section, or
    /// Include Section for a section already skipped.
    func testAHeadingRowsCommandsAreNamedAsItsContextMenuNamesThem() {
        let included = HeadingRow.commandTitles(isSkipped: false)
        XCTAssertEqual(included.goTo, "Go To")
        XCTAssertEqual(included.toggleSkip, "Skip Section")
        let skipped = HeadingRow.commandTitles(isSkipped: true)
        XCTAssertEqual(skipped.goTo, "Go To")
        XCTAssertEqual(skipped.toggleSkip, "Include Section")
    }

    /// The custom timer's field names the stepper beside it, and its step,
    /// which is the stepper's own.
    func testTheCustomTimerFieldNamesItsStepper() {
        XCTAssertEqual(SleepTimerView.customMinutesStep, 5)
        XCTAssertEqual(
            SleepTimerView.customMinutesHint,
            "Type the minutes, or change them 5 at a time with Adjust minutes. Return sets the timer and starts playing."
        )
    }

    /// The empty bookmark list names the key in force for adding one, in
    /// words, or the Add Bookmark button when it has no key.
    func testTheEmptyBookmarkListNamesTheKeyInForceInWords() {
        XCTAssertEqual(
            BookmarkPanelView.emptyListHelp(keys: ShortcutAction.defaultBindings[.addBookmark] ?? []),
            "Command + B adds a bookmark at the current position."
        )
        XCTAssertEqual(
            BookmarkPanelView.emptyListHelp(keys: [KeyBinding(key: "b", shift: true), KeyBinding(key: "b").asDoublePress(true)]),
            "Shift + B or B twice adds a bookmark at the current position."
        )
        XCTAssertEqual(BookmarkPanelView.emptyListHelp(keys: []), "Add Bookmark adds one at the current position.")
    }

    /// The restart gesture's note names the tab as its toolbar does and the
    /// default key in words, not in signs.
    func testTheRestartGesturesNoteNamesTheShortcutsTabAndTheKeyInWords() {
        XCTAssertEqual(
            MiscellaneousSettingsView.restartShortcutNote,
            "The keyboard shortcut for the same action is Restart Sleep Timer in the Shortcuts tab; its default is Shift + Command + R."
        )
    }

    /// None of the hints and notes above names a gesture, a click, a menu
    /// to open, or a key in signs.
    func testNoneOfTheseHintsNamesAGestureAClickOrASign() {
        let texts = [
            FolderRow.accessibilityHint,
            BookRow.accessibilityHint(isEditMode: false, isEditSelected: false),
            BookRow.accessibilityHint(isEditMode: true, isEditSelected: false),
            BookRow.accessibilityHint(isEditMode: true, isEditSelected: true),
            LibraryView.editModeButtonHint(isEditMode: false, selectedCount: 0),
            BookmarkRow(bookmark: Bookmark(number: 1, chapterIndex: 0, characterOffset: 0), headingText: nil).accessibilityHintText,
            HeadingRow(heading: Heading(level: 1, text: "One"), isCurrent: false, infoText: "").accessibilityHintText,
            ShortcutsSettingsWording.recordHint,
            ShortcutsSettingsWording.recordingHint,
            SleepTimerView.customMinutesHint,
            BookmarkPanelView.emptyListHelp(keys: ShortcutAction.defaultBindings[.addBookmark] ?? []),
            MiscellaneousSettingsView.restartShortcutNote,
        ]
        for text in texts {
            for forbidden in ["tap", "click", "context menu", "Cmd", "\u{2318}", "\u{21E7}", "\u{2325}", "\u{2303}", "arrows"] {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden), "\"\(text)\" says \"\(forbidden)\"")
            }
        }
    }
}

// MARK: - Counted Words

/// Every count the audit found with a plural noun beside it, whatever the
/// count, now goes through `CountWording`: one book, one rule, one minute,
/// one second, and the screen and VoiceOver say the same words.
@MainActor
final class CountedWordTests: XCTestCase {
    /// The counts the fixes use: minutes, seconds, and a part of a whole
    /// whose noun agrees with the whole.
    func testCountWordingCountsMinutesSecondsAndParts() {
        XCTAssertEqual(CountWording.minutes(1), "1 minute")
        XCTAssertEqual(CountWording.minutes(0), "0 minutes")
        XCTAssertEqual(CountWording.minutes(30), "30 minutes")
        XCTAssertEqual(CountWording.seconds(1), "1 second")
        XCTAssertEqual(CountWording.seconds(5), "5 seconds")
        XCTAssertEqual(CountWording.part(0, of: 1, singular: "book", plural: "books"), "0 of 1 book")
        XCTAssertEqual(CountWording.part(1, of: 1, singular: "book", plural: "books"), "1 of 1 book")
        XCTAssertEqual(CountWording.part(2, of: 5, singular: "book", plural: "books"), "2 of 5 books")
    }

    /// The Library's edit mode counts one book as one: the toolbar's Edit
    /// button, the bar's Select All, and the bar itself.
    func testTheLibrarysEditModeCountsOneBook() {
        XCTAssertEqual(LibraryView.editModeButtonHint(isEditMode: true, selectedCount: 1), "Exits edit mode. 1 book selected.")
        XCTAssertEqual(LibraryView.editModeButtonHint(isEditMode: true, selectedCount: 0), "Exits edit mode. 0 books selected.")
        XCTAssertEqual(EditModeBar.selectAllLabel(selectedCount: 0, totalCount: 1), "Select all 1 book")
        XCTAssertEqual(EditModeBar.selectAllLabel(selectedCount: 2, totalCount: 12), "Select all 12 books")
        XCTAssertEqual(EditModeBar.selectAllLabel(selectedCount: 1, totalCount: 1), "Deselect all books")
        XCTAssertEqual(EditModeBar.accessibilityLabel(selectedCount: 0, totalCount: 1), "Edit mode, 0 of 1 book selected")
        XCTAssertEqual(EditModeBar.accessibilityLabel(selectedCount: 2, totalCount: 5), "Edit mode, 2 of 5 books selected")
    }

    /// The Text tab's footer counts one rule as one.
    func testTheTextTabCountsOneRule() {
        XCTAssertEqual(SubstitutionsSettingsView.ruleCountText(rules: 1, enabled: 1), "1 rule (1 enabled)")
        XCTAssertEqual(SubstitutionsSettingsView.ruleCountText(rules: 15, enabled: 12), "15 rules (12 enabled)")
        XCTAssertEqual(SubstitutionsSettingsView.ruleCountText(rules: 0, enabled: 0), "0 rules (0 enabled)")
    }

    /// The sleep timer counts one minute as one, in its name, the
    /// announcement of setting it, and its buttons' labels; and the
    /// Playback tab's fade counts one second as one.
    func testTheSleepTimerCountsOneMinuteAndOneSecond() {
        XCTAssertEqual(SleepTimerDuration.minutes(1).displayName, "1 minute")
        XCTAssertEqual(SleepTimerDuration.minutes(45).displayName, "45 minutes")
        XCTAssertEqual(SleepTimerView.announcement(forSetting: .minutes(1)), "Timer set for 1 minute.")
        XCTAssertEqual(SleepTimerView.setTimerLabel(minutes: 1), "Set timer for 1 minute and start playing")
        XCTAssertEqual(SleepTimerView.setTimerLabel(minutes: 60), "Set timer for 60 minutes and start playing")
        XCTAssertEqual(PlaybackSettingsView.fadeOutText(0), "Off")
        XCTAssertEqual(PlaybackSettingsView.fadeOutText(1), "1 second")
        XCTAssertEqual(PlaybackSettingsView.fadeOutText(3), "3 seconds")
    }
}

// MARK: - The Heading Filter

/// The headings list's level filter names its choices in words, "Level 1",
/// "Levels 1 to 2", "All levels", where it said "H1–H1" with an en dash;
/// and it is one control with one name, "Show levels", where VoiceOver met
/// a caption, then the picker under another name, and the screen showed
/// the picker's own title too.
@MainActor
final class HeadingFilterWordingTests: XCTestCase {
    /// Each choice's name, and the choices books with headings at some
    /// levels are offered.
    func testTheFiltersChoicesAreNamedInWords() {
        XCTAssertEqual(HeadingNavigatorView.filterChoiceTitle(maximumLevel: 1), "Level 1")
        XCTAssertEqual(HeadingNavigatorView.filterChoiceTitle(maximumLevel: 2), "Levels 1 to 2")
        XCTAssertEqual(HeadingNavigatorView.filterChoiceTitle(maximumLevel: 5), "Levels 1 to 5")
        XCTAssertEqual(HeadingNavigatorView.filterChoiceTitle(maximumLevel: HeadingNavigatorView.deepestFilterLevel), "All levels")
        XCTAssertEqual(offeredTitles(forLevels: [1, 2, 3]), ["Level 1", "Levels 1 to 2", "All levels"])
        XCTAssertEqual(offeredTitles(forLevels: [2, 4]), ["Levels 1 to 2", "All levels"])
        XCTAssertEqual(HeadingNavigatorView.levelFilterLabel, "Show levels")
        XCTAssertEqual(HeadingNavigatorView.levelFilterHint, "Shows only the headings up to the level chosen.")
        XCTAssertEqual(HeadingNavigatorView.listLabel(headingCount: 1), "Headings, 1 heading")
        XCTAssertEqual(HeadingNavigatorView.listLabel(headingCount: 3), "Headings, 3 headings")
    }

    /// Drawn, the filter is one radio group VoiceOver calls "Show levels",
    /// holding the choices by their names; nothing is called "Heading level
    /// filter" or "Max level" any more. The sheet's other controls keep
    /// their own names too: the list's name, "Headings, 3 headings", was on
    /// the whole sheet, and every control in it took it, the filter and the
    /// display picker among them.
    func testTheDrawnFilterHasOneNameAndItsChoicesWords() throws {
        let reader = makeA10TextReader(content: DocumentContent(
            title: "Filter",
            author: "Tester",
            chapters: [
                Chapter(
                    title: "One",
                    text: "Part. Chapter. Scene.",
                    headings: [
                        Heading(level: 1, text: "Part", characterOffset: 0),
                        Heading(level: 2, text: "Chapter", characterOffset: 6),
                        Heading(level: 3, text: "Scene", characterOffset: 15),
                    ]
                ),
            ]
        ))
        defer { reader.close() }
        try withA10HostedControls(HeadingNavigatorView(viewModel: reader)) { controls in
            let filter = try XCTUnwrap(
                controls.first { $0.role == .radioGroup && $0.label == HeadingNavigatorView.levelFilterLabel },
                "\(controls.map { "\($0.role.rawValue) \($0.label)" })"
            )
            let choices = (filter.element.accessibilityChildren() ?? []).compactMap {
                ($0 as? NSAccessibilityProtocol)?.accessibilityLabel()
            }
            XCTAssertEqual(choices, ["Level 1", "Levels 1 to 2", "All levels"])
            let labels = controls.map(\.label)
            XCTAssertFalse(labels.contains("Heading level filter"), "\(labels)")
            XCTAssertFalse(labels.contains("Max level"), "\(labels)")
            XCTAssertEqual(
                controls.filter { $0.role == .radioGroup }.map(\.label),
                ["Heading info display mode", HeadingNavigatorView.levelFilterLabel]
            )
            XCTAssertEqual(
                controls.filter { $0.role == .scrollArea }.map(\.label),
                [HeadingNavigatorView.listLabel(headingCount: 3)]
            )
        }
    }

    /// The titles the filter offers a book whose headings are at `levels`.
    private func offeredTitles(forLevels levels: [Int]) -> [String] {
        HeadingNavigatorView.filterLevels(for: levels).map { HeadingNavigatorView.filterChoiceTitle(maximumLevel: $0) }
            + [HeadingNavigatorView.filterChoiceTitle(maximumLevel: HeadingNavigatorView.deepestFilterLevel)]
    }
}

// MARK: - Saving a Book's Settings

/// The two buttons that make a book's voice settings the defaults, the
/// playback bar's and the voice sheet's, share one label naming the voice,
/// the speed, and the pitch, which is what they copy; they said "speed",
/// and "voice and speed". The sheet's reset, which clears all three, says
/// so too.
@MainActor
final class SaveAsDefaultsWordingTests: XCTestCase {
    /// The shared words.
    func testTheButtonsNameTheVoiceTheSpeedAndThePitch() {
        XCTAssertEqual(BookVoiceSettingsWording.saveAsDefaultsLabel, "Save this book's voice, speed, and pitch as the global defaults")
        XCTAssertEqual(
            BookVoiceSettingsWording.saveAsDefaultsHint,
            "Updates the default voice, speed, and pitch for every book without settings of its own."
        )
        XCTAssertEqual(BookVoiceSettingsWording.resetToDefaultsLabel, "Reset this book's voice, speed, and pitch to the global defaults")
        XCTAssertEqual(
            BookVoiceSettingsWording.resetToDefaultsHint,
            "Removes this book's own voice, speed, and pitch, so it uses the global defaults."
        )
    }

    /// What the label says is what saving does: a book's own speed, pitch,
    /// and voice all become the defaults.
    func testSavingCopiesTheSpeedThePitchAndTheVoice() throws {
        guard let voiceID = AVSpeechSynthesisVoice.speechVoices().first?.identifier else {
            throw XCTSkip("This Mac has no speech voice to choose")
        }
        let settings = try makeA10Settings()
        let reader = makeA10TextReader(settings: settings, voiceID: voiceID, wordsPerMinute: 310, pitch: 1.3)
        defer { reader.close() }

        recordingAnnouncements { reader.saveSettingsToGlobal() }

        XCTAssertEqual(settings.wordsPerMinute, 310)
        XCTAssertEqual(settings.pitchMultiplier, 1.3, accuracy: 0.001)
        XCTAssertEqual(settings.selectedVoiceID, voiceID)
    }
}

// MARK: - Shared Fixtures

extension XCTestCase {
    /// Hosts `view` in a frame of its own fixed size, so the window never
    /// follows its content, and passes the AppKit controls VoiceOver reads
    /// to `body`; skipped where hosted windows expose none.
    @MainActor
    fileprivate func withA10HostedControls<Content: View>(
        _ view: Content,
        _ body: ([AccessibleControl]) throws -> Void
    ) throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        let size = NSSize(width: 600, height: 900)
        try withHostedView(
            view.frame(width: size.width, height: size.height),
            size: size,
            until: { !self.accessibleControls(in: $0).isEmpty }
        ) { hostingView in
            try body(accessibleControls(in: hostingView))
        }
    }

    /// A reader of a text book whose file does not exist, in a library of
    /// its own: enough for the sheets, which read it but never play it.
    /// `content`, given, is the book's as though it had loaded; the book's
    /// own voice, speed, and pitch are those given; and `settings` are the
    /// global settings, a model without services unless a test passes one.
    @MainActor
    fileprivate func makeA10TextReader(
        content: DocumentContent? = nil,
        settings: SettingsViewModel? = nil,
        voiceID: String? = nil,
        wordsPerMinute: Double? = nil,
        pitch: Double? = nil
    ) -> ReaderViewModel {
        let book = Book(
            title: "A10 Fixture",
            format: .txt,
            filePath: TextMouthPaths.root.appendingPathComponent("missing-\(UUID().uuidString).txt").path,
            md5Hash: UUID().uuidString,
            localVoiceID: voiceID,
            localWPM: wordsPerMinute,
            localPitch: pitch
        )
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book])
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: settings ?? SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        )
        if let content {
            reader.content = content
        }
        return reader
    }

    /// A settings model of the test's own, whose preferences and config.json
    /// are the test's.
    @MainActor
    fileprivate func makeA10Settings() throws -> SettingsViewModel {
        let configFile = try makeTestDirectory("A10Settings").appendingPathComponent("config.json")
        let configService = ConfigService(fileURL: configFile, fileOperations: ConfigService.FileOperations(
            write: { data, url in try data.write(to: url, options: .atomic) },
            openForEvents: { _ in -1 },
            close: { _ in }
        ))
        return SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: makeSandboxedPreferences("a10-settings"),
            configService: configService
        )
    }
}
