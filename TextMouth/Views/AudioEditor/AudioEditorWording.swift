import Foundation

/// The words of the audio editor window (FR04), shared by its controls,
/// VoiceOver's announcements, the braille display, and the tests, so each
/// says the same thing the same way. Lengths and times are spoken through
/// `AudioEditWording.duration`, which keeps the tenths an edit needs; the
/// screen shows them as clock times (`clock(_:)`), which a braille display
/// reads in few cells.
///
/// Every sentence is localized whole (FR34): numbers that name a thing (a
/// marker's or a chapter's number) are written without digit grouping, and
/// counts are plural strings.
enum AudioEditorWording {
    // MARK: - Opening the Editor

    /// The command that opens the editor: the library row's context menu
    /// item and VoiceOver action, and the reader's Book menu item.
    static var editAudioCommand: String {
        String(localized: "Edit Audio…",
               comment: "Command that opens the audio editor on a book: the library row's context menu item and VoiceOver action, and the reader's Book menu item.")
    }

    /// The window's title: the book, and the track of a book of several.
    static func windowTitle(book: String, track: String?) -> String {
        guard let track else {
            return String(localized: "Edit Audio: \(book)",
                          comment: "Title of the audio editor's window. %@ is the book's title.")
        }
        return String(localized: "Edit Audio: \(book), \(track)",
                      comment: "Title of the audio editor's window for a book of several tracks. %1$@ is the book's title and %2$@ the track's name.")
    }

    /// Said when Edit Audio… is chosen for something that is not an
    /// audiobook kept in a package of its own.
    static var notAnAudiobook: String {
        String(localized: "Only an audiobook's audio can be edited.",
               comment: "Said when Edit Audio… is chosen for something that is not an audiobook kept in a package of its own.")
    }

    /// Said when Edit Audio… reaches an episode in its feed's folder, which
    /// is not editable (FR11): it is never offered for one.
    static var feedEpisodeNotEditable: String {
        String(localized: "An episode in its feed can't be edited.",
               comment: "Said when Edit Audio… reaches a podcast episode that lives in its feed's folder, which can't be edited.")
    }

    /// Said when the book's editor is open already: it comes forward.
    static func alreadyOpen(book: String) -> String {
        String(localized: "The audio editor for \(book) is already open.",
               comment: "Said when Edit Audio… is chosen for a book whose editor is already open; that window comes forward. %@ is the book's title.")
    }

    /// Said as the book's reader is closed before the editor opens.
    static func closingReader(book: String) -> String {
        String(localized: "Closing the reader of \(book), since editing changes its audio.",
               comment: "Said as a book's reader window is closed before the audio editor opens on the book. %@ is the book's title.")
    }

    /// Said when the book's reader did not close.
    static func readerStillOpen(book: String) -> String {
        String(localized: "\(book) is still open in a reader. Close the reader, then choose Edit Audio again.",
               comment: "Said when a book's reader did not close, so the audio editor can't open. %@ is the book's title. \"Edit Audio\" is the name of the command.")
    }

    /// The question asked for a book of several tracks.
    static func chooseTrackQuestion(book: String) -> String {
        String(localized: "Which track of \(book) do you want to edit?",
               comment: "Question asked before editing a book of several audio tracks. %@ is the book's title.")
    }

    /// What the track question explains.
    static var chooseTrackExplanation: String {
        String(localized: "The editor works on one track at a time. Tracks are listed by their chapter names.",
               comment: "Explains the question about which track of a book to edit.")
    }

    /// The track pop-up's label.
    static var trackLabel: String {
        String(localized: "Track", comment: "Label of the pop-up that chooses which audio track of a book to edit.")
    }

    /// The button that opens the editor on the track chosen.
    static var editButton: String {
        String(localized: "Edit", comment: "Button of the track question that opens the audio editor on the track chosen, and the heading of the audio editor's editing buttons.")
    }

    /// Every dialog's Cancel button.
    static var cancelButton: String {
        String(localized: "Cancel", comment: "Button that closes a sheet or dialog without making its change.")
    }

    /// Said for a book whose sections are stretches of its tracks, as a
    /// DAISY-style manifest makes them: editing a track would move them.
    static func sectionsNotEditable(book: String) -> String {
        String(localized: "\(book) plays sections that are stretches of its tracks, so its tracks can't be edited yet.",
               comment: "Said when Edit Audio… is chosen for a book whose sections are stretches of its audio tracks. %@ is the book's title.")
    }

    /// Said for a book of several tracks with none found.
    static func noTracks(book: String) -> String {
        String(localized: "No audio files were found in \(book).",
               comment: "Said when a book of several audio tracks has no audio file to edit. %@ is the book's title.")
    }

    /// The question asked when the book's edit history can't be read.
    static func historyUnusableQuestion(book: String) -> String {
        String(localized: "The edit history of \(book) couldn't be read.",
               comment: "Question asked when a book's saved audio edit history can't be read. %@ is the book's title.")
    }

    /// What starting over does.
    static var historyUnusableExplanation: String {
        String(localized: "A copy of it was kept in the book's package. Start over with no edits, or cancel and leave the book as it is.",
               comment: "Explains the question about an unreadable audio edit history: what Start Over and Cancel do.")
    }

    /// The button that starts over with an empty history.
    static var startOverButton: String {
        String(localized: "Start Over", comment: "Button that starts the audio editor over with an empty edit history, when the saved history can't be read.")
    }

    /// The title of the alert saying the editor couldn't open.
    static var openFailedTitle: String {
        String(localized: "The audio can't be edited", comment: "Title of the alert saying the audio editor couldn't open.")
    }

    /// Why the editor couldn't open: the engine's own sentence after the
    /// book's name.
    static func openFailed(book: String, reason: String) -> String {
        SentenceWording.joined([
            String(localized: "The audio of \(book) couldn't be opened for editing.",
                   comment: "Said when the audio editor couldn't open a book. %@ is the book's title. A sentence giving the reason follows."),
            reason
        ])
    }

    /// The OK button of a notice.
    static var okButton: String {
        String(localized: "OK", comment: "Button that closes a notice.")
    }

    // MARK: - Time

    /// `seconds` as a clock time, to the tenth of a second when there is
    /// one: "12:04.3", "1:02:03", "0:00". The screen and the braille display
    /// show times this way; VoiceOver speaks them in words.
    static func clock(_ seconds: TimeInterval) -> String {
        // A time beyond a million hours is no time in any audio, and would
        // overflow the whole numbers below.
        guard seconds.isFinite, seconds >= 0, seconds < 3.6e9 else { return "--:--" } // l10n: no (a placeholder of punctuation for a time that is no time)
        let allTenths = Int((seconds * 10).rounded())
        let tenths = allTenths % 10
        let whole = allTenths / 10
        // The whole seconds are written by the system's duration format, in
        // the language's own digits; the tenth follows the region's decimal
        // separator.
        let pattern: Duration.TimeFormatStyle.Pattern = whole >= 3_600 ? .hourMinuteSecond : .minuteSecond
        var text = Duration.seconds(whole).formatted(.time(pattern: pattern))
        if tenths != 0 {
            text += (Locale.current.decimalSeparator ?? ".") + tenths.formatted(.number.grouping(.never)) // l10n: no (a separator fallback)
        }
        return text
    }

    /// `seconds` in words, to the tenth: "12 minutes, 4.3 seconds".
    static func spoken(_ seconds: TimeInterval) -> String {
        AudioEditWording.duration(seconds)
    }

    /// The time display's label.
    static var positionLabel: String {
        String(localized: "Position", comment: "Label of the audio editor's time display: where the cursor is.")
    }

    /// The time display as it shows: "12:04.3 of 48:00".
    static func positionText(_ cursor: TimeInterval, of duration: TimeInterval) -> String {
        String(localized: "\(clock(cursor)) of \(clock(duration))",
               comment: "The audio editor's time display as shown and brailled. %1$@ is the cursor's time and %2$@ the audio's length, both as clock times such as \"12:04.3\".")
    }

    /// The time display as VoiceOver speaks it: "12 minutes, 4.3 seconds of
    /// 48 minutes".
    static func positionValue(_ cursor: TimeInterval, of duration: TimeInterval) -> String {
        String(localized: "\(spoken(cursor)) of \(spoken(duration))",
               comment: "The audio editor's time display as VoiceOver speaks it. %1$@ is the cursor's time and %2$@ the audio's length, both in words such as \"12 minutes, 4.3 seconds\".")
    }

    /// The label of the line repeating the last announcement, so a braille
    /// display can read it again.
    static var messageLabel: String {
        String(localized: "Last message", comment: "Label of the audio editor's line that repeats the last announcement, so a braille display can read it again.")
    }

    /// The status line's label.
    static var statusLabel: String {
        String(localized: "Status", comment: "Label of the audio editor's status line: the cursor's time, chapter, and selection.")
    }

