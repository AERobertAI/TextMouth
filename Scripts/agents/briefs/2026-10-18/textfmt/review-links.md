# textfmt-rvlinks: symbolic links to documents (review item 5)

Slug `textfmt-rvlinks`, branch `textfmt/rvlinks` from `team/textfmt`. Read `Scripts/agents/briefs/2026-10-18/textfmt/shared.md` first.

## The bugs

- `DocumentByteLimit.contents(of:)` (DocumentByteLimit.swift, around 39-42) sizes the link, not its target, so a link to a huge file is read whole into memory before the limit refuses it.
- `TextutilConverter.documentSize(of:)` sizes a top-level link as the link, while textutil follows it (TextutilConverter.swift, around 156-157).
- The import copies a link itself into the package (`FileImportService.stageContent`, around 967), so the book's file points outside its package, and an RTFD folder's copy keeps links inside it.

## What to do

For the text formats (every format but `.audio` and a DAISY package's own files, which keep today's handling), size and copy the resolved target:
1. `DocumentByteLimit.contents(of:)` and `TextutilConverter.documentSize(of:)` measure what a link points to (resolve first; a link that resolves nowhere is a file that cannot be read, refused as today).
2. `stageContent` copies the resolved target of a linked document, so the package holds a real file named as the link was; an RTFD's staged copy holds no symbolic link (remove any the copy brought, after copying, with a comment: an attachment link may point anywhere on the disk).
3. Comment each.

## Tests (a new class `DocumentLinkTests`)

Each fails before its fix: a link to an RTF imports, and the package holds a regular file with the RTF's bytes; a link to a file past a bound `DocumentByteLimit.$current` is refused before reading (show the limit's sentence, and that the target was not read: a target larger than the bound and a stand-in that would notice, or by the error coming from the size check); an RTFD holding a link to a file outside it imports, and its staged copy holds no link; a link to an SSML file imports with its words.

Your lead has posted the folder-of-tracks case (a link inside an imported folder or ZIP of audio) to team audiofmt: leave audio alone. Run `DocumentLinkTests`, `DocumentByteLimitTests`, `TextutilConverterTests`, `TextutilImportTests`, `ImportStagingTests`, and `StagedImportTests`.
