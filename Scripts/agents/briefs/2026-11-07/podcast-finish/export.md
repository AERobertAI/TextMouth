# Worker `pf-export`: writing a transcript as captions, reviewed and proven

Slug `pf-export`, branch `podcast/export-proof`. Read `common.md` beside this brief first.

## Your files

`TextMouth/Services/Export/TimedTextWriters.swift`, the branch's changes to `TextMouth/Services/BookExportService.swift`, `TextMouth/ViewModels/BookExportModel.swift`, `TextMouth/Views/Export/BookExportSheet.swift`, and `TextMouth/Models/BookExportWording.swift` (see them with `git diff main...podcast/finish -- <file>`), and `TextMouthProductionTests/TranscriptExportTests.swift`.

Two other teams are working in the Export dialog tonight: `speechexport` (speech to audio) and `epubexport`. Main has also moved a long way since this code was written. So read the dialog as it is now, and keep your edits in the transcript's own lines. Read `bbs claims` first; if you must change a line another team claims, ask it on the board and tell the lead.

## What this is

The Export dialog's Transcript checkbox has a picker: a transcript exports as its text (through the Convert to writers), as WebVTT, or as SubRip. A file for each track or one for the book, as the dialog's existing choices allow. See the team brief's order of work, item 3.

## Check, at least

1. **A file the format's readers accept, and what it says.** A round trip through `WebVTTReader` and `SubRipReader` gives back the same cues, on hostile transcripts. A sentence holding `-->`, `<`, `&`, `{\an8}`, a line feed (can a sentence's text hold one? an Edit Text save may), only digits, or text that looks like a cue number or `NOTE`. A sentence with no duration. Sentences that overlap. Times past 99 hours. A WebVTT cue's text may not hold `-->`, by the specification (https://www.w3.org/TR/webvtt1/, section 4). In SubRip, a line of digits followed by a timing line looks like the next cue. Check that other players would read these too, as far as the specifications say.
2. **A book of several tracks.** One file for the book: each track's cues moved along by the tracks before it (`Transcript.bookTimelineCues`), by each track's length as the book's timeline lays them. A track with no sentences. An edited transcript: which text is exported, the edited or the original? Does a cleaned-up transcript export as cleaned? Check it against what the reader shows.
3. **Word times.** A transcript of timed words (recognition's, or a Podcasting 2.0 JSON one) exports by sentence. Is that what the code does, and does a test say so?
4. **The dialog.** Each control is reachable by keyboard, labelled, and its value spoken. The picker shows only when the Transcript checkbox is on, or says why not. The choice survives as the dialog's other choices do. A book with no transcript. Names of the files written: a track's name, uniqueness, an existing file (never overwritten silently?), a name with a slash. The export's failure messages are full sentences.
5. **Encoding.** UTF-8 with what BOM and line endings, and why: SubRip is read by many old tools.
6. **The tests.** Read them as a skeptic, and prove the writers' tests by mutation in a small harness (see `common.md`). `TimedTextWriters.swift` should compile with very little else.

## Fix what you find

A commit for each fix, with a test that fails without it. Keep `BookExportService`'s public API unless a fix needs otherwise, and say so in your report.

Run `TranscriptExportTests BookExportServiceTests BookExportSheetTests BookExportConvertToTests` and the `export` area on the train.
