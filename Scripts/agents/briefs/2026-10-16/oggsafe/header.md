# Task header (REV17a finding 1): no AVFoundation on Ogg for metadata, and a hand-written Ogg header reader

Slug `oggsafe-header`, branch `oggsafe/header` (made from `team/oggsafe`). Read `Scripts/agents/briefs/2026-10-16/teams-common.md`: "The worker's part", "Rules for everyone", "The board", "Builds", "Usage", "Keeping the cost down". Never open, play, probe, or decode a real Ogg file with any Apple API in a test or an experiment (AVFoundation, AudioToolbox, afconvert, afinfo): the user's Mac was taken down by Apple's Vorbis decoder on October 14. The one allowance: your parser tests may read the bytes of the two committed fixtures (`OggTestFixtures.vorbis`, `OggTestFixtures.opus` in `OggAudioConverterTests.swift:11-15`) with `Data(contentsOf:)` and hand them to your pure parser, nothing else.

## The problem
`AudioPlaybackService.extractChapters(from:)`, `extractFullMetadata(from:)` (and `extractMetadata`, which calls it), and `getDuration(of:)` (`TextMouth/Services/AudioPlaybackService.swift:1580-1680`) open an `AVURLAsset` on any URL. Ogg URLs reach them from the import (`FileImportService.swift:179`, called from `ImportedFileMetadata.read` at :808 before staging or afconvert), `ReaderViewModel.swift:1409`, `LibraryBookInfoLoader.swift:61`, `LibraryViewModel+MetadataRefresh.swift:172`, `FileImportService+Packages.swift:398`, `AudioBookParser.swift:96,101`. `AsyncBridge.waitForResult` has no timeout, so a spinning Ogg demuxer would hang the import thread for good. The rule since October 14: Ogg never reaches Apple's decoders or AVFoundation's probing in the app's process; only `afconvert`, in a child process under a watchdog, reads it. Without AVFoundation, an Ogg file's tags and length would be lost at import, so you also read them by hand, from the file's bytes.

