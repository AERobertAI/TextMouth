import Foundation
#if canImport(TextMouth)
@testable import TextMouth
#endif

// Mirror the Bookmark struct for testing proximity logic
private struct TestBookmark {
    let id: UUID
    var chapterIndex: Int
    var characterOffset: Int
}

/// Find the closest bookmark within the proximity threshold of the given position.
/// Only matches bookmarks in the same chapter. When multiple bookmarks fall
/// within range, returns the one with the smallest distance.
private func nearbyBookmark(
    bookmarks: [TestBookmark],
    chapterIndex: Int,
    characterOffset: Int,
    threshold: Int
) -> TestBookmark? {
#if canImport(TextMouth)
    let productionBookmarks = bookmarks.enumerated().map { index, bookmark in
        Bookmark(
            id: bookmark.id,
            number: index + 1,
            chapterIndex: bookmark.chapterIndex,
            characterOffset: bookmark.characterOffset
        )
    }
    guard let match = ReaderViewModel.nearbyBookmark(
        in: productionBookmarks,
        chapterIndex: chapterIndex,
        characterOffset: characterOffset,
        threshold: threshold
    ) else {
        return nil
    }
    return bookmarks.first(where: { $0.id == match.id })
#else
    bookmarks
        .filter { $0.chapterIndex == chapterIndex && abs($0.characterOffset - characterOffset) <= threshold }
        .min(by: { abs($0.characterOffset - characterOffset) < abs($1.characterOffset - characterOffset) })
#endif
}

/// Adjust a bookmark offset so it doesn't land within the proximity zone
/// of any existing bookmark in the same chapter. First tries nudging backward;
/// if that still conflicts, scans forward through sorted bookmarks, jumping
/// past each conflicting zone in turn.
private func adjustedBookmarkOffset(
    bookmarks: [TestBookmark],
    chapterIndex: Int,
    characterOffset: Int,
    threshold: Int
) -> Int {
#if canImport(TextMouth)
    let productionBookmarks = bookmarks.enumerated().map { index, bookmark in
        Bookmark(
            id: bookmark.id,
            number: index + 1,
            chapterIndex: bookmark.chapterIndex,
            characterOffset: bookmark.characterOffset
        )
    }
    return ReaderViewModel.adjustedBookmarkOffset(
        bookmarks: productionBookmarks,
        chapterIndex: chapterIndex,
        characterOffset: characterOffset,
        threshold: threshold,
        chapterLength: nil
    )
#else
    let sameChapter = bookmarks
        .filter { $0.chapterIndex == chapterIndex }
        .sorted(by: { $0.characterOffset < $1.characterOffset })

    guard sameChapter.contains(where: { abs($0.characterOffset - characterOffset) <= threshold }) else {
        return characterOffset
    }

    // Try backward nudge first
    if let first = sameChapter.first(where: { abs($0.characterOffset - characterOffset) <= threshold }),
       characterOffset < first.characterOffset {
        let candidate = max(0, first.characterOffset - threshold - 1)
        if !sameChapter.contains(where: { abs($0.characterOffset - candidate) <= threshold }) {
            return candidate
        }
    }

    // Forward scan: walk through sorted bookmarks, jumping past each conflict
    var adjusted = characterOffset
    for bm in sameChapter {
        if abs(bm.characterOffset - adjusted) <= threshold {
            adjusted = bm.characterOffset + threshold + 1
        }
    }
    return adjusted
#endif
}

@MainActor
func runBookmarkToggleTests() {

// ====================================================================
// Proximity Detection — Basic
// ====================================================================
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
    let found = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 105, threshold: 5)
    try assertTrue(found != nil, "Should find bookmark 5 chars away with audio threshold")
    let notFound = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 106, threshold: 5)
    try assertTrue(notFound == nil, "Should not find bookmark 6 chars away with audio threshold 5")
}

test("Nearby bookmark detected before current position") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 100)]
    let result = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 93, threshold: 10)
    try assertTrue(result != nil, "Should find bookmark 7 chars behind with threshold 10")
}

// ====================================================================
// Proximity Detection — Edge Cases
// ====================================================================
print("\n--- Proximity Detection Edge Cases ---")

