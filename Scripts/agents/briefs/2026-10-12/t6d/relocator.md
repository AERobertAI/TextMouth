# t6d task "relocator": a skip that waits names no heading, and the relocator is built only when a place moved

Slug `t6d-relocator`, branch `t6d/relocator`, board task in your launch prompt. Read `worker-common.md` beside this file first. Two commits, in this order.

## Background
`PlaceRelocator` (`TextMouth/Models/PlaceRelocator.swift`, pure) moves a book's places from its old text to its new one. Nothing calls it yet; the team's later tasks will, at every rebuild of a book's text. Two things must change first.

**A waiting skip.** When the relocator finds no heading for a skipped heading, the skip "waits": today `relocate(_:movedAt:)` leaves it in `outcome.places.skippedHeadings`, exactly as it was, with a nil finding. Its saved ID (`SkippedHeading.id`, "<chapter>-<offset>-<level>-<label>") is unchanged, so when the next section of the same label and level slid into the removed section's numbers, that new heading has exactly that ID, and the reader, which matches IDs, would skip it. The fix: the outcome keeps waiting skips apart, and the book will store them apart (another task), naming no heading. A later move gives a waiting skip a heading again only where its heading stands exactly as it was skipped.

**Eager work.** `PlaceRelocator.init` reads both texts' fine words, lines them up with a patience diff, and indexes both texts (about 20 ms for a novel, 130 ms for a long book), even when every place still stands. Most rebuilt books' places stand. A static entry point checks each place directly against the new text first and builds a relocator only when some place does not stand.

## Read (by line range)
- `TextMouth/Models/PlaceRelocator.swift`: the type's doc, lines 1-120 (the skip paragraph is lines 89-101); `relocate(_ anchor:savedAt:savedGlobalOffset:)`, lines 318-351 (rule 1: `newFinder.settled`, then `standsAnywhere`); `relocate(_ skipped:)` and its doc, lines 401-462; `holdsNoWords`, lines 1005-1013; the book-level extension, lines 1035-1250 (`Places`, `Outcome`, `Counts`, `isAtTheStart`, `relocate(_:movedAt:)`, `moved(_:to:)`, `moved(_:to:at:)`, `skip(of:keeping:)`).
- `TextMouth/Models/TextAnchorFinder.swift`, `settled(_:savedAt:)`, lines 225-248.
- `TextMouth/Models/FineWords.swift`: `BookWords`, lines 244-300; `endPlace` and `isEnd(_:)`, lines 304-325; `globalOffset(of:)`, lines 405-411.
- `TextMouth/Models/TextAnchor.swift`: `stands(at:in:)`, lines 136-145; `init?(capturingAt:in:measuredIn:)`, lines 113-124.
- `TextMouth/Models/TextAnchorCapture.swift`, lines 1-25: `DocumentContent.anchor(at:measuredIn:)`.
- Tests: `TextMouthProductionTests/PlaceRelocatorBookTests.swift` (all, 298 lines) and `PlaceRelocatorHeadingTests.swift` lines 50-70 and 245-262; fixtures in `PlaceRelocatorTestSupport.swift` (`MillBook`, `SavedPlace`, `Phrase`).

