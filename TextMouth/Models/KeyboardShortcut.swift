import AppKit

/// All actions that can have keyboard shortcuts
enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case togglePlayback = "Play / Pause"
    case skipForward = "Skip Forward"
    case skipBackward = "Skip Backward"
    case increaseSpeed = "Increase Speed"
    case decreaseSpeed = "Decrease Speed"
    case goToLibrary = "Go to Library"
    case goBack = "Go Back"
    case goForward = "Go Forward"
    case nextHeading = "Next Heading"
    case previousHeading = "Previous Heading"
    case addBookmark = "Add Bookmark"
    case nextBookmark = "Next Bookmark"
    case previousBookmark = "Previous Bookmark"
    case whereAmI = "Where Am I?"
    case navigateUpLevel = "Up One Level"
    case openSelectedBook = "Open Selected Book"
    case showBookInfo = "Book Info"
    case removeFromLibrary = "Remove from Library"
    case newFolder = "New Folder"
    case moveToFolder = "Move to Folder"
    case selectAll = "Select All"
    case toggleEditMode = "Edit Mode"
    case moveBookUp = "Move Book Up"
    case moveBookDown = "Move Book Down"

    var id: String { rawValue }

    /// The notification to post when this action is triggered
    var notificationName: Notification.Name {
        switch self {
        case .togglePlayback: return .togglePlayback
        case .skipForward: return .skipForward
        case .skipBackward: return .skipBackward
        case .increaseSpeed: return .increaseSpeed
        case .decreaseSpeed: return .decreaseSpeed
        case .goToLibrary: return .goToLibrary
        case .goBack: return .goBack
        case .goForward: return .goForward
        case .navigateUpLevel: return .navigateUpLevel
        case .nextHeading: return .nextHeading
        case .previousHeading: return .previousHeading
        case .addBookmark: return .addBookmark
        case .nextBookmark: return .nextBookmark
        case .previousBookmark: return .previousBookmark
        case .whereAmI: return .whereAmI
        case .openSelectedBook: return .openSelectedBook
        case .showBookInfo: return .showBookInfo
        case .removeFromLibrary: return .removeFromLibrary
        case .newFolder: return .newFolder
        case .moveToFolder: return .moveToFolder
        case .selectAll: return .selectAll
        case .toggleEditMode: return .toggleEditMode
        case .moveBookUp: return .moveBookUp
        case .moveBookDown: return .moveBookDown
        }
    }

    /// Category for grouping in settings
    var category: String {
        switch self {
        case .togglePlayback, .skipForward, .skipBackward, .increaseSpeed, .decreaseSpeed:
            return "Playback"
        case .goToLibrary, .goBack, .goForward, .navigateUpLevel, .nextHeading, .previousHeading:
            return "Navigation"
        case .addBookmark, .nextBookmark, .previousBookmark:
            return "Bookmarks"
        case .whereAmI:
            return "Information"
        case .openSelectedBook, .showBookInfo, .removeFromLibrary, .newFolder, .moveToFolder, .selectAll, .toggleEditMode, .moveBookUp, .moveBookDown:
            return "Library"
        }
    }
}

/// A keyboard binding: key + modifiers
struct KeyBinding: Codable, Equatable, Hashable {
    /// The key character (lowercased letter) or special key name:
    /// "space", "rightArrow", "leftArrow", "upArrow", "downArrow", "tab",
    /// "return", "delete", "escape", or a single character like "k", "+", "-", "[", "]"
    var key: String
    var command: Bool = false
    var option: Bool = false
    var shift: Bool = false
    var control: Bool = false

    /// Human-readable display string
    var displayString: String {
        var parts: [String] = []
        if control { parts.append("\u{2303}") }      // ⌃
        if option { parts.append("\u{2325}") }        // ⌥
        if shift { parts.append("\u{21E7}") }         // ⇧
        if command { parts.append("\u{2318}") }       // ⌘
        parts.append(keyDisplayName)
        return parts.joined()
    }

    /// Accessible display string using words
    var accessibleDisplayString: String {
        var parts: [String] = []
        if control { parts.append("Control") }
        if option { parts.append("Option") }
        if shift { parts.append("Shift") }
        if command { parts.append("Command") }
        parts.append(keyDisplayName)
        return parts.joined(separator: " + ")
    }

