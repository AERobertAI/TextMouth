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

    // MARK: - The Selection

    /// The selection as the status line says it, in clock times, which a
    /// braille display shows in few cells: "selection from 11:58 to
    /// 12:04.3, 6.3 seconds".
    static func selectionPart(_ range: AudioTimeRange) -> String {
        "selection from \(clock(range.start)) to \(clock(range.end)), \(spoken(range.duration))"
    }

    /// The selection said in full, in words, as Speak Selection says it.
    static func selectionSentence(_ range: AudioTimeRange) -> String {
        "Selection from \(spoken(range.start)) to \(spoken(range.end)); \(spoken(range.duration)) long."
    }

    /// Said as a selection is made: how long it is.
    static func selected(_ range: AudioTimeRange) -> String {
        "Selected \(spoken(range.duration))."
    }

    /// Said as In is marked, with the selection it makes, if any.
    static func markedIn(at time: TimeInterval, selection: AudioTimeRange?) -> String {
        "In at \(spoken(time)).\(selection.map { " " + selected($0) } ?? "")"
    }

    /// Said as Out is marked, with the selection it makes, if any.
    static func markedOut(at time: TimeInterval, selection: AudioTimeRange?) -> String {
        "Out at \(spoken(time)).\(selection.map { " " + selected($0) } ?? "")"
    }

    /// Said as Select Chapter selects a chapter.
    static func selectedChapter(number: Int, title: String, length: TimeInterval) -> String {
        "Selected chapter \(number): \(title), \(spoken(length))."
    }

    /// Said as Select Chapter selects the audio before the first marker.
    static func selectedBeforeFirstChapter(_ length: TimeInterval) -> String {
        "Selected the \(spoken(length)) before chapter 1."
    }

    /// Said as Select All selects everything.
    static func selectedAll(_ duration: TimeInterval) -> String {
        "Selected all \(spoken(duration))."
    }

    /// Said when a command needs a selection and there is none.
    static let noSelection = "Nothing is selected."

    /// Said as the selection is cleared.
    static let selectionCleared = "Selection cleared."

    // MARK: - Markers

    /// A marker as the list and the announcements name it: "Marker 3" or
    /// "Marker 3, Intro".
    static func markerName(_ number: Int, named name: String) -> String {
        name.isEmpty ? "Marker \(number)" : "Marker \(number), \(name)"
    }

    /// Said as a marker is dropped.
    static func markerAdded(_ number: Int, at time: TimeInterval) -> String {
        "Marker \(number) at \(spoken(time))."
    }

    /// Said as the cursor goes to a marker, and its row's label.
    static func marker(_ number: Int, named name: String, at time: TimeInterval) -> String {
        "\(markerName(number, named: name)), at \(spoken(time))."
    }

    /// Said as a marker is named, or its name taken away.
    static func markerRenamed(_ number: Int, named name: String) -> String {
        name.isEmpty ? "Marker \(number) has no name now." : "Marker \(number) named \(name)."
    }

    /// Said as a marker is deleted.
    static func markerDeleted(_ number: Int, named name: String) -> String {
        "\(markerName(number, named: name)) deleted."
    }

    /// A pause's row in the list: "Pause 2, 1.3 seconds, at 1 minute, 4.2
    /// seconds".
    static func pauseRow(_ number: Int, _ pause: AudioEditorPause) -> String {
        "Pause \(number), \(spoken(pause.duration)), at \(spoken(pause.start))"
    }

    /// The marker list's title.
    static let markersTitle = "Markers and Pauses"
    /// The heading of the markers in the list.
    static let markersHeading = "Markers"
    /// The heading of the pauses in the list.
    static let pausesHeading = "Pauses"
    /// Shown when no marker has been dropped.
    static let noMarkers = "No markers yet. Add Marker drops one at the cursor, even while the audio plays."
    /// Shown when the audio has no pauses.
    static let noPauses = "No pauses were found."
    /// The button that goes to a marker or a pause.
    static let goToButton = "Go To"
    /// The button that selects a pause.
    static let selectButton = "Select"
    /// The button that names a marker.
    static let renameButton = "Rename"
    /// The button that deletes a marker.
    static let deleteButton = "Delete"
    /// The button that closes a list.
    static let closeButton = "Close"
    /// The button that keeps a new name.
    static let saveNameButton = "Save Name"
    /// The label of a marker's name field.
    static let nameFieldLabel = "Name"

    /// A button of a row's, named with the row's subject, so VoiceOver
    /// tells one row's Delete from the next: "Delete Marker 3".
    static func rowButton(_ title: String, _ subject: String) -> String {
        "\(title) \(subject)"
    }

    // MARK: - Editing

    /// The audio's new length, after an edit: "Now 12 minutes, 27.5 seconds
    /// long."
    static func nowLong(_ duration: TimeInterval) -> String {
        "Now \(spoken(duration)) long."
    }

    /// Said when a command would change the audio while another change, a
    /// save, or an export is under way.
    static let stillWorking = "Still working on the last change."

    /// Said when a command other than the punch-in's own is chosen while it
    /// records.
    static let stillRecording = "Recording. Stop the recording first."

    /// Said as Cut cuts.
    static func cut(_ length: TimeInterval, now duration: TimeInterval) -> String {
        "Cut \(spoken(length)). \(nowLong(duration))"
    }

    /// Said as Copy copies.
    static func copied(_ length: TimeInterval) -> String {
        "Copied \(spoken(length))."
    }

    /// Said when the selection is too long to copy.
    static let copyTooLong = "Copy at most 10 minutes at a time."

    /// Said by Paste with nothing cut or copied.
    static let nothingToPaste = "Nothing has been cut or copied."

    /// Said by Paste when the audio cut was too long to keep.
    static let cutTooLongToPaste = "The audio cut was too long to keep for pasting. To move a long stretch, paste right after cutting it."

    /// Said when the disk is too full to keep audio for Paste.
    static let diskTooFullToKeepClip = "The disk is too full to keep this audio for pasting."

    /// Said as Paste pastes, at the cursor or over a selection `replaced`
    /// seconds long.
    static func pasted(_ length: TimeInterval, replacing replaced: TimeInterval?, now duration: TimeInterval) -> String {
        guard let replaced else { return "Pasted \(spoken(length)). \(nowLong(duration))" }
        return "Pasted \(spoken(length)) over \(spoken(replaced)). \(nowLong(duration))"
    }

    /// Said as a Paste right after a Cut, at the cut's own place, puts the
    /// audio back.
    static func pastedBack(_ length: TimeInterval) -> String {
        "Pasted \(spoken(length)) back where they were cut."
    }

    /// Said as a Paste right after a Cut moves the audio.
    static func moved(_ length: TimeInterval, to time: TimeInterval) -> String {
        "Moved \(spoken(length)) to \(spoken(time))."
    }

    /// Said by Trim to Selection when the selection is all of the audio.
    static let selectionIsEverything = "The selection is all of the audio, so there's nothing to trim."

    /// Said as Trim to Selection trims.
    static func trimmed(keeping length: TimeInterval) -> String {
        "Trimmed to the selection: \(spoken(length)) kept."
    }

    /// The name Undo and Redo give the two trims of a Trim to Selection.
    static let trimToSelectionName = "Trim to Selection"

    /// Said as silence is inserted.
    static func insertedSilence(_ length: TimeInterval, now duration: TimeInterval) -> String {
        "Inserted \(spoken(length)) of silence. \(nowLong(duration))"
    }

    /// Said as a chapter marker is set.
    static func chapterSet(_ title: String, at time: TimeInterval) -> String {
        "Chapter marker “\(title)” set at \(spoken(time))."
    }

    /// Said as a chapter marker is renamed.
    static func chapterRenamed(_ title: String) -> String {
        "Chapter marker renamed “\(title)”."
    }

    /// Said as a chapter marker is removed.
    static func chapterRemoved(_ title: String) -> String {
        "Chapter marker “\(title)” removed."
    }

    /// Undo's button title: "Undo Cut 2.5 Seconds".
    static func undoTitle(_ name: String) -> String {
        "Undo \(name)"
    }

    /// Redo's button title.
    static func redoTitle(_ name: String) -> String {
        "Redo \(name)"
    }

    /// Said as Undo undoes.
    static func undid(_ name: String, now duration: TimeInterval) -> String {
        "Undid \(name). \(nowLong(duration))"
    }

    /// Said as Redo redoes.
    static func redid(_ name: String, now duration: TimeInterval) -> String {
        "Redid \(name). \(nowLong(duration))"
    }

    /// Said by Redo with nothing undone.
    static let nothingToRedo = "There's nothing to redo."

    // MARK: - Insert Silence and Chapter Markers

    /// Insert Silence's sheet title.
    static let insertSilenceTitle = "Insert Silence"
    /// Insert Chapter Marker's sheet title.
    static let insertChapterTitle = "Insert Chapter Marker"
    /// The label of the silence's length field.
    static let lengthFieldLabel = "Length"
    /// The label of a chapter marker's title field.
    static let titleFieldLabel = "Title"
    /// What the silence's length field takes.
    static let silenceExplanation = "How long a silence to insert at the cursor: seconds, such as 2.5, or minutes and seconds, such as 1:30."
    /// What the chapter marker's title field takes.
    static let chapterExplanation = "The title of a chapter marker at the cursor. A chapter marker already at the cursor is renamed."
    /// The button that inserts.
    static let insertButton = "Insert"
    /// Why a silence of no length can't be inserted.
    static let silenceTooShort = "Silence has to last longer than no time at all."
    /// Why a silence of more than a day can't be inserted.
    static let silenceTooLong = "Silence can last at most a day."
    /// Why a blank title can't be a chapter marker's.
    static let chapterNeedsTitle = "A chapter marker needs a title."

    /// The title Insert Chapter Marker offers: "Chapter 4".
    static func defaultChapterTitle(_ number: Int) -> String {
        "Chapter \(number)"
    }

    /// The heading of the chapter markers in the list.
    static let chaptersHeading = "Chapter Markers"
    /// The button that removes a chapter marker.
    static let removeButton = "Remove"

    /// A chapter marker's row in the list: "Chapter 3: Tide Tables, at 12
    /// minutes, 4 seconds".
    static func chapterRow(_ number: Int, title: String, at time: TimeInterval) -> String {
        "Chapter \(number): \(title), at \(spoken(time))"
    }

    // MARK: - Punch In

    /// Punch In's title while it records.
    static let stopRecordingTitle = "Stop Recording"

    /// The microphone pop-up's label.
    static let microphoneLabel = "Microphone for Punch In"

    /// The microphone pop-up's hint.
    static let microphoneHint = "The microphone Punch In records from. TextMouth remembers it, as the Record window does, "
        + "apart from the input macOS uses for everything else."

    /// Shown in the microphone pop-up with none connected.
    static let noMicrophoneItem = "No microphone"

    /// Said by Punch In with no microphone connected.
    static let noMicrophone = "No microphone is connected. Connect one to punch in."

    /// Said before the count-in: what will be recorded, from where, and how
    /// it ends.
    static func punchInStarting(_ punch: AudioEditorPunchIn) -> String {
        let what = punch.range.map { "Recording over \(spoken($0.duration)) at \(spoken(punch.place))" }
            ?? "Recording to insert at \(spoken(punch.place))"
        return "\(what), from \(punch.microphone), after the beep. Punch In or Stop ends it; Clear Selection discards it."
    }

    /// The status line's part while a punch-in gets ready.
    static let punchInStartingStatus = "Getting ready to record"

    /// The status line's part while a punch-in records: the time recorded
    /// and the level.
    static func punchInStatus(elapsed: TimeInterval, level: String) -> String {
        "Recording, \(spoken(elapsed)), level \(level)"
    }

    /// Said as a take under way is discarded.
    static let punchInDiscarded = "Recording discarded."

    /// Said as a take replaces the selection.
    static func punchedIn(_ length: TimeInterval, replacing replaced: TimeInterval, now duration: TimeInterval) -> String {
        "Replaced \(spoken(replaced)) with \(spoken(length)) of new recording, which is selected. \(nowLong(duration))"
    }

    /// Said as a take is inserted at the cursor.
    static func recordingInserted(_ length: TimeInterval, now duration: TimeInterval) -> String {
        "Inserted \(spoken(length)) of new recording, which is selected. \(nowLong(duration))"
    }

    // MARK: - Apply Filter

    /// Apply Filter's sheet title.
    static let filterTitle = "Apply Filter"
    /// The preset pop-up's label.
    static let presetLabel = "Filter"
    /// The label of the line showing a preset's chain.
    static let chainLabel = "Chain"
    /// The label of the choice of what to filter.
    static let applyToLabel = "Apply to"
    /// The button that plays the processed sound.
    static let previewButton = "Preview"
    /// The button that stops a preview.
    static let stopPreviewButton = "Stop Preview"
    /// The button that applies the filter.
    static let applyButton = "Apply"
    /// Shown when there are no presets.
    static let noPresets = "There are no filter presets. Add some in Storage settings, under Audio Editing."

    /// How the choice of what to filter names `target`.
    static func targetTitle(_ target: AudioEditorFilterTarget) -> String {
        switch target {
        case .selection: return "Selection"
        case .wholeFile: return "Whole File"
        }
    }

    /// Said as a preview begins.
    static func previewingFilter(_ name: String) -> String {
        "Previewing \(name)."
    }

    /// Said as Apply previews first, as "Preview filters before applying"
    /// asks.
    static func previewingBeforeApplying(_ name: String) -> String {
        "Previewing \(name) first. Choose Apply again to apply it."
    }

    /// Apply's hint with the preview first.
    static let applyPreviewsFirstHint = "Plays the filtered audio first; choose Apply again to apply the filter."

    /// Apply's hint without it.
    static let applyHint = "Applies the filter."

    /// Said when there is nothing after the cursor to preview.
    static let nothingToPreview = "There's no audio after the cursor to preview."

    /// Said as a filter begins.
    static func applyingFilter(_ name: String) -> String {
        "Applying \(name)."
    }

    /// Said as a filter has been applied, to a selection `length` seconds
    /// long, or to the whole file for nil.
    static func appliedFilter(_ name: String, to length: TimeInterval?, now duration: TimeInterval) -> String {
        let what = length.map { spoken($0) } ?? "all of the audio"
        return "Applied \(name) to \(what). \(nowLong(duration))"
    }

    // MARK: - Saving and Exporting

    /// A format a save or an export writes, by name: the name Export lists
    /// it by (`AudioExportFormat.title`), but for MP3, whose name there says
    /// what it needs.
    static func formatName(_ format: AudioRenderFormat) -> String {
        switch format {
        case .aacM4A: return "M4A (AAC)"
        case .aacM4B: return "M4B Audiobook (AAC)"
        case .alacM4A: return "Apple Lossless (M4A)"
        case .pcmCAF: return "CAF"
        case .pcmWAV: return "WAV"
        case .pcmAIFF: return "AIFF"
        case .mp3: return "MP3"
        }
    }

    /// Said by Save with nothing to save.
    static let nothingToSave = "There's nothing to save: the book's audio already holds every edit."

    /// The save's sheet title.
    static let savingTitle = "Saving"

    /// What a save writes, said as it begins and shown in its sheet.
    static func savingDetail(_ duration: TimeInterval, format: String?) -> String {
        guard let format else { return "Saving \(spoken(duration)) of audio into the book." }
        return "Saving \(spoken(duration)) of audio as \(format), the format this book keeps."
    }

    /// Said when a save or an export writes a format with no place for
    /// chapter markers: "WAV files can't hold chapter markers, so its 3
    /// chapter markers are left out of this file."
    static func chaptersLeftOut(_ count: Int, format: String) -> String {
        let markers = count == 1 ? "its chapter marker is" : "its \(count) chapter markers are"
        return "\(format) files can't hold chapter markers, so \(markers) left out of this file."
    }

    /// Said as a save ends: the new length, and a new file name when the
    /// format's extension changed it.
    static func saved(_ duration: TimeInterval, renamedTo file: String?) -> String {
        let saved = "Saved. The book's audio is now \(spoken(duration)) long."
        guard let file else { return saved }
        return "\(saved) Its file is now “\(file)”, since TextMouth can't write its old format."
    }

    /// Said when a save fails.
    static func saveFailed(_ reason: String) -> String {
        "The edits couldn't be saved. \(reason)"
    }

    /// The export's sheet title while it runs.
    static let exportingTitle = "Exporting"

    /// What an export writes, said as it begins and shown in its sheet.
    static func exportingDetail(_ duration: TimeInterval, format: String, file: String) -> String {
        "Exporting \(spoken(duration)) of audio as \(format) to “\(file)”."
    }

    /// Said as an export ends.
    static func exported(file: String) -> String {
        "Exported “\(file)”."
    }

    /// Said when an export fails.
    static func exportFailed(_ reason: String) -> String {
        "The audio couldn't be exported. \(reason)"
    }

    /// Said at each quarter of a long save or export.
    static func percentDone(_ percent: Int) -> String {
        "\(percent) percent"
    }

    /// The label of the progress bar.
    static let progressLabel = "Progress"

    /// Export's sheet title.
    static let exportTitle = "Export Audio"
    /// The format pop-up's label.
    static let formatLabel = "Format"
    /// The button that asks where to export to.
    static let exportButton = "Export…"
    /// What Export… does.
    static let exportButtonHint = "Asks where to save the file, then writes it. The book's own file stays as it is."

    // MARK: - Reverting

    /// Revert's confirmation question.
    static let revertQuestion = "Revert to the original audio?"

    /// What reverting does, with how many edits it undoes and how many
    /// markers it deletes.
    static func revertExplanation(_ count: Int, markers: Int = 0) -> String {
        let undone = "\(CountWording.phrase(count, singular: "edit is", plural: "edits are")) undone. Redo brings them back until you make another edit."
        switch markers {
        case 0: return undone
        case 1: return undone + " The marker is deleted, and Redo doesn't bring it back."
        default: return undone + " The \(markers) markers are deleted, and Redo doesn't bring them back."
        }
    }

    /// The button that reverts.
    static let revertButton = "Revert"

    /// Said as Revert to Original ends, having undone `count` edits and
    /// deleted `markers` markers.
    static func reverted(_ count: Int, markers: Int = 0) -> String {
        let reverted = "Reverted to the original audio. Redo brings back the \(CountWording.phrase(count, singular: "edit", plural: "edits"))."
        switch markers {
        case 0: return reverted
        case 1: return reverted + " The marker is deleted."
        default: return reverted + " The \(markers) markers are deleted."
        }
    }

    /// Said by Revert to Original with nothing to undo.
    static let nothingToRevert = "There's nothing to revert: no edit can be undone."

    /// Said by Revert to Original when no original is kept.
    static let revertNoOriginal = "No original audio is kept for this book, so it can't be reverted. "
        + "Undo takes back the edits made since it was last saved."

    // MARK: - Audio Info

    /// Audio Info's sheet title.
    static let infoTitle = "Audio Info"
    /// The labels of Audio Info's facts.
    static let lengthLabel = "Length"
    static let fileLabel = "File"
    static let savedAsLabel = "Saved as"
    static let editsLabel = "Edits"
    static let originalLabel = "Original audio"
    /// The original policy pop-up's label.
    static let policyLabel = "Original audio for this book"

    /// The policy pop-up's first choice: the global setting, named.
    static func useGlobal(_ global: AudioOriginalPolicy) -> String {
        "Use the global setting (\(AudioEditingSettingsWording.choiceTitle(global.choice)))"
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
        guard count > 0 else { return unsaved ? "No edits, not saved" : "No edits" }
        return "\(CountWording.phrase(count, singular: "edit", plural: "edits")), \(unsaved ? "not all saved" : "all saved")"
    }

    /// Whether the original is kept, as Audio Info says it.
    static func originalStatus(kept: Bool, deletedAt: Date?) -> String {
        if kept { return "Kept" }
        if let deletedAt { return "Deleted on \(deletedAt.formatted(date: .long, time: .omitted))" }
        return "Not kept"
    }

    /// Said as the book's own policy changes: what it does now.
    static func policyChanged(_ policy: AudioOriginalPolicy?, global: AudioOriginalPolicy) -> String {
        switch policy {
        case nil:
            return "This book follows the global setting now. \(AudioEditingSettingsWording.explanation(global))"
        case .keep?:
            return "This book keeps its original audio until the book is removed."
        case .delete?:
            return "This book keeps no original audio: saved edits change its audio in place, and can't be undone after."
        case .deleteAfter(let days)?:
            return "This book keeps its original audio for \(AudioEditingSettingsWording.days(Int(days.rounded()))) "
                + "after it was saved or last edited."
        }
    }

    // MARK: - Closing

    /// The question asked as a window with unsaved edits closes.
    static func closeQuestion(book: String) -> String {
        "Save the edits to “\(book)”?"
    }

    /// What its answers do.
    static let closeExplanation = "The book's audio doesn't hold them yet. Discard undoes them; the next time you edit "
        + "this book, Redo brings them back until you make another edit."

    /// The close question's buttons.
    static let saveButton = "Save"
    static let discardButton = "Discard"

    /// Said when the window can't close while work is under way.
    static let closeWhileWorking = "The editor is still working. Close it once the change is done."

    /// Said when the window can't close while a punch-in records.
    static let closeWhileRecording = "A recording is under way. Stop it, or discard it with Clear Selection, then close the editor."

    /// Said when Discard can't reach the audio as saved.
    static let discardKept = "The book's audio holds edits its history no longer has, so the edits stay, "
        + "to be saved or undone the next time you edit this book."

    // MARK: - Quitting

    /// What the question about an editor's unsaved edits explains as
    /// TextMouth quits.
    static let quitExplanation = "TextMouth is quitting, and the book's audio doesn't hold these edits yet. Discard undoes them; "
        + "the next time you edit this book, Redo brings them back until you make another edit. Cancel keeps TextMouth open."

    /// Said, in the editor of `book`, when TextMouth can't quit while its
    /// work is under way.
    static func quitWhileWorking(book: String) -> String {
        "The editor of “\(book)” is still working. Quit TextMouth once the change is done."
    }

    /// Said, in the editor of `book`, when TextMouth can't quit while a
    /// punch-in records there.
    static func quitWhileRecording(book: String) -> String {
        "A recording is under way in the editor of “\(book)”. Stop it, or discard it with Clear Selection, then quit TextMouth."
    }

    // MARK: - The Commands

    /// The names of the editor's groups of buttons, as headings.
    static let listenHeading = "Listen and Move"
    /// The heading of the selection's and the markers' buttons.
    static let selectHeading = "Select and Mark"
    /// The heading of the editing buttons.
    static let editHeading = "Edit"
    /// The heading of the saving buttons.
    static let fileHeading = "Save and Export"

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
        case .editorMarkIn: return "Marks the selection's start at the cursor."
        case .editorMarkOut: return "Marks the selection's end at the cursor."
        case .editorSelectToPreviousPause:
            return "Selects from where the sound after the previous pause begins to the cursor."
        case .editorSelectToNextPause:
            return "Selects from the cursor to where the sound after the next pause begins."
        case .editorSelectChapter: return "Selects the chapter the cursor is in."
        case .editorSelectAll: return "Selects all of the audio."
        case .editorClearSelection: return "Clears the selection."
        case .editorSpeakSelection: return "Says where the selection starts and ends, and how long it is."
        case .editorPlaySelection: return "Plays the selection, and stops at its end."
        case .editorAddMarker: return "Drops a marker at the cursor, even while the audio plays."
        case .editorShowMarkers:
            return "Lists the markers, the chapter markers, and the pauses, to go to, name, select, or delete them."
        case .editorUndo: return "Undoes the newest edit."
        case .editorRedo: return "Redoes the edit undone last."
        case .editorCut: return "Cuts the selection out, and keeps it for Paste."
        case .editorCopy: return "Copies the selection for Paste."
        case .editorPaste:
            return "Pastes the audio cut or copied at the cursor, or over the selection. Right after a cut, it moves the audio cut."
        case .editorTrimToSelection: return "Keeps only the selection, removing the audio before and after it."
        case .editorInsertSilence: return "Inserts a silence of a length you type at the cursor."
        case .editorInsertChapter: return "Sets a chapter marker at the cursor, with a title you type."
        case .editorApplyFilter: return "Runs a filter preset over the selection or the whole file, with a preview first."
        case .editorPunchIn:
            return "Records from the microphone over the selection, or at the cursor, after a beep. Again, or Stop, ends it."
        case .editorSave: return "Saves the edits into the book's audio file, in the format the book keeps."
        case .editorExport: return "Exports the edited audio to a file outside the library, in a format you choose."
        case .editorRevert: return "Undoes every edit, back to the original audio; Redo brings them back."
        case .editorInfo:
            return "Shows the audio's length, file, and edits, and sets what happens to this book's original audio."
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