test("Empty bookmarks array returns nil") {
    let result = nearbyBookmark(bookmarks: [], chapterIndex: 0, characterOffset: 50, threshold: 10)
    try assertTrue(result == nil, "Empty array should always return nil")
}

test("Position at zero with bookmark at zero is found") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 0)]
    let result = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 0, threshold: 10)
    try assertTrue(result != nil, "Zero-zero should match")
}

test("Position at zero with bookmark just within threshold") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 10)]
    let result = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 0, threshold: 10)
    try assertTrue(result != nil, "Bookmark at offset 10 from position 0 should match threshold 10")
}

test("Position at zero with bookmark just outside threshold") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 11)]
    let result = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 0, threshold: 10)
    try assertTrue(result == nil, "Bookmark at offset 11 from position 0 should not match threshold 10")
}

test("Large offsets work correctly") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 1_000_000)]
    let found = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 1_000_005, threshold: 10)
    try assertTrue(found != nil, "Should find bookmark at large offset within threshold")
    let notFound = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 1_000_011, threshold: 10)
    try assertTrue(notFound == nil, "Should not find bookmark at large offset beyond threshold")
}

test("Multiple bookmarks in same chapter: closest one is returned") {
    let bm1 = TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 95)
    let bm2 = TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 105)
    // Position 100: bm1 is 5 away, bm2 is 5 away — both in range.
    // When equidistant, either is acceptable, but result must be one of them.
    let result = nearbyBookmark(bookmarks: [bm1, bm2], chapterIndex: 0, characterOffset: 100, threshold: 10)
    try assertTrue(result != nil, "Should find one of the two equidistant bookmarks")
}

test("Multiple bookmarks: nearer one returned regardless of array order") {
    let far = TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 90)
    let near = TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 98)
    // Position 100: far is 10 away, near is 2 away. Both in range.
    // Should return near regardless of array order.
    let resultFarFirst = nearbyBookmark(bookmarks: [far, near], chapterIndex: 0, characterOffset: 100, threshold: 10)
    try assertTrue(resultFarFirst != nil, "Should find a bookmark")
    try assertEqual(resultFarFirst!.characterOffset, 98, "Should return the closer bookmark (98) not the farther (90) — array order [far, near]")

    let resultNearFirst = nearbyBookmark(bookmarks: [near, far], chapterIndex: 0, characterOffset: 100, threshold: 10)
    try assertEqual(resultNearFirst!.characterOffset, 98, "Should return the closer bookmark (98) — array order [near, far]")
}

test("Multiple bookmarks across chapters: only same-chapter matched") {
    let sameChapter = TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 100)
    let otherChapter = TestBookmark(id: UUID(), chapterIndex: 1, characterOffset: 50)
    let result = nearbyBookmark(bookmarks: [otherChapter, sameChapter], chapterIndex: 0, characterOffset: 105, threshold: 10)
    try assertTrue(result != nil, "Should find same-chapter bookmark")
    try assertEqual(result!.characterOffset, 100, "Should match the chapter-0 bookmark")
}

test("Threshold of zero: only exact match") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 100)]
    let exact = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 100, threshold: 0)
    try assertTrue(exact != nil, "Threshold 0 should match exact position")
    let off1 = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 101, threshold: 0)
    try assertTrue(off1 == nil, "Threshold 0 should not match 1 char away")
}

test("Threshold of 1: matches within 1 character") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 100)]
    let before = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 99, threshold: 1)
    try assertTrue(before != nil, "Should match 1 char before")
    let after = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 101, threshold: 1)
    try assertTrue(after != nil, "Should match 1 char after")
    let tooFar = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 102, threshold: 1)
    try assertTrue(tooFar == nil, "Should not match 2 chars away")
}

test("Many bookmarks in same chapter: correct closest found") {
    var bookmarks: [TestBookmark] = []
    // Place bookmarks every 50 chars from 0 to 500
    for i in stride(from: 0, through: 500, by: 50) {
        bookmarks.append(TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: i))
    }
    // Position 227: closest bookmark is 250 (23 away) vs 200 (27 away)
    let result = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 227, threshold: 30)
    try assertTrue(result != nil, "Should find a bookmark within threshold 30")
    try assertEqual(result!.characterOffset, 250, "Should return closest bookmark (250) not 200")
}

