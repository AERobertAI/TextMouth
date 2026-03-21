import Foundation

// Mirror the KeyBinding struct for testing
struct KeyBinding: Codable, Equatable, Hashable {
    var key: String
    var command: Bool = false
    var option: Bool = false
    var shift: Bool = false
    var control: Bool = false

    var displayString: String {
        var parts: [String] = []
        if control { parts.append("\u{2303}") }
        if option { parts.append("\u{2325}") }
        if shift { parts.append("\u{21E7}") }
        if command { parts.append("\u{2318}") }
        parts.append(keyDisplayName)
        return parts.joined()
    }

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
        case "rightArrow": return "\u{2192}"
        case "leftArrow": return "\u{2190}"
        case "upArrow": return "\u{2191}"
        case "downArrow": return "\u{2193}"
        case "tab": return "\u{21E5}"
        case "return": return "\u{21A9}"
        case "delete": return "\u{232B}"
        case "escape": return "\u{238B}"
        default: return key.uppercased()
        }
    }
}

// Mirror ShortcutAction for testing
enum ShortcutAction: String, CaseIterable, Codable {
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
    case openSelectedBook = "Open Selected Book"
    case showBookInfo = "Book Info"
    case removeFromLibrary = "Remove from Library"
    case newFolder = "New Folder"
    case moveToFolder = "Move to Folder"
    case selectAll = "Select All"
    case toggleEditMode = "Edit Mode"

    var category: String {
        switch self {
        case .togglePlayback, .skipForward, .skipBackward, .increaseSpeed, .decreaseSpeed:
            return "Playback"
        case .goToLibrary, .goBack, .goForward, .nextHeading, .previousHeading:
            return "Navigation"
        case .addBookmark, .nextBookmark, .previousBookmark:
            return "Bookmarks"
        case .whereAmI:
            return "Information"
        case .openSelectedBook, .showBookInfo, .removeFromLibrary, .newFolder, .moveToFolder, .selectAll, .toggleEditMode:
            return "Library"
        }
    }

    static var defaultBindings: [ShortcutAction: [KeyBinding]] {
        [
            .togglePlayback: [KeyBinding(key: "space"), KeyBinding(key: "k")],
            .skipForward: [KeyBinding(key: "rightArrow", command: true), KeyBinding(key: "l")],
            .skipBackward: [KeyBinding(key: "leftArrow", command: true), KeyBinding(key: "j")],
            .increaseSpeed: [KeyBinding(key: "+", command: true)],
            .decreaseSpeed: [KeyBinding(key: "-", command: true)],
            .goToLibrary: [KeyBinding(key: "l", command: true)],
            .goBack: [KeyBinding(key: "[", command: true)],
            .goForward: [KeyBinding(key: "]", command: true)],
            .nextHeading: [KeyBinding(key: "downArrow", command: true, option: true)],
            .previousHeading: [KeyBinding(key: "upArrow", command: true, option: true)],
            .addBookmark: [KeyBinding(key: "b", command: true)],
            .nextBookmark: [KeyBinding(key: "b", command: true, shift: true)],
            .previousBookmark: [KeyBinding(key: "b", command: true, option: true)],
            .whereAmI: [KeyBinding(key: "w")],
            .openSelectedBook: [KeyBinding(key: "return")],
            .showBookInfo: [KeyBinding(key: "i", command: true)],
            .removeFromLibrary: [KeyBinding(key: "delete", command: true)],
            .newFolder: [KeyBinding(key: "n", command: true, shift: true)],
            .moveToFolder: [KeyBinding(key: "m", command: true, shift: true)],
            .selectAll: [KeyBinding(key: "a", command: true)],
            .toggleEditMode: [KeyBinding(key: "e", command: true)],
        ]
    }
}

// Mirror SoundEvent
enum SoundEvent: String, CaseIterable, Codable {
    case play = "Play"
    case pause = "Pause"
    case skipForward = "Skip Forward"
    case skipBackward = "Skip Backward"
    case whereAmIStart = "Where Am I (Start)"
    case whereAmIEnd = "Where Am I (End)"
}

let defaultSoundAssignments: [SoundEvent: String] = [
    .play: "Pop",
    .pause: "Tink",
    .skipForward: "Tink",
    .skipBackward: "Tink",
    .whereAmIStart: "Glass",
    .whereAmIEnd: "Submarine",
]

