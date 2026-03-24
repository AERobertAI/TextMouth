import Foundation

// Mirror the Bookmark struct for testing proximity logic
private struct TestBookmark {
    let id: UUID
    var chapterIndex: Int
    var characterOffset: Int
}

/// Find a bookmark within the proximity threshold of the given position
private func nearbyBookmark(
    bookmarks: [TestBookmark],
    chapterIndex: Int,
    characterOffset: Int,
    threshold: Int
) -> TestBookmark? {
    bookmarks.first { bm in
        bm.chapterIndex == chapterIndex &&
        abs(bm.characterOffset - characterOffset) <= threshold
    }
}

/// Adjust a bookmark offset so it doesn't land within the proximity zone
/// of an existing bookmark in the same chapter
private func adjustedBookmarkOffset(
    bookmarks: [TestBookmark],
    chapterIndex: Int,
    characterOffset: Int,
    threshold: Int
) -> Int {
    let sameChapter = bookmarks.filter { $0.chapterIndex == chapterIndex }
    guard let conflict = sameChapter.first(where: {
        abs($0.characterOffset - characterOffset) <= threshold
    }) else {
        return characterOffset
    }
    if characterOffset >= conflict.characterOffset {
        return conflict.characterOffset + threshold + 1
    } else {
        return max(0, conflict.characterOffset - threshold - 1)
    }
}

func runBookmarkToggleTests() {
print("\n--- Bookmark Proximity Detection Tests ---")

test("No nearby bookmark returns nil") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 100)]
    let result = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 200, threshold: 10)
    try assertTrue(result == nil, "Should not find bookmark 100 chars away with threshold 10")
}

test("Bookmark at exact position is found") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 100)]
    let result = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 100, threshold: 10)
    try assertTrue(result != nil, "Should find bookmark at exact position")
}

test("Bookmark within threshold is found (text: 10 chars)") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 100)]
    let result = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 108, threshold: 10)
    try assertTrue(result != nil, "Should find bookmark 8 chars away with threshold 10")
}

test("Bookmark at threshold boundary is found") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 100)]
    let result = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 110, threshold: 10)
    try assertTrue(result != nil, "Should find bookmark exactly at threshold boundary")
}

test("Bookmark just beyond threshold is not found") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 100)]
    let result = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 111, threshold: 10)
    try assertTrue(result == nil, "Should not find bookmark 11 chars away with threshold 10")
}

test("Bookmark in different chapter is not found") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 1, characterOffset: 100)]
    let result = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 100, threshold: 10)
    try assertTrue(result == nil, "Should not match bookmark in different chapter")
}

test("Audio threshold is 5 chars (half second)") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 100)]
    // 5 chars away with audio threshold of 5
    let found = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 105, threshold: 5)
    try assertTrue(found != nil, "Should find bookmark 5 chars away with audio threshold")
    // 6 chars away — too far
    let notFound = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 106, threshold: 5)
    try assertTrue(notFound == nil, "Should not find bookmark 6 chars away with audio threshold 5")
}

test("Nearby bookmark detected before current position") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 100)]
    let result = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 93, threshold: 10)
    try assertTrue(result != nil, "Should find bookmark 7 chars behind with threshold 10")
}

// ---- Overlap Prevention Tests ----
print("\n--- Bookmark Overlap Prevention Tests ---")

test("No overlap returns original position") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 50)]
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 200, threshold: 10)
    try assertEqual(result, 200, "Should return original offset when no overlap")
}

test("Overlap nudges forward when position is at or after conflict") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 100)]
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 105, threshold: 10)
    try assertEqual(result, 111, "Should nudge to conflict + threshold + 1 = 111")
}

test("Overlap nudges backward when position is before conflict") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 100)]
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 95, threshold: 10)
    try assertEqual(result, 89, "Should nudge to conflict - threshold - 1 = 89")
}

test("Backward nudge clamps to zero") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 5)]
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 3, threshold: 10)
    try assertEqual(result, 0, "Should clamp to 0 when nudge would go negative")
}

test("Different chapter bookmarks don't cause overlap") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 1, characterOffset: 100)]
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 100, threshold: 10)
    try assertEqual(result, 100, "Bookmark in different chapter should not conflict")
}

test("Exact position conflict nudges forward") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 100)]
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 100, threshold: 10)
    try assertEqual(result, 111, "Same position nudges forward to threshold + 1")
}

test("Multiple bookmarks: first conflict is resolved") {
    let bookmarks = [
        TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 50),
        TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 200),
    ]
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 55, threshold: 10)
    try assertEqual(result, 61, "Should resolve conflict with first overlapping bookmark")
}

} // end runBookmarkToggleTests