test("High chapter index works correctly") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 99, characterOffset: 500)]
    let result = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 99, characterOffset: 505, threshold: 10)
    try assertTrue(result != nil, "Should match in high chapter index")
}

// ====================================================================
// Overlap Prevention — Basic
// ====================================================================
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

test("Backward nudge near zero: clamp fails so forward scan used") {
    // Bookmark at 5, threshold 10, position 3.
    // Backward: candidate max(0, 5-10-1)=0, but |0-5|=5<=10 conflicts.
    // Forward: bm5 |5-3|=2<=10 → 16.
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 5)]
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 3, threshold: 10)
    try assertEqual(result, 16, "Backward clamp conflicts, forward scan to 5+10+1=16")
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

// ====================================================================
// Overlap Prevention — Edge Cases
// ====================================================================
print("\n--- Overlap Prevention Edge Cases ---")

test("Empty bookmarks returns original position") {
    let result = adjustedBookmarkOffset(bookmarks: [], chapterIndex: 0, characterOffset: 100, threshold: 10)
    try assertEqual(result, 100, "Empty array should return original position")
}

test("Cascading overlap: nudge forward into second bookmark's zone") {
    // Bookmarks at 50 and 70, threshold 10. Position 55.
    // Forward scan: bm50 |50-55|=5<=10 → 61, bm70 |70-61|=9<=10 → 81
    let bookmarks = [
        TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 50),
        TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 70),
    ]
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 55, threshold: 10)
    try assertEqual(result, 81, "Should cascade past both bookmarks to 70+10+1=81")
    try assertTrue(abs(result - 50) > 10, "Result must be more than 10 from bookmark at 50")
    try assertTrue(abs(result - 70) > 10, "Result must be more than 10 from bookmark at 70")
}

test("Bracketed position: bookmarks on both sides") {
    // Bookmarks at 90 and 120, threshold 10. Position 105.
    // Conflicts with 90 (|105-90|=15 > 10)? No. With 120 (|105-120|=15 > 10)? No.
    // Actually 15 > 10 so no conflict at all — should return 105.
    let bookmarks = [
        TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 90),
        TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 120),
    ]
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 105, threshold: 10)
    try assertEqual(result, 105, "Position between well-separated bookmarks should be unchanged")
}

test("Tight bracket: bookmarks close on both sides") {
    // Bookmarks at 95 and 115, threshold 10. Position 105.
    // Forward scan: bm95 |95-105|=10<=10 → 106, bm115 |115-106|=9<=10 → 126
    // The zones overlap so the forward scan escapes past the rightmost bookmark.
    let bookmarks = [
        TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 95),
        TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 115),
    ]
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 105, threshold: 10)
    try assertEqual(result, 126, "Should escape past rightmost bookmark to 115+10+1=126")
    try assertTrue(abs(result - 95) > 10, "Must be clear of 95")
    try assertTrue(abs(result - 115) > 10, "Must be clear of 115")
}

test("Three bookmarks: cascading through all") {
    // Bookmarks at 50, 80, 110 with threshold 10. Position 55.
    // First conflict: 50 → nudge to 61
    // Second conflict: 80 (|61-80|=19 > 10) → no conflict, returns 61
    let bookmarks = [
        TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 50),
        TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 80),
        TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 110),
    ]
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 55, threshold: 10)
    try assertTrue(abs(result - 50) > 10, "Must be clear of bookmark at 50")
    try assertTrue(abs(result - 80) > 10, "Must be clear of bookmark at 80")
    try assertTrue(abs(result - 110) > 10, "Must be clear of bookmark at 110")
    print("    Three-bookmark cascade resolved to offset \(result)")
}

test("Position at zero, bookmark at zero: nudges forward") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 0)]
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 0, threshold: 10)
    try assertEqual(result, 11, "Same position at zero nudges to threshold + 1")
}

test("Position at zero, bookmark at 5: backward clamp fails, forward scan escapes") {
    // Position 2, bookmark at 5, threshold 10.
    // Backward try: candidate max(0, 5-10-1)=0, but |0-5|=5<=10 still conflicts.
    // Forward scan: bm5 |5-2|=3<=10 → 16.
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 5)]
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 2, threshold: 10)
    try assertEqual(result, 16, "Backward clamp conflicts, forward scan to 5+10+1=16")
}

