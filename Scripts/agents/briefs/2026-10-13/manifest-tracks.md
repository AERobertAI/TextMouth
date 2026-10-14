# Task brief: manifesttracks — arranging a ZIP of audio tracks with manifest.json

Slug `manifesttracks`. Branch `feature/manifest-tracks` from local `main`. Read `common.md` beside this brief first.

## Why
On October 13, 2026 the user imported a 4.2 GB ZIP of 176 radio dramas, each an Ogg file at the archive's top level, with names like `the_living_doll.ogg`. The orchestrator fixed why that import did nothing (Ogg was not an audio format; a batch that found no book ended silently; merged before this brief). The user then asked for this, in their words:

> "I think I remember there being a MANAfest.json that could be put in audio zips to make them go in the correct order, is there documentation for that format? Also does it allow renaming files to make more sense? Also while we're at it I think it would be nice if the format could allow inserting brief pauses measured in ms between files that should be definable in the manifest, default 250, and should allow top level headings to be marked at spots to separate them... My usecase is I downloaded a big collection of the [Twilight] Zone Radio Dramas and wanted to have them sort out into a good format"

## What exists (read these first)
- `TextMouth/Parsers/AudioBookParser.swift`: `AudioManifest` (bottom of the file: `title`, `author`, `chapters` (file → heading title), `order` (file list), `segments`); `parseDirectory(url:prober:)` reads `url/manifest.json` with `try?` (a manifest that can't be read is silently ignored), orders tracks with `orderedFileNames(_:manifestOrder:)` (unlisted tracks follow in Finder order; unknown names are ignored), and makes one chapter per track with one level-1 heading. Track names are paths relative to the audio folder (`relativeName(of:in:)`), so a track inside a wrapper folder is `Radio Dramas/elegy.ogg`.
- `TextMouth/Services/FileImportService.swift`, `importAudioZipWithReport(from:toFolder:observer:extraction:)`: extracts the ZIP into the staged package's `audio` folder, reads the manifest's title and author (again with `try?`), and publishes the book through `publishReadableBook`, which reads the book as the reader will (so a parse error fails the import, naming the step).
- `TextMouth/Models/AudioSegment.swift`: the `segments` coding, which TextMouth writes for a converted DAISY audiobook. Leave it as it is.
- The reader: `ReaderViewModel+Playback.swift` (`audioDidFinish(_:)`, `playAudioChapter()`, `fileAfterCurrentChapter`, `nameFileAfterCurrentChapter()`, `pause(playingPauseSound:)`, `stopAudioWaitingToPlay(because:)`, `isPlaybackUnderWay`, `stop()`), `ReaderViewModel+CloudDownload.swift` (`isWaitingForChapterDownload`, the model for a play that waits), and `ReaderViewModel+Navigation.swift` (`nextHeading()`, `previousHeading()`).
- Tests to extend: `AudioDirectoryImportTests`, `AudioMediaValidationTests`, `AudioZIPClassificationTests`; fixtures `AudioTestFixtures.writeSilence(to:)` and `IntegrationTestSupport.makeSilentAudioBook`.

## The format to build
Keep every manifest that works today working exactly as today. Add:

```json
{
  "title": "Radio Dramas",
  "author": "Various",
  "pauseBetweenTracksMs": 250,
  "tracks": [
    { "heading": "Season One" },
    { "file": "where_is_everybody.ogg", "title": "Where Is Everybody?" },
    { "file": "one_for_the_angels.ogg", "title": "One for the Angels", "pauseAfterMs": 1500 },
    "mr_denton_on_dooms_day.ogg",
    { "heading": "Season Two" },
    { "file": "king_nine_will_not_return.ogg" }
  ]
}
```

- `tracks`: the book's order. An entry is a track's path as a string; or an object with `file` (required), `title` (the heading's title; without it, the file's name without its extension, as today), and `pauseAfterMs`; or an object with `heading` (a non-empty string), a group heading.
- A group heading is a level-1 heading at the start of the next track. Every track after the first group heading has a level-2 heading; tracks before it keep level 1. Archive tracks the list leaves out follow the listed ones, in Finder's order (as `order` does), each with a level-1 heading of its own, outside any group.
- `pauseBetweenTracksMs`: the silence, in milliseconds, between one track's end and the next track's start while the book plays on. **Default 250 for a book whose manifest exists (old or new keys) and has no `segments`; no pause at all for a book without a manifest**, which plays gaplessly as today. `pauseAfterMs` on a track entry replaces it after that track. Either may be 0. Valid values: numbers from 0 to 60000. No pause after the last track. The pause is real time, whatever the playback speed.
- Paths in the manifest are relative to the folder holding `manifest.json`. The manifest is looked for at the archive's top level, as today, and also, when the top level has no `manifest.json` and holds exactly one visible folder and no visible files (ignore `__MACOSX` and hidden entries), inside that folder: Finder's Compress command puts a folder's contents under the folder's name, so a manifest made beside the tracks lands there. One function finds it (and the prefix its names take), used by the import's title and author and by the parser.

## Required behavior, one commit each, each with its tests
1. **The manifest in a wrapper folder.** The shared locating function above; the import's title and author and the parser both use it; names resolve relative to the manifest's folder. Tests: a ZIP made with `zipItem(at:to:shouldKeepParent: true)` whose folder holds the tracks and a manifest gets the manifest's title, order, and titles; a manifest at the top level still works; two visible folders at the top level mean no wrapper (only a top-level manifest counts).
2. **The `tracks` list.** Decoding (string or object entries; synthesized encoding must still omit absent keys, so the DAISY converter's manifests are unchanged), order, titles, group headings and levels, tracks left out. `order` and `chapters` keep working when `tracks` is absent. Tests: the example above as a parse, heading by heading (titles, levels, chapter indexes, offsets); tracks left out; a book with no group headings has level-1 headings only.
3. **Problems in a manifest fail the import, naming the problem.** Today a manifest that can't be read is ignored and the book imports in Finder's order, which a person writing JSON by hand, with a screen reader, cannot tell from success. At import only (`importAudioZipWithReport`, before the book is read), check the manifest and throw an error whose message starts with "manifest.json" and says what is wrong and where. The reader stays lenient when it loads a book that imported (a book that opens today must still open). The checks:
   - not valid JSON, or not an object: Foundation's own position ("around line 3, column 7"); when the file holds curly quotation marks (U+201C, U+201D), add that JSON needs straight ones, since TextEdit's smart quotes make them; a UTF-8 byte order mark is accepted;
   - a key it doesn't know, at the top level or in a `tracks` entry ("titel"), named;
   - a value of the wrong kind, or a pause outside 0 to 60000, naming the key (and the entry's number in `tracks`);
   - a file named in `tracks`, `order`, or `chapters` that the archive doesn't hold, or one listed twice in `tracks` (name up to five, then "and N more");
   - a `tracks` entry with both `file` and `heading`, or neither; a heading with no track after it before the next heading or the end;
   - `tracks` together with `order`, `chapters`, or `segments`: use one.
   Look at how `ImportFailure` words a failed step so the alert reads well ("Could not import “Radio.zip”: …"). Pin every message with a test.
4. **Next Heading and Previous Heading say every heading at the place they reach.** A group heading and its first track's heading share a place; landing there says both, outermost first: "Heading: Season Two, Where Is Everybody?". Wherever two headings share a place in any book, the same holds. Choosing a heading from the headings list is unchanged. Test the static helpers and the announcement.
5. **The pause between tracks.** For a multi-file audiobook (`audioLayout == .multiFile`), the reader knows the pause after each chapter, computed when the book loads by one function shared with the parser, from the package's manifest; do not add it to the persisted content index (a load from the index must get the same pauses). Then:
   - `audioDidFinish(_:)`: after the sleep-timer check, when the pause after the finished chapter is above 0, move the cursor to the next chapter at offset 0, and start that chapter (`playAudioChapter()`) once the pause has passed, from a cancellable pending start, not straight away.
   - While the start is pending, the reader is still playing: `isPlaybackUnderWay` counts it, as it counts a chapter waiting for its download, so Play does nothing, Play/Pause pauses, and the system's media commands see a playing book.
   - `stopAudioWaitingToPlay(because:)` cancels it (so pause and a sleep timer's stop do), and so do `stop()`, closing the reader, and any start of playback (`playAudioChapter()` itself), so nothing ever starts twice. A book paused during the pause rests at the start of the next track, and Play plays that track from its start.
   - Navigation during the pause moves the cursor without starting playback (the player has nothing playing), so the pending start then plays from where the listener moved: say so in a comment and test it.
   - `fileAfterCurrentChapter` names no file when a pause follows the current chapter, so the player does not roll straight on into the next file.
   - A book without a manifest, or a pause of 0, behaves exactly as today, gapless queueing included: test that.
   Tests use silent fixtures (short tracks, a pause of a few hundred milliseconds), wait with expectations or `waitUntil`, never `sleep` beyond a short margin, and play nothing audible.

## Out of scope
Renaming the files themselves (titles rename the headings); a heading's own pause; speaking a group heading's name aloud as it is reached; DAISY books; the audio editor (it refuses books whose manifest plays sections, and edits one track at a time: check that a book with `tracks` still opens in it, and report what you find).

## Report
As `common.md` says, plus: the README wording for a new section that documents the whole manifest format (old keys and new, with the example above), written for a VoiceOver user, and the sentence for the formats list.