    /// The chapter the cursor is in, as the status line says it: "in
    /// chapter 3: Tide Tables".
    static func inChapter(number: Int, title: String) -> String {
        String(localized: "in chapter \(String(number)): \(title)",
               comment: "A part of the audio editor's status line: the chapter the cursor is in. %1$@ is the chapter's number, an identifier written without digit grouping, and %2$@ its title.")
    }

    /// The status line made of its parts, in order: "12 minutes, 4.3
    /// seconds of 48 minutes; in chapter 3: Tide Tables". Semicolons keep
    /// the parts apart from the commas inside a spoken time.
    static func status(_ parts: [String]) -> String {
        guard let first = parts.first else { return "" }
        return parts.dropFirst().reduce(first) { text, next in
            String(localized: "\(text); \(next)",
                   comment: "Joins two parts of the audio editor's status line. %1$@ is the parts so far and %2$@ the next part. A semicolon keeps parts apart from the commas inside a spoken time.")
        }
    }

    // MARK: - Listening and Moving

    /// The status line's first part while the audio plays.
    static var playing: String {
        String(localized: "Playing", comment: "A part of the audio editor's status line while the audio plays.")
    }

    /// Said as playing pauses: where.
    static func paused(at time: TimeInterval) -> String {
        String(localized: "Paused at \(spoken(time)).",
               comment: "Said as the audio editor's playing pauses. %@ is where, as a time in words such as \"12 minutes, 4 seconds\".")
    }

    /// Said as Play starts again from the start, the cursor having been at
    /// the end.
    static var playingFromStart: String {
        String(localized: "Playing from the start.", comment: "Said as Play starts again from the start of the audio, the cursor having been at the end.")
    }

    /// Said as Stop goes back to where playing began.
    static func stopped(backAt time: TimeInterval) -> String {
        String(localized: "Stopped. Back at \(spoken(time)).",
               comment: "Said as the audio editor's Stop goes back to where playing began. %@ is that time in words.")
    }

    /// Said when Stop is pressed with nothing playing.
    static var notPlaying: String {
        String(localized: "Nothing is playing.", comment: "Said when the audio editor's Stop is pressed with nothing playing.")
    }

    /// Said when Play is pressed before the edited audio is ready, or after
    /// it couldn't be made ready.
    static var notReadyToPlay: String {
        String(localized: "The audio isn't ready to play yet.", comment: "Said when Play is pressed in the audio editor before the edited audio is ready, or after it couldn't be made ready.")
    }

    /// Said as playing reaches the end of the audio.
    static var endOfAudio: String {
        String(localized: "End of the audio.", comment: "Said as the audio editor's playing reaches the end of the audio.")
    }

    /// Said as Go to End lands there: how long the audio is.
    static func endOfAudio(_ duration: TimeInterval) -> String {
        String(localized: "End of the audio, at \(spoken(duration)).",
               comment: "Said as the audio editor's Go to End lands at the end. %@ is the audio's length in words.")
    }

    /// Said as Go to Start lands there.
    static var startOfAudio: String {
        String(localized: "Start of the audio.", comment: "Said as the audio editor's Go to Start lands at the start.")
    }

    /// Said when a step back can go no further.
    static var atStart: String {
        String(localized: "Already at the start.", comment: "Said when a step back in the audio editor can go no further.")
    }

    /// Said when a step forward can go no further.
    static var atEnd: String {
        String(localized: "Already at the end.", comment: "Said when a step forward in the audio editor can go no further.")
    }

    /// Why a time typed can't be gone to.
    static func afterTheEnd(_ duration: TimeInterval) -> String {
        String(localized: "That's after the end of the audio, at \(spoken(duration)).",
               comment: "Said when a time typed into the audio editor's Go to Time lies past the end. %@ is the audio's length in words.")
    }

    /// Said by the chapter commands for audio without chapter markers.
    static var noChapters: String {
        String(localized: "This audio has no chapter markers.", comment: "Said by the audio editor's chapter commands when the audio has no chapter markers.")
    }

    /// Said when no chapter marker follows the cursor.
    static var noChapterAfter: String {
        String(localized: "No chapter marker after the cursor.", comment: "Said when the audio editor's Next Chapter finds no chapter marker after the cursor.")
    }

    /// Said when no chapter marker comes before the cursor.
    static var noChapterBefore: String {
        String(localized: "No chapter marker before the cursor.", comment: "Said when the audio editor's Previous Chapter finds no chapter marker before the cursor.")
    }

    /// Said as the cursor lands on a chapter marker: "Chapter 3: Tide
    /// Tables, at 12 minutes, 4 seconds."
    static func chapter(number: Int, title: String, at time: TimeInterval) -> String {
        String(localized: "Chapter \(String(number)): \(title), at \(spoken(time)).",
               comment: "Said as the audio editor's cursor lands on a chapter marker. %1$@ is the chapter's number, an identifier written without digit grouping, %2$@ its title, and %3$@ its time in words.")
    }

    /// Said as the cursor lands where the sound after a pause begins.
    static func afterPause(_ pause: AudioEditorPause) -> String {
        String(localized: "After a pause of \(spoken(pause.duration)), at \(spoken(pause.end)).",
               comment: "Said as the audio editor's cursor lands where the sound after a pause begins. %1$@ is the pause's length in words and %2$@ the time the sound begins, in words.")
    }

    /// Said when no pause follows the cursor.
    static var noPauseAfter: String {
        String(localized: "No pause after the cursor.", comment: "Said when the audio editor's Next Pause finds no pause after the cursor.")
    }

    /// Said when no pause comes before the cursor.
    static var noPauseBefore: String {
        String(localized: "No pause before the cursor.", comment: "Said when the audio editor's Previous Pause finds no pause before the cursor.")
    }

    /// Said while the pauses are still being found.
    static var findingPauses: String {
        String(localized: "Still finding the pauses. Try again in a moment.", comment: "Said when a pause command is used in the audio editor while the pauses are still being found.")
    }

    /// Said when the pauses couldn't be found.
    static func pausesFailed(_ reason: String) -> String {
        SentenceWording.joined([
            String(localized: "The pauses couldn't be found.", comment: "Said when the audio editor couldn't find the audio's pauses. A sentence giving the reason follows."),
            reason
        ])
    }

    // MARK: - Go to Time

    /// Go to Time's sheet title.
    static var goToTimeTitle: String {
        String(localized: "Go to Time", comment: "Title of the audio editor's Go to Time sheet.")
    }

    /// The label of a field taking a time.
    static var timeFieldLabel: String {
        String(localized: "Time", comment: "Label of a field in the audio editor that takes a time.")
    }

    /// The button that goes to the time typed.
    static var goButton: String {
        String(localized: "Go", comment: "Button of the audio editor's Go to Time sheet that moves the cursor to the time typed.")
    }

    /// How a field's problem is read: "Problem: Seconds must be less than
    /// 60."
    static func problemLabel(_ problem: String) -> String {
        String(localized: "Problem: \(problem)",
               comment: "How VoiceOver reads the problem shown under a field. %@ is the problem's sentence.")
    }

    /// A label and its value as one line: "Chain: highpass=f=80".
    static func labeled(_ label: String, _ value: String) -> String {
        String(localized: "\(label): \(value)",
               comment: "A label, a colon, and its value, as one line of the audio editor's sheets and the filter presets. %1$@ is the label and %2$@ the value.")
    }

    // MARK: - The Selection

    /// The selection as the status line says it, in clock times, which a
    /// braille display shows in few cells: "selection from 11:58 to
    /// 12:04.3, 6.3 seconds".
    static func selectionPart(_ range: AudioTimeRange) -> String {
        String(localized: "selection from \(clock(range.start)) to \(clock(range.end)), \(spoken(range.duration))",
               comment: "A part of the audio editor's status line: the selection. %1$@ is its start and %2$@ its end, as clock times such as \"11:58\", and %3$@ its length in words.")
    }

    /// The selection said in full, in words, as Speak Selection says it.
    static func selectionSentence(_ range: AudioTimeRange) -> String {
        String(localized: "Selection from \(spoken(range.start)) to \(spoken(range.end)); \(spoken(range.duration)) long.",
               comment: "Said by the audio editor's Speak Selection. %1$@ is the selection's start, %2$@ its end, and %3$@ its length, all in words.")
    }

    /// Said as a selection is made: how long it is.
    static func selected(_ range: AudioTimeRange) -> String {
        String(localized: "Selected \(spoken(range.duration)).",
               comment: "Said as a selection is made in the audio editor. %@ is its length in words.")
    }

    /// Said as In is marked, with the selection it makes, if any.
    static func markedIn(at time: TimeInterval, selection: AudioTimeRange?) -> String {
        let marked = String(localized: "In at \(spoken(time)).",
                            comment: "Said as the audio editor's Mark In marks the selection's start. %@ is the time in words. A sentence about the selection it makes may follow.")
        return SentenceWording.joined([marked] + (selection.map { [selected($0)] } ?? []))
    }