    private var keyDisplayName: String {
        switch key {
        case "space": return "Space"
        case "rightArrow": return "\u{2192}"   // →
        case "leftArrow": return "\u{2190}"    // ←
        case "upArrow": return "\u{2191}"      // ↑
        case "downArrow": return "\u{2193}"    // ↓
        case "tab": return "\u{21E5}"          // ⇥
        case "return": return "\u{21A9}"       // ↩
        case "delete": return "\u{232B}"       // ⌫
        case "escape": return "\u{238B}"       // ⎋
        default: return key.uppercased()
        }
    }

    /// Check if this binding matches an NSEvent
    func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) == command,
              flags.contains(.option) == option,
              flags.contains(.shift) == shift,
              flags.contains(.control) == control else {
            return false
        }
        return matchesKey(event)
    }

    private func matchesKey(_ event: NSEvent) -> Bool {
        switch key {
        case "space":
            return event.keyCode == 49
        case "rightArrow":
            return event.keyCode == 124
        case "leftArrow":
            return event.keyCode == 123
        case "upArrow":
            return event.keyCode == 126
        case "downArrow":
            return event.keyCode == 125
        case "tab":
            return event.keyCode == 48
        case "return":
            return event.keyCode == 36
        case "delete":
            return event.keyCode == 51
        case "escape":
            return event.keyCode == 53
        default:
            // Regular character — case-insensitive comparison
            guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
            return chars == key.lowercased()
        }
    }

    /// Create a KeyBinding from an NSEvent (used in the shortcut recorder)
    static func from(event: NSEvent) -> KeyBinding? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let opt = flags.contains(.option)
        let shft = flags.contains(.shift)
        let ctrl = flags.contains(.control)

        let key: String
        switch event.keyCode {
        case 49: key = "space"
        case 124: key = "rightArrow"
        case 123: key = "leftArrow"
        case 126: key = "upArrow"
        case 125: key = "downArrow"
        case 48: key = "tab"
        case 36: key = "return"
        case 51: key = "delete"
        case 53: key = "escape"
        default:
            guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else {
                return nil
            }
            key = chars
        }

        return KeyBinding(key: key, command: cmd, option: opt, shift: shft, control: ctrl)
    }
}

/// All default keyboard shortcut bindings
extension ShortcutAction {
    /// Default bindings for each action (primary + optional secondary)
    static var defaultBindings: [ShortcutAction: [KeyBinding]] {
        [
            .togglePlayback: [
                KeyBinding(key: "space"),
                KeyBinding(key: "k")
            ],
            .skipForward: [
                KeyBinding(key: "rightArrow", command: true),
                KeyBinding(key: "l")
            ],
            .skipBackward: [
                KeyBinding(key: "leftArrow", command: true),
                KeyBinding(key: "j")
            ],
            .increaseSpeed: [
                KeyBinding(key: "+", command: true)
            ],
            .decreaseSpeed: [
                KeyBinding(key: "-", command: true)
            ],
            .goToLibrary: [
                KeyBinding(key: "l", command: true)
            ],
            .goBack: [
                KeyBinding(key: "[", command: true)
            ],
            .goForward: [
                KeyBinding(key: "]", command: true)
            ],
            .navigateUpLevel: [
                KeyBinding(key: "upArrow", command: true)
            ],
            .nextHeading: [
                KeyBinding(key: "downArrow", command: true, option: true)
            ],
            .previousHeading: [
                KeyBinding(key: "upArrow", command: true, option: true)
            ],
            .addBookmark: [
                KeyBinding(key: "b", command: true)
            ],
            .nextBookmark: [
                KeyBinding(key: "b", command: true, shift: true)
            ],
            .previousBookmark: [
                KeyBinding(key: "b", command: true, option: true)
            ],
            .whereAmI: [
                KeyBinding(key: "w")
            ],
            .openSelectedBook: [
                KeyBinding(key: "return")
            ],
            .showBookInfo: [
                KeyBinding(key: "i", command: true)
            ],
            .removeFromLibrary: [
                KeyBinding(key: "delete", command: true)
            ],
            .newFolder: [
                KeyBinding(key: "n", command: true, shift: true)
            ],
            .moveToFolder: [
                KeyBinding(key: "m", command: true, shift: true)
            ],
            .selectAll: [
                KeyBinding(key: "a", command: true)
            ],
            .toggleEditMode: [
                KeyBinding(key: "e", command: true)
            ],
            .moveBookUp: [
                KeyBinding(key: "upArrow", option: true, control: true)
            ],
            .moveBookDown: [
                KeyBinding(key: "downArrow", option: true, control: true)
            ]
        ]
    }
}
