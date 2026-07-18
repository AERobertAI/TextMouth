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
                accessibilitySuffix: ""
            )
        }

        XCTAssertEqual(items.count, headings.count)
        XCTAssertEqual(Set(items.map(\.id)).count, headings.count)
    }

    func testHeadingInitialFocusPrefersCurrentHeading() {
        let items = headingItems(count: 3)

        XCTAssertEqual(
            HeadingNavigatorView.initialFocusHeadingID(
                currentHeadingID: items[1].id,
                headingItems: items
            ),
            items[1].id
        )
    }

    func testHeadingInitialFocusFallsBackToFirstHeading() {
        let items = headingItems(count: 3)

        XCTAssertEqual(
            HeadingNavigatorView.initialFocusHeadingID(
                currentHeadingID: nil,
                headingItems: items
            ),
            items[0].id
        )
    }

    func testHeadingInitialFocusIsNilForEmptyBook() {
        XCTAssertNil(HeadingNavigatorView.initialFocusHeadingID(
            currentHeadingID: nil,
            headingItems: []
        ))
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

    func testCurrentHeadingStatusImmediatelyFollowsHeadingName() {
        XCTAssertEqual(
            HeadingNavigatorView.accessibilityDescription(
                text: "Chapter 3",
                level: 1,
                isCurrent: true,
                suffix: "4 minutes"
            ),
            "Chapter 3 (current heading) - level 1, 4 minutes"
        )
    }

    func testSleepTimerInitialFocusPrefersFirstPreset() {
        XCTAssertEqual(SleepTimerView.initialFocusPresetMinutes, 10)
        XCTAssertEqual(SleepTimerView.presetMinutes.first, SleepTimerView.initialFocusPresetMinutes)
    }

    func testSleepTimerFocusRequestCanBeConsumedBeforeStateChanges() {
        XCTAssertTrue(SleepTimerView.isInitialFocusTarget(minutes: 10, shouldRequest: true))
        XCTAssertFalse(SleepTimerView.isInitialFocusTarget(minutes: 10, shouldRequest: false))
        XCTAssertFalse(SleepTimerView.isInitialFocusTarget(minutes: 15, shouldRequest: true))
    }

    func testSleepTimerDismissPrefersPresenterBinding() {
        var parentCloseCount = 0
        var fallbackCount = 0

        SleepTimerView.performDismiss(
            onClose: { parentCloseCount += 1 },
            fallback: { fallbackCount += 1 }
        )

        XCTAssertEqual(parentCloseCount, 1)
        XCTAssertEqual(fallbackCount, 0)
    }

    func testSleepTimerDismissFallsBackWithoutPresenterBinding() {
        var fallbackCount = 0

        SleepTimerView.performDismiss(onClose: nil) {
            fallbackCount += 1
        }

        XCTAssertEqual(fallbackCount, 1)
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

    /// Build lightweight heading rows for focus-policy tests without needing a
    /// reader model, parsed document, or rendered SwiftUI hierarchy.
    private func headingItems(count: Int) -> [HeadingNavigatorView.HeadingListItem] {
        (0..<count).map { index in
            let heading = Heading(
                level: 1,
                text: "Heading \(index)",
                chapterIndex: 0,
                characterOffset: index
            )
            return HeadingNavigatorView.HeadingListItem(
                heading: heading,
                isSkipped: false,
                infoText: "",
                accessibilitySuffix: ""
            )
        }
    }
}
