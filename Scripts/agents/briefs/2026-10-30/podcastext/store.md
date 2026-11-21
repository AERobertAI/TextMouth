# Task `store`: a transcript from outside, in the transcript store (FMT23 step 2, FMT25)

Slug `podcastext-store`, branch `podcastext/store` (from `team/podcastext`). Read `common.md` beside this brief first.

## Goal
Everything the later tasks (Attach Transcript…, the import's pairing, the podcast fetch) need to save a transcript that came from a file or a feed, as recognition saves one: where it came from, recorded in transcript.json and in the book's record; a builder that turns timed sentences into a `Transcript` of the book's audio, fingerprinted and measured as recognition does it, refusing one that runs past the audio's end; an install that keeps a transcript the book already has when asked to; the Retranscribe sheet saying where the book's transcript came from; and no offer to transcribe a book that has a transcript.

Read first (by line): `TextMouth/Models/Transcript.swift` (all, 395 lines), `TextMouth/Services/TranscriptInstallation.swift:16-170`, `TextMouth/Services/TranscriptionService.swift:120-200` (the plan: files, paths, durations) and `:330-405` (how recognition builds a transcript), `TextMouth/ViewModels/TranscriptionSheetModel.swift:165-180, 300-335, 425-440`, `TextMouth/Models/TranscriptionWording.swift:140-160, 410-431`, `TextMouth/ViewModels/TranscriptionOffers.swift`, and the cue model `TextMouth/Models/TimedText.swift`.

## Files
- `TextMouth/Models/Transcript.swift`: `TranscriptSource`; `source` on `Transcript` and `TranscriptNote`.
- New `TextMouth/Services/OutsideTranscript.swift`: the builder and its errors.
- `TextMouth/Services/TranscriptInstallation.swift`: the install's `keepingExisting`.
- `TextMouth/ViewModels/TranscriptionSheetModel.swift` and `TextMouth/Models/TranscriptionWording.swift`: the sheet's line.
- `TextMouth/ViewModels/TranscriptionOffers.swift`: no offer for a book with a transcript.
- New `TextMouthProductionTests/OutsideTranscriptTests.swift`.
Nothing else.

## Behavior

### Where a transcript came from (Transcript.swift)
1. ```swift
   /// Where a transcript that TextMouth's recognizer did not make came from (FMT23, FMT25) ...
   struct TranscriptSource: Codable, Hashable, Sendable {
       enum Origin: String, Sendable {
           case attached   // the listener's Book > Attach Transcript…
           case imported   // a file found beside the audio when the book was imported
           case podcast    // the podcast's own transcript, downloaded with the episode
       }
       var origin: String          // an Origin's raw value, or a later TextMouth's, kept as written
       var format: String          // a TimedTextFormat's raw value, or a later one's, kept as written
       var fileName: String?       // the file's name when one file was read; never a path, never an address
       init(origin: Origin, format: TimedTextFormat, fileName: String? = nil)
       var knownOrigin: Origin? { Origin(rawValue: origin) }
       var knownFormat: TimedTextFormat? { TimedTextFormat(rawValue: format) }
   }
   ```
   The stored values are strings so that a value a later TextMouth writes neither fails the whole transcript.json (an unknown enum case would throw, and an unusable transcript.json is set aside) nor is lost when this TextMouth saves the transcript again. Comment it so.
2. `Transcript` gains `var source: TranscriptSource? = nil` after `cleanedUp`, documented: nil for a transcript recognition made; transcript.json leaves it out until then, so a recognized transcript is written byte for byte as before, and an earlier TextMouth reads one with a source as any other (JSONDecoder ignores keys it does not know).
3. `TranscriptNote` gains `var source: TranscriptSource? = nil`, and `Transcript.note` passes it, so the book's record (bookInfo.json, through the index's transcript layer and `saveContentAnalysis`) notes where the transcript came from. No layout version changes: both are optional additions.

