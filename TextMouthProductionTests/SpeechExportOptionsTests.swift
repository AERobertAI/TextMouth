import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The spoken audio options of the Export dialog (FMT43): every word they
/// show or speak, the state behind them, and the view that draws them.
@MainActor
final class SpeechExportOptionsTests: XCTestCase {
    // MARK: - A Book and a Voice

    /// A voice that is not a Personal Voice, which the book is read with.
    private let moira = SpeechExportVoiceInfo(
        identifier: "com.apple.voice.compact.en-IE.Moira",
        name: "Moira",
        isPersonalVoice: false
    )

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
}
