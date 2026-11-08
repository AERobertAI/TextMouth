# speechexport/support: the voice, the kept chapters, the disk check, and the power assertion (FMT43, step 4a)

Slug `speechexport-support`; branch `speechexport/support`, made with `git checkout -b speechexport/support team/speechexport`. Team `speechexport`, lead `speechexport-lead`. Follow "The worker's part" of `Scripts/agents/briefs/2026-10-30/teams-common.md`, and the build section at the end of this brief, which overrides its build-folder rules.

## Goal

A speech export (FMT43) speaks a text book into an audio file, chapter by chapter, which can take half an hour. Before it starts it must know the book's voice, speed, and pitch, refuse a Personal Voice, and check the disk; while it runs it keeps the Mac awake; and it keeps each finished chapter's file so that a stopped export goes on from its next chapter (the user's answer to question 19). This task makes those parts, each small and tested on its own. The `job` task joins them later. Three commits: voice and errors; the kept chapters; space and power.

## Read first (only these, by line range)

- `TextMouth/Services/SpeechService.swift` 939-982 (the global voice, speed, and pitch, the `"selectedVoiceID"` key, and the en-US fallback), 994-997, 2190-2205.
- `TextMouth/ViewModels/ReaderViewModel+VoiceAndSpeed.swift` 85-115 (`applyLocalSpeechOverrides`: a book's own voice, speed, and pitch win).
- `TextMouth/Models/Book.swift` 749-763 (the local voice settings).
- `TextMouth/Models/SettingsPolicy.swift` 40-80 and 365-380 (`validated`, `storedValue(in:)`, `wordsPerMinute`, `pitchMultiplier`).
- `TextMouth/Services/ArchiveBudget.swift` 28-85 (`freeSpaceReserve`, `volumeFreeSpace(at:)`); `TextMouth/Services/ImportScratchSpace.swift` 17-45 (`areOnSameVolume`).
- `TextMouth/Models/CloudStorageContract.swift` 568-660 (`MachineLocalPaths.caches`, under the test sandbox in hosted tests).
- `TextMouth/Services/AudioEditing/AudioEditRenderer.swift` 140-150 (`AudioRenderSettings.bitRatePerChannel`).
- `TextMouth/App/AppDelegate.swift` 48-85 (the launch sweeps).

## Commit 1: `SpeechExportVoice.swift` and `SpeechExportError.swift` (new, in `TextMouth/Services/SpeechExport/`; create the folder if it is not there yet)

1. `struct SpeechExportVoiceSettings: Equatable, Sendable { var voiceIdentifier: String?; var wordsPerMinute: Double; var pitch: Double }`, the voice, speed, and pitch a text book is read with, and
   `static func of(_ book: Book, defaults: UserDefaults, isInstalled: (String) -> Bool = SpeechExportVoiceInfo.isInstalled, fallback: () -> String? = SpeechExportVoiceInfo.fallbackIdentifier) -> SpeechExportVoiceSettings`, as a reader applies them:
   - the voice: `book.localVoiceID` when installed; else `defaults.string(forKey: "selectedVoiceID")` when installed (the key `SpeechService` and the settings model use: say so in a comment, naming both); else `fallback()`, the identifier of `AVSpeechSynthesisVoice(language: "en-US")`, as `SpeechService.init` falls back.
   - the speed: `book.localWPM` held to `SettingsPolicy.wordsPerMinute.range` when finite, as `SpeechService.setSpeedRealtime` holds it; else `SettingsPolicy.wordsPerMinute.storedValue(in: defaults)`.
   - the pitch: `book.localPitch` through `SpeechService.clampedPitch` when finite; else `SettingsPolicy.pitchMultiplier.storedValue(in: defaults)`.
2. `struct SpeechExportVoiceInfo: Equatable, Sendable { let identifier: String; let name: String; let isPersonalVoice: Bool }` with `static func installed(_ identifier: String) -> SpeechExportVoiceInfo?` (from `AVSpeechSynthesisVoice(identifier:)`; `isPersonalVoice` is `voiceTraits.contains(.isPersonalVoice)`; it reads the voice's description only, never speaks), `static func isInstalled(_ identifier: String) -> Bool`, and `static func fallbackIdentifier() -> String?`.
3. `enum SpeechExportError: LocalizedError, Equatable`, with exactly these `errorDescription`s (curly quotes as shown):
   - `personalVoice(name: String)`: "“\(name)” is a Personal Voice, which macOS can't record to a file. Choose another voice for this book with the Voice button in its reader, then export again."
   - `noVoice`: "No voice is installed to speak it. Add a voice in System Settings, Accessibility, Spoken Content, then export again."
   - `notEnoughSpace(needed: Int64)`: "There isn't room on the disk for it: it needs about \(needed), and TextMouth keeps \(reserve) free. Free some space, then export again." Both sizes through `ByteCountFormatter.string(fromByteCount:countStyle: .file)`; the reserve is `ArchiveLimits.standard.freeSpaceReserve`.
   - `busy`: "Another book is being exported as spoken audio. Export this one once it has finished."
   - `nothingToSpeak`: "The part of the book chosen has no words to speak."
   - `headingsChanged`: "The book's headings changed after the Export dialog opened. Close it, open it again, and choose the range again."

## Commit 2: `SpeechExportStore.swift` (new), and one line in `AppDelegate.swift`

The chapters one export has spoken, kept in this Mac's Caches folder (never the library) until that export finishes, another export replaces them, or TextMouth next launches.

1. `struct SpeechExportStore: Sendable { let root: URL; let key: String }`, with `static var liveRoot: URL` = `MachineLocalPaths.caches/Speech Export` and `var folder: URL` = `root/key`.
2. `static func key(bookID: UUID, voiceIdentifier: String?, wordsPerMinute: Double, pitch: Double, sections: [[String]]) -> String`: what decides whether kept chapters can be used again (each section given as its title, then its texts). SHA-256 (CryptoKit) over: the version string "TextMouth speech export 1"; the book ID's `uuidString`; the voice identifier or ""; `String(wordsPerMinute)`; `String(pitch)`; the number of sections; and for each section its number of strings, then each string. Every string and number goes in as its 8-byte little-endian length (or value) followed by its UTF-8 bytes, so no two inputs can run together. The key is the first 16 bytes in lowercase hex (32 characters).
3. `func chapterName(_ index: Int) -> String`: `String(format: "%04d.caf", index + 1)` ("0001.caf"); `func chapterURL(_ index: Int) -> URL`; `func partURL(_ index: Int) -> URL`: "%04d.partial.caf" (it keeps the `caf` extension, which AVAudioFile needs).
4. `func open() throws -> Int`: makes `root` and `folder`; removes everything in `root` but `folder` (any other export's kept chapters, and anything else); removes every `*.partial.caf` in `folder`; then counts the kept chapters from index 0 up while each chapter file exists and opens with `AVAudioFile(forReading:)` with a length above 0; the first that does not ends the count, and it and every other `NNNN.caf` after it are removed. Returns the count.
5. `func finishChapter(_ index: Int) throws`: moves `partURL(index)` to `chapterURL(index)`, removing a file already there first.
6. `func removeAll()`: removes `root` and all it holds (after a finished export); errors ignored.
7. One export at a time: `static func claim() -> Bool` (false while claimed) and `static func release()`, over a process-wide `OSAllocatedUnfairLock<Bool>`.
8. `static func sweep(root: URL = liveRoot)`: when `claim()` succeeds, removes `root` and releases; otherwise (an export is running) leaves it. `static func sweepInBackground()` runs `sweep()` on a utility-priority global queue.
9. In `AppDelegate.applicationDidFinishLaunching`, after `MigrationStagingLeftovers.sweepInBackground()`, call `SpeechExportStore.sweepInBackground()`, with a comment like its neighbours': a speech export's kept chapters outlive only the session that spoke them, so those a quit or crash left are removed at launch.

## Commit 3: `SpeechExportSpace.swift` and `SpeechExportPower.swift` (new)

1. `enum SpeechExportSpace`:
   - `static let speechBytesPerSecond: Int64 = 44_100`: 16-bit mono at 22,050 Hz, what the kept chapter files take (research 7.5).
   - `static var fileBytesPerSecond: Int64 { Int64(AudioRenderSettings.bitRatePerChannel / 8) }`: the AAC or MP3 file at 64 kbit/s.
   - `static func seconds(wordCount: Int, wordsPerMinute: Double) -> TimeInterval`: `wordCount / wordsPerMinute × 60`; 0 when the speed is not above 0 or not finite.
   - `static func check(speechSeconds: TimeInterval, fileSeconds: TimeInterval, speechFolder: URL, fileFolder: URL, freeSpace: (URL) -> Int64? = ArchiveLimits.volumeFreeSpace(at:), sameVolume: (URL, URL) -> Bool = ImportScratchSpace.areOnSameVolume, reserve: Int64 = ArchiveLimits.standard.freeSpaceReserve) throws`: the speech needs `ceil(speechSeconds) × speechBytesPerSecond` on `speechFolder`'s volume, the file `ceil(fileSeconds) × fileBytesPerSecond` on `fileFolder`'s. On one volume they add up. A volume whose free space minus what it needs is below `reserve` throws `SpeechExportError.notEnoughSpace(needed:)` with what it needs; a volume whose free space is unknown (nil) is not checked.
2. `struct SpeechExportPower: Sendable` (import `IOKit.pwr_mgt`): `var hold: @Sendable (_ reason: String) -> IOPMAssertionID?` and `var release: @Sendable (IOPMAssertionID) -> Void`, with
   - `static let live`: `IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)`, nil unless `kIOReturnSuccess`; `IOPMAssertionRelease`. An assertion ID is a plain number, so nothing here needs `@unchecked`.
   - `func whileHeld<Value>(reason: String, _ body: () throws -> Value) rethrows -> Value`: holds, runs `body`, and releases (when held) however `body` ends.

Comment every type, property, and function, and each non-obvious block. Avoid `@unchecked Sendable` and `nonisolated(unsafe)`.

## Tests: `TextMouthProductionTests/SpeechExportSupportTests.swift` (new), with a MARK per part

1. The voice settings: a book's own voice, speed, and pitch win; a book voice not installed falls back to the global one, and a global one not installed to the fallback (pass your own `isInstalled` and `fallback`); a book speed of 900 is held to 650, a pitch of 3 to 2; unset defaults give the policy's defaults; for a book without its own settings, the result equals what `SpeechService(userDefaults:)` reads from the same sandboxed preferences (`makeSandboxedPreferences`): `wordsPerMinute`, `pitchMultiplier`, and `currentVoice?.identifier` (making a `SpeechService` speaks nothing).
2. The voice info: an identifier no voice has gives nil; the first installed voice that is not a Personal Voice gives its name and `isPersonalVoice` false (skip when none).
3. Every error's words, exactly.
4. The store, in a sandbox root (`makeSandboxDirectory`): the key is 32 lowercase hex characters, the same for the same inputs, and different when any one input changes, including `[["a", "bc"]]` against `[["ab", "c"]]` and a section split in two; `open()` removes other keys' folders and partial files, counts consecutive readable chapters (write small real CAFs with `AVAudioFile`), stops at a missing or unreadable one (garbage bytes), and removes that one and those after it; `finishChapter` moves the part into place; `removeAll` removes the root; `claim` is exclusive until `release`; `sweep` removes the root, but not while claimed.
5. The space check: one volume adds the two needs; two volumes are checked apart; free space exactly `reserve` above the need passes and one byte less throws `notEnoughSpace` with the need; unknown free space passes; `seconds(wordCount:wordsPerMinute:)`, including 0 and a non-finite speed.
6. The power: `whileHeld` holds once and releases once, when its body returns and when it throws (a fake `SpeechExportPower` recording calls in a lock); the live one's hold gives an ID for a short reason, which its release lets go.

## Run

`SpeechExportSupportTests UncheckedConcurrencyPolicyTests export`. Report the exact `Executed N tests, with S tests skipped and F failures` line.

## Do not

- Touch `SpeechService.swift`, `AudioEngineService.swift`, or any reader file.
- Use a real synthesizer, touch Personal Voice beyond reading a voice's traits, or play a sound.
- Read or write anything under `~/.TextMouth`. Edit any `*.md` file, or any file not named here.

## Build and test (this team's rules; they override teams-common.md's build folder rules)

- The team shares ONE build folder, used by one teammate at a time: `/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-speechexport`. Never make another and never delete it: the lead deletes it at the end.
- Disk: before each build, `df -g /System/Volumes/Data` must show at least 2 GB available when that folder exists, 5 GB when it does not. Otherwise post to `speechexport-lead` and wait (`python3 .claude/skills/agent-bbs/scripts/bbs.py watch <slug> --timeout 600`), then check again.
- Build in the background, through the team's lock, which queues you behind a teammate's build (waiting is normal):
  `BBS_AGENT=<slug> /usr/bin/lockf -k /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-speechexport-build.lock python3 Scripts/test/run-area.py --derived-data /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-speechexport --log <your scratchpad>/<slug>-run.log <names>`
  Check on it no more often than every 4 minutes, with one short command.
- New files need `/opt/homebrew/bin/xcodegen generate`; commit the regenerated `TextMouth.xcodeproj/project.pbxproj` with them.
- Before reporting, `make lint-tests LINT_BASE=team/speechexport` must be clean, and the build must add no Swift warning.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
