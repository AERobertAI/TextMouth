# Task `pairing`: a transcript beside a track, attached at import (FMT23, step 2)

Slug `podcastext-pairing`, branch `podcastext/pairing` (from `team/podcastext`, which by now holds the readers, the store's builder, and `TimedTextReader`). Read `common.md` beside this brief first.

## Goal
When an audiobook is imported, a .vtt or .srt file beside a track with the same name (lecture.vtt beside lecture.m4a; 03.vtt beside 03.mp3 in a folder, a ZIP, or a playlist's folder) becomes the book's transcript, timed on that track, with no recognition, on any macOS. WebVTT is preferred to SubRip when both are there. A file found but not usable is named to the listener after the import; a book with no such file imports exactly as today.

Read first (by line): `TextMouth/Services/FileImportService.swift:855-972` (one file), `:1230-1280` (a folder), `:1307-1372` (a playlist), `:1499-1530` (`publishReadableBook`), `:2292-2382` (a ZIP and `publishTracks`), `:75-100` (`ImportedBook.notice`); `TextMouth/Services/TranscriptionService.swift:120-200` (`TranscriptionPlan`: the plan of a book's files and their paths); `TextMouth/Services/OutsideTranscript.swift`; `TextMouth/Parsers/TimedTextReader.swift`; `TextMouth/Models/TimedText.swift`; and `TextMouth/Services/Feeds/FeedEpisodeImporter.swift:185-260` (a download writing a kept transcript into its staged package before it is published, the model for this task).

## Files
- New `TextMouth/Services/TranscriptPairing.swift`: where to look, the attaching, the notice.
- `TextMouth/Services/FileImportService.swift`: the hook in `publishReadableBook` and the four callers' pairings (items 5 and 6) — your lines only; the `bughunt` team may fix bugs in this file tonight, so claim it on the board (`bbs claim`) before you edit it, read `bbs claims`, and say on `team:podcastext` which functions you touch.
- `TextMouth/Models/TranscriptionWording.swift`: the notice's words, in a new `// MARK: A Transcript Found at Import` section.
- New `TextMouthProductionTests/TranscriptPairingTests.swift`.

## Behavior
1. ```swift
   /// Where an import looks for a transcript beside the audio it imports (FMT23).
   enum TranscriptPairing: Sendable, Equatable {
       /// Beside the one file the import was chosen as: its name with .vtt, else .srt.
       case besideFile(URL)
       /// In the folder the tracks' paths are relative to: each track's path with .vtt, else .srt, in place of its extension.
       case inFolder(URL)
       func transcriptFile(forTrack path: String) -> URL?
       static func attach(_ pairing: TranscriptPairing, to staged: Book, index: BookContentIndex) -> String?
   }
   ```
2. `transcriptFile(forTrack:)`: for `.besideFile(source)`, `source` without its extension plus each extension of `TimedTextFormat.cueFileFormats` in order (vtt, then srt), each tried lowercased and then uppercased ("VTT"), the first that exists as a regular file (`FileManager.default.fileExists(atPath:isDirectory:)`, not a folder) winning; the track's path is not used (the one file's name may have changed in a conversion: lecture.ogg becomes lecture.m4a). For `.inFolder(folder)`, the same with `folder` + the track's path without its extension. A symbolic link is not followed (`FileImportService.isSymbolicLink`). Nil when none.
3. `attach(_:to:index:)`, for a staged audiobook whose content was just read (`staged.tmbDirectory` is the staged package):
   - the plan: `TranscriptionPlan.make(for: staged, index: index, isDataless: DatalessFiles.isDataless, measure: TranscriptionPlan.duration(ofAudioFileAt:))`; if it throws, log and return nil (the audio is read already, so this only happens to a file macOS cannot measure);
   - for each file of the plan, its transcript file (item 2); none anywhere returns nil at once, writing nothing;
   - each one found: its format from its extension, `TimedTextReader.read(fileAt:as:)` (20 MB default), its `sentences`, and `OutsideTranscript.checkFits(_:durationMilliseconds: Transcript.milliseconds(file.duration))`; one that fails is set aside with its error;
   - when any was kept: `OutsideTranscript.transcript(sentencesByFile:plan:source:)` with `TranscriptSource(origin: .imported, format: <the first kept file's format>, fileName: <its name when exactly one file was kept, else nil>)`, written into the staged package with `TranscriptStore.write(_:into: staged.tmbDirectory)`. The book's text is then written from it the first time the book opens (`TranscriptTextLoader`'s rebuild of a transcript without a text layer), as an episode's kept transcript is; its library row says "Transcribed" as soon as it is listed (`TranscribedBooks` looks for transcript.json), and no offer to transcribe it is made (`TranscriptionOffers` skips a book with a transcript.json);
   - a failure to build or write is logged and returns nil: it never fails the import;
   - the debug log: one `DiagnosticLog.event(.import, "TRANSCRIPT_FOUND_AT_IMPORT: \(title): \(kept) of \(files) tracks' transcripts attached")` when any was kept, and one `TRANSCRIPT_FOUND_AT_IMPORT_REFUSED: \(title): \(fileName): \(reason)` per file set aside (the reason is the error's description, which never quotes the file's text); names, never paths.
4. **The notice** (returned, nil when nothing was set aside), in `TranscriptionWording`, pinned by tests:
   - one file set aside: `transcriptNotAttached(fileName:reason:)`: "“\(fileName)” was beside the audio but wasn't attached as the book's transcript: \(reason)"
   - several: `transcriptsNotAttached(fileNames:)`: "These transcript files were beside the audio but weren't attached: “03.vtt”, “07.vtt”, and “09.srt”. The debug log says why." Names in the plan's order, an Oxford comma before "and" from three on ("“a.vtt” and “b.vtt”" for two), at most five named and then ", and 4 more" for the rest.
5. **The hook:** `publishReadableBook` (`:1499`) gains `pairingTranscripts pairing: TranscriptPairing? = nil`. Right after `readableContent` returns, for an audiobook with a pairing, `let notice = TranscriptPairing.attach(pairing, to: staged, index: content.index)`; the `ImportedBook` it returns carries that notice. Every other caller (feeds, recordings, packages) passes nothing and is unchanged.
6. **The callers:**
   - `importFileWithReport` (`:868-972`): `.besideFile(sourceURL)` when `format.isAudio`.
   - `publishTracks` (`:2348-2382`) gains a `pairingIn folder: URL` parameter, passed on as `.inFolder(folder)`: the ZIP import (`:2324`) passes its `audioDirectory` (the archive's tracks, extracted there with any .vtt beside them); the folder import (`:1262`) passes `folder`, the folder chosen; the playlist import (`:1351`) passes the playlist's own folder (`playlist.deletingLastPathComponent()`), where its tracks' paths are relative to.
   - The playlist import sets `imported.notice` after `publishTracks` (`:1366`): make it keep the pairing's notice, the two joined by a space when both are there (the pairing's first), and nil when neither is.
7. A ZIP batch of several books extracts its books and imports each with `importFileWithReport`, so an audio file and its .vtt in such a ZIP pair through item 6's first case; no change for it.

## Tests (TranscriptPairingTests)
Each test makes its own files in a folder of its own (`makeSandboxDirectory`), and removes its imported packages (`importedForTest` does for one file; for the others add a teardown as it does).
- one file: copy the sample folder `vtt` (`copyOfFormatSample("vtt")` copies the folder, with tone4.wav and tone4.vtt) and import its tone4.wav with `importedForTest`: the package holds a transcript.json whose source is imported/webvtt/"tone4.vtt" and whose first sentence is "Ana: First tone, 440 hertz."; `imported.notice` is nil; `TranscriptionOffers.offersTranscription(of:)` is false for it; and `TranscriptTextLoader.load(for:audioIndex:)` (as `TranscriptTextTests` calls it) shows the text;
- the SubRip sample folder likewise; both a .vtt and a .srt beside one file: the .vtt wins;
- none beside it: no transcript.json, no notice, the import as before;
- a .vtt whose last cue ends at 20 s beside the 4-second tone: no transcript.json, the import succeeds, and the notice is exactly `transcriptNotAttached` with the `runsPastTheEnd` sentence; a garbage .vtt: the notice with `TimedTextError.notTimedText(.webVTT)`'s sentence;
- a folder of tracks (`AudioTestFixtures.writeSilence(to:duration:)`: 01.wav of 2 s and 02.wav of 2 s, with 01.vtt timing one cue at 0 to 1,000 ms) imported with `FileImportService.importAudioFolderWithReport(from:toFolder:)`: file "01.wav" has that sentence, "02.wav" none, the source names "01.vtt";
- a ZIP of the same tracks and 02.srt (write the ZIP with ZIPFoundation as `ArchiveImportBoundsTests` or `AudioDirectoryImportTests` does: read one of them first) imported with `importAudioZipWithReport(from:)`: paired;
- a playlist (see how `M3UPlaylistTests` or the playlist import tests write one) listing the two tracks, with 01.vtt beside the first: paired, and its own notice of skipped entries still said after a pairing notice when both are there;
- three, two, and seven files set aside: the wording of item 4 (unit-test the wording functions; build one import with two bad files to see the joined notice end to end).

Run: `TranscriptPairingTests AudioDirectoryImportTests M3UPlaylistTests ImportAudioFormatsTests IntegrationImportTests TranscriptionOfferTests OutsideTranscriptTests` (and whichever test class covers the playlist import, found by `grep -l importPlaylistWithReport TextMouthProductionTests/*.swift`).

## Not yours
Attach Transcript…, feeds, export, Replace Existing (`DuplicateReplacement` carries an old copy's transcript into the new package when its audio fits, over a paired one, which is what decision 1 asks; do not change it, but say in your report whether you confirmed it by reading `DuplicateReplacement.swift:540-575, 683-725, 860-875`). Do not change `TimedText.swift`, `OutsideTranscript.swift`, or `TimedTextReader.swift` (ask the lead).
