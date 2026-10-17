import Foundation

/// How a way of adding to the library runs once chosen: exactly what its menu
/// command runs, so the sheet and the menu cannot drift apart (FR20).
enum AddToLibraryRun: Equatable, Sendable {
    /// Posts this notification, which the library window acts on, as the
    /// command's menu item does.
    case notification(Notification.Name)
    /// Shows the Record window (`RecordingWindowController.shared.show(library:)`),
    /// as File > New Recording… does; it posts no notification.
    case recordingWindow
}

/// One way of adding to the library, as the Add to Library sheet lists it
/// (FR20): each is a menu command of its own, and choosing it does what that
/// menu item does. The cases are in the order the sheet lists them.
///
/// The choices are defined here once. A later "Import from URL…" is one more
/// case: its `action`, its `summary` (in `AddToLibraryWording`), and its
/// `run`, and nothing else, since the sheet, its model, and the toolbar
/// button all walk `allCases`.
enum AddToLibraryChoice: CaseIterable, Identifiable, Equatable, Sendable {
    case openBook
    case importFolder
    case newFromText
    case newRecording
    case addFeed

    var id: Self { self }

    /// The shortcut action whose menu command this choice stands for: its
    /// title, its key, and the windows it works in all come from it.
    var action: ShortcutAction {
        switch self {
        case .openBook: return .openBook
        case .importFolder: return .importDAISYFolder
        case .newFromText: return .newFromText
        case .newRecording: return .newRecording
        case .addFeed: return .addFeed
        }
    }

    /// The choice's words: its action's own title, so the sheet and the menus
    /// say the same thing, and a rename of an action reaches the sheet.
    var title: String { action.title }

    /// One line saying what the choice does, shown under its button and given
    /// as the button's accessibility hint.
    var summary: String { AddToLibraryWording.summary(self) }

    /// What choosing it runs: the same code path its menu item runs.
    var run: AddToLibraryRun {
        switch self {
        case .openBook: return .notification(.openBookFile)
        case .importFolder: return .notification(.importDAISYFolder)
        case .newFromText: return .notification(.newFromText)
        case .newRecording: return .recordingWindow
        case .addFeed: return .notification(.addFeed)
        }
    }
}
