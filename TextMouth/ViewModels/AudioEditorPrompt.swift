import Foundation

/// A sheet over the audio editor window (FR04). One shows at a time, so a
/// sheet never opens over another, and VoiceOver always knows where it is.
enum AudioEditorSheet: Identifiable, Equatable {
    /// A question with one text field.
    case prompt(AudioEditorPrompt)
    /// The list of markers, chapter markers, and pauses, each with its
    /// commands.
    case markers
    /// Apply Filter: the presets, what to apply one to, Preview, and Apply.
    case filter
    /// A save or an export under way, and how far it is.
    case progress
    /// Export: the formats, then where to export to.
    case export
    /// Audio Info: the audio, its edits, and its original audio policy.
    case info

    /// Tells sheets apart.
    var id: String {
        switch self {
        case .prompt(let prompt): return "prompt-\(prompt.id)"
        case .markers: return "markers"
        case .filter: return "filter"
        case .progress: return "progress"
        case .export: return "export"
        case .info: return "info"
        }
    }
}

/// A question the audio editor asks in a sheet with one text field (FR04):
/// a time to go to, a length of silence, or a chapter marker's title. The
/// sheet shows the question's title, labels its field, explains what to
/// type, and says what's wrong with an answer without closing, so the
/// answer can be corrected where it was typed.
enum AudioEditorPrompt: Identifiable, Equatable {
    /// Go to Time: where to move the cursor.
    case goToTime
    /// Insert Silence: how long a silence to insert at the cursor.
    case insertSilence
    /// Insert Chapter Marker: the title of a marker at the cursor.
    case insertChapter

    /// Tells sheets apart.
    var id: String {
        switch self {
        case .goToTime: return "goToTime"
        case .insertSilence: return "insertSilence"
        case .insertChapter: return "insertChapter"
        }
    }

    /// The sheet's title, its heading.
    var title: String {
        switch self {
        case .goToTime: return AudioEditorWording.goToTimeTitle
        case .insertSilence: return AudioEditorWording.insertSilenceTitle
        case .insertChapter: return AudioEditorWording.insertChapterTitle
        }
    }

    /// The field's label.
    var fieldLabel: String {
        switch self {
        case .goToTime: return AudioEditorWording.timeFieldLabel
        case .insertSilence: return AudioEditorWording.lengthFieldLabel
        case .insertChapter: return AudioEditorWording.titleFieldLabel
        }
    }

    /// What to type, said by the field's hint and shown under it.
    var explanation: String {
        switch self {
        case .goToTime: return TimeEntry.howToType
        case .insertSilence: return AudioEditorWording.silenceExplanation
        case .insertChapter: return AudioEditorWording.chapterExplanation
        }
    }

    /// The button that takes the answer.
    var actionTitle: String {
        switch self {
        case .goToTime: return AudioEditorWording.goButton
        case .insertSilence, .insertChapter: return AudioEditorWording.insertButton
        }
    }
}