    /// Said as Out is marked, with the selection it makes, if any.
    static func markedOut(at time: TimeInterval, selection: AudioTimeRange?) -> String {
        let marked = String(localized: "Out at \(spoken(time)).",
                            comment: "Said as the audio editor's Mark Out marks the selection's end. %@ is the time in words. A sentence about the selection it makes may follow.")
        return SentenceWording.joined([marked] + (selection.map { [selected($0)] } ?? []))
    }

    /// Said as Select Chapter selects a chapter.
    static func selectedChapter(number: Int, title: String, length: TimeInterval) -> String {
        String(localized: "Selected chapter \(String(number)): \(title), \(spoken(length)).",
               comment: "Said as the audio editor's Select Chapter selects a chapter. %1$@ is the chapter's number, an identifier written without digit grouping, %2$@ its title, and %3$@ its length in words.")
    }

    /// Said as Select Chapter selects the audio before the first marker.
    static func selectedBeforeFirstChapter(_ length: TimeInterval) -> String {
        String(localized: "Selected the \(spoken(length)) before chapter 1.",
               comment: "Said as the audio editor's Select Chapter selects the audio before the first chapter marker. %@ is its length in words.")
    }

    /// Said as Select All selects everything.
    static func selectedAll(_ duration: TimeInterval) -> String {
        String(localized: "Selected all \(spoken(duration)).",
               comment: "Said as the audio editor's Select All selects everything. %@ is the audio's length in words.")
    }

    /// Said when a command needs a selection and there is none.
    static var noSelection: String {
        String(localized: "Nothing is selected.", comment: "Said when an audio editor command needs a selection and there is none.")
    }

    /// Said as the selection is cleared.
    static var selectionCleared: String {
        String(localized: "Selection cleared.", comment: "Said as the audio editor's selection is cleared.")
    }

    // MARK: - Markers

    /// A marker as the list and the announcements name it: "Marker 3" or
    /// "Marker 3, Intro".
    static func markerName(_ number: Int, named name: String) -> String {
        guard !name.isEmpty else { return markerSubject(number) }
        return String(localized: "Marker \(String(number)), \(name)",
                      comment: "A named marker as the audio editor's list and announcements name it. %1$@ is the marker's number, an identifier written without digit grouping, and %2$@ the name the user gave it.")
    }

    /// Said as a marker is dropped.
    static func markerAdded(_ number: Int, at time: TimeInterval) -> String {
        String(localized: "Marker \(String(number)) at \(spoken(time)).",
               comment: "Said as a marker is dropped in the audio editor. %1$@ is the marker's number, an identifier written without digit grouping, and %2$@ its time in words.")
    }

    /// Said as the cursor goes to a marker, and its row's label.
    static func marker(_ number: Int, named name: String, at time: TimeInterval) -> String {
        String(localized: "\(markerName(number, named: name)), at \(spoken(time)).",
               comment: "Said as the audio editor's cursor goes to a marker, and its row's label. %1$@ is the marker's name such as \"Marker 3\" or \"Marker 3, Intro\", and %2$@ its time in words.")
    }

    /// Said as a marker is named, or its name taken away.
    static func markerRenamed(_ number: Int, named name: String) -> String {
        name.isEmpty
            ? String(localized: "Marker \(String(number)) has no name now.",
                     comment: "Said as a marker's name is taken away in the audio editor. %@ is the marker's number, an identifier written without digit grouping.")
            : String(localized: "Marker \(String(number)) named \(name).",
                     comment: "Said as a marker is named in the audio editor. %1$@ is the marker's number, an identifier written without digit grouping, and %2$@ the name the user gave it.")
    }

    /// Said as a marker is deleted.
    static func markerDeleted(_ number: Int, named name: String) -> String {
        String(localized: "\(markerName(number, named: name)) deleted.",
               comment: "Said as a marker is deleted in the audio editor. %@ is the marker's name such as \"Marker 3\" or \"Marker 3, Intro\".")
    }

    /// A marker as its row's buttons and name field name it: "Marker 3".
    static func markerSubject(_ number: Int) -> String {
        String(localized: "Marker \(String(number))",
               comment: "A marker as the audio editor's list, its row's buttons, and announcements name it. %@ is the marker's number, an identifier written without digit grouping.")
    }

    /// A pause's row in the list: "Pause 2, 1.3 seconds, at 1 minute, 4.2
    /// seconds".
    static func pauseRow(_ number: Int, _ pause: AudioEditorPause) -> String {
        String(localized: "\(pauseSubject(number)), \(spoken(pause.duration)), at \(spoken(pause.start))",
               comment: "A pause's row in the audio editor's list. %1$@ is the pause such as \"Pause 2\", %2$@ its length in words, and %3$@ its start in words.")
    }

    /// A pause as its row's buttons name it: "Pause 2".
    static func pauseSubject(_ number: Int) -> String {
        String(localized: "Pause \(String(number))",
               comment: "A pause as the audio editor's list and its row's buttons name it. %@ is the pause's number, an identifier written without digit grouping.")
    }

    /// The marker list's title.
    static var markersTitle: String {
        String(localized: "Markers and Pauses", comment: "Title of the audio editor's list of markers, chapter markers, and pauses.")
    }

    /// The heading of the markers in the list.
    static var markersHeading: String {
        String(localized: "Markers", comment: "Heading of the markers in the audio editor's list.")
    }

    /// The heading of the pauses in the list.
    static var pausesHeading: String {
        String(localized: "Pauses", comment: "Heading of the pauses in the audio editor's list.")
    }

    /// Shown when no marker has been dropped.
    static var noMarkers: String {
        String(localized: "No markers yet. Add Marker drops one at the cursor, even while the audio plays.",
               comment: "Shown in the audio editor's list when no marker has been dropped. \"Add Marker\" is the name of the command.")
    }

    /// Shown when the audio has no pauses.
    static var noPauses: String {
        String(localized: "No pauses were found.", comment: "Shown in the audio editor's list when the audio has no pauses.")
    }

    /// The button that goes to a marker or a pause.
    static var goToButton: String {
        String(localized: "Go To", comment: "Button of a marker's or a pause's row in the audio editor's list that moves the cursor there.")
    }

    /// The button that selects a pause.
    static var selectButton: String {
        String(localized: "Select", comment: "Button of a pause's row in the audio editor's list that selects the pause.")
    }

    /// The button that names a marker.
    static var renameButton: String {
        String(localized: "Rename", comment: "Button of a marker's row in the audio editor's list that gives the marker a name.")
    }

    /// The button that deletes a marker.
    static var deleteButton: String {
        String(localized: "Delete", comment: "Button of a marker's row in the audio editor's list that deletes the marker.")
    }

    /// The button that closes a list.
    static var closeButton: String {
        String(localized: "Close", comment: "Button that closes a sheet, such as the audio editor's list of markers.")
    }

    /// The button that keeps a new name.
    static var saveNameButton: String {
        String(localized: "Save Name", comment: "Button that keeps the new name typed for a marker.")
    }

    /// The label of a marker's name field.
    static var nameFieldLabel: String {
        String(localized: "Name", comment: "Label of the name field of a filter preset or an audio marker.")
    }

    /// A button of a row's, named with the row's subject, so VoiceOver
    /// tells one row's Delete from the next: "Delete Marker 3".
    static func rowButton(_ title: String, _ subject: String) -> String {
        String(localized: "\(title) \(subject)",
               comment: "A row button's name with the row's subject, so VoiceOver tells one row's button from the next, such as \"Delete Marker 3\". %1$@ is the button's name and %2$@ the row's subject.")
    }

    // MARK: - Editing

    /// The audio's new length, after an edit: "Now 12 minutes, 27.5 seconds
    /// long."
    static func nowLong(_ duration: TimeInterval) -> String {
        String(localized: "Now \(spoken(duration)) long.",
               comment: "Ends the announcement of an edit in the audio editor: the audio's new length. %@ is the length in words.")
    }

    /// Said when a command would change the audio while another change, a
    /// save, or an export is under way.
    static var stillWorking: String {
        String(localized: "Still working on the last change.", comment: "Said when an audio editor command would change the audio while another change, a save, or an export is under way.")
    }

    /// Said when a command other than the punch-in's own is chosen while it
    /// records.
    static var stillRecording: String {
        String(localized: "Recording. Stop the recording first.", comment: "Said when an audio editor command other than the punch-in's own is chosen while a punch-in records.")
    }

    /// Said as Cut cuts.
    static func cut(_ length: TimeInterval, now duration: TimeInterval) -> String {
        SentenceWording.joined([
            String(localized: "Cut \(spoken(length)).", comment: "Said as the audio editor's Cut cuts. %@ is the length cut, in words."),
            nowLong(duration)
        ])
    }

    /// Said as Copy copies.
    static func copied(_ length: TimeInterval) -> String {
        String(localized: "Copied \(spoken(length)).", comment: "Said as the audio editor's Copy copies the selection. %@ is its length in words.")
    }

    /// Said when the selection is too long to copy.
    static var copyTooLong: String {
        String(localized: "Copy at most 10 minutes at a time.", comment: "Said when the selection is too long for the audio editor's Copy.")
    }

