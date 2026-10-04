import Foundation

// MARK: - The Editor's Commands (FR04)

/// Where every command arrives, however it was chosen: a button, its
/// shortcut, or VoiceOver. Each editor action of the shortcut manager's
/// "Audio Editor" group is one command here, and the questions the
/// commands ask in a sheet are answered here too.
extension AudioEditorModel {
    /// Performs the editor command `action`; an action that isn't the
    /// editor's does nothing.
    func perform(_ action: ShortcutAction) {
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
        default: break
        }
    }

    /// Whether `action` can act now, so its button is dimmed when it can't.
    /// A command that would only say why it can't stays available, so it
    /// says so: the shortcut does the same.
    func canPerform(_ action: ShortcutAction) -> Bool {
        switch action {
        case .editorStop:
            return isPlaying
        case .editorClearSelection, .editorPlaySelection:
            return selection != nil
        default:
            return action.scope == .audioEditor
        }
    }

    // MARK: Questions

    /// Asks `prompt`'s question in a sheet.
    func ask(_ prompt: AudioEditorPrompt) {
        self.prompt = prompt
    }

    /// The text `prompt`'s field starts with.
    func initialText(for prompt: AudioEditorPrompt) -> String {
        switch prompt {
        case .goToTime:
            return AudioEditorWording.clock(cursor)
        }
    }

    /// Takes `text` as the answer to `prompt`; returns the sentence saying
    /// what's wrong with it, which VoiceOver hears too, or nil once done,
    /// when the sheet closes.
    func answer(_ prompt: AudioEditorPrompt, with text: String) -> String? {
        let problem: String?
        switch prompt {
        case .goToTime:
            problem = goToTime(typed: text)
        }
        if let problem {
            announce(problem)
        } else if self.prompt == prompt {
            sheet = nil
        }
        return problem
    }
}
