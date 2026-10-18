# Team audiofmt: more audio formats converted at import, lossless kept lossless, Nero chapters, and M3U playlists

Read `Scripts/agents/briefs/2026-10-18/teams-common.md` first: it is the pattern you follow, and it stands in for AGENTS.md. You are the lead, `audiofmt-lead`, on branch `team/audiofmt` made from `main`. Your workers' briefs go in `Scripts/agents/briefs/2026-10-18/audiofmt/`.

## What the user asked (in their words)

October 17: "I think it would be nice if at least we could convert a bunch more audio formats to a standardized format like how we convert the text files to markdown". October 18: "go ahead and send some teams to work on implementing the easy sets of formats, maybe choose 5-10 to start with or to do and pollish today if possible".

Their answers to the research's questions:
- **Question 8, the rarer formats:** "Yes wait on those, I do see WebM more then the others on this list". WMA, Matroska and WebM, APE, and WavPack wait for ffmpeg; they are not today's work.
- **Question 10, lossless sources and originals:** "Yes but keep originals as off, I don't think most people would need it especially sense the file loaded into the app would still probably exist unless deleted".
- **Question 11, files a playlist names elsewhere:** "Yes for now, maybe let adding trusted folders like ~/Music or something?". A playlist uses only files inside its own folder for now; trusted folders are a follow-up.

## Your items, in order of priority

Each has an entry in `TODO-2026-09-04.md` (`grep -n "FMT09 —" TODO-2026-09-04.md`, and so on) and sections in `FORMATS-RESEARCH-2026-10-17.md` (4.1, 4.2, 4.7, 5.1, and 5.2). Read those, and no other part of either document.
1. **FMT09: the audio formats macOS already decodes, converted at import.** The user's own wish, first.
2. **FMT14: lossless sources stay lossless.** Lossless sources go to Apple Lossless, Ogg FLAC is accepted, and a setting, off by default, keeps the original beside the converted file.
3. **FMT05: Nero chapter lists (chpl) in M4B and M4A files.**
4. **FMT10: M3U and M3U8 playlists.**

The samples are in `TestData/format-samples/<folder>/` (ac3, eac3, amr, 3gp, mp2, au, aifc, caf, w64, rf64, bwf, wav-variants, m4b-chapters, flac-chapters, m3u, m3u8), listed in `samples.tsv`. Every audio sample is a tone, never speech.

## The safety rules this team lives by

On October 14, 2026, Apple's Vorbis decoder locked up inside AVPlayer, TextMouth reached 34 GB of memory, and the Mac had to be reset. Since then, Ogg is converted at import by afconvert in a watched child process, and never decoded in the app.
- **No source file of a newly accepted coded format is opened by Apple's audio frameworks in TextMouth's own process.** That means no AVPlayer, AVAudioPlayer, AVAudioFile, AVURLAsset, AudioFile, or ExtAudioFile, and no playability check either.
  - Each such file is converted by afconvert under `WatchedProcess.run` (`TextMouth/Services/WatchedProcess.swift:234`), as `OggAudioConverter.convert` does (`OggAudioConverter.swift:286-355`).
  - What afconvert needs to know about a source comes from the child process (afconvert or afinfo), never from an in-process reader.
  - Only the converted file (AAC or Apple Lossless in .m4a) is probed (`AudioMediaProbe`) and played.
  - A file whose conversion fails, or runs past its limits, is refused by name, as an Ogg file is today.
- **Plain PCM that plays today stays as it is.** Decide from section 4.2 which of the new containers hold plain PCM that the player reads safely, and which are converted, and say so in your report.
- **One converter, not two.** Generalize `OggAudioConverter` into one import converter.
  - Its plan says, for each file, whether it is left as it is, converted to AAC, or converted to Apple Lossless.
  - Ogg keeps its own header reader (`OggHeaderReader`) and its checks.
  - Every import of audio passes through `FileImportService.convertOggAudio` (`FileImportService+Ogg.swift:23`; read its doc comment: ZIPs, folders, single files, feed episodes, and DAISY audio). The general step takes its place, under a name that says what it does now.
  - There is no second copy of the afconvert runner, the naming and renaming, the leftovers' removal, the orphaned-conversion sweep (`OrphanedConversionSweep.swift`), or the manifest renames.
  - The refactor's brief ends with a `grep` that must find nothing.
- **Extend `Scripts/test/ogg-lint.py`** (its rules; the engine is `difflint.py`) so that a new reader call must refuse every format converted at import, not only Ogg. Update its selftest.
- **Nothing is left behind.** Temporary outputs are removed when an import fails, is cancelled, or the app quits, and a child process never outlives TextMouth.
- **Only the staged copy changes.** The file, folder, or archive imported from is never changed.
- **No test plays sound.** Tests convert the samples (tones) in their own temporary folders, and use a stand-in tool for hangs and failures, as `OggAfconvertTests` does.

## Item notes

