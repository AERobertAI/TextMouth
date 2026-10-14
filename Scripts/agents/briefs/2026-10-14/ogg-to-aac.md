# Task brief: oggtoaac — Ogg audio converted to AAC, at import and once for the library (B06)

Slug `oggtoaac`. Branch `fix/ogg-to-aac` from local `main`. Read `common.md` beside this brief first, above all its rule on Ogg.

## Why, and the user's words
On October 14, 2026 the user's radio dramas, 176 Ogg Vorbis tracks in one audiobook, played through AVPlayer at 1.5x. A few seconds into the second track, Apple's Vorbis decoder (`ACVorbisDecoder`, new in macOS 15.4) locked up inside AudioToolbox. Its `AQConverterThread` spun in `ACSpanningInputBuffer::checkRelocateClientPacketDescriptions` → caulk's real-time allocator, and TextMouth grew to 34 GB until the Mac ran out of memory and had to be reset (JetsamEvent and WindowServer watchdog, 16:31). Offline decoding of the same files (afconvert, AVAssetReader) had worked. So TextMouth must never hand Ogg to AVPlayer.

The user: "I say yes to converting everything to m4a or acc (which ever one is losslessly smaller) and go ahead an convert all the ogg files already imported and the manafest as well so we don't have to warry about old coppies (this Text Mouth library is stil the only one in existants until I make it public some day...)".

The format is decided: **AAC-LC in an .m4a file.** Lossless (ALAC) would be about ten times larger and can't restore what the Ogg encoding lost. Each track is encoded at its source's average bitrate (bytes × 8 ÷ duration), rounded up to the next standard AAC rate for its channel count:
- stereo: 64, 80, 96, 112, 128, 160, or 192 kbps;
- mono: half of those.

So a track stays about the same size and is no worse. Keep the source's channel count and sample rate where AAC takes it, else 44.1 or 48 kHz. Write it with the audio editor's AAC writer (`AudioEditRenderer` and `AudioRenderSettings`), not a second encoder path. Decode with ExtAudioFile or AVAssetReader, never a player.

## Required behavior, one commit each, with tests
1. **The converter.** One function converts an Ogg file (.ogg, .oga, .opus) to an AAC .m4a beside it, under a temporary name. It checks the result with `AudioMediaProbe` (it plays, and its length is within a second of the source's), then gives it its final name: the same stem with .m4a, made unique if taken. It reports how long the source took and the bytes before and after. Up to four files at a time; this Mac has 8 GB of memory, so measure peak memory on the 176-track scale with synthetic fixtures before choosing. Tests use the synthetic fixtures in `TestData/audio` (make longer synthetic ones with ffmpeg if needed; never the user's audio).
2. **Every import converts its Ogg before anything plays or reads it as a book.** This covers a ZIP of tracks, a folder of tracks (FR17's `importAudioFolderWithReport`), a single file from Open Book or Finder, a feed's downloaded episode, and a DAISY book's Ogg audio.
   - The step: a new import step, Converting its audio, with the overlay's count ("12 of 176 tracks"). It comes after extraction and after the manifest's check, which names the archive's .ogg files as they are, and before Reading its audio.
   - The manifest: each converted file is renamed in the package's manifest (`tracks`, `order`, `chapters`, `segments`) through the one write path FR17 made (`BookManifestFile.change`, as `AudioEditBookRender.renameTrack` uses it). The ZIP or folder imported from is never touched.
   - A single file: its book's file is the .m4a.
3. **Once for the library: the books already imported.** A launch pass runs off the main thread, once per library on this Mac, recorded by the library's identity as FR18's hand-edit pass records itself. It converts every Ogg file of every book of the library's own: a folder of tracks, a single Ogg file, or a DAISY package's audio.
   - **Commit per book:** convert all of a book's Ogg files beside them and check each. Then, in one step, rename them in its manifest, update its record and content index (the chapters' audio file paths; a single-file book's `filePath`), and the library row. Then delete the Ogg files.
   - **Places:** positions, bookmarks, and skips stay exactly as they are, since the order and durations do not change.
   - **Interruptions:** a pass interrupted before a book's commit leaves that book as it was, and the next launch converts it again.
   - **Space and the cloud:** before a book, check the disk can hold its converted copy plus the import's one-gigabyte reserve. A book that doesn't fit waits, with a log line, and an alert once says how much space it needs. Never download: a book whose files are only in the cloud waits for a launch that finds them here.
   - **While a book converts:** its reader refuses to play it. Play says "This book's audio is being converted from Ogg to AAC. It plays once the conversion ends." (pin it). The Library window's overlay shows the progress, as in "Converting audio: 12 of 176 tracks of “tri-Zone-Radio-Dromas”".
   - **Log:** one `OGG_CONVERTED` event line per book (tracks, minutes taken, bytes before and after), and one `OGG_CONVERSION_WAITS` line for each book that waits.
   - The user's library has one such book, with 176 tracks and about 4 GB.
4. **Nothing hands Ogg to a player any more.** As a last guard, the audio service refuses an Ogg URL. The reader then says the book's audio needs converting and starts the book's conversion, rather than play it. Test the refusal without playing anything.

## Out of scope
The playback watchdog and the sound effects (agent `playbackwatch`); other formats.

## Report
As `common.md` says. Include the measured conversion speed and peak memory, the bitrate chosen for a 75 kbps stereo Vorbis source, and the documentation wording, naming the page for each sentence (`docs/user/what-textmouth-reads.md`, `docs/user/audiobook-manifest.md`, `docs/user/adding-books.md`, `docs/user/where-your-library-lives.md`, and the architecture pages you touch).
