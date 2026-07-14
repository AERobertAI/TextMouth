import XCTest
@testable import TextMouth

final class WindowFocusPolicyTests: XCTestCase {
    func testSourceWindowOnlyMatchesItsHost() {
        XCTAssertTrue(route(source: true, match: true, host: true, key: true))
        XCTAssertFalse(route(source: true, match: false, host: true, key: false))
    }

    func testOnlyFocusedReaderAcceptsTaggedPlaybackShortcut() {
        XCTAssertTrue(route(source: true, match: true, host: true, key: true))
        XCTAssertFalse(route(source: true, match: false, host: true, key: false))
    }

    func testSourceLessMenuCommandRequiresKeyWindow() {
        XCTAssertTrue(route(source: false, match: false, host: true, key: true))
        XCTAssertFalse(route(source: false, match: false, host: true, key: false))
    }

    func testStandardFocusAllowsLaunchWithoutAnotherKeyWindow() {
        XCTAssertTrue(StandardVoiceOverFocusTriggerView.shouldPostFocus(
            isSheet: false, targetWindowIsKey: false, anotherWindowIsKey: false
        ))
    }

    func testStandardFocusDoesNotStealFromAnotherKeyWindow() {
        XCTAssertFalse(StandardVoiceOverFocusTriggerView.shouldPostFocus(
            isSheet: false, targetWindowIsKey: false, anotherWindowIsKey: true
        ))
    }

    func testStandardFocusUsesFewerRetriesThanSheetFocus() {
        XCTAssertEqual(StandardVoiceOverFocusTriggerView.focusAttemptCount(isSheet: false), 2)
        XCTAssertEqual(StandardVoiceOverFocusTriggerView.focusAttemptCount(isSheet: true), 4)
    }

    func testHeadingPresentationStoresOneItemPerHeading() {
        let headings = (0..<6).map {
            Heading(level: 1, text: "Heading \($0)", chapterIndex: 0, characterOffset: $0)
        }
        let items = headings.map {
            HeadingNavigatorView.HeadingListItem(
                heading: $0,
                isSkipped: false,
                infoText: "",
                accessibilityDescription: HeadingNavigatorView.accessibilityDescription(
                    text: $0.text, level: $0.level
                )
            )
        }

        XCTAssertEqual(items.count, headings.count)
        XCTAssertEqual(Set(items.map(\.id)).count, headings.count)
    }

    func testEmptyBookmarkControlHasInteractiveFocusMetadata() {
        XCTAssertEqual(voiceOverFocusID, "vo-focus-target")
        XCTAssertTrue(StandardVoiceOverFocusTriggerView.acceptsFallback(
            role: "AXButton", label: "Add bookmark at current position", isScrollerPart: false
        ))
    }

    func testLibraryFallbackPrefersTimeSummaryWhenBooksExist() {
        XCTAssertEqual(
            LibraryFocusTarget.preferred(hasContinueListening: false, hasDisplayedBooks: true),
            .timeSummary
        )
    }

    func testContinueListeningWinsOverOtherLibraryTargets() {
        XCTAssertEqual(
            LibraryFocusTarget.preferred(hasContinueListening: true, hasDisplayedBooks: true),
            .continueListening
        )
    }

    func testEmptyLibraryFallsBackToImportButton() {
        XCTAssertEqual(
            LibraryFocusTarget.preferred(hasContinueListening: false, hasDisplayedBooks: false),
            .importButton
        )
    }

    func testFoldersWithBooksStillPreferTimeSummary() {
        XCTAssertEqual(
            LibraryFocusTarget.preferred(hasContinueListening: false, hasDisplayedBooks: true),
            .timeSummary
        )
    }

    func testTimeSummaryIsARealFocusableGroup() {
        XCTAssertTrue(StandardVoiceOverFocusTriggerView.acceptsFallback(
            role: "AXRow", label: "2 books, 6 hours remaining", isScrollerPart: false
        ))
    }

    func testFallbackRejectsUnlabelledScrollerButtons() {
        XCTAssertFalse(StandardVoiceOverFocusTriggerView.acceptsFallback(
            role: "AXButton", label: "", isScrollerPart: true
        ))
    }

    func testSearchMenuCommandOnlyTargetsFocusedReader() {
        XCTAssertTrue(route(source: false, match: false, host: true, key: true))
        XCTAssertFalse(route(source: false, match: false, host: true, key: false))
    }

    func testCopyPositionMenuCommandOnlyTargetsFocusedReader() {
        XCTAssertTrue(route(source: false, match: false, host: true, key: true))
        XCTAssertFalse(route(source: false, match: false, host: true, key: false))
    }

    func testOpenBookShortcutOnlyTargetsMatchingLibrary() {
        XCTAssertTrue(route(source: true, match: true, host: true, key: true))
        XCTAssertFalse(route(source: true, match: false, host: true, key: false))
    }

    func testNewFromTextMenuOnlyTargetsFocusedLibrary() {
        XCTAssertTrue(route(source: false, match: false, host: true, key: true))
        XCTAssertFalse(route(source: false, match: false, host: true, key: false))
    }

    func testMissingHostWindowAcceptsCommandDuringAttachment() {
        XCTAssertTrue(route(source: true, match: false, host: false, key: false))
        XCTAssertTrue(route(source: false, match: false, host: false, key: false))
    }

    func testHeadingAccessibilityNamesHeadingBeforeLevel() {
        XCTAssertEqual(
            HeadingNavigatorView.accessibilityDescription(text: "The Departure", level: 2),
            "The Departure - level 2"
        )
    }

    func testSkippedHeadingPrefixComesBeforeName() {
        XCTAssertEqual(
            HeadingNavigatorView.accessibilityDescription(
                text: "Skipped Section", level: 3, isSkipped: true
            ),
            "Skipped, Skipped Section - level 3"
        )
    }

    func testHeadingAccessibilityFormatIsConcise() {
        let description = HeadingNavigatorView.accessibilityDescription(text: "Chapter 5", level: 1)

        XCTAssertEqual(description, "Chapter 5 - level 1")
        XCTAssertLessThan(description.count, "Level 1 heading: Chapter 5".count)
    }

    func testHeadingRotorAndRowShareFormatter() {
        let row = HeadingNavigatorView.accessibilityDescription(text: "The Battle", level: 2)
        let rotor = HeadingNavigatorView.accessibilityDescription(text: "The Battle", level: 2)

        XCTAssertEqual(rotor, row)
    }

    private func route(source: Bool, match: Bool, host: Bool, key: Bool) -> Bool {
        WindowCommandRouting.shouldAccept(
            hasSourceWindow: source,
            sourceMatchesHost: match,
            hasHostWindow: host,
            hostWindowIsKey: key
        )
    }
}
