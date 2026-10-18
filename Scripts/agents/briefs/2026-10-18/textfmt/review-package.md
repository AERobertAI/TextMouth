# textfmt-rvpackage: an RTFD book's own package opens and imports again (review item 1, high)

Slug `textfmt-rvpackage`, branch `textfmt/rvpackage` from `team/textfmt`. Read `Scripts/agents/briefs/2026-10-18/textfmt/shared.md` first.

## The bug (found by the orchestrator's reviewers)

Every text book's package (.tmb) can be opened from the Finder, restored from a backup, or taken back after Remove from Library Only, and imports as the book it holds, with its places and bookmarks. An RTFD book's package cannot: its content is a folder, and the package code assumes folder content is an audiobook's tracks.

- `FileImportService.inspectContent(...)` (FileImportService.swift, around line 590-608): a folder content throws "only audiobook content may be a directory".
- `FileImportService+Packages.swift`: `reconstructedBook(inPackage:marker:folderPath:dateAdded:)` (around 380-400) makes any folder content `.audio`; `contentHash(of:bookID:)` (around 462-472) gives a folder "package-<id>"; `holdsSameContent(_:as:)` (around 222-232) passes over a folder. So re-importing after Remove from Library Only rebuilds the book as `.audio` with a made-up checksum, and fails.

`FileImportService+Packages.swift` is team audiofmt's file: change ONLY these functions there (your lead has told audiofmt-lead), and nothing else in it.

## What to do

1. A content folder whose `BookFormat.detect(from:)` is `.rtfd` is an RTFD book's content, never tracks: in `inspectContent`, it must match the record's format and its checksum (the folder checksum `FileImportService` already computes for an RTFD: `contentChecksum(of:format:)`, private today; make it internal and reuse it, never a second copy).
2. `reconstructedBook`: an `.rtfd` folder is format `.rtfd`, its title and author read as any RTFD's (`ImportedFileMetadata.read`), and its checksum the folder checksum; a folder of tracks stays `.audio` as today.
3. `contentHash(of:bookID:)` and `holdsSameContent(_:as:)` likewise treat an `.rtfd` folder by its folder checksum.
4. Comment each change in the files' style.

## Tests (a new class `RTFDPackageTests`, `xcodegen generate`)

Each fails before the fix. Import a copy of `rtfd/with-image.rtfd`, set a reading position and a bookmark on the book (find how `TMBPackageImportTests` and `RetainedPackageImportTests` do it), then:
1. the package itself, copied out of the library, imports through `FileImportService.importTMBPackage(from:)` (or the path opening a .tmb from the Finder takes) as `.rtfd` with its place and bookmark;
2. after Remove from Library Only (the path `RetainedPackageImportTests` uses), importing the same RTFD again takes the book back as `.rtfd`, its checksum the folder checksum, with its place and bookmark;
3. a folder of audio tracks in a package still reads as `.audio` (the existing tests cover it: run them).

Run `RTFDPackageTests`, `TMBPackageImportTests`, `RetainedPackageImportTests`, `TextutilImportTests`, and `import` is your lead's.
