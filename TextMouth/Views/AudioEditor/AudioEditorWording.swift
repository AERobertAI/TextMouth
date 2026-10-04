import Foundation

/// The words of the audio editor window (FR04), shared by its controls,
/// VoiceOver's announcements, the braille display, and the tests, so each
/// says the same thing the same way. Lengths and times are spoken through
/// `AudioEditWording.duration`, which keeps the tenths an edit needs; the
/// screen shows them as clock times (`clock(_:)`), which a braille display
/// reads in few cells.
enum AudioEditorWording {
    // MARK: - Opening the Editor

    /// The command that opens the editor: the library row's context menu
    /// item and VoiceOver action, and the reader's Book menu item.
    static let editAudioCommand = "Edit Audio…"

    /// The window's title: the book, and the track of a book of several.
    static func windowTitle(book: String, track: String?) -> String {
        guard let track else { return "Edit Audio: \(book)" }
        return "Edit Audio: \(book), \(track)"
    }

    /// Said when Edit Audio… is chosen for something that is not an
    /// audiobook kept in a package of its own.
    static let notAnAudiobook = "Only an audiobook's audio can be edited."

    /// Said when the book's editor is open already: it comes forward.
    static func alreadyOpen(book: String) -> String {
        "The audio editor for \(book) is already open."
    }

    /// Said as the book's reader is closed before the editor opens.
    static func closingReader(book: String) -> String {
        "Closing the reader of \(book), since editing changes its audio."
    }

    /// Said when the book's reader did not close.
    static func readerStillOpen(book: String) -> String {
        "\(book) is still open in a reader. Close the reader, then choose Edit Audio again."
    }

    /// The question asked for a book of several tracks.
    static func chooseTrackQuestion(book: String) -> String {
        "Which track of \(book) do you want to edit?"
    }

    /// What the track question explains.
    static let chooseTrackExplanation = "The editor works on one track at a time. Tracks are listed by their chapter names."

    /// The track pop-up's label.
    static let trackLabel = "Track"

    /// The button that opens the editor on the track chosen.
    static let editButton = "Edit"

    /// Every dialog's Cancel button.
    static let cancelButton = "Cancel"

    /// Said for a book whose sections are stretches of its tracks, as a
    /// DAISY-style manifest makes them: editing a track would move them.
    static func sectionsNotEditable(book: String) -> String {
        "\(book) plays sections that are stretches of its tracks, so its tracks can't be edited yet."
    }

    /// Said for a book of several tracks with none found.
    static func noTracks(book: String) -> String {
        "No audio files were found in \(book)."
    }

    /// The question asked when the book's edit history can't be read.
    static func historyUnusableQuestion(book: String) -> String {
        "The edit history of \(book) couldn't be read."
    }

    /// What starting over does.
    static let historyUnusableExplanation = "A copy of it was kept in the book's package. Start over with no edits, "
        + "or cancel and leave the book as it is."

    /// The button that starts over with an empty history.
    static let startOverButton = "Start Over"

    /// The title of the alert saying the editor couldn't open.
    static let openFailedTitle = "The audio can't be edited"

    /// Why the editor couldn't open: the engine's own sentence after the
    /// book's name.
    static func openFailed(book: String, reason: String) -> String {
        "The audio of \(book) couldn't be opened for editing. \(reason)"
    }

    /// The OK button of a notice.
    static let okButton = "OK"

    // MARK: - Time

    /// `seconds` as a clock time, to the tenth of a second when there is
    /// one: "12:04.3", "1:02:03", "0:00". The screen and the braille display
    /// show times this way; VoiceOver speaks them in words.
    static func clock(_ seconds: TimeInterval) -> String {
        // A time beyond a million hours is no time in any audio, and would
        // overflow the whole numbers below.
        guard seconds.isFinite, seconds >= 0, seconds < 3.6e9 else { return "--:--" }
        let allTenths = Int((seconds * 10).rounded())
        let tenths = allTenths % 10
        let whole = allTenths / 10
        let hours = whole / 3_600
        let minutes = (whole % 3_600) / 60
        let rest = whole % 60
        var text = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
        if tenths != 0 {
            text += ".\(tenths)"
        }
        return text
    }

    /// `seconds` in words, to the tenth: "12 minutes, 4.3 seconds".
    static func spoken(_ seconds: TimeInterval) -> String {
        AudioEditWording.duration(seconds)
    }

    /// The time display's label.
    static let positionLabel = "Position"

    /// The time display as it shows: "12:04.3 of 48:00".
    static func positionText(_ cursor: TimeInterval, of duration: TimeInterval) -> String {
        "\(clock(cursor)) of \(clock(duration))"
    }

    /// The time display as VoiceOver speaks it: "12 minutes, 4.3 seconds of
    /// 48 minutes".
    static func positionValue(_ cursor: TimeInterval, of duration: TimeInterval) -> String {
        "\(spoken(cursor)) of \(spoken(duration))"
    }

    /// The label of the line repeating the last announcement, so a braille
    /// display can read it again.
    static let messageLabel = "Last message"

    /// The status line's label.
    static let statusLabel = "Status"

    /// The chapter the cursor is in, as the status line says it: "in
    /// chapter 3: Tide Tables".
    static func inChapter(number: Int, title: String) -> String {
        "in chapter \(number): \(title)"
    }

    /// The status line made of its parts, in order: "12 minutes, 4.3
    /// seconds of 48 minutes; in chapter 3: Tide Tables". Semicolons keep
    /// the parts apart from the commas inside a spoken time.
    static func status(_ parts: [String]) -> String {
        parts.joined(separator: "; ")
    }
}
