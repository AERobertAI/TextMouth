# Worker `pf-bookinfo`: Book Information says where a transcript came from

Slug `pf-bookinfo`, branch `podcast/bookinfo`. Read `common.md` beside this brief first.

## Goal

Decision 2 of the team's brief: a transcript from a file or a feed is marked as such, "so Retranscribe Audio… and Book Information can say so". The Transcribe Audio sheet says so already (`TranscriptionSheetModel.existingLine`, `TranscriptionWording.outsideTranscript`). Book Information says nothing about a transcript today. Add one read-only detail for a book that has one.

## Behavior

1. **The detail.** Labelled "Transcript", for an audiobook with a transcript, in each Book Information an audiobook has:
   - `MetadataEditorView`'s `audioReadOnlySection` (`TextMouth/Views/Reader/MetadataEditorView.swift:249`), as a `LabeledContent` with `.accessibilityLabel("Transcript: <value>")`, as Duration and Format are;
   - `FeedItemBookInfoWording.details(of:info:feedTitle:)` and `FeedItemBookInfoSheet` (`TextMouth/Views/Library/FeedItemBookInfoSheet.swift`), as a `BookInfoDetail`, placed after "Format".

   A text book, and an audiobook with no transcript, show no such detail.

2. **Its words,** one sentence, from a new function in `TranscriptionWording`, reusing what is there (`cameFrom`, `day`, the first sentence of `alreadyTranscribed`) without repeating it, and without changing any existing sentence:
   - from recognition: "Transcribed on November 7, 2026, in English (United States)." with `TranscriptionLanguage.name(of:)`;
   - from outside: what `cameFrom` says: "Attached from “lecture.vtt” on October 30, 2026.", "Attached from “lecture.vtt” when the book was imported, on October 30, 2026.", "The podcast's own transcript, downloaded with the episode on October 30, 2026.";
   - edited: the sentence above, then "You edited it on <day>." when `editedAt` is set; cleaned up: then "You cleaned it up on <day>." when `cleanedUp` is set. Read how `TranscriptionSheetModel` names them, and reuse its words if it has them;
   - a transcript only in iCloud: "It is in iCloud, and its details appear once the book is downloaded.", or reuse the words the sheet uses; a later TextMouth's transcript: reuse the sheet's words if it has them.
   Pin each sentence word for word in a test.

3. **The loading, never on the main thread, and never downloading.** One small async function, on `TranscriptStore` or a new small type, gives the line for a `Book`: it reads `TranscriptStore.read(from: book.tmbDirectory)` through `OffMainWork.run` and asks `TranscriptionWording`. `read` downloads nothing (`SavedFile.readWithoutDownloading`). A book without a package of its own (`tmbDirectoryName` empty) has no line. The two sheets call it from `.task(id: book.id)`, or from the sheet's model, showing nothing until it answers, and the row then appears. The sheet must not change size or lose VoiceOver's focus as it appears. `MetadataEditorView`'s audio initializer gains a parameter with a default, so its other callers and tests stand, and `ReaderView.swift:578` and `LibraryView.swift:2120` pass the book. Claim those two lines on the board; another agent has a claim on `ReaderView.swift`, so ask it before editing and tell the lead.

4. **Cost.** A long book's transcript.json runs to tens of megabytes. Read it once for each showing of the sheet, off the main thread. If a much cheaper read is easy (a small `Decodable` taking only the top-level fields, `editedAt`, `cleanedUp`, `createdAt`, `locale`, `source`), do that, with one comment saying why, and test it against a transcript `TranscriptStore` wrote.

## Tests

- The wording, each case, word for word, including a source of a later TextMouth's origin (`knownOrigin` nil).
- A hosted test that the sheet's text and accessibility label hold the detail for a book with a transcript of each origin, and that none shows for an audiobook without one and for a text book (follow `TextMouthProductionTests/FeedItemUIBookInfoTests.swift` and `BookInfoSheetTests.swift`).
- Book Info's existing tests still stand.

Run `BookInfoSheetTests FeedItemUIBookInfoTests` and your new class, with the `sheets` area, on the train. Add a line to `Scripts/test/areas.conf` for any new class. Run `make lint-a11y LINT_BASE=podcast/finish` before you report, and fix what it says of your lines.
