# Task convert: one import converter in place of the Ogg-only one (FMT09, step 1)

Slug `audiofmt-convert`, branch `audiofmt/convert` made from `team/audiofmt`. Read `Scripts/agents/briefs/2026-10-18/audiofmt/common.md` first.

This is a refactor: renames, two new predicates, and the reader guards moved onto them. **No behavior changes** for any format: Ogg is still the only format converted when you finish; task `formats` adds the others on top of your work. The error messages' wording does not change either (task `formats` changes it).

## What to change

1. `git mv TextMouth/Services/OggAudioConverter.swift TextMouth/Services/ImportAudioConverter.swift`, and rename the type `OggAudioConverter` to `ImportAudioConverter` everywhere. Rewrite the type's doc comment (lines 4-25) to describe one converter for every audio format the import converts, Ogg first, keeping the October 14 story and the bit-rate paragraph as they are.
2. In the type:
   - Rename `fileExtensions` (line 29) to `oggExtensions`.
   - Add `static let convertedExtensions: Set<String> = oggExtensions`, documented as the extensions, in lowercase, of every audio format the import converts (task `formats` adds the rest).
   - Add `static let ownWorkingExtensions: Set<String> = ["caf"]`, documented: TextMouth writes CAF files itself from its own samples with Apple's encoder, and reads them back in the app: a recording's take (`BookOrigin.originalTakeFileName`), the audio editor's takes and passes (`AudioEditPackage`, `AudioFilterProcessor`). An imported CAF is converted at import like every other format in `convertedExtensions`, so no CAF from outside ever reaches a reader.
   - Add `static func isConvertedAtImport(_ url: URL) -> Bool`: its extension, in any case, is in `convertedExtensions`.
   - Add `static func isNeverDecodedInApp(_ url: URL) -> Bool`: `isConvertedAtImport(url)` and its extension is not in `ownWorkingExtensions`. Documented as the question every reader guard asks.
   - Add `static func filesToConvert(in folder: URL) -> [URL]`: the tracks `isConvertedAtImport` accepts. Keep `oggFiles(in:)` (lines 119-125: the library's conversion of Ogg books uses it), and make both one-line calls of a private helper that takes the predicate (no second copy of the listing).
3. Temporary names:
   - `temporarySuffix` (line 50) becomes `".audio-conversion.m4a"`.
   - Add `static let legacyTemporarySuffix = ".ogg-conversion.m4a"`: the suffix before October 18, still recognized so a leftover from an earlier version is removed.
   - Add `static func isTemporaryName(_ name: String) -> Bool`: hidden (starts with "."), ends with either suffix, with something before the suffix.
   - `removeLeftovers(in:)` (lines 526-532) uses it, and so does `OrphanedConversionSweep.isTemporaryOutputName` (`OrphanedConversionSweep.swift:45-52`, which keeps its signature and passes the last path component). Update that file's doc comment (lines 18-32) to speak of the audio the import converts.
4. The log tag `OGG_CONVERSION_KILLED` (line 346 and the doc of `convert`, line 282) becomes `AUDIO_CONVERSION_KILLED`. If a test pins the old tag, update that pin: that is the intended change; say so in your report.
5. `git mv TextMouth/Services/FileImportService+Ogg.swift TextMouth/Services/FileImportService+AudioConversion.swift`:
   - `convertOggAudio(of:in:run:)` becomes `convertImportedAudio(of:in:run:)`; a folder uses `filesToConvert(in:)` and a single file `isConvertedAtImport`.
   - The private `convertOgg` becomes `convertTracks`.
   - Rewrite the doc comments in general terms, keeping their list of the imports that pass through here. The MARK becomes `Audio Converted at Import (B06, FMT09)`.
6. `ImportStep.convertingOggAudio(done:of:)` (`TextMouth/Services/ImportFailure.swift:22-26`, and `:51`) becomes `.convertingImportedAudio(done:of:)`, documented as converting the audio the import converts. Its words stay "Converting its audio". Update `TextMouth/Models/ImportProgressWording.swift:99-107` to match (the pattern, and "converted from Ogg to AAC" becomes "converted at import").
7. `TextMouth/Services/FileImportService.swift:1193` (doc) and `:1206` (the call).
8. **The reader guards.** Replace `OggAudioConverter.isOgg(url)` with `ImportAudioConverter.isNeverDecodedInApp(url)` (or `$0.url` as there) at:
   - `TextMouth/Parsers/AudioMediaProbe.swift:95`
   - `TextMouth/Services/TranscriptionEngine.swift:172`
   - `TextMouth/Services/AudioPlaybackService.swift:889`
   - `TextMouth/Services/TranscriptionService.swift:194`
   - `TextMouth/Services/AudioEditing/AudioEditComposition.swift:45`
   - `TextMouth/Services/AudioEditing/AudioEditorPlayer.swift:93`

   Each comment above them becomes short and general, such as: "Never decode a format the import converts (B09, FMT09): Apple's Vorbis decoder once spun forever. Such audio is converted in a child process first."

   **One exception,** `AudioPlaybackService.metadataAsset(for:)` (lines 1574-1584): use `ImportAudioConverter.isConvertedAtImport(url)`. It is the reader an import runs on a source file before converting it, for its tags, so it refuses CAF too. Update its doc comment minimally. Touch nothing else in `AudioPlaybackService.swift`: task `chpl` changes `extractChapters` just below.
9. `TextMouth/ViewModels/LibraryViewModel+OggConversion.swift` and `ReaderViewModel+OggConversion.swift`: rename the type only. They stay about Ogg alone (`isOgg`, `oggFiles(in:)`), since Ogg books were the only ones in the library before conversion at import began.
10. **`Scripts/test/ogg-lint.py`:**
    - `ADVICE` (line 43) becomes: make sure this path refuses every format the import converts (`ImportAudioConverter.isNeverDecodedInApp`, or `isConvertedAtImport` where an import's source arrives) before Apple's decoder sees it (Ogg once locked up the Mac), then add `// lint-ok: <how it refuses>`.
    - Add an ERROR rule `ogg-only-guard`, pattern `(?<!\w)(?<!func )isOgg\s*\(`, with the message: isOgg refuses Ogg alone, while a reader must refuse every format the import converts: guard with ImportAudioConverter.isNeverDecodedInApp (or isConvertedAtImport for an import's source), or, on a path about Ogg alone (the library's conversion of Ogg books), add `// lint-ok: <why Ogg alone>`.
    - Selftest cases: it hits `guard !ImportAudioConverter.isOgg(url) else { return }` and does not hit `static func isOgg(_ url: URL) -> Bool {`.
    - Update the module docstring.
    - Your own edited `isOgg(` lines in the two `+OggConversion.swift` files get `// lint-ok: the library converts Ogg books alone, the one format converted at import before October 18`.
    - Run `python3 Scripts/test/ogg-lint.py --selftest`.
11. **Tests:**
    - Update every reference in `OggAudioConverterTests`, `OggAfconvertTests`, `OggImportConversionTests`, `OggLibraryConversionTests`, `OggNamingTests`, `OggBookCommitTests`, and `OrphanedConversionSweepTests`. These are renames only: the test classes and files keep their names, and no expected value changes but the log tag and the temporary suffix where they are pinned.
    - Add, in `OggAudioConverterTests`:
      - `isConvertedAtImport` and `isNeverDecodedInApp` for .ogg, .OPUS, .mp3, and .caf (a .caf is not converted yet, and is never refused as the app's own);
      - `filesToConvert(in:)` and `oggFiles(in:)` on a folder of .ogg, .mp3, and a hidden file;
      - `removeLeftovers(in:)` removing a hidden file of each suffix and keeping a visible one;
      - `isTemporaryName` on each suffix, on a bare suffix, and on a visible name.
    - In `OrphanedConversionSweepTests`, test that the sweep accepts an output with the legacy suffix.
12. `/opt/homebrew/bin/xcodegen generate` (two files were renamed); commit the project with the change.

## Commits
1. The rename and the predicates, with the tests (items 1-9, 11, 12).
2. The lint rule (item 10).

## Test classes (one run)
`OggAudioConverterTests OggAfconvertTests OggImportConversionTests OggLibraryConversionTests OggNamingTests OggBookCommitTests OggHeaderReaderTests OrphanedConversionSweepTests WatchedProcessSafetyTests AudioMediaImportTests AudioDirectoryImportTests ImportAndShortcutPolicyTests UncheckedConcurrencyPolicyTests LogContentPolicyTests`, plus every class of `grep -l "ImportProgressWording\|convertingOggAudio\|TranscriptionEngine\|AudioEditComposition\|AudioEditorPlayer" TextMouthProductionTests/*.swift`.

## Do not touch
`OggHeaderReader.swift`, `WatchedProcess.swift` (task `afinfo` works there), `extractChapters` (task `chpl`), `Book.swift`, `Info.plist`, the `Failure` messages' wording, and any `*.md`.

## Completion check
This must print nothing:

    grep -rn "OggAudioConverter\|convertOggAudio\|convertingOggAudio\|FileImportService+Ogg\|OGG_CONVERSION_KILLED" TextMouth TextMouthProductionTests TextMouthTests Scripts/test project.yml
