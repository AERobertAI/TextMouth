# Review fix small: the lint, Nero titles, and tests that cannot fail or that flake (review items 10, 13, 14)

Slug `audiofmt-small`, branch `audiofmt/small` made from `team/audiofmt`. Read `../common.md`, then `common.md` in this folder, then this brief.

## Item 10 (low): ogg-lint misses forms
`Scripts/test/ogg-lint.py` (its rules at about lines 53-71) misses:
- **`isOgg` named without a call**, as in `contains(where: ImportAudioConverter.isOgg)` (`TextMouth/ViewModels/ReaderViewModel+OggConversion.swift` line 34);
- **`AVAsset(url:)`**, which makes an AVURLAsset;
- **a reader named by `.init`**: `map(AVURLAsset.init(url:))`, and so `AVAudioFile.init(forReading:)`, `AVPlayer.init(url:)`, and the rest of the rules' types.
Add the rules or widen the existing ones, each with selftest cases that must hit and that must not (a `func isOgg(` declaration, a string, a comment). `python3 Scripts/test/ogg-lint.py --selftest` must pass. `--all` then lists every existing line the new rules find: each must already carry a `lint-ok` with its reason. If one does not, name it in your report and to your lead; add an excuse yourself only where the path really refuses every converted format, and say how.

## Item 13 (low): Nero chapter titles
`NeroChapterReader.decodeTitle` (`TextMouth/Parsers/NeroChapterReader.swift` about lines 137-145): stop a title at its first NUL byte, as FFmpeg does, and read bytes that are not valid UTF-8 through the shared Windows-1252 rule, `TextFileDecoder.windows1252Text(_:)` (`TextMouth/Parsers/TextFileDecoder.swift` about line 400), not as ISO Latin 1. Tests: a title "A\0B" reads "A"; the bytes 0x93 0x48 0x69 0x94 read "“Hi”"; valid UTF-8 reads as before.

## Item 14 (low): tests that cannot fail, or that flake
- **`NeroChapterReaderTests.swift` about line 380.** The `.dat` half of `testFallbackFollowsTheExtension` cannot fail: a `.dat` file gets no chapters with the fallback or without it. Make it a test that fails if the fallback applied to an extension outside the MPEG-4 list: test the function that decides by the extension directly, or give bytes that would yield chapters under the fallback an extension AVFoundation still opens but the list excludes. Prove it in your failing run by making that decision wrong once.
- **`OggFlacConversionTests.swift` lines 88 and 127** lack `try OggTestFixtures.skipUnlessOggDecodes()` as their first line, so they fail on macOS 14 to 15.3. Add it (this Mac cannot show that failure; say so).
- **`ContinueToNextBookTests.swift` line 408** (`testFinishingABookPassesOverFinishedBooksToTheNextUnfinishedOne`) failed once in a full suite on a busy Mac: `world.requests.hasRequest(for: next.id)` was read before the request had arrived. Wait for it with the test's own `eventually { }`, as line 401 waits for `asked()`, and keep every assertion.

## Commits
One per item; item 14 may take one commit for each test file.

## Test classes (one run each, in your turn)
`NeroChapterReaderTests`, `OggFlacConversionTests`, `ContinueToNextBookTests`; and `python3 Scripts/test/ogg-lint.py --selftest` with `make lint-ogg LINT_BASE=main`.

## Do not touch
Any app file but `NeroChapterReader.swift`, and any `*.md`.
