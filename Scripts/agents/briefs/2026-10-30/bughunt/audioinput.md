# bughunt-audioinput: audio files and their headers must not crash an import, and misnamed Ogg must never reach AVFoundation

Worker slug `bughunt-audioinput`, branch `bughunt/audioinput` (from `team/bughunt`). Read `README.md` beside this file first. Four small fixes, one commit each, each with its test.

## 1. An absurd duration from a file's header traps or builds a gigantic placeholder
- `TextMouth/Parsers/AudioBookParser.swift:8-10`: `placeholderLength(for:)` is `max(1, Int(duration * ReaderViewModel.audioCharsPerSecond))`. `Int(_:)` traps from about 9.2e17 seconds on, and on NaN or infinity; below that, an absurd duration builds a String of spaces gigabytes long (`:173-174`, `:186-188`, `:284`, `:368`).
- The duration comes from `TextMouth/Parsers/AudioMediaProbe.swift:114-127`, which checks only `seconds.isFinite, seconds > 0` on the asset's duration (an `mvhd` header can state 1e18 seconds while the audio track is short).
- `TextMouth/Services/AudioPlaybackService.swift:1740` (`durationString`) computes `Int(seconds)` of the same duration.

Fix:
1. `AudioMediaProbe`: refuse (`.failure(.noAudio)`, as for a non-finite duration) an asset duration longer than `OggHeaderReader.maximumDuration` (one year, the ceiling `AudioFileInfo.isPlausible` already applies to converted formats). Use that constant; do not write a second one.
2. `placeholderLength(for:)`: a non-finite or non-positive duration gives 1; otherwise compute in `Double` and clamp to `BookContentIndex.maximumCharacterCount` (the index refuses more on every reopen anyway) before converting, so no value traps.
3. `durationString`: a non-finite or negative value shows as `0:00`; clamp before converting, so no value traps.

Tests, in `AudioMediaValidationTests`: write a 2-second WAV in the test's temporary folder (`AudioTestFixtures.writeSilence`, grep for it); `AudioBookParser.parse(url:prober:)` with a stand-in prober returning `.success(1e18)` (grep the class for how it builds stand-in probers) neither traps nor builds more than `BookContentIndex.maximumCharacterCount` characters; `placeholderLength(for:)` of `.infinity`, `.nan`, `-5`, `1e18` gives 1, 1, 1, and `BookContentIndex.maximumCharacterCount`. Never run a test that would trap before your fix is in (README).

## 2. The downmix arithmetic traps on a lossless source with more than two channels and a huge sample rate
- `TextMouth/Services/ImportAudioConverter.swift:568` (`downmixBytesNeeded`: `Int64((duration * target.sampleRate).rounded())`) and `:651` (`downmixArguments`: `Int(target.sampleRate)`). A lossless `Target` keeps the source's rate as afinfo printed it (`:510-516`); `AudioFileInfo.swift:194` checks only `sampleRate > 0`, which `.infinity` and 1e19 pass. `expectedOutputBytes` (`:599-600`) already clamps duration and rate with `maximumCappedSeconds` and `maximumCappedSampleRate` "so a lying header cannot overflow the arithmetic"; these two do not.

Fix: one private helper each for the clamped seconds and the clamped rate, used by both `expectedOutputBytes` and `downmixBytesNeeded` (DRY); and `convert` refuses a source whose sample rate is not finite or is above `maximumCappedSampleRate` with `Failure.unreadable` (the failure an unreadable header already gets), before `target` is computed, so `downmixArguments` never sees such a rate.

Tests, in `AudioChannelDownmixTests`: `downmixBytesNeeded(duration: 0.99, target: Target(channels: 2, sampleRate: 1e19, bitRate: nil, appleLosslessBitDepth: 16))` returns the capped value without trapping; `convert` with the stand-in afinfo `Tool` the class already uses (grep it) printing a sample rate of 1e19 and 3 channels throws `Failure.unreadable`.

## 3. Hashing a source whose read fails raises an Objective-C exception, which ends TextMouth
- `TextMouth/Services/FileImportService.swift:2156-2176`, `md5Hash(of:)`: `handle.readData(ofLength:)` raises `NSFileHandleOperationException` on a read error (a USB disk unplugged or a network share dropped mid-import, an iCloud download failing mid-read), which Swift cannot catch. Every import, ZIP batch, folder, and text-cache fingerprint hashes through it.

Fix: read with `try handle.read(upToCount: bufferSize)` (nil or empty at the end) and close with `try? handle.close()`, so a failed read throws a Swift error, which the import already reports ("Reading the file failed"). To test the failure, give `md5Hash` an internal overload taking the chunk reader (`(FileHandle) throws -> Data?`), which the public one calls with the real read; keep `md5Hash(of:)`'s signature and every caller unchanged.

Tests, in the class that already tests `md5Hash` (grep `TextMouthProductionTests` for `md5Hash(of:`; otherwise `StagedImportTests`): a 3 MB file in the temporary folder hashes to the same digest as before (compare with `Insecure.MD5` over the whole data); and with a chunk reader that throws on its second call, `md5Hash` throws that error.

## 4. An Ogg file named .mp3 or .m4a is opened by AVFoundation during import
- `TextMouth/Services/AudioPlaybackService.swift:1626` (`metadataAssetOptions(for:)`) refuses only by extension (`ImportAudioConverter.isConvertedAtImport`), so `FileImportService.audioTags(of:)` (`FileImportService.swift:252-254`, called from `ImportedFileMetadata.read` at `:236`, before the import converts the file at `:1511`) opens an Ogg Vorbis file named `episode.mp3` with `AVURLAsset` in TextMouth's own process. Apple's Ogg code in the app is what hung the Mac on October 14; the rule is that no Apple audio API opens Ogg in the app.

Fix: `metadataAssetOptions(for:)` also returns nil when `AudioContentSniffer.isOgg(at:)` is true, after the extension check (keep the extension check first: it costs nothing). Keep the reason the doc comment gives for using `isConvertedAtImport` rather than `isNeverDecodedInApp` (a CAF source must be refused too), and say the content check closes the misnamed-Ogg case. Update the `// lint-ok:` comment on `metadataAsset(for:)` to say it refuses by extension and by content. A file refused this way gives empty tags, so the import names the book after its file, as for any Ogg file whose tags are not read.

Tests, in `ImportAudioFormatsTests`, beside `testNoMetadataAssetIsMadeForAConvertedFormat`: write `OggS` and a few more bytes as `track.mp3` and as `track.m4a` in the temporary folder; `AudioPlaybackService.metadataAsset(for:)` is nil for both; `ImportedFileMetadata.read(from:format: .audio, ...)` gives the file's name as the title (grep the class for how it calls it). These files are never played or decoded.

## Run
`AudioMediaValidationTests AudioChannelDownmixTests ImportAudioFormatsTests StagedImportTests` plus the class that tests `md5Hash`, then `make lint-ogg LINT_BASE=team/bughunt` and `make lint-tests LINT_BASE=team/bughunt`.

## Do not touch
Any other reader of audio, the converter's targets for valid files, or any wording a listener hears (none changes).
