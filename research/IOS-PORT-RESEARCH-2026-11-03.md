# TextMouth on iOS: research (November 3, 2026)

Your question (November 3): "Can you do some investigating on how hard this app would be to port to ios? is there a way to use the same codebase (abstracting the Mac and IOS code to librarys / modules) and using different compiler commands or would it need a whole nother repository for a port?"

Nothing in the repository was changed for this. Every measurement was made on a copy of main at commit 3c83a630, in a scratch folder. The script that made it is saved for later runs (see "How the measurement was made").

## The answers in brief

- **One repository and one codebase. No second repository.** Apple's tools are built for one set of sources serving several platforms. One `project.yml` can define the Mac app, as now, and an iOS app that compiles the same source files. The two builds differ only in the SDK they compile against, which the build command chooses:
  - the Mac: `xcodebuild -scheme TextMouth -destination 'platform=macOS'` (what `make build` and the test suite already do);
  - iOS: `xcodebuild -scheme "TextMouth iOS" -destination 'generic/platform=iOS'`.
- **What stays separate.** A few files belong to one platform only. They live in a platform folder that only that platform's target compiles. Inside a shared file, a few lines can be marked `#if os(macOS)` or `#if os(iOS)`.
- **Why not a second repository.** Both apps must read and write the same library format (library.json, the package records, content.md and its layers, which `OnDiskContractTests` pins). They must read every format the same way and speak the same way. A copy would drift apart with every fix, and main gets several fixes a day.
- **How hard: the engine ports, the interface and the system glue do not.** The compiler's own count, made by type-checking the whole app for iOS:
  - 434 of the 534 Swift files compile for iOS unchanged: 144,446 of 201,567 lines, 72%.
  - The other 100 files have 819 distinct errors.
  - These compile with no change: the speech and audiobook playback, the library's storage, imports, the feed engine, transcription, the reader's navigation and bookmarks, and most parsers.
  - The three Swift packages build for iOS without an error, and the vendored C code (LAME, liblouis, the exception catcher) passes clang's checks for iOS.
- **Where the work is.** It is in three places:
  - code written for AppKit: windows, menus, keyboard shortcuts, and VoiceOver focus;
  - the programs TextMouth runs beside itself (textutil, afconvert, afinfo, ffmpeg, and the braille helper), which iOS does not allow at all;
  - an iPhone interface, which needs designing for touch and VoiceOver gestures rather than menus and keys.
- **Rough size.** A first iPhone reader is a few waves of agent work, with you checking each round on the phone:
  - the app: the library, importing from Files, text and audio books read aloud in the background, lock-screen and AirPods controls, bookmarks, and the sleep timer;
  - before it, a wave that makes both apps compile with the Mac app unchanged.

  The rest of the Mac's features follow in later phases (see "A plan in phases").
- **Before any iOS build, this Mac needs the iOS platform.** Xcode refuses every iOS build, even for a device, until the iOS platform is downloaded in Xcode > Settings > Components. The download is about 10 GB, and the disk has 12 GB free today.

## How the measurement was made

