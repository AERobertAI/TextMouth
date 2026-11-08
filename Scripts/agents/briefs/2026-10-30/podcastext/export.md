# Task `export`: the WebVTT and SubRip writers, and Export of a transcript in either (FMT23, step 3)

Slug `podcastext-export`, branch `podcastext/export` (from `team/podcastext`). Read `common.md` beside this brief first.

## Goal
The Export dialog's Transcript checkbox gains a Convert to picker, as "Text as Markdown" has one (FMT18): "JSON and Markdown" (today's export, the default), "WebVTT", or "SubRip". With WebVTT or SubRip chosen, the transcript is written as one caption file for the book, its times counted from the start of the book's audio: a book of one file gets that file's captions; a book of several gets every file's captions one after another, each file's times moved along by the lengths of the files before it. (A file per track is a follow-up; the dialog has no choice for it.)

## Files
- New `TextMouth/Services/Export/TimedTextWriters.swift`: `TranscriptExportFormat`, the two writers, and `Transcript.bookTimelineCues`.
- `TextMouth/Services/BookExportService.swift`: the conversion case, the files a converted transcript makes, and writing them.
- `TextMouth/ViewModels/BookExportModel.swift`: the transcript's picker.
- `TextMouth/Models/BookExportWording.swift`: the words.
- `TextMouth/Views/Export/BookExportSheet.swift`: the picker's label, one expression.
- New `TextMouthProductionTests/TranscriptExportTests.swift`.
- `TextMouthProductionTests/BookExportConvertToTests.swift`: ONE allowed change, item 15.
Nothing else.

## Behavior

### The writers (TimedTextWriters.swift)
1. ```swift
   /// The formats Export writes a transcript in (FMT23).
   enum TranscriptExportFormat: String, CaseIterable, Sendable { case webVTT, subRip
       var timedTextFormat: TimedTextFormat   // .webVTT, .subRip
       var choiceID: String                   // "transcript-webvtt", "transcript-srt"
       func fileBytes(of cues: [TimedTextCue]) -> Data
   }
   enum WebVTTWriter { static func text(of cues: [TimedTextCue]) -> String }
   enum SubRipWriter { static func text(of cues: [TimedTextCue]) -> String }
   extension Transcript { var bookTimelineCues: [TimedTextCue] }
   ```
   `name` and `fileExtension` come from `timedTextFormat` (`TextMouth/Models/TimedText.swift`): "WebVTT"/"vtt", "SubRip"/"srt".
2. **WebVTT:** "WEBVTT\n", then for each cue "\n", the timing line `HH:MM:SS.mmm --> HH:MM:SS.mmm`, "\n", the text, "\n". Hours have at least two digits (more when needed: "100:00:00.000"). The text is `TimedTextCue.plainText(cue.text)` with `&` written `&amp;`, `<` written `&lt;`, and `>` written `&gt;` (so the text can never hold "-->" or a tag). No identifiers, no settings, no voice tags (a sentence already says its speaker as "Name: "). No cues gives "WEBVTT\n".
3. **SubRip:** each cue as its number from 1, "\r\n", the timing line `HH:MM:SS,mmm --> HH:MM:SS,mmm`, "\r\n", the text (plainText, no escaping: SubRip has none), "\r\n"; cues separated by one more "\r\n" (a blank line). CR LF throughout, as SubRip's Windows tools write it. No cues gives "".
4. `fileBytes(of:)`: the text in UTF-8; SubRip's preceded by the UTF-8 byte-order mark (EF BB BF), since a SubRip file names no encoding and Windows players rely on the mark to read UTF-8; WebVTT's without one (WebVTT is UTF-8 by definition).
5. `bookTimelineCues`: the transcript's files in order; each file's sentences become cues (`text`, start, end; no voice, no words) moved along by the sum of the `durationMilliseconds` of the files before it.

### The service (BookExportService.swift)
6. `BookExportConversion` (`:221-257`) gains `case timedText(TranscriptExportFormat)`: its `fileExtension` and `name` are the format's; `applies(to:)` is true for `.transcript` alone. The text case is unchanged.
7. `files(of:for:conversions:)` (`:752-781`): for a `.timedText` conversion, the item's files become only its transcript.json file (`source.url.lastPathComponent == TextMouthPaths.transcriptFileName`), as `.converted(from: <transcript.json>, book: details, by: conversion)`, named with the conversion's extension in place of ".json" ("Moby-Dick - Transcript.vtt"); the Markdown file of the item is not exported. The text conversions are unchanged.
8. `writeConverted` (`:902-923`) gains the `.timedText(let format)` case: decode the bytes with `TranscriptStore.decoded(_:)`; a decoding error, or a transcript whose `validationFailure()` is not nil, throws `TranscriptExportError.unusable` (new, in TimedTextWriters.swift, a `LocalizedError` whose description is "The book's transcript couldn't be read, so it wasn't exported."); then `cancellation.checkCancelled()`, and write `format.fileBytes(of: transcript.bookTimelineCues)` through `writeThroughScratchFile(to:cancellation:)` exactly as the text case does.

