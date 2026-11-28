# The two apps and the platform folders
<!-- id: two-apps-platform-folders; keys: iOS port, TextMouthiOS, one codebase, XcodeGen; src: project.yml -->

Part of [TextMouth's architecture](../../ARCHITECTURE.md).

TextMouth is a Mac app, and, since phase 0 of the iOS port, a second app, for iOS, compiles from the same code.
The design is in research/IOS-PORT-RESEARCH-2026-11-03.md, in the repository root, whose sections "How one codebase builds both apps" and "A plan in phases" this page follows.
Phase 0 had one goal: the iOS app compiles and links, and the Mac app does exactly what it did.
This page says how the code is divided between the two, and then how the iPhone app built on that division is put together (see "The iPhone app", below).
Its feeds are real, not a stand-in: see [Feeds on the iPhone](platforms-phone-feeds.md).

## One source folder, two apps
<!-- id: one-source-folder-two-apps; keys: targets, XcodeGen, excludes, Swift 6, strict concurrency, shared code; src: project.yml, TextMouthProductionTests/UncheckedConcurrencyPolicyTests.swift -->

- Both apps compile the TextMouth source folder. project.yml defines `TextMouth`, the Mac app, and `TextMouthiOS`, the iOS app (how they build is in [Building TextMouth](../developer/building.md)).
  It also defines the static library targets SwiftSoup and SwiftSoup_iOS, one for each app, which compile the vendored HTML and XML parser in `Vendor/SwiftSoup` (see [Third-party code](../developer/third-party-code.md)).
  The iOS app has the module name TextMouth too, so shared code and shared tests read the same on both.
- Each app leaves out the other's platform folder:
  - the Mac app leaves out `TextMouth/Platform/iOS/`;
  - the iOS app leaves out `TextMouth/Platform/macOS/` and the Mac's `TextMouth/Resources/`.
- A file anywhere else is shared.
  A new file is shared by default, which is the point: write it for both apps, and put in a platform folder only what one app alone can compile.
- Every Swift file under `TextMouth/` is in an app target, and both apps use the same Swift 6 language mode and complete concurrency checking.
  `UncheckedConcurrencyPolicyTests` counts `@unchecked Sendable` and `nonisolated(unsafe)` across every Swift file, the platform folders included.

## The platform folders
<!-- id: platform-folders; keys: Info.plist, UIBackgroundModes, scene manifest, LSItemContentTypes, check-ios-plist, typealias, UTI; src: project.yml, Makefile, Scripts/ios/sync-info-plist.py, TextMouth/Platform/iOS/Info.plist, TextMouth/Resources/Info.plist, TextMouthProductionTests/IOSInfoPlistTests.swift, TextMouth/Platform/PlatformTypes.swift, TextMouth/Platform/PlatformApplication.swift, TextMouth/Platform/PlatformControlStyles.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift, TextMouth/Platform/iOS/Services/WatchedProcess+iOS.swift, TextMouth/Platform/macOS/App/FrontWindowKind.swift, TextMouth/Platform/macOS/App/TextMouthApp.swift, TextMouth/Platform/macOS/App/AppDelegate.swift, TextMouth/Platform/macOS/Services/OrphanedConversionSweep.swift, TextMouth/Platform/macOS/Services/OrphanedConversionSweep+Textutil.swift, TextMouth/Platform/macOS/Services/PackageFileEditing.swift, TextMouth/Platform/macOS/Services/BookTextEditor.swift, TextMouth/Platform/macOS/Services/BookManifestEditor.swift, TextMouth/Platform/macOS/Services/MenuVisibilityManager.swift, TextMouth/Platform/macOS/Services/Export/WordDocExportWriter.swift, TextMouth/Platform/macOS/Views/VoiceOverFocus.swift, TextMouth/Platform/macOS/Views/ReadOnlyTextArea.swift, TextMouth/Platform/macOS/Views/SilentKeyEquivalent.swift, TextMouth/Platform/macOS/Views/SwitchedWindowFocus.swift, TextMouth/Platform/macOS/Views/LogsInFinder.swift, TextMouth/Platform/macOS/Views/Reader/WindowAccessor.swift, TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorEditMenu.swift, TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorLauncher.swift, TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorWindowController.swift, TextMouth/Platform/macOS/Views/Recording/RecordingWindowController.swift -->

- `TextMouth/Platform/macOS/` holds what only the Mac compiles.
  Its folders mirror the ones the files came from, so a file keeps its place below `Platform/macOS/`: WatchedProcess, which came from the `Services` folder, is `TextMouth/Platform/macOS/Services/WatchedProcess.swift`.
  It holds:
  - `App`: TextMouthApp, AppDelegate, and FrontWindowKind (split out of MenuCommands, which stays in `App`);
  - `Services`: WatchedProcess, OrphanedConversionSweep (and its Textutil extension), PackageFileEditing, BookTextEditor, BookManifestEditor, MenuVisibilityManager, and `Export/WordDocExportWriter`;
  - `Views`:
    - the window controllers of the Record window and the audio editor, and the audio editor's Edit menu and launcher;
    - the Search Library window (`LibrarySearch/LibrarySearchWindowController` and `LibrarySearchWindowView`);
    - and QuitNotice, VoiceOverFocus, ReadOnlyTextArea, SilentKeyEquivalent, SwitchedWindowFocus, LogsInFinder, and `Reader/WindowAccessor`.
- `TextMouth/Platform/iOS/` holds what only the iOS app compiles: the iPhone app's own code (its app and scene delegates, views, and services), IOSUnavailable, and a stand-in for each Mac-only type that shared code still names, in folders that mirror the Mac's.
  The iPhone's plain types, the ones that import no UIKit, are in the shared folder `TextMouth/Phone/` instead, so the Mac's tests reach them.
  A stand-in's file name ends `+iOS` and starts with the comment `// Phase 0 stand-in:`, which says what the Mac version does and what iOS does instead.

### The iOS Info.plist
<!-- id: ios-info-plist; keys: Info.plist, UIBackgroundModes, scene manifest, LSItemContentTypes, check-ios-plist, sync-info-plist; src: project.yml, Makefile, Scripts/ios/sync-info-plist.py, TextMouth/Platform/iOS/Info.plist, TextMouth/Resources/Info.plist, TextMouthProductionTests/IOSInfoPlistTests.swift -->

- The iOS app has one Info.plist, an Info.plist of its own, `TextMouth/Platform/iOS/Info.plist`, which project.yml names in `INFOPLIST_FILE` and Xcode merges into the plist it generates (`GENERATE_INFOPLIST_FILE`).
  XcodeGen would pick the first `Info.plist` among a target's sources, even an excluded one, so project.yml names the iOS file.
  `Scripts/ios/sync-info-plist.py` writes the iOS file from the Mac's, `TextMouth/Resources/Info.plist`, so the two cannot drift, and `make check-ios-plist` (`--check`) exits 1 when the iOS file is stale:
  - It leaves out the document types iOS cannot import, with the declaration of any type nothing else names:
    - "Ogg Audio" and "Audio Converted at Import" (the import converts that audio with `afconvert`, which iOS cannot start);
    - "ALAC Audio" (its one type, `com.apple.coreaudio-format`, is also the system's `.caf` type, converted the same way);
    - and "NLS BARD Braille Package" (`.bopf`, FMT56), since the iPhone copies only the file it is handed, and a package file alone would arrive without its BRF volumes.
      A BARD ZIP, or a folder chosen with Import Folder…, imports there.
      `FileImportService.supportedTypes` names the type only under `#if os(macOS)`; `IOSInfoPlistTests` pins both.
    The BRF, BRL, and PEF types stay, since the iPhone reads them in the app (DR34).
    "Audio and Video Converted with ffmpeg" stays, since the app converts it (FMT54), and so does "Lossless Audio Read by TextMouth".
  - It leaves out the keys `LSMinimumSystemVersion` and `NSAppleEventsUsageDescription`, which are macOS's.
    The Mac's own list names `.azw3` (FMT48), so the Kindle type is the Mac's.
  - It adds the keys that only iOS has (`IOS_ONLY_KEYS` in the script):
    - `UIBackgroundModes` with the one mode `audio`, without which every book stops as the screen locks;
    - `BGTaskSchedulerPermittedIdentifiers`, a wildcard for the export task ([Exports on the iPhone](state/exports-iphone.md));
    - and `UIApplicationSceneManifest` with `UIApplicationSupportsMultipleScenes` false, so the app has one scene at a time, an iPad included, since one reading session cannot serve two windows.

    The scene's delegate is named in code, by `TextMouthAppDelegate`, so the manifest names no configuration.
    The script stops, rather than hide a mistake, if the Mac's plist ever holds one of those two keys.
  - project.yml leaves out `INFOPLIST_KEY_UIApplicationSceneManifest_Generation`, because Xcode's generated manifest would allow several scenes.
    The iOS plist holds no key that an `INFOPLIST_KEY_` setting in project.yml also sets (`INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace` and `INFOPLIST_KEY_UILaunchScreen_Generation`), since Apple does not say which would win.
    The app's display name, "TextMouth", comes from this plist, which takes it from the Mac's.
  - It keeps the "CUE Sheet" type (`com.textmouth.cue-sheet`, FMT24); whether the iPhone's import takes a .cue has not been tried.
  - iOS goes by the types a document type names (`LSItemContentTypes`) and the extensions their declarations tag, not by `CFBundleTypeExtensions`, which is why a type is left out by name.
    Everything else is the Mac's, including the Kindle MOBI and KFX types and the App Transport Security setting feeds need.
  - `IOSInfoPlistTests` reads both plists and the project's per-configuration setting.
    It checks that the iOS list is the Mac's less the named exceptions, and compares the Kindle MOBI type with the Mac's whole, like every other type, with its explicit extension list.
    It also checks that the background modes are `audio` alone, that the app allows one scene, that file sharing is off, that no plist key is also a build setting, and that each configuration of the project uses its own app's plist.
  - Nothing has run on a device: whether `Info.plist` is the place iOS reads `.azw3` from is unchecked.
    The simulator build merges the file into Xcode's generated plist and installs.

### The files directly in Platform
<!-- id: platform-shared-files; keys: PlatformTypes, PlatformWindow, PlatformFont, PlatformView, PlatformApplication, PlatformControlStyles; src: TextMouth/Platform/PlatformTypes.swift, TextMouth/Platform/PlatformApplication.swift, TextMouth/Platform/PlatformControlStyles.swift -->

- The files directly in `TextMouth/Platform/` are shared by both apps:
  - `PlatformTypes` declares three aliases: `PlatformWindow` (NSWindow on the Mac, UIWindow on iOS), `PlatformFont` (NSFont, UIFont), and `PlatformView` (NSView, UIView);
  - `PlatformApplication` answers the application-wide questions shared code asks: `keyWindow`, `mainWindow`, `isActive`, `didBecomeActiveNotification`, and `didResignActiveNotification`.
    On the Mac each is the AppKit expression the code used before (`NSApp.keyWindow`).
    On iOS there is no key or main window to name yet, so those two answer nil, and "active" means in the foreground;
  - `PlatformControlStyles` gives `checkboxToggleStyle()` (a checkbox on the Mac, a switch on iOS) and `radioGroupPickerStyle()` (a radio group on the Mac, an inline list on iOS).

## The five kinds of Mac change
<!-- id: five-kinds-mac-change; keys: mac-projection, #if os(macOS), typealias, toggleStyle, pickerStyle, equivalences; src: Scripts/ios/mac-projection.py, Makefile, TextMouth/Platform/PlatformTypes.swift, TextMouth/Platform/PlatformApplication.swift, TextMouth/Platform/PlatformControlStyles.swift, TextMouth/Platform/macOS/App/FrontWindowKind.swift, TextMouth/Platform/macOS/Views/Reader/WindowAccessor.swift, TextMouth/Views/AudioEditor/AudioEditorLauncher+Describe.swift, TextMouth/Services/LibrarySessionLease.swift, TextMouth/Services/ReadingStatsService.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/Views/ContentView.swift -->

The Mac app must compile what it compiled before.
Every change phase 0 made to a file the Mac compiles is one of these five, and nothing else is allowed without a reason a reviewer reads:

- **A move, unchanged.**
  A file only the Mac needs is moved into `Platform/macOS/`, with its text unchanged in the move.
- **A wrapper.**
  Existing Mac code is wrapped, as it stands, in `#if os(macOS)`, with iOS code in the `#else` branch.
  In a file both apps share, `import AppKit` becomes `import AppKit` under `#if os(macOS)` and `import UIKit` under `#else`.
- **A platform alias.**
  A type or an expression is named through a shared alias that is exactly the old one on the Mac: `PlatformWindow`, `PlatformFont`, `PlatformView`, and `PlatformApplication`'s members.
  A new alias goes in a shared file directly in `Platform/`, one alias to a line in the form `typealias PlatformX = NSX`.
- **A control-style helper.**
  `.toggleStyle(.checkbox)` is `.checkboxToggleStyle()`, and `.pickerStyle(.radioGroup)` is `.radioGroupPickerStyle()`.
  On the Mac each applies exactly the old style.
- **A split, unchanged.**
  When a file holds shared code and code only the Mac can compile, a whole declaration moves, unchanged, into a file of its own:
  - FrontWindowKind out of MenuCommands and WindowAccessor out of BookReaderWindowView, both into `Platform/macOS/`;
  - and AudioEditorLauncher's `describe(_:)`, which the shared audio editor models call on either app, into a shared extension, `Views/AudioEditor/AudioEditorLauncher+Describe.swift`.


`make mac-projection` checks this (see [Building TextMouth](../developer/building.md)).
It reads each changed file as the Mac compiles it, resolving `#if os(macOS)` the Mac's way and reading each alias and helper as the Mac expression it stands for, and prints what is left.
Its list of equivalences lives in `Scripts/ios/mac-projection.py`: a new helper in `Platform/` needs its line there, or its calls look like real changes.
One limit: it pools the removed lines of all the files, so a real deletion of a line such as `}` can count as moved when another file adds the same text.
The final review of phase 0 read the 13 files it listed with a stricter matcher and found nothing hidden.

In phase 0 the projection read 105 changed Swift files, of which 92 are unchanged for the Mac.
The other 13 are new shared code that only tests and aliases use (the portable XML tree and the three shared files directly in `Platform/`), the three declarations split out unchanged, which add only their imports and an `extension` line, and four closures reflowed around a `#if`.
Each of the four closures is a one-line default or argument made into a closure so that an `#if` has a place to sit (LibrarySessionLease's quit, ReadingStatsService's workspace notifications, LibraryViewModel's reveal in Finder, and ContentView's Quit): the Mac still runs the same statement.

## The iOS stand-ins and IOSUnavailable
<!-- id: ios-stand-ins-iosunavailable; keys: stub, Mac-only types, not available on iPhone, no-op, fallback, UIKit stand-in; status: incomplete; issues: FR34; src: TextMouth/Platform/iOS/IOSUnavailable.swift, TextMouth/Platform/iOS/Services/WatchedProcess+iOS.swift, TextMouth/Platform/iOS/Services/OrphanedConversionSweep+iOS.swift, TextMouth/Platform/iOS/Services/PackageFileEditing+iOS.swift, TextMouth/Platform/iOS/Services/BookTextEditor+iOS.swift, TextMouth/Platform/iOS/Services/BookManifestEditor+iOS.swift, TextMouth/Platform/iOS/Services/NowPlayingService+iOS.swift, TextMouth/Platform/iOS/Services/NSAccessibilityPriorityLevel+iOS.swift, TextMouth/Platform/iOS/App/FrontWindowKind+iOS.swift, TextMouth/Platform/iOS/Views/Reader/WindowAccessor+iOS.swift, TextMouth/Platform/iOS/Views/SilentKeyEquivalent+iOS.swift, TextMouth/Platform/iOS/Views/SwitchedWindowFocus+iOS.swift, TextMouth/Platform/iOS/Views/LogsInFinder+iOS.swift, TextMouth/Platform/iOS/Views/VoiceOverFocus+iOS.swift, TextMouth/Platform/iOS/Views/ReadOnlyTextArea+iOS.swift, TextMouth/Platform/iOS/Views/AudioEditor/AudioEditorLauncher+iOS.swift, TextMouth/Platform/iOS/Views/AudioEditor/AudioEditorWindowController+iOS.swift, TextMouth/Platform/iOS/Views/Recording/RecordingWindowController+iOS.swift, TextMouth/Platform/iOS/Models/FunctionKeyConstants+iOS.swift, TextMouth/Platform/iOS/Parsers/UIFontDescriptorSymbolicTraits+iOS.swift, TextMouth/Platform/iOS/Windows/PlatformWindow+iOS.swift, TextMouth/Services/RecordingCaptureBackend.swift, TextMouth/Services/AudioEditing/FFmpeg.swift, TextMouth/Services/ImportAudioConverter.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/Platform/macOS/Services/Export/WordDocExportWriter.swift -->

- Where shared code names a Mac-only type, the type has a stand-in in `Platform/iOS/` with the same name and the members shared code uses.
  The rule is that a name is never taken away from iOS: move a type to `Platform/macOS/` only with a stand-in for each name a shared file still uses.
- A stand-in does the least it safely can: it does nothing, answers "no", or throws.
  None traps.
  Mark it `@MainActor` where its Mac twin is.
- `IOSUnavailable` (`Platform/iOS/IOSUnavailable.swift`) is what a stand-in throws for work the iPhone app cannot do, and the log writes its English (`LogDescribing`).
  - Its own refusals are typed cases, each a whole localized sentence (2d38de070): `convertingThisKindOfFile`, `editingInAnotherApp`, `showingLogsInFinder`.
  - `feature(_:)` takes an English phrase that completes "… is not available on iPhone yet", for the callers that have not converted (ImportAudioConverter and three more).
- The stand-ins phase 1 inherits, by what they stand in for:
  - Helper programs: WatchedProcess throws `IOSUnavailable` from `run`, `runCapturingOutput`, and `runStreaming` and has no memory reading; OrphanedConversionSweep does nothing.
    The only document reading that needs textutil, and so a helper, is a compound-file Word document older than Word 6, which iOS therefore refuses with "Converting this kind of file isn't available on iPhone yet."
    Every other document format reads on iOS through TextMouth's own readers, which are shared code with no AppKit and no process: rich text and RTFD, Word 6 to Word 2003, Word, OpenDocument text, Word 2003 XML, MOBI, and KFX (see [Imports](state/imports.md)).
  - Editing in another app: PackageFileEditing's workspace opener throws, and BookTextEditor and BookManifestEditor start no session (`canEditText` is false).
  - Windows and keys:
    - WindowAccessor reports no window;
    - SilentKeyEquivalent takes no key;
    - SwitchedWindowFocus does nothing;
    - FrontWindowKind is always nil;
    - LogsInFinder says so with `showingLogsInFinder`;
    - `FunctionKeyConstants+iOS` gives the 72 function-key constants NSEvent.h defines, with its values, so config.json's key names (pageDown, f5, and the rest) read the same.
  - VoiceOver:
    - VoiceOverFocus and StandardVoiceOverFocus are hidden views;
    - VoiceOverAnnouncer posts `AccessibilityNotification.Announcement`, mapping the shared high and medium priorities to iOS's default and low to iOS's low (see [The announcement priorities on iOS](platforms-phone-interface.md));
    - `NSAccessibilityPriorityLevel` exists on iOS as an enum.
  - Text: ReadOnlyTextArea is a read-only, selectable `UITextView` with the Mac's label.
  - Recording and editing audio: the Record window and audio editor controllers and the audio editor launcher do nothing; the capture backend's `start` throws `IOSUnavailable` for "Recording"; FFmpeg's `run` throws that ffmpeg is missing.
  - Now Playing: audio-device queries answer "no device", and the device listeners are never installed.
  - Smaller ones: PDF text reading's bold and italic traits (`UIFontDescriptorSymbolicTraits+iOS`), and `isMainWindow` on UIWindow.
- Some Mac-only work has no stand-in file, only an `#else` branch where it is called:
  - the quit hold and the memory guard's alert and quit do nothing on iOS;
  - opening TextMouth again throws `IOSUnavailable`;
  - Word 97-2003 export (`WordDocExportWriter`) is left out of the list of export writers;
  - and the file and folder panels (DAISY folder import, OPML import, the data directory's folder chooser, Export's destination, and the text input's open-in-editor action) are empty branches.

## The portable XML tree
<!-- id: portable-xml-tree; keys: XMLDocument, XPath, XMLParser, SwiftSoup, Tidy, differential test, stack size; src: TextMouth/Parsers/PortableXML.swift, TextMouth/Parsers/PortableXMLPath.swift, TextMouth/Parsers/PortableXMLBuilder.swift, TextMouth/Parsers/MarkupGuard.swift, TextMouth/Parsers/EPUBParser.swift, TextMouth/Platform/iOS/Parsers/XMLTree+iOS.swift, TextMouthProductionTests/PortableXMLDifferentialTests.swift, TextMouthProductionTests/PortableXMLCorpus.swift -->

The EPUB, feed, and OPML readers walk Foundation's `XMLDocument`.
The EPUB reader reads its package document, NCX, and page list through `XMLElementIndex`, which uses only the tree's `children` and `localName`; the rest search it with XPath.
See [Shared helpers: readers and markup guards](shared-helpers-parsers.md).
iOS's Foundation has only the streaming `XMLParser`.
So phase 0 added a portable tree that has the part of the interface those readers use, and gave it Foundation's names on iOS, so the reader files compile for iOS as they are.

- `Parsers/PortableXML.swift` holds the classes (`PortableXMLDocument`, `PortableXMLElement`, and `PortableXMLNode`).
  The tree is read-only: its name, local name, prefix, namespace, kind, level, string value, attributes, children, and `rootElement()`, `attribute(forName:)`, and `nodes(forXPath:)`.
- `Parsers/PortableXMLPath.swift` is the XPath subset the readers use: an optional `//`, steps that are `*` with any number of `[local-name()='x']`, `[@a]`, and `[@a='v']` predicates.
  Anything else throws `PortableXMLError.unsupportedXPath`.
- `Parsers/PortableXMLBuilder.swift` builds the tree with no recursion.
  A strict reader runs on Foundation's `XMLParser`.
  A lenient reader, used only when Tidy is asked for and the strict reading fails, runs on SwiftSoup's XML parser, which it reaches only through `MarkupGuard.parseXML(_:baseURI:deepestNesting:)` with `deepestNesting` set to `PortableXMLDocument.maximumDepth`, 512.
  The guard counts the depth from the bytes before SwiftSoup builds anything and measures the parsed tree again afterwards, so markup nested deeper never becomes a tree of SwiftSoup's own, whose recursion would overflow the stack of an import.
  See [Shared helpers: readers and markup guards](shared-helpers-parsers.md).
  Either layer's refusal is `PortableXMLError.tooDeep`, and a document with too many tags or attributes throws `MarkupRefusal`.
  A tree deeper than 512 levels is refused, a document that declares its own entities is refused, and releasing a tree is iterative, so a hostile feed cannot overflow the stack or hang the app.
- The markup guard asks for a thread with a 490 MiB stack (`MarkupGuard.onLargeStack`, see Shared helpers in [Architecture](../../ARCHITECTURE.md)).
  - On the Mac this was tried: a 4 GiB stack was created and ran.
  - On an iPhone it is unverified.
    Apple's Threading Programming Guide gives the iOS main thread 1 MB and a secondary thread 512 KB, lets `pthread_attr_setstacksize` set the size before the thread starts, and says the memory is reserved when the thread is created and committed only as it is touched.
    It names no upper limit.
  - If iOS refuses the size at creation, the fallback steps down to 122 MiB, then 30 MiB, then the caller's own thread, as the Mac would.
  - If iOS accepts a size and cannot commit the pages when they are touched, that is memory pressure, not a refusal at creation, and the fallback does not catch it.
  - Only the type-check has run for iOS; a device or simulator check is still to do.
- `Platform/iOS/Parsers/XMLTree+iOS.swift` is the iOS-only file that makes `XMLDocument`, `XMLElement`, and `XMLNode` the portable classes.
  The Mac compiles the portable tree too, but only `PortableXMLDifferentialTests` uses it: no Mac code reads through it, so the Mac's own EPUB and feed reading is unchanged.
- `PortableXMLDifferentialTests` is what makes the tree trustworthy.
  It reads with Foundation's `XMLDocument` and with the portable tree, strictly and tidied, every XML document of every `.epub` under TestData (17 are tracked), the feed, OPML, and OPF fixtures there, and the small documents in `PortableXMLCorpus`.
  It compares every node's kind, level, name, local name, prefix, namespace, and string value, every attribute, and the answers to the XPath expressions the four reader files use.
  A scan test confirms every XPath string in them is one the comparison makes, and that at least 4 remain (the package, NCX, and page list no longer use XPath).
  The trees agree except where `knownDifferences` lists a difference, 16 in all, each with its reason and an evidence fragment the reported difference must contain; a listed difference that goes away fails the test.
  Some differences are accepted and hidden on purpose: attribute order within an element, `*` selecting a processing instruction in Foundation, the DTD node and XML declaration not being nodes, and the depth bound.
- `EPUBParser.updateOPFMetadata`, which writes a book's details into its EPUB, is wrapped in `#if os(macOS)`: its output must match what Foundation's pretty printer writes, and the portable tree does not write.
  On iOS it throws `IOSUnavailable` for "Saving a book's details into its EPUB file".

## Where the iPhone differs
<!-- id: where-iphone-differs; keys: fenced tests, shared tests, simulator, Core Foundation, XMLParser, Licenses folder, LAME licence; src: project.yml, TextMouthProductionTests/TextEncodingCatalogTests.swift, TextMouthProductionTests/EPUBStructureFailureTests.swift, TextMouthProductionTests/BundledLicenseTests.swift, TextMouthProductionTests/ImportRefusalTestSupport.swift; status: incomplete; issues: QN01 -->

The Mac's tests that the iPhone's unit bundle shares (see [Testing the iPhone app](../developer/testing-iphone.md)) found these.
Each is fenced with `#if os(macOS)` unless it says otherwise.

- iPhone lists keep titles as written whatever the leading-articles setting (`LeadingArticlesSortTests` 3), as `LibraryViewModel.leadingArticles` says.
- Core Foundation on iOS names GBK "cp936" and has 36 distinct encodings, not 37, so the IANA round trip fails (`TextEncodingCatalogTests` 2).
- `XMLParser`'s error code for a package document that is not XML is 111 on iOS and 4 on the Mac (`EPUBStructureFailureTests` 1).
- In the simulator a case-variant package fails with "file already exists" (`FolderDuplicateRepairTests` 1), cause unknown.
- The iPhone's runtime detection reads a launch request, by design (`PhoneLaunchRequestTests` 1).
- An import's refusal alert is titled "Nothing Imported" on iOS and has no title on the Mac, by design; `ImportRefusalTestSupport` expects each, for the 10 EPUB and DOCX refusal tests.
- Not a fence: `BundledLicenseTests` stays Mac-only, and the iPhone's Licenses folder (LAME, liblouis, SwiftSoup, ZIPFoundation, swift-cmark, and foliate-js) is checked by `BundledLicenseIOSTests`.
  An in-app notice naming the LGPL libraries, beside that folder, is not built (QN01).

## The iPhone app
<!-- id: iphone-app; keys: interface spec, hand-check list, phone code; src: TextMouth/Phone/PhoneSession.swift -->

The iPhone interface is built from research/IOS-INTERFACE-SPEC-2026-11-07.md, in the repository root, which holds the design and the hand-check list.
This section says how the code is put together.
It describes the code main holds: the interface of branch `ios/lead-1108`, and the fixes of branch `ios/fix-c-1108`.
The fixes are the sheet buttons ([PhoneSheetButton: where a sheet's buttons go](platforms-phone-interface.md)) and the full-contrast text ([PhoneTextStyle: the phone's text at full contrast](platforms-phone-interface.md)).
The Search in Book of branch `ios/search-1109` (see [Search in Book](platforms-phone-interface.md)) is merged into main with 0.4.4, with the focus requests and `PhoneSession.closeBook(id:)`.

### The frame
<!-- id: iphone-frame; keys: UIApplicationDelegate, scene delegate, magic tap, @main, life cycle, two readers; src: TextMouth/Platform/iOS/App/TextMouthAppDelegate.swift, TextMouth/Platform/iOS/App/TextMouthSceneDelegate.swift, TextMouth/Platform/iOS/App/MagicTapWindow.swift, TextMouth/Phone/PhoneAppModel.swift, TextMouth/Phone/PhoneSession.swift, TextMouth/Phone/PhoneLifeCycle.swift, TextMouth/Phone/ReaderPhoneHooks.swift -->

- The iPhone app runs on UIKit's life cycle, not SwiftUI's `App`.
  `TextMouthAppDelegate` is the `@main` type, and the app's one window is `MagicTapWindow`, a subclass that is the reliable home for the magic tap.
- `PhoneAppModel` holds everything the app keeps for as long as it runs: the library, the settings, the sounds, the session, the life cycle, and the navigation path.
  - `TextMouthAppDelegate.model` makes it once for the process, never once per scene.
  - The reason is that iOS may disconnect a scene while a book plays on behind a locked screen, and a second model would be a second library over the same files.
- `PhoneSession` owns the open readers, above the navigation.
  Leaving a reader's screen does not close the book.
  - At most two readers are open: the one on screen (`reader`), and one that goes on behind it (`listeningReader`).
- `PhoneLifeCycle` is the one place where every slice joins the system's calls.
  The scene delegate only calls it, and each slice registers what it does there, so no slice edits the delegate.
- The code is split by what it imports:
  - `TextMouth/Phone/` holds the plain types: the session, the models, the policies, and the words.
    They import no UIKit, both apps compile them, and the Mac's tests decide every case (the `phone` test area).
  - `TextMouth/Platform/iOS/` holds the UIKit and SwiftUI parts: the delegates, the views, and the services that touch the audio session and the screen.
- A reader reaches the phone through `ReaderPhoneHooks`.
  - These are closures that the phone fills and the shared reader calls at a few fixed points, each under `#if os(iOS)`.
  - Every default leaves the reader doing what it does on the Mac.

### PhoneLaunchRequest
<!-- id: phone-launch-request; keys: launch environment, UI test sandbox, simctl, SIMCTL_CHILD_, XCTestConfigurationFilePath, debug build; src: TextMouth/Phone/PhoneLaunchRequest.swift, TextMouth/App/TextMouthRuntime.swift, TextMouth/Platform/iOS/App/TextMouthSceneDelegate.swift, TextMouthProductionTests/PhoneLaunchRequestTests.swift, TextMouthiOSTests/IOSRuntimeTests.swift -->

- `PhoneLaunchRequest` is what a UI test, or a run in the simulator, asks of the app at launch through its environment.
  It has two variables.
  - `TEXTMOUTH_UI_TEST` set to exactly "1" gives the launch a library and preferences in a sandbox of its own, as a hosted test has.
    An empty or mistyped value leaves the app as it is.
  - `TEXTMOUTH_OPEN_AT_LAUNCH` set to an absolute path sends the app that file, as another app would send one at a cold launch.
    A relative path is ignored.
- It exists in debug builds only (0.4.3).
  - The whole of `PhoneLaunchRequest.swift` is inside `#if DEBUG`.
    So are its tests: `PhoneLaunchRequestTests` on the Mac, and the two tests of `IOSRuntimeTests` that read it.
  - The two places that read the environment are inside `#if DEBUG` on iOS: `TextMouthRuntime.detect`, which sets the sandbox (also inside `#if os(iOS)`, so no Mac code names the type), and the scene delegate, which opens the file.
    `PhoneLaunchRequestTests.testTheRequestIsReadOnlyInTheIPhonesDebugBuild` pins those reads, and that the Search in Book sheet reads no launch variable, and `testTheTypeIsCompiledIntoDebugBuildsOnly` that the type is debug only.
  - No launch variable fills the Search in Book field: the interface tests type on GitHub's runners.
  - A release build holds neither the type nor its two variable names, so no environment variable can steer it.
    A Release build for the simulator succeeded, and `strings` found none of the type or its variables in the Release binary and three in the Debug one.
    That was measured when the type had two variables, which it has again.
  - The Mac's Release build was not checked for it by a build.
    By reading, the Mac's Release code never names it.
- A UI test needs it because XCTest names its configuration (`XCTestConfigurationFilePath`) only in a process that hosts a test bundle, and the app a UI test drives does not host one.
  Without the sandbox, each test would find what the last one left in the app's real container.
- The book comes in the way a person's would: held until the library starts, copied by the import's copier, imported, and opened.
  The file is never moved or deleted.
- From a shell, `xcrun simctl launch` passes each variable with the prefix `SIMCTL_CHILD_` (see [Building TextMouth](../developer/building.md)).

### PhoneSession.readerMade
<!-- id: phone-session-reader-made; keys: Combine, PassthroughSubject, hand-over, listeningReader, silent gaps; src: TextMouth/Phone/PhoneSession.swift, TextMouth/Platform/iOS/Services/PhoneAudioSession.swift, TextMouth/Platform/iOS/Services/PhoneBackgroundWork.swift -->

- `PhoneSession.readerMade` is a Combine subject that sends each reader once, as the session makes it.
  It does so before anything can play the reader, and whichever slot the reader takes.
- The parts of the phone that give a reader its hooks join there: `PhoneAudioSession.attach`, and `PhoneBackgroundWork`'s hold for the life cycle.
- Before it, each part watched the two slots its own way, and one missed a slot.
  - A next book that goes straight behind the screen, as a hand-over does, got none of the hooks.
  - Its silent gaps then held nothing, and its pause in the background was never flushed.
- A new part that needs a hook on every reader subscribes to `readerMade`.
  It does not subscribe to the two slots.
- `PhoneBackgroundWork` also gives its hooks to the readers that were open before it ran, in either slot.

### ReaderPhoneHooks.unitInForce
<!-- id: reader-phone-hooks-unit-in-force; keys: lock screen, Control Center, skip commands, remote commands, navigation unit; src: TextMouth/Phone/ReaderPhoneHooks.swift, TextMouth/Phone/PhoneReaderModel.swift, TextMouth/Phone/PhoneDefaults.swift, TextMouth/Phone/PhoneRemoteCommandPolicy.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Platform/iOS/Services/PhoneAudioSession.swift, TextMouth/Services/NowPlayingService.swift -->

- `unitInForce` is a closure in `ReaderPhoneHooks`.
  It answers the unit that the phone's moves go by for this reader now: the book's own unit, else its kind's unit from Settings.
- `PhoneReaderModel` fills it.
  If the model or the reader is gone, it answers `PhoneDefaults.textNavigationUnitDefault`, the sentence.
- The lock screen and Control Center build their skip commands from it.
  - `ReaderViewModel.phoneRemoteCommandPolicy` calls `PhoneRemoteCommandPolicy(unitInForce:forward:backward:)`.
  - That initializer uses the unit in force when the phone has filled it in, and otherwise the Mac's shared skip units.
- Without it, a text book's lock screen offered 15 seconds while each press moved one sentence.
  That breaks the spec's rule that the lock screen never promises 15 seconds and moves a heading.
- The policy is read again when the book changes, when the settings model changes, and when the preferences change.
  Settings keeps each kind's unit in the preferences, not in the settings model.
  - `PhoneAudioSession.attach` merges the three and calls `phoneRemoteCommandsMayHaveChanged()`.
- On the Mac the closure is nil, and the shared units apply as they did.

### The crash guard
<!-- id: phone-crash-guard; keys: openingBookID, reopen, relaunch, crash on load, lock-screen Play, UserDefaults; src: TextMouth/Phone/PhoneSession.swift, TextMouth/Phone/PhoneLifeCycle+Reopening.swift, TextMouth/Phone/PhoneAppWording.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouthProductionTests/PhoneSessionTests.swift, TextMouthProductionTests/PhoneLifeCycleReopeningTests.swift -->

- `PhoneSession.openingBookKey` (`phone.openingBookID`) is a preference.
  It is written before a reader is made and removed once the reader's load ends.
  If it is still there at launch, the app ended while opening that book.
- The session reads and clears it in its initializer, which runs at launch, before any reader exists.
  - It keeps what it read in `openingBookAtLastEnd`.
  - `takeReopeningAtLaunch(fileOpened:)` acts on it at the first activation.
- It is not read at the first activation: a Play from the lock screen that wakes a killed app opens a book first and writes its own mark, which the first activation would take for a crash.
- The reopen keys are cleared with the guard (0.4.3), in the same step, as the session is made.
  - The three keys are `reopenBookKey`, `reopenShowsReaderKey`, and `reopenFromReadingListKey`.
    `PhoneSession.init` removes them when it finds a guard, with `forgetReopening(in:)`, the one place that lists them.
  - The reason: the guard is gone from disk at that moment.
    If the app ended again before its first activation, the next launch found no guard and keys still naming the book that crashed it, and reopened that book.
    Now it reopens nothing.
  - Without a guard, `init` leaves the keys for the first activation, which reopens the book as before.
- The verdict branch of `takeReopeningAtLaunch(fileOpened:)` keeps the keys of a book opened since.
  - It does not clear the keys either: a Play from the lock screen that opens a book before the first activation writes keys of its own.
  - The verdict only says "TextMouth closed while opening TITLE, so it wasn't reopened." and forgets the guard.
    The keys of the book opened since stand.
  - The tests:
    - `testTheReopenKeysGoWithTheCrashGuardWhenTheSessionIsMade`, `testTheVerdictLeavesTheKeysOfABookOpenedSince`, and `testTheReopenKeysStandWhenNoCrashGuardIsFound` in `PhoneSessionTests`;
    - and `PhoneLifeCycleReopeningTests`, whose crash test writes the keys beside the guard, before the session, and asserts the keys are gone after `reopenAtLaunch`.
  - Still open, and older than this change: `registerOpenBook` saves the book being opened as the last opened.
    If that save lands before a crash while opening a book, a lock-screen Play can open it, and the first activation then says it closed while opening that book while it plays.
- When the guard finds a crash, the book is not reopened, and the listener hears "TextMouth closed while opening TITLE, so it wasn't reopened."
  (`PhoneAppWording.closedWhileOpening`).
- A file opened at launch wins over reopening.
  A book that crashes on loading therefore cannot do so at every launch.
- A lock-screen Play that opens a book takes a hold on the app for the load ("Playing from the lock screen", through `PhoneSession.beginHold`), as going on to the next book does.

### PhoneScreenHolds
<!-- id: phone-screen-holds; keys: isIdleTimerDisabled, idle timer, screen sleep, auto-lock, keep awake; src: TextMouth/Phone/PhoneScreenHolds.swift, TextMouth/Platform/iOS/Services/PhoneScreenSleep.swift, TextMouthProductionTests/PhoneScreenHoldsTests.swift -->

- `PhoneScreenHolds` is the one keeper of the screen's sleep.
  Each owner takes a hold with `begin()`, which returns a closure that lets go.
  Letting go twice does nothing.
- The keeper tells its `apply` closure whether the screen should stay awake, once per change.
  The screen should stay awake while any hold is in force.
- `UIApplication.isIdleTimerDisabled` is one app-wide flag.
  - Two owners that each set it and then cleared it would let whichever let go first lock the screen for the other.
- `PhoneScreenSleep`, in `Platform/iOS/Services`, holds the one keeper, whose `apply` sets the flag.
  Nothing else sets the flag.
- The keeper imports no UIKit, so the Mac's tests decide every case.
