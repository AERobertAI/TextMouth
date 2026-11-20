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
        // Translators: Command that opens the audio editor on a book: the library row's context menu item and VoiceOver action, and the reader's Book menu item.
        String(localized: "Edit Audio…")
    }

    /// The window's title: the book, and the track of a book of several.
    static func windowTitle(book: String, track: String?) -> String {
        guard let track else {
            // Translators: Title of the audio editor's window. %@ is the book's title.
            return String(localized: "Edit Audio: \(book)")
        }
        // Translators: Title of the audio editor's window for a book of several tracks. %1$@ is the book's title and %2$@ the track's name.
        return String(localized: "Edit Audio: \(book), \(track)")
    }

    /// Said when Edit Audio… is chosen for something that is not an
    /// audiobook kept in a package of its own.
    static var notAnAudiobook: String {
        // Translators: Said when Edit Audio… is chosen for something that is not an audiobook kept in a package of its own.
        String(localized: "Only an audiobook's audio can be edited.")
    }

    /// Said when Edit Audio… reaches an episode in its feed's folder, which
    /// is not editable (FR11): it is never offered for one.
    static var feedEpisodeNotEditable: String {
        // Translators: Said when Edit Audio… reaches a podcast episode that lives in its feed's folder, which can't be edited.
        String(localized: "An episode in its feed can't be edited.")
    }

    /// Said when the book's editor is open already: it comes forward.
    static func alreadyOpen(book: String) -> String {
        // Translators: Said when Edit Audio… is chosen for a book whose editor is already open; that window comes forward. %@ is the book's title.
        String(localized: "The audio editor for \(book) is already open.")
    }

    /// Said as the book's reader is closed before the editor opens.
    static func closingReader(book: String) -> String {
        // Translators: Said as a book's reader window is closed before the audio editor opens on the book. %@ is the book's title.
        String(localized: "Closing the reader of \(book), since editing changes its audio.")
    }

    /// Said when the book's reader did not close.
    static func readerStillOpen(book: String) -> String {
        // Translators: Said when a book's reader did not close, so the audio editor can't open. %@ is the book's title. "Edit Audio" is the name of the command.
        String(localized: "\(book) is open in a reader. Close it, then choose Edit Audio again.")
    }

    /// The question asked for a book of several tracks.
    static func chooseTrackQuestion(book: String) -> String {
        // Translators: Question asked before editing a book of several audio tracks. %@ is the book's title.
        String(localized: "Which track of \(book) do you want to edit?")
    }

    /// What the track question explains.
    static var chooseTrackExplanation: String {
        // Translators: Explains the question about which track of a book to edit.
        String(localized: "Edits one track at a time, listed by chapter name.")
    }

    /// The track pop-up's label.
    static var trackLabel: String {
        // Translators: Label of the pop-up that chooses which audio track of a book to edit.
        String(localized: "Track")
    }

    /// The button that opens the editor on the track chosen.
    static var editButton: String {
        // Translators: Button of the track question that opens the audio editor on the track chosen, and the heading of the audio editor's editing buttons.
        String(localized: "Edit")
    }

    /// Every dialog's Cancel button.
    static var cancelButton: String {
        // Translators: Button that closes a sheet or dialog without making its change.
        String(localized: "Cancel")
    }

    /// Said for a book whose sections are stretches of its tracks, as a
    /// DAISY-style manifest makes them: editing a track would move them.
    static func sectionsNotEditable(book: String) -> String {
        // Translators: Said when Edit Audio… is chosen for a book whose sections are stretches of its audio tracks. %@ is the book's title.
        String(localized: "\(book) plays sections that are stretches of its tracks, so its tracks can't be edited yet.")
    }

    /// Said for a book of several tracks with none found.
    static func noTracks(book: String) -> String {
        // Translators: Said when a book of several audio tracks has no audio file to edit. %@ is the book's title.
        String(localized: "No audio files were found in \(book).")
    }

    /// The question asked when the book's edit history can't be read.
    static func historyUnusableQuestion(book: String) -> String {
        // Translators: Question asked when a book's saved audio edit history can't be read. %@ is the book's title.
        String(localized: "The edit history of \(book) couldn't be read.")
    }

    /// What starting over does.
    static var historyUnusableExplanation: String {
        // Translators: Explains the question about an unreadable audio edit history: what Start Over and Cancel do.
        String(localized: "A copy was kept in the book's package. Start over with no edits, or cancel.")
    }

    /// The button that starts over with an empty history.
    static var startOverButton: String {
        // Translators: Button that starts the audio editor over with an empty edit history, when the saved history can't be read.
        String(localized: "Start Over")
    }

    /// The title of the alert saying the editor couldn't open.
    static var openFailedTitle: String {
        // Translators: Title of the alert saying the audio editor couldn't open.
        String(localized: "The audio can't be edited")
    }

    /// Why the editor couldn't open: the engine's own sentence after the
    /// book's name.
    static func openFailed(book: String, reason: String) -> String {
        SentenceWording.joined([
            // Translators: Said when the audio editor couldn't open a book. %@ is the book's title. A sentence giving the reason follows.
            String(localized: "The audio of \(book) couldn't be opened for editing."),
            reason
        ])
    }

    /// The OK button of a notice.
    static var okButton: String {
        // Translators: Button that closes a notice.
        String(localized: "OK")
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
        // Translators: Label of the audio editor's time display: where the cursor is.
        String(localized: "Position")
    }

    /// The time display as it shows: "12:04.3 of 48:00".
    static func positionText(_ cursor: TimeInterval, of duration: TimeInterval) -> String {
        // Translators: The audio editor's time display as shown and brailled. %1$@ is the cursor's time and %2$@ the audio's length, both as clock times such as "12:04.3".
        String(localized: "\(clock(cursor)) of \(clock(duration))")
    }

    /// The time display as VoiceOver speaks it: "12 minutes, 4.3 seconds of
    /// 48 minutes".
    static func positionValue(_ cursor: TimeInterval, of duration: TimeInterval) -> String {
        // Translators: The audio editor's time display as VoiceOver speaks it. %1$@ is the cursor's time and %2$@ the audio's length, both in words such as "12 minutes, 4.3 seconds".
        String(localized: "\(spoken(cursor)) of \(spoken(duration))")
    }

    /// The label of the line repeating the last announcement, so a braille
    /// display can read it again.
    static var messageLabel: String {
        // Translators: Label of the audio editor's line that repeats the last announcement, so a braille display can read it again.
        String(localized: "Last message")
    }

    /// The status line's label.
    static var statusLabel: String {
        // Translators: Label of the audio editor's status line: the cursor's time, chapter, and selection.
        String(localized: "Status")
    }

    /// The chapter the cursor is in, as the status line says it: "in
    /// chapter 3: Tide Tables".
    static func inChapter(number: Int, title: String) -> String {
        // Translators: A part of the audio editor's status line: the chapter the cursor is in. %1$@ is the chapter's number, an identifier written without digit grouping, and %2$@ its title.
        String(localized: "in chapter \(String(number)): \(title)")
    }

    /// The status line made of its parts, in order: "12 minutes, 4.3
    /// seconds of 48 minutes; in chapter 3: Tide Tables". Semicolons keep
    /// the parts apart from the commas inside a spoken time.
    static func status(_ parts: [String]) -> String {
        guard let first = parts.first else { return "" }
        return parts.dropFirst().reduce(first) { text, next in
            // Translators: Joins two parts of the audio editor's status line. %1$@ is the parts so far and %2$@ the next part. A semicolon keeps parts apart from the commas inside a spoken time.
            String(localized: "\(text); \(next)")
        }
    }

    // MARK: - Listening and Moving

    /// The status line's first part while the audio plays.
    static var playing: String {
        // Translators: A part of the audio editor's status line while the audio plays.
        String(localized: "Playing")
    }

    /// Said as playing pauses: where.
    static func paused(at time: TimeInterval) -> String {
        // Translators: Said as the audio editor's playing pauses. %@ is where, as a time in words such as "12 minutes, 4 seconds".
        String(localized: "Paused at \(spoken(time)).")
    }

    /// Said as Play starts again from the start, the cursor having been at
    /// the end.
    static var playingFromStart: String {
        // Translators: Said as Play starts again from the start of the audio, the cursor having been at the end.
        String(localized: "Playing from the start.")
    }

    /// Said as Stop goes back to where playing began.
    static func stopped(backAt time: TimeInterval) -> String {
        // Translators: Said as the audio editor's Stop goes back to where playing began. %@ is that time in words.
        String(localized: "Stopped. Back at \(spoken(time)).")
    }

    /// Said when Stop is pressed with nothing playing.
    static var notPlaying: String {
        // Translators: Said when the audio editor's Stop is pressed with nothing playing.
        String(localized: "Nothing is playing.")
    }

    /// Said when Play is pressed before the edited audio is ready, or after
    /// it couldn't be made ready.
    static var notReadyToPlay: String {
        // Translators: Said when Play is pressed in the audio editor before the edited audio is ready, or after it couldn't be made ready.
        String(localized: "The audio isn't ready to play yet.")
    }

    /// Said as playing reaches the end of the audio.
    static var endOfAudio: String {
        // Translators: Said as the audio editor's playing reaches the end of the audio.
        String(localized: "End of the audio.")
    }

    /// Said as Go to End lands there: how long the audio is.
    static func endOfAudio(_ duration: TimeInterval) -> String {
        // Translators: Said as the audio editor's Go to End lands at the end. %@ is the audio's length in words.
        String(localized: "End of the audio, at \(spoken(duration)).")
    }

    /// Said as Go to Start lands there.
    static var startOfAudio: String {
        // Translators: Said as the audio editor's Go to Start lands at the start.
        String(localized: "Start of the audio.")
    }

    /// Said when a step back can go no further.
    static var atStart: String {
        // Translators: Said when a step back in the audio editor can go no further.
        String(localized: "Already at the start.")
    }

    /// Said when a step forward can go no further.
    static var atEnd: String {
        // Translators: Said when a step forward in the audio editor can go no further.
        String(localized: "Already at the end.")
    }

    /// Why a time typed can't be gone to.
    static func afterTheEnd(_ duration: TimeInterval) -> String {
        // Translators: Said when a time typed into the audio editor's Go to Time lies past the end. %@ is the audio's length in words.
        String(localized: "That's after the end of the audio, at \(spoken(duration)).")
    }

    /// Said by the chapter commands for audio without chapter markers.
    static var noChapters: String {
        // Translators: Said by the audio editor's chapter commands when the audio has no chapter markers.
        String(localized: "This audio has no chapter markers.")
    }

    /// Said when no chapter marker follows the cursor.
    static var noChapterAfter: String {
        // Translators: Said when the audio editor's Next Chapter finds no chapter marker after the cursor.
        String(localized: "No chapter marker after the cursor.")
    }

    /// Said when no chapter marker comes before the cursor.
    static var noChapterBefore: String {
        // Translators: Said when the audio editor's Previous Chapter finds no chapter marker before the cursor.
        String(localized: "No chapter marker before the cursor.")
    }

    /// Said as the cursor lands on a chapter marker: "Chapter 3: Tide
    /// Tables, at 12 minutes, 4 seconds."
    static func chapter(number: Int, title: String, at time: TimeInterval) -> String {
        // Translators: Said as the audio editor's cursor lands on a chapter marker. %1$@ is the chapter's number, an identifier written without digit grouping, %2$@ its title, and %3$@ its time in words.
        String(localized: "Chapter \(String(number)): \(title), at \(spoken(time)).")
    }

    /// Said as the cursor lands where the sound after a pause begins.
    static func afterPause(_ pause: AudioEditorPause) -> String {
        // Translators: Said as the audio editor's cursor lands where the sound after a pause begins. %1$@ is the pause's length in words and %2$@ the time the sound begins, in words.
        String(localized: "After a pause of \(spoken(pause.duration)), at \(spoken(pause.end)).")
    }

    /// Said when no pause follows the cursor.
    static var noPauseAfter: String {
        // Translators: Said when the audio editor's Next Pause finds no pause after the cursor.
        String(localized: "No pause after the cursor.")
    }

    /// Said when no pause comes before the cursor.
    static var noPauseBefore: String {
        // Translators: Said when the audio editor's Previous Pause finds no pause before the cursor.
        String(localized: "No pause before the cursor.")
    }

    /// Said while the pauses are still being found.
    static var findingPauses: String {
        // Translators: Said when a pause command is used in the audio editor while the pauses are still being found.
        String(localized: "Still finding the pauses. Try again in a moment.")
    }

    /// Said when the pauses couldn't be found.
    static func pausesFailed(_ reason: String) -> String {
        SentenceWording.joined([
            // Translators: Said when the audio editor couldn't find the audio's pauses. A sentence giving the reason follows.
            String(localized: "The pauses couldn't be found."),
            reason
        ])
    }

    // MARK: - Go to Time

    /// Go to Time's sheet title.
    static var goToTimeTitle: String {
        // Translators: Title of the audio editor's Go to Time sheet.
        String(localized: "Go to Time")
    }

    /// The label of a field taking a time.
    static var timeFieldLabel: String {
        // Translators: Label of a field in the audio editor that takes a time.
        String(localized: "Time")
    }

    /// The button that goes to the time typed.
    static var goButton: String {
        // Translators: Button of the audio editor's Go to Time sheet that moves the cursor to the time typed.
        String(localized: "Go")
    }

    /// How a field's problem is read: "Problem: Seconds must be less than
    /// 60."
    static func problemLabel(_ problem: String) -> String {
        // Translators: How VoiceOver reads the problem shown under a field. %@ is the problem's sentence.
        String(localized: "Problem: \(problem)")
    }

    /// A label and its value as one line: "Chain: highpass=f=80".
    static func labeled(_ label: String, _ value: String) -> String {
        // Translators: A label, a colon, and its value, as one line of the audio editor's sheets and the filter presets. %1$@ is the label and %2$@ the value.
        String(localized: "\(label): \(value)")
    }

    // MARK: - The Selection

    /// The selection as the status line says it, in clock times, which a
    /// braille display shows in few cells: "selection from 11:58 to
    /// 12:04.3, 6.3 seconds".
    static func selectionPart(_ range: AudioTimeRange) -> String {
        // Translators: A part of the audio editor's status line: the selection. %1$@ is its start and %2$@ its end, as clock times such as "11:58", and %3$@ its length in words.
        String(localized: "selection from \(clock(range.start)) to \(clock(range.end)), \(spoken(range.duration))")
    }

    /// The selection said in full, in words, as Speak Selection says it.
    static func selectionSentence(_ range: AudioTimeRange) -> String {
        // Translators: Said by the audio editor's Speak Selection. %1$@ is the selection's start, %2$@ its end, and %3$@ its length, all in words.
        String(localized: "Selection from \(spoken(range.start)) to \(spoken(range.end)); \(spoken(range.duration)) long.")
    }

    /// Said as a selection is made: how long it is.
    static func selected(_ range: AudioTimeRange) -> String {
        // Translators: Said as a selection is made in the audio editor. %@ is its length in words.
        String(localized: "Selected \(spoken(range.duration)).")
    }

    /// Said as In is marked, with the selection it makes, if any.
    static func markedIn(at time: TimeInterval, selection: AudioTimeRange?) -> String {
        // Translators: Said as the audio editor's Mark In marks the selection's start. %@ is the time in words. A sentence about the selection it makes may follow.
        let marked = String(localized: "In at \(spoken(time)).")
        return SentenceWording.joined([marked] + (selection.map { [selected($0)] } ?? []))
    }

    /// Said as Out is marked, with the selection it makes, if any.
    static func markedOut(at time: TimeInterval, selection: AudioTimeRange?) -> String {
        // Translators: Said as the audio editor's Mark Out marks the selection's end. %@ is the time in words. A sentence about the selection it makes may follow.
        let marked = String(localized: "Out at \(spoken(time)).")
        return SentenceWording.joined([marked] + (selection.map { [selected($0)] } ?? []))
    }

    /// Said as Select Chapter selects a chapter.
    static func selectedChapter(number: Int, title: String, length: TimeInterval) -> String {
        // Translators: Said as the audio editor's Select Chapter selects a chapter. %1$@ is the chapter's number, an identifier written without digit grouping, %2$@ its title, and %3$@ its length in words.
        String(localized: "Selected chapter \(String(number)): \(title), \(spoken(length)).")
    }

    /// Said as Select Chapter selects the audio before the first marker.
    static func selectedBeforeFirstChapter(_ length: TimeInterval) -> String {
        // Translators: Said as the audio editor's Select Chapter selects the audio before the first chapter marker. %@ is its length in words.
        String(localized: "Selected the \(spoken(length)) before chapter 1.")
    }

    /// Said as Select All selects everything.
    static func selectedAll(_ duration: TimeInterval) -> String {
        // Translators: Said as the audio editor's Select All selects everything. %@ is the audio's length in words.
        String(localized: "Selected all \(spoken(duration)).")
    }

    /// Said when a command needs a selection and there is none.
    static var noSelection: String {
        // Translators: Said when an audio editor command needs a selection and there is none.
        String(localized: "Nothing is selected.")
    }

    /// Said as the selection is cleared.
    static var selectionCleared: String {
        // Translators: Said as the audio editor's selection is cleared.
        String(localized: "Selection cleared.")
    }

    // MARK: - Markers

    /// A marker as the list and the announcements name it: "Marker 3" or
    /// "Marker 3, Intro".
    static func markerName(_ number: Int, named name: String) -> String {
        guard !name.isEmpty else { return markerSubject(number) }
        // Translators: A named marker as the audio editor's list and announcements name it. %1$@ is the marker's number, an identifier written without digit grouping, and %2$@ the name the user gave it.
        return String(localized: "Marker \(String(number)), \(name)")
    }

    /// Said as a marker is dropped.
    static func markerAdded(_ number: Int, at time: TimeInterval) -> String {
        // Translators: Said as a marker is dropped in the audio editor. %1$@ is the marker's number, an identifier written without digit grouping, and %2$@ its time in words.
        String(localized: "Marker \(String(number)) at \(spoken(time)).")
    }

    /// Said as the cursor goes to a marker, and its row's label.
    static func marker(_ number: Int, named name: String, at time: TimeInterval) -> String {
        // Translators: Said as the audio editor's cursor goes to a marker, and its row's label. %1$@ is the marker's name such as "Marker 3" or "Marker 3, Intro", and %2$@ its time in words.
        String(localized: "\(markerName(number, named: name)), at \(spoken(time)).")
    }

    /// Said as a marker is named, or its name taken away.
    static func markerRenamed(_ number: Int, named name: String) -> String {
        name.isEmpty
            // Translators: Said as a marker's name is taken away in the audio editor. %@ is the marker's number, an identifier written without digit grouping.
            ? String(localized: "Marker \(String(number)) has no name now.")
            // Translators: Said as a marker is named in the audio editor. %1$@ is the marker's number, an identifier written without digit grouping, and %2$@ the name the user gave it.
            : String(localized: "Marker \(String(number)) named \(name).")
    }

    /// Said as a marker is deleted.
    static func markerDeleted(_ number: Int, named name: String) -> String {
        // Translators: Said as a marker is deleted in the audio editor. %@ is the marker's name such as "Marker 3" or "Marker 3, Intro".
        String(localized: "\(markerName(number, named: name)) deleted.")
    }

    /// A marker as its row's buttons and name field name it: "Marker 3".
    static func markerSubject(_ number: Int) -> String {
        // Translators: A marker as the audio editor's list, its row's buttons, and announcements name it. %@ is the marker's number, an identifier written without digit grouping.
        String(localized: "Marker \(String(number))")
    }

    /// A pause's row in the list: "Pause 2, 1.3 seconds, at 1 minute, 4.2
    /// seconds".
    static func pauseRow(_ number: Int, _ pause: AudioEditorPause) -> String {
        // Translators: A pause's row in the audio editor's list. %1$@ is the pause such as "Pause 2", %2$@ its length in words, and %3$@ its start in words.
        String(localized: "\(pauseSubject(number)), \(spoken(pause.duration)), at \(spoken(pause.start))")
    }

    /// A pause as its row's buttons name it: "Pause 2".
    static func pauseSubject(_ number: Int) -> String {
        // Translators: A pause as the audio editor's list and its row's buttons name it. %@ is the pause's number, an identifier written without digit grouping.
        String(localized: "Pause \(String(number))")
    }

    /// The marker list's title.
    static var markersTitle: String {
        // Translators: Title of the audio editor's list of markers, chapter markers, and pauses.
        String(localized: "Markers and Pauses")
    }

    /// The heading of the markers in the list.
    static var markersHeading: String {
        // Translators: Heading of the markers in the audio editor's list.
        String(localized: "Markers")
    }

    /// The heading of the pauses in the list.
    static var pausesHeading: String {
        // Translators: Heading of the pauses in the audio editor's list.
        String(localized: "Pauses")
    }

    /// Shown when no marker has been dropped.
    static var noMarkers: String {
        // Translators: Shown in the audio editor's list when no marker has been dropped. "Add Marker" is the name of the command.
        String(localized: "No markers yet. Add Marker drops one at the cursor.")
    }

    /// Shown when the audio has no pauses.
    static var noPauses: String {
        // Translators: Shown in the audio editor's list when the audio has no pauses.
        String(localized: "No pauses were found.")
    }

    /// The button that goes to a marker or a pause.
    static var goToButton: String {
        // Translators: Button of a marker's or a pause's row in the audio editor's list that moves the cursor there.
        String(localized: "Go To")
    }

    /// The button that selects a pause.
    static var selectButton: String {
        // Translators: Button of a pause's row in the audio editor's list that selects the pause.
        String(localized: "Select")
    }

    /// The button that names a marker.
    static var renameButton: String {
        // Translators: Button of a marker's row in the audio editor's list that gives the marker a name.
        String(localized: "Rename")
    }

    /// The button that deletes a marker.
    static var deleteButton: String {
        // Translators: Button of a marker's row in the audio editor's list that deletes the marker.
        String(localized: "Delete")
    }

    /// The button that closes a list.
    static var closeButton: String {
        // Translators: Button that closes a sheet, such as the audio editor's list of markers.
        String(localized: "Close")
    }

    /// The button that keeps a new name.
    static var saveNameButton: String {
        // Translators: Button that keeps the new name typed for a marker.
        String(localized: "Save Name")
    }

    /// The label of a marker's name field.
    static var nameFieldLabel: String {
        // Translators: Label of the name field of a filter preset or an audio marker.
        String(localized: "Name")
    }

    /// A button of a row's, named with the row's subject, so VoiceOver
    /// tells one row's Delete from the next: "Delete Marker 3".
    static func rowButton(_ title: String, _ subject: String) -> String {
        // Translators: A row button's name with the row's subject, so VoiceOver tells one row's button from the next, such as "Delete Marker 3". %1$@ is the button's name and %2$@ the row's subject.
        String(localized: "\(title) \(subject)")
    }

    // MARK: - Editing

    /// The audio's new length, after an edit: "Now 12 minutes, 27.5 seconds
    /// long."
    static func nowLong(_ duration: TimeInterval) -> String {
        // Translators: Ends the announcement of an edit in the audio editor: the audio's new length. %@ is the length in words.
        String(localized: "Now \(spoken(duration)) long.")
    }

    /// Said when a command would change the audio while another change, a
    /// save, or an export is under way.
    static var stillWorking: String {
        // Translators: Said when an audio editor command would change the audio while another change, a save, or an export is under way.
        String(localized: "Still working on the last change.")
    }

    /// Said when a command other than the punch-in's own is chosen while it
    /// records.
    static var stillRecording: String {
        // Translators: Said when an audio editor command other than the punch-in's own is chosen while a punch-in records.
        String(localized: "Recording. Stop the recording first.")
    }

    /// Said as Cut cuts.
    static func cut(_ length: TimeInterval, now duration: TimeInterval) -> String {
        SentenceWording.joined([
            // Translators: Said as the audio editor's Cut cuts. %@ is the length cut, in words.
            String(localized: "Cut \(spoken(length))."),
            nowLong(duration)
        ])
    }

    /// Said as Copy copies.
    static func copied(_ length: TimeInterval) -> String {
        // Translators: Said as the audio editor's Copy copies the selection. %@ is its length in words.
        String(localized: "Copied \(spoken(length)).")
    }

    /// Said when the selection is too long to copy.
    static var copyTooLong: String {
        // Translators: Said when the selection is too long for the audio editor's Copy.
        String(localized: "Copy at most 10 minutes at a time.")
    }

    /// Said by Paste with nothing cut or copied.
    static var nothingToPaste: String {
        // Translators: Said by the audio editor's Paste when nothing has been cut or copied.
        String(localized: "Nothing has been cut or copied.")
    }

    /// Said by Paste when the audio cut was too long to keep.
    static var cutTooLongToPaste: String {
        // Translators: Said by the audio editor's Paste when the audio cut was too long to keep for pasting.
        String(localized: "Too long to keep for pasting. To move it, paste right after cutting.")
    }

    /// Said when the disk is too full to keep audio for Paste.
    static var diskTooFullToKeepClip: String {
        // Translators: Said when the disk is too full to keep the audio cut or copied in the audio editor for Paste.
        String(localized: "The disk is too full to keep this audio for pasting.")
    }

    /// Said as Paste pastes, at the cursor or over a selection `replaced`
    /// seconds long.
    static func pasted(_ length: TimeInterval, replacing replaced: TimeInterval?, now duration: TimeInterval) -> String {
        let pasted = replaced.map {
            // Translators: Said as the audio editor's Paste pastes over a selection. %1$@ is the length pasted and %2$@ the length of the selection it replaced, both in words.
            String(localized: "Pasted \(spoken(length)) over \(spoken($0)).")
        // Translators: Said as the audio editor's Paste pastes at the cursor. %@ is the length pasted, in words.
        } ?? String(localized: "Pasted \(spoken(length)).")
        return SentenceWording.joined([pasted, nowLong(duration)])
    }

    /// Said as a Paste right after a Cut, at the cut's own place, puts the
    /// audio back.
    static func pastedBack(_ length: TimeInterval) -> String {
        // Translators: Said as a Paste right after a Cut, at the cut's own place, puts the audio back. %@ is its length in words.
        String(localized: "Pasted \(spoken(length)) back where they were cut.")
    }

    /// Said as a Paste right after a Cut moves the audio.
    static func moved(_ length: TimeInterval, to time: TimeInterval) -> String {
        // Translators: Said as a Paste right after a Cut moves the audio. %1$@ is the length moved and %2$@ the time it moved to, both in words.
        String(localized: "Moved \(spoken(length)) to \(spoken(time)).")
    }

    /// Said by Trim to Selection when the selection is all of the audio.
    static var selectionIsEverything: String {
        // Translators: Said by the audio editor's Trim to Selection when the selection is all of the audio.
        String(localized: "The selection is all the audio; nothing to trim.")
    }

    /// Said as Trim to Selection trims.
    static func trimmed(keeping length: TimeInterval) -> String {
        // Translators: Said as the audio editor's Trim to Selection trims. %@ is the length kept, in words.
        String(localized: "Trimmed to the selection: \(spoken(length)) kept.")
    }

    /// The name Undo and Redo give the two trims of a Trim to Selection.
    static var trimToSelectionName: String {
        // Translators: Name of an edit, as the Undo and Redo menu items say it after "Undo" or "Redo": the audio editor's Trim to Selection, which trims the start and the end together.
        String(localized: "Trim to Selection")
    }

    /// Said as silence is inserted.
    static func insertedSilence(_ length: TimeInterval, now duration: TimeInterval) -> String {
        SentenceWording.joined([
            // Translators: Said as silence is inserted in the audio editor. %@ is its length in words.
            String(localized: "Inserted \(spoken(length)) of silence."),
            nowLong(duration)
        ])
    }

    /// Said as a chapter marker is set.
    static func chapterSet(_ title: String, at time: TimeInterval) -> String {
        // Translators: Said as a chapter marker is set in the audio editor. %1$@ is its title and %2$@ its time in words.
        String(localized: "Chapter marker “\(title)” set at \(spoken(time)).")
    }

    /// Said as a chapter marker is renamed.
    static func chapterRenamed(_ title: String) -> String {
        // Translators: Said as a chapter marker is renamed in the audio editor. %@ is its new title.
        String(localized: "Chapter marker renamed “\(title)”.")
    }

    /// Said as a chapter marker is removed.
    static func chapterRemoved(_ title: String) -> String {
        // Translators: Said as a chapter marker is removed in the audio editor. %@ is its title.
        String(localized: "Chapter marker “\(title)” removed.")
    }

    /// Undo's button title: "Undo Cut 2.5 Seconds".
    static func undoTitle(_ name: String) -> String {
        // Translators: Title of the audio editor's Undo button. %@ is the name of the edit it would undo, such as "Cut 2.5 Seconds".
        String(localized: "Undo \(name)")
    }

    /// Redo's button title.
    static func redoTitle(_ name: String) -> String {
        // Translators: Title of the audio editor's Redo button. %@ is the name of the edit it would redo, such as "Cut 2.5 Seconds".
        String(localized: "Redo \(name)")
    }

    /// Said as Undo undoes.
    static func undid(_ name: String, now duration: TimeInterval) -> String {
        SentenceWording.joined([
            // Translators: Said as the audio editor's Undo undoes an edit. %@ is the edit's name, such as "Cut 2.5 Seconds".
            String(localized: "Undid \(name)."),
            nowLong(duration)
        ])
    }

    /// Said as Redo redoes.
    static func redid(_ name: String, now duration: TimeInterval) -> String {
        SentenceWording.joined([
            // Translators: Said as the audio editor's Redo redoes an edit. %@ is the edit's name, such as "Cut 2.5 Seconds".
            String(localized: "Redid \(name)."),
            nowLong(duration)
        ])
    }

    /// Said by Redo with nothing undone.
    static var nothingToRedo: String {
        // Translators: Said by the audio editor's Redo when nothing has been undone.
        String(localized: "There's nothing to redo.")
    }

    // MARK: - Insert Silence and Chapter Markers

    /// Insert Silence's sheet title.
    static var insertSilenceTitle: String {
        // Translators: Title of the audio editor's Insert Silence sheet.
        String(localized: "Insert Silence")
    }

    /// Insert Chapter Marker's sheet title.
    static var insertChapterTitle: String {
        // Translators: Title of the audio editor's Insert Chapter Marker sheet.
        String(localized: "Insert Chapter Marker")
    }

    /// The label of the silence's length field.
    static var lengthFieldLabel: String {
        // Translators: Label of the audio editor's field for the length of a silence, and of the audio's length in Audio Info.
        String(localized: "Length")
    }

    /// The label of a chapter marker's title field.
    static var titleFieldLabel: String {
        // Translators: Label of the audio editor's field for a chapter marker's title.
        String(localized: "Title")
    }

    /// What the silence's length field takes.
    static var silenceExplanation: String {
        // Translators: Explains the silence length field of the audio editor's Insert Silence sheet. The examples are typed times.
        String(localized: "Length of silence to insert: seconds (2.5) or minutes and seconds (1:30).")
    }

    /// What the chapter marker's title field takes.
    static var chapterExplanation: String {
        // Translators: Explains the title field of the audio editor's Insert Chapter Marker sheet.
        String(localized: "Title for a chapter marker at the cursor. One already there is renamed.")
    }

    /// The button that inserts.
    static var insertButton: String {
        // Translators: Button of the audio editor's Insert Silence and Insert Chapter Marker sheets that makes the insertion.
        String(localized: "Insert")
    }

    /// Why a silence of no length can't be inserted.
    static var silenceTooShort: String {
        // Translators: Problem shown when the silence to insert in the audio editor has no length.
        String(localized: "Silence must be longer than zero.")
    }

    /// Why a silence of more than a day can't be inserted.
    static var silenceTooLong: String {
        // Translators: Problem shown when the silence to insert in the audio editor is longer than a day.
        String(localized: "Silence can last at most a day.")
    }

    /// Why a blank title can't be a chapter marker's.
    static var chapterNeedsTitle: String {
        // Translators: Problem shown when the title of a chapter marker to insert in the audio editor is blank.
        String(localized: "A chapter marker needs a title.")
    }

    /// The title Insert Chapter Marker offers: "Chapter 4".
    static func defaultChapterTitle(_ number: Int) -> String {
        chapterSubject(number)
    }

    /// The heading of the chapter markers in the list.
    static var chaptersHeading: String {
        // Translators: Heading of the chapter markers in the audio editor's list.
        String(localized: "Chapter Markers")
    }

    /// The button that removes a chapter marker.
    static var removeButton: String {
        // Translators: Button of a chapter marker's row in the audio editor's list that removes the chapter marker.
        String(localized: "Remove")
    }

    /// A chapter marker's row in the list: "Chapter 3: Tide Tables, at 12
    /// minutes, 4 seconds".
    static func chapterRow(_ number: Int, title: String, at time: TimeInterval) -> String {
        // Translators: A chapter marker's row in the audio editor's list. %1$@ is the chapter's number, an identifier written without digit grouping, %2$@ its title, and %3$@ its time in words.
        String(localized: "Chapter \(String(number)): \(title), at \(spoken(time))")
    }

    /// A chapter marker as its row's buttons and title field name it:
    /// "Chapter 3".
    static func chapterSubject(_ number: Int) -> String {
        // Translators: A chapter as the audio editor's list, its row's buttons, and the default title of a new chapter marker name it. %@ is the chapter's number, an identifier written without digit grouping.
        String(localized: "Chapter \(String(number))")
    }

    // MARK: - Punch In

    /// Punch In's title while it records.
    static var stopRecordingTitle: String {
        // Translators: Title of the audio editor's Punch In button while it records.
        String(localized: "Stop Recording")
    }

    /// The microphone pop-up's label.
    static var microphoneLabel: String {
        // Translators: Label of the pop-up in the audio editor that chooses the microphone Punch In records from.
        String(localized: "Microphone for Punch In")
    }

    /// The microphone pop-up's hint.
    static var microphoneHint: String {
        // Translators: Hint of the audio editor's microphone pop-up. "Record window" is TextMouth's window that records audio.
        String(localized: "The microphone Punch In records from. TextMouth remembers it, apart from macOS's input.")
    }

    /// Shown in the microphone pop-up with none connected.
    static var noMicrophoneItem: String {
        // Translators: Shown in the audio editor's microphone pop-up when no microphone is connected.
        String(localized: "No microphone")
    }

    /// Said by Punch In with no microphone connected.
    static var noMicrophone: String {
        // Translators: Said by the audio editor's Punch In when no microphone is connected.
        String(localized: "No microphone is connected. Connect one to punch in.")
    }

    /// Said before the count-in: what will be recorded, from where, and how
    /// it ends.
    static func punchInStarting(_ punch: AudioEditorPunchIn) -> String {
        guard let range = punch.range else {
            // Translators: Said before the audio editor's Punch In records at the cursor. %1$@ is the cursor's time in words and %2$@ the microphone's name. "Punch In", "Stop" and "Clear Selection" are the names of controls.
            return String(localized: "Recording to insert at \(spoken(punch.place)), from \(punch.microphone), after the beep. Punch In or Stop ends it; Clear Selection discards it.")
        }
        // Translators: Said before the audio editor's Punch In records over a selection. %1$@ is the selection's length in words, %2$@ its start in words, and %3$@ the microphone's name. "Punch In", "Stop" and "Clear Selection" are the names of controls.
        return String(localized: "Recording over \(spoken(range.duration)) at \(spoken(punch.place)), from \(punch.microphone), after the beep. Punch In or Stop ends it; Clear Selection discards it.")
    }

    /// The status line's part while a punch-in gets ready.
    static var punchInStartingStatus: String {
        // Translators: A part of the audio editor's status line while a punch-in gets ready to record.
        String(localized: "Getting ready to record")
    }

    /// The status line's part while a punch-in records: the time recorded
    /// and the level.
    static func punchInStatus(elapsed: TimeInterval, level: String) -> String {
        // Translators: A part of the audio editor's status line while a punch-in records. %1$@ is the time recorded, in words, and %2$@ the input level.
        String(localized: "Recording, \(spoken(elapsed)), level \(level)")
    }

    /// Said as a take under way is discarded.
    static var punchInDiscarded: String {
        // Translators: Said as a punch-in recording under way is discarded in the audio editor.
        String(localized: "Recording discarded.")
    }

    /// Said as a take replaces the selection.
    static func punchedIn(_ length: TimeInterval, replacing replaced: TimeInterval, now duration: TimeInterval) -> String {
        SentenceWording.joined([
            // Translators: Said as a punch-in recording replaces the selection in the audio editor. %1$@ is the length replaced and %2$@ the length of the new recording, both in words.
            String(localized: "Replaced \(spoken(replaced)) with \(spoken(length)) of new recording, which is selected."),
            nowLong(duration)
        ])
    }

    /// Said as a take is inserted at the cursor.
    static func recordingInserted(_ length: TimeInterval, now duration: TimeInterval) -> String {
        SentenceWording.joined([
            // Translators: Said as a punch-in recording is inserted at the cursor in the audio editor. %@ is its length in words.
            String(localized: "Inserted \(spoken(length)) of new recording, which is selected."),
            nowLong(duration)
        ])
    }

    // MARK: - Apply Filter

    /// Apply Filter's sheet title.
    static var filterTitle: String {
        // Translators: Name of an edit, as the Undo and Redo menu items say it after "Undo" or "Redo"; also the title of the audio editor's filter sheet.
        String(localized: "Apply Filter")
    }

    /// The preset pop-up's label.
    static var presetLabel: String {
        // Translators: Label of the pop-up in the audio editor's Apply Filter sheet that chooses a filter preset.
        String(localized: "Filter")
    }

    /// The label of the line showing a preset's chain.
    static var chainLabel: String {
        // Translators: Label of the field that holds a filter preset's chain of filters, and of the line that shows it in the audio editor's Apply Filter.
        String(localized: "Chain")
    }

    /// The label of the choice of what to filter.
    static var applyToLabel: String {
        // Translators: Label of the choice in the audio editor's Apply Filter sheet of what to filter: the selection or the whole file.
        String(localized: "Apply to")
    }

    /// The button that plays the processed sound.
    static var previewButton: String {
        // Translators: Button of the audio editor's Apply Filter sheet that plays the filtered sound.
        String(localized: "Preview")
    }

    /// The button that stops a preview.
    static var stopPreviewButton: String {
        // Translators: Button of the audio editor's Apply Filter sheet that stops the preview.
        String(localized: "Stop Preview")
    }

    /// The button that applies the filter.
    static var applyButton: String {
        // Translators: Button of the audio editor's Apply Filter sheet that applies the filter.
        String(localized: "Apply")
    }

    /// Shown when there are no presets.
    static var noPresets: String {
        // Translators: Shown in the audio editor's Apply Filter sheet when there are no filter presets. "Storage settings" and "Audio Editing" are the names of a settings tab and its group.
        String(localized: "No filter presets. Add some in Storage settings, under Audio Editing.")
    }

    /// How the choice of what to filter names `target`.
    static func targetTitle(_ target: AudioEditorFilterTarget) -> String {
        switch target {
        case .selection:
            // Translators: Choice in the audio editor's Apply Filter sheet: filter the selected stretch of the audio.
            return String(localized: "Selection")
        case .wholeFile:
            // Translators: Choice in the audio editor's Apply Filter sheet: filter all of the audio.
            return String(localized: "Whole File")
        }
    }

    /// Said as a preview begins.
    static func previewingFilter(_ name: String) -> String {
        // Translators: Said as a filter preview begins in the audio editor. %@ is the filter preset's name.
        String(localized: "Previewing \(name).")
    }

    /// Said as Apply previews first, as "Preview filters before applying"
    /// asks.
    static func previewingBeforeApplying(_ name: String) -> String {
        // Translators: Said as the audio editor's Apply plays a preview first, because the Preview filters before applying setting is on. %@ is the filter preset's name. "Apply" is the name of the button.
        String(localized: "Previewing \(name) first. Choose Apply again to apply it.")
    }

    /// Apply's hint while a press would preview first
    /// (`AudioEditorModel.applyWouldPreview`).
    static var applyPreviewsFirstHint: String {
        // Translators: Hint of the audio editor's Apply button while a press would play a preview first.
        String(localized: "Plays a preview; choose Apply again to apply.")
    }

    /// Apply's hint while a press applies.
    static var applyHint: String {
        // Translators: Hint of the audio editor's Apply button while a press applies the filter.
        String(localized: "Applies the filter.")
    }

    /// Said when there is nothing after the cursor to preview.
    static var nothingToPreview: String {
        // Translators: Said when the audio editor has no audio after the cursor to preview a filter on.
        String(localized: "There's no audio after the cursor to preview.")
    }

    /// Said as a filter begins.
    static func applyingFilter(_ name: String) -> String {
        // Translators: Said as a filter begins to be applied in the audio editor. %@ is the filter preset's name.
        String(localized: "Applying \(name).")
    }

    /// Said as a filter has been applied, to a selection `length` seconds
    /// long, or to the whole file for nil.
    static func appliedFilter(_ name: String, to length: TimeInterval?, now duration: TimeInterval) -> String {
        let applied = length.map {
            // Translators: Said as a filter has been applied to a selection in the audio editor. %1$@ is the filter preset's name and %2$@ the selection's length in words.
            String(localized: "Applied \(name) to \(spoken($0)).")
        // Translators: Said as a filter has been applied to the whole audio in the audio editor. %@ is the filter preset's name.
        } ?? String(localized: "Applied \(name) to all of the audio.")
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
        // Translators: Said by the audio editor's Save when there is nothing to save.
        String(localized: "Nothing to save: the book's audio holds every edit.")
    }

    /// The save's sheet title.
    static var savingTitle: String {
        // Translators: Title of the sheet shown while the audio editor saves the edits into the book.
        String(localized: "Saving")
    }

    /// What a save writes, said as it begins and shown in its sheet.
    static func savingDetail(_ duration: TimeInterval, format: String?) -> String {
        guard let format else {
            // Translators: Said as the audio editor begins to save, and shown in its sheet. %@ is the audio's length in words.
            return String(localized: "Saving \(spoken(duration)) of audio into the book.")
        }
        // Translators: Said as the audio editor begins to save, and shown in its sheet. %1$@ is the audio's length in words and %2$@ the name of the file format the book keeps, such as "M4A (AAC)".
        return String(localized: "Saving \(spoken(duration)) of audio as \(format), the format this book keeps.")
    }

    /// Said when a save or an export writes a format with no place for
    /// chapter markers: "WAV files can't hold chapter markers, so its 3
    /// chapter markers are left out of this file."
    static func chaptersLeftOut(_ count: Int, format: String) -> String {
        // Translators: Said when a save or an export writes a file format that has no place for chapter markers. %1$@ is the format's name, such as "WAV", and %2$lld the number of chapter markers left out.
        String(localized: "\(format) files can't hold chapter markers, so its \(count) chapter markers are left out of this file.")
    }

    /// Said when a save writes the book's file in a format whose markers
    /// TextMouth writes but never reads back as a book's chapters (a CAF
    /// file's, FMT11): "TextMouth doesn't read chapter markers back from CAF
    /// files, so this book won't list its 3 chapter markers once saved."
    static func chaptersNotReadBack(_ count: Int, format: String) -> String {
        // Translators: Said when a save writes the book's file in a format whose chapter markers TextMouth writes but never reads back as the book's chapters. %1$@ is the format's name, such as "CAF", and %2$lld the number of chapter markers.
        String(localized: "TextMouth doesn't read chapter markers back from \(format) files, so this book won't list its \(count) chapter markers once saved.")
    }

    /// Said after a save or an export whose audio was written but whose
    /// chapter markers could not be (FMT11): "Its 3 chapter markers couldn't
    /// be written into the file, so it has none."
    static func chapterMarkersNotWritten(_ count: Int) -> String {
        // Translators: Said after a save or an export whose audio was written but whose chapter markers could not be. %lld is the number of chapter markers.
        String(localized: "Its \(count) chapter markers couldn't be written into the file, so it has none.")
    }

    /// Said as a save ends: the new length, and a new file name when the
    /// format's extension changed it.
    static func saved(_ duration: TimeInterval, renamedTo file: String?) -> String {
        // Translators: Said as the audio editor's save ends. %@ is the book's new audio length in words.
        let saved = String(localized: "Saved. The book's audio is now \(spoken(duration)) long.")
        guard let file else { return saved }
        return SentenceWording.joined([
            saved,
            // Translators: Said as a save ends and the book's file got a new name because TextMouth can't write the old format. %@ is the file's new name.
            String(localized: "Its file is now “\(file)”, since TextMouth can't write its old format.")
        ])
    }

    /// Said when a save fails.
    static func saveFailed(_ reason: String) -> String {
        SentenceWording.joined([
            // Translators: Said when the audio editor's save fails. A sentence giving the reason follows.
            String(localized: "The edits couldn't be saved."),
            reason
        ])
    }

    /// The export's sheet title while it runs.
    static var exportingTitle: String {
        // Translators: Title of the sheet shown while the audio editor exports the audio.
        String(localized: "Exporting")
    }

    /// What an export writes, said as it begins and shown in its sheet.
    static func exportingDetail(_ duration: TimeInterval, format: String, file: String) -> String {
        // Translators: Said as the audio editor begins to export, and shown in its sheet. %1$@ is the audio's length in words, %2$@ the file format's name, and %3$@ the exported file's name.
        String(localized: "Exporting \(spoken(duration)) of audio as \(format) to “\(file)”.")
    }

    /// Said as an export ends.
    static func exported(file: String) -> String {
        // Translators: Said as the audio editor's export ends. %@ is the exported file's name.
        String(localized: "Exported “\(file)”.")
    }

    /// Said as an export ends that wrote its label file beside the audio
    /// (FMT06).
    static func exported(file: String, labels: String) -> String {
        // Translators: Said as the audio editor's export ends having written a label file beside the audio. %1$@ is the audio file's name and %2$@ the label file's name.
        String(localized: "Exported “\(file)” and its labels, “\(labels)”.")
    }

    /// Said as an export ends whose audio was written but whose label file
    /// could not be, for `reason`.
    static func exported(file: String, labelsFailed reason: String) -> String {
        SentenceWording.joined([
            // Translators: Said as the audio editor's export ends having written the audio but not the label file. %@ is the audio file's name. A sentence giving the reason follows.
            String(localized: "Exported “\(file)”, but its labels couldn't be written."),
            reason
        ])
    }

    /// The Export Audio checkbox that writes the markers as labels too, and
    /// its hint (FMT06).
    static var exportLabelsToggle: String {
        // Translators: Label of the checkbox in the audio editor's Export Audio sheet that writes the markers as a label file too. Audacity is the name of an audio editing program.
        String(localized: "Also write the markers as Audacity labels")
    }

    static var exportLabelsHint: String {
        // Translators: Hint of the Also write the markers as Audacity labels checkbox. Audacity is the name of an audio editing program.
        String(localized: "Writes chapter markers and markers beside the audio, in an Audacity label file of the same name.")
    }

    /// The checkbox's hint while the audio has no marker of either kind to
    /// write.
    static var exportLabelsNothingHint: String {
        // Translators: Hint of the Also write the markers as Audacity labels checkbox while the audio has no markers of either kind.
        String(localized: "No chapter markers or markers, so no label file would be written.")
    }

    /// Said as an export ends that was asked for labels but had no marker to
    /// write.
    static func exportedWithoutLabels(file: String) -> String {
        // Translators: Said as the audio editor's export ends when labels were asked for but the audio has no marker. %@ is the exported file's name.
        String(localized: "Exported “\(file)”. It has no markers, so no label file was written.")
    }

    /// Said when an export fails.
    static func exportFailed(_ reason: String) -> String {
        SentenceWording.joined([
            // Translators: Said when the audio editor's export fails. A sentence giving the reason follows.
            String(localized: "The audio couldn't be exported."),
            reason
        ])
    }

    /// Said at each quarter of a long save or export.
    static func percentDone(_ percent: Int) -> String {
        // Translators: Said at each quarter of a long save or export in the audio editor. %lld is how much is done, from 0 to 100.
        String(localized: "\(percent) percent")
    }

    /// The label of the progress bar.
    static var progressLabel: String {
        // Translators: Label of the progress bar of a save or an export in the audio editor.
        String(localized: "Progress")
    }

    /// Export's sheet title.
    static var exportTitle: String {
        // Translators: Title of the audio editor's Export Audio sheet.
        String(localized: "Export Audio")
    }

    /// The format pop-up's label.
    static var formatLabel: String {
        // Translators: Label of the pop-up in the audio editor's Export Audio sheet that chooses the file format.
        String(localized: "Format")
    }

    /// The button that asks where to export to.
    static var exportButton: String {
        // Translators: Button of the audio editor's Export Audio sheet that asks where to save the file.
        String(localized: "Export…")
    }

    /// What Export… does.
    static var exportButtonHint: String {
        // Translators: Hint of the audio editor's Export… button.
        String(localized: "Exports to a file you choose; the book's own file is unchanged.")
    }

    // MARK: - Reverting

    /// Revert's confirmation question.
    static var revertQuestion: String {
        // Translators: Question of the confirmation shown before the audio editor's Revert to Original.
        String(localized: "Revert to the original audio?")
    }

    /// What reverting does, with how many edits it undoes and how many
    /// markers it deletes.
    static func revertExplanation(_ count: Int, markers: Int = 0) -> String {
        // Translators: Explains the audio editor's Revert to Original confirmation: how many edits it undoes. %lld is the number of edits.
        let undone = String(localized: "\(count) edits are undone. Redo brings them back until you make another edit.")
        guard markers > 0 else { return undone }
        return SentenceWording.joined([
            undone,
            // Translators: Explains the audio editor's Revert to Original confirmation: how many markers it deletes. %lld is the number of markers.
            String(localized: "The \(markers) markers are deleted, and Redo doesn't bring them back.")
        ])
    }

    /// The button that reverts.
    static var revertButton: String {
        // Translators: Button of the audio editor's Revert to Original confirmation that reverts.
        String(localized: "Revert")
    }

    /// Said as Revert to Original ends, having undone `count` edits and
    /// deleted `markers` markers.
    static func reverted(_ count: Int, markers: Int = 0) -> String {
        // Translators: Said as the audio editor's Revert to Original ends. %lld is the number of edits undone, which Redo brings back.
        let reverted = String(localized: "Reverted to the original audio. Redo brings back the \(count) edits.")
        guard markers > 0 else { return reverted }
        return SentenceWording.joined([
            reverted,
            // Translators: Said as the audio editor's Revert to Original ends having deleted markers. %lld is the number of markers deleted.
            String(localized: "The \(markers) markers are deleted.")
        ])
    }

    /// Said by Revert to Original with nothing to undo.
    static var nothingToRevert: String {
        // Translators: Said by the audio editor's Revert to Original when no edit can be undone.
        String(localized: "Nothing to revert: no edit can be undone.")
    }

    /// Said by Revert to Original when no original is kept.
    static var revertNoOriginal: String {
        // Translators: Said by the audio editor's Revert to Original when the book keeps no original audio.
        String(localized: "No original is kept, so it can't be reverted. Undo takes back edits since the last save.")
    }

    // MARK: - Audio Info

    /// Audio Info's sheet title.
    static var infoTitle: String {
        // Translators: Title of the audio editor's Audio Info sheet.
        String(localized: "Audio Info")
    }

    /// The labels of Audio Info's facts.
    static var lengthLabel: String {
        // Translators: Label of the audio editor's field for the length of a silence, and of the audio's length in Audio Info.
        String(localized: "Length")
    }

    static var fileLabel: String {
        // Translators: Label of the audio file's name in the audio editor's Audio Info sheet.
        String(localized: "File")
    }

    static var savedAsLabel: String {
        // Translators: Label of the file format the book's audio is saved as, in the audio editor's Audio Info sheet.
        String(localized: "Saved as")
    }

    static var editsLabel: String {
        // Translators: Label of the number of edits made, in the audio editor's Audio Info sheet.
        String(localized: "Edits")
    }

    static var originalLabel: String {
        // Translators: Label of whether the original audio is kept, in the audio editor's Audio Info sheet.
        String(localized: "Original audio")
    }

    /// The original policy pop-up's label.
    static var policyLabel: String {
        // Translators: Label of the pop-up in the audio editor's Audio Info sheet that sets what happens to this book's original audio.
        String(localized: "Original audio for this book")
    }

    /// The policy pop-up's first choice: the global setting, named.
    static func useGlobal(_ global: AudioOriginalPolicy) -> String {
        // Translators: The first choice of the Audio Info pop-up for a book's original audio: follow the global setting. %@ is that setting's name, such as "Keep".
        String(localized: "Use the global setting (\(AudioEditingSettingsWording.choiceTitle(global.choice)))")
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
                // Translators: The edits as the audio editor's Audio Info says them: there are none, and the work is not saved.
                ? String(localized: "No edits, not saved")
                // Translators: The edits as the audio editor's Audio Info says them: there are none.
                : String(localized: "No edits")
        }
        return unsaved
            // Translators: The edits as the audio editor's Audio Info says them. %lld is the number of edits.
            ? String(localized: "\(count) edits, not all saved")
            // Translators: The edits as the audio editor's Audio Info says them. %lld is the number of edits.
            : String(localized: "\(count) edits, all saved")
    }

    /// Whether the original is kept, as Audio Info says it.
    static func originalStatus(kept: Bool, deletedAt: Date?) -> String {
        if kept {
            // Translators: The original audio's state in the audio editor's Audio Info sheet: it is kept.
            return String(localized: "Kept")
        }
        if let deletedAt {
            // Translators: The original audio's state in the audio editor's Audio Info sheet. %@ is the date it was deleted, in long form.
            return String(localized: "Deleted on \(deletedAt.formatted(date: .long, time: .omitted))")
        }
        // Translators: The original audio's state in the audio editor's Audio Info sheet: it is not kept.
        return String(localized: "Not kept")
    }

    /// Said as the book's own policy changes: what it does now.
    static func policyChanged(_ policy: AudioOriginalPolicy?, global: AudioOriginalPolicy) -> String {
        switch policy {
        case nil:
            return SentenceWording.joined([
                // Translators: Said as a book's original audio policy is set to follow the global setting. A sentence saying what that setting does follows.
                String(localized: "This book follows the global setting now."),
                AudioEditingSettingsWording.explanation(global)
            ])
        case .keep?:
            // Translators: Said as a book's original audio policy is set to keep the original until the book is removed.
            return String(localized: "This book keeps its original audio until the book is removed.")
        case .delete?:
            // Translators: Said as a book's original audio policy is set to keep no original.
            return String(localized: "This book keeps no original audio: saved edits change its audio in place, and can't be undone after.")
        case .deleteAfter(let days)?:
            // Translators: Said as a book's original audio policy is set to keep the original for a number of days. %lld is the number of days.
            return String(localized: "This book keeps its original audio for \(Int(days.rounded())) days after it was saved or last edited.")
        }
    }

    // MARK: - Closing

    /// The question asked as a window with unsaved edits closes.
    static func closeQuestion(book: String) -> String {
        // Translators: Question asked as the audio editor's window with unsaved edits closes. %@ is the book's title.
        String(localized: "Save the edits to “\(book)”?")
    }

    /// What its answers do.
    static var closeExplanation: String {
        // Translators: Explains the question asked as the audio editor's window with unsaved edits closes: what Discard does.
        String(localized: "Not in the book's audio yet. Discard undoes them; next time you edit this book, Redo brings them back until you make another edit.")
    }

    /// The close question's buttons.
    static var saveButton: String {
        // Translators: Button that saves what a sheet or window edited, such as a filter preset or the audio editor's edits.
        String(localized: "Save")
    }

    static var discardButton: String {
        // Translators: Button of the audio editor's close question that undoes the unsaved edits.
        String(localized: "Discard")
    }

    /// Said when the window can't close while work is under way.
    static var closeWhileWorking: String {
        // Translators: Said when the audio editor's window can't close because a change, save, or export is under way.
        String(localized: "Still working. Close once the change is done.")
    }

    /// Said when the window can't close while a punch-in records.
    static var closeWhileRecording: String {
        // Translators: Said when the audio editor's window can't close because a punch-in records. "Clear Selection" is the name of a command.
        String(localized: "Recording. Stop or discard it with Clear Selection, then close.")
    }

    /// Said when Discard can't reach the audio as saved.
    static var discardKept: String {
        // Translators: Said when the audio editor's Discard can't reach the audio as it was saved: the edits stay.
        String(localized: "The book's audio holds edits its history lost, so they stay, to save or undo next time you edit this book.")
    }

    // MARK: - Quitting

    /// What the question about an editor's unsaved edits explains as
    /// TextMouth quits.
    static var quitExplanation: String {
        // Translators: Explains the question about the audio editor's unsaved edits asked as TextMouth quits: what Discard and Cancel do.
        String(localized: "TextMouth is quitting and the book's audio doesn't hold these edits yet. Discard undoes them; next time you edit this book, Redo brings them back until you make another edit. Cancel keeps TextMouth open.")
    }

    /// Said, in the editor of `book`, when TextMouth can't quit while its
    /// work is under way.
    static func quitWhileWorking(book: String) -> String {
        // Translators: Said in an audio editor when TextMouth can't quit because its work is under way. %@ is the book's title.
        String(localized: "“\(book)” is still working. Quit once the change is done.")
    }

    /// Said, in the editor of `book`, when TextMouth can't quit while a
    /// punch-in records there.
    static func quitWhileRecording(book: String) -> String {
        // Translators: Said in an audio editor when TextMouth can't quit because a punch-in records there. %@ is the book's title. "Clear Selection" is the name of a command.
        String(localized: "“\(book)” is recording. Stop or discard it with Clear Selection, then quit.")
    }

    // MARK: - The Commands

    /// The names of the editor's groups of buttons, as headings.
    static var listenHeading: String {
        // Translators: Heading of the audio editor's buttons for listening and moving the cursor.
        String(localized: "Listen and Move")
    }

    /// The heading of the selection's and the markers' buttons.
    static var selectHeading: String {
        // Translators: Heading of the audio editor's buttons for the selection and the markers.
        String(localized: "Select and Mark")
    }

    /// The heading of the editing buttons.
    static var editHeading: String {
        // Translators: Button of the track question that opens the audio editor on the track chosen, and the heading of the audio editor's editing buttons.
        String(localized: "Edit")
    }

    /// The heading of the saving buttons.
    static var fileHeading: String {
        // Translators: Heading of the audio editor's buttons for saving and exporting.
        String(localized: "Save and Export")
    }

    /// What `action`'s button does, as its hint says, before its shortcut;
    /// empty for an action that isn't the editor's.
    static func explanation(of action: ShortcutAction) -> String {
        switch action {
        case .editorPlayPause:
            // Translators: Hint of the audio editor's Play or Pause button.
            return String(localized: "Plays from the cursor, or pauses.")
        case .editorStop:
            // Translators: Hint of the audio editor's Stop button.
            return String(localized: "Stops playing, and goes back to where playing began.")
        case .editorSkipBack:
            // Translators: Hint of the audio editor's Skip Back button.
            return String(localized: "Moves the cursor back one second.")
        case .editorSkipForward:
            // Translators: Hint of the audio editor's Skip Forward button.
            return String(localized: "Moves the cursor forward one second.")
        case .editorSkipBackLong:
            // Translators: Hint of the audio editor's Skip Back Long button.
            return String(localized: "Moves the cursor back ten seconds.")
        case .editorSkipForwardLong:
            // Translators: Hint of the audio editor's Skip Forward Long button.
            return String(localized: "Moves the cursor forward ten seconds.")
        case .editorSkipBackShort:
            // Translators: Hint of the audio editor's Skip Back Short button.
            return String(localized: "Moves the cursor back a tenth of a second.")
        case .editorSkipForwardShort:
            // Translators: Hint of the audio editor's Skip Forward Short button.
            return String(localized: "Moves the cursor forward a tenth of a second.")
        case .editorGoToStart:
            // Translators: Hint of the audio editor's Go to Start button.
            return String(localized: "Moves the cursor to the start of the audio.")
        case .editorGoToEnd:
            // Translators: Hint of the audio editor's Go to End button.
            return String(localized: "Moves the cursor to the end of the audio.")
        case .editorGoToTime:
            // Translators: Hint of the audio editor's Go to Time button.
            return String(localized: "Moves the cursor to a time you type.")
        case .editorPreviousChapter:
            // Translators: Hint of the audio editor's Previous Chapter button.
            return String(localized: "Moves the cursor to the previous chapter marker.")
        case .editorNextChapter:
            // Translators: Hint of the audio editor's Next Chapter button.
            return String(localized: "Moves the cursor to the next chapter marker.")
        case .editorPreviousPause:
            // Translators: Hint of the audio editor's Previous Pause button.
            return String(localized: "Moves the cursor to the end of the previous pause.")
        case .editorNextPause:
            // Translators: Hint of the audio editor's Next Pause button.
            return String(localized: "Moves the cursor to the end of the next pause.")
        case .editorWhereAmI:
            // Translators: Hint of the audio editor's Where Am I button.
            return String(localized: "Says where the cursor is, in which chapter, and what is selected.")
        case .editorMarkIn:
            // Translators: Hint of the audio editor's Mark In button.
            return String(localized: "Marks the selection's start at the cursor.")
        case .editorMarkOut:
            // Translators: Hint of the audio editor's Mark Out button.
            return String(localized: "Marks the selection's end at the cursor.")
        case .editorSelectToPreviousPause:
            // Translators: Hint of the audio editor's Select to Previous Pause button.
            return String(localized: "Selects from the end of the previous pause to the cursor.")
        case .editorSelectToNextPause:
            // Translators: Hint of the audio editor's Select to Next Pause button.
            return String(localized: "Selects from the cursor to the end of the next pause.")
        case .editorSelectChapter:
            // Translators: Hint of the audio editor's Select Chapter button.
            return String(localized: "Selects the chapter the cursor is in.")
        case .editorSelectAll:
            // Translators: Hint of the audio editor's Select All button.
            return String(localized: "Selects all of the audio.")
        case .editorClearSelection:
            // Translators: Hint of the audio editor's Clear Selection button.
            return String(localized: "Clears the selection.")
        case .editorSpeakSelection:
            // Translators: Hint of the audio editor's Speak Selection button.
            return String(localized: "Says where the selection starts and ends, and how long it is.")
        case .editorPlaySelection:
            // Translators: Hint of the audio editor's Play Selection button.
            return String(localized: "Plays the selection, and stops at its end.")
        case .editorAddMarker:
            // Translators: Hint of the audio editor's Add Marker button.
            return String(localized: "Drops a marker at the cursor, even while the audio plays.")
        case .editorShowMarkers:
            // Translators: Hint of the audio editor's Show Markers button.
            return String(localized: "Lists markers, chapter markers, and pauses, to go to, name, select, or delete.")
        case .editorUndo:
            // Translators: Hint of the audio editor's Undo button.
            return String(localized: "Undoes the newest edit.")
        case .editorRedo:
            // Translators: Hint of the audio editor's Redo button.
            return String(localized: "Redoes the edit undone last.")
        case .editorCut:
            // Translators: Hint of the audio editor's Cut button. "Paste" is the name of a command.
            return String(localized: "Cuts the selection out, and keeps it for Paste.")
        case .editorCopy:
            // Translators: Hint of the audio editor's Copy button. "Paste" is the name of a command.
            return String(localized: "Copies the selection for Paste.")
        case .editorPaste:
            // Translators: Hint of the audio editor's Paste button.
            return String(localized: "Pastes at the cursor, or over the selection. Right after a cut, it moves the audio.")
        case .editorTrimToSelection:
            // Translators: Hint of the audio editor's Trim to Selection button.
            return String(localized: "Keeps only the selection.")
        case .editorInsertSilence:
            // Translators: Hint of the audio editor's Insert Silence button.
            return String(localized: "Inserts a silence of a length you type at the cursor.")
        case .editorInsertChapter:
            // Translators: Hint of the audio editor's Insert Chapter Marker button.
            return String(localized: "Sets a chapter marker at the cursor, with a title you type.")
        case .editorApplyFilter:
            // Translators: Hint of the audio editor's Apply Filter button.
            return String(localized: "Runs a filter preset over the selection or the whole file.")
        case .editorPunchIn:
            // Translators: Hint of the audio editor's Punch In button. "Stop" is the name of a button.
            return String(localized: "Records over the selection, or at the cursor, after a beep. Again, or Stop, ends it.")
        case .editorSave:
            // Translators: Hint of the audio editor's Save button.
            return String(localized: "Saves the edits into the book's audio file, in the format the book keeps.")
        case .editorExport:
            // Translators: Hint of the audio editor's Export button.
            return String(localized: "Exports to a file outside the library, in a format you choose.")
        case .editorRevert:
            // Translators: Hint of the audio editor's Revert to Original button. "Redo" is the name of a command.
            return String(localized: "Undoes every edit, back to the original; Redo brings them back.")
        case .editorInfo:
            // Translators: Hint of the audio editor's Audio Info button.
            return String(localized: "Shows length, file, and edits; sets what happens to the original audio.")
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
            // Translators: Ends a button's hint in the audio editor when its command has no keyboard shortcut.
            return String(localized: "No shortcut.")
        }
        // The keys are named in the region's own list style: "J or Comma",
        // and "J, Comma, or Period" in English.
        let names = bindings.map(\.accessibleDisplayString).formatted(.list(type: .or, width: .standard))
        return bindings.count == 1
            // Translators: Ends a button's hint in the audio editor: the command's one keyboard shortcut. %@ is the key's name such as "Shift + J".
            ? String(localized: "Shortcut: \(names).")
            // Translators: Ends a button's hint in the audio editor: the command's keyboard shortcuts. %@ is their names as a list, such as "J or Comma".
            : String(localized: "Shortcuts: \(names).")
    }
}
