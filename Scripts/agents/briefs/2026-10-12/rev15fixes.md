# Task brief: rev15fixes — REV15's findings in `PlaceRelocator` (T06's branch C)

Slug `rev15fixes`; branch `fix/rev15-place-relocator`, from main. Read `common.md` beside this file first. Use main's suite count (5929 tests, 64 skipped) as your baseline.

## Where these come from
On October 12, 2026 a read-only review (REV15) of the `feature/place-diff` merge (20bc9d76) confirmed 15 bugs in `TextMouth/Models/PlaceRelocator.swift`, and seven more it ranked lower. Each was reproduced by compiling the repository's own engine files with a small program on concrete inputs. `PatienceDiff` and the `TextAnchorFinder` refactor came back clean: 0 mismatches with the old `find` in about 790,000 random comparisons, and no crash in about 30,000 random books.

Nothing in the app calls `PlaceRelocator` yet. Branch D (rebuilds of the text cache) and branch E (Edit Text, and load) will, so the relocator must be right before they do. No saved data needs migrating.

`rev15-review/`, beside this brief, holds the review:
- `findings.json`: the 15 findings, most severe first, each with its failure scenario.
- `VERIFIED.txt`: every verified candidate, V1 to V23, one line each, and the known cleanups. `CANDIDATES.txt` gives each one's full text; `LEAD-FINDINGS.txt` gives the lead reviewer's own.
- `repro/`: the program that reproduced each one. Build and run one with `rev15-review/build-probe.sh rev15-review/repro/<name>.swift <scratchpad>/rev15fixes-<name>`; its header says what it compiles (your worktree's engine files, by default). Each program prints what the relocator returns. Turn each case into a unit test that pins the right answer, and rerun the program once your fix is in.

## What the relocator promises
The type's doc comment states its rules; keep them except where an item below changes one, and update the comment with every change.
- **Skipped headings.** "Failing that, the skip waits, applying to no heading, so no section is skipped by mistake." A skip on the wrong heading silently hides text the listener never chose to skip. That is worse than a skip that waits, which only lets the section play. But a skip whose heading plainly still stands (relabelled, re-levelled) must not be lost either.
- **Places.** A place stays with its own text, and a chapter restored after a place does not take it. A place goes to the end of the book only when it was at the end: `Book.restsAtEnd` (`Book.swift` about 745) reads a book as finished when its place is at or past the end of its text, and "a place short of the end, however near, is not the end."

## Items
Group commits by root cause, one commit each with its tests, and say in your report which findings each commit closes. Numbers 1 to 15 are the review's (the order in `findings.json`); Vn is a candidate's ID in `VERIFIED.txt`. Lines are main's.

Suggested order: B and C first, since a skipped heading's start is carried like a place, then A, D, and E.

### A. Skipped headings bound to the wrong heading
**Suggested approach** (find a better one if you can, and say why):
- Give the relocator the old text's headings: `init(old: DocumentContent, new: DocumentContent)` has `old.allHeadings`.
- Find a skip's heading in the old text by the heading its ID names there. Failing that, find it by its level and label, when only one heading has them. Never find it by its saved words alone, or at its stale numbers.
- Judge whether a new heading is the same section by the diff's account of the heading's own words: where the new heading's words came from in the old text. Words that came from another old heading make it another section. One following word is not enough to decide.
- Among several headings that start at one word, the label decides.
- A skip moves only on proof; a guess never moves a skip onto a heading.

1. **Finding 1** (line 365; `repro/lead-twice.swift`, `gap-p1.swift`). The fixture is from `PlaceRelocatorHeadingTests.testASkippedSectionLeftOutWaitsRatherThanSkipTheNext`. Rebuild 1 (opening + "The Pump" + "The Soup", to opening + "The Soup") rightly leaves "0-118-2-The Pump" waiting. A second rebuild with the text unchanged (a second save in Edit Text, or Redo Text Extraction) returns "0-118-2-The Soup" as a sure `.movedByTheDiff(.linedUp)`. The cause: `placeInOldText` accepts an old-text find scored on the words before the heading alone, and nothing checks that a heading starts there. **Expected:** the skip waits on every later rebuild.
2. **Finding 3** (line 275; `V2.swift`). A skip saved without an anchor (every skip saved before T06 is rebuilt from its ID) gets words read in the old text at its stale numbers, even when its ID names no heading there.
   - Example: chapter III was restored after the skip "2-0-1-CHAPTER IV. …" was saved, so today its ID names nothing. Any rebuild, even one that changes nothing, binds the skip to CHAPTER III (`.foundBySavedWords`, score 20 to 24), and chapter III goes silent while chapter IV plays.
   - In the same way, "1-0-1-Contents" after a dropped cover becomes "CHAPTER I.".
   - `waiting()` then stores those wrong words for later rebuilds.
   - Branch B's capture refuses exactly this case (`TextAnchorCapture.swift` about 81 to 83: a skip "whose ID names no heading now… could make it skip another section").
   - **Expected:** it never takes the heading now at its stale numbers. It may take the heading its label names when that heading is the only one of its level with that label and is not another section by the diff's account. Otherwise it waits.
3. **Finding 4** (line 342; `V3.swift`, `lead-notes.swift`). Chapters I and II each end with a level-2 "Notes", and only chapter I's is skipped. When Edit Text removes chapter I's Notes, the skip goes to chapter II's Notes (`.onlyHeadingWithItsLabel`). With a third Notes it goes there as a `.nearestHeadingWithItsLabel` guess. The diff had lined that heading up with its own old heading. **Expected:** the skip waits.
4. **Finding 5, its heading half** (lines 477 and 376; `V4.swift`, `lead-replsec.swift`). A mid-chapter level-2 "Pump Repairs" section (21 words) is replaced by an 85-word "Forge Work" section. Its start is reported as `.followedMovedText`, so `carriedHeadingStart`'s `default: return nil` skips the removal guard, and `findHeading` gives the skip to "Forge Work" (score 12, all from the words before the heading). **Expected:** the skip waits, as it does when the section is only removed. Item 8 fixes the moved-text rule itself.
5. **Finding 6** (line 390; `V5.swift`, `V6.swift`, `V18.swift`, `lead-chapterrepl.swift`). `headingTextStands` decides from the one old word after the heading's first word, and line 391 counts a `.replaced` verdict as standing.
   - **Too lenient; each case must wait:**
     - A removed 7-word "Dedication" section passes the like-for-like test (7 <= 2 × 0 + 8), and its skip moves onto "CHAPTER I.".
     - "CHAPTER III. The Stones", replaced by a same-length "INTERLUDE. A Letter", moves its skip to INTERLUDE.
     - Removing "BOOK ONE. CHAPTER II." moves its skip to "BOOK ONE. CHAPTER III.".
     - Removing the section "Notes on the Pump" moves its skip to "Notes on the Soup".
   - **Too strict; each skip must stay on its heading:**
     - "Prologue" relabelled "Prologue: Before the Spring Flood".
     - "CHAPTER III. The Stones" relabelled "III. The Stones".
6. **Finding 10** (line 333; `V17.swift`). Chapters I and II each end in a level-2 "Exercises", and chapter I's is skipped. The new reading makes it level 3 (Edit Text's `##` to `###`, or a PDF's font-size levels), with an earlier edit in chapter I. The diff's proof that its text stands is dropped, and `findHeading` gives the skip to chapter II's level-2 Exercises. **Expected:** the skip goes to chapter I's Exercises at its new level, or waits; never to chapter II's. Say which and why.
7. **Finding 15** (line 402; `V7.swift`). `heading(ofLevel:startingAt:)` returns the first heading of the level whose start maps to the landing word, whatever its label.
   - Real books have piles of wordless headings: level-1 "Cover", "Title Page", and "Copyright" at offsets 2803, 2804, and 2806 of one chapter. The probe builds such a pile; do not read the user's library for one.
   - After a word is added earlier in the chapter, the skip of "Copyright" becomes "Cover", and the copyright page is read aloud.
   - **Expected:** "Copyright". In a pile, the label decides; with no label matching, fall back to the finder, or wait.
8. **V21** (line 793; `V21.swift`). When two skips now name one heading, the first one is kept, even when it is a skip that waits, holding stale words. The Outcome's findings and counts follow the input skips, so they need not match what was kept. **Expected:** a skip that names a heading wins over one that waits. Make the Outcome's findings and counts agree with what is kept, and document which.

### B. Carrying a place
9. **Finding 7** (line 511; `V10.swift`; see also `gap-p4.swift`). The keeping rule is tried only when the place's run breaks right after its own word.
   - So text put in before a place, beginning with the place's first two or more words, takes the place.
   - Example: one chapter's text runs "BOOK ONE. CHAPTER I.…" then "BOOK ONE. CHAPTER III.…", and "BOOK ONE. CHAPTER II.…" is restored between them. A position at "BOOK ONE. CHAPTER III." lands at the restored chapter II (offset 505 instead of 899), as a sure `.linedUp`. The skip of III moves to II, so II is hidden and III plays.
   - Ordinary prose does the same: "The captain kept a terrier…" put in before "The captain waved once…" takes a place at the second sentence.
   - `testTextPutInThatBeginsWithAPlacesWordsDoesNotTakeIt` covers only one shared word ("CHAPTER").
   - **Expected:** the place stays at its own words, and the skip stays on III.
10. **V15** (lines 612 and 617; `V15.swift`). The keeping rule's window has no lower bound at the previous solid match's partner, and it may skip kept words. A place can jump back across a solid run, up to about 84 words, even into the previous chapter. **Expected:** a kept place never lands before the previous solid match.
11. **Finding 5, its place half** (line 477; `lead-replaced.swift`, `V4.swift`). The moved-text rule accepts an `onlyBestSpot` scored on the words before the place alone. So a plain one-word replacement mid-chapter ("frogspawn" to "duckweed") is labelled `.followedMovedText` rather than `.wordReplaced`; that label is what diverts the heading in item 4. **Expected:** moved text is followed only on evidence from the place's own words, the words after it.
12. **Finding 11** (line 555; `V9.swift`). The slide-back loop has no chapter boundary.
    - Old [VI, ending "…Ffion said.", VII, ending "…Bramwell said.", VIII] becomes new [VI, VIII].
    - Places in VII land at (0,357), on "said." at the end of VI, as sure `.passageRemoved`, rather than at (1,0), where VIII begins. Letters that all close "Your brother as ever, Tobias" do the same.
    - **Expected:** the slide stays within the chapter where the text after the removal begins.
13. **V14** (line 556; `V14.swift`). The slide condition matches -1 with -1 for an unpaired word when the slide reaches new word 0. The target becomes -1, which lands at (0,0). **Expected:** the slide never passes its lower bound.
14. **V13** (line 530, with 562 and `PatienceDiff.swift` about 183; `V13.swift`). The like-for-like rule has no length cap. A long stretch that `PatienceDiff` leaves unmatched because of its size (a repetitive passage) counts as local editing. Places then collapse onto one spot thousands of words back, reported as sure. **Expected:** such a stretch is not local editing. Its places go to the saved words (rule 4), or to the diff's unsure answer. Change `PatienceDiff` only as far as the relocator must know about such a stretch.
15. **V20** (line 463; `V20.swift`). The in-word offset (`inside`) is applied to `.replaced`, `.removed`, and unsure targets, so a place lands mid-word in an unrelated word that has the same key. **Expected:** only on the place's own word.

### C. Chapter ends, chapters without words, and the book's two ends
16. **Finding 2** (line 454; `V8.swift`). The chapter-end rule holds only when the chapter's last word is `.linedUp` to its own partner.
    - The case: old [millrace, wheel, flour] becomes new [millrace, wheel (its "hand-painted sign." now "hand-painted placard."), stones (restored), flour].
    - A position or bookmark at the end of chapter II, (1,382), moves to (2,401): the end of the restored chapter III, which is then skipped. `TextAnchorFinder` alone keeps it in chapter II.
    - The same happens when the last word pairs with an identical last word of text put in after the chapter (Pride and Prejudice's chapters ending in "[Illustration]").
    - **Expected:** a place at its chapter's end stays at the end of that chapter in the new text.
17. **Finding 9** (line 439; `V11.swift`). A place with no fine word after it anywhere in the old text goes to the new text's end before the chapter-end rule runs.
    - The case: old [I, II, III, "[]"], with the position at the end of chapter III (843 of 845, not finished). The rebuild restores a title page and an AFTERWORD before the back cover.
    - The place goes to (5,2), 1056 of 1056, marked `.endOfBook`, so the afterword is skipped and `Book.restsAtEnd` turns true. The recaptured anchor marks the end, so later rebuilds keep it there.
    - With nothing added, a place merely short of the end still becomes finished.
    - **Expected:** a place goes to the end only when it was at the end by `Book.restsAtEnd`'s rule (or rule 1's end-marking anchor). A place followed only by chapters without words stays at the end of its own chapter.
18. **Finding 13** (line 444; `V12.swift`). A place in a chapter whose text has no fine words ("* * *", a "[]" image page from before 3.0.5) gets `nothingAfter = true`. It fails the chapter-end guard because `word - 1` lies in an earlier chapter, and lands at the end of the previous chapter (or the next chapter's start) as a sure `.linedUp`.
    - The case: old [millrace, wheel, "[]", stones, flour] becomes new [millrace, wheel, "", stones, flour]. A bookmark at (2,0) moves to (1,382).
    - With a chapter also restored right after the page, the place lands at the end of the restored chapter.
    - **Expected:** (2,0). A place in a chapter without words goes to the matching chapter between its neighbours' chapters in the new text.
19. **Finding 12** (line 244; `V19.swift`). An anchor captured in a chapter without words holds no words, so it "stands" anywhere, and rule 1 keeps the place at its old numbers.
    - The case: old [I, "" (a plate), II, III], with the position at (1,0). The rebuild restores a preface: new [preface, I, plate, II, III].
    - The place stays `.unchanged` at (1,0), now the start of chapter I, which was already heard; expected (2,0). The recaptured anchor makes it stick.
    - A damaged anchor (two empty strings) is kept the same way.
    - **Expected:** an anchor that holds no words is no evidence by itself that a place stands. Item 18's rule places it.
20. **Finding 8** (line 296; `V1.swift`). `heldInOldText` holds a place without saved words, in a chapter past the old text's last, at `old.endPlace`. The place then goes to the new text's end and the book reads finished. For example, `ReadingPosition(chapterIndex: 5, characterOffset: 140, globalCharacterOffset: 1044 of 1899, anchor: nil)` against a 4-chapter old text becomes (3,417) `.endOfBook`; bookmarks in such a chapter go to the end as well. **Expected:** follow the reader's own rule, `ReaderViewModel.openingPlace` (`ReaderViewModel+SavedPlaces.swift` about 112 to 151): a chapter past the last opens at the end only when the saved whole-book offset was at or past the end, and otherwise at the last chapter's start. Share that rule rather than restate it. A bookmark has no whole-book offset, so it goes to the last chapter's start.
21. **Finding 14** (line 466; `lead-start.swift`, `gap-p3.swift`). A position at the very start of the book (never begun, or after Start Over) is carried like any place. A restored "PREFACE" before chapter I moves it to (1,0), whole-book offset 137, as a sure `.linedUp`, so starting the book skips the preface and the library row shows it begun. The relocator has an end-of-book rule (P07) but no start-of-book one. **Expected:** a position at the very start stays at the new text's start. Decide whether a bookmark there does the same, and say why. `gap-p3.swift` also checks the counts and `anythingMoved` for an unchanged place whose whole-book offset changed.

### D. A moved position's date
22. **V22** (line 808). A moved position keeps its old `lastUpdated`. The design says otherwise (`TEXT-ANCHORS-RESEARCH-2026-10-10.md`, line 295): "A moved position is dated at the move, as `AudioEditPlaces.follow` dates one, so it wins over an older copy in the checkpoint journal's adoption or another Mac's index." **Expected:** date a position that moved. Take the date as a parameter, since the relocator is pure. A position that stayed keeps its date, and bookmarks keep theirs (the Outcome's doc). Check the Outcome's doc comment ("a position's time … stay as they were") against what you do.

### E. Clean-ups (one or two commits)
- The dead `after` scan and `min` in the like-for-like rule (lines 538 to 540, 547).
- `bySavedWords`' unreachable arm (line 652).
- The redundant verdict guard (line 511).
- The duplicated `moved(...)` overloads (lines 808 and 819).
- The "16 MB at most" comment (`PatienceDiff.swift` line 33; it can reach 32 MB).
- The test fixtures duplicated across the `PlaceRelocator*Tests` files (`SeededWords`, the chapter XVII to XIX texts, the ledger, the mill): move them into `PlaceRelocatorTestSupport.swift`, and give `SeededWords.init(seed:)` a doc comment.

### Not this branch (list them as follow-ups)
- V16 and V23: one patience diff with a work budget, shared with `TranscriptEditAlignment.matches`. `repro/V23-SharedCore.swift` sketches it.
- The longest-common-subsequence code duplicated in `TextAnchorFinder.alignment`.
- `onlyBestSpot` duplicating `choose()`.
- `nearestSolid`'s linear scans.
- The eager old-text index.
- `reserveCapacity` oversizing in `wordsOnceInEach`.
- Derivable counts.

## The accuracy harness: once before, once after
The rules were ported from a measured program and checked against its exact truth. Keep what it measured.
- **The harness.** It is in `~/programming/ai/claude/investigate/text-anchors-2026-10-10/placediff-harness/` (`placediff-build.sh`, `placediff-run.sh`). Its stored results are `placediff-real.txt` (every real version step placed exactly: "near 0 wrong 0") and `placediff-synth.txt` (the synthetic cases).
- **Use a copy.** Copy the folder to the sibling `…/text-anchors-2026-10-10/rev15-harness/`; the run script finds the readings and the truth by relative paths. Work only in the copy, and adapt its `main.swift` and `PlaceStubs.swift` there when the relocator's initializers or the place types change. Pass `PLACE_STUBS=<copy>/PlaceStubs.swift` to `build-probe.sh` then too.
- **Build and run.**
  - Build: `MODELS=<worktree>/TextMouth/Models OUT=<copy>/harness zsh <copy>/placediff-build.sh`
  - Run: `BIN=<copy>/harness zsh <copy>/placediff-run.sh <copy>/rev15-real.txt <copy>/rev15-synth.txt`
- **When.** Run it before your first change (it should match the stored results, timings aside) and again at the end.
- **What to report.** Give both runs' totals for places (placed, same, near, wrong) and for headings (right, guessedRight, withoutTruth), and explain every change. A guessed heading may rightly become a skip that waits. A place that newly lands wrong is a regression to fix.
- **Keep the harness compiling.** If the relocator comes to depend on a file outside the engine files (for example a shared rule from the reader or `Book`), move that rule into a pure file the harness can compile. Add it to `placediff-build.sh` in the copy, and pass it to `build-probe.sh` with `EXTRA`.
- **The fuzz program.** At the end, also build and run `repro/gap-fuzz.swift`: random books, edits, places, and skips. It must show no trap, places in range, headings among the new headings, and outcome sizes that agree.

## Files you own
- `PlaceRelocator.swift`, `PatienceDiff.swift`, and their tests: `PlaceRelocator*Tests.swift`, `PlaceRelocatorTestSupport.swift`, and `PatienceDiffTests.swift`.
- `FineWords.swift`, `TextAnchor.swift`, and `TextAnchorFinder.swift`, only where a rule must be shared. Say which, and why.
- For items 17 and 20: the rules in `Book.restsAtEnd` and `ReaderViewModel.openingPlace`, moved into a shared pure form if that is what it takes to share them. Their call sites keep their behavior, and their tests stay green.
- Nothing else. Branches D and E have no call sites yet.

## Report (besides `common.md`'s list)
- For each finding (1 to 15, and V13, V14, V15, V20, V21, V22): the commit that fixes it and the test that pins it, or why it is not fixed.
- The harness's totals before and after, and the fuzz program's result.
- The rules you changed, as sentences ARCHITECTURE.md can take. ARCHITECTURE.md does not describe the relocator yet. Branch C's proposed paragraph, which a documentation pass will apply with yours, says of skipped headings: "A skipped heading lands on the heading of its level where its own text lands, else is found by level, label, and words, else waits; after a removal only a heading with its label takes the skip." Give the sentences that replace whatever your changes make untrue.
