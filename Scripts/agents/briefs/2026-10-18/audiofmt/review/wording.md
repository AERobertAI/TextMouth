# Review fix wording: short lists, a title that is not an error's, and a truer caption (review items 6, 11, 15)

Slug `audiofmt-wording`, branch `audiofmt/wording` made from `team/audiofmt`. Read `../common.md`, then `common.md` in this folder, then this brief.

## Item 6 (medium): skipped entries are named in full, without limit
`PlaylistImportWording.skippedList` (`TextMouth/Models/PlaylistImportWording.swift` lines 63-71) names each entry whole. One 4 MiB line yields a 4-million-character alert for VoiceOver and the braille display.
- **Each named entry** is at most 60 characters. A longer one keeps its start and its file name (what follows its last `/` or `\`), joined by "…": `Music/Audiobooks/A Very…/03 Intro.mp3`. A file name of more than 40 characters is itself shortened in its middle: its first 20 and its last 19 characters around "…". Make it a function (`shortened(_:)`) and pin examples, among them one of exactly 60 characters (kept whole) and one of 61.
- **The list** names entries in order while the whole list stays within 600 characters, and at most `namedLimit` (10) of them; "and N more" counts the rest, as today.
- **Tests.** An entry of 4 MiB gives a notice and a refusal (`noTrack`) each shorter than 1,000 characters, ending as today; a short list reads exactly as before (the existing wording tests pass unchanged).

## Item 11 (low): the alert's title
A playlist that imported shows its skipped-entries notice under the title "Error" (`TextMouth/ViewModels/LibraryViewModel+Import.swift` about lines 607-635, `presentImportMessage` at about 717; `TextMouth/Views/ContentView.swift` about line 153, `errorTitle ?? "Error"`). textfmt's kept-RTFD notice joins it there, and so does the warning of chapters left out.
- **Every alert that follows an import that added its book is titled "Book Imported"**: in `completeSingleImportedBook`, and in `completePackageImport` (about line 352). Add the title to `ImportProgressWording` beside `nothingImportedTitle` (`grep -rn "nothingImportedTitle" TextMouth`). A failure keeps "Error": it added no book.
- **Tests.** The library's alert after a playlist import with a skipped entry, after an RTFD import whose original was kept (`grep -ln "rtfdOriginalKeptNotice" TextMouthProductionTests/*.swift` for its tests), and after a book with chapters left out, is titled "Book Imported" (`errorTitle`), with its message as before (`errorMessage`).

## Item 15 (low): the caption's words
`ConvertedOriginalWording.keepingCaption` (`TextMouth/Models/ConvertedOriginalWording.swift` lines 15-18) becomes, exactly:
"When TextMouth converts audio at import, it keeps the original file too. An original takes about as much disk space as its converted file, or about twice as much when it is uncompressed. Export offers it as the Original file. A feed episode's original is not kept: it can be downloaded again."
Update the test that pins it (`ConvertedOriginalTests.swift` about line 78): that is the intended change.

## Commits
One per item.

## Test classes (one run each, in your turn)
`PlaylistImportTests`, `M3UPlaylistTests`, `ConvertedOriginalTests`, the library's import alert classes (`grep -ln "completeSingleImportedBook\|errorTitle" TextMouthProductionTests/*.swift`), and the RTFD notice's class.

## Do not touch
`M3UPlaylist.swift` (task `m3usafety`'s), `M3UPlaylistTests.swift` (put your tests in `PlaylistImportTests` and `ConvertedOriginalTests`), and any `*.md`.
