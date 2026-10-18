# Task m3uparse: reading an M3U or M3U8 playlist and finding its files (FMT10, step 1)

Slug `audiofmt-m3uparse`, branch `audiofmt/m3uparse` made from `team/audiofmt`. Read `Scripts/agents/briefs/2026-10-18/audiofmt/common.md` first.

A playlist of local files will import as one book of tracks (task `m3uimport`, later). This task is the pure part: reading the playlist, and deciding which entries are files TextMouth may use. TextMouth is not sandboxed, so a playlist could name any file the user can read. The user's answer: only files inside the playlist's own folder, with the entries skipped named. Never fetch a URL.

## A new file `TextMouth/Parsers/M3UPlaylist.swift`
```swift
struct M3UPlaylist: Equatable, Sendable {
    struct Entry: Equatable, Sendable { let location: String; let title: String?; let line: Int }
    var title: String?          // #PLAYLIST:
    var entries: [Entry]
    var isStreaming: Bool       // any line starting with #EXT-X-
    static let fileExtensions: Set<String> = ["m3u", "m3u8"]
    static func isPlaylist(_ url: URL) -> Bool
    static func parse(_ text: String) -> M3UPlaylist
    static func read(at url: URL) throws -> M3UPlaylist
}
```
1. **`parse`:**
   - Lines are split at CR, LF, or CRLF. A leading byte-order mark is dropped, each line is trimmed, and blank lines are skipped.
   - `#EXTM3U` is ignored, and `#PLAYLIST:<title>` sets the title.
   - `#EXTINF:<seconds>[ attributes],<title>` gives the next entry its title: the text after the first comma that is not inside a quoted attribute value. A blank title is nil, and the title clears once an entry takes it.
   - A line starting with `#EXT-X-` sets `isStreaming`. Any other line starting with `#` is a comment.
   - Every other line is an entry, numbered by its line from 1.
2. **`read`:**
   - The file's bytes, at most 4 MiB, are decoded by `TextFileDecoder.decode(_:fileName:format: .txt)`. Use that decoder as it is: team textfmt owns it. A legacy .m3u is Windows-1252 or Latin-1, which its fallback reads; an .m3u8 is UTF-8.
   - A larger file throws `M3UPlaylistError.tooLarge(fileName:)`, whose words are "The playlist “<name>” is too large to read." A read error is thrown as it is.

## Resolving entries to files
```swift
extension M3UPlaylist {
    struct Track: Equatable, Sendable { let url: URL; let path: String; let title: String? }   // path: relative to the folder, "more/tone4.wav"
    struct Skipped: Equatable, Sendable { let location: String; let reason: SkipReason }
    enum SkipReason: Equatable, Sendable { case webAddress, outsideFolder, missing, folder, notAudio, listedBefore }
    struct Resolution: Equatable, Sendable { var tracks: [Track]; var skipped: [Skipped] }
    func resolve(inFolder folder: URL, fileManager: FileManager = .default) -> Resolution
    var listsOnlyWebAddresses: Bool   // entries is not empty, and every one is a web address
}
```
- **`SkipReason.words`:** "a web address", "outside the playlist's folder", "not found", "a folder", "not an audio file", "listed before".
- **Each entry, in order, is tested in this order** (the first that applies decides):
  1. A location with a URL scheme (`^[A-Za-z][A-Za-z0-9+.-]+:`; a single letter followed by `:\` or `:/` is a Windows drive, not a scheme):
     - `file:` becomes its path, percent escapes decoded, through `URL(string:)`;
     - any other scheme is `webAddress`.
  2. Backslashes become slashes. A Windows drive path (`C:/Music/x.mp3`) is `outsideFolder`.
  3. A relative path is taken from `folder`; an absolute one as it is. When that path does not exist but its percent-decoded form (`removingPercentEncoding`) differs and does, the decoded one is used.
  4. **Outside.** Both the folder and the candidate are made canonical (`resolvingSymlinksInPath()`, then `standardizedFileURL`). The candidate must lie strictly inside the folder, by path components, not by string prefix; otherwise `outsideFolder`. This is checked before existence, so nothing outside is probed. A symbolic link inside the folder that points outside is `outsideFolder`.
  5. `missing` when nothing is there, `folder` when it is a directory, and `notAudio` when its extension, in any case, is not in `BookFormat.audio.fileExtensions`.
  6. `listedBefore` when an earlier track has the same canonical path (compared in Unicode NFC, `precomposedStringWithCanonicalMapping`).
- **A track's `path`** is its canonical path relative to the canonical folder. Its title is the entry's.

## Tests: a new file `TextMouthProductionTests/M3UPlaylistTests.swift`
**`parse`:**
- CRLF line ends and a byte-order mark;
- `#EXTINF` with attributes (`#EXTINF:-1 tvg-name="a,b",Title`) and without a title;
- `#PLAYLIST`, comments, and blank lines;
- an HLS media and a master playlist (the samples `m3u8/hls-media.m3u8` and `hls-master.m3u8`) setting `isStreaming`.

**`read` and `resolve` on the samples,** each folder copied whole into the test's temporary folder:
- `m3u/playlist.m3u` (Latin-1, CRLF, a backslash path into `more/`) gives four tracks, in order: tone1, tone2, tone3, more/tone4. Their titles are "Café tone, 440 Hz", "Señal two - 660 Hz", "Third (subfolder-free)", and "Fourth in a subfolder".
- `m3u/edge-cases.m3u` gives tracks tone2 and tone1. Skipped, in order, are `missing-file.wav` (missing), `../outside-the-folder.wav` (outside), `/System/Library/Sounds/Basso.aiff` (outside), and `http://example.invalid/stream.mp3` (web).
- `m3u8/playlist.m3u8` gives three tracks with their UTF-8 titles.

**Made in the test:**
- a symbolic link inside the folder pointing outside;
- `more/../tone1.wav` (inside);
- `tone%201.wav` naming "tone 1.wav";
- a `file://` URL inside the folder;
- a folder entry, and `notes.txt`;
- the same file as `tone1.wav` and as `./tone1.wav` (the second is `listedBefore`);
- a name spelled in NFD in the playlist and NFC on disk;
- `C:\Music\x.mp3`;
- a playlist of only web addresses;
- an empty playlist;
- 5,000 entries, parsed and resolved in under two seconds.

Then `/opt/homebrew/bin/xcodegen generate`, and commit the project with the tests.

## Commits
One: the parser, the resolution, and the tests.

## Test classes (one run)
`M3UPlaylistTests BookFormatTests`

## Do not touch
Every existing file but the project; no import code (task `m3uimport` does that); no `*.md`.
