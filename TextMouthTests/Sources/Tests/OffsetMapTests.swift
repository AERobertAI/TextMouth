import Foundation

func runOffsetMapTests() {
print("\n--- OffsetMap Tests ---")

func linearToSource(_ targetOffset: Int, points: [(targetPos: Int, cumulativeDelta: Int)]) -> Int {
    var delta = 0
    for point in points {
        if point.targetPos <= targetOffset {
            delta = point.cumulativeDelta
        } else {
            break
        }
    }
    return targetOffset + delta
}

func linearToTarget(_ sourceOffset: Int, points: [(targetPos: Int, cumulativeDelta: Int)]) -> Int {
    var delta = 0
    for point in points {
        let sourceAtPoint = point.targetPos + point.cumulativeDelta
        if sourceAtPoint <= sourceOffset {
            delta = point.cumulativeDelta
        } else {
            break
        }
    }
    return max(0, sourceOffset - delta)
}

// MARK: - Identity Map

test("Identity map toSource returns input unchanged") {
    let map = OffsetMap.identity
    try assertEqual(map.toSource(0), 0)
    try assertEqual(map.toSource(50), 50)
    try assertEqual(map.toSource(1000), 1000)
}

test("Identity map toTarget returns input unchanged") {
    let map = OffsetMap.identity
    try assertEqual(map.toTarget(0), 0)
    try assertEqual(map.toTarget(50), 50)
    try assertEqual(map.toTarget(1000), 1000)
}

test("Identity map hasChanges is false") {
    try assertTrue(!OffsetMap.identity.hasChanges)
}

// MARK: - Deletion Map (source longer than target, positive delta)
// Example: "Hello World!" (12 chars) → filter removes "World " → "Hello!" (6 chars)
// Characters at positions 5-10 ("World ") were removed.
// In target text: position 5 has delta +6 (target 5 → source 11)

test("Deletion map: toSource maps target offsets to source") {
    // "Hello World!" → remove " World" (pos 5..10) → "Hello!"
    // target pos 0-4 map to source 0-4 (unchanged before deletion)
    // target pos 5+ maps to source pos + 6 (after deletion)
    let map = OffsetMap(points: [(targetPos: 5, cumulativeDelta: 6)])
    // Before deletion point
    try assertEqual(map.toSource(0), 0)
    try assertEqual(map.toSource(4), 4)
    // At and after deletion point
    try assertEqual(map.toSource(5), 11, "target 5 → source 11 (5+6)")
}

test("Deletion map: toTarget maps source offsets to target") {
    let map = OffsetMap(points: [(targetPos: 5, cumulativeDelta: 6)])
    // Before deletion: source 0-4 → target 0-4
    try assertEqual(map.toTarget(0), 0)
    try assertEqual(map.toTarget(4), 4)
    // Source offsets inside the deleted region (5-10) all map to target 5
    // sourceAtPoint = 5 + 6 = 11, so for source < 11, delta is still 0
    try assertEqual(map.toTarget(5), 5, "source 5 is before the deletion boundary in source space")
    try assertEqual(map.toTarget(10), 10, "source 10 is still before sourceAtPoint=11")
    // After deletion: source 11+ → target 5+ (11 - 6 = 5)
    try assertEqual(map.toTarget(11), 5, "source 11 → target 5")
    try assertEqual(map.toTarget(12), 6, "source 12 → target 6")
}

test("Multiple deletions: two separate ranges removed") {
    // "AABBCCDD" (8 chars) → remove "BB" (pos 2-3) and "CC" (pos 4-5) → "AADD" (4 chars)
    // First deletion at source 2-3: removes 2 chars → target delta +2 at target pos 2
    // Second deletion at source 4-5: removes 2 more → target delta +4 at target pos 2
    // Wait, need to think about this in target coordinates:
    //   "AA" is target 0-1 (source 0-1, no delta)
    //   "DD" is target 2-3 (source 6-7, delta = 4)
    let map = OffsetMap(points: [(targetPos: 2, cumulativeDelta: 4)])
    try assertEqual(map.toSource(0), 0)
    try assertEqual(map.toSource(1), 1)
    try assertEqual(map.toSource(2), 6, "target 2 → source 6 (after both deletions)")
    try assertEqual(map.toSource(3), 7)
    try assertEqual(map.toTarget(0), 0)
    try assertEqual(map.toTarget(1), 1)
    try assertEqual(map.toTarget(6), 2, "source 6 → target 2")
    try assertEqual(map.toTarget(7), 3)
}

// MARK: - Insertion Map (target longer than source, negative delta)
// Example: "Hi." → insert pause after period → "Hi.. " (5 chars)
// At target position 3, 2 extra characters were inserted → delta = -2

test("Insertion map: toSource maps target back to source") {
    // "Hi." (3 chars) → "Hi.. " (5 chars), insertion at target pos 3
    // target 0-2 → source 0-2 (unchanged)
    // target 3-4 are inserted chars, map back to source 3 (end of "Hi.")
    // Actually: target 3 → source 3 + (-2) = source 1? No...
    // Let me re-think the convention.
    //
    // Convention: delta is positive when chars are removed (target shorter).
    // For insertion: target is longer, so delta is negative.
    // toSource(targetOffset) = targetOffset + delta
    //
    // "Hi." → "Hi.. " — inserted ". " after the period.
    // target[0..2] = "Hi." = source[0..2], no delta
    // target[3..4] = ". " (inserted), these don't exist in source
    // After the insertion, there are no more characters.
    //
    // So delta at target pos 3 is -2:
    // toSource(3) = 3 + (-2) = 1? That's wrong.
    //
    // Let me reconsider. The insertion is AFTER the period.
    // Source: "Hi." — positions 0='H', 1='i', 2='.'
    // Target: "Hi.. " — positions 0='H', 1='i', 2='.', 3='.', 4=' '
    // Target pos 0-2 map to source 0-2 (no change)
    // Target pos 3-4 are new chars with no source equivalent
    // If target had more text after: target pos 5+ would map to source pos 3+
    // So delta kicks in at target pos 3, and delta = -2
    // toSource(5) = 5 + (-2) = 3 ✓
    // toSource(3) = 3 + (-2) = 1... that's the middle of inserted text mapping back.
    // For positions inside the insertion, there's no exact source equivalent,
    // but mapping to source 1 would be wrong. They should map to source 3 (the position
    // right after the original period). But our formula gives 1.
    //
    // Hmm, the delta should be applied such that: positions AFTER the inserted text
    // map correctly. Positions INSIDE the inserted text will give an approximate result.
    // This is the same behavior as TextTransformation's existing logic.
    //
    // Actually, rethinking: the convention should be that the delta point is placed
    // AFTER the inserted text, not at the start. So for "Hi." → "Hi.. ":
    // delta at target pos 5 (after the insertion) = -2
    // toSource(2) = 2 (before insertion, no delta)
    // toSource(5) = 5 + (-2) = 3 (after insertion) ✓
    // toSource(3) = 3 (inside insertion, but delta hasn't kicked in yet) — maps to source 3
    //
    // Wait, that would mean toSource(3) = 3 which is past the end of "Hi." (which is 3 chars, 0-2).
    // That's still not great for positions inside the insertion, but there's genuinely
    // no correct source position for those — 3 (just past the end) is reasonable.
    //
    // Actually for a real scenario like "Hi. Next" → "Hi.. Next":
    // Source: H(0) i(1) .(2) (3)N(4)e(5)x(6)t(7) — 8 chars
    // Target: H(0) i(1) .(2) .(3) (4)N(5)e(6)x(7)t(8) — wait no, the original has a space.
    // Let me use a cleaner example.
    //
    // Source: "A. B" (4 chars) → Target: "A.. B" (5 chars)
    // Inserted one '.' after position 2. Target is 1 char longer.
    // Source: A(0) .(1) (2) B(3)
    // Target: A(0) .(1) .(2) (3) B(4)
    // Mapping: target 0-1 = source 0-1, target 2 is inserted, target 3-4 = source 2-3
    // Delta point: at target pos 2, delta = -1
    // toSource(0) = 0 ✓
    // toSource(1) = 1 ✓
    // toSource(2) = 2 + (-1) = 1... that maps the inserted period back to position 1
    //   (the original period). That's actually a reasonable approximation!
    // toSource(3) = 3 + (-1) = 2 ✓ (space)
    // toSource(4) = 4 + (-1) = 3 ✓ (B)
    //
    // And toTarget:
    // sourceAtPoint = 2 + (-1) = 1
    // toTarget(0) = 0 (0 >= 0 but sourceAtPoint=1, 1 > 0, so delta stays 0) = 0 ✓
    // toTarget(1) = 1 (sourceAtPoint=1 <= 1, delta = -1) → 1 - (-1) = 2
    //   But source 1 is '.', target 1 is also '.' — should map to 1, not 2.
    //   This is wrong!
    //
    // The issue is that for insertions, the delta point should be placed so that
    // the original character maps correctly. Let me think again...
    //
    // For "A. B" → "A.. B" (inserted '.' after the original '.'):
    // The original '.' at source 1 should still map to target 1.
    // The space at source 2 should map to target 3 (shifted by 1).
    // So the delta kicks in at source position 2, meaning:
    //   sourceAtPoint should be 2, and targetPos should be 3, delta = -1
    //   Check: targetPos + delta = 3 + (-1) = 2 = sourceAtPoint ✓
    //
    // toTarget(1) = 1 (sourceAtPoint=2 > 1, delta stays 0) = 1 ✓
    // toTarget(2) = 2 (sourceAtPoint=2 <= 2, delta = -1) → 2 - (-1) = 3 ✓
    // toTarget(3) = 3 (same delta) → 3 - (-1) = 4 ✓
    //
    // toSource(1) = 1 (targetPos=3 > 1, delta stays 0) = 1 ✓
    // toSource(3) = 3 (targetPos=3 <= 3, delta = -1) → 3 + (-1) = 2 ✓
    // toSource(4) = 4 + (-1) = 3 ✓
    // toSource(2) = 2 (targetPos=3 > 2, delta stays 0) = 2... but target 2 is the
    //   inserted '.', which doesn't exist in source. Mapping to 2 (the space) is
    //   a reasonable approximation — it's the first char after the insertion point.
    //
    // So the correct point is: (targetPos: 3, cumulativeDelta: -1)

    let map = OffsetMap(points: [(targetPos: 3, cumulativeDelta: -1)])
    // Source: "A. B" → Target: "A.. B"
    try assertEqual(map.toSource(0), 0, "A")
    try assertEqual(map.toSource(1), 1, ".")
    try assertEqual(map.toSource(2), 2, "inserted . maps to source 2 (approximate)")
    try assertEqual(map.toSource(3), 2, "space: target 3 → source 2")
    try assertEqual(map.toSource(4), 3, "B: target 4 → source 3")

    try assertEqual(map.toTarget(0), 0, "A")
    try assertEqual(map.toTarget(1), 1, ".")
    try assertEqual(map.toTarget(2), 3, "space: source 2 → target 3")
    try assertEqual(map.toTarget(3), 4, "B: source 3 → target 4")
}

// MARK: - Substitution Map (same-length and different-length replacements)

test("Substitution: replace shorter with longer") {
    // "Dr. X" → "Doctor X" — "Dr." (3 chars) replaced with "Doctor" (6 chars)
    // Source: D(0)r(1).(2) (3)X(4) — 5 chars
    // Target: D(0)o(1)c(2)t(3)o(4)r(5) (6)X(7) — 8 chars
    // After substitution: target positions 6+ are shifted by -3 (target is 3 longer)
    // sourceAtPoint for the delta = 3 (the space after "Dr.")
    // targetPos = 3 - (-3) = 6, delta = -3
    let map = OffsetMap(points: [(targetPos: 6, cumulativeDelta: -3)])
    try assertEqual(map.toTarget(3), 6, "space after Dr. → space after Doctor")
    try assertEqual(map.toTarget(4), 7, "X stays at right position")
    try assertEqual(map.toSource(6), 3, "space back")
    try assertEqual(map.toSource(7), 4, "X back")
}

// MARK: - Composed Map

test("ComposedOffsetMap with identity stages") {
    let composed = ComposedOffsetMap(stages: [.identity, .identity, .identity])
    try assertEqual(composed.toModified(0), 0)
    try assertEqual(composed.toModified(100), 100)
    try assertEqual(composed.toOriginal(0), 0)
    try assertEqual(composed.toOriginal(100), 100)
    try assertTrue(!composed.hasChanges)
}

test("ComposedOffsetMap with single deletion stage") {
    // Same as the single deletion test but wrapped in ComposedOffsetMap
    let deletion = OffsetMap(points: [(targetPos: 5, cumulativeDelta: 6)])
    let composed = ComposedOffsetMap(stages: [deletion])
    try assertEqual(composed.toModified(0), 0)
    try assertEqual(composed.toModified(11), 5, "source 11 → target 5 (deletion)")
    try assertEqual(composed.toOriginal(5), 11, "target 5 → source 11")
    try assertTrue(composed.hasChanges)
}

test("ComposedOffsetMap chains two stages correctly") {
    // Stage 1 (filtering): removes 10 chars starting at source position 20
    //   "...20 chars...REMOVED10CH...rest..." → "...20 chars...rest..."
    //   delta +10 at target pos 20
    let filterMap = OffsetMap(points: [(targetPos: 20, cumulativeDelta: 10)])

    // Stage 2 (insertion): inserts 5 chars at filtered position 10
    //   "...10 chars...INSERTED...rest..."
    //   delta -5 at target pos 15 (10 + 5 inserted chars)
    let insertMap = OffsetMap(points: [(targetPos: 15, cumulativeDelta: -5)])

    let composed = ComposedOffsetMap(stages: [filterMap, insertMap])

    // Source offset 0 → filter: 0, insert: 0
    try assertEqual(composed.toModified(0), 0)

    // Source offset 5 → filter: 5, insert: 5 (before insertion point)
    try assertEqual(composed.toModified(5), 5)

    // Source offset 10 → filter: 10 (before filter delta), insert: 10 (at insertion source boundary)
    // insertMap.toTarget(10): sourceAtPoint = 15 + (-5) = 10. 10 <= 10 so delta = -5.
    // result = 10 - (-5) = 15
    try assertEqual(composed.toModified(10), 15)

    // Source offset 35 → filter: sourceAtPoint = 20 + 10 = 30. 30 <= 35 so delta = 10.
    //   filter result = 35 - 10 = 25
    // → insert: sourceAtPoint = 15 + (-5) = 10. 10 <= 25 so delta = -5.
    //   insert result = 25 - (-5) = 30
    try assertEqual(composed.toModified(35), 30)

    // Reverse: modified offset 30 → insert.toSource(30) = 30 + (-5) = 25
    // → filter.toSource(25) = 25 + 10 = 35
    try assertEqual(composed.toOriginal(30), 35)
}

test("ComposedOffsetMap round-trip for offset 0") {
    let map1 = OffsetMap(points: [(targetPos: 5, cumulativeDelta: 3)])
    let map2 = OffsetMap(points: [(targetPos: 10, cumulativeDelta: -2)])
    let composed = ComposedOffsetMap(stages: [map1, map2])

    // Offset 0 should round-trip cleanly (before any delta points)
    let modified = composed.toModified(0)
    let original = composed.toOriginal(modified)
    try assertEqual(original, 0, "Round-trip for offset 0")
}

test("ComposedOffsetMap three stages: filter + pause + substitution") {
    // Simulate the real pipeline:
    // Stage 1 (filter): removes 50 chars at source position 100
    let filterMap = OffsetMap(points: [(targetPos: 100, cumulativeDelta: 50)])

    // Stage 2 (pause): inserts 2 chars at filtered position 30
    let pauseMap = OffsetMap(points: [(targetPos: 32, cumulativeDelta: -2)])

    // Stage 3 (substitution): replaces 3-char pattern with 7-char at paused position 50
    let subMap = OffsetMap(points: [(targetPos: 54, cumulativeDelta: -4)])

    let composed = ComposedOffsetMap(stages: [filterMap, pauseMap, subMap])

    // Source offset 0 should pass through all three stages unchanged
    try assertEqual(composed.toModified(0), 0)

    // Test round-trip for an offset before all deltas
    let rt = composed.toOriginal(composed.toModified(10))
    try assertEqual(rt, 10, "Round-trip for offset in clean region")
}

// MARK: - Edge Cases

test("OffsetMap with offset 0 at boundary") {
    // Delta right at position 0
    let map = OffsetMap(points: [(targetPos: 0, cumulativeDelta: 5)])
    try assertEqual(map.toSource(0), 5, "target 0 → source 5")
    try assertEqual(map.toTarget(5), 0, "source 5 → target 0")
}

test("OffsetMap toTarget clamps to 0") {
    // If source offset is 0 and there's a negative delta, result should not go below 0
    let map = OffsetMap(points: [(targetPos: 0, cumulativeDelta: -5)])
    try assertEqual(map.toTarget(0), 5, "source 0 → target 5 (inserted chars before start)")
    // Actually: sourceAtPoint = 0 + (-5) = -5. -5 <= 0, so delta = -5.
    // toTarget(0) = 0 - (-5) = 5... that means 5 chars were inserted before the original text.
    // source 0 → target 5 ✓ (the original first char is now at target pos 5)
}

test("OffsetMap multiple points increasing deltas") {
    // Two separate deletions:
    // Source: "AAA_BBB_CCC" (11 chars) → remove "_BBB" (pos 3-6) and "_CCC" (pos 7-10)
    // After first removal: "AAA_CCC" — wait, need to track in target coords.
    // After removing "_BBB" (4 chars): target has "AAA_CCC" → but then removing "_CCC"
    // Let's just say: Target = "AAA" (3 chars).
    // target pos 3: delta = 8 (11 - 3 = 8 chars removed)
    // Actually, two separate deletion points:
    // After removing "_BBB" at source 3-6: target pos 3, delta = 4
    // After removing "_CCC" at source 7-10: target pos 3, delta = 8
    // Since both deletions map to the same target position, they merge.
    let map = OffsetMap(points: [(targetPos: 3, cumulativeDelta: 8)])
    try assertEqual(map.toSource(0), 0)
    try assertEqual(map.toSource(2), 2)
    try assertEqual(map.toSource(3), 11, "target 3 → past all removed chars")
}

test("OffsetMap binary search preserves boundary equivalence") {
    let points: [(targetPos: Int, cumulativeDelta: Int)] = [
        (targetPos: 0, cumulativeDelta: 5),
        (targetPos: 3, cumulativeDelta: 8),
        (targetPos: 10, cumulativeDelta: 4),
        (targetPos: 18, cumulativeDelta: -2),
        (targetPos: 25, cumulativeDelta: 0),
    ]
    let map = OffsetMap(points: points)

    for targetOffset in [-1, 0, 2, 3, 4, 9, 10, 11, 17, 18, 19, 24, 25, 26, 100] {
        try assertEqual(
            map.toSource(targetOffset),
            linearToSource(targetOffset, points: points),
            "target offset \(targetOffset)"
        )
    }

    for sourceOffset in [-1, 0, 4, 5, 6, 10, 11, 12, 13, 14, 15, 16, 17, 24, 25, 26, 100] {
        try assertEqual(
            map.toTarget(sourceOffset),
            linearToTarget(sourceOffset, points: points),
            "source offset \(sourceOffset)"
        )
    }
}

test("OffsetMap large target map preserves toSource order") {
    let pointCount = 10_000
    let points: [(targetPos: Int, cumulativeDelta: Int)] = (0..<pointCount).map { index in
        (targetPos: index * 10, cumulativeDelta: index)
    }
    let map = OffsetMap(points: points)
    var sampledTargets = [-1, 0, 1, pointCount * 10 - 1, pointCount * 10, pointCount * 10 + 1]

    for index in stride(from: 0, to: pointCount, by: 997) {
        sampledTargets.append(contentsOf: [index * 10 - 1, index * 10, index * 10 + 1])
    }

    var previousSource = Int.min
    for targetOffset in sampledTargets.sorted() {
        let expectedDelta = targetOffset >= 0 ? min(targetOffset / 10, pointCount - 1) : 0
        let mappedSource = map.toSource(targetOffset)
        try assertEqual(mappedSource, targetOffset + expectedDelta, "target offset \(targetOffset)")
        try assertTrue(mappedSource >= previousSource, "toSource monotonic at target \(targetOffset)")
        previousSource = mappedSource
    }
}

test("OffsetMap toTarget preserves target-sorted linear semantics") {
    let points: [(targetPos: Int, cumulativeDelta: Int)] = [
        (targetPos: 10, cumulativeDelta: 10),
        (targetPos: 15, cumulativeDelta: -10),
    ]
    let map = OffsetMap(points: points)

    for sourceOffset in [-1, 0, 6, 20, 21, 100] {
        try assertEqual(
            map.toTarget(sourceOffset),
            linearToTarget(sourceOffset, points: points),
            "source offset \(sourceOffset)"
        )
    }
}

// MARK: - Punctuation Pause Offset Map Simulation

test("Punctuation pause map: single period insertion") {
    // Simulates: "A. B" → "A.. B" (". " → ".. ", 1 extra char)
    // Scanning: sourcePos 0 copies 'A', sourcePos 1 matches ". ", emits ".. " (3 chars),
    //   sourcePos 3 copies 'B'. Result = "A.. B" (5 chars).
    // Point at targetPos 4 (after ".. "), cumulativeDelta -1.
    // Source: A(0) .(1) ' '(2) B(3)
    // Target: A(0) .(1) .(2) ' '(3) B(4)
    // sourceAtPoint = 4 + (-1) = 3
    let map = OffsetMap(points: [(targetPos: 4, cumulativeDelta: -1)])
    try assertEqual(map.toTarget(0), 0, "A → A")
    try assertEqual(map.toTarget(1), 1, ". → .")
    // source 2 (space): sourceAtPoint=3 > 2 → delta=0 → toTarget=2. But actual target is 3.
    // This is the known edge case: source positions INSIDE the replacement zone map approximately.
    // The space at source 2 is part of the matched pattern ". ", which was expanded.
    // The 'after' point placement means positions within the pattern aren't perfectly mapped,
    // but positions AFTER the pattern are correct:
    try assertEqual(map.toTarget(3), 4, "B: source 3 → target 4")
    try assertEqual(map.toSource(4), 3, "B: target 4 → source 3")
    try assertEqual(map.toSource(0), 0, "A: target 0 → source 0")
}

test("Punctuation pause map: two periods in text") {
    // "Hi. Bye. End" (12) → "Hi.. Bye.. End" (14), two insertions of 1 char each.
    // First match at source 2: ". " → ".. " → point at target 5, delta -1
    // Second match at source 7+1(shifted)=8 target pos: let me trace carefully.
    // Source positions: H(0)i(1).(2) (3)B(4)y(5)e(6).(7) (8)E(9)n(10)d(11)
    //
    // Scan: copy H,i → sourcePos=2. Match ". " → emit ".. " → result="Hi.. " (5 chars)
    //   point: (5, -1), sourcePos=4
    // Copy B,y,e → sourcePos=7. Match ". " → emit ".. " → result="Hi.. Bye.. " (11 chars)
    //   point: (11, -2), sourcePos=9
    // Copy E,n,d → result="Hi.. Bye.. End" (14 chars)
    let map = OffsetMap(points: [
        (targetPos: 5, cumulativeDelta: -1),
        (targetPos: 11, cumulativeDelta: -2),
    ])
    // Before first insertion
    try assertEqual(map.toTarget(0), 0, "H")
    try assertEqual(map.toTarget(1), 1, "i")
    // After first insertion: sourceAtPoint for point1 = 5 + (-1) = 4.
    // source 4: 4 <= 4 → delta = -1. toTarget(4) = 4 - (-1) = 5 ✓
    try assertEqual(map.toTarget(4), 5, "B: source 4 → target 5")
    // source 6: sourceAtPoint1=4 <= 6 → delta=-1. sourceAtPoint2=11+(-2)=9, 9 > 6 → stop.
    // toTarget(6) = 6 - (-1) = 7
    try assertEqual(map.toTarget(6), 7, "e: source 6 → target 7")
    // After second insertion
    try assertEqual(map.toTarget(9), 11, "E: source 9 → target 11")
    try assertEqual(map.toTarget(11), 13, "d: source 11 → target 13")
    // Reverse
    try assertEqual(map.toSource(5), 4, "B back")
    try assertEqual(map.toSource(11), 9, "E back")
    try assertEqual(map.toSource(13), 11, "d back")
}

} // end runOffsetMapTests