## Commit 1: "Keep a waiting skip apart, naming no heading, in the relocator's outcome"
1. `Places` gains `var waitingSkippedHeadings: [SkippedHeading] = []`, after `skippedHeadings`: the skips that wait, naming no heading, because an earlier move found none for them; kept so that a later move may. `Places` also conforms to `Codable` (synthesized; another task saves it in a file). Document both, and say in `skippedHeadings`' doc that each names a heading.
2. In `relocate(_ places:movedAt:)`, after the named skips (`places.skippedHeadings`, each through `relocate(_ skipped:)` as now), take each of `places.waitingSkippedHeadings` by the **waiting rule**: it names a heading again only when its heading stands in the new text exactly as it was skipped, which is when (a) a new heading has its ID, (b) it has saved words (`anchor` not nil) that hold a fine word (`!Self.holdsNoWords(anchor)`), and (c) those words stand exactly at its saved place in the new text (`anchor.stands(at: TextPlace(chapter: skip.chapterIndex, offset: skip.characterOffset), in: new.texts)`). Then it is `.unchanged`, taken from that heading by `skip(of:keeping:)`. Otherwise it still waits, exactly as it was. It is never found in the old text (which did not hold its heading, or it would not have waited, and where the next section that slid into its numbers has its ID), by its label, or by its saved words alone.
3. One helper serves rule 1 of `relocate(_ skipped:)` (lines 439-443) and the waiting rule: the new heading with a skip's ID whose saved words, if any, stand at its place, with a flag (or two small functions over one lookup) for the waiting rule's demand that saved words exist and hold a word. Make it `static`, taking the new headings and the new texts, because commit 2's shortcut calls it without a relocator. Rule 1's own behavior must not change: a named skip without saved words still takes a heading with its ID.
4. The named results, then the waiting ones, go through the existing one-per-ID filter (lines 1180-1192) unchanged: two skips that now name one heading are one, the first kept; a skip that names a heading wins over one that waits whose saved ID that heading now has.
5. The outcome: `places.skippedHeadings` holds the kept skips that name a heading, and `places.waitingSkippedHeadings` the kept skips that wait (newly or still), each list in input order. `skippedHeadingFindings` becomes `[Finding]`: one finding for each of `places.skippedHeadings`, no nils. `counts.waiting` counts the skips in `places.waitingSkippedHeadings`. Update the docs of `Outcome`, its `places` and `skippedHeadingFindings`, `Counts.waiting`, `Counts.count(_:)` (whose nil case stays, or drop it if nothing passes nil), and the type doc's skip paragraph (lines 89-101): a skip that waits is kept apart, naming no heading, and names one again only where its heading stands exactly as it was skipped.
6. Update the existing assertions that expected a waiting skip inside `places.skippedHeadings` with a nil finding. They are: `PlaceRelocatorHeadingTests.swift` lines 66-68 and 258-260; `PlaceRelocatorBookTests.swift` lines 139-141, 155-157, 172-176, 200-205, and 291-293. Each such skip now appears in `places.waitingSkippedHeadings`, and the findings list drops its nil. Change nothing else those tests assert.
7. New tests in `PlaceRelocatorBookTests.swift`, built on the texts of `testASkipThatNamesAHeadingWinsOverOneThatWaits` (lines 186-205), where removing the first "Notes" section slides the second into its numbers so that the new heading has the first one's ID:
   - **The slide, twice.** Only the first "Notes" is skipped. The first move: `places.skippedHeadings` is empty, `places.waitingSkippedHeadings` holds the skip exactly as it was, and no kept skip names the new "Notes". The second move, from that new text to one changed elsewhere (a sentence added at the chapter's end), given `Places(waitingSkippedHeadings: [that skip])`: it still waits, unchanged, and nothing names the new "Notes" (whose ID is the skip's).
   - **Its section comes back.** From the text without the first "Notes" to one with it again at its old numbers, the waiting skip names it: `.unchanged`, with the first "Notes"' ID, and `waitingSkippedHeadings` is empty.
   - **No saved words, no heading.** A waiting skip without an anchor whose ID a new heading has keeps waiting.
   - **Named first.** A waiting skip whose heading stands again and a named skip of the same heading make one skip, the named one, and nothing waits.
   - **Codable.** `Places` with a position, two bookmarks, a skip, and a waiting skip, encoded and decoded with `JSONEncoder` and `JSONDecoder`, is equal to itself.

