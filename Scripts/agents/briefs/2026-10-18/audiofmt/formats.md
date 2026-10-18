# Task formats: the audio formats macOS already decodes, converted at import (FMT09, step 3)

Slug `audiofmt-formats`, branch `audiofmt/formats` made from `team/audiofmt`. Read `Scripts/agents/briefs/2026-10-18/audiofmt/common.md` first.

The user's wish: "convert a bunch more audio formats to a standardized format like how we convert the text files to markdown". Two earlier tasks are already on `team/audiofmt`:
- `convert` made `OggAudioConverter` into `ImportAudioConverter` (`TextMouth/Services/ImportAudioConverter.swift`), with `convertedExtensions`, `isConvertedAtImport`, `isNeverDecodedInApp`, and `filesToConvert(in:)`. Every import of audio passes through `FileImportService.convertImportedAudio(of:in:run:)` (`FileImportService+AudioConversion.swift`).
- `afinfo` added `AudioFileInfo.read(_:using:)` (`TextMouth/Services/AudioFileInfo.swift`): codec, channels, rate, bit depth, and length, from `/usr/bin/afinfo` in a watched child process.

This task makes the import convert the new formats: lossy ones to AAC, lossless ones (PCM, ALAC, FLAC) to Apple Lossless, both in .m4a.

## Decisions already made (do not reopen)
- **Every file with one of the new extensions is converted**, PCM included. The reader guards decide by extension, and a CAF, AIFC, AU, or Wave64 file holds coded audio as often as PCM. So none of these extensions may reach Apple's readers in the app, and PCM goes to Apple Lossless, which loses nothing.
- **The extensions TextMouth already plays stay as they are**, whatever they hold: mp3, m4a, m4b, wav (RF64, BWF, and the ADPCM, μ-law, and A-law WAVs included), aiff, aif, flac, alac, aac, mp4, m4v, mov.
- **CAF is in `ownWorkingExtensions`**: TextMouth reads its own CAF takes in the app, so `isNeverDecodedInApp` lets .caf through, while `isConvertedAtImport` converts every imported .caf.

