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
        XCTAssertTrue(macView.contains(".accessibilityLabel(\"Skip backward: \\(viewModel.playbackSkipBackwardUnit.rawValue)\")"))
        XCTAssertEqual(PhoneReaderVocabulary.skipForward(by: .page), "Skip forward: Page")
        XCTAssertTrue(macView.contains(".accessibilityLabel(\"Skip forward: \\(viewModel.playbackSkipForwardUnit.rawValue)\")"))
        XCTAssertTrue(macView.contains(".accessibilityLabel(\"\(PhoneReaderVocabulary.navigationUnit)\")"))
        XCTAssertTrue(macView.contains(
            "viewModel.hasNearbyBookmark ? \"\(PhoneReaderVocabulary.removeBookmark)\" : \"\(PhoneReaderVocabulary.addBookmark)\""
        ))
        XCTAssertEqual(PhoneReaderVocabulary.wordsPerMinute(200), "200 words per minute")
        XCTAssertTrue(macView.contains("\"\\(Int(viewModel.currentWPM)) words per minute\""))
    }

    /// The toolbar's and the loading screen's words are ReaderView's.
    func testTheReadersToolbarAndLoadingWordsAreTheMacs() throws {
        let macView = try Self.source("Views/Reader/ReaderView.swift")

        XCTAssertTrue(macView.contains("spokenLabel: \"\(PhoneReaderVocabulary.returnToPreviousPosition)\""))
        XCTAssertTrue(macView.contains("toolbarButton(\"\(PhoneReaderVocabulary.headings)\""))
        XCTAssertTrue(macView.contains("toolbarButton(\"\(PhoneReaderVocabulary.bookmarks)\""))
        XCTAssertTrue(macView.contains("toolbarButton(\"\(PhoneReaderVocabulary.sleepTimer)\""))
        XCTAssertTrue(macView.contains("\"\(PhoneReaderVocabulary.bookInfo)\","))
        XCTAssertTrue(macView.contains("ProgressView(\"\(PhoneReaderVocabulary.loadingBook)\")"))
        XCTAssertEqual(PhoneReaderVocabulary.loading("Emma"), "Loading Emma")
        XCTAssertTrue(macView.contains(".accessibilityLabel(\"Loading \\(viewModel.book.title)\")"))
    }

    /// Where Am I?'s parts are the shared summaries' own phrases.
    func testWhereAmIsPartsAreTheSummariesPhrases() throws {
        let shared = try Self.source("ViewModels/ReaderViewModel+WhereAmI.swift")

        XCTAssertEqual(PhoneReaderVocabulary.percent(29.6), "30 percent")
        XCTAssertTrue(shared.contains("String(format: \"%.0f percent\", percentComplete)"))
        XCTAssertEqual(PhoneReaderVocabulary.remaining(10_800, speed: nil), "3 hours remaining")
        XCTAssertTrue(shared.contains(
            "\"\\(TimeFormatting.spoken(timeRemaining)) remaining\\(ReaderTimeWording.spokenSpeed(speed))\""
        ))
        XCTAssertEqual(PhoneReaderVocabulary.remainingInHeading(720), "12 minutes remaining in this heading")
        XCTAssertTrue(shared.contains(
            "\"\\(TimeFormatting.spoken(timeRemainingInHeading)) remaining in this heading\""
        ))
    }

    /// The text of the source file at `path` in the app's source folder.
    private static func source(_ path: String) throws -> String {
        try String(contentsOf: AppSourceFile.folder.appendingPathComponent(path), encoding: .utf8)
    }
}
