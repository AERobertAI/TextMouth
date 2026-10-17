# todo18/import: a folder is never deleted as an original; a text file with no text is refused

Slug `todo18-import`. Branch `todo18/import`, made from `team/todo18`. You build; at most two of the team's workers build at once. Read `Scripts/agents/briefs/2026-10-17/teams-common.md` first, everything except "The lead's part" and "A lead's report": the worker's part, the rules, the board, the builds, the lessons, and the usage note. Your lead is `todo18-lead`.

Both changes are in `TextMouth/Services/FileImportService.swift` (2666 lines: read it by the line ranges below, never whole). Two commits, in this order, each with its tests.

## 1. A folder is never deleted as an import's original

**Why.** Import Folder... (a DAISY book kept as loose files, a folder of audio tracks) sets `ImportedBook.isFromFolder` (`FileImportService.swift:63-96`; `mayDeleteOriginal` at line 87), so the library never offers or runs the deletion for such a book. That is the only guard: the function that deletes still takes a folder if it is ever called with one. Make the service refuse.

**Code.** `FileImportService.deleteOriginalFile(at:)`, lines 1727-1735: `@MainActor static func deleteOriginalFile(at url: URL) throws { try removeItemRespectingTrashSetting(at: url) }`. Its one caller is `LibraryViewModel.deleteOriginalFile(at:using:)` (`TextMouth/ViewModels/LibraryViewModel+Duplicates.swift:383-406`), whose default `delete` closure calls it, and which reports a throw to the failure center (a banner with a retry).

**Required.**
1. When `url` is a directory (`FileManager.fileExists(atPath:isDirectory:)` follows a symbolic link, so a link to a folder counts, which is wanted), the function removes nothing, sends nothing to the Trash, and does not throw: nothing failed, so the failure banner must not appear. A file, and a path that is already gone (counts as removed), behave exactly as now.
2. It writes one event line: `DiagnosticLog.event(.import, "ORIGINAL_KEPT: <name>: is a folder, which an import never deletes")`, `<name>` being `url.lastPathComponent`. The log policy allows file names, never absolute paths (`DiagnosticLog.swift:1-60`; `LogContentPolicyTests` scans the source).
3. Update the function's doc comment (it says what it now refuses and why), and add one sentence to `ImportedBook.isFromFolder`'s doc comment (lines 69-75) saying the service refuses a folder too. Comments only there.

**Tests**, in `TextMouthProductionTests/OriginalFileDeletionTests.swift` (existing `@MainActor` class; helpers `makeTestDirectory(_:)`, `withTrashPreference(movesToTrash:_:)`, `cleanSharedFailureCenter()`, and `debugLogLines(containing:)` from `ConfigTestSupport.swift:158`). **Every test of the refusal runs with `withTrashPreference(movesToTrash: false)`**: if the guard were missing, the folder (made by the test, in the sandbox) is then deleted for good, and never sent to the user's real Trash.
- A folder holding a file: after the call, the folder and its file exist, nothing is thrown, and the log holds one `ORIGINAL_KEPT: <folder name>: ` line that names the folder by its name alone.
- A symbolic link to a folder: both the link and the folder survive.
- Controls: a plain file is still removed (Trash off), and a path that does not exist does not throw.
- Through the model: `model.deleteOriginalFile(at: folder)` with the default `delete` leaves the folder and records no failure (`center.outstandingFailures().isEmpty`).

Commit 1: `Never delete a folder as an import's original`.

## 2. A text file with no text is refused

**Why.** Found by the import fuzz sweep (`ImportFuzzTests.knownIssues`, case `sample.md#empty#seed=20261016`): an empty Markdown file imports as an empty book whose report says nothing is missing, while an empty EPUB is refused (`EPUBParserError.noReadableChapters`, whose message for a book with no text is "This EPUB book has no text to read.", `TextMouth/Parsers/EPUBParser.swift:37-45`). A blind user who imports a blank file hears nothing and cannot tell why.

**Code.**
- `FileImportError` (lines 6-39): the enum of the import's own errors.
- `importFileWithReport(from:checksum:toFolder:observer:)`, lines 793-869; line 865 is `var imported = try publishReadableBook(staged, from: staging, run: &run)`.
- `publishReadableBook(_:from:run:feedLink:replacing:publish:)`, lines 1187-1206, and `readableContent(of:run:)`, lines 1223-1244. The text branch calls `MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(for:)` and gets `generated.content.chapters`. Other callers: `importText` (New from Text, line 1149), the package imports (`FileImportService+Packages.swift:160` and `:281`), recordings, orphan adoption, the DAISY audio ZIP, and feed episodes (`Feeds/FeedEpisodeImporter.swift:233` and `:298`). **None of them changes behavior.**
- Do NOT put the check in `MarkdownCacheService`: every rebuild of an existing book's text (Redo Text Extraction, launch maintenance) goes through it too, and a book already in the library must never become unreadable.

