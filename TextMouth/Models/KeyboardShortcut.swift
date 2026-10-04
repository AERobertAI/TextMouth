import AppKit

/// All actions that can have keyboard shortcuts
enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case togglePlayback = "Play / Pause"
    case releaseMediaControls = "Release Media Controls"
    case skipForward = "Skip Forward"
    case skipBackward = "Skip Backward"
    case cycleForwardNavigationUnit = "Cycle Forward Navigation Unit"
    case cycleBackwardNavigationUnit = "Cycle Backward Navigation Unit"
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
    case showHeadingList = "Show Headings"
    case showBookmarkList = "Show Bookmarks"
    case showSleepTimer = "Show Sleep Timer"
    case restartSleepTimer = "Restart Sleep Timer"
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

    // The audio editor's (FR04): a group of their own, matched only while an
    // editor window is key (`ShortcutScope`), so they may share keys with
    // the reader's. Each raw value begins with the group's name, so
    // config.json tells them apart from the reader's actions of the same
    // name; Settings lists them by `title`, under the group's heading.
    case editorPlayPause = "Audio Editor: Play / Pause"
    case editorStop = "Audio Editor: Stop"
    case editorSkipBack = "Audio Editor: Back One Second"
    case editorSkipForward = "Audio Editor: Forward One Second"
    case editorSkipBackLong = "Audio Editor: Back 10 Seconds"
    case editorSkipForwardLong = "Audio Editor: Forward 10 Seconds"
    case editorSkipBackShort = "Audio Editor: Back a Tenth of a Second"
    case editorSkipForwardShort = "Audio Editor: Forward a Tenth of a Second"
    case editorGoToStart = "Audio Editor: Go to Start"
    case editorGoToEnd = "Audio Editor: Go to End"
    case editorGoToTime = "Audio Editor: Go to Time…"
    case editorPreviousChapter = "Audio Editor: Previous Chapter Marker"
    case editorNextChapter = "Audio Editor: Next Chapter Marker"
    case editorPreviousPause = "Audio Editor: Previous Pause"
    case editorNextPause = "Audio Editor: Next Pause"
    case editorWhereAmI = "Audio Editor: Where Am I?"

    var id: String { rawValue }

    /// The heading of the audio editor's group in Settings, and the start
    /// of each of its actions' raw values.
    static let audioEditorCategory = "Audio Editor"

    /// The action's name as Settings lists it under its group's heading:
    /// its raw value, less the group's name that begins an audio editor
    /// action's.
    var title: String {
        let prefix = Self.audioEditorCategory + ": "
        return rawValue.hasPrefix(prefix) ? String(rawValue.dropFirst(prefix.count)) : rawValue
    }

    /// Where the action's shortcuts work: the audio editor's group in its
    /// windows alone, every other action everywhere else.
    var scope: ShortcutScope {
        category == Self.audioEditorCategory ? .audioEditor : .app
    }

    /// The notification to post when this action is triggered
    var notificationName: Notification.Name {
        switch self {
        case .togglePlayback: return .togglePlayback
        case .releaseMediaControls: return .releaseMediaControls
        case .skipForward: return .skipForward
        case .skipBackward: return .skipBackward
        case .cycleForwardNavigationUnit: return .cycleForwardNavigationUnit
        case .cycleBackwardNavigationUnit: return .cycleBackwardNavigationUnit
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
        case .showHeadingList: return .showHeadingList
        case .showBookmarkList: return .showBookmarkList
        case .showSleepTimer: return .showSleepTimer
        case .restartSleepTimer: return .restartSleepTimer
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
        // The audio editor's actions all post one name, carrying the action
        // in their user info, and its window performs them.
        case .editorPlayPause, .editorStop, .editorSkipBack, .editorSkipForward,
             .editorSkipBackLong, .editorSkipForwardLong, .editorSkipBackShort, .editorSkipForwardShort,
             .editorGoToStart, .editorGoToEnd, .editorGoToTime, .editorPreviousChapter, .editorNextChapter,
             .editorPreviousPause, .editorNextPause, .editorWhereAmI:
            return .audioEditorShortcut
        }
    }

    /// Category for grouping in settings
    var category: String {
        switch self {
        case .togglePlayback, .releaseMediaControls, .skipForward, .skipBackward,
             .cycleForwardNavigationUnit, .cycleBackwardNavigationUnit,
             .increaseSpeed, .decreaseSpeed:
            return "Playback"
        case .goToLibrary, .goBack, .goForward, .navigateUpLevel, .nextHeading, .previousHeading:
            return "Navigation"
        case .addBookmark, .nextBookmark, .previousBookmark, .showBookmarkList:
            return "Bookmarks"
        case .showHeadingList, .showSleepTimer, .restartSleepTimer:
            return "Panels"
        case .whereAmI:
            return "Information"
        case .openSelectedBook, .showBookInfo, .removeFromLibrary, .newFolder, .moveToFolder, .selectAll, .toggleEditMode, .moveBookUp, .moveBookDown:
            return "Library"
        case .editorPlayPause, .editorStop, .editorSkipBack, .editorSkipForward,
             .editorSkipBackLong, .editorSkipForwardLong, .editorSkipBackShort, .editorSkipForwardShort,
             .editorGoToStart, .editorGoToEnd, .editorGoToTime, .editorPreviousChapter, .editorNextChapter,
             .editorPreviousPause, .editorNextPause, .editorWhereAmI:
            return Self.audioEditorCategory
        }
    }
}