### The dialog (BookExportModel.swift, BookExportWording.swift, BookExportSheet.swift)
9. `conversionChoices(for: .transcript)` (`:274-286`) gives, in order:
   - id "transcript-json", name "JSON and Markdown", hint "The transcript as TextMouth keeps it, in JSON, with its text as Markdown."
   - id "transcript-webvtt", name "WebVTT", hint "Captions in WebVTT, which web browsers and most players read: one file for the book, timed from the start of its audio."
   - id "transcript-srt", name "SubRip", hint "Captions in SubRip (.srt), which nearly every player reads: one file for the book, timed from the start of its audio."
   The Markdown kind's choices are unchanged; every other kind still has none.
10. `conversionID(for: .transcript)` is "transcript-json" until another is chosen; `setConversionID` accepts the three ids for the transcript (no writer, so no options state is made).
11. `conversions` (`:348-356`): while `.transcript` is checked and on WebVTT or SubRip, it maps `.transcript` to `.timedText(format)`; on "transcript-json", or unchecked, it maps nothing (today's export, unchanged). The text kinds are unchanged.
12. **The checkbox's words** while WebVTT or SubRip is chosen: label "Transcript as WebVTT" (or "Transcript as SubRip"), then the counts and the cloud as today, and no size (a converted file's size is unknown until written, as a converted text's label says none); hint "The transcript as WebVTT captions, one file for the book, timed from the start of its audio." (SubRip alike). On "transcript-json" every word is today's. Build these in `BookExportWording` (new functions `transcriptName(as:)`, `transcriptHint(as:)`, and whatever `choiceLabel` needs), WITHOUT changing what `name(of:convertedTo:)`, `hint(for:convertedTo:)`, or `choiceLabel(...convertedTo:)` return for any input they take today: existing tests pin them for every kind.
13. **The picker's label** is "Convert transcript to" beside the Transcript checkbox, and stays "Convert to" beside "Text as Markdown", so the two never sound alike when one export shows both: add `static func convertToLabel(for kind: BookExportKind) -> String` and use it in `BookExportSheet.conversionPicker(for:)` (`:115-127`) for both the picker's title and its `accessibilityLabel`. Keep the constant `convertToLabel` as it is.
14. The sheet already draws a picker for any checked kind with choices (`BookExportSheet.swift:100`); change nothing else there.

### The one existing test you change
15. `BookExportConvertToTests.testThePickersChoicesAreMarkdownThenEachWriter` ends with a loop asserting that every kind but `.markdown` has no picker. The Transcript checkbox now has one by design: change that loop's `where kind != .markdown` to `where kind != .markdown && kind != .transcript`, and nothing else in that file. Your new test pins the transcript's choices.

## Tests (TranscriptExportTests)
- the writers' exact output (strings and bytes) for: two cues, one at 0 to 900 ms and one at 3,723,004 to 3,723,500 ms (01:02:03.004) whose text is "a < b & c > d"; a time of 360,000,000 ms ("100:00:00.000"); no cues; SubRip's byte-order mark and CR LF; a cue text holding a line break written on one line;
- `bookTimelineCues` of `TranscriptFixtures.twoFiles` (`TextMouthProductionTests/TranscriptTestSupport.swift:104-122`): the second file's cues moved by 9,000 ms, texts as they were;
- the transcript's choices (item 9) exactly; the default; the label and hint (item 12) for each choice, with one book and with several; the picker labels (item 13); `conversions` checked and unchecked (item 11); an unknown id changes nothing;
- `BookExportService.plan` with `[.transcript: .timedText(.subRip)]` plans one file "<stem> - Transcript.srt" and no Markdown;
- a real export: `let world = try makeIntegrationWorld("Transcript Export")`, `let book = try world.makeSilentAudioBook(title: "Harbour Captions", trackDurations: [3, 2])`, install `try TranscriptFixtures.transcript(of: book, sentences: ["01.wav": [...], "02.wav": [...]])` with `TranscriptStore.install(_:for:)`, then `BookExportService.export([BookExportService.offer(for: book)], kinds: [.transcript], conversions: [.transcript: .timedText(.webVTT)], to: <a sandbox folder from makeSandboxDirectory>)` writes exactly one file whose text is the expected WebVTT, the second track's cues 3,000 ms later; and with SubRip chosen, the same in SubRip; and through the dialog (`let model = BookExportModel(books: [book], library: world.library, destination: folder)`, `await model.load()`, as `BookExportConvertToTests.makeDialog` does at `:518-524`, and its `testExportingWithHTMLChosenWritesAnHTMLFile` at `:254-281` for the checks and `AnnouncementCapture`) checking only the transcript and choosing "transcript-webvtt" exports exactly the .vtt and announces it.

Run: `TranscriptExportTests BookExportConvertToTests BookExportConversionTests BookExportServiceTests BookExportSheetTests`.

## Not yours
Reading cue files, attaching, feeds. Do not change `TimedText.swift` (ask the lead).