## What to change
1. **The new extensions.** In `ImportAudioConverter`, add `static let coreAudioExtensions: Set<String> = ["aifc", "caf", "au", "snd", "w64", "ac3", "ec3", "eac3", "mp1", "mp2", "mpa", "amr", "awb", "3gp", "3g2", "3ga"]`. Document it: the formats macOS decodes that TextMouth converts at import (FMT09), the coded ones so that Apple's rarer decoders stay out of the player, and the PCM containers because of the extension rule above. Then `convertedExtensions = oggExtensions.union(coreAudioExtensions)`.
2. **`BookFormat.audio`** (`TextMouth/Models/Book.swift`, the `.audio` case's list, lines 61-62, and its doc comment, lines 41-51): append `+ ImportAudioConverter.coreAudioExtensions.sorted()` to the list, on a line of its own so team textfmt's lines are never touched, rather than spelling the extensions a second time. To the doc comment, add a paragraph saying that these are converted at import (`ImportAudioConverter`). Keep the Ogg paragraph.
3. **The Open panel.**
   - In `FileImportService.supportedTypes` (`FileImportService.swift`, the "Audio formats" block, lines 2071-2082), append `UTType(filenameExtension:)` of each of `coreAudioExtensions`, sorted, compactMapped, with a comment.
   - In `TextMouth/Resources/Info.plist`, add one `CFBundleDocumentTypes` entry after "Ogg Audio": `CFBundleTypeName` "Audio Converted at Import", `CFBundleTypeExtensions` the 16 extensions, `LSItemContentTypes` the system types that exist for them, role Viewer, rank Alternate, as the neighbours are. Find the types with `swift -e 'import UniformTypeIdentifiers; for e in ["aifc","caf","au","snd","w64","ac3","ec3","eac3","mp1","mp2","mpa","amr","awb","3gp","3g2","3ga"] { print(e, UTType(filenameExtension: e)?.identifier ?? "-") }'`, and list only identifiers that do not start with `dyn.`.
4. **What the converter knows of a source.** `SourceInfo` gains:
   - `formatID: String`: "vorbis" or "opus" for Ogg (from `OggHeaderReader`'s codec), afinfo's format otherwise;
   - `bitsPerSample: Int?`;
   - `isLossless: Bool`.

   `inspect(_:)` becomes `async throws` (it throws only `CancellationError`). Ogg is read by `OggHeaderReader` as now; any other converted extension by `AudioFileInfo.read`. Update its two callers, `convert` and `estimatedSize(of:)` (which treats a cancellation as an unreadable file, as before).
5. **The plan.**
   ```swift
   /// What the import does with one audio file.
   enum Plan: Equatable, Sendable { case leaveAsItIs, convertToAAC, convertToAppleLossless }
   static func plan(for source: URL, info: SourceInfo) -> Plan
   ```
   - `.leaveAsItIs` when `isConvertedAtImport(source)` is false;
   - `.convertToAppleLossless` when `info.isLossless`;
   - otherwise `.convertToAAC`.
6. **The target.**
   - `Target` gains `var appleLosslessBitDepth: Int? = nil`. A default value keeps the memberwise initializer that existing tests call; nil means AAC.
   - For Apple Lossless, `target(for:bytes:)` gives:
     - the source's channels, eight at most;
     - its own sample rate;
     - no bit rate;
     - and a bit depth from `bitsPerSample`: up to 16 gives 16, up to 20 gives 20, up to 24 gives 24, above that 32, and nil (float or unknown) gives 24.
   - `afconvertArguments` writes Apple Lossless as `["-f", "m4af", "-d", "alac/<flag>"]`, where the flag is 1, 2, 3, or 4 for 16, 20, 24, or 32 bits, then `-c 8` only for more than eight channels, then the input and output paths.

     Verified in a shell: without the flag, afconvert writes 32-bit ALAC from a 16-bit FLAC, five times larger (216 KB against 40 KB).
   - AAC stays exactly as it is.
7. **`estimatedSize(of:)`:** an Apple Lossless target is estimated at the source's size plus 64 KB.
8. **The words of `Failure`** (lines 96-109 before the rename) become format-neutral. These are the exact strings:
   - `unreadable`: "The audio file \(fileName) could not be read for converting."
   - `checkFailed`: "The audio converted from \(fileName) failed its check: \(reason)."
   - `cannotName`: "The audio converted from \(fileName) could not be given its name."
   - `killed`: "Converting \(fileName) was stopped because \(reason)."
   - `processFailed`: "Converting \(fileName) failed (the converter ended with code \(status))."

   These existing tests pin the old words, and you update them to the new ones (that is the intended change; name each in your report): `OggAudioConverterTests.swift:204`, `OggLibraryConversionTests.swift:104`, `OggImportConversionTests.swift:50`, and `OggBookCommitTests.swift:23` and `:40`. The library's own Ogg sentences ("converted from Ogg to AAC") stay: they are about Ogg books.
9. **The type's doc comment** says which formats are converted to what, and that a format a Mac cannot convert is refused by name. The app's oldest macOS is 14.0 (`project.yml`). afinfo or afconvert then fails, and the import stops at "Converting its audio" with the file's name and nothing left behind; no other check is needed.

## Tests: a new file `TextMouthProductionTests/ImportAudioFormatsTests.swift`
- **Each new-format sample,** copied into the test's temporary folder, then `convert`:
  - the samples are `ac3/tones.ac3`, `eac3/tones.ec3`, `amr/tones.amr`, `3gp/tones-aac.3gp`, `3gp/tones-amr.3gp`, `mp2/tones.mp2`, `au/tones.au`, `aifc/tones-ima4.aifc`, `aifc/tones-ulaw.aifc`, `caf/tones-pcm.caf`, `caf/tones-alac.caf`, `caf/tones-opus.caf`, and `w64/tones.w64`;
  - the plan is as expected (Apple Lossless for the PCM CAF, the ALAC CAF, the AU, and the Wave64; AAC for the rest);
  - the converted .m4a holds "aac " or "alac", by `AudioFileInfo.read`;
  - its length matches the source's within the tolerance;
  - `AudioMediaProbe` passes it;
  - for Apple Lossless, its bit depth is the source's (16).

  Print each conversion's `secondsTaken` in one line per sample, so your report can give the times.
- **A single-file import** of `ac3/tones.ac3` (through `FileImportService.importFileWithReport`, as `OggImportConversionTests` imports Ogg, in its own library folder):
  - the book's file is `tones.m4a`;
  - no `.ac3` is left in the package;
  - the original is unchanged.
- **A folder import** of `01.ac3`, `02.mp3`, and `03.caf` gives the tracks `01.m4a`, `02.mp3`, and `03.m4a`, in that order. With a manifest naming the three, the manifest names the renamed tracks.
- **An `.amr` of random bytes** fails at "Converting its audio" with the new `unreadable` words, and nothing is left in the library folder.
- **The guards:**
  - `isConvertedAtImport` and `isNeverDecodedInApp` for each new extension (both true, but `isNeverDecodedInApp` false for .caf);
  - `AudioPlaybackService.metadataAsset(for:)` is nil for .ac3 and .caf;
  - `BookFormat.detect` gives `.audio` for each new extension (add this to `BookFormatTests`).
- `/opt/homebrew/bin/xcodegen generate`, and commit the project with the tests.

## Commits
1. The plan, the target, and the source info (items 4-9), with their unit tests.
2. The new extensions (items 1-3), with the sample and import tests.

## Test classes (one run)
`ImportAudioFormatsTests AudioFileInfoTests OggAudioConverterTests OggAfconvertTests OggImportConversionTests OggLibraryConversionTests OggNamingTests OggBookCommitTests OggHeaderReaderTests AudioMediaImportTests AudioDirectoryImportTests AudioManifestTests AudioManifestCheckTests ArchiveImportBoundsTests BookFormatTests ImportAndShortcutPolicyTests IntegrationImportTests UncheckedConcurrencyPolicyTests LogContentPolicyTests`. If `ImportAndShortcutPolicyTests` pins the list of supported extensions or types, its expectation changes with item 2 or 3: update it and say so.

## Do not touch
`OggHeaderReader.swift` (task `oggflac` comes next), `WatchedProcess.swift`, `AudioFileInfo.swift` (use it as it is), the library's Ogg conversion (`LibraryViewModel+OggConversion.swift`), team textfmt's lines in `Book.swift`, `FileImportService.swift`, and `Info.plist`, and any `*.md`.

## Completion check
This must print one line, `TextMouth/Services/ImportAudioConverter.swift`, the only Swift file where the new extensions are spelled out:

    grep -rln --include='*.swift' '"ac3"' TextMouth
