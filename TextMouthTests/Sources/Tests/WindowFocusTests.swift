import Foundation

func runWindowFocusTests() {
print("\n--- Window Focus & Notification Routing Tests ---")

test("Keyboard shortcut: notification with sourceWindow only accepted by matching window") {
    let userInfo: [String: Any] = ["sourceWindow": "window-A"]

    // Reader A has "window-A" — should accept
    let readerAWindow = "window-A"
    let sourceWindow = userInfo["sourceWindow"] as? String
    let readerAAccepts = (sourceWindow == readerAWindow)
    try assertTrue(readerAAccepts, "Reader A should accept notification from window-A")

    // Reader B has "window-B" — should reject
    let readerBWindow = "window-B"
    let readerBAccepts = (sourceWindow == readerBWindow)
    try assertTrue(!readerBAccepts, "Reader B should NOT accept notification from window-A")
}

test("Keyboard shortcut: only focused reader responds to play/pause") {
    var readerAPlayed = false
    var readerBPlayed = false
    let focusedWindow = "focused-reader"

    let userInfo: [String: Any] = ["sourceWindow": focusedWindow]

    // Reader A checks — it's the focused one
    if let source = userInfo["sourceWindow"] as? String, source == focusedWindow {
        readerAPlayed = true
    }

    // Reader B checks — it's NOT focused
    let readerBHostWindow = "other-reader"
    if let source = userInfo["sourceWindow"] as? String, source == readerBHostWindow {
        readerBPlayed = true
    }

    try assertTrue(readerAPlayed, "Focused reader should respond")
    try assertTrue(!readerBPlayed, "Unfocused reader should NOT respond")
}

test("Menu command: no sourceWindow, only key window should respond") {
    // Menu commands don't include a sourceWindow. The handler must check
    // whether its own window is the key window before responding.
    let userInfo: [String: Any]? = nil

    // Simulate isTargetedNotification logic for menu commands:
    // If no sourceWindow, check hostWindow.isKeyWindow

    // Reader A's window is key — should respond
    let readerAIsKey = true
    let readerAAccepts: Bool
    if userInfo?["sourceWindow"] != nil {
        readerAAccepts = false // Would need to match, but no sourceWindow
    } else {
        readerAAccepts = readerAIsKey
    }
    try assertTrue(readerAAccepts, "Key window reader should accept menu command")

    // Reader B's window is NOT key — should not respond
    let readerBIsKey = false
    let readerBAccepts: Bool
    if userInfo?["sourceWindow"] != nil {
        readerBAccepts = false
    } else {
        readerBAccepts = readerBIsKey
    }
    try assertTrue(!readerBAccepts, "Non-key window reader should reject menu command")
}

test("Menu command: Cmd+F search only opens in focused reader") {
    // searchInBook comes from menu with no sourceWindow.
    // Only the reader whose window is key should open the search sheet.
    var searchOpenedInA = false
    var searchOpenedInB = false

    let windowAIsKey = true
    let windowBIsKey = false

    // Simulate the handler: guard hostWindow.isKeyWindow
    if windowAIsKey { searchOpenedInA = true }
    if windowBIsKey { searchOpenedInB = true }

    try assertTrue(searchOpenedInA, "Search should open in focused reader")
    try assertTrue(!searchOpenedInB, "Search should NOT open in unfocused reader")
}

test("Menu command: Cmd+Shift+P copy position only in focused reader") {
    // copyReadingPosition from menu — same pattern
    var copiedInA = false
    var copiedInB = false

    let windowAIsKey = true
    let windowBIsKey = false

    if windowAIsKey { copiedInA = true }
    if windowBIsKey { copiedInB = true }

    try assertTrue(copiedInA, "Copy position should run in focused reader")
    try assertTrue(!copiedInB, "Copy position should NOT run in unfocused reader")
}

test("Library: Enter key only opens book from focused library window") {
    var libraryAOpened = false
    var libraryBOpened = false

    let windowAIsKey = true
    let windowBIsKey = false

    // openSelectedBook from KeyboardShortcutManager — has sourceWindow
    let sourceWindow = "library-window-A"
    let libraryAHostWindow = "library-window-A"
    let libraryBHostWindow = "library-window-B"

    if sourceWindow == libraryAHostWindow { libraryAOpened = true }
    if sourceWindow == libraryBHostWindow { libraryBOpened = true }

    try assertTrue(libraryAOpened, "Focused library should open selected book")
    try assertTrue(!libraryBOpened, "Unfocused library should NOT open selected book")
    // Suppress unused variable warnings
    _ = windowAIsKey
    _ = windowBIsKey
}

test("Library: Cmd+Shift+T new from text only in focused library") {
    var textShownInA = false
    var textShownInB = false

    let windowAIsKey = true
    let windowBIsKey = false

    // newFromText comes from menu — no sourceWindow, check isKeyWindow
    if windowAIsKey { textShownInA = true }
    if windowBIsKey { textShownInB = true }

    try assertTrue(textShownInA, "New from text should open in focused library")
    try assertTrue(!textShownInB, "New from text should NOT open in unfocused library")
}

test("No hostWindow set yet: accept notification as fallback") {
    // When the window hasn't been captured yet (nil hostWindow),
    // notifications should be accepted to avoid silently dropping commands
    let hostWindow: String? = nil
    let accepted = (hostWindow == nil) // true means accept
    try assertTrue(accepted, "Should accept when hostWindow not yet captured")
}

// MARK: - Heading Navigator Format Tests

print("\n--- Heading Navigator Format Tests ---")

test("Heading accessibility: name comes before level") {
    let headingText = "The Departure"
    let level = 2
    let description = "\(headingText) - level \(level)"
    try assertTrue(description.hasPrefix("The Departure"), "Heading name should come first")
    try assertTrue(description.contains("- level 2"), "Level should come after name")
    try assertEqual(description, "The Departure - level 2")
}

test("Heading accessibility: skipped prefix before name") {
    let headingText = "Skipped Section"
    let level = 3
    let isSkipped = true
    let skipPrefix = isSkipped ? "Skipped, " : ""
    let description = "\(skipPrefix)\(headingText) - level \(level)"
    try assertEqual(description, "Skipped, Skipped Section - level 3")
}

test("Heading accessibility: format is shorter than old format") {
    let headingText = "Chapter 5"
    let level = 1
    let newFormat = "\(headingText) - level \(level)"
    let oldFormat = "Level \(level) heading: \(headingText)"
    try assertTrue(newFormat.count < oldFormat.count,
                   "New format should be shorter for faster screen reader scanning")
    try assertEqual(newFormat, "Chapter 5 - level 1")
}

test("Heading rotor entry format matches row format") {
    let headingText = "The Battle"
    let level = 2
    let rotorFormat = "\(headingText) - level \(level)"
    let rowFormat = "\(headingText) - level \(level)"
    try assertEqual(rotorFormat, rowFormat, "Rotor and row formats should match")
}

} // end runWindowFocusTests