/// Where a shortcut works.
enum ShortcutScope: Hashable, Sendable {
    /// Every window but the audio editor's: the Library, the readers,
    /// Settings, and the rest, as TextMouth's shortcuts always have.
    case app
    /// The audio editor's windows (FR04), and nowhere else: so the editor
    /// can take Space, J, K, and L for itself.
    case audioEditor
}

extension Notification.Name {
    /// Posted for every audio editor shortcut (FR04), with the action's raw
    /// value under "action" in its user info, and the window it was pressed
    /// in under "sourceWindow": that window's editor performs it.
    static let audioEditorShortcut = Notification.Name("audioEditorShortcut")
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

// MARK: - Shortcuts as config.json Writes Them

extension KeyBinding {
    /// The special keys' names, spelled as `from(event:)` records them. Any
    /// other key is a single character.
    static let namedKeys = [
        "space", "tab", "return", "delete", "escape", "leftArrow", "rightArrow", "upArrow", "downArrow",
    ]

    /// The binding as config.json writes it: its modifiers in the order
    /// Settings shows them (Control, Option, Shift, Command), then its key,
    /// joined by "+", such as "space", "command+rightArrow", or
    /// "option+shift+command+b".
    var configText: String {
        (ConfigModifier.allCases.filter { $0.isHeld(in: self) }.map(\.word) + [key]).joined(separator: "+")
    }

    /// Reads a shortcut written in config.json: modifier names joined to a
    /// key by "+", as `configText` writes them.
    ///
    /// Text edited by hand is read generously: names may be capitalized,
    /// spaces are ignored, cmd, ctrl, opt, and alt stand for command,
    /// control, and option, and a letter key may be a capital. The key comes
    /// last and may itself be the plus key, as in "command++". Returns nil
    /// for text that names no key, or a key that is neither a special key's
    /// name nor a single character.
    init?(configText: String) {
        var remaining = Substring(configText.filter { !$0.isWhitespace })
        var binding = KeyBinding(key: "")
        // Take modifiers off the front while one is followed by "+"; what
        // remains is the key.
        while let leading = ConfigModifier.leading(in: remaining) {
            leading.modifier.hold(in: &binding)
            remaining = leading.rest
        }
        guard let key = Self.storedKey(named: remaining) else { return nil }
        binding.key = key
        self = binding
    }

    /// Reads the shortcuts config.json lists for one action, keeping the
    /// first of any repeated. Returns nil when any of them cannot be read,
    /// so a mistyped shortcut leaves the action's bindings as they are
    /// rather than dropping it and keeping the rest.
    static func bindings(fromConfigTexts texts: [String]) -> [KeyBinding]? {
        var bindings: [KeyBinding] = []
        for text in texts {
            guard let binding = KeyBinding(configText: text) else { return nil }
            if !bindings.contains(binding) {
                bindings.append(binding)
            }
        }
        return bindings
    }

    /// The key as bindings store it: a special key's name in its usual
    /// spelling, or a single character in lower case, as recorded; nil for
    /// anything else.
    private static func storedKey(named text: Substring) -> String? {
        if let named = namedKeys.first(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
            return named
        }
        return text.count == 1 ? text.lowercased() : nil
    }
}

/// A modifier key as config.json names it, in the order Settings shows the
/// modifiers (⌃⌥⇧⌘).
private enum ConfigModifier: CaseIterable {
    case control, option, shift, command

    /// Every name config.json accepts for the modifier, the one it writes
    /// first.
    var names: [String] {
        switch self {
        case .control: return ["control", "ctrl"]
        case .option: return ["option", "opt", "alt"]
        case .shift: return ["shift"]
        case .command: return ["command", "cmd"]
        }
    }

    /// The name config.json writes.
    var word: String { names[0] }

    /// Whether `binding` holds this modifier down.
    func isHeld(in binding: KeyBinding) -> Bool {
        switch self {
        case .control: return binding.control
        case .option: return binding.option
        case .shift: return binding.shift
        case .command: return binding.command
        }
    }

