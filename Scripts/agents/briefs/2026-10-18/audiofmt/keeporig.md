# Task keeporig: a setting that keeps the original of converted audio (FMT14, step 2)

Slug `audiofmt-keeporig`, branch `audiofmt/keeporig` made from `team/audiofmt`. Read `Scripts/agents/briefs/2026-10-18/audiofmt/common.md` first.

An import converts Ogg, AC-3, CAF and the rest to AAC or Apple Lossless (`ImportAudioConverter`), then deletes the staged source: `ImportAudioConverter.removeSources(of:)`, called from `FileImportService.convertImportedAudio(of:in:run:)` in `FileImportService+AudioConversion.swift`. The user asked (question 10): "Yes but keep originals as off, I don't think most people would need it especially sense the file loaded into the app would still probably exist unless deleted". So this task adds a setting, off by default, that keeps the staged source in the book's package instead. Only the staged copy is ever moved: the file, folder, or archive imported from is never touched.

## Decisions already made
- **Off by default.** Only imports made while it is on keep anything; nothing already in the library changes.
- **Feed episodes never keep an original:** a download can be fetched again. The lead puts this to the user as a question.
- **Where it is kept:** a hidden folder at the package's top, `.convertedOriginals`, holding each source under its path from the book's folder of tracks (for a single file, its own name).
  - Hidden, so that every track scan, manifest, playlist, and player passes it by: `AudioBookParser.audioFiles(in:)` and the others use `.skipsHiddenFiles`, and `FileImportService.isPackageContentName` refuses names starting with ".".
  - A kept .ogg is never opened by anything: the October 14 rule.
- **The library's own conversion** of Ogg books already in the library (`LibraryViewModel+OggConversion.swift`) is not an import, and never keeps one.

## What to change
1. **The setting.** Follow `moveToTrashInsteadOfDeleting` through `TextMouth/Services/ConfigService.swift` (the field at about line 261, its read at about 447, and the `fileOnly` list at about 620) and add `keepsOriginalOfConvertedAudio: Bool = false` the same way. Add a `SettingsViewModel` property for it (model it on `importDeleteBehavior`, `SettingsViewModel.swift:424-440`).
2. **The control,** in `TextMouth/Views/Settings/StorageSettingsView.swift`'s "Import Behavior" section (lines 281-307), after the explanation the `switch` shows. Its exact words are:
   - the label: "Keep originals of converted audio";
   - the hint (`.accessibilityHint`): "Also keeps each audio file that an import converts, such as Ogg or AC-3, inside the book's package.";
   - a caption below, while it is on: "Audio that TextMouth converts at import keeps its original file too, which takes about as much disk space again. Export offers it as the Original file. Feed episodes are not kept: they can be downloaded again.";
   - while it is off: "Audio that TextMouth converts at import keeps only the converted file."

   Put the words in a small wording type, such as `ConvertedOriginalWording` in `TextMouth/Models/`, so a test pins them, as the view's neighbours do with theirs. The caption is `.font(.caption)`, `.foregroundColor(.secondary)`, and `.fixedSize(horizontal: false, vertical: true)`, as the neighbours are.
3. **The import.**
   - `FileImportService.publishReadableBook` (`FileImportService.swift`, about lines 1196-1215) passes `keepingOriginals: feedLink == nil && ConfigService.shared.config.keepsOriginalOfConvertedAudio` to `convertImportedAudio`. `FileImportService.swift:1751` reads `ConfigService.shared.config` the same way, off the main thread.
   - `convertImportedAudio(of:in:keepingOriginals:run:)` then calls `ImportAudioConverter.keepSources(of:from:inPackage:)` in place of `removeSources(of:)`.
4. **In `ImportAudioConverter`:**
   - `static let keptOriginalsFolderName = ".convertedOriginals"`, documented as above.
   - `static func keepSources(of conversions: [Conversion], from base: URL, inPackage package: URL) throws` moves each source to `package/.convertedOriginals/<its path from base>`, creating the folders. The base is the book's folder of tracks for a folder book, or the single file's own folder. A failure throws, and the import then fails at "Converting its audio", with everything staged removed, as any failure there is.
   - `static func keptOriginals(inPackage package: URL) -> [URL]`: the files kept, in Finder's order by their paths; none when there is no folder. Task `keepexport` will use it.
5. **Deleting a book** deletes its package, and so its kept originals; nothing to change, but a test pins it.

## Tests
New file `TextMouthProductionTests/ConvertedOriginalTests.swift`. Use the Ogg tones in `TestData/audio`, copied, and set the setting through `ConfigService` as the tests of `moveToTrashInsteadOfDeleting` do (find them with `grep -ln "moveToTrashInsteadOfDeleting" TextMouthProductionTests/*.swift`), restoring it afterwards.
- The setting is off by default, round-trips through the config file, and reads as off from a config file without the key.
- **With it on,** a single-file import of an .ogg:
  - keeps `.convertedOriginals/<name>.ogg`, byte for byte the source;
  - the book's file is the .m4a;
  - the source outside is unchanged.
- **With it on,** a folder import of `01.ogg` and `02.mp3` keeps `.convertedOriginals/01.ogg` only.
- **With it off,** the package has no `.convertedOriginals` (as today).
- **A feed episode,** through `publishReadableBook` with a `FeedBookLink`, as the feed import tests make one, keeps nothing with the setting on.
- **The kept original appears in no listing.** Run `grep -rn "audioFiles\|tracks(in\|contentsOfDirectory" TextMouth/Parsers TextMouth/Services`. For each function it finds that lists a book's files (at least `AudioBookParser.audioFiles(in:)` and `trackPaths(in:)`, `FileImportService.retainedContentURL(in:)` and `isPackageContentName`, `AudioManifestLocation.find(in:)`, and `BookContentAnalysisService.load`'s chapters), test that the kept file is not among them. List them all in your report.
- `FileImportService.deleteBookPackage(_:)` removes the kept original with the package.
- **The words:** the label, the hint, and both captions.
- `/opt/homebrew/bin/xcodegen generate`, and commit the project with the tests.

## Commits
1. The setting and its control, with their tests.
2. Keeping the originals at import, with the import tests.

## Test classes (one run)
`ConvertedOriginalTests OggImportConversionTests OggAudioConverterTests ImportAudioFormatsTests AudioDirectoryImportTests AudioMediaImportTests`, the settings classes (`grep -l "StorageSettingsView\|SettingsViewModel\|ConfigService" TextMouthProductionTests/*.swift`, at most 12 of them: name them in your report), `KeyboardReachabilityTests`, `UncheckedConcurrencyPolicyTests`, and `LogContentPolicyTests`. Also run `make lint-a11y LINT_BASE=team/audiofmt`.

## Do not touch
Export (task `keepexport`), the library's Ogg conversion, `OggHeaderReader.swift`, and any `*.md`.
