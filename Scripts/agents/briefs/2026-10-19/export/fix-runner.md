# Task `fixrunner` (team export, review round, October 19, 2026): no export ever removes or replaces a file in the folder chosen

Worker `export-fixrunner`, branch `export/fixrunner` from `team/export`. Review items M3, L1, and L5 of the two Opus reviewers. Three commits, one per item, each with its tests.

## Read first (only these)
- `TextMouth/Services/BookExportService.swift` lines 770 to 945 (`export`, `write`, `makeFolder`, `writeConverted`, `writeThroughScratchFile`, `makeScratchFolder`) and 990 to 1035 (`fileNameStem`, `safeFileName`).
- `TextMouthProductionTests/BookExportServiceTests.swift` lines 1 to 50, 276 to 340, 395 to 430, and 530 to 552, for how its tests make a library, import a book, export, and check names.

## M3 (commit 1): every exported file goes through the scratch file and the exclusive move
Today `write` removes the target after a failed copy or reading-text write whenever the target was missing at its `existedBefore` check (lines 819 to 826). Two Export dialogs exporting one book's text to one folder both pass that check; the second's `.withoutOverwriting` write fails, and its cleanup deletes the first dialog's file, which that dialog announced as exported. The rule now: **nothing in the folder chosen is ever removed by an export.**
1. In `write`, every source kind is made at the scratch URL inside `writeThroughScratchFile(to:cancellation:_:)`, which then moves it to the target (DRY: one path for all):
   - `.copy(url)`: `access.read(url) { try FileManager.default.copyItem(at: url, to: scratch) }` (a file, or a folder such as an RTFD package);
   - `.readingText(markdown)`: read through `access.read`, make the text with `plainText(fromMarkdown:at:title:)`, `Data(text.utf8).write(to: scratch, options: .withoutOverwriting)`;
   - `.converted(...)`: as `writeConverted` does now, its write going to the scratch URL (keep `writeConverted` as the function that reads, walks, and writes, now given the scratch URL by its caller, or fold it in; either way one function per source kind at most).
2. `existedBefore` and `removePartialFile` go, with every call of them. The catch clauses stay as they are otherwise: `CancellationError` sets `wasCancelled`, a download refusal notes the book in the cloud, anything else is a failure named for the target's file name.
3. Update the comments of `write`, `writeThroughScratchFile`, and `export` (and `BookExportFile.Source.converted`'s, which says only a conversion goes through a scratch file).
4. **Tests** (in `BookExportServiceTests.swift`, a new `// MARK: - Never Removing a File` part):
   - A file that appears at the target after the plan survives a failed export, for each source kind. Export one book's `[.originalFile, .markdown, .plainText]`; in the `progress` callback after the first file (`done == 1`), write "Someone else's" to the targets of the second and third files ("<stem> - Text.md" and "<stem> - Text.txt" in the destination). Both are failures named for their files, and both files still hold "Someone else's".
   - The same with a conversion: `[.originalFile, .markdown]` with `.markdown` converted to HTML (`BookExportConversion.text(TextExportConversion(HTMLExportWriter(), options: NoTextExportOptions()))`), and "<stem> - Text.html" written in the callback: a failure, and the file still holds "Someone else's".
   - `testAFileThatCannotBeWrittenIsNamedWithTheReason` must still pass as it is.

## L1 (commit 2): the move refuses an existing target atomically
`FileManager.moveItem` checks for the target and then renames, so a file created in that instant is replaced; a reviewer's race replaced 2,995 of 3,000 such files.
1. A function `static func moveExclusively(_ source: URL, to target: URL, rename: (URL, URL) -> Int32 = <renamex_np with RENAME_EXCL>) throws` (internal, so a test can call it):
   - `renamex_np(source.path, target.path, UInt32(RENAME_EXCL))` (Darwin); 0 is done;
   - `EEXIST` throws `CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path, NSURLErrorKey: target])` and leaves both files as they are;
   - `EXDEV` (the scratch folder on another volume, when the system gave no scratch folder on the target's) or `ENOTSUP` and `EINVAL` (a volume without exclusive rename): copy with exclusive creation, `copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL))` for a file, and for a folder `COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL`; an `EEXIST` there throws as above; on any other failure of the copy, remove only what the copy itself created, which it created exclusively, and throw; on success remove the source;
   - any other errno throws `POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)`.
   - The `rename` parameter exists only so a test can make the rename report `EXDEV` and so check the copy path on one volume; its comment says so.
2. `writeThroughScratchFile` calls it in place of `moveItem`. Correct the comments that say the move "fails rather than replace": now it does, atomically on one volume, and by exclusive creation across volumes.
3. **Tests** (same part): `moveExclusively` refuses an existing target, throwing `CocoaError.fileWriteFileExists`, with the target's bytes unchanged and the source still there; moves a file to a free target; and, with a `rename` that returns -1 and sets `errno = EXDEV`, refuses an existing target the same way and copies to a free target, removing the source.

## L5 (commit 3): a safe name never begins with a dot or white space
`safeFileName` removes leading dots before trimming white space, so a title beginning with a non-breaking space or an ideographic space before a dot, or ". " before a dot, gives ".config - Text.html", hidden in Finder; ". . ." gives ". . - Text.html".
1. Replace the leading-dot loop and the trim after it (lines 1021 to 1024) with one loop that removes leading characters while the first is a dot or white space (any Unicode White_Space: `first.unicodeScalars.allSatisfy(\.properties.isWhitespace)`), then trim trailing white space as now. Update the function's comment.
2. **Tests** in `testTitlesBecomeSafeNames` or a new test beside it: "\u{00A0}.config", "\u{3000}.config", and ". .config" give "config"; ". . ." gives the fallback; the existing assertions still hold.

## Build and test
`BBS_AGENT=export-fixrunner python3 Scripts/test/run-area.py BookExportServiceTests BookExportConversionTests BookExportSheetTests ConvertedOriginalTests` (read `-h` first), with your own build folder as `teams-common.md` says. Then `make lint-tests LINT_BASE=team/export`.

## Do not touch
Anything but `BookExportService.swift` and `BookExportServiceTests.swift`. Another worker is changing the dialog's files, and the lead the files under `TextMouth/Services/Export/` and the other test files. A failing existing test means stop and ask `export-lead`.