- **The copy.** The committed `TextMouth/`, `Vendor/`, and `TextMouthBraille/` folders of commit 3c83a630, unpacked with `git archive`.
- **One edit, in the copy only.** `import AppKit` was rewritten as `import UIKit` in the 57 files that have it. Without that, each of those files stops at a single "no such module" error, which hides everything after it.
- **The type-check.** SwiftPM built the copy against Xcode's iOS 26.0 SDK (`swift build --triple arm64-apple-ios26.0 --sdk <iPhoneOS SDK>`), two jobs at a time to spare the 8 GB of memory. It took about two minutes, and no single process passed 0.9 GB.
- **Why not xcodebuild.** Xcode refused with: "iOS 26.0 is not installed. Please download and install the platform from Xcode > Settings > Components." SwiftPM needs only the iOS SDK, which Xcode includes. Your iPhone appeared in that same list of destinations, so Xcode can already see it.
- **The deployment target was iOS 26.0,** so that no error is only an availability check. With a lower iOS target, the seven `#available(macOS 26.0, *)` blocks would each need an iOS 26 check as well, since the `*` lets them pass on every other platform.
- **The C code was checked separately.** Clang syntax-checked against the iOS SDK every LAME source (19 files), every liblouis source (9), the exception catcher, and the braille helper's main.c, with no errors. They were not linked.
- **Run it again.** `build/orchestrator/ios-probe/run-ios-probe.sh [commit] [new folder]` (gitignored). It never changes the repository, and it writes `summary.md` and `errors.txt`, one line per distinct error. This run's results are in `build/orchestrator/ios-probe/2026-11-03/`. A second run from scratch gave the identical 819 errors. During a port the count is a progress meter.
- **The count's limits.**
  - The compiler stops reporting an expression at its first error, so fixing some errors will show others.
  - Some errors follow from others. For example, the 13 "cannot find type 'Context'" errors all come from the missing `NSViewRepresentable`.
  - Compiling is not working. Several parts compile on iOS but would fail when run (see "What compiles for iOS but would not work there").
- **A search would have missed half of it.** 47 of the 100 files never import AppKit, yet use its names, because SwiftUI brings AppKit's names in on the Mac. Only the compiler gives a true count.
- **The other way round,** four of the 434 clean files import AppKit without using it: SoundEffectService, ReaderViewModel+Navigation, ReaderViewModel+Bookmarks, and FeedArrivals. Each needs only that import line changed.

## What the compiler found

### The parts that compile for iOS unchanged

- **Speech and playback:** SpeechService (2,762 lines), AudioPlaybackService (2,258), and ReaderViewModel+Playback (3,807 lines, one error).
- **The library:** LibraryPersistenceService (1,620) and FileImportService (3,798).
- **Feeds:** FeedCenter and FeedDownloadManager.
- **Transcription:** TranscriptionService.
- **The reader:** ReaderViewModel+Navigation and ReaderViewModel+Bookmarks.
- **Models:** 111 of the 112 Model files. The exception is KeyboardShortcut.swift.
- **Parsers:** 67 of the 70. The exceptions are the two EPUB files and the PDF reader's font check.
- **Views:** most of the SwiftUI views compile too: 6 of the 12 reader views, 10 of the 19 library views, and 9 of the 15 settings views have no error at all. They will need touch-sized layouts, but not a rewrite.

### Where the 819 errors are, by cause

- **Windows (the largest group).** The names: `NSWindow` (193), `NSApp` (40), `NSApplication` (34), `NSView` (29), `NSAlert` (11).
  - View models pass the window an action came from (`from window: NSWindow?`), so that an alert or an announcement lands on the right window.
  - LibraryWindowRouter decides which window takes each app-wide action.
  - The Record window and the audio editor are AppKit windows (RecordingWindowController, AudioEditorWindowController, AudioEditorLauncher).
  - iOS has no `NSWindow`. These parameters become a small platform-neutral "window identity" type, and the alerts become SwiftUI alerts, which TextMouth already uses in 23 places.
- **Keyboard shortcuts and menus.** KeyboardShortcut.swift (40), KeyboardShortcutManager (21), KeyboardShortcutsSettingsView (15), MenuCommands (15), AudioEditorEditMenu (15), SilentKeyEquivalent (13), ReaderBookCommands (12), MenuVisibilityManager (11), ShortcutPressDispatcher (6).
  - The customizable shortcuts are built on AppKit's key events and function-key constants.
  - SwiftUI's `CommandMenu` and `CommandGroup` exist on iOS 14 and later, and on iPadOS 26 they fill the iPad's new menu bar [10].
  - On iPhone the same commands become buttons, context menus, and VoiceOver actions.