    /// Said by Paste with nothing cut or copied.
    static var nothingToPaste: String {
        String(localized: "Nothing has been cut or copied.", comment: "Said by the audio editor's Paste when nothing has been cut or copied.")
    }

    /// Said by Paste when the audio cut was too long to keep.
    static var cutTooLongToPaste: String {
        String(localized: "The audio cut was too long to keep for pasting. To move a long stretch, paste right after cutting it.",
               comment: "Said by the audio editor's Paste when the audio cut was too long to keep for pasting.")
    }

    /// Said when the disk is too full to keep audio for Paste.
    static var diskTooFullToKeepClip: String {
        String(localized: "The disk is too full to keep this audio for pasting.", comment: "Said when the disk is too full to keep the audio cut or copied in the audio editor for Paste.")
    }

    /// Said as Paste pastes, at the cursor or over a selection `replaced`
    /// seconds long.
    static func pasted(_ length: TimeInterval, replacing replaced: TimeInterval?, now duration: TimeInterval) -> String {
        let pasted = replaced.map {
            String(localized: "Pasted \(spoken(length)) over \(spoken($0)).",
                   comment: "Said as the audio editor's Paste pastes over a selection. %1$@ is the length pasted and %2$@ the length of the selection it replaced, both in words.")
        } ?? String(localized: "Pasted \(spoken(length)).",
                    comment: "Said as the audio editor's Paste pastes at the cursor. %@ is the length pasted, in words.")
        return SentenceWording.joined([pasted, nowLong(duration)])
    }

    /// Said as a Paste right after a Cut, at the cut's own place, puts the
    /// audio back.
    static func pastedBack(_ length: TimeInterval) -> String {
        String(localized: "Pasted \(spoken(length)) back where they were cut.",
               comment: "Said as a Paste right after a Cut, at the cut's own place, puts the audio back. %@ is its length in words.")
    }

    /// Said as a Paste right after a Cut moves the audio.
    static func moved(_ length: TimeInterval, to time: TimeInterval) -> String {
        String(localized: "Moved \(spoken(length)) to \(spoken(time)).",
               comment: "Said as a Paste right after a Cut moves the audio. %1$@ is the length moved and %2$@ the time it moved to, both in words.")
    }

    /// Said by Trim to Selection when the selection is all of the audio.
    static var selectionIsEverything: String {
        String(localized: "The selection is all of the audio, so there's nothing to trim.", comment: "Said by the audio editor's Trim to Selection when the selection is all of the audio.")
    }

    /// Said as Trim to Selection trims.
    static func trimmed(keeping length: TimeInterval) -> String {
        String(localized: "Trimmed to the selection: \(spoken(length)) kept.",
               comment: "Said as the audio editor's Trim to Selection trims. %@ is the length kept, in words.")
    }

    /// The name Undo and Redo give the two trims of a Trim to Selection.
    static var trimToSelectionName: String {
        String(localized: "Trim to Selection", comment: "Name of an edit, as the Undo and Redo menu items say it after \"Undo\" or \"Redo\": the audio editor's Trim to Selection, which trims the start and the end together.")
    }

    /// Said as silence is inserted.
    static func insertedSilence(_ length: TimeInterval, now duration: TimeInterval) -> String {
        SentenceWording.joined([
            String(localized: "Inserted \(spoken(length)) of silence.", comment: "Said as silence is inserted in the audio editor. %@ is its length in words."),
            nowLong(duration)
        ])
    }

    /// Said as a chapter marker is set.
    static func chapterSet(_ title: String, at time: TimeInterval) -> String {
        String(localized: "Chapter marker “\(title)” set at \(spoken(time)).",
               comment: "Said as a chapter marker is set in the audio editor. %1$@ is its title and %2$@ its time in words.")
    }

    /// Said as a chapter marker is renamed.
    static func chapterRenamed(_ title: String) -> String {
        String(localized: "Chapter marker renamed “\(title)”.",
               comment: "Said as a chapter marker is renamed in the audio editor. %@ is its new title.")
    }

    /// Said as a chapter marker is removed.
    static func chapterRemoved(_ title: String) -> String {
        String(localized: "Chapter marker “\(title)” removed.",
               comment: "Said as a chapter marker is removed in the audio editor. %@ is its title.")
    }

    /// Undo's button title: "Undo Cut 2.5 Seconds".
    static func undoTitle(_ name: String) -> String {
        String(localized: "Undo \(name)",
               comment: "Title of the audio editor's Undo button. %@ is the name of the edit it would undo, such as \"Cut 2.5 Seconds\".")
    }

    /// Redo's button title.
    static func redoTitle(_ name: String) -> String {
        String(localized: "Redo \(name)",
               comment: "Title of the audio editor's Redo button. %@ is the name of the edit it would redo, such as \"Cut 2.5 Seconds\".")
    }

    /// Said as Undo undoes.
    static func undid(_ name: String, now duration: TimeInterval) -> String {
        SentenceWording.joined([
            String(localized: "Undid \(name).", comment: "Said as the audio editor's Undo undoes an edit. %@ is the edit's name, such as \"Cut 2.5 Seconds\"."),
            nowLong(duration)
        ])
    }

    /// Said as Redo redoes.
    static func redid(_ name: String, now duration: TimeInterval) -> String {
        SentenceWording.joined([
            String(localized: "Redid \(name).", comment: "Said as the audio editor's Redo redoes an edit. %@ is the edit's name, such as \"Cut 2.5 Seconds\"."),
            nowLong(duration)
        ])
    }

    /// Said by Redo with nothing undone.
    static var nothingToRedo: String {
        String(localized: "There's nothing to redo.", comment: "Said by the audio editor's Redo when nothing has been undone.")
    }

    // MARK: - Insert Silence and Chapter Markers

    /// Insert Silence's sheet title.
    static var insertSilenceTitle: String {
        String(localized: "Insert Silence", comment: "Title of the audio editor's Insert Silence sheet.")
    }

    /// Insert Chapter Marker's sheet title.
    static var insertChapterTitle: String {
        String(localized: "Insert Chapter Marker", comment: "Title of the audio editor's Insert Chapter Marker sheet.")
    }

    /// The label of the silence's length field.
    static var lengthFieldLabel: String {
        String(localized: "Length", comment: "Label of the audio editor's field for the length of a silence, and of the audio's length in Audio Info.")
    }

    /// The label of a chapter marker's title field.
    static var titleFieldLabel: String {
        String(localized: "Title", comment: "Label of the audio editor's field for a chapter marker's title.")
    }

    /// What the silence's length field takes.
    static var silenceExplanation: String {
        String(localized: "How long a silence to insert at the cursor: seconds, such as 2.5, or minutes and seconds, such as 1:30.",
               comment: "Explains the silence length field of the audio editor's Insert Silence sheet. The examples are typed times.")
    }

    /// What the chapter marker's title field takes.
    static var chapterExplanation: String {
        String(localized: "The title of a chapter marker at the cursor. A chapter marker already at the cursor is renamed.",
               comment: "Explains the title field of the audio editor's Insert Chapter Marker sheet.")
    }

    /// The button that inserts.
    static var insertButton: String {
        String(localized: "Insert", comment: "Button of the audio editor's Insert Silence and Insert Chapter Marker sheets that makes the insertion.")
    }

    /// Why a silence of no length can't be inserted.
    static var silenceTooShort: String {
        String(localized: "Silence has to last longer than no time at all.", comment: "Problem shown when the silence to insert in the audio editor has no length.")
    }

    /// Why a silence of more than a day can't be inserted.
    static var silenceTooLong: String {
        String(localized: "Silence can last at most a day.", comment: "Problem shown when the silence to insert in the audio editor is longer than a day.")
    }

    /// Why a blank title can't be a chapter marker's.
    static var chapterNeedsTitle: String {
        String(localized: "A chapter marker needs a title.", comment: "Problem shown when the title of a chapter marker to insert in the audio editor is blank.")
    }

    /// The title Insert Chapter Marker offers: "Chapter 4".
    static func defaultChapterTitle(_ number: Int) -> String {
        chapterSubject(number)
    }

    /// The heading of the chapter markers in the list.
    static var chaptersHeading: String {
        String(localized: "Chapter Markers", comment: "Heading of the chapter markers in the audio editor's list.")
    }

    /// The button that removes a chapter marker.
    static var removeButton: String {
        String(localized: "Remove", comment: "Button of a chapter marker's row in the audio editor's list that removes the chapter marker.")
    }

    /// A chapter marker's row in the list: "Chapter 3: Tide Tables, at 12
    /// minutes, 4 seconds".
    static func chapterRow(_ number: Int, title: String, at time: TimeInterval) -> String {
        String(localized: "Chapter \(String(number)): \(title), at \(spoken(time))",
               comment: "A chapter marker's row in the audio editor's list. %1$@ is the chapter's number, an identifier written without digit grouping, %2$@ its title, and %3$@ its time in words.")
    }