### The builder (OutsideTranscript.swift)
4. ```swift
   enum OutsideTranscript {
       static let undeterminedLocale = "und"      // BCP 47's "undetermined": a file rarely says its language, and validation needs one
       static var noRecognizer: TranscriptSpeechModel   // engine "none", assetStatus "none", systemVersion ProcessInfo's operatingSystemVersionString
       static func checkFits(_ sentences: [TranscriptSentence], durationMilliseconds: Int) throws
       static func split(_ sentences: [TranscriptSentence], across files: [TranscriptionPlan.File]) -> [String: [TranscriptSentence]]
       static func transcript(sentencesByFile: [String: [TranscriptSentence]], plan: TranscriptionPlan, source: TranscriptSource,
                              now: Date = Date(), hasher: FingerprintHasher = .md5) throws -> Transcript
       static func transcript(bookTimeline sentences: [TranscriptSentence], plan: TranscriptionPlan, source: TranscriptSource,
                              now: Date = Date(), hasher: FingerprintHasher = .md5) throws -> Transcript
   }
   enum OutsideTranscriptError: LocalizedError, Equatable {
       case runsPastTheEnd(transcriptEnd: Int, audioEnd: Int)   // milliseconds
       case noText
       case alreadyTranscribed
       case unusable(String)
   }
   ```
5. `checkFits`: when the latest `endMilliseconds` among `sentences` is more than `TimedTextLimits.pastTheEndMarginMilliseconds` after `durationMilliseconds`, throw `.runsPastTheEnd(transcriptEnd: <that end>, audioEnd: durationMilliseconds)`. Exactly the margin is accepted. No sentences is fine.
6. `split` (the book's timeline: its files one after another, whole, in the plan's order; each file's length is `Transcript.milliseconds(file.duration)`, so file k starts at the sum `c[k]` of the lengths before it):
   - a sentence goes to the last file whose start `c[k]` is at or before the sentence's start (a sentence starting exactly where a file starts goes to that file; one starting at or past the book's end goes to the last file; a file of no length gets nothing);
   - its start and end become `start - c[k]` and `end - c[k]`, each held inside `0...<the file's length>`;
   - its words move by `-c[k]` too, and are kept only when every word then lies inside the sentence's new time; otherwise the sentence keeps no words;
   - each file's sentences keep their order; a file that gets none is absent from the result.
7. `transcript(sentencesByFile:plan:source:now:hasher:)`: for each file of `plan`, in order: its sentences (none when the dictionary names it not), `checkFits` against its length, and a `TranscriptFile` with the file's `path`, `FileFingerprint(of: file.url, hasher: hasher)` (nil throws `TranscriptionError.unreadableFile(file: path, reason: TranscriptionError.unreadableAudioReason)`), and `durationMilliseconds` as item 6. Paths the plan does not list are ignored. When no file has a sentence, throw `.noText`. The transcript: `version: Transcript.currentVersion`, `locale: undeterminedLocale`, `model: noRecognizer`, `app: .current`, `createdAt` = `now` cut to whole seconds (as `TranscriptionService.swift:396` does), `source`. When `validationFailure()` is not nil, throw `.unusable(<the reason>)`.
8. `transcript(bookTimeline:...)`: `checkFits(sentences, durationMilliseconds: <the sum of the files' lengths>)` first, then `split`, then item 7.
9. `errorDescription`s, exactly:
   - `.runsPastTheEnd(t, a)`: "The transcript runs to \(TimeFormatting.spoken(Double(t) / 1000)), past the end of the audio at \(TimeFormatting.spoken(Double(a) / 1000)), so it was made for other audio."
   - `.noText`: "The transcript holds no text to attach."
   - `.alreadyTranscribed`: "The book has a transcript already, so TextMouth kept it."
   - `.unusable`: "The transcript's times don't fit together, so TextMouth can't use it." (the reason is for the log only; it never quotes text)

