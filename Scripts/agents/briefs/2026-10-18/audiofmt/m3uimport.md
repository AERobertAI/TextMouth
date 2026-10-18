# Task m3uimport: an M3U or M3U8 playlist imports as one book of tracks (FMT10, step 2)

Slug `audiofmt-m3uimport`, branch `audiofmt/m3uimport` made from `team/audiofmt`. Read `Scripts/agents/briefs/2026-10-18/audiofmt/common.md` first.

Task `m3uparse` (on `team/audiofmt` already) added `M3UPlaylist` (`TextMouth/Parsers/M3UPlaylist.swift`):
- `read(at:)` and `parse(_:)` read a playlist;
- `isStreaming` and `listsOnlyWebAddresses` tell an HLS or web-only one;
- `resolve(inFolder:)` gives the tracks inside the playlist's folder, each with its path and `#EXTINF` title, and the entries skipped, each with a `SkipReason` and its `words`.

This task imports a playlist of local files as one book of tracks, as a folder of tracks imports (`FileImportService.importAudioFolderWithReport`, `FileImportService.swift:1046-1095`). It goes through the same staging, copying, manifest check, and `publishTracks`, so each entry's format goes through the converter (an Ogg or AC-3 entry becomes .m4a) and is renamed in the manifest. Write no second path.

## What to change
1. **`FileImportService.importPlaylistWithReport(from playlist: URL, toFolder: String = "", observer: ImportStepObserver? = nil) throws -> ImportedBook`**, beside `importAudioFolderWithReport`, inside `ImportRun.perform(importing: playlist.lastPathComponent, …)`:
   - **Reading the source** (`run.begin(.readingSource)`): read and resolve the playlist against its own folder. Refuse it, with a `PlaylistImportError`, when:
     - `isStreaming`: "It is a streaming playlist for audio on the web, which TextMouth does not import.";
     - `listsOnlyWebAddresses`: "It lists only web addresses, and TextMouth imports only files on this Mac.";
     - no tracks are left: "It names no audio file in its own folder that TextMouth can import.", followed, when entries were skipped, by the skipped list below.
   - **The checksum** is that of the tracks' paths and bytes, as `folderHash(of:in:)` makes it, with the playlist's own name and bytes added, so the same playlist imported twice is a duplicate.
   - **Copying.** The tracks are copied into the staged `audio` folder (`makeAudioDirectory(in:)`), each at its `path` (so `more/tone4.wav` keeps its folder). The playlist's folder is never changed.
   - **The manifest.** Write a `manifest.json` into the staged audio folder (`AudioManifest`, `TextMouth/Parsers/AudioManifest.swift:14-48`):
     - `title`: the playlist's `#PLAYLIST` title, or else the playlist's file name without its extension;
     - `tracks`: `.track(AudioManifestTrack(file: path, title: entry title))` for each track, in the playlist's order.

     Encode it as the code's other manifest writers do (`grep -rn "JSONEncoder" TextMouth/Parsers/AudioManifest*.swift TextMouth/Services/BookManifestFile*.swift`).
   - **Publishing.** Then `publishTracks(titled:…)`, as the folder import calls it.
   - **The result.** `imported.isFromFolder = true`: a playlist import deletes nothing, neither the tracks nor the playlist, whatever "After Importing a Book" says. The tracks belong to the listener's music folders, and the lead puts this to the user as a question.
2. **The skipped entries.** `ImportedBook` (`FileImportService.swift:66-101`) gains `var notice: String?`. When entries were skipped, it says: "TextMouth skipped 2 entries of “edge-cases.m3u”: “missing-file.wav” (not found) and “http://example.invalid/stream.mp3” (a web address)."
   - Use `CountWording` for "1 entry" or "N entries", and a list joined with commas and "and".
   - Name at most 10, then "and N more".
   - Put the words in a wording type, such as `PlaylistImportWording` in `TextMouth/Models/`, which the refusal's skipped list shares.
   - `LibraryViewModel.completeSingleImportedBook` (`LibraryViewModel+Import.swift:594-620`) presents a notice as it presents a warning (`presentImportMessage`).
3. **Reaching it.**
   - `importFileWithReport(from:checksum:toFolder:observer:)` (`FileImportService.swift:800-812`) sends a playlist (`M3UPlaylist.isPlaylist`) to `importPlaylistWithReport`, before the folder-of-tracks check.
   - Find every gate between the Open panel or Finder (`AppDelegate.application(_:open:)`, `.openFiles`) and that function that could refuse a .m3u first (a check of `BookFormat.detect` or of the supported types), and let playlists through.
   - Add the playlist types to `FileImportService.supportedTypes` (after the audio block, in lines of their own), and an "M3U Playlist" document type to `TextMouth/Resources/Info.plist` (extensions m3u and m3u8; for the system types, run `swift -e 'import UniformTypeIdentifiers; print(UTType(filenameExtension: "m3u")?.identifier ?? "-", UTType(filenameExtension: "m3u8")?.identifier ?? "-")'`; role Viewer, rank Alternate).

## Tests: a new file `TextMouthProductionTests/PlaylistImportTests.swift`
Each test copies a sample folder whole into its own temporary folder and imports into its own library folder, as `AudioDirectoryImportTests` does.

**The samples:**
- `m3u/playlist.m3u` gives a book titled "playlist" with four tracks in the playlist's order, headed by the four `#EXTINF` titles, `more/tone4.wav` included. The playlist and its tracks are unchanged afterwards.
- `m3u/edge-cases.m3u` gives two tracks, and the notice names its four skipped entries, in order, with their reasons.
- `m3u8/playlist.m3u8` gives three tracks with UTF-8 headings.
- `m3u8/hls-media.m3u8` and `hls-master.m3u8` are refused with the streaming sentence, and nothing is left in the library folder.

**Made in the test:**
- a playlist of two Ogg tones (`TestData/audio/ogg-vorbis-tone.ogg`, copied twice under two names), whose tracks become .m4a, with the manifest naming the .m4a files and the headings kept;
- the same file listed twice gives one track, with "listed before" in the notice;
- an empty playlist, and one whose every entry is skipped, refused with the sentence and the skipped list;
- one of only web addresses, refused;
- `#PLAYLIST:A Title` gives the book's title;
- a name spelled in NFD in the playlist and NFC on disk imports;
- a playlist of 60 entries (copies of one tone under 60 names) imports 60 tracks in order;
- the same playlist imported twice is a duplicate (the checksum);
- `ImportedBook.mayDeleteOriginal` is false.

**A library-level test** with "After Importing a Book" set to delete: the playlist and its tracks are still there. Model it on the folder import's own test of this: `grep -n "isFromFolder\|mayDeleteOriginal" TextMouthProductionTests/*.swift`.

**The words:** the three refusals and the notice (1 entry, 2 entries, and 12 entries with "and 2 more").

Then `/opt/homebrew/bin/xcodegen generate`, and commit the project with the tests.

## Commits
1. The import and its wording, with the import tests.
2. Reaching it (item 3), with its tests.

## Test classes (one run)
`PlaylistImportTests M3UPlaylistTests AudioDirectoryImportTests AudioManifestTests AudioManifestCheckTests ImportAudioFormatsTests OggImportConversionTests BookFormatTests ImportAndShortcutPolicyTests IntegrationImportTests UncheckedConcurrencyPolicyTests LogContentPolicyTests`, plus the class you find testing the gate of item 3.

## Do not touch
`M3UPlaylist.swift` (use it as it is; post a finding if it needs a change), `TextFileDecoder.swift` (team textfmt's), the converter, and any `*.md`.