    /// A chapter marker as its row's buttons and title field name it:
    /// "Chapter 3".
    static func chapterSubject(_ number: Int) -> String {
        String(localized: "Chapter \(String(number))",
               comment: "A chapter as the audio editor's list, its row's buttons, and the default title of a new chapter marker name it. %@ is the chapter's number, an identifier written without digit grouping.")
    }

    // MARK: - Punch In

    /// Punch In's title while it records.
    static var stopRecordingTitle: String {
        String(localized: "Stop Recording", comment: "Title of the audio editor's Punch In button while it records.")
    }

    /// The microphone pop-up's label.
    static var microphoneLabel: String {
        String(localized: "Microphone for Punch In", comment: "Label of the pop-up in the audio editor that chooses the microphone Punch In records from.")
    }

    /// The microphone pop-up's hint.
    static var microphoneHint: String {
        String(localized: "The microphone Punch In records from. TextMouth remembers it, as the Record window does, apart from the input macOS uses for everything else.",
               comment: "Hint of the audio editor's microphone pop-up. \"Record window\" is TextMouth's window that records audio.")
    }

    /// Shown in the microphone pop-up with none connected.
    static var noMicrophoneItem: String {
        String(localized: "No microphone", comment: "Shown in the audio editor's microphone pop-up when no microphone is connected.")
    }

    /// Said by Punch In with no microphone connected.
    static var noMicrophone: String {
        String(localized: "No microphone is connected. Connect one to punch in.", comment: "Said by the audio editor's Punch In when no microphone is connected.")
    }

    /// Said before the count-in: what will be recorded, from where, and how
    /// it ends.
    static func punchInStarting(_ punch: AudioEditorPunchIn) -> String {
        guard let range = punch.range else {
            return String(localized: "Recording to insert at \(spoken(punch.place)), from \(punch.microphone), after the beep. Punch In or Stop ends it; Clear Selection discards it.",
                          comment: "Said before the audio editor's Punch In records at the cursor. %1$@ is the cursor's time in words and %2$@ the microphone's name. \"Punch In\", \"Stop\" and \"Clear Selection\" are the names of controls.")
        }
        return String(localized: "Recording over \(spoken(range.duration)) at \(spoken(punch.place)), from \(punch.microphone), after the beep. Punch In or Stop ends it; Clear Selection discards it.",
                      comment: "Said before the audio editor's Punch In records over a selection. %1$@ is the selection's length in words, %2$@ its start in words, and %3$@ the microphone's name. \"Punch In\", \"Stop\" and \"Clear Selection\" are the names of controls.")
    }

    /// The status line's part while a punch-in gets ready.
    static var punchInStartingStatus: String {
        String(localized: "Getting ready to record", comment: "A part of the audio editor's status line while a punch-in gets ready to record.")
    }

    /// The status line's part while a punch-in records: the time recorded
    /// and the level.
    static func punchInStatus(elapsed: TimeInterval, level: String) -> String {
        String(localized: "Recording, \(spoken(elapsed)), level \(level)",
               comment: "A part of the audio editor's status line while a punch-in records. %1$@ is the time recorded, in words, and %2$@ the input level.")
    }

    /// Said as a take under way is discarded.
    static var punchInDiscarded: String {
        String(localized: "Recording discarded.", comment: "Said as a punch-in recording under way is discarded in the audio editor.")
    }

    /// Said as a take replaces the selection.
    static func punchedIn(_ length: TimeInterval, replacing replaced: TimeInterval, now duration: TimeInterval) -> String {
        SentenceWording.joined([
            String(localized: "Replaced \(spoken(replaced)) with \(spoken(length)) of new recording, which is selected.",
                   comment: "Said as a punch-in recording replaces the selection in the audio editor. %1$@ is the length replaced and %2$@ the length of the new recording, both in words."),
            nowLong(duration)
        ])
    }

    /// Said as a take is inserted at the cursor.
    static func recordingInserted(_ length: TimeInterval, now duration: TimeInterval) -> String {
        SentenceWording.joined([
            String(localized: "Inserted \(spoken(length)) of new recording, which is selected.",
                   comment: "Said as a punch-in recording is inserted at the cursor in the audio editor. %@ is its length in words."),
            nowLong(duration)
        ])
    }

    // MARK: - Apply Filter

    /// Apply Filter's sheet title.
    static var filterTitle: String {
        String(localized: "Apply Filter", comment: "Name of an edit, as the Undo and Redo menu items say it after \"Undo\" or \"Redo\"; also the title of the audio editor's filter sheet.")
    }

    /// The preset pop-up's label.
    static var presetLabel: String {
        String(localized: "Filter", comment: "Label of the pop-up in the audio editor's Apply Filter sheet that chooses a filter preset.")
    }

    /// The label of the line showing a preset's chain.
    static var chainLabel: String {
        String(localized: "Chain", comment: "Label of the field that holds a filter preset's chain of filters, and of the line that shows it in the audio editor's Apply Filter.")
    }

    /// The label of the choice of what to filter.
    static var applyToLabel: String {
        String(localized: "Apply to", comment: "Label of the choice in the audio editor's Apply Filter sheet of what to filter: the selection or the whole file.")
    }

    /// The button that plays the processed sound.
    static var previewButton: String {
        String(localized: "Preview", comment: "Button of the audio editor's Apply Filter sheet that plays the filtered sound.")
    }

    /// The button that stops a preview.
    static var stopPreviewButton: String {
        String(localized: "Stop Preview", comment: "Button of the audio editor's Apply Filter sheet that stops the preview.")
    }

    /// The button that applies the filter.
    static var applyButton: String {
        String(localized: "Apply", comment: "Button of the audio editor's Apply Filter sheet that applies the filter.")
    }

    /// Shown when there are no presets.
    static var noPresets: String {
        String(localized: "There are no filter presets. Add some in Storage settings, under Audio Editing.",
               comment: "Shown in the audio editor's Apply Filter sheet when there are no filter presets. \"Storage settings\" and \"Audio Editing\" are the names of a settings tab and its group.")
    }

    /// How the choice of what to filter names `target`.
    static func targetTitle(_ target: AudioEditorFilterTarget) -> String {
        switch target {
        case .selection:
            return String(localized: "Selection", comment: "Choice in the audio editor's Apply Filter sheet: filter the selected stretch of the audio.")
        case .wholeFile:
            return String(localized: "Whole File", comment: "Choice in the audio editor's Apply Filter sheet: filter all of the audio.")
        }
    }

    /// Said as a preview begins.
    static func previewingFilter(_ name: String) -> String {
        String(localized: "Previewing \(name).", comment: "Said as a filter preview begins in the audio editor. %@ is the filter preset's name.")
    }

    /// Said as Apply previews first, as "Preview filters before applying"
    /// asks.
    static func previewingBeforeApplying(_ name: String) -> String {
        String(localized: "Previewing \(name) first. Choose Apply again to apply it.",
               comment: "Said as the audio editor's Apply plays a preview first, because the Preview filters before applying setting is on. %@ is the filter preset's name. \"Apply\" is the name of the button.")
    }

    /// Apply's hint while a press would preview first
    /// (`AudioEditorModel.applyWouldPreview`).
    static var applyPreviewsFirstHint: String {
        String(localized: "Plays the filtered audio first; choose Apply again to apply the filter.",
               comment: "Hint of the audio editor's Apply button while a press would play a preview first.")
    }

    /// Apply's hint while a press applies.
    static var applyHint: String {
        String(localized: "Applies the filter.", comment: "Hint of the audio editor's Apply button while a press applies the filter.")
    }

    /// Said when there is nothing after the cursor to preview.
    static var nothingToPreview: String {
        String(localized: "There's no audio after the cursor to preview.", comment: "Said when the audio editor has no audio after the cursor to preview a filter on.")
    }

    /// Said as a filter begins.
    static func applyingFilter(_ name: String) -> String {
        String(localized: "Applying \(name).", comment: "Said as a filter begins to be applied in the audio editor. %@ is the filter preset's name.")
    }

    /// Said as a filter has been applied, to a selection `length` seconds
    /// long, or to the whole file for nil.
    static func appliedFilter(_ name: String, to length: TimeInterval?, now duration: TimeInterval) -> String {
        let applied = length.map {
            String(localized: "Applied \(name) to \(spoken($0)).",
                   comment: "Said as a filter has been applied to a selection in the audio editor. %1$@ is the filter preset's name and %2$@ the selection's length in words.")
        } ?? String(localized: "Applied \(name) to all of the audio.",
                    comment: "Said as a filter has been applied to the whole audio in the audio editor. %@ is the filter preset's name.")
        return SentenceWording.joined([applied, nowLong(duration)])
    }

    // MARK: - Saving and Exporting

