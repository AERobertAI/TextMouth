import AppKit
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
