import XCTest
@testable import TextMouth

/// `PhoneAppWording`: each of the Mac's words the phone uses is read from the
/// Mac's own view, where it sits inline, so the two apps cannot drift apart.
final class PhoneAppWordingTests: XCTestCase {
    /// The app-wide alert's words are ContentView's.
    func testTheAlertSaysWhatTheMacsSays() throws {
        let macView = try Self.source("Views/ContentView.swift")

        // The Mac's alert shows the shared words, so one definition serves both apps (FR34).
        XCTAssertTrue(macView.contains("libraryViewModel.errorTitle ?? LibraryWindowWording.errorTitle"))
        XCTAssertTrue(macView.contains("Button(LibraryWindowWording.errorDismiss, role: .cancel)"))
        XCTAssertTrue(macView.contains("libraryViewModel.errorMessage ?? LibraryWindowWording.unknownError"))
        XCTAssertEqual(PhoneAppWording.errorTitle, LibraryWindowWording.errorTitle)
        XCTAssertEqual(PhoneAppWording.errorDismiss, LibraryWindowWording.errorDismiss)
        XCTAssertEqual(PhoneAppWording.unknownError, LibraryWindowWording.unknownError)
        XCTAssertEqual(LibraryWindowWording.errorTitle, "Error")
        XCTAssertEqual(LibraryWindowWording.errorDismiss, "OK")
        XCTAssertEqual(LibraryWindowWording.unknownError, "An unknown error occurred.")
    }

    /// Every phone sheet and question says one "Cancel", the Mac's word.
    func testCancelIsTheMacsWord() {
        XCTAssertEqual(PhoneAppWording.cancel, "Cancel")
        XCTAssertEqual(PhoneAppWording.cancel, LibraryWindowWording.cancel)
    }

    /// Close and Save are the Mac's words, said once for every phone sheet.
    func testCloseAndSaveAreTheMacsWords() {
        XCTAssertEqual(PhoneAppWording.close, "Close")
        XCTAssertEqual(PhoneAppWording.save, "Save")
        XCTAssertEqual(PhoneAppWording.save, LibraryWindowWording.save)
    }

    /// The Play button's words are PlaybackControlsView's, by its rule: Pause
    /// while the book plays, and Play otherwise.
    func testThePlayButtonSaysWhatTheMacsSays() throws {
        let macView = try Self.source("Views/Reader/PlaybackControlsView.swift")

        XCTAssertEqual(PhoneAppWording.playButton(isPlaying: true), "Pause")
        XCTAssertEqual(PhoneAppWording.playButton(isPlaying: false), "Play")
        XCTAssertEqual(PhoneAppWording.playButton(isPlaying: true), PlaybackControlsWording.pause)
        XCTAssertEqual(PhoneAppWording.playButton(isPlaying: false), PlaybackControlsWording.play)
        XCTAssertTrue(macView.contains("return PlaybackControlsWording.pause"))
        XCTAssertTrue(macView.contains("return PlaybackControlsWording.play"))
    }

    /// The sentence for a book that closed the app while opening is the
    /// engineering review's, with the book's title.
    func testTheSentenceForABookThatClosedTheAppNamesIt() {
        XCTAssertEqual(
            PhoneAppWording.closedWhileOpening("Dune"),
            "TextMouth closed while opening Dune, so it wasn't reopened."
        )
    }

    /// The text of the source file at `path` in the app's source folder.
    private static func source(_ path: String) throws -> String {
        try String(contentsOf: AppSourceFile.folder.appendingPathComponent(path), encoding: .utf8)
    }
}