- **VoiceOver focus and announcements.** VoiceOverFocus.swift (76), VoiceOverAnnouncer (13), and the uses of `NSAccessibility`.
  - iOS has its own calls (`UIAccessibility.post` with screen-changed, layout-changed, and announcement notifications) and SwiftUI's `AccessibilityFocusState`.
  - SwiftUI's `AccessibilityNotification`, which VoiceOverFocus.swift already uses for some of its announcements, exists on both platforms. The file's errors are in its AppKit parts.
- **Audio devices.** NowPlayingService (76), RecordingCaptureBackend, RecordingInputDevices.
  - The Now Playing service listens to Core Audio's device list to notice AirPods coming and going. That part of Core Audio exists only on the Mac.
  - On iOS the same news comes from the audio session's route-change notification.
  - Recording uses `AVCaptureAudioFileOutput` and a device's `transportType`, both Mac-only. iOS records through AVAudioEngine or AVAudioRecorder.
- **XML trees.** EPUBParser (22), EPUBParser+Navigation (6), FeedParser (8), FeedOPML (5).
  - They use Foundation's `XMLDocument` with XPath. iOS's Foundation has only the streaming `XMLParser` (the iOS SDK has `NSXMLParser.h` and no other `NSXML` header) [12].
  - The DAISY, DOCX, SSML, and braille readers already use `XMLParser`, so they compile.
