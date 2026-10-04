import Foundation

/// A question the audio editor asks in a sheet with one text field (FR04):
/// a time to go to. The sheet shows the question's title, labels its field,
/// explains what to type, and says what's wrong with an answer without
/// closing, so the answer can be corrected where it was typed.
enum AudioEditorPrompt: Identifiable, Equatable {
    /// Go to Time: where to move the cursor.
    case goToTime

    /// Tells sheets apart.
    var id: String {
        switch self {
        case .goToTime: return "goToTime"
        }
    }

    /// The sheet's title, its heading.
    var title: String {
        switch self {
        case .goToTime: return AudioEditorWording.goToTimeTitle
        }
    }

    /// The field's label.
    var fieldLabel: String {
        switch self {
        case .goToTime: return AudioEditorWording.timeFieldLabel
        }
    }

    /// What to type, said by the field's hint and shown under it.
    var explanation: String {
        switch self {
        case .goToTime: return AudioEditorTimeEntry.howToType
        }
    }

    /// The button that takes the answer.
    var actionTitle: String {
        switch self {
        case .goToTime: return AudioEditorWording.goButton
        }
    }
}
