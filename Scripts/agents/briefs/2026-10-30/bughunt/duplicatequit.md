# bughunt-duplicatequit: a duplicate's package never outlives its unanswered question

Worker slug `bughunt-duplicatequit`, branch `bughunt/duplicatequit` (from `team/bughunt`). Read `README.md` beside this file first. One fix, one or two commits, with its tests. Verified by the lead by reading; TODO-2026-09-04.md line 3780 records it as open.

## The bug
- An import whose book matches one in the library publishes the new copy's package into the library folder first, then queues "Duplicate Book Found" (`LibraryViewModel.addBookCheckingDuplicate`, `TextMouth/ViewModels/LibraryViewModel+Duplicates.swift:91-108`). The question lives only in memory (the decision queue).
- Quit (Command-Q, a logout), or a crash, before the question is answered leaves the package on disk. Nothing withdraws it (`AppDelegate.applicationShouldTerminate`, `TextMouth/App/AppDelegate.swift:195-216`).
- At every later launch, `FileImportService.adoptOrphanedTMBPackages` (`TextMouth/Services/FileImportService.swift`, about 3090-3160) reads it, finds its book ID unlisted, and calls `library.addBook`, which silently refuses a second book with the same checksum (`TextMouth/Models/Library.swift:460-466`). So a 3 GB copy stays hidden for good; when the user later deletes the old copy, the next launch adopts the forgotten one, and a deleted book comes back; and when the match was by source path with different content, the next launch adopts it at once as a second book, a Keep Both the user never chose.

## What to build
1. Before the question is queued, write a small marker file into the new copy's package saying it waits for the listener's answer to a duplicate question (a hidden file name, one constant, with a doc comment; follow how `RemovedFromLibraryMarker` names and writes its file, `TextMouth/Models/RemovedFromLibraryMarker.swift`, but keep this one as small as a file's presence).
2. Every answer that keeps the new copy (Keep Both, Replace Existing: grep the decision handlers in `LibraryViewModel+Duplicates.swift` and `DuplicateReplacement.swift`) removes the marker before the book is added; the answer that discards it (Cancel, or however the question's discard path is named) removes the package as it does now, marker and all.
3. The launch's orphan adoption, before anything else it does with a package, discards a package that holds the marker: to the Trash or for good as "Move to Trash instead of deleting" says, exactly as the question's own discard does (reuse that code; do not write a second removal), with one `DiagnosticLog` line naming the package's folder and name (never a full path) and why. The book's original file was never deleted for an unanswered duplicate (it is deleted only once the book is kept), so discarding the copy loses nothing.
4. Comment each step with why.

## Tests
In `ImportDecisionFlowTests` (grep how it imports the same file twice in its scene's temporary library so the duplicate question waits):
- With the question waiting, the new copy's package holds the marker; Keep Both and Replace Existing each leave the kept package without it.
- With the question still waiting, a fresh `LibraryViewModel(initializeServices: false)` on the same data directory, running the launch's repair as the class runs it (grep `adoptOrphanedTMBPackages` in the tests), discards that package (Trash off), lists one book, and logs the line; then delete the first book, run the repair again, and nothing is adopted.

## Run
`ImportDecisionFlowTests ImportDecisionQueueTests DuplicateReplacementTests RetainedPackageImportTests LibraryStartupRepairTests` (grep each; drop any that does not exist and say so).

## Do not touch
Replace Existing's carrying of the old copy's state, the question's wording, `LibraryViewModel.swift` and `LibraryViewModel+FolderManagement.swift` (team `views`).