test("Many bookmarks in different chapters: only same chapter conflicts") {
    let bookmarks = [
        TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 100),
        TestBookmark(id: UUID(), chapterIndex: 1, characterOffset: 100),
        TestBookmark(id: UUID(), chapterIndex: 2, characterOffset: 100),
        TestBookmark(id: UUID(), chapterIndex: 3, characterOffset: 100),
    ]
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 1, characterOffset: 105, threshold: 10)
    try assertEqual(result, 111, "Should only conflict with chapter 1 bookmark")
}

test("Audio threshold: overlap prevention with threshold 5") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 100)]
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 103, threshold: 5)
    try assertEqual(result, 106, "Audio: 103 near 100 (3<=5), nudges forward to 100+5+1=106")
}

test("Backward nudge succeeds when there is clear space behind") {
    // Bookmark at 100, threshold 10, position 95.
    // 95 < 100, backward candidate = max(0, 100-10-1) = 89.
    // Check: |89-100|=11 > 10, no conflict. Return 89.
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 100)]
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 95, threshold: 10)
    try assertEqual(result, 89, "Backward nudge should succeed to 100-10-1=89")
}

test("Backward nudge blocked by another bookmark falls through to forward") {
    // Bookmarks at 30 and 50, threshold 10, position 45.
    // 45 < 50, backward candidate = max(0, 50-10-1) = 39.
    // Check: |39-30|=9 <= 10, conflicts! Backward fails.
    // Forward scan (sorted 30,50): bm30 |30-45|=15>10 skip, bm50 |50-45|=5<=10 → 61.
    let bookmarks = [
        TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 30),
        TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 50),
    ]
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 45, threshold: 10)
    try assertEqual(result, 61, "Backward blocked by bm30, forward scan to 50+10+1=61")
}

test("Nudge result is exactly threshold+1 from conflict") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 50)]
    let fwd = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 55, threshold: 10)
    try assertEqual(abs(fwd - 50), 11, "Forward nudge should place exactly threshold+1 from conflict")
    let bwd = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 45, threshold: 10)
    try assertEqual(abs(bwd - 50), 11, "Backward nudge should place exactly threshold+1 from conflict")
}

// ====================================================================
// Toggle Round-Trip Simulation
// ====================================================================
print("\n--- Bookmark Toggle Round-Trip Tests ---")

test("Toggle at empty position adds, toggle again at same position removes") {
    var bookmarks: [TestBookmark] = []
    let pos = 100
    let threshold = 10

    // Toggle 1: no nearby bookmark → add
    let nearby1 = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: pos, threshold: threshold)
    try assertTrue(nearby1 == nil, "First toggle should not find a bookmark")
    // Simulate adding
    bookmarks.append(TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: pos))
    try assertEqual(bookmarks.count, 1)

    // Toggle 2: nearby bookmark exists → remove
    let nearby2 = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: pos, threshold: threshold)
    try assertTrue(nearby2 != nil, "Second toggle should find the bookmark")
    // Simulate removing
    bookmarks.removeAll { $0.characterOffset == nearby2!.characterOffset && $0.chapterIndex == 0 }
    try assertEqual(bookmarks.count, 0, "Bookmark should be removed")
}

test("Toggle near existing bookmark removes it, not a new one") {
    let bm = TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 100)
    let bookmarks = [bm]
    // Position 107 is within threshold 10 of bookmark at 100
    let nearby = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 107, threshold: 10)
    try assertTrue(nearby != nil, "Should detect bookmark 7 chars away")
    try assertEqual(nearby!.id, bm.id, "Should return the specific nearby bookmark")
}

test("Toggle at position with no nearby bookmark but overlap needed") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 100)]
    let pos = 108

    // First check: is there a nearby bookmark? Yes, at 100 (8 away, within 10)
    let nearby = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: pos, threshold: 10)
    try assertTrue(nearby != nil, "Should find nearby bookmark at 100")
    // This means toggle removes — NOT add. So overlap adjustment never happens.
    // This is the correct behavior: you can't accidentally add when you're near an existing one.
}