    /// A format a save or an export writes, by name: the name Export lists
    /// it by (`AudioExportFormat.title`).
    static func formatName(_ format: AudioRenderFormat) -> String {
        switch format {
        case .aacM4A: return AudioExportFormat.m4a.title
        case .aacM4B: return AudioExportFormat.m4b.title
        case .alacM4A: return AudioExportFormat.appleLossless.title
        case .pcmCAF: return AudioExportFormat.caf.title
        case .pcmWAV: return AudioExportFormat.wav.title
        case .pcmAIFF: return AudioExportFormat.aiff.title
        case .mp3: return AudioExportFormat.mp3.title
        }
    }

    /// Said by Save with nothing to save.
    static var nothingToSave: String {
        String(localized: "There's nothing to save: the book's audio already holds every edit.", comment: "Said by the audio editor's Save when there is nothing to save.")
    }

    /// The save's sheet title.
    static var savingTitle: String {
        String(localized: "Saving", comment: "Title of the sheet shown while the audio editor saves the edits into the book.")
    }

    /// What a save writes, said as it begins and shown in its sheet.
    static func savingDetail(_ duration: TimeInterval, format: String?) -> String {
        guard let format else {
            return String(localized: "Saving \(spoken(duration)) of audio into the book.",
                          comment: "Said as the audio editor begins to save, and shown in its sheet. %@ is the audio's length in words.")
        }
        return String(localized: "Saving \(spoken(duration)) of audio as \(format), the format this book keeps.",
                      comment: "Said as the audio editor begins to save, and shown in its sheet. %1$@ is the audio's length in words and %2$@ the name of the file format the book keeps, such as \"M4A (AAC)\".")
    }

    /// Said when a save or an export writes a format with no place for
    /// chapter markers: "WAV files can't hold chapter markers, so its 3
    /// chapter markers are left out of this file."
    static func chaptersLeftOut(_ count: Int, format: String) -> String {
        String(localized: "\(format) files can't hold chapter markers, so its \(count) chapter markers are left out of this file.",
               comment: "Said when a save or an export writes a file format that has no place for chapter markers. %1$@ is the format's name, such as \"WAV\", and %2$lld the number of chapter markers left out.")
    }

    /// Said when a save writes the book's file in a format whose markers
    /// TextMouth writes but never reads back as a book's chapters (a CAF
    /// file's, FMT11): "TextMouth doesn't read chapter markers back from CAF
    /// files, so this book won't list its 3 chapter markers once saved."
    static func chaptersNotReadBack(_ count: Int, format: String) -> String {
        String(localized: "TextMouth doesn't read chapter markers back from \(format) files, so this book won't list its \(count) chapter markers once saved.",
               comment: "Said when a save writes the book's file in a format whose chapter markers TextMouth writes but never reads back as the book's chapters. %1$@ is the format's name, such as \"CAF\", and %2$lld the number of chapter markers.")
    }

    /// Said after a save or an export whose audio was written but whose
    /// chapter markers could not be (FMT11): "Its 3 chapter markers couldn't
    /// be written into the file, so it has none."
    static func chapterMarkersNotWritten(_ count: Int) -> String {
        String(localized: "Its \(count) chapter markers couldn't be written into the file, so it has none.",
               comment: "Said after a save or an export whose audio was written but whose chapter markers could not be. %lld is the number of chapter markers.")
    }

    /// Said as a save ends: the new length, and a new file name when the
    /// format's extension changed it.
    static func saved(_ duration: TimeInterval, renamedTo file: String?) -> String {
        let saved = String(localized: "Saved. The book's audio is now \(spoken(duration)) long.",
                           comment: "Said as the audio editor's save ends. %@ is the book's new audio length in words.")
        guard let file else { return saved }
        return SentenceWording.joined([
            saved,
            String(localized: "Its file is now “\(file)”, since TextMouth can't write its old format.",
                   comment: "Said as a save ends and the book's file got a new name because TextMouth can't write the old format. %@ is the file's new name.")
        ])
    }

    /// Said when a save fails.
    static func saveFailed(_ reason: String) -> String {
        SentenceWording.joined([
            String(localized: "The edits couldn't be saved.", comment: "Said when the audio editor's save fails. A sentence giving the reason follows."),
            reason
        ])
    }

    /// The export's sheet title while it runs.
    static var exportingTitle: String {
        String(localized: "Exporting", comment: "Title of the sheet shown while the audio editor exports the audio.")
    }

    /// What an export writes, said as it begins and shown in its sheet.
    static func exportingDetail(_ duration: TimeInterval, format: String, file: String) -> String {
        String(localized: "Exporting \(spoken(duration)) of audio as \(format) to “\(file)”.",
               comment: "Said as the audio editor begins to export, and shown in its sheet. %1$@ is the audio's length in words, %2$@ the file format's name, and %3$@ the exported file's name.")
    }

    /// Said as an export ends.
    static func exported(file: String) -> String {
        String(localized: "Exported “\(file)”.", comment: "Said as the audio editor's export ends. %@ is the exported file's name.")
    }

    /// Said as an export ends that wrote its label file beside the audio
    /// (FMT06).
    static func exported(file: String, labels: String) -> String {
        String(localized: "Exported “\(file)” and its labels, “\(labels)”.",
               comment: "Said as the audio editor's export ends having written a label file beside the audio. %1$@ is the audio file's name and %2$@ the label file's name.")
    }

    /// Said as an export ends whose audio was written but whose label file
    /// could not be, for `reason`.
    static func exported(file: String, labelsFailed reason: String) -> String {
        SentenceWording.joined([
            String(localized: "Exported “\(file)”, but its labels couldn't be written.",
                   comment: "Said as the audio editor's export ends having written the audio but not the label file. %@ is the audio file's name. A sentence giving the reason follows."),
            reason
        ])
    }

    /// The Export Audio checkbox that writes the markers as labels too, and
    /// its hint (FMT06).
    static var exportLabelsToggle: String {
        String(localized: "Also write the markers as Audacity labels", comment: "Label of the checkbox in the audio editor's Export Audio sheet that writes the markers as a label file too. Audacity is the name of an audio editing program.")
    }

    static var exportLabelsHint: String {
        String(localized: "Writes the chapter markers and the markers beside the audio, in an Audacity label file of the same name, which Audacity imports as a label track.",
               comment: "Hint of the Also write the markers as Audacity labels checkbox. Audacity is the name of an audio editing program.")
    }

    /// The checkbox's hint while the audio has no marker of either kind to
    /// write.
    static var exportLabelsNothingHint: String {
        String(localized: "The audio has no chapter markers or markers yet, so no label file would be written.",
               comment: "Hint of the Also write the markers as Audacity labels checkbox while the audio has no markers of either kind.")
    }

    /// Said as an export ends that was asked for labels but had no marker to
    /// write.
    static func exportedWithoutLabels(file: String) -> String {
        String(localized: "Exported “\(file)”. It has no markers, so no label file was written.",
               comment: "Said as the audio editor's export ends when labels were asked for but the audio has no marker. %@ is the exported file's name.")
    }

    /// Said when an export fails.
    static func exportFailed(_ reason: String) -> String {
        SentenceWording.joined([
            String(localized: "The audio couldn't be exported.", comment: "Said when the audio editor's export fails. A sentence giving the reason follows."),
            reason
        ])
    }

    /// Said at each quarter of a long save or export.
    static func percentDone(_ percent: Int) -> String {
        String(localized: "\(percent) percent", comment: "Said at each quarter of a long save or export in the audio editor. %lld is how much is done, from 0 to 100.")
    }

    /// The label of the progress bar.
    static var progressLabel: String {
        String(localized: "Progress", comment: "Label of the progress bar of a save or an export in the audio editor.")
    }

    /// Export's sheet title.
    static var exportTitle: String {
        String(localized: "Export Audio", comment: "Title of the audio editor's Export Audio sheet.")
    }

    /// The format pop-up's label.
    static var formatLabel: String {
        String(localized: "Format", comment: "Label of the pop-up in the audio editor's Export Audio sheet that chooses the file format.")
    }

    /// The button that asks where to export to.
    static var exportButton: String {
        String(localized: "Export…", comment: "Button of the audio editor's Export Audio sheet that asks where to save the file.")
    }

    /// What Export… does.
    static var exportButtonHint: String {
        String(localized: "Asks where to save the file, then writes it. The book's own file stays as it is.",
               comment: "Hint of the audio editor's Export… button.")
    }

    // MARK: - Reverting

    /// Revert's confirmation question.
    static var revertQuestion: String {
        String(localized: "Revert to the original audio?", comment: "Question of the confirmation shown before the audio editor's Revert to Original.")
    }

    /// What reverting does, with how many edits it undoes and how many
    /// markers it deletes.
    static func revertExplanation(_ count: Int, markers: Int = 0) -> String {
        let undone = String(localized: "\(count) edits are undone. Redo brings them back until you make another edit.",
                            comment: "Explains the audio editor's Revert to Original confirmation: how many edits it undoes. %lld is the number of edits.")
        guard markers > 0 else { return undone }
        return SentenceWording.joined([
            undone,
            String(localized: "The \(markers) markers are deleted, and Redo doesn't bring them back.",
                   comment: "Explains the audio editor's Revert to Original confirmation: how many markers it deletes. %lld is the number of markers.")
        ])
    }