- **Running other programs.** WatchedProcess (10), OrphanedConversionSweep (12, through `libproc`'s process list), FFmpeg (1). `Process` does not exist in iOS's Foundation (no `NSTask.h` in the iOS SDK).
- **Editing in another app.** PackageFileEditing (16), BookTextEditor (10), BookManifestEditor (6) open a file in your own editor through `NSWorkspace` and watch for its return.
- **Small ones:**
  - the checkbox and radio-group control styles (13 places in 11 files);
  - `onExitCommand` (2 places) and `onDeleteCommand` (1), which exist only on the Mac;
  - `NSFont` in the PDF reader (3);
  - the Mac's computer name in the session lease (`SCDynamicStoreCopyComputerName`);
  - `NSPasteboard`;
  - the subscriptions to a file's published progress in PublishedFileProgress (`Progress.addSubscriber(forFileURL:withPublishingHandler:)`, Mac-only);
  - the sleep and wake notifications that ReadingStatsService gets from `NSWorkspace`.

## What compiles for iOS but would not work there

The compiler cannot see these. They compile for iOS, or will once a few small errors are fixed, but they would fail or go wrong when run there.

- **The programs TextMouth starts.** Every conversion that runs beside the app under WatchedProcess's watchdog: ImportAudioConverter (afconvert), AudioFileInfo (afinfo), TextutilConverter (textutil), BrailleTranslator and MacBrailleTableCheck (the TextMouthBraille helper), and FFmpeg.
  - iOS apps cannot start other programs: "system is not supported on iOS, and neither is posix_spawn or any other traditional UNIX mechanism to launch child processes" (Apple DTS) [7].
  - So on iOS, each of these is done inside the app, or not done at all (the next section, feature by feature).
- **Fixed system folders.**
  - VoiceOver's braille tables, which the Mac app reads in `/System/Library/ScreenReader/BrailleTables`, are not available to an iOS app.
  - The sounds in `/System/Library/Sounds`, which SoundEffectService and the audio editor's punch-in play, are not available either. An iOS app bundles its own sounds.
  - App Review guideline 2.5.2: an app "may not read or write data outside the designated container area" [6].
- **The library's folder.**
  - The Mac app is not sandboxed (`com.apple.security.app-sandbox` is false in TextMouth.entitlements), so it reads `~/.TextMouth` and any folder you choose, anywhere.
  - An iOS app always lives in its own container. The library goes in the container, and books come in through the Files app's picker, the share sheet, and "Open in TextMouth".
  - A folder you pick, in iCloud Drive or another provider, can be kept across launches with a bookmark [1].
- **The audio session.**
  - iOS manages audio for the whole device. Its default session silences an app when the phone is locked or set to silent [2].
  - A reader needs the playback category (the spoken-audio mode suits speech), the "Audio, AirPlay, and Picture in Picture" background mode, and handling of interruptions (calls, Siri) and route changes (headphones out pauses).
  - None of this exists on the Mac, so TextMouth has no `AVAudioSession` code today.
  - The lock screen and AirPods controls use the same MPRemoteCommandCenter and MPNowPlayingInfoCenter calls TextMouth already makes [9].
- **Quitting.**
  - AppDelegate holds a quit until nothing would be lost: unsaved edits, a recording take, a data-directory move, the feed downloads' places.
  - iOS has no quit. It suspends an app in the background and may end it without notice.
  - So on iOS everything is saved as the app goes to the background, with a few seconds of background time to finish. Long jobs (an import, a transcription) either run while the app is in front or use iOS 26's continued-processing task, which shows its progress to the user [4].
- **The memory guard.**
  - Its lines (watch at 1 GB, stop playback at 3 GB, save and quit at 6 GB) are Mac numbers.
  - An iPhone ends an app at a per-device limit, often well under those numbers. iOS gives the room left directly with `os_proc_available_memory`, which is iOS-only [3].

## How one codebase builds both apps

### The tools

- **Two app targets in one project.yml.**
  - The `TextMouth` target stays the Mac app, exactly as now.
  - A new `TextMouth iOS` target compiles the same `TextMouth/` folder, less the Mac-only platform folder.
  - It is given the module name `TextMouth` (`PRODUCT_MODULE_NAME`), so shared code and shared tests keep `@testable import TextMouth`.
- **Platform folders.**
  - `TextMouth/Platform/macOS/` holds what only the Mac compiles: window controllers, the AppKit key dispatch, VoiceOver focus for AppKit, WatchedProcess and the converters it runs, the menus' AppKit parts.
  - `TextMouth/Platform/iOS/` holds what only iOS compiles: the audio session, scene handling, the document picker, background tasks.
  - Each target excludes the other's folder. A new file anywhere else is shared by default, which is the point.
- **Seams as protocols.** Where both platforms do a job differently, the shared code names the job and each platform supplies its own way. Examples:
  - converting a document: textutil on the Mac, Apple's in-process RTF reader on iOS;
  - the window an action came from: an `NSWindow` on the Mac, a scene on iOS;
  - the device's name: the computer's name on the Mac, the device's on iOS.
- **`#if os(macOS)` and `#if os(iOS)`** for a few lines inside an otherwise shared file, such as the checkbox style versus a switch. The codebase has none today.
- **The build commands.**
  - `make build`, `make test`, and `make check` stay the Mac's.
  - New targets: `make build-ios` (compile only, for every merge) and `make test-ios`.
  - `make install-ios` would build, sign, and install on your iPhone (`xcrun devicectl device install app`).

A sketch of the iOS target in project.yml (its other settings would follow the Mac target's):

```yaml
  TextMouth iOS:
    type: application
    platform: iOS
    deploymentTarget: "26.0"
    sources:
      - path: TextMouth
        excludes:
          - "Platform/macOS/**"
          - "Resources/Info.plist"
          - "Resources/TextMouth.entitlements"
    settings:
      base:
        PRODUCT_MODULE_NAME: TextMouth
        PRODUCT_BUNDLE_IDENTIFIER: com.textmouth.TextMouth
        INFOPLIST_FILE: TextMouth/Platform/iOS/Info.plist
    dependencies:
      - package: ZIPFoundation
      - package: SwiftSoup
      - package: swift-markdown
        product: Markdown
      - target: LAME_iOS
      - target: ObjCExceptionCatcher_iOS
      - target: liblouis_iOS   # only if braille comes to iOS: linked into the app, as iOS has no helper programs
```

The Mac target's `sources` gains `excludes: ["Platform/iOS/**"]`. Each C library target gets an iOS twin. The simplest way is XcodeGen's `platform: [macOS, iOS]`, which makes one target for each platform, named with a `_macOS` or `_iOS` suffix, so the Mac target then names `LAME_macOS` [8]. liblouis is linked into the iOS app only if braille comes to iOS (question 7).

### The choices, and the recommendation

- **Two app targets from the same sources (recommended).**
  - It moves nothing the Mac build depends on: its test host path, the braille helper copied into Contents/MacOS, the Release stripping, and `make check`'s size gate all stay as they are.
  - Everything stays one module, so no declaration has to become `public`.
- **One multiplatform target.** XcodeGen's `supportedDestinations: [macOS, iOS]`, with `destinationFilters` on files and dependencies, or `inferDestinationFiltersByPath` for files under a `macOS` or `iOS` folder [8].
  - It works too, and is what Xcode's own multiplatform template makes.
  - But the Mac's Info.plist, entitlements, test host, and helper would all become per-platform settings of one target. That is more moving parts in the Mac build than the twin targets.
- **A core library module (later, if ever).** You suggested libraries or modules: a `TextMouthCore` framework or Swift package holding the Models, Parsers, and platform-free Services, used by both apps.
  - It makes the line between the engine and the platform one the compiler enforces.
  - It could also let the parser tests run without launching the app, which would spare the icon cache and the crash dialogs.
  - It costs a mechanical rewrite: everything one module uses from another must be marked `public` (or `package`), across hundreds of types, and the test imports change.
  - Worth considering once the port's seams have settled. The Parsers folder, which turns files into DocumentContent with almost no other dependency, would be the natural first module. It is not needed for the port.
- **Mac Catalyst** goes the other way (an iPad app running on the Mac). It does not fit, since the Mac app is the main one and is native.

## The iPhone app, for the person using it

- **One screen at a time.**
  - The Library is a list. Choosing a book opens its reader full screen, with Back to the library, and a small "now playing" bar keeps the book in reach from the library.
  - Settings is a screen, not a window: iOS has no Settings window (SwiftUI's `Settings` scene does not exist on iOS) [12].
- **VoiceOver gestures in place of keys.**
  - The reader's units (sentence, paragraph, heading, page, bookmark) on the rotor, with swipe up and down to move.
  - The two-finger double-tap (magic tap) for Play and Pause, anywhere in the app.
  - Adjustable controls for rate and position, and the reader's commands as VoiceOver actions.
  - The two-finger scrub to go back.
  - The SwiftUI calls for these (`accessibilityRotor`, `accessibilityAction`, `accessibilityAdjustableAction`) exist on both platforms, and TextMouth already uses the first two.
- **Listening with the screen locked**, from the lock screen, Control Center, and AirPods or headphone buttons, and pausing when headphones are taken out.
- **Adding books** from the Files app, the share sheet ("Open in TextMouth" from Mail, Safari, or Files), and, on iPad, drag and drop.
- **On iPad,** the Mac's design fits more closely:
  - iPadOS has windows, and SwiftUI's `openWindow` exists there (iOS 16 and later), so each book can have its own window as on the Mac;
  - the commands appear in the iPadOS 26 menu bar;
  - a keyboard's shortcuts work.

## Feature by feature

Each Mac feature and what it needs on iOS. "Shared" means the Mac's code, with at most small changes.

- **Speech (voices, rate, speech markup, substitutions).**
  - Shared. AVSpeechSynthesizer is the same class, and the engine path's `write(_:toBufferCallback:)` exists on iOS 13 and later [12].
  - iOS adds a setting for which audio session the synthesizer uses (`usesApplicationAudioSession`).
  - The voices are the iPhone's own, downloaded on the phone in Settings > Accessibility > Spoken Content, so the list will differ from the Mac's.
- **Audiobook playback, chapters, the manifest.** Shared, plus the audio session.
- **Bookmarks, Where Am I?, the sleep timer (End of heading included), reading statistics, the reading list, library views, folders.** Shared models; new touch views.
- **Text formats read in-process:** EPUB (after its XML change), PDF, DOCX, .dotx, .docm, .dotm, DAISY, HTML, web archives (WebArchiveReader reads the property list itself), Markdown, plain text, SSML, DTBook. Shared. The braille formats need liblouis (below).
- **RTF and RTFD.** On iOS, Apple's in-process reader (`NSAttributedString` reads plain text, RTF, RTFD, and HTML on iOS [12]), in place of textutil.
- **Word 97-2003 .doc and .dot import, and Word 97-2003 export.** iOS has no reader or writer for that format: only the Mac's AppKit has `.docFormat` [12]. Not on iOS at first.
- **OpenDocument (.odt) and Word 2003 XML.** Need readers of TextMouth's own (both are XML; ODT is a ZIP of XML, much like DOCX). Later.
- **Ogg audio (.ogg, .oga, .opus).**
  - The Mac converts it with afconvert in a watched child process, because Apple's own Vorbis decoder locked up inside TextMouth on October 14.
  - On iOS that decoder could only run inside the app, which is exactly what the Mac avoids. Recommended: no Ogg on iOS at first (convert it on the Mac).
  - Later, possibly: Xiph's own decoders (libogg, libvorbis, libopus, BSD-licensed C), built into the app.
- **Braille: reading BRF, BRL, and PEF, and writing BRF and PEF.**
  - liblouis passes clang's checks for iOS, but there it would run inside the app: no helper program, so no watchdog that can kill a hang, and a memory error would crash the app itself.
  - All its calls would go through one serial queue, since it is not thread-safe.
  - VoiceOver's tables cannot be read on iOS, so the app would bundle the tables it offers: TextMouth's four English tables are 332 KB, and VoiceOver's whole set on this Mac is 5.9 MB in 492 files.
  - This is a decision for you (question 7).
- **Feeds.**
  - The engine is shared.
  - Downloads that go on while the app is suspended need URLSession's background sessions, and refreshing on a schedule needs a background refresh task.
  - Second phase.
- **Transcription.** SpeechAnalyzer and SpeechTranscriber exist on iOS 26 as on macOS 26 [12]. TranscriptionService compiles. A long job runs in front, or as a continued-processing task [4]. Second phase.
- **Export.** Markdown, HTML, RTF, BRF, and PEF writers are shared. On iOS the file goes out through the share sheet or a save dialog (SwiftUI's `fileExporter`).
- **Edit Text and Edit Manifest in your own editor.**
  - On the Mac, TextMouth opens the file in another app and watches for its return.
  - iOS has no such round trip, so the iOS app would have its own editor. The New from Text view is a start.
- **The cloud library.**
  - The cloud code compiles, the dataless-file policy call included: `setiopolicy_np` exists on iOS 2 and later [12].
  - A library shared by the Mac and the iPhone would need the library in iCloud Drive (yours is in `~/.TextMouth`, on the Mac's disk).
  - Two devices would also write it at once. That is FR02's "a warning and never a lock", meant for two Macs used one at a time, whereas a phone in a pocket is used while the Mac is open.
  - Recommended: a library of the phone's own first (question 3).
- **Recording, and the audio editor.** Recording needs AVAudioEngine or AVAudioRecorder and microphone permission. The editor's engine is shared, but its window is AppKit's and ffmpeg is gone. Last phase; the editor suits the iPad first.
- **The keyboard shortcuts settings.** Mostly for an iPad with a keyboard. Last phase.

## A plan in phases

Each step is a branch of small commits with tests, reviewed and merged as now. The Mac suite (9301 tests, 75 skipped, 0 failures on November 1) must stay green at every merge, and `make build-ios` joins the merge check from phase 0 on.

### Phase 0: both apps compile, and the Mac app works exactly as before

- 0.1 The iOS target, with a placeholder screen: the iOS twins of LAME and the exception catcher (and of liblouis, if braille comes to iOS); the iOS Info.plist; `make build-ios`.
- 0.2 Move the files that are AppKit through and through into `Platform/macOS/`, unchanged.
- 0.3 The seams: the window identity (the 193 `NSWindow` uses), announcements, the control styles, fonts, the pasteboard, opening links, the device's name.
- 0.4 One XML tree reader, built on `XMLParser`, for EPUB, feeds, and OPML on both platforms.
  - This changes the Mac's own EPUB and feed reading, so the document goldens and the feed tests must show identical results.
  - It is the riskiest step of the phase. Give it a review of its own.
- 0.5 iOS stand-ins for the converters, so an iOS import of a format it cannot read says so.

Size: one or two waves. Review rounds will find things, as every round has.

### Phase 1: a first iPhone reader

- 1.1 The app's frame: the library list, the reader screen, the settings screen, importing (Files, share sheet, Open in), and the library in the app's container.
- 1.2 Audio: the audio session, background audio, interruptions, route changes (and the AirPods rewind from them), the lock screen and remote commands.
- 1.3 The life cycle: saving as the app goes to the background, and the memory guard from `os_proc_available_memory`.
- 1.4 VoiceOver: the rotor for headings, pages, and bookmarks, the magic tap, adjustable rate and position, the reader's actions, focus on new screens.
- 1.5 Bookmarks, Where Am I?, the sleep timer, voices and rate, all as touch views over the shared models.
- 1.6 An iOS test target for the shared tests and the iOS seams. 804 of the 931 test files use no AppKit name, so most could run on iOS.

Size: two to four waves. You check each round on the iPhone with VoiceOver, since no test can stand in for that.

### Phase 2: more of the Mac's features

Feeds with background downloads, transcription, export through the share sheet, RTF in-process, an in-app text editor, the reading list and library views, and braille if you want it on iOS. Size: two to four waves.

### Phase 3: iPad and the rest

Windows for each book, the menu bar, keyboard shortcuts, recording, the audio editor, and a library shared with the Mac if you want one.

These sizes are for planning only. They assume this project's way of working: Sonnet workers, Opus reviews of the large branches, the build train, and your hand checks between waves.

## What it needs from this Mac and from Apple

- **The iOS platform download.**
  - About 10 GB: forum reports give 10.3 GB for Xcode 26.1.1's iOS platform support and 10.6 GB for the iOS 26.4 simulator [11]. Apple's DTS engineer there explains that what is needed "isn't the SDK, it's the platform support components, which includes the simulator."
  - Xcode > Settings > Components, or `xcodebuild -downloadPlatform iOS`.
  - With 12 GB free today, that would leave about 2 GB, under what a merge suite needs (the archive-import tests refuse to run under 1 GB, and AGENTS.md asks for 2 to 3 GB free). So free space first.
- **Memory.**
  - Building both platforms doubles the compile work on an 8 GB Mac, and the iOS Simulator takes memory of its own while it runs.
  - The build train's one-build-at-a-time rule extends naturally: the iOS compile check at each merge, and the iOS tests less often.
  - Running the iOS tests on your iPhone instead of the simulator spares the Mac that memory.
- **Signing [5].**
  - With your free Apple Account, Xcode's "Personal Team" installs on your own iPhone, but every install expires after 7 days and must be rebuilt and reinstalled. There is a limit of 3 apps per device and 10 App IDs.
  - Background audio is an Info.plist key (`UIBackgroundModes`), not an entitlement [13], so the free team's limits on entitlements should not stop it. The first install will confirm it.
  - The Apple Developer Program (US$99 a year) gives year-long installs, TestFlight, and the App Store.
- **App size** should stay near the Mac's, within your 25 MB target: the same code, no helper program, plus whatever braille tables are bundled. The Mac app from the last `make build` is 21.7 MB.

## Risks

- **The window seam touches the Mac's window routing.** That routing was reworked on November 1 for the next book in the same window. Review it as closely as that work was.
- **The XML change changes what the Mac reads** from EPUBs and feeds. The goldens are the guard, and any difference stops the merge.
- **liblouis inside the app on iOS** loses the isolation the Mac's helper gives (question 7).
- **iOS background rules** limit feeds, transcription, and imports while the app is not in front.
- **VoiceOver on iPhone can only be checked by hand,** like the Mac's hosted VoiceOver tests, which skip even with VoiceOver on.
- **Two platforms cost more at every merge,** in build time, in disk, and in the weekly usage.

## Questions for you

They are in `humanQuestions/2026-11-03.md`, each with a recommended answer and a line for yours:

1. iPhone first, iPad first, or both?
2. What the first iPhone version must do.
3. A library of the phone's own, or one shared with the Mac.
4. The free Personal Team or the paid program.
5. Which iOS versions.
6. Freeing about 10 GB and downloading the iOS platform.
7. Braille on iOS without the helper's isolation.
8. No Ogg on iOS at first.
9. No Word 97-2003 on iOS.
10. Twin targets now, a core module perhaps later.
11. When to start.

## Sources

1. Apple, "Providing access to directories": a picked folder's security-scoped URL, a bookmark that keeps access across launches, and the user's control in Settings > Privacy > Files and Folders. https://developer.apple.com/documentation/uikit/providing-access-to-directories
2. Apple, "Configuring your app for media playback": the playback category, the background mode, and the default session's silencing. https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback
3. Apple, `os_proc_available_memory` (iOS 13 and later; not macOS). https://developer.apple.com/documentation/os/os_proc_available_memory
4. Apple, `BGContinuedProcessingTask` (iOS and iPadOS 26 and later). https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask
5. Apple, "Choosing a membership": the Personal Team's limits (App IDs and profiles that expire after 7 days, 3 devices, 3 apps per device). https://developer.apple.com/support/compare-memberships/
6. Apple, App Review Guidelines 2.5.2 (self-contained apps) and 2.5.4 (background audio for its intended purpose). https://developer.apple.com/app-store/review/guidelines/
7. Apple Developer Forums, DTS replies on child processes on iOS. https://developer.apple.com/forums/thread/72265 and https://developer.apple.com/forums/thread/747499
8. XcodeGen's project spec: `supportedDestinations`, `destinationFilters`, `inferDestinationFiltersByPath`, and `platform` as a list. https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md
9. Apple, "Becoming a now playable app" (sample code, macOS 10.14, iOS 12.2, tvOS 12.2). https://developer.apple.com/documentation/mediaplayer/becoming-a-now-playable-app
10. Apple, WWDC25 "Elevate the design of your iPad app" (session 208) and "What's new in UIKit" (session 243): the iPadOS 26 menu bar. https://developer.apple.com/videos/play/wwdc2025/208/ and https://developer.apple.com/videos/play/wwdc2025/243/
11. Apple Developer Forums, reports of the iOS platform's download size. https://developer.apple.com/forums/thread/817687 and https://developer.apple.com/forums/thread/821839
12. The iOS 26.0 and macOS 26.0 SDKs of Xcode 26.0.1 on this Mac, read directly:
    - Foundation's headers on iOS (no `NSTask.h`, `NSXMLParser.h` alone among the `NSXML` headers);
    - `NSAttributedString.h` in UIKit and AppKit (the document types);
    - `AVSpeechSynthesis.h`;
    - `sys/resource.h` (`setiopolicy_np`);
    - the SwiftUI and Speech interfaces (`Settings`, `Window`, `MenuBarExtra`, the checkbox style, and `onExitCommand` unavailable on iOS; `CommandMenu` from iOS 14; `OpenWindowAction` from iOS 16; `SpeechAnalyzer` on iOS 26).
13. Apple Developer Forums: background modes are set by the `UIBackgroundModes` Info.plist key, and `com.apple.developer.background-modes` is not a valid entitlement. https://developer.apple.com/forums/thread/798959
