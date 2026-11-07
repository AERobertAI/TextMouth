import XCTest
@testable import TextMouth

/// `PhoneAppWording`: each of the Mac's words the phone uses is read from the
/// Mac's own view, where it sits inline, so the two apps cannot drift apart.
final class PhoneAppWordingTests: XCTestCase {
    /// The app-wide alert's words are ContentView's.
    func testTheAlertSaysWhatTheMacsSays() throws {
        let macView = try Self.source("Views/ContentView.swift")

        XCTAssertTrue(macView.contains("libraryViewModel.errorTitle ?? \"\(PhoneAppWording.errorTitle)\""))
        XCTAssertTrue(macView.contains("Button(\"\(PhoneAppWording.errorDismiss)\", role: .cancel)"))
        XCTAssertTrue(macView.contains("libraryViewModel.errorMessage ?? \"\(PhoneAppWording.unknownError)\""))
    }

    /// The Play button's words are PlaybackControlsView's, by its rule: Pause
    /// while the book plays, and Play otherwise.
    func testThePlayButtonSaysWhatTheMacsSays() throws {
        let macView = try Self.source("Views/Reader/PlaybackControlsView.swift")

        XCTAssertEqual(PhoneAppWording.playButton(isPlaying: true), "Pause")
        XCTAssertEqual(PhoneAppWording.playButton(isPlaying: false), "Play")
        XCTAssertTrue(macView.contains("return \"\(PhoneAppWording.playButton(isPlaying: true))\""))
        XCTAssertTrue(macView.contains("return \"\(PhoneAppWording.playButton(isPlaying: false))\""))
    }

    /// The text of the source file at `path` in the app's source folder.
    private static func source(_ path: String) throws -> String {
        try String(contentsOf: AppSourceFile.folder.appendingPathComponent(path), encoding: .utf8)
    }
}