    /// The button that reverts.
    static var revertButton: String {
        String(localized: "Revert", comment: "Button of the audio editor's Revert to Original confirmation that reverts.")
    }

    /// Said as Revert to Original ends, having undone `count` edits and
    /// deleted `markers` markers.
    static func reverted(_ count: Int, markers: Int = 0) -> String {
        let reverted = String(localized: "Reverted to the original audio. Redo brings back the \(count) edits.",
                              comment: "Said as the audio editor's Revert to Original ends. %lld is the number of edits undone, which Redo brings back.")
        guard markers > 0 else { return reverted }
        return SentenceWording.joined([
            reverted,
            String(localized: "The \(markers) markers are deleted.",
                   comment: "Said as the audio editor's Revert to Original ends having deleted markers. %lld is the number of markers deleted.")
        ])
    }

    /// Said by Revert to Original with nothing to undo.
    static var nothingToRevert: String {
        String(localized: "There's nothing to revert: no edit can be undone.", comment: "Said by the audio editor's Revert to Original when no edit can be undone.")
    }

    /// Said by Revert to Original when no original is kept.
    static var revertNoOriginal: String {
        String(localized: "No original audio is kept for this book, so it can't be reverted. Undo takes back the edits made since it was last saved.",
               comment: "Said by the audio editor's Revert to Original when the book keeps no original audio.")
    }

    // MARK: - Audio Info

    /// Audio Info's sheet title.
    static var infoTitle: String {
        String(localized: "Audio Info", comment: "Title of the audio editor's Audio Info sheet.")
    }

    /// The labels of Audio Info's facts.
    static var lengthLabel: String {
        String(localized: "Length", comment: "Label of the audio editor's field for the length of a silence, and of the audio's length in Audio Info.")
    }

    static var fileLabel: String {
        String(localized: "File", comment: "Label of the audio file's name in the audio editor's Audio Info sheet.")
    }

    static var savedAsLabel: String {
        String(localized: "Saved as", comment: "Label of the file format the book's audio is saved as, in the audio editor's Audio Info sheet.")
    }

    static var editsLabel: String {
        String(localized: "Edits", comment: "Label of the number of edits made, in the audio editor's Audio Info sheet.")
    }

    static var originalLabel: String {
        String(localized: "Original audio", comment: "Label of whether the original audio is kept, in the audio editor's Audio Info sheet.")
    }

    /// The original policy pop-up's label.
    static var policyLabel: String {
        String(localized: "Original audio for this book", comment: "Label of the pop-up in the audio editor's Audio Info sheet that sets what happens to this book's original audio.")
    }

    /// The policy pop-up's first choice: the global setting, named.
    static func useGlobal(_ global: AudioOriginalPolicy) -> String {
        String(localized: "Use the global setting (\(AudioEditingSettingsWording.choiceTitle(global.choice)))",
               comment: "The first choice of the Audio Info pop-up for a book's original audio: follow the global setting. %@ is that setting's name, such as \"Keep\".")
    }

    /// How the policy pop-up names `choice`.
    static func choiceTitle(_ choice: AudioEditorPolicyChoice, global: AudioOriginalPolicy) -> String {
        switch choice {
        case .global: return useGlobal(global)
        case .keep: return AudioEditingSettingsWording.choiceTitle(.keep)
        case .delete: return AudioEditingSettingsWording.choiceTitle(.delete)
        case .deleteAfterDays: return AudioEditingSettingsWording.choiceTitle(.deleteAfterDays)
        }
    }

    /// The edits, as Audio Info says them: "No edits", "3 edits, all
    /// saved", "3 edits, not all saved".
    static func edits(_ count: Int, unsaved: Bool) -> String {
        guard count > 0 else {
            return unsaved
                ? String(localized: "No edits, not saved", comment: "The edits as the audio editor's Audio Info says them: there are none, and the work is not saved.")
                : String(localized: "No edits", comment: "The edits as the audio editor's Audio Info says them: there are none.")
        }
        return unsaved
            ? String(localized: "\(count) edits, not all saved", comment: "The edits as the audio editor's Audio Info says them. %lld is the number of edits.")
            : String(localized: "\(count) edits, all saved", comment: "The edits as the audio editor's Audio Info says them. %lld is the number of edits.")
    }

    /// Whether the original is kept, as Audio Info says it.
    static func originalStatus(kept: Bool, deletedAt: Date?) -> String {
        if kept {
            return String(localized: "Kept", comment: "The original audio's state in the audio editor's Audio Info sheet: it is kept.")
        }
        if let deletedAt {
            return String(localized: "Deleted on \(deletedAt.formatted(date: .long, time: .omitted))",
                          comment: "The original audio's state in the audio editor's Audio Info sheet. %@ is the date it was deleted, in long form.")
        }
        return String(localized: "Not kept", comment: "The original audio's state in the audio editor's Audio Info sheet: it is not kept.")
    }

    /// Said as the book's own policy changes: what it does now.
    static func policyChanged(_ policy: AudioOriginalPolicy?, global: AudioOriginalPolicy) -> String {
        switch policy {
        case nil:
            return SentenceWording.joined([
                String(localized: "This book follows the global setting now.",
                       comment: "Said as a book's original audio policy is set to follow the global setting. A sentence saying what that setting does follows."),
                AudioEditingSettingsWording.explanation(global)
            ])
        case .keep?:
            return String(localized: "This book keeps its original audio until the book is removed.",
                          comment: "Said as a book's original audio policy is set to keep the original until the book is removed.")
        case .delete?:
            return String(localized: "This book keeps no original audio: saved edits change its audio in place, and can't be undone after.",
                          comment: "Said as a book's original audio policy is set to keep no original.")
        case .deleteAfter(let days)?:
            return String(localized: "This book keeps its original audio for \(Int(days.rounded())) days after it was saved or last edited.",
                          comment: "Said as a book's original audio policy is set to keep the original for a number of days. %lld is the number of days.")
        }
    }

    // MARK: - Closing

    /// The question asked as a window with unsaved edits closes.
    static func closeQuestion(book: String) -> String {
        String(localized: "Save the edits to “\(book)”?",
               comment: "Question asked as the audio editor's window with unsaved edits closes. %@ is the book's title.")
    }

    /// What its answers do.
    static var closeExplanation: String {
        String(localized: "The book's audio doesn't hold them yet. Discard undoes them; the next time you edit this book, Redo brings them back until you make another edit.",
               comment: "Explains the question asked as the audio editor's window with unsaved edits closes: what Discard does.")
    }

    /// The close question's buttons.
    static var saveButton: String {
        String(localized: "Save", comment: "Button that saves what a sheet or window edited, such as a filter preset or the audio editor's edits.")
    }

    static var discardButton: String {
        String(localized: "Discard", comment: "Button of the audio editor's close question that undoes the unsaved edits.")
    }

    /// Said when the window can't close while work is under way.
    static var closeWhileWorking: String {
        String(localized: "The editor is still working. Close it once the change is done.", comment: "Said when the audio editor's window can't close because a change, save, or export is under way.")
    }

    /// Said when the window can't close while a punch-in records.
    static var closeWhileRecording: String {
        String(localized: "A recording is under way. Stop it, or discard it with Clear Selection, then close the editor.",
               comment: "Said when the audio editor's window can't close because a punch-in records. \"Clear Selection\" is the name of a command.")
    }

    /// Said when Discard can't reach the audio as saved.
    static var discardKept: String {
        String(localized: "The book's audio holds edits its history no longer has, so the edits stay, to be saved or undone the next time you edit this book.",
               comment: "Said when the audio editor's Discard can't reach the audio as it was saved: the edits stay.")
    }

    // MARK: - Quitting

    /// What the question about an editor's unsaved edits explains as
    /// TextMouth quits.
    static var quitExplanation: String {
        String(localized: "TextMouth is quitting, and the book's audio doesn't hold these edits yet. Discard undoes them; the next time you edit this book, Redo brings them back until you make another edit. Cancel keeps TextMouth open.",
               comment: "Explains the question about the audio editor's unsaved edits asked as TextMouth quits: what Discard and Cancel do.")
    }

    /// Said, in the editor of `book`, when TextMouth can't quit while its
    /// work is under way.
    static func quitWhileWorking(book: String) -> String {
        String(localized: "The editor of “\(book)” is still working. Quit TextMouth once the change is done.",
               comment: "Said in an audio editor when TextMouth can't quit because its work is under way. %@ is the book's title.")
    }

    /// Said, in the editor of `book`, when TextMouth can't quit while a
    /// punch-in records there.
    static func quitWhileRecording(book: String) -> String {
        String(localized: "A recording is under way in the editor of “\(book)”. Stop it, or discard it with Clear Selection, then quit TextMouth.",
               comment: "Said in an audio editor when TextMouth can't quit because a punch-in records there. %@ is the book's title. \"Clear Selection\" is the name of a command.")
    }

