import XCTest
@testable import TextMouth

/// `PhoneReaderVocabulary`: each of the Mac's reader words that the phone
/// holds is read from the Mac's own source, where it sits inline, so the two
/// apps can't drift apart unnoticed (the spec, under "One vocabulary").
final class PhoneReaderVocabularyTests: XCTestCase {
    /// The playback bar's words are PlaybackControlsView's.
    func testThePlaybackBarsWordsAreTheMacs() throws {
        let macView = try Self.source("Views/Reader/PlaybackControlsView.swift")

        XCTAssertEqual(PhoneReaderVocabulary.skipBackward(by: .sentence), "Skip backward: Sentence")
        XCTAssertEqual(PhoneReaderVocabulary.skipBackward(by: .sentence), PlaybackControlsWording.skipBackward(unit: "Sentence"))
        XCTAssertTrue(macView.contains(".accessibilityLabel(PlaybackControlsWording.skipBackward(unit: viewModel.playbackSkipBackwardUnit.title))"))
        XCTAssertEqual(PhoneReaderVocabulary.skipForward(by: .page), "Skip forward: Page")
        XCTAssertEqual(PhoneReaderVocabulary.skipForward(by: .page), PlaybackControlsWording.skipForward(unit: "Page"))
        XCTAssertTrue(macView.contains(".accessibilityLabel(PlaybackControlsWording.skipForward(unit: viewModel.playbackSkipForwardUnit.title))"))
        XCTAssertEqual(PhoneReaderVocabulary.navigationUnit, PlaybackControlsWording.unitLabel)
        XCTAssertTrue(macView.contains(".accessibilityLabel(PlaybackControlsWording.unitLabel)"))
        XCTAssertEqual(PhoneReaderVocabulary.removeBookmark, PlaybackControlsWording.removeBookmark)
        XCTAssertEqual(PhoneReaderVocabulary.addBookmark, PlaybackControlsWording.addBookmark)
        XCTAssertTrue(macView.contains(
            "viewModel.hasNearbyBookmark ? PlaybackControlsWording.removeBookmark : PlaybackControlsWording.addBookmark"
        ))
        XCTAssertEqual(PhoneReaderVocabulary.wordsPerMinute(200), "200 words per minute")
        XCTAssertEqual(PhoneReaderVocabulary.wordsPerMinute(200), PlaybackControlsWording.wordsPerMinute(200))
        XCTAssertTrue(macView.contains("PlaybackControlsWording.wordsPerMinute(Int(viewModel.currentWPM))"))
    }

    /// The toolbar's and the loading screen's words are ReaderView's.
    func testTheReadersToolbarAndLoadingWordsAreTheMacs() throws {
        let macView = try Self.source("Views/Reader/ReaderView.swift")

        XCTAssertEqual(PhoneReaderVocabulary.returnToPreviousPosition, ReaderViewWording.returnSpoken)
        XCTAssertTrue(macView.contains("spokenLabel: ReaderViewWording.returnSpoken"))
        XCTAssertEqual(PhoneReaderVocabulary.headings, ReaderViewWording.headingsTitle)
        XCTAssertTrue(macView.contains("toolbarButton(ReaderViewWording.headingsTitle"))
        XCTAssertEqual(PhoneReaderVocabulary.bookmarks, ReaderViewWording.bookmarksTitle)
        XCTAssertTrue(macView.contains("toolbarButton(ReaderViewWording.bookmarksTitle"))
        XCTAssertEqual(PhoneReaderVocabulary.sleepTimer, ReaderViewWording.sleepTimerTitle)
        XCTAssertTrue(macView.contains("toolbarButton(ReaderViewWording.sleepTimerTitle"))
        XCTAssertEqual(PhoneLibraryVocabulary.bookInfo, ReaderViewWording.bookInfoTitle)
        XCTAssertTrue(macView.contains("ReaderViewWording.bookInfoTitle,"))
        XCTAssertEqual(PhoneReaderVocabulary.loadingBook, ReaderViewWording.loadingBook)
        XCTAssertTrue(macView.contains("ProgressView(ReaderViewWording.loadingBook)"))
        XCTAssertEqual(PhoneReaderVocabulary.loading("Emma"), "Loading Emma")
        XCTAssertEqual(PhoneReaderVocabulary.loading("Emma"), ReaderViewWording.loading(title: "Emma"))
        XCTAssertTrue(macView.contains(".accessibilityLabel(ReaderViewWording.loading(title: viewModel.book.title))"))
    }

    /// Where Am I?'s parts are the shared summaries' own phrases.
    func testWhereAmIsPartsAreTheSummariesPhrases() throws {
        let shared = try Self.source("ViewModels/ReaderViewModel+WhereAmI.swift")

        XCTAssertEqual(PhoneReaderVocabulary.percent(29.6), "30 percent")
        XCTAssertTrue(shared.contains("String(format: \"%.0f percent\", percentComplete)"))
        XCTAssertEqual(PhoneReaderVocabulary.remaining(10_800, speed: nil), "3 hours remaining")
        XCTAssertTrue(shared.contains(
            "ReaderTimeWording.remainingSpoken(TimeFormatting.spoken(timeRemaining), speed: speed)"
        ))
        XCTAssertEqual(PhoneReaderVocabulary.remainingInHeading(720), "12 minutes remaining in this heading")
        XCTAssertTrue(shared.contains(
            "InterfaceText.line(\"common.valueRemainingInThisHeading\", \"\\(TimeFormatting.spoken(timeRemainingInHeading)) remaining in this heading\""
        ))
    }

    /// The percent rounds half to even as the Mac's "%.0f" does, and is a count
    /// for the region (FR34).
    func testThePercentRoundsAsTheMacsFormatDoes() {
        XCTAssertEqual(PhoneReaderVocabulary.percent(0.5), String(format: "%.0f percent", 0.5))
        XCTAssertEqual(PhoneReaderVocabulary.percent(2.5), String(format: "%.0f percent", 2.5))
        XCTAssertEqual(PhoneReaderVocabulary.percent(100), "100 percent")
        XCTAssertEqual(PhoneReaderVocabulary.percent(0), "0 percent")
    }

    /// The text of the source file at `path` in the app's source folder.
    private static func source(_ path: String) throws -> String {
        try String(contentsOf: AppSourceFile.folder.appendingPathComponent(path), encoding: .utf8)
    }
}