- **FMT09.**
  - Add the extensions the TODO entry lists, in `BookFormat.audio` (`TextMouth/Models/Book.swift`, the `.audio` case's list and its doc comment, which are yours) and in the audio document types (`TextMouth/Resources/Info.plist`, `FileImportService.supportedTypes`).
  - Check what the app's oldest supported macOS can convert (the deployment target is in `project.yml`). A format a Mac cannot convert is refused by name, never half-imported.
  - Reuse the import progress's "Converting" step and its wording.
- **FMT14.**
  - The plan converts lossless sources to Apple Lossless in .m4a (the same container, tags, and chapters as the AAC path) and lossy ones to AAC, as today.
  - Ogg FLAC, refused today, is accepted and becomes Apple Lossless.
  - **The setting.** Add it where the import settings are (find "Move to Trash instead of deleting" in `TextMouth/Views/Settings/StorageSettingsView.swift:311-325`, and the delete-after-import setting), off by default, with a label and help a VoiceOver user understands, pinned by tests. Only imports after it is turned on are affected. Decide whether a feed episode is included: its file can be downloaded again, so the recommended answer is no. Ask the user.
  - **A kept original must never play or become a track.** Keep it where no track scan, manifest, playlist, or player ever looks, and keep the Ogg rule: a kept .ogg is never opened. Find every place that lists a book's audio files (`grep -rn "audioFiles\|tracks(in\|contentsOfDirectory" TextMouth/Parsers TextMouth/Services`), and test that a kept original is in none of them.
  - Export's "Original file" (`BookExportWording.swift:17`) offers the kept original.
  - Deleting the book, or its downloaded file, deletes the original too.
  - The storage figures count it.
- **FMT05.**
  - When AVFoundation finds no chapters in an M4B or M4A file (find where chapters are read: `AudioPlaybackService.swift:1595` and `AudioBookParser.swift`), read the Nero `chpl` atom by hand: `moov` → `udta` → `chpl`.
  - The box walker is bounds-checked, as `OggHeaderReader` is. It handles 64-bit box sizes, truncated files, absurd counts, titles that are not UTF-8, and starts out of order or past the end. Use an MP4 box reader if the code already has one (search before writing one).
  - The sample `m4b-chapters/three-tones.m4b` holds both a chapter track and `chpl`. A test makes the chpl-only form by renaming the chapter-track reference in a copy, as the research did.
- **FMT10.**
  - A playlist of local files becomes one book of tracks, as a folder of tracks does, through a manifest written in memory. Reuse the folder import (`FileImportService+Packages.swift`) and `AudioManifest`; write no second path.
  - There is a heading per entry, titled by `#EXTINF` or else by the file's name, in the playlist's order. The book's title comes from `#PLAYLIST` or else the playlist's name.
  - Decode with `TextFileDecoder` (a legacy .m3u is Windows-1252 or Latin-1, an .m3u8 UTF-8), and use it as it is: team textfmt owns it.
  - Accept relative paths, backslashes, percent escapes, and `file:` URLs.
  - Use only files inside the playlist's own folder, with symbolic links and `..` resolved before that check.
  - Name the skipped entries (missing, outside the folder, a folder, not audio, a web address) in the import's message.
  - Refuse an HLS streaming playlist (any `#EXT-X-` tag, or only web addresses) in a sentence. Never fetch a URL.
  - Each entry's own format goes through the converter, so a playlist of Ogg files is converted.
  - **A playlist import deletes nothing**, neither the tracks nor the playlist, whatever the delete-after-import setting says: the tracks belong to the listener's music folders. Pin it with a test, and put it to the user as a question.
  - Edge cases, each with a test: the same file listed twice; an empty playlist, or one that is empty after skipping; a playlist with no tracks inside its folder; CRLF line ends and a BOM; Unicode names in another normalization; and a very long playlist.
- **Tests.** Name in your briefs `OggAudioConverterTests`, `OggAfconvertTests`, `OggImportConversionTests`, `OggLibraryConversionTests`, `OggNamingTests`, `OggBookCommitTests`, `OggHeaderReaderTests`, `WatchedProcessSafetyTests`, `AudioMediaImportTests`, `AudioDirectoryImportTests`, `AudioManifestTests`, `AudioManifestCheckTests`, `ArchiveImportBoundsTests`, `BookFormatTests`, `ImportAndShortcutPolicyTests`, `IntegrationImportTests`, `ImportFuzzTests`, `UncheckedConcurrencyPolicyTests`, and `LogContentPolicyTests`, and the settings' tests for FMT14 (`grep -l StorageSettingsView TextMouthProductionTests/*.swift`).
- **Reusable test tools.** Add the new formats' samples to the import fuzz's corpus (`Scripts/test/import-fuzz.sh`, `make-corpus.py`) if it takes a list.

## Regions

You own:
- `WatchedProcess.swift`, `OggAudioConverter.swift` and what it becomes, `OggHeaderReader.swift`, and `OrphanedConversionSweep.swift`;
- `FileImportService+Ogg.swift` and `FileImportService+Packages.swift`;
- `AudioMediaProbe.swift`, `AudioBookParser.swift`, `AudioManifest*.swift`, and the chapter reading in `AudioPlaybackService.swift`;
- the import settings in `StorageSettingsView.swift`;
- `ogg-lint.py`;
- the audio entries in `Book.swift` (the `.audio` case's list and its doc comment), `FileImportService.swift`, and `Info.plist`.

Team textfmt owns the rest of `BookFormat`, the text readers, `TextFileDecoder.swift`, `MarkdownCacheService.swift`, and the text entries in the shared files. It uses `WatchedProcess.run` for `textutil`: tell `textfmt-lead` on the board before you change that function's signature or behavior. Both teams add lines to `Book.swift`, `FileImportService.swift`, `Info.plist`, and the test tools' lists:
- keep your additions in blocks of your own;
- never reformat a neighbour's line;
- the orchestrator settles any conflict at the merge.

No `*.md` file but your briefs. The user documents are updated after the merge from your report: `docs/user/what-textmouth-reads.md`, whose "so it stays about the same size and sounds no worse" must be corrected (a second lossy encoding cannot promise that), `adding-books.md`, and the settings pages.

## Your report

As `teams-common.md` says, and also:
- each item's number and whether it was done;
- which formats are converted and which are left as they are;
- the setting's exact label and help;
- the exact words of every new message a listener hears;
- conversion times on the samples;
- questions for the user, each with a recommended answer;
- the sentences the user documents need.
