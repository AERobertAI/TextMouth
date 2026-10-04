import Foundation

// MARK: - The Editor's Commands (FR04)

/// Where every command arrives, however it was chosen: a button, its
/// shortcut, or VoiceOver. Each editor action of the shortcut manager's
/// "Audio Editor" group is one command here, and the questions the
/// commands ask in a sheet are answered here too. While a punch-in records,
/// only the commands that end it, discard it, or say where it is act, so
/// nothing else plays into the microphone or changes the audio under it.
extension AudioEditorModel {
    /// Performs the editor command `action`; an action that isn't the
    /// editor's does nothing.
    func perform(_ action: ShortcutAction) {
        if punchIn != nil {
            return performWhileRecording(action)
        }
        switch action {
        // Listening and moving.
        case .editorPlayPause: togglePlay()
        case .editorStop: stop()
        case .editorSkipBack: skip(by: -1)
        case .editorSkipForward: skip(by: 1)
        case .editorSkipBackLong: skip(by: -10)
        case .editorSkipForwardLong: skip(by: 10)
        case .editorSkipBackShort: skip(by: -0.1)
        case .editorSkipForwardShort: skip(by: 0.1)
        case .editorGoToStart: goToStart()
        case .editorGoToEnd: goToEnd()
        case .editorGoToTime: ask(.goToTime)
        case .editorPreviousChapter: previousChapter()
        case .editorNextChapter: nextChapter()
        case .editorPreviousPause: previousPause()
        case .editorNextPause: nextPause()
        case .editorWhereAmI: whereAmI()
        // Selecting and markers.
        case .editorMarkIn: markIn()
        case .editorMarkOut: markOut()
        case .editorSelectToPreviousPause: selectToPreviousPause()
        case .editorSelectToNextPause: selectToNextPause()
        case .editorSelectChapter: selectChapter()
        case .editorSelectAll: selectAll()
        case .editorClearSelection: clearSelection()
        case .editorSpeakSelection: speakSelection()
        case .editorPlaySelection: playSelection()
        case .editorAddMarker: addMarker()
        case .editorShowMarkers: sheet = .markers
        // Editing.
        case .editorUndo: Task { await undo() }
        case .editorRedo: Task { await redo() }
        case .editorCut: Task { await cut() }
        case .editorCopy: Task { await copy() }
        case .editorPaste: Task { await paste() }
        case .editorTrimToSelection: Task { await trimToSelection() }
        case .editorInsertSilence: ask(.insertSilence)
        case .editorInsertChapter: ask(.insertChapter)
        case .editorApplyFilter: openFilters()
        case .editorPunchIn: Task { await togglePunchIn() }
        default: break
        }
    }

    /// Performs `action` while a punch-in records: Stop, Play/Pause, and
    /// Punch In end it, keeping the take; Clear Selection discards it;
    /// Where Am I says where it is; anything else says to stop first.
    private func performWhileRecording(_ action: ShortcutAction) {
        switch action {
        case .editorStop, .editorPlayPause, .editorPunchIn:
            Task { await stopPunchIn() }
        case .editorClearSelection:
            Task { await cancelPunchIn() }
        case .editorWhereAmI:
            whereAmI()
        default:
            if action.scope == .audioEditor {
                announce(AudioEditorWording.stillRecording)
            }
        }
    }

    /// Opens Apply Filter, unless other work is under way.
    func openFilters() {
        guard !isWorking else { return announce(AudioEditorWording.stillWorking) }
        sheet = .filter
    }

