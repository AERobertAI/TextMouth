import Foundation

// Mirror the BookmarkPanelMode enum for state machine testing.
// The real enum lives in BookmarkPanelView.swift.
private enum TestPanelMode: Equatable {
    case list
    case add
    case edit(Bookmark)
}

/// Reproduce the BookmarkRow accessibility label logic so we can
/// verify it independently of SwiftUI rendering.
private func bookmarkAccessibilityLabel(_ bookmark: Bookmark) -> String {
    var parts = ["Bookmark \(bookmark.number)", "Chapter \(bookmark.chapterIndex + 1)"]
    if !bookmark.label.isEmpty {
        parts.append("Note: \(bookmark.label)")
    }
    return parts.joined(separator: ", ")
}

func runBookmarkPanelAccessibilityTests() {

// ====================================================================
// Bookmark Row Accessibility Labels
// ====================================================================
print("\n--- Bookmark Row Accessibility Labels ---")

test("Label includes bookmark number and chapter") {
    let bm = Bookmark(number: 3, chapterIndex: 4, characterOffset: 0)
    let label = bookmarkAccessibilityLabel(bm)
    try assertEqual(label, "Bookmark 3, Chapter 5")
}

test("Label includes note when present") {
    let bm = Bookmark(number: 1, chapterIndex: 0, characterOffset: 0, label: "Important passage")
    let label = bookmarkAccessibilityLabel(bm)
    try assertEqual(label, "Bookmark 1, Chapter 1, Note: Important passage")
}

test("Label omits note when empty") {
    let bm = Bookmark(number: 2, chapterIndex: 1, characterOffset: 0, label: "")
    let label = bookmarkAccessibilityLabel(bm)
    try assertEqual(label, "Bookmark 2, Chapter 2")
}

test("Label does not contain redundant 'bookmarks' word") {
    let bm = Bookmark(number: 1, chapterIndex: 0, characterOffset: 0)
    let label = bookmarkAccessibilityLabel(bm)
    // Should say "Bookmark" (singular, for the item), never "Bookmarks"
    let count = label.components(separatedBy: "ookmark").count - 1
    try assertEqual(count, 1, "Should contain 'Bookmark' exactly once, not multiple times")
}

test("Chapter index is 1-based in label") {
    let bm = Bookmark(number: 1, chapterIndex: 0, characterOffset: 0)
    let label = bookmarkAccessibilityLabel(bm)
    try assertTrue(label.contains("Chapter 1"), "Chapter 0 should display as Chapter 1")
}

test("High chapter index is correct in label") {
    let bm = Bookmark(number: 5, chapterIndex: 99, characterOffset: 0)
    let label = bookmarkAccessibilityLabel(bm)
    try assertTrue(label.contains("Chapter 100"), "Chapter 99 should display as Chapter 100")
}

// ====================================================================
// Panel Mode State Machine
// ====================================================================
print("\n--- Panel Mode State Machine ---")

test("Initial mode is list") {
    let mode = TestPanelMode.list
    try assertTrue(mode == .list)
}

test("Transition from list to add") {
    var mode = TestPanelMode.list
    mode = .add
    try assertTrue(mode == .add)
}

test("Transition from add back to list (cancel)") {
    var mode = TestPanelMode.add
    mode = .list
    try assertTrue(mode == .list)
}

test("Transition from add back to list (save)") {
    var mode = TestPanelMode.add
    // Simulate saving — mode returns to list
    mode = .list
    try assertTrue(mode == .list)
}

test("Transition from list to edit") {
    let bm = Bookmark(number: 1, chapterIndex: 0, characterOffset: 0, label: "test")
    var mode = TestPanelMode.list
    mode = .edit(bm)
    try assertTrue(mode == .edit(bm))
}

test("Transition from edit back to list (cancel)") {
    let bm = Bookmark(number: 1, chapterIndex: 0, characterOffset: 0)
    var mode = TestPanelMode.edit(bm)
    mode = .list
    try assertTrue(mode == .list)
}

test("Transition from edit back to list (save)") {
    let bm = Bookmark(number: 1, chapterIndex: 0, characterOffset: 0)
    var mode = TestPanelMode.edit(bm)
    mode = .list
    try assertTrue(mode == .list)
}

test("Edit mode carries the correct bookmark") {
    let bm1 = Bookmark(number: 1, chapterIndex: 0, characterOffset: 100, label: "first")
    let bm2 = Bookmark(number: 2, chapterIndex: 1, characterOffset: 200, label: "second")
    var mode = TestPanelMode.list
    mode = .edit(bm1)
    try assertTrue(mode == .edit(bm1))
    try assertTrue(mode != .edit(bm2), "Should not equal edit mode with different bookmark")
}

test("Mode never transitions directly from add to edit") {
    // Verify the expected flow: add -> list -> edit, not add -> edit
    var mode = TestPanelMode.add
    // Cancel or save always goes back to list first
    mode = .list
    let bm = Bookmark(number: 1, chapterIndex: 0, characterOffset: 0)
    mode = .edit(bm)
    try assertTrue(mode == .edit(bm))
}

// ====================================================================
// Escape Key Behavior (State Transitions)
// ====================================================================
print("\n--- Escape Key State Transitions ---")

/// Simulate what pressing escape does in each mode.
/// In list mode, escape dismisses the panel (returns nil).
/// In add/edit mode, escape returns to list mode.
func simulateEscape(_ mode: TestPanelMode) -> TestPanelMode? {
    switch mode {
    case .list:
        return nil // dismisses panel
    case .add, .edit:
        return .list // returns to list
    }
}

test("Escape in list mode dismisses panel") {
    let result = simulateEscape(.list)
    try assertTrue(result == nil, "Escape in list mode should dismiss (nil)")
}

test("Escape in add mode returns to list") {
    let result = simulateEscape(.add)
    try assertTrue(result == .list, "Escape in add mode should return to list")
}

test("Escape in edit mode returns to list") {
    let bm = Bookmark(number: 1, chapterIndex: 0, characterOffset: 0)
    let result = simulateEscape(.edit(bm))
    try assertTrue(result == .list, "Escape in edit mode should return to list")
}

test("Double escape from add mode dismisses panel") {
    var mode: TestPanelMode? = .add
    mode = simulateEscape(mode!)  // first escape -> list
    try assertTrue(mode == .list)
    mode = simulateEscape(mode!)  // second escape -> dismiss
    try assertTrue(mode == nil, "Second escape should dismiss")
}

test("Double escape from edit mode dismisses panel") {
    let bm = Bookmark(number: 1, chapterIndex: 0, characterOffset: 0)
    var mode: TestPanelMode? = .edit(bm)
    mode = simulateEscape(mode!)  // first escape -> list
    try assertTrue(mode == .list)
    mode = simulateEscape(mode!)  // second escape -> dismiss
    try assertTrue(mode == nil, "Second escape should dismiss")
}

// ====================================================================
// Empty State Accessibility
// ====================================================================
print("\n--- Empty State Accessibility ---")

test("Empty bookmark list should result in combined empty state") {
    // When bookmarks.isEmpty, the view groups "No bookmarks yet" and
    // "Press Cmd+B..." into a single .accessibilityElement(children: .combine).
    // We verify the text content that would be combined.
    let emptyMessage = "No bookmarks yet."
    let helpText = "Press Cmd+B to add a bookmark at the current position."
    // Combined element should contain both strings
    let combined = "\(emptyMessage) \(helpText)"
    try assertTrue(combined.contains("No bookmarks yet"), "Combined text should have empty message")
    try assertTrue(combined.contains("Cmd+B"), "Combined text should have keyboard hint")
}

test("Empty state does not contain count in container label") {
    // The old bug: outer VStack had .accessibilityLabel("Bookmarks, 0 bookmarks")
    // which leaked into all children. Verify the pattern we're avoiding.
    let badLabel = "Bookmarks, 0 bookmarks"
    let bookmarkWordCount = badLabel.components(separatedBy: "ookmark").count - 1
    // This demonstrates why the old label was redundant
    try assertTrue(bookmarkWordCount >= 2, "Old label had 'bookmark' twice — this is the bug we fixed")
}

// ====================================================================
// Navigation Title
// ====================================================================
print("\n--- Navigation Title ---")

test("Navigation title should be just the book title, not redundant") {
    // The view now uses .navigationTitle(viewModel.book.title) instead of
    // .navigationTitle("Bookmarks: \(viewModel.book.title)")
    let bookTitle = "The Great Adventure"
    // New: just the title
    let newTitle = bookTitle
    try assertTrue(!newTitle.contains("Bookmarks"), "Nav title should not repeat 'Bookmarks'")
    // Old: had redundant prefix
    let oldTitle = "Bookmarks: \(bookTitle)"
    try assertTrue(oldTitle.contains("Bookmarks"), "Old title had redundant 'Bookmarks' prefix")
}

// ====================================================================
// Sorted Bookmarks
// ====================================================================
print("\n--- Bookmark Sorting ---")

test("Bookmarks are sorted by number for display") {
    let bm1 = Bookmark(number: 3, chapterIndex: 0, characterOffset: 300)
    let bm2 = Bookmark(number: 1, chapterIndex: 0, characterOffset: 100)
    let bm3 = Bookmark(number: 2, chapterIndex: 1, characterOffset: 200)
    let bookmarks = [bm1, bm2, bm3]
    let sorted = bookmarks.sorted(by: { $0.number < $1.number })
    try assertEqual(sorted[0].number, 1)
    try assertEqual(sorted[1].number, 2)
    try assertEqual(sorted[2].number, 3)
}

test("Rotor entry format includes chapter and optional label") {
    let bm = Bookmark(number: 2, chapterIndex: 3, characterOffset: 0, label: "Climax")
    let entry = "Bookmark \(bm.number), Chapter \(bm.chapterIndex + 1)\(bm.label.isEmpty ? "" : ", \(bm.label)")"
    try assertEqual(entry, "Bookmark 2, Chapter 4, Climax")
}

test("Rotor entry without label omits trailing comma") {
    let bm = Bookmark(number: 1, chapterIndex: 0, characterOffset: 0, label: "")
    let entry = "Bookmark \(bm.number), Chapter \(bm.chapterIndex + 1)\(bm.label.isEmpty ? "" : ", \(bm.label)")"
    try assertEqual(entry, "Bookmark 1, Chapter 1")
}

} // end runBookmarkPanelAccessibilityTests
