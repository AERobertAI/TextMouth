# The two apps and the platform folders

Part of [TextMouth's architecture](../../ARCHITECTURE.md).

TextMouth is a Mac app, and since November 4, 2026 (phase 0 of the iOS port) a second app, for iOS, compiles from the same code. The design is in IOS-PORT-RESEARCH-2026-11-03.md, in the repository root, whose sections "How one codebase builds both apps" and "A plan in phases" this page follows. Phase 0 had one goal: the iOS app compiles and links, and the Mac app does exactly what it did. This page says how the code is divided between the two, and then how the iPhone app built on that division is put together (see "The iPhone app", below). On November 8, 2026 the iPhone interface of IOS-INTERFACE-SPEC-2026-11-07.md first ran in the iOS simulator; nothing has run on a phone.

## One source folder, two apps

- Both apps compile the TextMouth source folder. project.yml defines `TextMouth`, the Mac app, and `TextMouthiOS`, the iOS app (how they build is in [Building TextMouth](../developer/building.md)). The iOS app has the module name TextMouth too, so shared code and shared tests read the same on both.
- Each app leaves out the other's platform folder:
  - the Mac app leaves out `TextMouth/Platform/iOS/`;
  - the iOS app leaves out `TextMouth/Platform/macOS/` and the Mac's `TextMouth/Resources/`.
- A file anywhere else is shared. A new file is shared by default, which is the point: write it for both apps, and put in a platform folder only what one app alone can compile.
- Every Swift file under `TextMouth/` is in an app target, and both apps use the same Swift 6 language mode and complete concurrency checking. `UncheckedConcurrencyPolicyTests` counts `@unchecked Sendable` and `nonisolated(unsafe)` across every Swift file, the platform folders included.

## The platform folders

- `TextMouth/Platform/macOS/` holds what only the Mac compiles. Its folders mirror the ones the files came from, so a file keeps its place below `Platform/macOS/`: `TextMouth/Services/WatchedProcess.swift` is `TextMouth/Platform/macOS/Services/WatchedProcess.swift`. It holds:
  - `App`: TextMouthApp, AppDelegate, and FrontWindowKind (split out of MenuCommands, which stays in `App`);
  - `Services`: WatchedProcess, OrphanedConversionSweep (and its Textutil extension), PackageFileEditing, BookTextEditor, BookManifestEditor, MenuVisibilityManager, and `Export/WordDocExportWriter`;
  - `Views`: the window controllers of the Record window and the audio editor, the audio editor's Edit menu and launcher, VoiceOverFocus, ReadOnlyTextArea, SilentKeyEquivalent, SwitchedWindowFocus, LogsInFinder, and `Reader/WindowAccessor`.
- `TextMouth/Platform/iOS/` holds what only the iOS app compiles: the iPhone app's own code (its app and scene delegates, views, and services), IOSUnavailable, and a stand-in for each Mac-only type that shared code still names, in folders that mirror the Mac's. The iPhone's plain types, the ones that import no UIKit, are in the shared folder `TextMouth/Phone/` instead, so the Mac's tests reach them. A stand-in's file name ends `+iOS` and starts with the comment `// Phase 0 stand-in:`, which says what the Mac version does and what iOS does instead.
- The iOS app has one Info.plist, an Info.plist of its own, `TextMouth/Platform/iOS/Info.plist`, which project.yml names in `INFOPLIST_FILE` and Xcode merges into the plist it generates (`GENERATE_INFOPLIST_FILE`). Until 0.4.1 the iOS configurations used the Mac's plist, by accident: XcodeGen sets `INFOPLIST_FILE` to the first `Info.plist` among a target's sources, even one the target excludes. `Scripts/ios/sync-info-plist.py` writes the iOS file from the Mac's, `TextMouth/Resources/Info.plist`, so the two cannot drift apart by hand, and `make check-ios-plist` (`--check`) exits 1 when the iOS file is stale:
  - It leaves out the document types iOS cannot import, with the declaration of any type nothing else names: "Ogg Audio" and "Audio Converted at Import" (the import converts that audio with `afconvert`, which iOS cannot start), "ALAC Audio" (its one type, `com.apple.coreaudio-format`, is the system's type for `.caf` files too, which are converted the same way, so `.alac` is not offered on iOS either), and the BRF, BRL, and PEF braille files (reading them takes the braille helper).
  - It leaves out the keys `LSMinimumSystemVersion` and `NSAppleEventsUsageDescription`, which are macOS's, and, until 0.4.2, added `.azw3` to the Kindle MOBI type and its declaration. From 0.4.2 the Mac's own list names `.azw3` (FMT48), so that addition (`ADDED_EXTENSION` in Scripts/ios/sync-info-plist.py) is no longer needed.
  - It adds the two keys that only iOS has (`IOS_ONLY_KEYS` in the script): `UIBackgroundModes` with the one mode `audio`, without which every book stops as the screen locks, and `UIApplicationSceneManifest` with `UIApplicationSupportsMultipleScenes` false, so the app has one scene at a time, an iPad included, since one reading session cannot serve two windows. The scene's delegate is named in code, by `TextMouthAppDelegate`, so the manifest names no configuration. The script stops, rather than hide a mistake, if the Mac's plist ever holds one of those two keys.
  - project.yml leaves out `INFOPLIST_KEY_UIApplicationSceneManifest_Generation`, because Xcode's generated manifest would allow several scenes. The iOS plist holds no key that an `INFOPLIST_KEY_` setting in project.yml also sets (`INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace` and `INFOPLIST_KEY_UILaunchScreen_Generation`), since Apple does not say which would win. The app's display name, "TextMouth", comes from this plist, which takes it from the Mac's.
  - iOS goes by the types a document type names (`LSItemContentTypes`) and the extensions their declarations tag, not by `CFBundleTypeExtensions`, which is why a type is left out by name. Everything else is the Mac's, including the Kindle MOBI and KFX types and the App Transport Security setting feeds need.
  - `IOSInfoPlistTests` reads both plists and the project's per-configuration setting. It checks that the iOS list is the Mac's less the named exceptions, that the background modes are `audio` alone, that the app allows one scene, that file sharing is off, that no plist key is also a build setting, and that each configuration of the project uses its own app's plist.
  - Nothing has run on a device: whether `Info.plist` is the place iOS reads `.azw3` from is unchecked. The simulator build merges the file into Xcode's generated plist and installs, and `make check-ios-plist` passes at 1fefa2cf.
- The files directly in `TextMouth/Platform/` are shared by both apps:
  - `PlatformTypes` declares three aliases: `PlatformWindow` (NSWindow on the Mac, UIWindow on iOS), `PlatformFont` (NSFont, UIFont), and `PlatformView` (NSView, UIView);
  - `PlatformApplication` answers the application-wide questions shared code asks: `keyWindow`, `mainWindow`, `isActive`, `didBecomeActiveNotification`, and `didResignActiveNotification`. On the Mac each is the AppKit expression the code used before (`NSApp.keyWindow`). On iOS there is no key or main window to name yet, so those two answer nil, and "active" means in the foreground;
  - `PlatformControlStyles` gives `checkboxToggleStyle()` (a checkbox on the Mac, a switch on iOS) and `radioGroupPickerStyle()` (a radio group on the Mac, an inline list on iOS).

## The five kinds of Mac change

The Mac app must compile what it compiled before. Every change phase 0 made to a file the Mac compiles is one of these five, and nothing else is allowed without a reason a reviewer reads:

- **A move, unchanged.** A file only the Mac needs is moved into `Platform/macOS/`, with its text unchanged in the move.
- **A wrapper.** Existing Mac code is wrapped, as it stands, in `#if os(macOS)`, with iOS code in the `#else` branch. In a file both apps share, `import AppKit` becomes `import AppKit` under `#if os(macOS)` and `import UIKit` under `#else`.
- **A platform alias.** A type or an expression is named through a shared alias that is exactly the old one on the Mac: `PlatformWindow`, `PlatformFont`, `PlatformView`, and `PlatformApplication`'s members. A new alias goes in a shared file directly in `Platform/`, one alias to a line in the form `typealias PlatformX = NSX`.
- **A control-style helper.** `.toggleStyle(.checkbox)` is `.checkboxToggleStyle()`, and `.pickerStyle(.radioGroup)` is `.radioGroupPickerStyle()`. On the Mac each applies exactly the old style.
- **A split, unchanged.** When a file holds shared code and code only the Mac can compile, a whole declaration moves, unchanged, into a file of its own: FrontWindowKind out of MenuCommands and WindowAccessor out of BookReaderWindowView, both into `Platform/macOS/`, and AudioEditorLauncher's `describe(_:)`, which the shared audio editor models call on either app, into a shared extension, `Views/AudioEditor/AudioEditorLauncher+Describe.swift`.

`make mac-projection` checks this (see [Building TextMouth](../developer/building.md)). It reads each changed file as the Mac compiles it, resolving `#if os(macOS)` the Mac's way and reading each alias and helper as the Mac expression it stands for, and prints what is left. Its list of equivalences lives in `Scripts/ios/mac-projection.py`: a new helper in `Platform/` needs its line there, or its calls look like real changes. One limit: it pools the removed lines of all the files, so a real deletion of a line such as `}` can count as moved when another file adds the same text. The final review of phase 0 read the 13 files it listed with a stricter matcher and found nothing hidden.

On November 4 the projection read 105 changed Swift files, of which 92 are unchanged for the Mac. The other 13 are new shared code that only tests and aliases use (the portable XML tree and the three shared files directly in `Platform/`), the three declarations split out unchanged, which add only their imports and an `extension` line, and four closures reflowed around a `#if`. Each of the four closures is a one-line default or argument made into a closure so that an `#if` has a place to sit (LibrarySessionLease's quit, ReadingStatsService's workspace notifications, LibraryViewModel's reveal in Finder, and ContentView's Quit): the Mac still runs the same statement.

## The iOS stand-ins and IOSUnavailable

- Where shared code names a Mac-only type, the type has a stand-in in `Platform/iOS/` with the same name and the members shared code uses. The rule is that a name is never taken away from iOS: move a type to `Platform/macOS/` only with a stand-in for each name a shared file still uses.
- A stand-in does the least it safely can: it does nothing, answers "no", or throws. None traps. Mark it `@MainActor` where its Mac twin is.
- `IOSUnavailable` (`Platform/iOS/IOSUnavailable.swift`) is what a stand-in throws for work the iPhone app cannot do. Its one case, `feature`, takes a phrase that completes "… is not available on iPhone yet", and its description is the full sentence, such as "Converting this kind of file is not available on iPhone yet.", since a person may hear it.
- The stand-ins phase 1 inherits, by what they stand in for:
  - Helper programs: WatchedProcess throws `IOSUnavailable` from `run` and `runCapturingOutput` and has no memory reading; OrphanedConversionSweep does nothing. The only document reading that needs textutil, and so a helper, is a compound-file Word document older than Word 6, which iOS therefore refuses with "Converting this kind of file is not available on iPhone yet." Every other document format reads on iOS through TextMouth's own readers, which are shared code with no AppKit and no process: rich text and RTFD, Word 6 to Word 2003, Word, OpenDocument text, Word 2003 XML, MOBI, and KFX (see [Imports](state/imports.md)). OpenDocument text and Word 2003 XML read the same on the Mac since 0.4.0, and Word 6 and Word 95 documents since 0.4.1.
  - Editing in another app: PackageFileEditing's workspace opener throws, and BookTextEditor and BookManifestEditor start no session (`canEditText` is false).
  - Windows and keys: WindowAccessor reports no window; SilentKeyEquivalent takes no key; SwitchedWindowFocus does nothing; FrontWindowKind is always nil; LogsInFinder says showing the logs in Finder is not available on iPhone yet; `FunctionKeyConstants+iOS` gives the 72 function-key constants NSEvent.h defines, with its values, so config.json's key names (pageDown, f5, and the rest) read the same.
  - VoiceOver: VoiceOverFocus and StandardVoiceOverFocus are hidden views; VoiceOverAnnouncer posts `AccessibilityNotification.Announcement`, mapping the shared high and medium priorities to iOS's default and low to iOS's low (see "The announcement priorities on iOS", below); `NSAccessibilityPriorityLevel` exists on iOS as an enum.
  - Text: ReadOnlyTextArea is a read-only, selectable `UITextView` with the Mac's label.
  - Recording and editing audio: the Record window and audio editor controllers and the audio editor launcher do nothing; the capture backend's `start` throws `IOSUnavailable` for "Recording"; FFmpeg's `run` throws that ffmpeg is missing.
  - Now Playing: audio-device queries answer "no device", and the device listeners are never installed.
  - Smaller ones: PDF text reading's bold and italic traits (`UIFontDescriptorSymbolicTraits+iOS`), and `isMainWindow` on UIWindow.
- Some Mac-only work has no stand-in file, only an `#else` branch where it is called: the quit hold and the memory guard's alert and quit do nothing on iOS; opening TextMouth again throws `IOSUnavailable`; Word 97-2003 export (`WordDocExportWriter`) is left out of the list of export writers; and the file and folder panels (DAISY folder import, OPML import, the data directory's folder chooser, Export's destination, and the text input's open-in-editor action) are empty branches.

## The portable XML tree

The EPUB, feed, and OPML readers walk Foundation's `XMLDocument` and search it with XPath. iOS's Foundation has only the streaming `XMLParser`. So phase 0 added a portable tree that has the part of the interface those readers use, and gave it Foundation's names on iOS, so the reader files compile for iOS as they are.

- `Parsers/PortableXML.swift` holds the classes (`PortableXMLDocument`, `PortableXMLElement`, and `PortableXMLNode`). The tree is read-only: its name, local name, prefix, namespace, kind, level, string value, attributes, children, and `rootElement()`, `attribute(forName:)`, and `nodes(forXPath:)`.
- `Parsers/PortableXMLPath.swift` is the XPath subset the readers use: an optional `//`, steps that are `*` with any number of `[local-name()='x']`, `[@a]`, and `[@a='v']` predicates. Anything else throws `PortableXMLError.unsupportedXPath`.
- `Parsers/PortableXMLBuilder.swift` builds the tree with no recursion. A strict reader runs on Foundation's `XMLParser`; a lenient reader, used only when Tidy is asked for and the strict reading fails, runs on SwiftSoup's XML parser, which it reaches only through `MarkupGuard.parseXML(_:baseURI:deepestNesting:)` with `deepestNesting` set to `PortableXMLDocument.maximumDepth`, 512. The guard counts the depth from the bytes before SwiftSoup builds anything and measures the parsed tree again afterwards, so markup nested deeper never becomes a tree of SwiftSoup's own, whose recursion would overflow the stack of an import (see [Shared helpers](shared-helpers.md)). Either layer's refusal is `PortableXMLError.tooDeep`, and a document with too many tags or attributes throws `MarkupRefusal`. A tree deeper than 512 levels is refused, a document that declares its own entities is refused, and releasing a tree is iterative, so a hostile feed cannot overflow the stack or hang the app.
- The markup guard asks for a thread with a 490 MiB stack (`MarkupGuard.onLargeStack`, see Shared helpers in [Architecture](../../ARCHITECTURE.md)).
  - On the Mac this was tried: a 4 GiB stack was created and ran.
  - On an iPhone it is unverified. Apple's Threading Programming Guide gives the iOS main thread 1 MB and a secondary thread 512 KB, lets `pthread_attr_setstacksize` set the size before the thread starts, and says the memory is reserved when the thread is created and committed only as it is touched. It names no upper limit.
  - If iOS refuses the size at creation, the fallback steps down to 122 MiB, then 30 MiB, then the caller's own thread, as the Mac would.
  - If iOS accepts a size and cannot commit the pages when they are touched, that is memory pressure, not a refusal at creation, and the fallback does not catch it.
  - Only the type-check has run for iOS; a device or simulator check is still to do.
- `Platform/iOS/Parsers/XMLTree+iOS.swift` is the iOS-only file that makes `XMLDocument`, `XMLElement`, and `XMLNode` the portable classes. The Mac compiles the portable tree too, but only `PortableXMLDifferentialTests` uses it: no Mac code reads through it, so the Mac's own EPUB and feed reading is unchanged.
- `PortableXMLDifferentialTests` is what makes the tree trustworthy. It reads 104 documents with Foundation's `XMLDocument` and with the portable tree, strictly and tidied: the 16 XML documents of the five test EPUBs, 27 feed, OPML, and OPF fixtures, and 61 small documents in `PortableXMLCorpus`. It compares every node's kind, level, name, local name, prefix, namespace, and string value, every attribute, and the answers to the XPath expressions the four reader files use (a scan test confirms every XPath string in them is one the comparison makes). The trees agree except where `knownDifferences` lists a difference, 14 in all, each with its reason and an evidence fragment the reported difference must contain; a listed difference that goes away fails the test. Some differences are accepted and hidden on purpose: attribute order within an element, `*` selecting a processing instruction in Foundation, the DTD node and XML declaration not being nodes, and the depth bound.
- `EPUBParser.updateOPFMetadata`, which writes a book's details into its EPUB, is wrapped in `#if os(macOS)`: its output must match what Foundation's pretty printer writes, and the portable tree does not write. On iOS it throws `IOSUnavailable` for "Saving a book's details into its EPUB file".

## The iPhone app

The iPhone interface is built from IOS-INTERFACE-SPEC-2026-11-07.md, in the repository root, which holds the design and the hand-check list. This section says how the code is put together. It describes the code main holds since November 8, 2026: the interface of branch `ios/lead-1108`, and the fixes of branch `ios/fix-c-1108` (the sheet buttons and the full-contrast text, below).

### The frame

- The iPhone app runs on UIKit's life cycle, not SwiftUI's `App`. `TextMouthAppDelegate` is the `@main` type, and the app's one window is `MagicTapWindow`, a subclass that is the reliable home for the magic tap.
- `PhoneAppModel` holds everything the app keeps for as long as it runs: the library, the settings, the sounds, the session, the life cycle, and the navigation path.
  - `TextMouthAppDelegate.model` makes it once for the process, never once per scene.
  - The reason is that iOS may disconnect a scene while a book plays on behind a locked screen, and a second model would be a second library over the same files.
- `PhoneSession` owns the open readers, above the navigation. Leaving a reader's screen does not close the book.
  - At most two readers are open: the one on screen (`reader`), and one that goes on behind it (`listeningReader`).
- `PhoneLifeCycle` is the one place where every slice joins the system's calls. The scene delegate only calls it, and each slice registers what it does there, so no slice edits the delegate.
- The code is split by what it imports:
  - `TextMouth/Phone/` holds the plain types: the session, the models, the policies, and the words. They import no UIKit, both apps compile them, and the Mac's tests decide every case (the `phone` test area).
  - `TextMouth/Platform/iOS/` holds the UIKit and SwiftUI parts: the delegates, the views, and the services that touch the audio session and the screen.
- A reader reaches the phone through `ReaderPhoneHooks`.
  - These are closures that the phone fills and the shared reader calls at a few fixed points, each under `#if os(iOS)`.
  - Every default leaves the reader doing what it does on the Mac.

### PhoneLaunchRequest

- `PhoneLaunchRequest` is what a UI test, or a run in the simulator, asks of the app at launch through its environment. It has two variables.
  - `TEXTMOUTH_UI_TEST` set to exactly "1" gives the launch a library and preferences in a sandbox of its own, as a hosted test has. An empty or mistyped value leaves the app as it is.
  - `TEXTMOUTH_OPEN_AT_LAUNCH` set to an absolute path sends the app that file, as another app would send one at a cold launch. A relative path is ignored.
- It acts in debug builds only.
  - The type itself is shared code, and the Mac's tests cover it (`PhoneLaunchRequestTests`).
  - The two places that read the environment are inside `#if DEBUG` on iOS: `TextMouthRuntime.detect`, which sets the sandbox, and the scene delegate, which opens the file.
  - A release build ignores both variables.
- A UI test needs it because XCTest names its configuration (`XCTestConfigurationFilePath`) only in a process that hosts a test bundle, and the app a UI test drives does not host one. Without the sandbox, each test would find what the last one left in the app's real container.
- The book comes in the way a person's would: held until the library starts, copied by the import's copier, imported, and opened. The file is never moved or deleted.
- From a shell, `xcrun simctl launch` passes each variable with the prefix `SIMCTL_CHILD_` (see [Building TextMouth](../developer/building.md)).

### PhoneSession.readerMade

- `PhoneSession.readerMade` is a Combine subject that sends each reader once, as the session makes it. It does so before anything can play the reader, and whichever slot the reader takes.
- The parts of the phone that give a reader its hooks join there: `PhoneAudioSession.attach`, and `PhoneBackgroundWork`'s hold for the life cycle.
- Before it, each part watched the two slots its own way, and one missed a slot.
  - A next book that goes straight behind the screen, as a hand-over does, got none of the hooks.
  - Its silent gaps then held nothing, and its pause in the background was never flushed.
- A new part that needs a hook on every reader subscribes to `readerMade`. It does not subscribe to the two slots.
- `PhoneBackgroundWork` also gives its hooks to the readers that were open before it ran, in either slot.

### ReaderPhoneHooks.unitInForce

- `unitInForce` is a closure in `ReaderPhoneHooks`. It answers the unit that the phone's moves go by for this reader now: the book's own unit, else its kind's unit from Settings.
- `PhoneReaderModel` fills it. If the model or the reader is gone, it answers `PhoneDefaults.textNavigationUnitDefault`, the sentence.
- The lock screen and Control Center build their skip commands from it.
  - `ReaderViewModel.phoneRemoteCommandPolicy` calls `PhoneRemoteCommandPolicy(unitInForce:forward:backward:)`.
  - That initializer uses the unit in force when the phone has filled it in, and otherwise the Mac's shared skip units.
- Without it, a text book's lock screen offered 15 seconds while each press moved one sentence. That breaks the spec's rule that the lock screen never promises 15 seconds and moves a heading.
- The policy is read again when the book changes, when the settings model changes, and when the preferences change. Settings keeps each kind's unit in the preferences, not in the settings model.
  - `PhoneAudioSession.attach` merges the three and calls `phoneRemoteCommandsMayHaveChanged()`.
- On the Mac the closure is nil, and the shared units apply as they did.

### The crash guard

- `PhoneSession.openingBookKey` (`phone.openingBookID`) is a preference. It is written before a reader is made and removed once the reader's load ends. If it is still there at launch, the app ended while opening that book.
- The session reads and clears it in its initializer, which runs at launch, before any reader exists.
  - It keeps what it read in `openingBookAtLastEnd`.
  - `takeReopeningAtLaunch(fileOpened:)` acts on it at the first activation.
- It used to be read at the first activation. A Play from the lock screen that wakes a killed app opens a book first and writes its own mark, and the first activation then read that mark as a crash.
- When the guard finds a crash, the book is not reopened, and the listener hears "TextMouth closed while opening <title>, so it wasn't reopened." (`PhoneAppWording.closedWhileOpening`).
- A file opened at launch wins over reopening. A book that crashes on loading therefore cannot do so at every launch.
- A lock-screen Play that opens a book takes a hold on the app for the load ("Playing from the lock screen", through `PhoneSession.beginHold`), as going on to the next book does.

### PhoneScreenHolds

- `PhoneScreenHolds` is the one keeper of the screen's sleep. Each owner takes a hold with `begin()`, which returns a closure that lets go. Letting go twice does nothing.
- The keeper tells its `apply` closure whether the screen should stay awake, once per change. The screen should stay awake while any hold is in force.
- `UIApplication.isIdleTimerDisabled` is one app-wide flag.
  - The import copier and Book content each used to set it and clear it.
  - Whichever let go first let the screen lock for the other.
- `PhoneScreenSleep`, in `Platform/iOS/Services`, holds the one keeper, whose `apply` sets the flag. Nothing else sets the flag.
- The keeper imports no UIKit, so the Mac's tests decide every case.

### The announcement priorities on iOS

- Apple's header (`UIAccessibilityConstants.h`) says the default priority interrupts existing speech but can itself be interrupted. It says the low priority is queued and spoken after other speech has finished.
  - The first draft had these reversed, so every shared high or medium word cut off what VoiceOver was saying.
- `VoiceOverAnnouncer.postThroughAccessibility` now maps the shared priorities on iOS this way:
  - high and medium post at iOS's default priority, so they interrupt;
  - low posts at iOS's low priority, so it waits its turn.
- iOS's own high priority cannot be interrupted once started. The shared announcer never posts it. `PhoneAnnouncer.important` posts it by a path of its own (`VoiceOverAnnouncer.postToVoiceOver`).
  - In a process hosting tests, `important` goes through the announcer's poster at high priority, so a test reads it.
- `PhoneAnnouncer` is what the phone's own code says to VoiceOver:
  - `say` posts at low, after a delay of 0.15 seconds, so the words follow VoiceOver's own speech about what just changed.
  - `joined` runs several messages into one announcement. It adds a full stop to a message that ends in no sentence mark, so the voice pauses, and it returns a lone message as it is.
  - `say(inOrder:)` says a run of messages as one announcement, because a run posted one by one would cut each other off.
  - `combined` joins announcements posted together into one, at the highest priority among them.
  - `important` interrupts at once.
- `VoiceOverAnnouncer.collectingAnnouncements(during:)` returns what a synchronous call announced, instead of posting it. A move uses it to sort what it says (`PhoneMoveFeedback`) before anything is heard.
- Words that should follow VoiceOver's speech go through `say`: the sheets' farewell words, a folder's arrival words, and import results.

### Book content: PhonePassagePolicy

- `PhonePassagePolicy` decides what passage Book content holds and when it changes. It is a plain type, so the Mac's tests cover every rule.
- `placeToShow(chapter:offset:chapterCount:hasWords:)` says where the passage is taken from.
  - If the reading place's chapter has words to say, the passage is taken from that place.
  - If not, it is taken from the start of the next chapter that has words, which is where Play would begin reading.
  - If no chapter from there on has words, the answer is nil, and Book content keeps its stand-in.
- It is needed because a Project Gutenberg EPUB opens at its "Cover", a chapter that is only an image, and Book content was blank there.
  - `hasWords` uses `ReaderViewModel.hasSpeakableText`, which is playback's own rule.
  - The search is `ReaderViewModel.nextSpeakableChapterIndex`, the same forward-only search that playback makes over silent chapters.
  - The Mac's Book content still shows nothing at such a chapter. Whether the Mac should do the same is an open question to the user.
- `turnEffect(isPlaying:)` says what a page turn does. A page turn comes from the three-finger swipe or from VoiceOver's Read All.
  - Paused, it is `movesPlaceAndText`: the place moves to the new page, then the text shows it. Stopping Read All therefore leaves the place where the reading got to.
  - Playing, it is `movesTextOnly`: the book plays on where it is, and only the text moves.
- Read All works through the page-turn trait.
  - `PhoneBookTextView` adds `causesPageTurn` to its traits.
  - At the end of the passage, VoiceOver calls `accessibilityScroll(.next)` and reads on from the next passage.
  - At the book's end the scroll returns false, which ends the reading.
- `changesPassage(on:hasFocus:isPlaying:followsInBraille:)` decides when the text changes. A focused text view must not change under a reader, in speech or in braille.
  - A move made while the book plays does not swap the text under a reader who has focus on it, unless Follow in Braille is on. Paused, a move always shows.
  - The ten-second tick follows the book only while it plays and Book content has no focus, or Follow in Braille is on.
  - The book loading, focus leaving, and the listener's own request always change it.

### PhoneEscapePolicy

- VoiceOver's escape gesture is the two-finger scrub.
  - The system already pops a pushed screen (the reader, a folder) through the navigation stack's Back.
  - It closes a sheet unless the sheet turned off its interactive dismissal.
- The import question turns it off (`interactiveDismissDisabled(true)`), so only an answer settles it. A scrub on the question must leave it open.
- A search is the one place where the system does not know what "back" means, so `PhoneEscapePolicy.libraryOutcome(isSearching:isFolderScreen:)` says. It returns one of three outcomes:
  - `clearSearch`, if the search field holds text, wherever the screen is. The field is emptied and focus goes to it.
  - `goBack`, if the screen is a folder's and no search is in progress.
  - `nothing`, at the top of the Library, which has nowhere to go back to.
- `PhoneLibraryView` attaches it as `.accessibilityAction(.escape)`.

### The error alert plan, Speech Stopped, and the preview's pause

- `PhoneErrorAlertPlan` decides what the error alert over the reader shows and does. It is the Mac's `ReaderViewModel.ErrorAlert`, with the Mac's buttons.
  - An error that can be retried gets "Retry", or "Try Again" for a chapter that could not be got from the cloud, and "Cancel".
  - An error that cannot be retried gets "OK" alone.
  - Every button closes the alert and forgets the error in the reader.
  - Retry then calls `retryAudioPlayback()` on the next turn of the main queue. A retry that fails again can then present a fresh alert, instead of having the closing alert clear its message.
  - `returnsFocusToPlay(errorAlertNow:)` is true only when no alert is showing once the alert has closed, so focus is never taken from a fresh alert.
  - `PhoneReaderErrorAlert` presents the alert from the session's snapshot (`snapshot.errorAlert`), which changes only when the alert comes or goes.
- The Speech Stopped sheet is `PhoneSpeechRefusalSheet`, over the Mac's `SpeechRefusalReport` and `SpeechRefusalWording`. Its words say iPhone where the Mac's say Mac.
  - The summary reads "The iPhone's speech engine refused to speak the text here, twice, so speech stopped. Play tries again from the same place."
  - The report's device heading is "This iPhone", and its system line starts "iOS:".
  - `SpeechRefusalWording.runsOnPhone` chooses the words, and each function takes an `onPhone` parameter, so the Mac's tests reach both.
  - The sheet has no Show Logs in Finder. VoiceOver's order is the heading with what happened, the Details text area, Copy Details, and Close in the toolbar.
  - `PhoneSpeechRefusalPresentation.shows` decides when it shows. A screen presents one sheet or alert at a time, so the report waits while a panel sheet, the error alert, or another alert is over the reader. It shows as the last of them closes.
- Preview Voice pauses a playing book. `PhonePreviewPause.pause` pauses each reader that plays, and returns a closure that plays on the readers it paused, or nil if none was playing.
  - The closure leaves alone a book that plays by then, because a second Play would only restart it.
  - `PhoneSession.pauseBookForPreview` gives it both readers, once each. It pauses without the pause sound, since the preview is about to speak.
  - `PhoneSettingsVoicePreview` asks `audioMayStart` first. It pauses the book only at the first of a run of previews, and resumes it once, when the last preview ends, is cancelled, is refused by the speech engine, or is stopped.
  - Settings and the reader's Voice sheet both use it.

### PhoneTextStyle: the phone's text at full contrast

- `TextMouth/Platform/iOS/Views/PhoneTextStyle.swift` holds the colors of the phone's words in one place.
  - The reason is Apple's accessibility audit. It finds iOS's secondary gray only "nearly" enough contrast, and the tint a button draws its words in no better.
  - So the phone draws every word in the primary label color, and tells the kinds apart by font, weight, and position.
  - The Library did this first for its rows (`PhoneRowLines`). Settings, Headings, Go To, Sleep Timer, Bookmarks, the Voice sheet, Add to Library, Book Information, and the choice sheet use the same style now, with no word changed.
- `PhoneTextColor` names three colors:
  - `secondary`, for captions, details, values, and section headings: the words a design would draw in gray.
  - `primary`, for the words of a button or of a row that is one, which iOS would draw in the tint. It is kept apart from `secondary` because a tint fails the audit on its own account, whatever is decided about gray.
  - `disabled`, for words that do nothing now. It is `Color.secondary`, the system's gray, so that a dimmed button or row still looks dimmed. Whether the audit lets a disabled control's text pass is unverified.
- Two view modifiers apply them: `phoneSecondaryText()` and `phonePrimaryText()`. Each draws the color while the control is enabled, and `disabled` while it is not, by reading the `isEnabled` environment value.
  - They name a color outright and not a hierarchical style, because inside a button the hierarchical styles take the button's tint.
- `PhoneActionButton` is a `Button` whose plain words take `phonePrimaryText()`. Use it in place of `Button(title, action:)`. VoiceOver reads the same label. It takes an optional `ButtonRole`.
- `PhoneValueRow` shows a name and its value in place of `LabeledContent(name, value:)`, whose value iOS draws in gray. The name takes `primary` and the value `secondary`.
  - At the accessibility text sizes (`typeSize.isAccessibilitySize`) the value goes under the name, in a `VStack`. Side by side, the name broke in the middle of a word beside its value at the largest size ("Fade out duration" in Settings).
  - The stacking has no test of its own, and the test that would show it, `LargeTextUITests`, still fails on Settings (see [Testing TextMouth](../developer/testing.md)).
- Full contrast for all of the phone's text follows the recommended answer to question 2 of section 6 in `humanQuestions/2026-11-08.md`. The user has not answered. Until they do, the work follows the recommendation: yes, for people with low vision.
- To undo it, make one line say `static let secondary = Color.secondary` in `PhoneTextColor`. Button words stay at full contrast, since `primary` is a separate line.
- The contrast result: the audit's findings of contrast fell from about 50 to 2 on the sheets tested. Both remaining ones are on the first section header under the bar ("Voice" in Settings, "New Timer" in Sleep Timer), whose text is black in the screenshots, so they are probably false positives.

### PhoneSheetButton: where a sheet's buttons go

- `TextMouth/Platform/iOS/Views/PhoneSheetButton.swift` holds `PhoneSheetButtonPlacement` and `PhoneSheetButton`. Every sheet's Cancel, Close, Done, Save, and Back to Book comes from it, and no sheet places one itself.
  - The sheets: Book Information (and its loading state), the choice sheet, both folder sheets (the form and Delete Folder), the stand-in sheet for a panel not built yet (`PhoneUnbuiltSheet`), Speech Stopped, Go To, Headings, Sleep Timer, Voice, Bookmarks, and Add to Library.
- `PhoneSheetButtonPlacement.placement` is the one place the placement is decided. It is `.topBarTrailing`. Changing it back is one line.
- A `PhoneSheetButton` is a `ToolbarContent`, used in a `.toolbar` in place of a `ToolbarItem` with a `Button`. It takes:
  - `title`, the button's words, drawn at full contrast through `PhoneActionButton`;
  - `label`, what VoiceOver and braille call it when that is not the title, and the title if none is given;
  - `hint`, which is none by default;
  - `isEnabled`, which is true by default, and a button that is not enabled is dimmed;
  - the `action`.
- The order is the title, then Cancel (or Close, or Done), then the confirming button. VoiceOver reads the title, then Cancel, then the confirm button, as the spec orders them.
  - A sheet lists its Cancel before its confirm button in its toolbar, and the trailing placement keeps that order.
  - The two folder sheets had Cancel before the title. They follow the spec now.
- Why not the system's places, `.cancellationAction` and `.confirmationAction`:
  - In the simulator's tests (iPhone 17, iOS 26), Book Information's and the choice sheet's Cancel were reported missing, though Go To's, in `.topBarTrailing`, was found.
  - `ToolbarPlacementProbeUITests` put the buttons back in `.cancellationAction` and read the sheet's tree on November 8, 2026. The buttons were never missing. They were ordinary buttons labeled "Cancel" and "Save", with no identifier, drawn as text pills 66 and 51 points wide, and not as an xmark or "Close".
  - What was wrong was their order. Those places are the bar's leading side, so the accessibility tree read "Cancel, Save, Book Information", with the buttons before the title. The tests read a sheet from its title on, so they found no Cancel after it. The earlier reports of a missing Cancel were an order problem.
  - Limit: the probe gave the buttons explicit labels, so the unlabeled case was not observed. This is written in the helper's comment.
- The probe is `PhoneSheetButtonPlacement.probeVariable`, the launch variable `TEXTMOUTH_PROBE_SYSTEM_PLACEMENT`. In a debug build, when it is "1", every sheet button takes `.cancellationAction`. It is read under `#if DEBUG` only (see [Building TextMouth](../developer/building.md)).
- Not verified: the order on a phone with VoiceOver, since VoiceOver does not run in the simulator. The simulator's tree is what the tests read.
- A related fix from the same round: a `Slider` in the Voice sheet is labeled by its label closure alone. A `.accessibilityLabel` on top of it made VoiceOver read "Speed, Speed", so the extra modifier was removed.

## What is left

- These are not done: the rotors on Play, Book content's language, Search in Book, the Files drop folder, sounds, and `PhoneSession.closeBook(id:)`. [Testing TextMouth](../developer/testing.md) lists the audit findings that are still open.
- Phase 1 left these places empty or approximate, and the first run has not settled them:
  - the Shortcuts recorder, hardware keys, and menus, which compile but are untested on iOS;
  - a recording backend, if recording comes to iOS;
  - a writer for the EPUB metadata, which needs a serializer and a decision on whether to match Foundation's output;
  - the window passed through shared code, which is nil on iOS, since `PlatformApplication` names no key or main window.
- The iOS app has a bundle identifier of its own, `com.textmouth.TextMouth.iOS`, so the question phase 0 left open is settled.
- Everything that sounds or needs VoiceOver can be checked only on a phone, with the spec's hand-check list.
- A change to shared code has a second check. Compile it for iOS with `make typecheck-ios`, and show it leaves the Mac as it was with `make mac-projection`, besides the hosted test suite, which tests the Mac only. The type-checks do not compile tests (see [Testing TextMouth](../developer/testing.md)).
