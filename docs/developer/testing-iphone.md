# Testing the iPhone app
<!-- id: testing-iphone-app; keys: iPhone tests, iOS tests, simulator tests, interface tests; src: -->

Part of [TextMouth's documentation](../../README.md).

The iPhone app is tested in two places: on the Mac's test host, for everything that does not need iOS, and in the iOS simulator, for what only iOS compiles.
See [The two apps and the platform folders](../architecture/platforms.md) for how the code is divided, and [Building TextMouth](building.md) for how the simulator is built.

Tests that act as a person does find what tests of the parts miss.

## The phone area
<!-- id: phone-area; keys: phone tests, Mac test host, areas.conf, test-area, iOS branches; src: Scripts/test/areas.conf, Scripts/test/run-area.py, Makefile, TextMouth/Phone/PhoneSession.swift, TextMouth/Phone/PhoneLaunchRequest.swift, TextMouth/Phone/PhoneBookSearch.swift, TextMouth/Phone/PhoneFocusRequests.swift, TextMouth/Phone/PhoneLifeCycle+Reopening.swift, TextMouthProductionTests/PhoneSessionTests.swift, TextMouthProductionTests/PhoneLaunchRequestTests.swift, TextMouthProductionTests/PhoneBookSearchTests.swift, TextMouthProductionTests/PhoneFocusRequestsTests.swift, TextMouthProductionTests/TranscriptSearchTests.swift, TextMouthProductionTests/PhoneLifeCycleReopeningTests.swift, TextMouthProductionTests/PhoneReaderModelTests.swift, TextMouthProductionTests/PhoneReaderControlsTests.swift, TextMouthProductionTests/PhoneErrorAlertPlanTests.swift, TextMouthProductionTests/PhonePreviewPauseTests.swift, TextMouthProductionTests/PhoneSpeechRefusalPresentationTests.swift, TextMouthProductionTests/IOSBranchTests.swift, TextMouthProductionTests/IOSInfoPlistTests.swift, TextMouthProductionTests/PhoneFontPolicyTests.swift -->

- The `phone` area of `Scripts/test/areas.conf` holds the iPhone app's tests as far as the Mac's test host can reach it.
  It has 60 classes of TextMouthProductionTests: the session, the models, the routes, the words, the policies, `IOSInfoPlistTests`, the iOS branches of shared code (`IOSBranchTests`), and the scan for fixed-size fonts (`PhoneFontPolicyTests`).
- Most of the iPhone's logic is in plain types under `TextMouth/Phone/` that import no UIKit, so this area decides nearly every rule: `PhoneSessionTests`, `PhonePassagePolicyTests`, `PhoneEscapePolicyTests`, `PhoneScreenHoldsTests`, `PhoneLaunchRequestTests`, and the rest.
- Three of the 60 classes are for the error alert, Speech Stopped, and the preview's pause: `PhoneErrorAlertPlanTests`, `PhonePreviewPauseTests`, and `PhoneSpeechRefusalPresentationTests`.
  `Scripts/test/areas.conf` lists them in `phone` only.
- Search in Book (0.4.4) is tested in the hosted suite by:
  - `PhoneBookSearchTests` (12 tests):
    - the words,
    - that the shared words are the Mac's own,
    - the one-second typing pause,
    - a text result's row (a percent) and a transcript's (a time),
    - a result with no heading,
    - that a row says what the Mac's row says,
    - an empty source, and
    - the model searching, saying the count once, saying "No matches" and an invalid pattern, and saying nothing when cancelled.
  - `PhoneFocusRequestsTests` (6 tests):
    - an undisturbed request posts once;
    - a landing on any kind of reader control cancels the waiting request, with every control kind tried so that one whose landing fails to cancel is named;
    - a landing elsewhere (Back, the title) cancels nothing;
    - a landing cancels every request waiting;
    - a request made after a landing stands;
    - a landing with nothing waiting is harmless.
  - Additions to
    - `PhoneReaderModelTests` (an untranscribed audiobook says why without telling anyone to transcribe, the Mac's words still name the command, a text book's jump),
    - `PhoneReaderControlsTests` (the control's words, and `testTheGridRowsKeepOrderAndPairs`),
    - `PhoneFoundationTypesTests`,
    - `PhoneLaunchRequestTests` (the third variable, the reads and the debug-only type),
    - `PhoneSessionTests` (four tests of `closeBook(id:)`), and
    - `TranscriptSearchTests` (`goToSearchResult` takes the transcript's move for a transcript and the other move for any other book).

    The Mac's pinned sentences in `TranscriptSearchTests` still call with the defaults.
  - These classes run in the full suite, and `PhoneBookSearchTests` and `PhoneFocusRequestsTests` are in the `phone` area too.
- `PhoneLaunchRequestTests` is inside `#if DEBUG`, with the type it tests, so a Release test run does not have it.
  `PhoneSessionTests` pins the reopen keys that go with the crash guard (`testTheReopenKeysGoWithTheCrashGuardWhenTheSessionIsMade`, `testTheVerdictLeavesTheKeysOfABookOpenedSince`, and `testTheReopenKeysStandWhenNoCrashGuardIsFound`).
  `PhoneLifeCycleReopeningTests` checks from the life cycle that the crashed book's key is gone after the verdict (see The crash guard in [The two apps and the platform folders](../architecture/platforms.md)).

### Running the phone area
<!-- id: running-phone-area; keys: make test-area, run-area.py, train request, os(iOS), Mac build; src: Scripts/test/run-area.py, Scripts/test/areas.conf, Makefile -->

- It runs like any area: `make test-area AREAS="phone"`, `Scripts/test/run-area.py phone`, or a train request with `--areas phone` (see [Reusable test tools](testing-tools.md)).
- It tests the Mac's build.
  A rule written under `#if os(iOS)` that has no plain type behind it is not reached here.

## The two iOS test targets
<!-- id: two-ios-test-targets; keys: iOS test bundles, UI tests, interface tests, accessibility audit, Search in Book; src: project.yml, TextMouthiOSTests/PhoneControlButtonTests.swift, TextMouthiOSTests/IOSRuntimeTests.swift, TextMouthiOSTests/PhoneValueRowTests.swift, TextMouthiOSTests/PhoneTextFieldScalingTests.swift, Scripts/agents/ios_ui_tests.py, TextMouthiOSUITests/ReaderUITests.swift, TextMouthiOSUITests/LibraryUITests.swift, TextMouthiOSUITests/ScreenOrderUITests.swift, TextMouthiOSUITests/LargeTextUITests.swift, TextMouthiOSUITests/SearchUITests.swift, TextMouthiOSUITests/PlaybackUITests.swift, TextMouthiOSUITests/TextMouthUITestCase.swift, TextMouth/Phone/PhoneLaunchRequest.swift, TextMouth/Platform/iOS/Views/PhoneSheetButton.swift, TextMouth/Platform/iOS/Views/PhoneTextStyle.swift, TextMouthProductionTests/PhoneLaunchRequestTests.swift, Scripts/agents/run-ios-ui-tests.py, Scripts/agents/tests/test_run_ios_ui_tests.py, .github/workflows/tests.yml -->

- Both are in the committed `TextMouthiOS` scheme, which runs them together in the iOS simulator.
  The Mac's schemes do not run them.
  GitHub runs both in one `xcodebuild` run (see [Tests on GitHub Actions](testing-github.md)), so this Mac needs no simulator to run them.
- `TextMouthiOSTests` is a unit-test bundle hosted in the iPhone app.
  It has 46 tests of its own, and also compiles 189 of the Mac's test files, listed by path under its `sources` in `project.yml`, so that one file serves both bundles: about 2,330 tests in all.
  Neither the Mac's nor the iPhone's tests play, speak, or record anything (`test_run_ios_ui_tests.py` reads every file the target compiles, its own folder and the shared files, and fails if one names an audio framework, a player, or a recorder), so they need no sound variable.
  The check reads names (`SOUND_PATTERN` in `Scripts/agents/ios_ui_tests.py`), so it does not see a call whose name starts with another word, such as `startSpeaking(` or `startPlayback(`.
  A bare `record(` (the feed store's and the log's), `continuation.resume(`, and `resumeIndexWrites(` are not sound.
  Neither is a call on a `…Wording` type (`PhoneReaderWording.playHint(movingBy:)`), which only returns the text a control says; the same name on anything else still counts.
  What it does catch is the model types a unit test would reach one through (`ReaderViewModel`, `PhoneAppModel`), so add a pattern for those words if a unit test ever takes a bare model.
  The one exception is a helper `func makeReader() -> ReaderViewModel`, the only place `ReaderViewModel` may appear, since the stopped reader the Go To, Search, and Sleep Timer sheets need is built there (Q11).
  The scanner cuts the first such helper out by its braces and reads it with the whole rule except that one name, so a call in it that plays, speaks, or resumes is still refused, and every other file is read with the whole rule.
  - `PhoneControlButtonTests` (12 tests) tests the reader's UIKit control: its words, its traits, that it is one element, its actions, and its smallest height of 44 points.
  - `IOSRuntimeTests` (4 tests) tests the iOS runtime: that a hosting process runs in a sandbox, that a UI test's launch request does too, that without the request the home is the app's container, and that the library lives in Application Support.
    The two tests that read `PhoneLaunchRequest` are inside `#if DEBUG`, as the type is, so a Release test run has 2 of the 4.
  - `BrailleLibraryTests` (10 tests) call the braille library in the iPhone app with the bundled tables, and `BrailleBatchLimitsTests` (5) pin that the iPhone's batches read their limits, tables folder, and clock from `BrailleTranslator.tool`, as the Mac's do.
    `InProcessEngineTests` (16 tests) and the braille tests the iPhone shares with the Mac run on both platforms, fenced only where they differ; `BrailleDamagedInputTests` (4) run on GitHub only.
  - `PhoneTextFieldScalingTests` (5 tests, A11Y-GOTO) hosts the real Go To, Search, Sleep Timer, and Book Information sheets over a stopped reader, and checks that the font of each text field has a text style and grows at least twice at the largest text size.
    A fifth test, a canary, fails when SwiftUI turns UIKit's `adjustsFontForContentSizeCategory` on, which is when the accepted audit finding can go (see [The text fields' accepted finding](testing-iphone-audit.md#the-text-fields-accepted-finding)).
  - `PhoneValueRowTests` (3 tests) measures `PhoneValueRow` at the 12 Dynamic Type sizes: stacked at the 5 accessibility sizes, side by side at the 7 others (see PhoneTextStyle in [The two apps and the platform folders](../architecture/platforms-phone-interface.md)).
    A third test checks that SwiftUI still has 5 and 7.
- `TextMouthiOSUITests` is an XCUITest bundle that drives the app from outside, in the simulator.
  It has 37 tests, of which 13 press Play or type (the 6 of `PlaybackUITests`, 6 of the 7 of `SearchUITests`, all but its empty sheet's, and the Search test of `LargeTextUITests`) and run only where sound is allowed, on GitHub's runner (see In the simulator, sound tests run on GitHub only, below).
  - Each test launches the app with a library of its own and, usually, a public-domain book sent to it: Alice's Adventures in Wonderland, Project Gutenberg #11, from `TestData/alice.epub` (see PhoneLaunchRequest in [The two apps and the platform folders](../architecture/platforms.md)).
  - `ReaderUITests` (4 tests): the reader's order, its first values, 44-point controls, and its audit.
  - `LibraryUITests` (4 tests): the Library's words and order, empty and with a book, and the audit of each.
  - `ScreenOrderUITests` (11 tests): the order of the Add to Library sheet, Settings, Bookmarks, Headings, Go To, Sleep Timer, the Voice sheet, Book Information, and the navigation unit's choice, with the audit of each.
  - `LargeTextUITests` (4 tests): see [LargeTextUITests](testing-iphone-audit.md#largetextuitests).
  - `SearchUITests` (7 tests, 0.4.4; typed; see [SearchUITests](testing-iphone-audit.md#searchuitests)).
  - `PlaybackUITests` (6 tests): see [PlaybackUITests](testing-iphone-audit.md#playbackuitests).
  - `BrailleUITests` (1 test, DR34): a BRF sent to the app opens in the reader on its print, translated in the app, with nothing pressed or typed.
  - What iOS shows for a button in `.cancellationAction` is in `PhoneSheetButton.swift` and in [The two apps and the platform folders](../architecture/platforms-phone-interface.md).
  - They read what VoiceOver would be given: each element's label, value, and traits, in the order of the accessibility tree, as a depth-first walk of one snapshot.
  - No wait lasts longer than 60 seconds.
- To run them, use the `TextMouthiOS` scheme with the build rules in [Building TextMouth](building.md): the iPhone 17 simulator, the one build folder, `Scripts/agents/run_locked.py`, and a new result-bundle name for each pass.
  A test run has the shape `xcodebuild test -project TextMouth.xcodeproj -scheme TextMouthiOS -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData-ios.noindex`, and `-only-testing:TextMouthiOSTests` or `-only-testing:TextMouthiOSUITests` runs one bundle.

## In the simulator, sound tests run on GitHub only
<!-- id: simulator-sound-tests-run-github; keys: UI sound, no audio on the Mac, keyboard clicks, GitHub runner, requireSound; src: TextMouthiOSUITests/TextMouthUITestCase.swift, Scripts/agents/run-ios-ui-tests.py, Scripts/agents/tests/test_run_ios_ui_tests.py, project.yml, .github/workflows/tests.yml, TestData/alice.epub -->

The rule:

- The interface tests press Play and type, as a person does.
  That makes sound, since the simulator plays through the Mac's speakers and the keyboard clicks, so such a test runs only where nobody listens: on a GitHub runner.
- A test that makes sound runs only when the environment variable `TEXTMOUTH_UI_SOUND` is 1.
  `Scripts/agents/run-ios-ui-tests.py` is the one place that sets it (as `TEST_RUNNER_TEXTMOUTH_UI_SOUND`, which `xcodebuild` hands to the test runner without the prefix), and it runs only on the runner.
  Anywhere `GITHUB_ACTIONS` is not `true`, it stops at once with exit status 2, before it reads a request, writes a file, or starts a simulator.
  Never run it on this Mac; to run the interface tests, ask a GitHub run for them.
  The workflow, the other scripts, and the Mac never set it: `test_run_ios_ui_tests.py` fails if another tracked file names it, if the workflow sets it, or if a test file presses Play or types by hand.
- `TextMouthUITestCase` decides in one place.
  `requireSound(_:)` skips the test, saying why, unless the variable is 1.
  The helpers that make sound (`pressPlay`, `pressPause`, `startSleepTimer`, `type`) call it first themselves, so a test that forgot still makes no sound on this Mac.
- `openReaderSheet(_:titled:waitingFor:under:)` opens a reader sheet from its control, and looks for a control that isn't on the reader under the Book Actions menu (`under`), which it opens first: Sleep Timer, Voice, Book Info, and Export this book are items of it (FR51).
  The Sleep Timer is on the reader only while a timer runs, so a test asks that it exists then and not before, and `PlaybackUITests.value(of:)` reads "" for a control that has left.
  A test that makes sound calls `requireSound` before it launches anything, so a skip is quick.
- On this Mac those tests skip.
  Do not set the variable in a shell here.
  Nothing records audio anywhere.
- The unit tests (`TextMouthiOSTests`) make no sound and have no sound variable.
  They run in the same xcodebuild run as the interface tests, on GitHub; no agent runs a simulator on this Mac.
- A test that needs a book is sent one at launch (`TEXTMOUTH_OPEN_AT_LAUNCH`) and finds Play unpressed.
- Never play Ogg through Apple's frameworks, here or on the runner; the tests use the EPUB `TestData/alice.epub`.
- No test may trap, hang, or use a microphone, and every wait has a limit.
- VoiceOver does not run in the simulator.
  XCUITest's element queries stand in for it for labels, values, traits, and order, and the audit for missing labels, hit areas, and Dynamic Type.
  Everything that sounds or needs VoiceOver is checked only on a phone, with the spec's hand-check list.

## Type-checks and tests
<!-- id: type-checks-tests; keys: typecheck-tests, typecheck-ios, typecheck-mac, swiftc, SwiftPM, heavy-work lock, build train; src: Makefile, Scripts/ios/typecheck.py, Scripts/agents/run_locked.py, Scripts/agents/heavy_lock.py, project.yml, TextMouthProductionTests/PhoneSettingsVoicePreviewTests.swift, TextMouthProductionTests/PhoneVoiceModelTests.swift -->

- `make typecheck-ios` and `make typecheck-mac` build the app's sources alone, in a package of their own.
  They compile no test file.
- `make typecheck-tests` compiles the Mac's hosted tests too.
  It builds the app and `TextMouthProductionTests` (the folder of that name and the files of `TextMouthTests/Sources/Tests` that `project.yml` lists for it) with SwiftPM and `swift build --target TextMouthProductionTests`.
  It links no test bundle and runs nothing.
  Run it, once for a batch and after committing, before asking the build train for a build.
  `make typecheck-tests REF=<commit>` checks that commit from any worktree.
  It takes the heavy-work lock itself, so never wrap it in `run_locked.py`.
  A run takes about four minutes when most test files compile again, six from a cold start, and seconds when nothing changed, after the wait for the lock.
  Its errors read as the train's do (file, line, message), and its summary is in `build/typecheck/results/` of the main checkout.
- `TextMouthiOSUITests` can be type-checked on this Mac without the iOS runtime, because Xcode's iPhone Simulator SDK and its XCTest are enough (`xcrun --sdk iphonesimulator --show-sdk-path`).
  It touches nothing and builds no app.
  Run it under the heavy-work lock:
  - `python3 -I Scripts/agents/run_locked.py NAME xcrun swiftc -typecheck -sdk $P/SDKs/iPhoneSimulator26.0.sdk -target arm64-apple-ios26.0-simulator -F $P/Library/Frameworks -I $P/usr/lib -swift-version 5 TextMouthiOSUITests/*.swift`, with
  - `P=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer`.

  It would have found the unterminated string of run 42947183810 in seconds.
  `make typecheck-ios` does not cover these files, nor `TextMouthiOSTests`: it builds the app's sources alone.
- `make typecheck-ios-tests` compiles `TextMouthiOSTests` for iOS, with the Mac test files it shares (see Mac tests the iPhone shares, below), and the interface bundle `TextMouthiOSUITests`, so the `swiftc` step above is not needed when it runs.
- So, apart from those two targets and that command, a compile error in a test file is found only by a build that builds the tests.
  - For `TextMouthProductionTests`, `make typecheck-tests` finds it before a train does, and the build train finds it otherwise.
  - For `TextMouthiOSTests` and `TextMouthiOSUITests`, `make typecheck-ios-tests` does.
- After changing a test file, run `make typecheck-tests` before requesting a train for it.
  Do not take a clean `make typecheck-mac` or `make typecheck-ios` as a sign that its tests compile.

## Mac tests the iPhone shares
<!-- id: mac-tests-iphone-shares; keys: shared test files, fence, os(macOS), census, RunLoopWaiting, typecheck-ios-tests, typecheck-tests-census, unit bundle; src: project.yml, Makefile, Scripts/ios/typecheck.py, Scripts/agents/ios_ui_tests.py, Scripts/agents/tests/test_run_ios_ui_tests.py, TextMouthProductionTests/RunLoopWaiting.swift, TextMouthProductionTests/AudioTestFixtures.swift, TextMouthProductionTests/BrailleFileCodeTests.swift, TextMouthProductionTests/SoftHyphenEffectTests.swift, TextMouthProductionTests/LeadingArticlesSortTests.swift, TextMouthProductionTests/TextEncodingCatalogTests.swift, TextMouthProductionTests/EPUBStructureFailureTests.swift, TextMouthProductionTests/FolderDuplicateRepairTests.swift, TextMouthProductionTests/PhoneLaunchRequestTests.swift, TextMouthProductionTests/LanguagePackTests.swift -->

A Mac test file the iPhone can run is listed by path in the `sources` of `TextMouthiOSTests` in `project.yml`, so one file serves both bundles and the Mac suite compiles and runs the same classes.
Its helpers are listed beside it (`DOCXTestPackages`, `CollectionTestSupport`, `ImportDecisionTestSupport`, `LibraryIndexTestSupport`, `ImportRefusalTestSupport`, `DamagedFileTestSupport`, and `RunLoopWaiting.swift`).
`RunLoopWaiting.swift` holds `spinMainRunLoop(for:)` and `eventually(within:_:)`, split out of `AudioTestFixtures`, whose other waits name an `AVPlayerItem` and so cannot be shared.
A test that makes sound is never shared: the check in `test_run_ios_ui_tests.py` fails on one, and has a break test with a shared file that plays.

- **A fence** is `#if os(macOS)` around a test the iPhone really differs on, so the Mac still runs it.
  Eight tests are fenced, in `LeadingArticlesSortTests`, `TextEncodingCatalogTests`, `EPUBStructureFailureTests`, `FolderDuplicateRepairTests`, and `PhoneLaunchRequestTests`.
  Each difference and its reason is under Where the iPhone differs in [The two apps and the platform folders](../architecture/platforms.md).
  `BundledLicenseTests` and `UncheckedConcurrencyPolicyTests` (it scans the repository) are left Mac-only.
- **The export classes** (FR31): the Mac's writer and walker tests are shared, so the iPhone shows its writers make the Mac's files:
  - `HTMLExportWriterTests`, `MarkdownExportWriterTests`, `RTFExportWriterTests`, and `EPUBExportWriterTests` with its navigation and round-trip classes;
  - `ExportDocumentWalker*Tests`, `ExportDeepChapterWalkerTests`, `BrailleExportWriterTests`, and `BookExportDeliveryTests`, which runs the iPhone's coordinated copy on both;
  - their helpers, `MarkdownMarkerSupport`, `WordsInOrderSupport`, `EPUBRoundTripSupport`, `DeepMarkdown`, and `StackProbe`;
  - `PhoneExportFolderTests`, `PhoneExportMemoryCheckTests`, `PhoneExportOfferTests`, `PhoneExportQuestionTests`, and `PhoneExportSpeechTests` (the spoken audio rows, the bar, the card, the task's mirror, Share…) are shared too;
  - the speech export's own suites and the session's tests (`SpeechExportDialogTests`) are Mac-only: their fakes make audio buffers, and the iPhone's unit bundle takes no file that names `AVAudio` or `AVSpeech`;
  - the Mac-only parts of a shared class are fenced with `#if os(macOS)` (the RTF tests' textutil reads, the braille tests' Mac-table halves).
  - Not shared, because they build a library with `makeIntegrationWorld`: `PhoneExportModelTests`, `BookExportServiceTests`, `BookExportConversionTests`, `BookExportConvertToTests`, and `BookExportNestingTests`.
  - The iPhone's own: `PhoneExportSheetTests` (the real sheet hosted over a book, no export run), `PhoneBrailleExportOptionsTests`, and `PhoneExportPeakMemoryTests`.
- **The peak-memory test** exports a large fixture through each writer and logs a `PHONE_EXPORT_PEAK writer=… fixture=… text=… peak=… factor=… figure=…` line for each, and one `writer=engine fixed=…` line for the braille engine's tables.
  It runs only on GitHub's runner and fails past twice a writer's figure (see The memory check in [Exports on the iPhone](../architecture/state/exports-iphone.md)); read the lines in the run's log before raising a figure.
- **`ExportUITests`** (4 tests, on GitHub): the sheet's order and audit, with the spoken audio rows read and audited; the Library row's Export…; Convert to, an export, and Share…; and the largest text size, with the braille choices opened while the Braille code row is scrolled away.
  The system's folder picker can't be driven, so the one test that writes launches with `TEXTMOUTH_EXPORT_TO`, an absolute path the sheet uses as its folder.
  The variable is read in Debug builds alone (`#if DEBUG`), as `TEXTMOUTH_UI_TEST` is.
- **The FFmpeg classes** (the helper's protocol and hostile-file ones too), `InProcessEngineTests`, and `RunningClockTests` are shared, so each shows that the iPhone makes the Mac's streams, books, and sentences.
- **The interface text:** `InterfaceTextShippedPackTests` is shared, so GitHub checks that the iPhone app's pack gives the catalog's text and that the app ships no table of Apple's ([what the apps ship](localization.md#what-the-apps-ship)).
- **The own readers:** `OwnAudioImportTests` and `OwnAudioSampleSupport` are shared, and name no audio framework, which the iPhone bundle forbids.
  The reads that need one (`AVAudioFile`, afinfo) are in `OwnAudioConvertedFileSupport.swift`, Mac-only, so the iPhone checks a converted file's length with `AudioMediaProbe`, within 1 ms of its frames over its rate; the Mac also checks its codec, depth, and samples.
  `OwnAudioMemoryWatchTests` script the floor.
  `FFmpegInAppTests` is the iPhone's own (see [FFmpeg in the iPhone app](testing-formats.md#ffmpeg-in-the-iphone-app)).
- **The type-checks:** `make typecheck-ios-tests` compiles the unit bundle and its shared files for iOS, and takes the lock itself.
  Run it with `make typecheck-tests` before a train request that changes a shared test file.
  `make typecheck-tests-census` is the slow count of which Mac tests compile for the iPhone, written to `census.md` under `build/typecheck/results/`.
  At its last run, of 816 test classes (12,484 tests), 190 (2,501 tests) compiled and named no sound, 552 (8,799 tests) could with work, and 74 (1,184 tests) had 5 or more errors of their own.
  The main reasons are a file that does not compile (mostly Mac view and window helpers), AppKit, sound, and a Mac-only type (`NSWindow`, `Process`).
- **On GitHub,** a request naming the phone area runs both iPhone bundles.
  A class only the iPhone has can be named alone; a shared class stays in the request's `classes` for the Mac and is added to the iPhone's, so it runs on both.
- **The planner** counts a unit test as 0.05 seconds (`SECONDS_PER_TEST` in `Scripts/agents/ios_ui_tests.py`) and an interface test as 25, from a run in which about 1,979 unit tests took 71 seconds, so a shared class is dealt out by its size and not as one second.

