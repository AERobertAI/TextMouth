# Fix `fixreplace`: Replace Existing keeps a braille book's chosen file characters (review finding 3)

Team `braillecodes`, lead `braillecodes-lead`. Slug `braillecodes-fixreplace`, branch `braillecodes/fixreplace` from `team/braillecodes` (3b9bbee3 or later). Read `Scripts/agents/briefs/2026-10-30/teams-common.md`, "The worker's part", first. The outside review is `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/oct30/review-braillecodes.md`: read its finding 3 (lines 42-53).

**Do not build.** The disk is nearly full; the lead builds the whole fix round once. Write the code and test carefully (they must compile the first time), run `make lint-tests LINT_BASE=team/braillecodes`, commit, post `done:`, and report.

## Background

A braille book (BRF or BRL) records its braille file characters (`Book.brailleFileCode`, a `BrailleFileCode` id; `TextMouth/Parsers/BrailleFileCode.swift`). An import records the Braille setting's code, or `unicode` when `BrailleFileReader.certainCode(ofFileAt:)` says so; Book Information can read a book again with others (`LibraryViewModel.readTextAgain(bookID:choosing: .brailleFileCode(code), access:)`). `Book.recordedBrailleFileCode()` is the code that stands between a row and its record. A read that "decides" (`MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(for:replacingEditedText:decidingEncoding: true)`) reads a braille book with its row's code; `LibraryPersistenceService.saveContentAnalysis(..., brailleFileCode:)` writes a code into a package record as a decision.

Replace Existing (`TextMouth/Services/DuplicateReplacement.swift`; `prepare(replacing:with:access:now:)` and `carriedBook(replacing:with:places:location:)` around lines 41 and 203-226) carries the old book's places onto the new copy, which was already imported, and read, with the Braille setting's code. A book the listener corrected to Eurobraille is then silently read as North American Braille ASCII again.

## The fix (the orchestrator's decision)

1. In `prepare`, before places are carried (the place relocation must see the copy's final text): when both books are BRF or BRL braille books (`offersBrailleFileCodeChoice`), they have the same `md5Hash` (the same bytes), the copy's code was not certain (`BrailleFileReader.certainCode(ofFileAt: copy.bookFileURL) == nil`), and the existing book's standing code (`existing.recordedBrailleFileCode()`, nil meaning North American Braille ASCII; compare through `BrailleFileCode.code(forStored:)`) differs from the copy's, read the copy again in the existing book's code: set it on the copy as an explicit id, regenerate the copy's text deciding (as above), and record the code in the copy's package record so the copy's row and record agree. Find how the replacement writes the copy's record and use that path; keep the step inside whatever storage boundary and cloud checks `prepare` already holds. A failure of this read leaves the replacement as it would have been without it only if that is safe; otherwise refuse the replacement with the reader's sentence (say which you chose, and why, in your report).
2. Document it in `prepare`'s and the type's doc comments: the copy is read in the existing book's braille file characters when the files are the same, so a correction made in Book Information survives Replace Existing. The text encoding has the same gap; leave it (the lead lists it as a follow-up).

## Test

In `DuplicateReplacementTests` (or a new class, `BrailleFileCodeReplaceTests`, if that class's fixtures don't fit): import the grade 1 BRF written in Eurobraille (`BrailleFileCodeImportTests.copyOfBrailleSample(_:writtenIn:)` and `BrailleFileCodeSampleTests.bytes(_:writtenIn:)` are internal helpers you may call) with the setting North American (`BraillePreferences.$fileCodeForImports`, `$tableForImports` bound to `en-ueb-g1.ctb`), read it again as Eurobraille (`readTextAgain(bookID:choosing:)`), then import the same file again and answer Replace Existing as the existing tests do. The row and the record hold `ascii-eurobraille`, and content.md equals the North American sample's reading. And a second case: a copy whose bytes are Unicode braille patterns keeps `unicode`. Never touch `~/.TextMouth`; use `LibraryIndexSandbox` and the tests' own folders.

If you add a test file, run `/opt/homebrew/bin/xcodegen generate` and commit the project file (only its new lines; regenerate until the copy phases are not shuffled).

## Do not

Build; edit files other than `DuplicateReplacement.swift` (and, only if the replacement's record write lives there, the one file it lives in: name it in your report) and the test file; edit `*.md`; touch `~/.TextMouth`.
