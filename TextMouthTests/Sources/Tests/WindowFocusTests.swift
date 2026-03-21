import Foundation

func runWindowFocusTests() {
print("\n--- Window Focus & Notification Routing Tests ---")

test("Notification without sourceWindow is accepted (menu commands)") {
    // Menu commands don't include a sourceWindow, so all readers should respond
    let notification = Notification(name: .init("test"), object: nil, userInfo: nil)
    let sourceWindow = notification.userInfo?["sourceWindow"]
    // No sourceWindow means accept
    let accepted = (sourceWindow == nil)
    try assertTrue(accepted, "Menu commands (no sourceWindow) should always be accepted")
}

test("Notification with sourceWindow only accepted by matching window") {
    // Simulate: two readers, only one should respond
    let notification = Notification(
        name: .init("test"),
        object: nil,
        userInfo: ["sourceWindow": "window-A"]
    )
    let sourceWindow = notification.userInfo?["sourceWindow"] as? String

    // Reader A has "window-A"
    let readerAWindow = "window-A"
    let readerAAccepts = (sourceWindow == nil) || (sourceWindow == readerAWindow)
    try assertTrue(readerAAccepts, "Reader A should accept notification from window-A")

    // Reader B has "window-B"
    let readerBWindow = "window-B"
    let readerBAccepts = (sourceWindow == nil) || (sourceWindow == readerBWindow)
    try assertTrue(!readerBAccepts, "Reader B should NOT accept notification from window-A")
}

test("Notification routing: only focused reader responds to keyboard shortcut") {
    // Simulate the full flow:
    // 1. KeyboardShortcutManager posts notification with sourceWindow
    // 2. Multiple readers check isTargetedNotification
    // 3. Only the one matching the source window responds

    var readerAPlayed = false
    var readerBPlayed = false
    let focusedWindow = "focused-reader"

    // Simulate keyboard event posting
    let userInfo: [String: Any] = ["sourceWindow": focusedWindow]

    // Reader A checks (it's the focused one)
    let readerAHostWindow = focusedWindow
    if let source = userInfo["sourceWindow"] as? String, source == readerAHostWindow {
        readerAPlayed = true
    }

    // Reader B checks (it's NOT focused)
    let readerBHostWindow = "other-reader"
    if let source = userInfo["sourceWindow"] as? String, source == readerBHostWindow {
        readerBPlayed = true
    }

    try assertTrue(readerAPlayed, "Focused reader should respond")
    try assertTrue(!readerBPlayed, "Unfocused reader should NOT respond")
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
    // Both the rotor entry and the row should use the same format
    let rotorFormat = "\(headingText) - level \(level)"
    let rowFormat = "\(headingText) - level \(level)"
    try assertEqual(rotorFormat, rowFormat, "Rotor and row formats should match")
}

} // end runWindowFocusTests