    /// Whether `action` can act now, so its button is dimmed when it can't:
    /// the commands that need a selection, or something to paste, without
    /// one; every command that changes the audio while other work is under
    /// way; everything but the commands that end a punch-in while one
    /// records. A command that would only say why it can't, such as Undo
    /// with nothing to undo, stays available, so it says so.
    func canPerform(_ action: ShortcutAction) -> Bool {
        guard action.scope == .audioEditor else { return false }
        if punchIn != nil {
            return [.editorStop, .editorPlayPause, .editorPunchIn, .editorClearSelection, .editorWhereAmI].contains(action)
        }
        switch action {
        case .editorStop:
            return isPlaying || playing == .previewing
        case .editorClearSelection, .editorPlaySelection:
            return selection != nil
        case .editorCut, .editorCopy, .editorTrimToSelection:
            return selection != nil && !isWorking
        case .editorPaste:
            return clip != nil && !isWorking
        case .editorUndo, .editorRedo, .editorInsertSilence, .editorInsertChapter, .editorApplyFilter, .editorPunchIn:
            return !isWorking
        default:
            return true
        }
    }

    /// What `action`'s button is titled: Undo and Redo name what they
    /// would undo or redo, and Punch In says Stop Recording while it
    /// records.
    func title(for action: ShortcutAction) -> String {
        switch action {
        case .editorUndo:
            return undoName.map(AudioEditorWording.undoTitle) ?? action.title
        case .editorRedo:
            return redoName.map(AudioEditorWording.redoTitle) ?? action.title
        case .editorPunchIn where punchIn != nil:
            return AudioEditorWording.stopRecordingTitle
        default:
            return action.title
        }
    }

    /// What `action`'s button's hint says: what it does, its shortcuts, and,
    /// for an Undo that can't, why.
    func hint(for action: ShortcutAction) -> String {
        let hint = AudioEditorWording.hint(for: action, bindings: bindings(for: action))
        if action == .editorUndo, !session.canUndo, let reason = session.undoLimitExplanation {
            return "\(hint) \(reason)"
        }
        return hint
    }

    // MARK: Questions

    /// Asks `prompt`'s question in a sheet.
    func ask(_ prompt: AudioEditorPrompt) {
        if prompt != .goToTime, isWorking {
            return announce(AudioEditorWording.stillWorking)
        }
        self.prompt = prompt
    }

    /// The text `prompt`'s field starts with.
    func initialText(for prompt: AudioEditorPrompt) -> String {
        switch prompt {
        case .goToTime:
            return AudioEditorWording.clock(cursor)
        case .insertSilence:
            return "1"
        case .insertChapter:
            // The title of a marker already here, which the answer renames;
            // otherwise the next chapter's number.
            if let here = chapters.first(where: { abs($0.start - cursor) < Self.timeTolerance }) {
                return here.title
            }
            let before = chapters.filter { $0.start < cursor }.count
            return AudioEditorWording.defaultChapterTitle(before + 1)
        }
    }

    /// Takes `text` as the answer to `prompt`; returns the sentence saying
    /// what's wrong with it, which VoiceOver hears too, or nil once taken,
    /// when the sheet closes and an edit asked for begins.
    func answer(_ prompt: AudioEditorPrompt, with text: String) -> String? {
        let problem: String?
        switch prompt {
        case .goToTime:
            problem = goToTime(typed: text)
        case .insertSilence:
            problem = silenceLength(typed: text).problem
            if problem == nil, let seconds = silenceLength(typed: text).seconds {
                Task { await insertSilence(seconds) }
            }
        case .insertChapter:
            let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            problem = title.isEmpty ? AudioEditorWording.chapterNeedsTitle : nil
            if problem == nil {
                Task { await insertChapter(titled: title) }
            }
        }
        if let problem {
            announce(problem)
        } else if self.prompt == prompt {
            sheet = nil
        }
        return problem
    }

    /// The length of silence `text` names, or what's wrong with it: a time
    /// of more than none and at most a day.
    private func silenceLength(typed text: String) -> (seconds: TimeInterval?, problem: String?) {
        switch AudioEditorTimeEntry.reading(text) {
        case .problem(let sentence):
            return (nil, sentence)
        case .seconds(let seconds):
            guard seconds > 0 else { return (nil, AudioEditorWording.silenceTooShort) }
            guard seconds <= AudioEditTimeline.longestInsertion else { return (nil, AudioEditorWording.silenceTooLong) }
            return (seconds, nil)
        }
    }
}
