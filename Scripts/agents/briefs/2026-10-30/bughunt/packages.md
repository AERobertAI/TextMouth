# bughunt-packages: a second copy of a package never takes a listed book's place, and a zipped package imports as one book

Worker slug `bughunt-packages`, branch `bughunt/packages` (from `team/bughunt`). Read `README.md` beside this file first. Two fixes, one commit each, each with its tests. Both were verified by the lead by reading.

## 1. Opening a second package that names a listed book's ID points the listed book at that package
`LibraryViewModel.listedBookID(for:)` (`TextMouth/ViewModels/LibraryViewModel+Import.swift:310-333`) finds the listed book by the opened package's book ID and, whenever the package is a valid managed package inside the library, repairs the row from it (`FileImportService.reconciledLibraryBook`, `TextMouth/Services/FileImportService.swift:781-826`): file path, folder, and package name all become the opened package's. So Replace Existing's old copy put back from the Trash (it records the same ID), or a Finder duplicate of a package inside the library (Command-D), once opened, silently becomes the book: the library reads and plays the old copy, and the current package, with its carried places and kept transcript, is stranded (each launch logs `ORPHAN_ID_LISTED` and leaves it).

Fix: repair the row from the opened package only when the row's own package is that very package (the same item on disk: compare resolved paths, or file identity as `isSameItem` in `FileImportService+Packages.swift` does; reuse it) or is missing from disk. Otherwise open the listed book unchanged and log one line, in the style of the orphan adoption's `ORPHAN_ID_LISTED` (grep it), naming the second package's folder and name only, never a full path. Update the doc comment.

Test, in `RetainedPackageImportTests`, beside `testListedBookIsStillRepairedFromItsOwnPackage` (copy its setup): list a book with package P1 in the sandbox library; copy P1 to P2 in the same folder; `listedBookID(for: identifyTMBPackage(at: P2))` returns the book's ID, and the row's `tmbDirectoryName`, `filePath`, and `folderPath` still name P1. The existing test (the row's own package repairs it) passes unchanged, and a row whose package is gone is repaired from P2.

## 2. A ZIP holding a TextMouth package imports the package's insides as separate books
`FileImportService.importCandidates(in:unpacking:)` (`FileImportService.swift:1822-1861`) walks a `.tmb` folder like any folder: `DAISYParser.packageEntryPoints(in:)` finds no DAISY book in it, so the walk descends, and the package's `content.md` (a book titled "content"), each track in its `audio/`, and its original file all become books, while its `bookInfo.json`, with the listener's places, bookmarks, and settings, is passed over. A package mailed as a ZIP, or zipped by the Finder, imports as wrong books.

Fix: a folder whose extension is `tmb` (any case) is one candidate, never walked into (`entries.skipDescendants()`), as an RTFD is (`:1835-1840`). Then make the batch import such a candidate as a package: read how the batch imports each candidate (grep the caller of `importCandidates` and what it calls per book) and route a `.tmb` candidate through the package import (`identifyTMBPackage(at:)` then `importTMBPackageWithReport` or `importTMBPackage`, whichever the batch's per-book step can take; read `openTMBPackage(from:)` in `LibraryViewModel+Import.swift:271-300` for the order of the checks, but a batch does not open the book). If the batch's per-book step cannot take a package without a larger change, stop and ask the lead before writing more: the fallback is to list the package among the batch's failures with the sentence "TextMouth packages inside a ZIP are not imported; unzip it and open the .tmb." so the archive is kept and nothing wrong is imported.

Tests, in `ZIPImportTests` (grep how it builds an archive in the test's temporary folder): `importCandidates` over a folder holding `Novel.tmb/{novel.txt, content.md, bookInfo.json}` and `other.epub` lists `Novel.tmb` and `other.epub`, and nothing inside the package; a ZIP holding a valid package (build it as `TMBPackageImportTests` builds one) imports one book with the package's book ID, title, and place; under the fallback, the failure sentence is pinned and the archive is kept.

## Run
`RetainedPackageImportTests TMBPackageImportTests ZIPImportTests ImportDecisionFlowTests OriginalFileDeletionTests StagedImportTests`.

## Do not touch
`importFiles` and `deleteOriginalFile` (another task changes them tonight), `keepsOriginal` of a ZIP batch, and Replace Existing.

## What a listener hears
Nothing new, unless the fallback in item 2 is taken: then its sentence, exactly.
