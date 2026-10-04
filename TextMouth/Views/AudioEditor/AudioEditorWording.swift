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

    // MARK: - Listening and Moving

    /// The status line's first part while the audio plays.
    static let playing = "Playing"

    /// Said as playing pauses: where.
    static func paused(at time: TimeInterval) -> String {
        "Paused at \(spoken(time))."
    }

    /// Said as Play starts again from the start, the cursor having been at
    /// the end.
    static let playingFromStart = "Playing from the start."

    /// Said as Stop goes back to where playing began.
    static func stopped(backAt time: TimeInterval) -> String {
        "Stopped. Back at \(spoken(time))."
    }

    /// Said when Stop is pressed with nothing playing.
    static let notPlaying = "Nothing is playing."

    /// Said when Play is pressed before the edited audio is ready, or after
    /// it couldn't be made ready.
    static let notReadyToPlay = "The audio isn't ready to play yet."

    /// Said as playing reaches the end of the audio.
    static let endOfAudio = "End of the audio."

    /// Said as Go to End lands there: how long the audio is.
    static func endOfAudio(_ duration: TimeInterval) -> String {
        "End of the audio, at \(spoken(duration))."
    }

    /// Said as Go to Start lands there.
    static let startOfAudio = "Start of the audio."

    /// Said when a step back can go no further.
    static let atStart = "Already at the start."

    /// Said when a step forward can go no further.
    static let atEnd = "Already at the end."

    /// Why a time typed can't be gone to.
    static func afterTheEnd(_ duration: TimeInterval) -> String {
        "That's after the end of the audio, at \(spoken(duration))."
    }

    /// Said by the chapter commands for audio without chapter markers.
    static let noChapters = "This audio has no chapter markers."

    /// Said when no chapter marker follows the cursor.
    static let noChapterAfter = "No chapter marker after the cursor."

    /// Said when no chapter marker comes before the cursor.
    static let noChapterBefore = "No chapter marker before the cursor."

    /// Said as the cursor lands on a chapter marker: "Chapter 3: Tide
    /// Tables, at 12 minutes, 4 seconds."
    static func chapter(number: Int, title: String, at time: TimeInterval) -> String {
        "Chapter \(number): \(title), at \(spoken(time))."
    }

    /// Said as the cursor lands where the sound after a pause begins.
    static func afterPause(_ pause: AudioEditorPause) -> String {
        "After a pause of \(spoken(pause.duration)), at \(spoken(pause.end))."
    }

    /// Said when no pause follows the cursor.
    static let noPauseAfter = "No pause after the cursor."

    /// Said when no pause comes before the cursor.
    static let noPauseBefore = "No pause before the cursor."

    /// Said while the pauses are still being found.
    static let findingPauses = "Still finding the pauses. Try again in a moment."

    /// Said when the pauses couldn't be found.
    static func pausesFailed(_ reason: String) -> String {
        "The pauses couldn't be found. \(reason)"
    }

    // MARK: - Go to Time

    /// Go to Time's sheet title.
    static let goToTimeTitle = "Go to Time"

    /// The label of a field taking a time.
    static let timeFieldLabel = "Time"

    /// The button that goes to the time typed.
    static let goButton = "Go"

    /// How a field's problem is read: "Problem: Seconds must be less than
    /// 60."
    static func problemLabel(_ problem: String) -> String {
        "Problem: \(problem)"
    }

    // MARK: - The Commands

    /// The names of the editor's groups of buttons, as headings.
    static let listenHeading = "Listen and Move"

    /// What `action`'s button does, as its hint says, before its shortcut;
    /// empty for an action that isn't the editor's.
    static func explanation(of action: ShortcutAction) -> String {
        switch action {
        case .editorPlayPause: return "Plays from the cursor, or pauses where the audio is."
        case .editorStop: return "Stops playing, and goes back to where playing began."
        case .editorSkipBack: return "Moves the cursor back one second."
        case .editorSkipForward: return "Moves the cursor forward one second."
        case .editorSkipBackLong: return "Moves the cursor back ten seconds."
        case .editorSkipForwardLong: return "Moves the cursor forward ten seconds."
        case .editorSkipBackShort: return "Moves the cursor back a tenth of a second."
        case .editorSkipForwardShort: return "Moves the cursor forward a tenth of a second."
        case .editorGoToStart: return "Moves the cursor to the start of the audio."
        case .editorGoToEnd: return "Moves the cursor to the end of the audio."
        case .editorGoToTime: return "Moves the cursor to a time you type."
        case .editorPreviousChapter: return "Moves the cursor to the previous chapter marker."
        case .editorNextChapter: return "Moves the cursor to the next chapter marker."
        case .editorPreviousPause: return "Moves the cursor to where the sound after the previous pause begins."
        case .editorNextPause: return "Moves the cursor to where the sound after the next pause begins."
        case .editorWhereAmI: return "Says where the cursor is, in which chapter, and what is selected."
        default: return ""
        }
    }

    /// A button's hint: what it does, then its shortcuts in force.
    static func hint(for action: ShortcutAction, bindings: [KeyBinding]) -> String {
        "\(explanation(of: action)) \(shortcutSentence(bindings))"
    }

    /// The shortcuts of a command in words: "Shortcut: J.", "Shortcuts: J
    /// or Comma.", "No shortcut."
    static func shortcutSentence(_ bindings: [KeyBinding]) -> String {
        guard !bindings.isEmpty else { return "No shortcut." }
        let names = bindings.map(spokenShortcut)
        let joined = names.count < 3
            ? names.joined(separator: " or ")
            : names.dropLast().joined(separator: ", ") + ", or " + (names.last ?? "")
        return "\(bindings.count == 1 ? "Shortcut" : "Shortcuts"): \(joined)."
    }

    /// One shortcut as it is said: its modifiers in the order Settings shows
    /// them, then its key, joined by hyphens: "Shift-J", "Option-Comma",
    /// "Command-Up Arrow", "Space".
    static func spokenShortcut(_ binding: KeyBinding) -> String {
        var parts: [String] = []
        if binding.control { parts.append("Control") }
        if binding.option { parts.append("Option") }
        if binding.shift { parts.append("Shift") }
        if binding.command { parts.append("Command") }
        parts.append(keyName(binding.key))
        return parts.joined(separator: "-")
    }

    /// A key's name in words: a special key's or a punctuation mark's name,
    /// or a letter in capitals.
    static func keyName(_ key: String) -> String {
        switch key {
        case "space": return "Space"
        case "delete": return "Delete"
        case "escape": return "Escape"
        case "return": return "Return"
        case "tab": return "Tab"
        case "upArrow": return "Up Arrow"
        case "downArrow": return "Down Arrow"
        case "leftArrow": return "Left Arrow"
        case "rightArrow": return "Right Arrow"
        case ",": return "Comma"
        case ".": return "Period"
        case "<": return "Less Than"
        case ">": return "Greater Than"
        case "/": return "Slash"
        case "\\": return "Backslash"
        case ";": return "Semicolon"
        case "'": return "Apostrophe"
        case "`": return "Grave Accent"
        case "[": return "Left Bracket"
        case "]": return "Right Bracket"
        case "-": return "Minus"
        case "=": return "Equals"
        case "+": return "Plus"
        default: return key.uppercased()
        }
    }
}