    /// Makes `binding` hold this modifier down.
    func hold(in binding: inout KeyBinding) {
        switch self {
        case .control: binding.control = true
        case .option: binding.option = true
        case .shift: binding.shift = true
        case .command: binding.command = true
        }
    }

    /// The modifier `text` starts with, named in any letter case and
    /// followed by "+", and the text after that "+"; nil when `text` starts
    /// with none.
    static func leading(in text: Substring) -> (modifier: ConfigModifier, rest: Substring)? {
        for modifier in allCases {
            for name in modifier.names where text.prefix(name.count + 1).lowercased() == name + "+" {
                return (modifier, text.dropFirst(name.count + 1))
            }
        }
        return nil
    }
}

/// All default keyboard shortcut bindings
extension ShortcutAction {
    /// Default bindings for each action (primary + optional secondary)
    static var defaultBindings: [ShortcutAction: [KeyBinding]] {
        let everywhereElse: [ShortcutAction: [KeyBinding]] = [
            .togglePlayback: [
                KeyBinding(key: "space"),
                KeyBinding(key: "k")
            ],
            .releaseMediaControls: [],
            .skipForward: [
                KeyBinding(key: "rightArrow", command: true),
                KeyBinding(key: "l")
            ],
            .skipBackward: [
                KeyBinding(key: "leftArrow", command: true),
                KeyBinding(key: "j")
            ],
            .cycleForwardNavigationUnit: [
                // A plain key keeps unit changes as quick as J/K/L playback
                // navigation while text-input focus protection prevents typing
                // in search and metadata fields from triggering it.
                KeyBinding(key: "f")
            ],
            .cycleBackwardNavigationUnit: [
                KeyBinding(key: "b")
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
                KeyBinding(key: "b", command: true, option: true, shift: true)
            ],
            .previousBookmark: [
                KeyBinding(key: "b", command: true, option: true)
            ],
            .showHeadingList: [
                KeyBinding(key: "h", command: true, shift: true)
            ],
            .showBookmarkList: [
                KeyBinding(key: "b", command: true, shift: true)
            ],
            .showSleepTimer: [
                KeyBinding(key: "t", command: true, shift: true)
            ],
            .restartSleepTimer: [
                // Cmd+Shift+R — chosen to avoid existing bindings.
                // KeyboardShortcutManager.addBinding strips this from
                // any other action automatically if a user reassigns
                // it later, so conflicts resolve themselves.
                KeyBinding(key: "r", command: true, shift: true)
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
                KeyBinding(key: "upArrow", command: true, shift: true)
            ],
            .moveBookDown: [
                KeyBinding(key: "downArrow", command: true, shift: true)
            ]
        ]
        return everywhereElse.merging(audioEditorDefaultBindings) { existing, _ in existing }
    }

    /// The audio editor's default bindings (FR04): single keys wherever one
    /// fits, as the user chose on October 4, matched only in an editor
    /// window (`ShortcutScope.audioEditor`), so Space, J, K, and L play and
    /// move there as they do in a reader. None of them is any other editor
    /// action's, and the Command ones are no menu command's but the Edit
    /// menu's own Undo, Redo, Cut, Copy, Paste, and Select All, which the
    /// editor answers itself (the shortcut tests check both).
    static var audioEditorDefaultBindings: [ShortcutAction: [KeyBinding]] {
        [
            .editorPlayPause: [KeyBinding(key: "space"), KeyBinding(key: "k")],
            .editorStop: [KeyBinding(key: "s")],
            // J and Comma go back, L and Period forward: a second; Shift-J
            // and Shift-L ten; with Option, a tenth.
            .editorSkipBack: [KeyBinding(key: "j"), KeyBinding(key: ",")],
            .editorSkipForward: [KeyBinding(key: "l"), KeyBinding(key: ".")],
            .editorSkipBackLong: [KeyBinding(key: "j", shift: true)],
            .editorSkipForwardLong: [KeyBinding(key: "l", shift: true)],
            .editorSkipBackShort: [KeyBinding(key: "j", option: true), KeyBinding(key: ",", option: true)],
            .editorSkipForwardShort: [KeyBinding(key: "l", option: true), KeyBinding(key: ".", option: true)],
            // The start and the end of the audio, as of a document.
            .editorGoToStart: [KeyBinding(key: "upArrow", command: true)],
            .editorGoToEnd: [KeyBinding(key: "downArrow", command: true)],
            .editorGoToTime: [KeyBinding(key: "g")],
            // Chapter markers by the reader's keys for headings.
            .editorPreviousChapter: [KeyBinding(key: "upArrow", command: true, option: true)],
            .editorNextChapter: [KeyBinding(key: "downArrow", command: true, option: true)],
            .editorPreviousPause: [KeyBinding(key: "n", shift: true)],
            .editorNextPause: [KeyBinding(key: "n")],
            .editorWhereAmI: [KeyBinding(key: "w")],
        ]
    }
}
