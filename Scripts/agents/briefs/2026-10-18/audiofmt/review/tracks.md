# Review fix tracks: a package's track scan takes no converted format (review item 7, low)

Slug `audiofmt-tracks`, branch `audiofmt/tracks` made from `team/audiofmt`. Read `../common.md`, then `common.md` in this folder, then this brief.

## The bug
`BookFormat.audio.fileExtensions` (`TextMouth/Models/Book.swift` about lines 82-106) now lists every format the import converts, and `AudioBookParser.audioFiles(in:)` (`TextMouth/Parsers/AudioBookParser.swift` lines 35-61) takes them all as tracks. ZIP imports before October 18 kept every entry, so a stray .aifc, .au, .ac3, or .caf in an older book's folder becomes a track at the book's next re-analysis or manifest edit. A stray that is not a CAF makes the whole book fail (its decoder is refused). A stray CAF of any codec (Opus, say) is decoded in TextMouth's process, and it shifts the chapters after it, under the listener's places and bookmarks.

## The fix
- **Two lists.** What Open Book and an import accept (`BookFormat.audio.fileExtensions`, unchanged) is not what a package's track scan takes. The scan takes the formats TextMouth plays as they are (the audio list without `ImportAudioConverter.convertedExtensions`), and of the converted formats only TextMouth's own CAF takes.
- **TextMouth's own CAF takes.** Find every place TextMouth writes a CAF that a track scan can meet, and how it names it. Start from `ImportAudioConverter.ownWorkingExtensions` (about lines 60-67) and `grep -rn "\.caf\|\"caf\"\|RecordingTake.fileExtension" TextMouth`: `BookOrigin.originalTakeFileName` ("original-take.caf"), the audio editor's takes and passes (`AudioEditPackage`; `AudioEditorModel+Editing.swift` about line 246; `AudioFilterProcessor.swift` about lines 29-36), and recordings (`RecordingTake`). The scan takes a CAF only when it is one of these, by its name and its place. Say in a doc comment where each lives.
- **Every caller says which list it wants.** `audioFiles(in:)` gains a parameter (or a second function) for the two scans, with no default that silently changes a path. The import's own scans keep the full list: the staged folder's tracks to convert (`ImportAudioConverter.tracks(in:where:)`), `isFolderOfTracks`, and anything else that runs before the conversion. A package's scans (loading the reader, re-analysis, a manifest edit, the library's checks) take the scan's list. Audit every use of `AudioBookParser.audioFiles(in:)` and of `trackPaths(in:)` (`grep -rn` both), and list each with your choice in your report. Uses of `BookFormat.audio.fileExtensions` itself (Open Book, ZIP classification, playlists, feeds, Export) stay as they are.
- In `ImportAudioConverter.swift` change only `tracks(in:where:)`, to ask for the import's list: task `sniff` edits `filesToConvert(in:)` beside it.

## Tests (a new class `PackageTrackScanTests`)
- **An older book keeps its tracks.** A book's folder of three .m4a tracks with a stray `extra.ac3` and a stray Opus CAF (made in the test with `/usr/bin/afconvert -f caff -d opus` from a tone written with `AVAudioFile(forWriting:)`) re-analyses with its three tracks, and its chapters, places, and bookmarks unchanged. Use the re-analysis path the app runs, and an existing places or bookmarks test's way of making a book with places (`grep -rln "reanaly\|reAnaly" TextMouth TextMouthProductionTests | head`).
- **Own takes stay tracks** where TextMouth puts them, and a stray CAF elsewhere is not one.
- **The import still converts** a staged folder of .ac3 tracks (`isFolderOfTracks` and `filesToConvert(in:)` still find them).

## Commits
1. The two lists and the scans, with the tests (review item 7).

## Test classes (one run each, in your turn)
`PackageTrackScanTests` (new), the parser's classes (`grep -l "audioFiles(in:\|AudioBookParser" TextMouthProductionTests/*.swift`), `ImportAudioFormatsTests`, `AudioDirectoryImportTests`, `AudioZIPClassificationTests`, `AudioEditorEndToEndTests`, `RecordingEndToEndTests`, and `PlaylistImportTests`.

## Do not touch
The rest of "Which Files" in `ImportAudioConverter.swift` (task `sniff`'s), `M3UPlaylist.swift` (task `m3usafety`'s), and any `*.md`.