test("Toggle at position just outside threshold adds with no adjustment") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 100)]
    let pos = 111
    let threshold = 10

    // 111 is 11 away from 100 — not nearby
    let nearby = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: pos, threshold: threshold)
    try assertTrue(nearby == nil, "Should not find bookmark 11 chars away")

    // No overlap either since 111 is outside threshold of 100
    let adjusted = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: pos, threshold: threshold)
    try assertEqual(adjusted, 111, "Should use original position, no overlap")
}

// ====================================================================
// Keyboard Shortcut Completeness Tests
// ====================================================================
print("\n--- Keyboard Shortcut Completeness Tests ---")

test("Every ShortcutAction has a unique raw value") {
    var seen: [String: ShortcutAction] = [:]
    for action in ShortcutAction.allCases {
        if let existing = seen[action.rawValue] {
            throw TestError.assertionFailed("Duplicate raw value '\(action.rawValue)' for \(action) and \(existing)")
        }
        seen[action.rawValue] = action
    }
    print("    All \(ShortcutAction.allCases.count) actions have unique raw values")
}

test("Every ShortcutAction has a non-empty category") {
    for action in ShortcutAction.allCases {
        try assertTrue(!action.category.isEmpty, "\(action.rawValue) should have a category")
    }
}

test("Every ShortcutAction has a default binding entry") {
    let defaults = ShortcutAction.defaultBindings
    for action in ShortcutAction.allCases {
        let bindings = defaults[action]
        try assertTrue(bindings != nil, "\(action.rawValue) should have a default binding entry")
        // Release Media Controls, the reading list's four commands (FR09),
        // and Speak Import Progress and Speak Download Progress (FR10) have
        // no keys until the user gives them some.
        if ![
            .releaseMediaControls, .addToReadingList, .removeFromReadingList,
            .nextInReadingList, .previousInReadingList, .speakImportProgress,
            .speakDownloadProgress,
        ].contains(action) {
            try assertTrue(!bindings!.isEmpty, "\(action.rawValue) should have at least one default binding")
        }
    }
}

test("No default binding is shared between actions of one scope") {
    // The audio editor's actions, matched only in its windows, may share a
    // key with an action that works everywhere else (ShortcutScope); in
    // each kind of window a key means one thing, so actions working in
    // different kinds of window may share one, as New from Text and Show
    // Sleep Timer share Shift-Command-T (FR12's branch E).
    let defaults = ShortcutAction.defaultBindings
    let clashes = ShortcutKeyOwners.keysOnTwoActions(in: defaults)
    if !clashes.isEmpty {
        throw TestError.assertionFailed("Bindings shared: \(clashes.joined(separator: "; "))")
    }
    print("    All \(defaults.values.map(\.count).reduce(0, +)) bindings are unique within their kinds of window")
}

test("Panel shortcuts have the expected categories") {
    try assertEqual(ShortcutAction.showHeadingList.category, "Panels")
    try assertEqual(ShortcutAction.showBookmarkList.category, "Bookmarks")
    try assertEqual(ShortcutAction.showSleepTimer.category, "Panels")
    try assertEqual(ShortcutAction.addBookmark.category, "Bookmarks")
}

test("Panel shortcuts accessible display strings are correct") {
    let headingBinding = KeyBinding(key: "h", command: true, shift: true)
    try assertEqual(headingBinding.accessibleDisplayString, "Shift + Command + H")

    let bookmarkListBinding = KeyBinding(key: "b", command: true, shift: true)
    try assertEqual(bookmarkListBinding.accessibleDisplayString, "Shift + Command + B")

    let sleepTimerBinding = KeyBinding(key: "t", command: true, shift: true)
    try assertEqual(sleepTimerBinding.accessibleDisplayString, "Shift + Command + T")
}

test("Next Bookmark binding differs from Show Bookmarks binding") {
    let defaults = ShortcutAction.defaultBindings
    let nextBm = defaults[.nextBookmark]!.first!
    let showBm = defaults[.showBookmarkList]!.first!
    try assertTrue(nextBm != showBm, "Next Bookmark and Show Bookmarks must have different bindings")
    // Next Bookmark should have option modifier, Show Bookmarks should not
    try assertTrue(nextBm.option, "Next Bookmark should have option modifier")
    try assertTrue(!showBm.option, "Show Bookmarks should not have option modifier")
}