    // MARK: - The Commands

    /// The names of the editor's groups of buttons, as headings.
    static var listenHeading: String {
        String(localized: "Listen and Move", comment: "Heading of the audio editor's buttons for listening and moving the cursor.")
    }

    /// The heading of the selection's and the markers' buttons.
    static var selectHeading: String {
        String(localized: "Select and Mark", comment: "Heading of the audio editor's buttons for the selection and the markers.")
    }

    /// The heading of the editing buttons.
    static var editHeading: String {
        String(localized: "Edit", comment: "Button of the track question that opens the audio editor on the track chosen, and the heading of the audio editor's editing buttons.")
    }

    /// The heading of the saving buttons.
    static var fileHeading: String {
        String(localized: "Save and Export", comment: "Heading of the audio editor's buttons for saving and exporting.")
    }

    /// What `action`'s button does, as its hint says, before its shortcut;
    /// empty for an action that isn't the editor's.
    static func explanation(of action: ShortcutAction) -> String {
        switch action {
        case .editorPlayPause:
            return String(localized: "Plays from the cursor, or pauses where the audio is.", comment: "Hint of the audio editor's Play or Pause button.")
        case .editorStop:
            return String(localized: "Stops playing, and goes back to where playing began.", comment: "Hint of the audio editor's Stop button.")
        case .editorSkipBack:
            return String(localized: "Moves the cursor back one second.", comment: "Hint of the audio editor's Skip Back button.")
        case .editorSkipForward:
            return String(localized: "Moves the cursor forward one second.", comment: "Hint of the audio editor's Skip Forward button.")
        case .editorSkipBackLong:
            return String(localized: "Moves the cursor back ten seconds.", comment: "Hint of the audio editor's Skip Back Long button.")
        case .editorSkipForwardLong:
            return String(localized: "Moves the cursor forward ten seconds.", comment: "Hint of the audio editor's Skip Forward Long button.")
        case .editorSkipBackShort:
            return String(localized: "Moves the cursor back a tenth of a second.", comment: "Hint of the audio editor's Skip Back Short button.")
        case .editorSkipForwardShort:
            return String(localized: "Moves the cursor forward a tenth of a second.", comment: "Hint of the audio editor's Skip Forward Short button.")
        case .editorGoToStart:
            return String(localized: "Moves the cursor to the start of the audio.", comment: "Hint of the audio editor's Go to Start button.")
        case .editorGoToEnd:
            return String(localized: "Moves the cursor to the end of the audio.", comment: "Hint of the audio editor's Go to End button.")
        case .editorGoToTime:
            return String(localized: "Moves the cursor to a time you type.", comment: "Hint of the audio editor's Go to Time button.")
        case .editorPreviousChapter:
            return String(localized: "Moves the cursor to the previous chapter marker.", comment: "Hint of the audio editor's Previous Chapter button.")
        case .editorNextChapter:
            return String(localized: "Moves the cursor to the next chapter marker.", comment: "Hint of the audio editor's Next Chapter button.")
        case .editorPreviousPause:
            return String(localized: "Moves the cursor to where the sound after the previous pause begins.", comment: "Hint of the audio editor's Previous Pause button.")
        case .editorNextPause:
            return String(localized: "Moves the cursor to where the sound after the next pause begins.", comment: "Hint of the audio editor's Next Pause button.")
        case .editorWhereAmI:
            return String(localized: "Says where the cursor is, in which chapter, and what is selected.", comment: "Hint of the audio editor's Where Am I button.")
        case .editorMarkIn:
            return String(localized: "Marks the selection's start at the cursor.", comment: "Hint of the audio editor's Mark In button.")
        case .editorMarkOut:
            return String(localized: "Marks the selection's end at the cursor.", comment: "Hint of the audio editor's Mark Out button.")
        case .editorSelectToPreviousPause:
            return String(localized: "Selects from where the sound after the previous pause begins to the cursor.", comment: "Hint of the audio editor's Select to Previous Pause button.")
        case .editorSelectToNextPause:
            return String(localized: "Selects from the cursor to where the sound after the next pause begins.", comment: "Hint of the audio editor's Select to Next Pause button.")
        case .editorSelectChapter:
            return String(localized: "Selects the chapter the cursor is in.", comment: "Hint of the audio editor's Select Chapter button.")
        case .editorSelectAll:
            return String(localized: "Selects all of the audio.", comment: "Hint of the audio editor's Select All button.")
        case .editorClearSelection:
            return String(localized: "Clears the selection.", comment: "Hint of the audio editor's Clear Selection button.")
        case .editorSpeakSelection:
            return String(localized: "Says where the selection starts and ends, and how long it is.", comment: "Hint of the audio editor's Speak Selection button.")
        case .editorPlaySelection:
            return String(localized: "Plays the selection, and stops at its end.", comment: "Hint of the audio editor's Play Selection button.")
        case .editorAddMarker:
            return String(localized: "Drops a marker at the cursor, even while the audio plays.", comment: "Hint of the audio editor's Add Marker button.")
        case .editorShowMarkers:
            return String(localized: "Lists the markers, the chapter markers, and the pauses, to go to, name, select, or delete them.", comment: "Hint of the audio editor's Show Markers button.")
        case .editorUndo:
            return String(localized: "Undoes the newest edit.", comment: "Hint of the audio editor's Undo button.")
        case .editorRedo:
            return String(localized: "Redoes the edit undone last.", comment: "Hint of the audio editor's Redo button.")
        case .editorCut:
            return String(localized: "Cuts the selection out, and keeps it for Paste.", comment: "Hint of the audio editor's Cut button. \"Paste\" is the name of a command.")
        case .editorCopy:
            return String(localized: "Copies the selection for Paste.", comment: "Hint of the audio editor's Copy button. \"Paste\" is the name of a command.")
        case .editorPaste:
            return String(localized: "Pastes the audio cut or copied at the cursor, or over the selection. Right after a cut, it moves the audio cut.", comment: "Hint of the audio editor's Paste button.")
        case .editorTrimToSelection:
            return String(localized: "Keeps only the selection, removing the audio before and after it.", comment: "Hint of the audio editor's Trim to Selection button.")
        case .editorInsertSilence:
            return String(localized: "Inserts a silence of a length you type at the cursor.", comment: "Hint of the audio editor's Insert Silence button.")
        case .editorInsertChapter:
            return String(localized: "Sets a chapter marker at the cursor, with a title you type.", comment: "Hint of the audio editor's Insert Chapter Marker button.")
        case .editorApplyFilter:
            return String(localized: "Runs a filter preset over the selection or the whole file, with a preview first.", comment: "Hint of the audio editor's Apply Filter button.")
        case .editorPunchIn:
            return String(localized: "Records from the microphone over the selection, or at the cursor, after a beep. Again, or Stop, ends it.", comment: "Hint of the audio editor's Punch In button. \"Stop\" is the name of a button.")
        case .editorSave:
            return String(localized: "Saves the edits into the book's audio file, in the format the book keeps.", comment: "Hint of the audio editor's Save button.")
        case .editorExport:
            return String(localized: "Exports the edited audio to a file outside the library, in a format you choose.", comment: "Hint of the audio editor's Export button.")
        case .editorRevert:
            return String(localized: "Undoes every edit, back to the original audio; Redo brings them back.", comment: "Hint of the audio editor's Revert to Original button. \"Redo\" is the name of a command.")
        case .editorInfo:
            return String(localized: "Shows the audio's length, file, and edits, and sets what happens to this book's original audio.", comment: "Hint of the audio editor's Audio Info button.")
        default: return ""
        }
    }

    /// A button's hint: what it does, then its shortcuts in force.
    static func hint(for action: ShortcutAction, bindings: [KeyBinding]) -> String {
        SentenceWording.joined([explanation(of: action), shortcutSentence(bindings)])
    }

    /// The shortcuts of a command in words, each as the Shortcuts tab says
    /// it (`KeyBinding.accessibleDisplayString`, from the one table of key
    /// names, `KeyBinding.keyNames`): "Shortcut: Shift + J.", "Shortcuts: J
    /// or Comma.", "No shortcut."
    static func shortcutSentence(_ bindings: [KeyBinding]) -> String {
        guard !bindings.isEmpty else {
            return String(localized: "No shortcut.", comment: "Ends a button's hint in the audio editor when its command has no keyboard shortcut.")
        }
        // The keys are named in the region's own list style: "J or Comma",
        // and "J, Comma, or Period" in English.
        let names = bindings.map(\.accessibleDisplayString).formatted(.list(type: .or, width: .standard))
        return bindings.count == 1
            ? String(localized: "Shortcut: \(names).", comment: "Ends a button's hint in the audio editor: the command's one keyboard shortcut. %@ is the key's name such as \"Shift + J\".")
            : String(localized: "Shortcuts: \(names).", comment: "Ends a button's hint in the audio editor: the command's keyboard shortcuts. %@ is their names as a list, such as \"J or Comma\".")
    }
}
