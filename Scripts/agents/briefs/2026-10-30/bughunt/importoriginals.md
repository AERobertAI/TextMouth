# bughunt-importoriginals: "Delete After Import" never deletes the only copy of something, and Open Book… opens a package

Worker slug `bughunt-importoriginals`, branch `bughunt/importoriginals` (from `team/bughunt`). Read `README.md` beside this file first. Three fixes, one commit each, each with its tests. All three were verified by the lead by reading.

## 1. A ZIP holding a DAISY book with audio is imported as its audio alone, and then deleted
`LibraryViewModel+Import.swift:486-501`: an archive `DAISYParser.isDAISYZip(url:)` accepts, whose DAISY book has audio, goes to `FileImportService.importDAISYAudioZipWithReport` (`FileImportService.swift:2189-2255`), which stages only the converted audio and a `manifest.json`: the book is an audiobook, and the DAISY text (the DTBook XML a braille reader uses), its images, and anything else in the archive are not imported. Yet its `ImportedBook` is an ordinary complete one (`mayDeleteOriginal`, `FileImportService.swift:106`), so `completeSingleImportedBook` deletes the ZIP under "Delete After Import", or offers to under "Ask" (`LibraryViewModel+Import.swift:616`). The archive was the only copy of the text.

Fix:
1. `ImportedBook` (`FileImportService.swift:74-125`) gains a flag saying the import took only part of its original (doc comment: a DAISY audio ZIP, whose text stays in the archive), which `mayDeleteOriginal` honors exactly as it honors `isFromFolder`; `importDAISYAudioZipWithReport` sets it on what it returns.
2. Generalize `rtfdOriginalKeptNotice` (`:115-118`, used by `importWarning(for:)`, `LibraryViewModel+Import.swift:642-646`) into one `originalKeptNotice` that says, when "After Importing a Book" would have deleted or asked about the original but cannot: for an RTFD the sentence it says today, unchanged ("The original file was kept: it is a folder, and an import never deletes a folder."), and for a partial import "The original file was kept: TextMouth imported this DAISY book's audio, and the archive is the only copy of its text." Rename every use; keep both sentences pinned by tests.
3. A DAISY ZIP without audio, and every other import, behave exactly as today.

Tests: in `DAISYPackageImportTests` (grep `DAISYPackageFixtures` for how to build a DAISY 3 book with one audio file; build it as a ZIP in the test's temporary folder): import it with `importDAISYAudioZipWithReport`; the result's `mayDeleteOriginal` is false and `originalKeptNotice` is the new sentence; then hand it to `completeSingleImportedBook` with `.deleteAfterImport` and "Move to Trash instead of deleting" off, as `OriginalFileDeletionTests` does (grep it), and the ZIP still exists. In `RTFDOriginalTests`, the RTFD sentence is unchanged.

## 2. "Delete After Import" deletes an original that lies inside the library, such as a file inside another book's package
`FileImportService.deleteOriginalFile(at:)` (`FileImportService.swift:2143-2153`) refuses only folders. A file opened from inside a book's package (in Finder, Show Package Contents on `X.tmb`, then Open With TextMouth on `audio/03.mp3` or `book.epub`) imports as a new book from a single file, and its deletion then removes it from inside book X's package: X loses a chapter or its own file.

Fix: `deleteOriginalFile(at:)` also refuses, the same way it refuses a folder (nothing removed, nothing sent to the Trash, no error, one `ORIGINAL_KEPT` log line saying why), any original inside the data directory (`TextMouthPaths.root`) or inside any `.tmb` package, comparing paths with symbolic links resolved (`resolvingSymlinksInPath()` on both, and a path-component prefix test, not a string prefix: `/Lib` is not inside `/Library`). Update its doc comment.

Tests, in `OriginalFileDeletionTests`: with the real deletion and the Trash off, a file inside a `.tmb` folder in the test's temporary folder, and a file inside the hosted test's data directory (`TextMouthPaths.root`, which hosted tests keep in their sandbox), are both still there after `deleteOriginalFile(at:)`, each with one `ORIGINAL_KEPT` line logged (grep how the class reads the log); a file in a plain temporary folder is still deleted, as today; a folder named `Library2` beside a `Library` folder is not taken for being inside it.

## 3. Open Book… offers TextMouth packages, then refuses them as an unsupported format
`importFiles(urls:toFolder:from:addingToReadingList:)` (`LibraryViewModel+Import.swift:781-796`, which the Open Book… panel calls) sends only `.zip` aside, so a `.tmb` chosen in the panel goes to `importBooks` and fails with "Unsupported file format: .tmb", though the panel offers packages (`FileImportService.swift:2488-2490`, `com.textmouth.book-package`) and the same package opened from Finder imports and opens (`importAndOpenFiles`, `:139-140`, through `openTMBPackage(from:)`, `:271-300`).

Fix: `importFiles` sends a `.tmb` to `openTMBPackage(from:)`, exactly as `importAndOpenFiles` does (one shared test of the extension, not two literals: a small static that says whether a URL is a package to open). A package opened this way keeps its own place in the library, as from Finder; the folder chosen for the panel and Add to Reading List do not apply to it, which the function's doc comment says.

Test, in `TMBPackageImportTests` (grep how it makes a valid package outside the library): `model.importFiles(urls: [package], toFolder: "")`, wait for the import queue as the class waits, and the library lists the package's book with no error message set.

## Run
`DAISYPackageImportTests OriginalFileDeletionTests RTFDOriginalTests TMBPackageImportTests ImportDecisionFlowTests ZIPImportTests StagedImportTests`.

## Do not touch
`keepsOriginal` of a ZIP batch (`ZipImportResult`, which other files in an archive raise: a question for the user, not tonight), Replace Existing, and the rest of the import.

## What a listener hears
The new sentence in item 1, exactly as written there, and nothing else new.