**Required.**
1. New case `FileImportError.noTextToRead`, with a doc comment, and `errorDescription` exactly `This file has no text to read.`.
2. A new defaulted parameter `refusingBlankText: Bool = false` on `readableContent` and on `publishReadableBook` (document it in both doc comments). In the text branch of `readableContent`, after the cache is generated: when `refusingBlankText` is true, `book.format` is `.txt`, `.markdown`, or `.html`, and no chapter of `generated.content.chapters` has a character that is not white space (`chapter.text.contains { !$0.isWhitespace }`, which stops at the first one and copies nothing), throw `FileImportError.noTextToRead`. Name the three formats once, in a small documented constant, not inline.
3. Only line 865 passes `refusingBlankText: true`. The step in force is `.readingText`, so the listener hears: `Could not import “notes.md”. Reading its text failed: This file has no text to read.` The staged package is discarded by the existing `defer { staging.discard() }`, nothing is published, and the source is untouched.
4. In `TextMouthProductionTests/ImportFuzzTests.swift` (lines 28-40), remove the `knownIssues` entry and its comment: the dictionary becomes `[:]`, and its doc comment says it is empty now that the first sweep's finding is fixed (keep the mechanism; the sweep fails with "remove it from the list" otherwise).
5. EPUB, DOCX, DAISY, PDF, and audio are not touched: only the three plain formats. If you see that DOCX or DAISY have the same fault, say so in your report; do not fix it.

**Tests**, in `TextMouthProductionTests/StagedImportTests.swift` (existing class; use its `assertImportFails(at:of:...)` at line 410, which checks the alert's prefix, that the folder holds nothing, that the source's bytes are unchanged, and the one log line; and `makeTextSource()`, `folderEntries()`). Put the new tests under their own `// MARK: - Files With No Text`. Before you write the expectations, run each case once against the unchanged import (a scratch test you do not commit) and note what it does today; if a case already refuses, with another message, tell me before you replace that message. Pin the exact reason, `Reading its text failed: This file has no text to read.`, for each:
- a zero-byte `.md`, `.txt`, and `.html` file;
- a white-space-only `.md` and `.txt` (spaces, tabs, blank lines, a no-break space), and a UTF-8 byte-order mark with nothing after it;
- an `.html` file with markup and no text, e.g. `<html><body><div></div><script>var a = 1;</script></body></html>`;
- controls, which import as before: a one-word `.txt`, `.md`, and `.html`, and a `.md` that is only a heading (`# Title`);
- through the library, as `testCorruptDocumentFailsAndLeavesEverythingAsItWas` (line 46) does: `importSingleFileAsync` of an empty `.md` with "Delete After Import" on gives `model.errorMessage == "Could not import “<name>”. Reading its text failed: This file has no text to read."`, no row, no decision, the file still there;
- a ZIP of an empty `.txt` and a real `.md`: the `.md` imports, the empty one is listed as failed with that reason, and the archive is kept (see `ZIPImportTests.swift` for the way a test builds one; if that is not cheap, skip this test and say so).

Commit 2: `Refuse a text file that holds no text`.

## Tests to run

Run with `BBS_AGENT=todo18-import python3 Scripts/test/run-area.py <ClassNames>` (see `-h`; its build folder is then `/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-todo18-import`).
1. After commit 1: `OriginalFileDeletionTests`, `LogContentPolicyTests`, `DAISYPackageImportTests`.
2. After commit 2: `StagedImportTests`, `TextEncodingFidelityTests`, `ImportDecisionFlowTests`, `IntegrationImportTests`, `ZIPImportTests`, `ImportFuzzMutatorTests`, `ImportFuzzTests` (it shows its skip line without the variable).
3. The fuzz, for real, through the script: first `BBS_AGENT=todo18-import Scripts/test/import-fuzz.sh --docs sample.md --seed 20261016` (the old finding must be gone and nothing else found), then once with the defaults. Report the counts line of each.
4. Once at the end, the whole `import` area: `run-area.py import`. If an existing test fails because it imports an empty or blank text file on purpose, stop and ask me; do not change it.
5. Before you report: `LINT_BASE=team/todo18 make lint-tests` on your diff, and fix what it flags in your own lines.

## Do not touch

`MarkdownCacheService.swift`, the parsers, `ImportStaging.swift`, `ImportFailure.swift` (another worker is on it), `StorageDrillTests.swift`, any other test file than the three named, and any `*.md` file. Add no Swift warning.