## Commits (one each, each with its tests; build and test after each)
1. **Guard.** One funnel, not three copies: `static func metadataAsset(for url: URL) -> AVURLAsset?` in `AudioPlaybackService` returns nil when `OggAudioConverter.isOgg(url)` (by extension, any case), else `AVURLAsset(url:)`. The three functions open their asset only through it: `extractChapters` returns `[]`, `extractFullMetadata` returns an `AudioMetadata` with only `fileFormat` set (as it starts today), `getDuration` returns nil. Tests: the funnel is nil for `a.ogg`, `a.OGA`, `a.opus`, non-nil for `a.m4a`, `a.mp3`, `a.wav`; and, to prove the guard rather than a failing decode refuses, a real playable file (`AudioTestFixtures.writeSilence(to:duration:)`, `AudioTestFixtures.writeAACSilence`) written under the name `x.ogg` gives `[]`, empty tags, and nil, while the same bytes named `x.wav` give a duration. Completion check: `grep -n "AVURLAsset(" TextMouth/Services/AudioPlaybackService.swift` must show only `makeItem` (the player's, behind `fileProblem`, line ~850) and the funnel.
2. **The reader, stream facts.** New `TextMouth/Services/OggHeaderReader.swift`, pure Swift, no Apple audio API, spec below. Tests in new `TextMouthProductionTests/OggHeaderReaderTests.swift` (run `/opt/homebrew/bin/xcodegen generate` and commit the regenerated `project.pbxproj` with it).
3. **The reader, tags.** The comment packet's title, artist, album, genre, date.
4. **Wire it.** For Ogg URLs, `getDuration` returns the reader's duration, and `extractFullMetadata` fills title, artist (ARTIST, else PERFORMER), album, genre, year (DATE as written), and the duration string from the reader. The `h:mm:ss`/`m:ss` formatting of the AVFoundation branch becomes one private helper both branches use (DRY). `extractChapters` stays `[]` for Ogg. Do NOT touch `OggAudioConverter.swift`: the lead swaps `inspect` to call your reader after another worker has finished in that file.

## The reader's contract
```swift
enum OggHeaderReader {
    enum Codec: Equatable, Sendable { case vorbis, opus }
    struct Tags: Equatable, Sendable { var title = "", artist = "", album = "", genre = "", date = "" }
    struct Header: Equatable, Sendable { let codec: Codec; let channels: Int; let sampleRate: Double; let duration: TimeInterval; let tags: Tags }
    static let headLength = 256 * 1024      // read from the start
    static let tailLength = 70_000          // read from the end; an Ogg page is at most 65,307 bytes
    static func parse(head: [UInt8], tail: [UInt8]) -> Header?   // pure
    static func read(at url: URL) -> Header?                      // FileHandle only; bounded reads; nil on any problem
}
```
Convert `Data` to `[UInt8]` once (a `Data` slice's indices do not start at 0: that traps). Every length is checked against what remains, with overflow-safe arithmetic; nothing in the parser may trap or loop without a bound, whatever the bytes are.

**Pages** (RFC 3533). Bytes 0-3 `OggS`, 4 version (must be 0), 5 header type (0x01 continued packet, 0x02 first page, 0x04 last page), 6-13 granule position (Int64 little-endian; -1 means no packet ends here), 14-17 serial, 18-21 sequence, 22-25 CRC, 26 segment count n, 27..<27+n the lacing values, then a payload of sum(lacing) bytes. A packet is its segments joined; it ends at the first lacing value below 255 (255 continues into the next segment, and into the next page, whose type then has 0x01). **Accept a page only if it lies wholly inside the buffer and its CRC verifies:** CRC-32 with polynomial 0x04C11DB7, initial value 0, no bit reflection, no final xor, over the whole page with the CRC field read as zero. Expose it as `OggHeaderReader.crc(of:)` (the tests' page builder uses it); a page that fails is skipped, so a stray `OggS` in audio data costs nothing.

**The first packet** is on the first page of `head`, at offset 0 (the first page has type 0x02); it names the codec: Vorbis `0x01 "vorbis"` then version (UInt32 LE, 0), channels (byte 11, > 0), sample rate (UInt32 LE at 12, > 0); Opus `"OpusHead"` then version byte (high nibble 0), channels (byte 9, > 0), pre-skip (UInt16 LE at 10); the Opus sample rate to report is always 48,000 (the decoder's rate). Anything else (FLAC `\x7FFLAC`, Speex, Theora, bytes that are not Ogg, an empty file) returns nil.

**Duration** comes from the last good page of that stream (same serial, granule >= 0) in `tail`: Vorbis granule / sample rate; Opus (granule - pre-skip) / 48,000, not below 0. A file shorter than the windows is simply read whole (`head` and `tail` may overlap). nil when no such page exists, or the result is not finite and above 0.

**Tags** are in the stream's second packet (Vorbis `0x03 "vorbis"`, Opus `"OpusTags"`), which starts on a later page of the same serial and may span pages: vendor length (UInt32 LE) and vendor, comment count (UInt32 LE), then each comment as a UInt32 LE length and UTF-8 `NAME=value` (the Vorbis framing byte is ignored). Names match case-insensitively; the first of a name wins; read at most 1,000 comments and stop at the first inconsistent length; a comment packet larger than 256 KiB (cover art) or not wholly inside `head` gives empty tags, never a failure. Values are `String(decoding:as: UTF8.self)`, trimmed of whitespace and newlines.

## Tests (in `OggHeaderReaderTests`; the page builder is a private helper that writes valid pages with `crc(of:)`)
- Vorbis and Opus headers built in memory: channels, rate, duration (Vorbis 22,050 Hz, granule 44,100 gives 2.0 s; Opus pre-skip 312, granule 96,312 gives 2.0 s); stereo and mono; five channels.
- Real fixtures, bytes only: vorbis 22,050 Hz, 1 channel, 2 s within 0.1; opus 48,000, 1 channel, 2 s within 0.1 (this is what proves your CRC and page logic against real files).
- Tags: all five fields; names in mixed case; a comment with no `=`; an empty value; a comment packet spanning two and three pages (continuation flag, 255-valued lacing); a first-of-a-name duplicate; a declared length of 0xFFFFFFFF; a count of 0xFFFFFFFF; a packet over 256 KiB gives empty tags and still a header.
- Refusals and robustness: wrong CRC; version 1; zero segments; a lacing table promising more payload than the buffer holds; first page cut off mid-header; FLAC-in-Ogg and Speex first packets; a last page with granule -1 ignored in favour of the page before; garbage with a stray `OggS` before the real last page; 300 buffers of seeded pseudo-random bytes (a fixed-seed generator you write, so the test is repeatable) never trap and give nil; `read(at:)` on a missing file, an empty file, a directory, and a file that is not Ogg gives nil.
- Metadata readers (commit 4): a synthetic Ogg file written to disk with the extension `.ogg` and `.opus` gives the title, artist, album, genre, year, and duration string through `AudioPlaybackService.extractFullMetadata`, and `getDuration` its seconds; a `.ogg` that is not Ogg gives empty values.

## Run
Your new class `OggHeaderReaderTests`, plus these existing classes (grep the tests folder for `extractFullMetadata|extractChapters|getDuration\(of|extractMetadata` and run every class that uses them as well): `OggAfconvertTests`, `OggLibraryConversionTests`. A failing existing test means stop and ask.

## Not yours
`OggAudioConverter.swift`, `WatchedProcess.swift`, `PlaybackMemoryGuard.swift`, `AppDelegate.swift`, any `*.md`. Only `AudioPlaybackService.swift` lines 1570-1700 (the metadata readers and their helper), the new reader file, and the new test file.
