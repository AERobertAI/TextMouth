# Review fix m3usafety: a playlist names only ordinary files inside its folder (review items 2, 5, 12)

Slug `audiofmt-m3usafety`, branch `audiofmt/m3usafety` made from `team/audiofmt`. Read `../common.md`, then `common.md` in this folder, then this brief.

Everything is in `TextMouth/Parsers/M3UPlaylist.swift`; put your tests in `TextMouthProductionTests/M3UPlaylistTests.swift`. The review's reproductions are in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/8d971e15-7103-46cf-b45e-5c4d099f2f74/scratchpad/review-audiofmt-d/`: `run1.txt` lists what each hostile entry gave, `fifo/main.swift` shows the FIFO's block.

## Item 2 (high): an entry can name a file outside the folder
`findFile` (about lines 316-337), `canonical` (340-342), `isInside` (346-350). When a path cannot be fully resolved, `resolvingSymlinksInPath()` only removes `x/..` textually. So `nothing-here/../extras/diary.m4a`, with `extras` a link to a folder outside, passes the inside check, `fileExists` follows the link, and the import copies the outside file into the book (`FileImportService.swift` about line 1318). The same happens with a dangling link or a link loop in place of `nothing-here`.
- **Fix.** Once `fileExists` says something is there, resolve the found path fully again with `realpath(3)`, which fails when a component is missing or loops (the entry is then "not found"), and repeat the inside check against the folder resolved by `realpath` too. `resolvingSymlinksInPath` drops `/private` from `/private/tmp` and `realpath` keeps it, so resolve both sides the same way. Only a path inside after full resolution is a track, and the track's `url` (and its `path` relative to the folder) come from that full resolution.
- **Tests.** Each of the three variants (a missing folder, a dangling link, and a link loop, each followed by `/../extras/diary.m4a` with `extras` linking outside) is skipped as "outside the playlist's folder", and the outside file is never a track. A link inside the folder to a file inside still works, and so does a playlist folder given as `/tmp/…` rather than `/private/tmp/…`.

## Item 5 (medium): a FIFO, or a hidden entry
`resolve` (about lines 243-255) takes any non-folder with an audio extension. A FIFO named `01.mp3` becomes a track, and the import's checksum (`FileHandle(forReadingFrom:)`, `FileImportService.swift` about lines 1299 and 2123) blocks forever, stalling the one-at-a-time import queue until the app quits. `.hidden.wav`, or a file in a dot folder, fails the whole import with a manifest error the listener never caused.
- **Fix.** Apply the folder import's own track rules (`AudioBookParser.audioFiles(in:)`, `TextMouth/Parsers/AudioBookParser.swift` lines 35-61: regular files only, nothing hidden, nothing inside a hidden folder or `__MACOSX`) in `resolve`: to the fully resolved file, and to each folder between the playlist's folder and it. Read them with `resourceValues` (`isRegularFileKey`, `isHiddenKey`) or `lstat`, never by opening the file. Skip anything else with a reason:
  - `.hidden`, said "hidden" (the file, or a folder it is in);
  - `.notOrdinaryFile`, said "not an ordinary file" (a FIFO, a socket, a device).
  These are new words a listener hears: pin them in the existing words test (`testSkipReasonWords`).
- **Tests.** A FIFO named `01.mp3` (made with `mkfifo`, and never opened) is skipped as "not an ordinary file", and the test opens nothing that could block; `.hidden.wav`, `.dotfolder/x.wav`, and `__MACOSX/x.wav` are skipped as "hidden".

## Item 12 (low): skip reasons, and an .m3u8's text
- **A colon is not a scheme.** `Disc1:Intro.mp3` is taken for a web address, since colons are legal in Mac names (`hasURLScheme`, about lines 279-289). A web address is now a scheme followed by `//` (`https://`, `rtsp://`: any scheme but `file`), or one of the schemes that never name a file: `data`, `mailto`, `urn`, and `spotify`. `file:` stays a file. Everything else is a path. Tests: `Disc1:Intro.mp3` resolves to its file; `HTTP://x/a.mp3` and `spotify:track:abc` are web addresses; `C:\Music\x.mp3` stays "outside the playlist's folder".
- **Escaped dots are outside.** `%2E%2E/x.wav` is said to be "not found" instead of "outside the playlist's folder" (about lines 321-335: only the raw spelling's outside-ness counts). When no spelling finds a file and any spelling is outside, the reason is "outside the playlist's folder". Tests: `%2E%2E/x.wav` and `..%2F..%2Foutside%2Fsecret.wav`.
- **An .m3u8 is UTF-8.** An .m3u8 (UTF-8 by its specification) with one stray bad byte is decoded whole as Windows-1252 (`read(at:)`, about line 154), so every non-ASCII path in it fails. Decode an .m3u8 as UTF-8 leniently (`String(decoding: data, as: UTF8.self)`, which replaces the bad bytes alone with U+FFFD); an .m3u keeps `TextFileDecoder`. Test: an .m3u8 naming `Café.wav`, with a bad byte on another line: `Café.wav` is a track.

## Commits
1. Item 2. 2. Item 5. 3. Item 12 (one commit, or one for each bullet).

## Test classes (one run each, in your turn)
`M3UPlaylistTests`, `PlaylistImportTests`, `ImportAudioFormatsTests`.

## Do not touch
`PlaylistImportWording.swift` (task `wording` caps its lists), `FileImportService*.swift`, `AudioBookParser.swift`, and any `*.md`. If the new reasons need more wording than `SkipReason.words`, ask your lead.