### Keeping a transcript the book has (TranscriptInstallation.swift)
10. `TranscriptStore.install` gains `keepingExisting: Bool = false`, placed right after `for book:` so no existing call changes. When true, inside the storage work, right after the package-exists guard (`:81-83`) and before anything is read or written, a transcript.json in the package (`FileManager.default.fileExists`, a look that never downloads, so one only in iCloud counts as one) throws `OutsideTranscriptError.alreadyTranscribed`. Document it: the podcast fetch passes true, so a transcript the listener has (an earlier download's, kept with the episode) is never replaced; checking inside the storage work leaves no gap between the check and the write.

### The Retranscribe sheet's line (TranscriptionSheetModel.swift, TranscriptionWording.swift)
11. `ExistingTranscript` gains `var source: TranscriptSource? = nil`; `load()` fills it from `transcript.source`.
12. `existingLine`: for a transcript with a source, `TranscriptionWording.outsideTranscript(source, on: existing.createdAt)`; otherwise today's line, unchanged.
13. `outsideTranscript(_:on:)` is one sentence of where it came from, then " Transcribing again replaces this transcript." The first sentence, with `day` = `TranscriptionWording.day(date)` and a file name in curly quotes:
   - attached, with a file name: "Attached from “lecture.vtt” on \(day)."
   - attached, no name: "Attached from a WebVTT file on \(day)." (the known format's `name`), or "Attached from a file on \(day)." (format unknown)
   - imported, with a file name: "Attached from “lecture.vtt” when the book was imported, on \(day)."
   - imported, no name: "Attached from WebVTT files when the book was imported, on \(day)." or "Attached from files when the book was imported, on \(day)."
   - podcast: "The podcast's own transcript, downloaded with the episode on \(day)."
   - an origin this TextMouth does not know: "Attached on \(day)."

### No offer to transcribe a transcribed book (TranscriptionOffers.swift)
14. `offersTranscription(of:)` also requires that the book's package holds no transcript.json (`FileManager.default.fileExists` of `TextMouthPaths.transcriptPath(in: book.tmbDirectory)`, which never downloads): the import's pairing (a later task) gives a book a transcript as it is imported.

## Tests (OutsideTranscriptTests)
- `TranscriptSource`: encodes as `{"fileName":…,"format":"webvtt","origin":"attached"}` (sorted keys); an unknown origin and format ("radio", "ttml") decode, report `knownOrigin`/`knownFormat` nil, and encode back unchanged; a transcript.json holding such a source reads as `.found` through `TranscriptStore.read` (write the bytes into a sandbox package folder made with `makeSandboxDirectory`);
- a transcript without a source encodes with no "source" key (`TranscriptStore.encoded(TranscriptFixtures.twoFiles)`), and decodes the same as before; with a source, it round-trips; `note.source` follows;
- `split`, on plan files built by hand (`TranscriptionPlan.File(path:url:duration:)`, durations 3 and 2 seconds): a sentence at 0, one ending past 3,000 that starts before it (stays in file one, its end held at 3,000), one starting exactly at 3,000 (file two, at 0), one starting past 5,000 (file two, held at 2,000 to 2,000), words moved and words dropped, a zero-length file between two others getting nothing;
- `checkFits` at exactly the margin and one millisecond past it, and its error's words for 3,725,000 against 3,600,000 ms ("…runs to 1 hour, 2 minutes, 5 seconds, past the end of the audio at 1 hour, so…", as `TimeFormatting.spoken` words them: compute them with it rather than typing them);
- the builders on a real book: `let world = try makeIntegrationWorld("Outside Transcript")`, `let book = try world.makeSilentAudioBook(title: "Harbour Captions", trackDurations: [3, 2])`, `let plan = try TranscriptionPlan.make(for: book)`: fingerprints equal `FileFingerprint(of:hasher: .md5)` of each track, durations 3,000 and 2,000, locale "und", engine "none", the source, `createdAt` in whole seconds; `.noText`; `.runsPastTheEnd` for a file; and `TranscriptStore.install` of the result followed by `BookInfo.load(from: book.tmbDirectory).state.transcript?.source` equal to the source, and `TranscriptTextLoader.load(for:audioIndex:)` (as `TranscriptTextTests` calls it) showing the sentences' text;
- `keepingExisting`: install one transcript, then another with `keepingExisting: true`: it throws `.alreadyTranscribed` and transcript.json's bytes are unchanged; without the flag it replaces;
- every `outsideTranscript` wording of item 13 exactly, and the sheet's `existingLine` for a found transcript with a source, through `TranscriptionSheetModel(request:library:services:)` and `makeSheetServices(transcript:)` as `TranscriptionSheetTests.testABookTranscribedAlreadyOffersTranscribeAgain` (`TextMouthProductionTests/TranscriptionSheetTests.swift:560-576`) does;
- the offer: with the setting on (`preservePreferences`, as `TranscriptionOfferTests.swift:93-110` does), a book whose package holds a transcript.json is not offered, and one without is offered exactly when `TranscriptionAvailability.systemSupport == .available`.

Run: `OutsideTranscriptTests` and the `transcripts` area (`python3 Scripts/test/run-area.py ... transcripts OutsideTranscriptTests`).

## Not yours
Reading files, the Attach command, the import, feeds, Book Information. Do not change `TimedText.swift` (ask the lead).
