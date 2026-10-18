# Task chpl: Nero chapter lists in M4B and M4A files (FMT05)

Slug `audiofmt-chpl`, branch `audiofmt/chpl` made from `team/audiofmt`. Read `Scripts/agents/briefs/2026-10-18/audiofmt/common.md` first.

AVFoundation reads an MPEG-4 file's QuickTime chapter track, but not a Nero `chpl` atom alone. Some audiobook tools write only `chpl`, so such a book shows no headings. When AVFoundation finds no chapters in an MPEG-4 file, read the atom by hand. This is about formats TextMouth plays today (M4B, M4A, MP4, M4V, MOV), so AVFoundation may open them as it does now. The new reader itself reads bytes only.

## 1. A new file `TextMouth/Parsers/NeroChapterReader.swift`
```swift
enum NeroChapterReader {
    struct Chapter: Equatable, Sendable { let title: String; let start: TimeInterval }
    static func read(at url: URL) -> [Chapter]        // [] when there is no chpl or the file is malformed
    static func parse(chpl payload: [UInt8]) -> [Chapter]
}
```
No MP4 box reader exists in the code yet (searched). Write a small one on a `FileHandle` that seeks and reads box headers only, never the whole file:
- **The walk.** Top-level boxes until `moov`; inside `moov` until `udta`; inside `udta` until `chpl`.
- **A box header** is a 32-bit big-endian size and a four-byte type.
  - A size of 1 means a 64-bit size follows the type.
  - A size of 0 means the box runs to the end of its parent (or the file).
  - A size smaller than its own header, or a box that runs past its parent's end, stops the walk (no chapters).
- **Caps.** At most 10,000 boxes are looked at on each level. A `chpl` payload over 1 MiB is refused.
- **The payload** (FFmpeg's `mov_read_chpl` in libavformat/mov.c reads it so):
  - a version byte and three flag bytes;
  - when the version is not 0, four more bytes to skip;
  - a one-byte count;
  - then, for each chapter, its start as a 64-bit big-endian count of 100-nanosecond units, a one-byte title length, and that many title bytes.

  A payload that ends partway keeps the chapters read whole before it.
- **Titles** are UTF-8; bytes that are not valid UTF-8 are read as ISO Latin 1. They are trimmed of white space and NUL characters; an empty title is left empty here (see item 2).
- Every read is bounds-checked, as `OggHeaderReader` is: no force unwrap, no unguarded subscript.

## 2. Using it: `AudioPlaybackService.extractChapters(from:)`
The function is at `TextMouth/Services/AudioPlaybackService.swift`, about lines 1586-1615. When AVFoundation's chapter groups are empty, and the file's extension (any case) is m4a, m4b, mp4, m4v, or mov, it reads `NeroChapterReader.read(at:)` and makes the book's chapters from it:
- sorted by start, stably;
- those at or past the file's length (`asset.load(.duration)`) dropped, and so is a repeat of a start already taken;
- the first chapter taken to begin at 0, so the chapters cover the whole file;
- each lasting until the next one's start, the last until the file's end;
- an empty title becomes "Chapter N", N being its place from 1.

Return them in the function's existing tuple shape, or [] when none is left. Do not touch `metadataAsset(for:)` or its doc comment just above (task `convert` edits them), nor anything else in the file.

## 3. Tests: a new file `TextMouthProductionTests/NeroChapterReaderTests.swift`
- **Synthetic files** built by a small helper that writes boxes:
  - version 0 and version 1 payloads;
  - a 64-bit box size;
  - a box of size 0 at the end;
  - `moov` after a large `mdat` (the helper writes the size, not the bytes, of a large `mdat`, using a sparse file or a 64-bit size that points to the end);
  - a truncated payload;
  - a size smaller than its header;
  - a box running past its parent;
  - a count of 255 with only 2 chapters present;
  - a title of Latin-1 bytes (`0xE9`, as in "Café");
  - an empty title;
  - starts out of order, and a start past the end.
- **The sample.** Copy `TestData/format-samples/m4b-chapters/three-tones.m4b` (it holds both a chapter track and `chpl`) into the test's folder.
  - `NeroChapterReader.read` gives its three titles and starts: read them once with a short Python script over the bytes, and pin them.
  - `extractChapters` on the unchanged copy gives AVFoundation's chapters.
  - In a second copy, rename the audio track's chapter reference: the four bytes `chap` inside `tref`, replaced with `xxxx`, found by searching for `tref` and then `chap` within that box.
  - `extractChapters` on that copy now gives the Nero chapters: the same titles, starts within 0.01 seconds, and durations that add up to the file's length.
- `/opt/homebrew/bin/xcodegen generate`, and commit the project with the tests.

## Commits
1. `NeroChapterReader` and its synthetic tests.
2. The fallback in `extractChapters`, with the sample tests.

## Test classes (one run)
`NeroChapterReaderTests AudioMediaImportTests AudioDirectoryImportTests`, plus every class of `grep -l "extractChapters\|m4b-chapters" TextMouthProductionTests/*.swift`.

## Do not touch
Any file but the two new ones, `AudioPlaybackService.swift`'s `extractChapters`, and the project; no `*.md`.