## Commit 2: "Build a place relocator only when some place does not stand"
8. A static entry point in the book-level extension:

       static func relocate(_ places: Places, from old: () throws -> DocumentContent, to new: DocumentContent, movedAt date: Date) rethrows -> Outcome

   - It reads the new text's words once: `let newWords = BookWords(texts: new.chapters.map(\.text))`.
   - **Every place stands** when each of these holds:
     - the position, if any, and each bookmark: its anchor is not nil, and either the anchor marks the end of the book (`marksEndOfBook`) and `newWords.isEnd(saved)`, or it holds a fine word and `anchor.stands(at: saved, in: newWords.texts)`. This is exactly when rule 1 (lines 333-337) returns `.unchanged`; a place without saved words needs the old text, so it does not count as standing;
     - each named skip: rule 1 of `relocate(_ skipped:)` finds its heading (the helper of item 3) among `new.allHeadings`.
     - Waiting skips never stop the shortcut: the waiting rule needs only the new text.
   - If every place stands, the outcome is assembled without calling `old`: each position, bookmark, and named skip `.unchanged` at its saved place (a named skip taken from its heading), each waiting skip by the waiting rule.
   - Otherwise it calls `old()` once and returns `PlaceRelocator(old: BookWords(texts: oldText.chapters.map(\.text)), new: newWords, oldHeadings: oldText.allHeadings, newHeadings: new.allHeadings).relocate(places, movedAt: date)`, reusing `newWords`.
9. DRY: both paths build their outcome with the same code. Move the assembly out of `relocate(_:movedAt:)` (lines 1146-1203) into one function that takes how each place was found (the position's `Result`, each bookmark's `Result`, each named skip's `HeadingResult?`) and the new text's `BookWords` and headings, and does what lines 1149-1202 do now: `moved(_:to:)`, `moved(_:to:at:)`, `skip(of:keeping:)`, the waiting rule, the one-per-ID filter, and the counts. `moved` and `skip(of:keeping:)` become static (they read only `new`). `relocate(_:movedAt:)` keeps its signature and its rules: the start-of-book rule (lines 1158-1161) stays with the relocator's own finding of the position.
10. Docs: the new entry point says what it costs and saves (the relocator's cost from the type doc's last paragraph); the type doc's last paragraph mentions it.
11. Tests, in `PlaceRelocatorBookTests.swift`. The `old` closure records whether it was called (a local `var called = false` it sets); never `XCTFail` inside it.
    - **All stand.** `MillBook.chapters` with a sentence added to the end of the last chapter, places in the first three chapters (a position with `globalCharacterOffset` set, two bookmarks, a skip of chapter II's heading, each with anchors from `SavedPlace`): the static entry point's outcome equals `PlaceRelocator(old: oldContent, new: newContent).relocate(places, movedAt: SavedPlace.moveDate)`'s, and `old` was not called.
    - **An earlier chapter grew.** A sentence added to chapter I, the position in chapter III: the position stands, its `globalCharacterOffset` is the new text's (grown by the sentence's UTF-16 length), its date is unchanged, the outcome equals the full relocator's, and `old` was not called.
    - **The end.** A position at the end of the book (`endPlace`, with an anchor that marks the end): with the text unchanged, `old` is not called; with a sentence appended to the last chapter, `old` is called and the position goes to the new end, as the full relocator puts it.
    - **One place moved.** A sentence put in before a bookmark in chapter II: `old` is called once and the outcome equals the full relocator's.
    - Build `DocumentContent` from texts as the existing tests do, or with `MarkdownCacheService.parseMultiChapterMarkdown` if none does; `PlaceRelocator(old:new:)` (line 308) takes `DocumentContent`.

## Run
`PlaceRelocatorTests`, `PlaceRelocatorBookTests`, `PlaceRelocatorHeadingTests`, `PlaceRelocatorSharedRuleTests`.

## Do not touch
The rules themselves (the diff, `carry`, `oldHeading(of:)`, `carried`, `isSameSection`, the saved-words search), `TextAnchorFinder`, `FineWords`, `TextAnchor`, and any file but `PlaceRelocator.swift`, `PlaceRelocatorBookTests.swift`, and `PlaceRelocatorHeadingTests.swift`.