test("All bookmark-related actions have distinct default bindings") {
    let defaults = ShortcutAction.defaultBindings
    let bookmarkActions: [ShortcutAction] = [.addBookmark, .nextBookmark, .previousBookmark, .showBookmarkList]
    var allBindings: [KeyBinding] = []
    for action in bookmarkActions {
        let bindings = defaults[action] ?? []
        for binding in bindings {
            try assertTrue(!allBindings.contains(binding), "Duplicate binding \(binding.displayString) in bookmark actions")
            allBindings.append(binding)
        }
    }
    print("    All \(allBindings.count) bookmark-related bindings are distinct")
}

test("ShortcutAction round-trips through rawValue") {
    for action in ShortcutAction.allCases {
        let restored = ShortcutAction(rawValue: action.rawValue)
        try assertTrue(restored != nil, "\(action.rawValue) should round-trip")
        try assertTrue(restored == action, "\(action.rawValue) should restore to same case")
    }
}

test("ShortcutAction JSON encode/decode preserves all cases") {
    for action in ShortcutAction.allCases {
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(ShortcutAction.self, from: data)
        try assertTrue(decoded == action, "\(action.rawValue) should survive JSON round-trip")
    }
}

// ====================================================================
// Stress / Boundary Tests
// ====================================================================
print("\n--- Stress & Boundary Tests ---")

test("Proximity with single-char bookmark positions 0 and 1") {
    let bookmarks = [
        TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 0),
        TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 1),
    ]
    let atZero = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 0, threshold: 0)
    try assertTrue(atZero != nil, "Should find bookmark at exact position 0")
    try assertEqual(atZero!.characterOffset, 0, "Closest to 0 should be 0")

    let atOne = nearbyBookmark(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 1, threshold: 0)
    try assertTrue(atOne != nil, "Should find bookmark at exact position 1")
    try assertEqual(atOne!.characterOffset, 1, "Closest to 1 should be 1")
}

test("Overlap prevention: bookmark at 0, position 0, clamp edge") {
    let bookmarks = [TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 0)]
    // Position 0, conflicts with 0, since 0 >= 0, nudges forward to 0 + threshold + 1
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 0, threshold: 5)
    try assertEqual(result, 6, "0 + 5 + 1 = 6")
}

test("Overlap prevention: dense bookmarks every threshold apart") {
    // Bookmarks at 0, 11, 22, 33, 44 (each exactly threshold+1 apart with threshold 10)
    // Adding at 5 should conflict with 0, nudge to 11, conflict with 11, nudge to 22, ...
    // Eventually settle at a safe spot or exhaust iterations.
    let bookmarks = (0..<5).map { TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: $0 * 11) }
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 5, threshold: 10)
    // Each bookmark zone covers [bm-10, bm+10]. So:
    // 0: [-10, 10], 11: [1, 21], 22: [12, 32], 33: [23, 43], 44: [34, 54]
    // Nudging 5 → 11 (0+10+1) → 22 (11+10+1) → 33 (22+10+1) → 44 (33+10+1) → 55 (44+10+1)
    // 55 is clear of all zones
    try assertEqual(result, 55, "Should cascade through all 5 bookmarks to reach 55")
}

test("Overlapping zones: forward scan escapes past both") {
    // Bookmarks at 0 and 10, threshold 10
    // Zone 0: [-10, 10], Zone 10: [0, 20]
    // Forward scan: bm0 |0-5|=5<=10 → 11, bm10 |10-11|=1<=10 → 21
    let bookmarks = [
        TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 0),
        TestBookmark(id: UUID(), chapterIndex: 0, characterOffset: 10),
    ]
    let result = adjustedBookmarkOffset(bookmarks: bookmarks, chapterIndex: 0, characterOffset: 5, threshold: 10)
    try assertEqual(result, 21, "Forward scan should escape past bm10 to 10+10+1=21")
    try assertTrue(abs(result - 0) > 10, "Must be clear of 0")
    try assertTrue(abs(result - 10) > 10, "Must be clear of 10")
}

} // end runBookmarkToggleTests
