# Testing the iPhone app
<!-- id: testing-iphone-app; keys: ; src: -->

Part of [TextMouth's documentation](../../README.md).

The iPhone app is tested in two places: on the Mac's test host, for everything that does not need iOS, and in the iOS simulator, for what only iOS compiles.
See [The two apps and the platform folders](../architecture/platforms.md) for how the code is divided, and [Building TextMouth](building.md) for how the simulator is built.

Tests that act as a person does find what tests of the parts miss: the first iPhone test to set End of heading at a book's opening found a bug that the Mac's unit tests never met.

## The phone area
<!-- id: phone-area; keys: ; src: TextMouthProductionTests/PhoneSessionTests.swift, TextMouthProductionTests/PhoneLaunchRequestTests.swift, TextMouthProductionTests/PhoneBookSearchTests.swift, TextMouthProductionTests/PhoneFocusRequestsTests.swift, TextMouthProductionTests/TranscriptSearchTests.swift -->

- The `phone` area of `Scripts/test/areas.conf` holds the iPhone app's tests as far as the Mac's test host can reach it.
  It has 56 classes of TextMouthProductionTests: the session, the models, the routes, the words, the policies, `IOSInfoPlistTests`, and the iOS branches of shared code (`IOSBranchTests`).
- Most of the iPhone's logic is in plain types under `TextMouth/Phone/` that import no UIKit, so this area decides nearly every rule: `PhoneSessionTests`, `PhonePassagePolicyTests`, `PhoneEscapePolicyTests`, `PhoneScreenHoldsTests`, `PhoneLaunchRequestTests`, and the rest.
- Three of the 56 classes are for the error alert, Speech Stopped, and the preview's pause: `PhoneErrorAlertPlanTests`, `PhonePreviewPauseTests`, and `PhoneSpeechRefusalPresentationTests`.
  `Scripts/test/areas.conf` lists them in `phone` only.
- Search in Book (0.4.4) is tested in the hosted suite by:
  - `PhoneBookSearchTests` (12 tests): the words, that the shared words are the Mac's own, the one-second typing pause, a text result's row (a percent) and a transcript's (a time), a result with no heading, that a row says what the Mac's row says, an empty source, and the model searching, saying the count once, saying "No matches" and an invalid pattern, and saying nothing when cancelled.
  - `PhoneFocusRequestsTests` (6 tests): an undisturbed request posts once; a landing on any kind of reader control cancels the waiting request, with every control kind tried so that one whose landing fails to cancel is named; a landing elsewhere (Back, the title) cancels nothing; a landing cancels every request waiting; a request made after a landing stands; a landing with nothing waiting is harmless.
  - Additions to `PhoneReaderModelTests` (an untranscribed audiobook says why without telling anyone to transcribe, the Mac's words still name the command, a text book's jump), `PhoneReaderControlsTests` (the control's words, and `testTheGridRowsKeepOrderAndPairs`), `PhoneFoundationTypesTests`, `PhoneLaunchRequestTests` (6 tests: the third variable, the reads and the debug-only type), `PhoneSessionTests` (four tests of `closeBook(id:)`), and `TranscriptSearchTests` (`goToSearchResult` takes the transcript's move for a transcript and the other move for any other book).
    The Mac's pinned sentences in `TranscriptSearchTests` still call with the defaults.
  - These classes run in the full suite.
    `PhoneBookSearchTests` and `PhoneFocusRequestsTests` are not listed in an area of `Scripts/test/areas.conf` at the merge, so `run-area.py` does not run them.
- `PhoneLaunchRequestTests` is inside `#if DEBUG`, with the type it tests, so a Release test run does not have it.
  `PhoneSessionTests` pins the reopen keys that go with the crash guard (`testTheReopenKeysGoWithTheCrashGuardWhenTheSessionIsMade`, `testTheVerdictLeavesTheKeysOfABookOpenedSince`, and `testTheReopenKeysStandWhenNoCrashGuardIsFound`), and `PhoneLifeCycleReopeningTests` checks from the life cycle that the crashed book's key is gone after the verdict (see The crash guard in [The two apps and the platform folders](../architecture/platforms.md)).
- It runs like any area: `make test-area AREAS="phone"`, `Scripts/test/run-area.py phone`, or a train request with `--areas phone` (see Reusable test tools, above).
- It tests the Mac's build.
  A rule written under `#if os(iOS)` that has no plain type behind it is not reached here.

## The two iOS test targets
<!-- id: two-ios-test-targets; keys: ; src: TextMouthiOSUITests/LargeTextUITests.swift, TextMouthiOSUITests/PlaybackUITests.swift, TextMouthiOSUITests/SearchUITests.swift, TextMouth/Phone/PhoneLaunchRequest.swift, TextMouthProductionTests/PhoneLaunchRequestTests.swift -->

- Both are in the committed `TextMouthiOS` scheme, which runs them together in the iOS simulator.
  The Mac's schemes do not run them.
  Since November 11, 2026 GitHub runs both in one `xcodebuild` run (see Tests on GitHub Actions, above), so this Mac needs no simulator to run them.
- `TextMouthiOSTests` is a unit-test bundle hosted in the iPhone app.
  It has 19 tests, which make no sound (they play, speak, and record nothing; `test_run_ios_ui_tests.py` fails if a file of the folder names an audio framework, a player, or a recorder), so they need no sound variable.
  The check reads names, so it does not see a call whose name starts with another word, such as `startSpeaking(` or `startPlayback(`; what it does catch is the model types a unit test would reach one through (`ReaderViewModel`, `PhoneAppModel`), so add a pattern for those words if a unit test ever takes a bare model.
  - `PhoneControlButtonTests` (12 tests) tests the reader's UIKit control: its words, its traits, that it is one element, its actions, and its smallest height of 44 points.
  - `IOSRuntimeTests` (4 tests) tests the iOS runtime: that a hosting process runs in a sandbox, that a UI test's launch request does too, that without the request the home is the app's container, and that the library lives in Application Support.
    The two tests that read `PhoneLaunchRequest` are inside `#if DEBUG`, as the type is, so a Release test run has 2 of the 4.
  - `PhoneValueRowTests` (3 tests) measures `PhoneValueRow` at the 12 Dynamic Type sizes: stacked at the 5 accessibility sizes, side by side at the 7 others (see PhoneTextStyle in [The two apps and the platform folders](../architecture/platforms.md)).
    A third test checks that SwiftUI still has 5 and 7.
- `TextMouthiOSUITests` is an XCUITest bundle that drives the app from outside, in the simulator.
  It has 35 tests, of which 13 press Play or type (the 6 of `PlaybackUITests`, 6 of the 7 of `SearchUITests`, all but its empty sheet's, and the Search test of `LargeTextUITests`) and run only where sound is allowed, on GitHub's runner (see In the simulator, sound tests run on GitHub only, below).
  - Each test launches the app with a library of its own and, usually, a public-domain book sent to it: Alice's Adventures in Wonderland, Project Gutenberg #11, from `TestData/alice.epub` (see PhoneLaunchRequest in [The two apps and the platform folders](../architecture/platforms.md)).
  - `ReaderUITests` (4 tests): the reader's order, its first values, 44-point controls, and its audit.
  - `LibraryUITests` (4 tests): the Library's words and order, empty and with a book, and the audit of each.
  - `ScreenOrderUITests` (10 tests): the order of the Add to Library sheet, Settings, Bookmarks, Headings, Go To, Sleep Timer, the Voice sheet, Book Information, and the navigation unit's choice, with the audit of each.
  - `LargeTextUITests` (4 tests): see LargeTextUITests, below.
  - `SearchUITests` (7 tests, 0.4.4; typed since November 10, 2026; see SearchUITests, below).
  - `PlaybackUITests` (6 tests, November 10 and 11, 2026): see PlaybackUITests, below.
  - `ToolbarPlacementProbeUITests` is gone (0.4.3).
    It was one test that recorded what iOS shows for a button in `.cancellationAction`.
    Its answer is in `PhoneSheetButton.swift` and in [The two apps and the platform folders](../architecture/platforms.md), and its launch variable, `TEXTMOUTH_PROBE_SYSTEM_PLACEMENT`, went with it.
  - They read what VoiceOver would be given: each element's label, value, and traits, in the order of the accessibility tree, as a depth-first walk of one snapshot.
  - No wait lasts longer than 60 seconds.
- To run them, use the `TextMouthiOS` scheme with the build rules in [Building TextMouth](building.md): the iPhone 17 simulator, the one build folder, `Scripts/agents/run_locked.py`, and a new result-bundle name for each pass.
  A test run has the shape `xcodebuild test -project TextMouth.xcodeproj -scheme TextMouthiOS -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData-ios.noindex`, and `-only-testing:TextMouthiOSTests` or `-only-testing:TextMouthiOSUITests` runs one bundle.
- The passes of November 9, 2026 (the fix round `ios/fix-d-1109`), all on the iPhone 17:
  - Pass 3, before the review: 19 of 19 unit tests and 21 of 21 UI tests passed.
  - The review's fixes made Dynamic Type and clipped text fail again at the largest size (see LargeTextUITests, below).
    Pass 4 then ran 21 UI tests with 1 failure, Settings scrolled, on a nameless "Text clipped".
    Pass 5 ran 21 with 2: a nameless "partially unsupported" on the Library scrolled, and a Bookmarks tap that opened nothing, which is not a largest-size test.
  - The branch's last commit accepts the first and retries the second.
    The reports say it was only compiled.
    The log of a sixth pass, in the round's folder under `build/orchestrator/iosfixd/`, shows 19 of 19 unit tests and 21 of 21 UI tests with 0 failures, finished after that commit.
    The reports do not mention it, and the commit it ran is not recorded there.
  - Nothing here was run with VoiceOver.

## In the simulator, sound tests run on GitHub only
<!-- id: simulator-sound-tests-run-github; keys: ; src: TextMouthiOSUITests/TextMouthUITestCase.swift, Scripts/agents/tests/test_run_ios_ui_tests.py -->

The old rule, "never press Play and never type in the simulator", was the orchestrator's, not the user's, and the user withdrew it on November 10, 2026 ("I definitely think those should be tested on the IOS").
The rule now:

- The interface tests press Play and type, as a person does.
  That makes sound, since the simulator plays through the Mac's speakers and the keyboard clicks, so such a test runs only where nobody listens: on a GitHub runner.
- A test that makes sound runs only when the environment variable `TEXTMOUTH_UI_SOUND` is 1.
  `Scripts/agents/run-ios-ui-tests.py` is the one place that sets it (as `TEST_RUNNER_TEXTMOUTH_UI_SOUND`, which `xcodebuild` hands to the test runner without the prefix), and it runs only on the runner: anywhere `GITHUB_ACTIONS` is not `true`, it stops at once with exit status 2, before it reads a request, writes a file, or starts a simulator.
  Never run it on this Mac; to run the interface tests, ask a GitHub run for them.
  The workflow, the other scripts, and the Mac never set it: `test_run_ios_ui_tests.py` fails if another tracked file names it, if the workflow sets it, or if a test file presses Play or types by hand.
- `TextMouthUITestCase` decides in one place.
  `requireSound(_:)` skips the test, saying why, unless the variable is 1.
  The helpers that make sound (`pressPlay`, `pressPause`, `startSleepTimer`, `type`) call it first themselves, so a test that forgot still makes no sound on this Mac.
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
<!-- id: type-checks-tests; keys: ; src: TextMouthProductionTests/PhoneSettingsVoicePreviewTests.swift, TextMouthProductionTests/PhoneVoiceModelTests.swift, project.yml, Scripts/agents/run_locked.py -->

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
  It touches nothing and builds no app; run it under the heavy-work lock: `python3 -I Scripts/agents/run_locked.py NAME xcrun swiftc -typecheck -sdk $P/SDKs/iPhoneSimulator26.0.sdk -target arm64-apple-ios26.0-simulator -F $P/Library/Frameworks -I $P/usr/lib -swift-version 5 TextMouthiOSUITests/*.swift`, with `P=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer`.
  It would have found the unterminated string of run 42947183810 in seconds.
  `make typecheck-ios` does not cover these files, nor `TextMouthiOSTests`: it builds the app's sources alone.
- So, apart from `make typecheck-tests` and that command, a compile error in a test file is found only by a build that builds the tests.
  - For `TextMouthProductionTests`, `make typecheck-tests` finds it before a train does, and the build train finds it otherwise.
  - For `TextMouthiOSTests` and `TextMouthiOSUITests`, that is a simulator build (`build-for-testing`).
- This happened.
  On November 8, 2026 the iPhone branch's trains of 03:30 and 04:00 each stopped on a compile error in a test, though every type-check had passed: a stand-in that was not on the main actor in `PhoneSettingsVoicePreviewTests`, and a fixture out of scope in `PhoneVoiceModelTests`.
- After changing a test file, run `make typecheck-tests` before requesting a train for it.
  Do not take a clean `make typecheck-mac` or `make typecheck-ios` as a sign that its tests compile.