func runKeyboardShortcutTests() {
print("\n--- KeyBinding Model Tests ---")

test("KeyBinding display string for single key") {
    let binding = KeyBinding(key: "k")
    try assertEqual(binding.displayString, "K")
    print("    Single key 'k' displays as: \(binding.displayString)")
}

test("KeyBinding display string for modifier + key") {
    let binding = KeyBinding(key: "b", command: true)
    try assertTrue(binding.displayString.contains("\u{2318}"), "Should contain ⌘")
    try assertTrue(binding.displayString.contains("B"), "Should contain B")
    print("    Cmd+B displays as: \(binding.displayString)")
}

test("KeyBinding display string for multiple modifiers") {
    let binding = KeyBinding(key: "b", command: true, option: true)
    try assertTrue(binding.displayString.contains("\u{2318}"), "Should contain ⌘")
    try assertTrue(binding.displayString.contains("\u{2325}"), "Should contain ⌥")
    try assertTrue(binding.displayString.contains("B"), "Should contain B")
    print("    Cmd+Opt+B displays as: \(binding.displayString)")
}

test("KeyBinding display string for special keys") {
    let space = KeyBinding(key: "space")
    try assertEqual(space.displayString, "Space")

    let right = KeyBinding(key: "rightArrow", command: true)
    try assertTrue(right.displayString.contains("\u{2192}"), "Should contain →")
    try assertTrue(right.displayString.contains("\u{2318}"), "Should contain ⌘")

    let up = KeyBinding(key: "upArrow", command: true, option: true)
    try assertTrue(up.displayString.contains("\u{2191}"), "Should contain ↑")

    print("    Space displays as: \(space.displayString)")
    print("    Cmd+Right displays as: \(right.displayString)")
    print("    Cmd+Opt+Up displays as: \(up.displayString)")
}

test("KeyBinding accessible display string uses words") {
    let binding = KeyBinding(key: "b", command: true, shift: true)
    try assertEqual(binding.accessibleDisplayString, "Shift + Command + B")
    print("    Accessible: \(binding.accessibleDisplayString)")
}

test("KeyBinding accessible display string for single key") {
    let binding = KeyBinding(key: "k")
    try assertEqual(binding.accessibleDisplayString, "K")
    print("    Accessible single key: \(binding.accessibleDisplayString)")
}

test("KeyBinding equality comparison") {
    let a = KeyBinding(key: "k")
    let b = KeyBinding(key: "k")
    let c = KeyBinding(key: "k", command: true)
    let d = KeyBinding(key: "j")
    try assertTrue(a == b, "Same key should be equal")
    try assertTrue(a != c, "Different modifiers should not be equal")
    try assertTrue(a != d, "Different keys should not be equal")
}

test("KeyBinding JSON round-trip") {
    let original = KeyBinding(key: "b", command: true, shift: true)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(KeyBinding.self, from: data)
    try assertTrue(original == decoded, "Round-trip should preserve equality")
    try assertEqual(decoded.key, "b")
    try assertTrue(decoded.command, "Command should be true")
    try assertTrue(decoded.shift, "Shift should be true")
    try assertTrue(!decoded.option, "Option should be false")
    print("    JSON round-trip preserved: \(decoded.displayString)")
}

test("KeyBinding array JSON round-trip") {
    let bindings = [
        KeyBinding(key: "space"),
        KeyBinding(key: "k"),
        KeyBinding(key: "rightArrow", command: true),
    ]
    let data = try JSONEncoder().encode(bindings)
    let decoded = try JSONDecoder().decode([KeyBinding].self, from: data)
    try assertEqual(decoded.count, 3)
    try assertEqual(decoded[0].key, "space")
    try assertEqual(decoded[1].key, "k")
    try assertEqual(decoded[2].key, "rightArrow")
    try assertTrue(decoded[2].command, "Third binding should have command modifier")
    print("    Array round-trip preserved \(decoded.count) bindings")
}

// ---- ShortcutAction Tests ----
print("\n--- ShortcutAction Tests ---")

test("All actions have default bindings") {
    let defaults = ShortcutAction.defaultBindings
    for action in ShortcutAction.allCases {
        let bindings = defaults[action]
        try assertTrue(bindings != nil, "\(action.rawValue) should have default bindings")
        try assertGreater(bindings!.count, 0, "\(action.rawValue) should have at least one binding")
    }
    print("    All \(ShortcutAction.allCases.count) actions have default bindings")
}

test("Where Am I action exists with W default binding") {
    let defaults = ShortcutAction.defaultBindings
    let whereAmIBindings = defaults[.whereAmI]!
    try assertEqual(whereAmIBindings.count, 1)
    try assertEqual(whereAmIBindings[0].key, "w")
    try assertTrue(!whereAmIBindings[0].command, "W should be a single-key shortcut (no modifiers)")
    try assertTrue(!whereAmIBindings[0].option, "W should have no option modifier")
    try assertTrue(!whereAmIBindings[0].shift, "W should have no shift modifier")
    print("    Where Am I default: \(whereAmIBindings[0].displayString)")
}

test("Play/Pause has both Space and K bindings") {
    let defaults = ShortcutAction.defaultBindings
    let bindings = defaults[.togglePlayback]!
    try assertEqual(bindings.count, 2)
    try assertEqual(bindings[0].key, "space")
    try assertEqual(bindings[1].key, "k")
    try assertTrue(!bindings[0].command && !bindings[1].command, "Both should be single-key shortcuts")
    print("    Play/Pause defaults: \(bindings.map { $0.displayString }.joined(separator: ", "))")
}

test("Skip Forward has both Cmd+Right and L bindings") {
    let defaults = ShortcutAction.defaultBindings
    let bindings = defaults[.skipForward]!
    try assertEqual(bindings.count, 2)
    try assertEqual(bindings[0].key, "rightArrow")
    try assertTrue(bindings[0].command, "First binding should have command modifier")
    try assertEqual(bindings[1].key, "l")
    try assertTrue(!bindings[1].command, "L should be a single-key shortcut")
    print("    Skip Forward defaults: \(bindings.map { $0.displayString }.joined(separator: ", "))")
}

test("Skip Backward has both Cmd+Left and J bindings") {
    let defaults = ShortcutAction.defaultBindings
    let bindings = defaults[.skipBackward]!
    try assertEqual(bindings.count, 2)
    try assertEqual(bindings[0].key, "leftArrow")
    try assertTrue(bindings[0].command, "First binding should have command modifier")
    try assertEqual(bindings[1].key, "j")
    try assertTrue(!bindings[1].command, "J should be a single-key shortcut")
    print("    Skip Backward defaults: \(bindings.map { $0.displayString }.joined(separator: ", "))")
}

test("Action categories are correct") {
    try assertEqual(ShortcutAction.togglePlayback.category, "Playback")
    try assertEqual(ShortcutAction.skipForward.category, "Playback")
    try assertEqual(ShortcutAction.goToLibrary.category, "Navigation")
    try assertEqual(ShortcutAction.nextHeading.category, "Navigation")
    try assertEqual(ShortcutAction.addBookmark.category, "Bookmarks")
    try assertEqual(ShortcutAction.whereAmI.category, "Information")
    print("    Categories verified for all action types")
}

test("No duplicate bindings across actions in defaults") {
    let defaults = ShortcutAction.defaultBindings
    var seen: [KeyBinding: ShortcutAction] = [:]
    for (action, bindings) in defaults {
        for binding in bindings {
            if let existing = seen[binding] {
                throw TestError.assertionFailed("Duplicate binding \(binding.displayString) for \(action.rawValue) and \(existing.rawValue)")
            }
            seen[binding] = action
        }
    }
    print("    No duplicate bindings found across \(seen.count) total bindings")
}

test("Full bindings dictionary JSON round-trip") {
    let defaults = ShortcutAction.defaultBindings
    // Convert to [String: [KeyBinding]] for serialization
    var dict: [String: [KeyBinding]] = [:]
    for (action, bindings) in defaults {
        dict[action.rawValue] = bindings
    }
    let data = try JSONEncoder().encode(dict)
    let decoded = try JSONDecoder().decode([String: [KeyBinding]].self, from: data)

    // Verify all actions survived
    for action in ShortcutAction.allCases {
        let original = defaults[action]!
        let restored = decoded[action.rawValue]
        try assertTrue(restored != nil, "\(action.rawValue) should exist after round-trip")
        try assertEqual(original.count, restored!.count, "Binding count should match for \(action.rawValue)")
    }
    print("    Full bindings dictionary round-trip preserved \(decoded.count) actions")
}

// ---- Library Shortcut Tests ----
print("\n--- Library Shortcut Tests ---")

test("Remove from Library has Cmd+Delete binding") {
    let defaults = ShortcutAction.defaultBindings
    let bindings = defaults[.removeFromLibrary]!
    try assertEqual(bindings.count, 1)
    try assertEqual(bindings[0].key, "delete")
    try assertTrue(bindings[0].command, "Should have command modifier")
    try assertTrue(!bindings[0].shift, "Should not have shift modifier")
    print("    Remove from Library default: \(bindings[0].displayString)")
}

test("New Folder has Cmd+Shift+N binding") {
    let defaults = ShortcutAction.defaultBindings
    let bindings = defaults[.newFolder]!
    try assertEqual(bindings.count, 1)
    try assertEqual(bindings[0].key, "n")
    try assertTrue(bindings[0].command, "Should have command modifier")
    try assertTrue(bindings[0].shift, "Should have shift modifier")
    print("    New Folder default: \(bindings[0].displayString)")
}

test("Move to Folder has Cmd+Shift+M binding") {
    let defaults = ShortcutAction.defaultBindings
    let bindings = defaults[.moveToFolder]!
    try assertEqual(bindings.count, 1)
    try assertEqual(bindings[0].key, "m")
    try assertTrue(bindings[0].command, "Should have command modifier")
    try assertTrue(bindings[0].shift, "Should have shift modifier")
    print("    Move to Folder default: \(bindings[0].displayString)")
}

test("Select All has Cmd+A binding") {
    let defaults = ShortcutAction.defaultBindings
    let bindings = defaults[.selectAll]!
    try assertEqual(bindings.count, 1)
    try assertEqual(bindings[0].key, "a")
    try assertTrue(bindings[0].command, "Should have command modifier")
    try assertTrue(!bindings[0].shift, "Should not have shift modifier")
    print("    Select All default: \(bindings[0].displayString)")
}

test("Library category includes all library actions") {
    let libraryActions = ShortcutAction.allCases.filter { $0.category == "Library" }
    try assertEqual(libraryActions.count, 7, "Should have 7 library actions")
    let names = libraryActions.map { $0.rawValue }
    try assertTrue(names.contains("Remove from Library"))
    try assertTrue(names.contains("New Folder"))
    try assertTrue(names.contains("Move to Folder"))
    try assertTrue(names.contains("Select All"))
    try assertTrue(names.contains("Open Selected Book"))
    try assertTrue(names.contains("Book Info"))
    try assertTrue(names.contains("Edit Mode"))
    print("    Library category has \(libraryActions.count) actions")
}

test("Edit Mode has Cmd+E binding") {
    let defaults = ShortcutAction.defaultBindings
    let bindings = defaults[.toggleEditMode]!
    try assertEqual(bindings.count, 1)
    try assertEqual(bindings[0].key, "e")
    try assertTrue(bindings[0].command, "Should have command modifier")
    try assertTrue(!bindings[0].shift, "Should not have shift modifier")
    print("    Edit Mode default: \(bindings[0].displayString)")
}

test("New library shortcuts display correctly for accessibility") {
    let remove = KeyBinding(key: "delete", command: true)
    try assertEqual(remove.accessibleDisplayString, "Command + \u{232B}")

    let newFolder = KeyBinding(key: "n", command: true, shift: true)
    try assertEqual(newFolder.accessibleDisplayString, "Shift + Command + N")

    let move = KeyBinding(key: "m", command: true, shift: true)
    try assertEqual(move.accessibleDisplayString, "Shift + Command + M")

    let selectAll = KeyBinding(key: "a", command: true)
    try assertEqual(selectAll.accessibleDisplayString, "Command + A")
    print("    All accessible display strings verified")
}

// ---- SoundEvent Tests ----
print("\n--- Sound Effect Configuration Tests ---")

test("All sound events have default assignments") {
    for event in SoundEvent.allCases {
        let sound = defaultSoundAssignments[event]
        try assertTrue(sound != nil, "\(event.rawValue) should have a default sound")
        try assertTrue(!sound!.isEmpty, "\(event.rawValue) sound should not be empty")
    }
    print("    All \(SoundEvent.allCases.count) events have defaults")
}

test("Default sounds reference valid system sound files") {
    let systemSoundsPath = "/System/Library/Sounds"
    let fm = FileManager.default
    for (event, soundName) in defaultSoundAssignments {
        let path = "\(systemSoundsPath)/\(soundName).aiff"
        try assertTrue(fm.fileExists(atPath: path), "\(event.rawValue) default '\(soundName)' should exist at \(path)")
    }
    print("    All default sounds verified on disk")
}

test("System sounds directory has expected sounds") {
    let systemSoundsPath = "/System/Library/Sounds"
    let fm = FileManager.default
    let files = try fm.contentsOfDirectory(atPath: systemSoundsPath)
    let aiffs = files.filter { $0.hasSuffix(".aiff") }
    try assertGreater(aiffs.count, 10, "Should have at least 10 system sounds")

    let expected = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
                    "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
    for name in expected {
        try assertTrue(aiffs.contains("\(name).aiff"), "\(name).aiff should exist")
    }
    print("    Found \(aiffs.count) system sounds, all 14 expected sounds present")
}

test("SoundEvent JSON round-trip") {
    var dict: [String: String] = [:]
    for (event, sound) in defaultSoundAssignments {
        dict[event.rawValue] = sound
    }
    let data = try JSONEncoder().encode(dict)
    let decoded = try JSONDecoder().decode([String: String].self, from: data)
    try assertEqual(decoded.count, defaultSoundAssignments.count)
    for event in SoundEvent.allCases {
        try assertEqual(decoded[event.rawValue], defaultSoundAssignments[event])
    }
    print("    Sound assignments round-trip preserved")
}

} // end runKeyboardShortcutTests
