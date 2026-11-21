# Team engine: the services and view models

Read `ios0-common.md` beside this file first: it is the pattern, and its rules override this charter. Your team is `engine`, your lead `engine-lead`, and your branch `team/engine`. Your files are listed in `files-engine.md` beside this file: 35 files. Most errors are small: a view model that passes along the `NSWindow` an action came from, or an NSApp, NSAlert, or NSWorkspace call. The large ones are the Now Playing service's AirPods watching, the helper programs, and the round trip to the user's own editor.

## Decisions already made

- **The helper programs (Services/WatchedProcess.swift, Services/OrphanedConversionSweep.swift).**
  - WatchedProcess runs textutil, afconvert, afinfo, and the braille helper as watched child processes. iOS lets an app start none ("system is not supported on iOS, and neither is posix_spawn or any other traditional UNIX mechanism to launch child processes", Apple DTS).
  - Move both files unchanged to `TextMouth/Platform/macOS/Services/`.
  - Give iOS a `WatchedProcess` stand-in with exactly the members its callers use (ImportAudioConverter, AudioFileInfo, TextutilConverter, BrailleTranslator, MacBrailleTableCheck, PlaybackMemoryGuard's `terminateAll()`). Each run throws `IOSUnavailable.feature("Converting this kind of file")`, and each other member does nothing, so every conversion fails cleanly, through the error path it already has.
  - The sweep's stand-in sweeps nothing.
  - `OrphanedConversionSweep+Textutil.swift`, if it has no errors, moves with its main file only if it cannot compile without it.
- **The editor round trip (Services/PackageFileEditing.swift, BookTextEditor.swift, BookManifestEditor.swift)** opens a file in the user's own app through NSWorkspace and takes the saved file back.
  - Move each unchanged.
  - Give iOS stand-ins with the members shared code calls, each throwing `IOSUnavailable.feature("Editing a book's text in another app")` (or "…a book's manifest…"), or doing nothing.
- **Now Playing (Services/NowPlayingService.swift)** stays shared: its Now Playing info and remote commands are what iOS needs most. Only its Core Audio device listening (the default-output and device-list listeners, `AudioObject…`, `kAudioHardware…`, `kAudioDeviceTransportType…`) is Mac-only.
  - Move that part, unchanged, into an extension in `TextMouth/Platform/macOS/Services/NowPlayingService+macOS.swift` (rule 5), or wrap it in place, whichever leaves the projection smaller.
  - iOS gets the same members as stand-ins that watch nothing. Phase 1 will use the audio session's route changes.
- **Small wraps, in place:**
  - LibrarySessionLease: the computer's name becomes `UIDevice.current.name` on iOS, and NSApplication or NSWorkspace calls are wrapped;
  - PublishedFileProgress: `Progress.addSubscriber` is Mac-only, so iOS subscribes to nothing;
  - PlaybackMemoryGuard: its NSAlert and NSApplication;
  - ReadingStatsService: NSWorkspace's sleep and wake notifications, with none on iOS for now;
  - SleepTimerService and TextSubstitutionService: their one or two lines each.
- **The Word 97-2003 writer (Services/Export/WordDocExportWriter.swift)** uses AppKit's `.docFormat`, which iOS lacks. Move it unchanged. Wherever shared code lists or chooses it, wrap that line, so that iOS's export never offers it.
- **The PDF reader's fonts (Parsers/PDFTextParser.swift)**: `NSFont` becomes `PlatformFont`. Where it reads a font's traits, NSFont's and UIFont's names differ, so read them in an `#if os(macOS)` … `#else` pair. The Mac reads exactly as before.
- **The view models (ViewModels/…)**: `NSWindow` becomes `PlatformWindow`, and NSApp, NSAlert, NSOpenPanel, and NSWorkspace calls go behind `#if os(macOS)`. A method that only the Mac's windows call may be wrapped whole, if no shared caller needs it on iOS.

## Tasks

About five tasks of 40 to 60 errors each. For example:
1. the helper programs and their stand-ins;
2. the editor round trip;
3. Now Playing;
4. the small services, the Word writer, and the PDF reader;
5. the view models, in one or two tasks by file: Library… and Reader…, the others.

Do the first and second early, since others' code calls their names.

## Tests to request from the train

Request areas by task:
- the helper programs: `import`, `ogg`, `braille`;
- the editor round trip: `library`, `places`;
- Now Playing: `audio`, `playback-end`;
- the small services: `storage`, `stats`, `export`, `pdf`;
- the view models: `library`, `reader-text`, `cloud`, `transcripts`.

## Watch for

- WatchedProcess's watchdog, the memory guard, and the Ogg conversion protect the user's Mac from a hung decoder (October 14, when the Mac had to be restarted). Not one line of their Mac behavior may change.
- `UncheckedConcurrencyPolicyTests` pins the `@unchecked Sendable` and `nonisolated(unsafe)` counts across every file. A stand-in must add neither.
