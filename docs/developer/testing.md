# Testing TextMouth
<!-- id: testing-textmouth; keys: unit tests, test suite, how to test; src: -->

Part of [TextMouth's documentation](../../README.md).

## The hosted test suite
<!-- id: hosted-test-suite; keys: test host, hosted tests, unit tests, test bundle; src: project.yml, TextMouthProductionTests/Info.plist -->

The tests are one XCTest bundle, TextMouthProductionTests, hosted by the app itself: Xcode launches TextMouth.app and runs the tests inside it, so they exercise the real code through `@testable import TextMouth`.
New tests belong in TextMouthProductionTests/.
The files under TextMouthTests/Sources/Tests are older scenario groups that project.yml lists one by one.

### Hosted tests touch no user data
<!-- id: hosted-tests-touch-no-user; keys: isHostedTest, test isolation, no user data, TextMouthRuntime, notifications, media keys; src: TextMouth/App/TextMouthRuntime.swift, TextMouth/Services/VoiceOverAnnouncer.swift, TextMouth/Services/AudioInputPermission.swift, TextMouth/Services/NowPlayingService.swift, TextMouth/Services/Feeds/FeedNetwork.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Views/Feeds/FeedArrivals.swift, TextMouthProductionTests/HostedTestIsolationTests.swift, TextMouthProductionTests/HostedTestIsolationSupport.swift, TextMouthProductionTests/HostedTestObservers.swift, TextMouth/Platform/macOS/Services/FolderPanelSettings.swift -->

A process hosting tests never touches your data.
When the XCTestConfigurationFilePath environment variable is set, as XCTest sets it, TextMouth keeps these in a sandbox folder named TextMouthTests- followed by the process number, in the temporary directory:

- its data directory,
- this Mac's own folders (its Logs folder, its folders in Application Support, and its caches), and
- its preferences.

In that process, VoiceOver announcements made through the app's announcer are recorded instead of spoken, macOS is never asked for the microphone unless you run the microphone test (below), and a test that leaves a reader window open fails.
That process also takes no part in the system's media session: it never registers for the commands of headphones and media keys, nor tells the system it is playing, so a suite running while you listen can't take those commands from the TextMouth you are listening to.
Nor does it reach the network: its feed connections refuse every request, the feed tests answer theirs from a stub server of their own, and the feed engine never refreshes, downloads, or deletes anything by itself there.
Nor does that process post a notification, or ask permission for one.
A test reads a folder panel's settings as a value (`FolderPanelSettings`) and never builds a real `NSOpenPanel`: in a sandboxed host that starts the open-and-save panel service, which can take the person's keyboard focus.

### Test sandboxes
<!-- id: test-sandboxes; keys: temporary directory, sandbox sweep, abandonedSandboxes, TEXTMOUTH_KEEP_SANDBOX, leftover sandboxes; src: TextMouth/App/TextMouthRuntime.swift, TextMouthProductionTests/HostedTestIsolationTests.swift, TextMouthProductionTests/HostedTestObservers.swift -->

Each run deletes its sandbox as it finishes, and, as it starts, deletes in the background the sandboxes that earlier runs left behind, such as one that crashed.
The system reuses process numbers, so a sandbox counts as left behind once no process with its number is running, or the one running started more than an hour after the sandbox was made.
With TEST_RUNNER_TEXTMOUTH_KEEP_SANDBOX=1, a run keeps its sandbox for you to look inside, with a KEPT-SANDBOX.txt file in it that keeps later sweeps away; a later run given the same process number moves it aside, adding -kept- and a short suffix to its name.
Delete a kept sandbox when you are done with it.

### Running the suite
<!-- id: running-suite; keys: ProductionTestRunner, test runner, Package.swift, DerivedData, parallel testing, one test class; src: Makefile, project.yml, TextMouthTests/Package.swift, TextMouthTests/ProductionTestRunner/main.swift, Scripts/test/run-area.py, Scripts/test/areas.conf -->

- `make test` runs the whole suite.
  It runs `swift run` in TextMouthTests/, whose small runner calls:
  - With `TEST_DERIVED_DATA=<folder>`, as in `make test TEST_DERIVED_DATA=build/DerivedData`, the runner builds in that folder, counted from the repository root, instead of Xcode's default DerivedData folder.
  - `xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- Every target compiles in the Swift 6 language mode: `project.yml` sets `SWIFT_VERSION` to `6.0` for the whole project, beside `SWIFT_STRICT_CONCURRENCY` set to `complete`, and TextMouthTests/Package.swift builds the test runner in the same mode.
  So Xcode, `make build`, `make test`, and `make check` all report the same diagnostics, and a data race the compiler can find is an error.
  The mode also checks at run time that main-actor code called from Objective-C, such as a closure handed to a framework callback, runs on the main thread, and stops the app if it does not.
  The project's coding agents run the suite without parallel testing and with a build folder of their own; the `SWIFT_STRICT_CONCURRENCY=complete` in their command is redundant, and harmless:
  - `xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete -derivedDataPath /tmp/TextMouth-DerivedData`
- To run one test class, add `-only-testing:TextMouthProductionTests/` followed by the class name, such as `-only-testing:TextMouthProductionTests/CountWordingTests`.
  To run several classes, or whole areas, in one build, use `Scripts/test/run-area.py` (see [Reusable test tools](testing-tools.md)).

### Tests that skip in an ordinary run
<!-- id: tests-that-skip-ordinary-run; keys: XCTSkip, skipped tests, accessibility permission, SwiftUI elements, profiling, opt-in tests; src: TextMouthTests/README.md, Scripts/profile-production-playback.sh, TextMouthProductionTests/ProductionPlaybackProfilingTests.swift, TextMouthProductionTests/EPUBHeadingRecoveryTests.swift, TextMouthProductionTests/AccessibilityTestSupport.swift, TextMouthProductionTests/BookmarkKeyboardAccessTests.swift, TextMouthProductionTests/RecordingEndToEndTests.swift, TextMouthProductionTests/RecordingPermissionTests.swift, TextMouth/Services/AudioInputPermission.swift -->

- A full run compiles the app and runs every test; [Reusable test tools](testing-tools.md) gives how long that takes.
  Some tests skip in an ordinary run:
  - Opt-in tests that need a copied book or a library to profile, set up as TextMouthTests/README.md describes.
    That file also explains the playback profiling script, Scripts/profile-production-playback.sh.
  - Tests that read the accessibility structure SwiftUI builds, which it builds only while an assistive client such as VoiceOver is running.
  - Tests that read, through accessibility, the AppKit controls SwiftUI draws in a hosted window, such as steppers, sliders, and pop-up buttons, in a session that exposes none of them.
    Each run looks once, at a stepper of its own, and where it finds none exposed, every such test skips with one message, "This session exposes no accessibility elements for the AppKit controls in a hosted window", and the test log has one HOSTED_ACCESSIBILITY_UNAVAILABLE line.
    Where the controls are exposed, as on the development Mac, a control missing from a view, or left without its label, still fails its test.
  - 33 hosted VoiceOver tests, in 29 classes, which read the accessibility elements of SwiftUI's own texts and buttons.
    The test host is built with CODE_SIGNING_ALLOWED=NO and lacks Accessibility permission (AXIsProcessTrusted() is false), and SwiftUI exposes those elements only to an accessibility client, never to a test reading them in the same process.
    Each of the 33 skips at once with one message, "SwiftUI exposes the accessibility elements of its own texts and buttons only to an accessibility client, never to a test reading them in-process", and the log has SWIFTUI_ELEMENTS_UNEXPOSED lines.
    Running them would take a test host signed with a developer identity and granted Accessibility once in System Settings, or a trusted helper that reads the window as a client.
  - The bookmark keyboard tests, which need Keyboard navigation turned on in System Settings.
  - The microphone test, which records about three seconds, with a pause, from this Mac's default microphone, and runs only with TEST_RUNNER_TEXTMOUTH_MICROPHONE=1; its first run may show macOS's microphone prompt.
    Every other recording test uses a stand-in microphone and an answer of its own to the permission question, so the suite never shows the prompt.

### More tests that skip in an ordinary run
<!-- id: more-tests-that-skip-ordinary; keys: XCTSkip, opt-in tests, speech recognition, LAME, sweeps, TestMachine; src: TextMouthProductionTests/TranscriptionFixtureTests.swift, TextMouthProductionTests/TranscriptAccuracyMeasurementTests.swift, TextMouthProductionTests/LibraryTypeSelectProbeTests.swift, TextMouthProductionTests/LibraryTypeSelectBehaviorTests.swift, TextMouthProductionTests/LibraryTitleTypingTests.swift, TextMouthProductionTests/TitleTypingTests.swift, TextMouthProductionTests/MP3EncoderTests.swift, TextMouthProductionTests/AudioFilterTests.swift, TextMouthProductionTests/HostedTestIsolationSupport.swift, TextMouthProductionTests/VoiceSweepTests.swift, TextMouthProductionTests/ImportFuzzTests.swift, TextMouthProductionTests/StorageDrillTests.swift, TextMouthProductionTests/CorpusReportTests.swift, Scripts/agents/run-on-runner.py, Scripts/agents/github_run.py, Scripts/test/voice-sweep.sh, Scripts/test/import-fuzz.sh, Scripts/test/storage-drill.sh, Scripts/test/corpus-report.sh -->

- The real-drive tests, which run only when you name folders on cloud drives for them (see Testing on real cloud drives).
- The transcription tests that use this Mac's own speech recognizer (TranscriptionFixtureTests), which run only on macOS 26 or later, on a Mac that can run the recognizer, with the English speech model installed, and in a checkout whose TestData holds the two untracked DAISY audio ZIPs.
  Each transcribes one short file.
  With TEST_RUNNER_TEXTMOUTH_TRANSCRIPTION_LONG=1 they also transcribe both books whole, about a minute and a half more.
  No test downloads a speech model.
- The measurement behind research/TRANSCRIPT-CLEANUP-RESEARCH-2026-10-04.md (TranscriptAccuracyMeasurementTests), which runs only when `TEST_RUNNER_TEXTMOUTH_TRANSCRIPT_MEASUREMENT` names a folder, on a Mac that can transcribe, with the English speech model installed, and takes minutes.
  It measures the recognizer on the two DAISY audio ZIPs a checkout keeps, against their books' text, and on each audio file in the folder's audio folder, named as in `audio/<text>--<voice>.m4a` (or .wav, .caf, or .aiff), against `texts/<text>.txt`, the text it was made from.
  It keeps each transcript in the folder's transcripts folder, so a second run doesn't transcribe again, and writes measurement.md, the document's tables, and differences.json, every difference with its confidences and context.
  `TEST_RUNNER_TEXTMOUTH_TRANSCRIPT_MEASUREMENT_LOCALE=en-US,en-GB` measures in both Englishes.
  It downloads and plays nothing.
- The two tests that need an installed ffmpeg, which TextMouth looks for in Homebrew's and MacPorts' folders and along PATH, skip on a Mac without it, as they do on GitHub's runners, which have none:
  - one that writes MP3 through it, the route MP3 takes only should the LAME built in fail to start;
  - and one that runs every premade filter preset through it and through TextMouth's own filters and compares them.
  Only a run on a Mac with ffmpeg proves them, so the full Mac suite at a merge is their gate.
  The import's tests need none, since the app carries its own FFmpeg helper (see [Formats only ffmpeg reads](testing-formats.md#formats-only-ffmpeg-reads)).
- The opt-in benchmarks of the performance work (below).
- `LibraryTypeSelectProbeTests`, which types into hosted lists to find out what AppKit's type select does (for the Leading articles setting), runs only on request and only on GitHub's runner.
  It skips unless the test host has both `TEXTMOUTH_TEST_TIME_SCALE`, which marks the runner, and `TEXTMOUTH_TYPE_SELECT_PROBE`, since a key AppKit turned down would make the Mac beep, and no test may make a sound.
  No train or suite runs it: it takes about 72 seconds of a runner's time, and its findings are settled.
  To run it, send a request by hand through `github_run.run_remotely` with `"classes": ["LibraryTypeSelectProbeTests"]` and `"type_select_probe": true`.
  `Scripts/agents/run-on-runner.py` hands that flag to the test host as `TEST_RUNNER_TEXTMOUTH_TYPE_SELECT_PROBE=1` (a Python test pins it, and a request without the flag, or with it false, sets nothing), and each finding is a line beginning `TYPE-SELECT-PROBE:` in the run's `run.log`.
  The probe asserts only what must hold for it to mean anything (a list was drawn, its table took the keyboard), never a finding, so a finding cannot fail a run.
  Its timing test writes `InitialKeyRepeat` and `com.apple.mouse.doubleClickThreshold` into the app's own defaults domain, which is safe only on a fresh runner.
- `LibraryTypeSelectBehaviorTests` holds the probe's findings that can be asserted, and runs in every run (about 17 seconds, in real time, since AppKit reads the clock).
  In the first choice of the Leading articles setting, which the tests rely on and do not write (they skip while another is in force), AppKit's type select starts a new search at the row after the selected one and wraps.
  Letters typed 0.2 seconds apart add up, and a letter typed after the longer of 2.5 seconds and four times this Mac's Delay Until Repeat starts afresh.
  AppKit's own interval was 1.2 to 1.3 seconds on the runner and under 1 second on the development Mac, so the tests keep far from the edge.
  They skip where this macOS gives an offscreen window's list no keyboard focus.
  LibraryTitleTypingTests, TitleTypingTests, and the other Leading articles classes are ordinary tests (see [Windows](../architecture/state/windows.md), letter navigation in the Library list).
- The sweeps of the reusable test tools (VoiceSweepTests, ImportFuzzTests, StorageDrillTests, and CorpusReportTests), which run only from their scripts (see [Reusable test tools](testing-tools.md)).
- The performance baselines tests, while the Mac is busy, and on a Mac model or in a build configuration other than their baselines' (see The performance baselines).

### The tests on GitHub's macOS runner
<!-- id: tests-github-macos-runner; keys: GitHub Actions, check gate, runner skips, CI; src: .github/workflows/check.yml, Scripts/agents/runner-skips.conf, Scripts/agents/runner_skips.py, TextMouthProductionTests/AccessibilityTestSupport.swift, TextMouthProductionTests/PerformanceBaselineSupport.swift -->

- GitHub's macOS runner, where the gate's suite runs for every push to main and every pull request from this repository, skips more tests than the development Mac.
  [The make check gate](building.md#the-make-check-gate) says in what ways that suite is weaker than `make check` here.
  It skips the 14 of `Scripts/agents/runner-skips.conf` (see [Tests on GitHub Actions](testing-github.md)), and the following.
  There SwiftUI builds no accessibility structure, a hosted window exposes none of its AppKit controls to accessibility.
  Keyboard navigation is off there until `Scripts/agents/runner_settings.py` turns it on, so most tests that need it run.
  So the kinds of test above that read accessibility skip rather than fail, as do the opt-in tests and benchmarks.
  The performance baselines tests skip too, since their baselines belong to the development Mac's model (so a request for strict baselines checks no baseline on a runner).

### A test that may crash the host
<!-- id: test-may-crash-host; keys: skipUnlessGitHubRunner, isGitHubRunner, TEXTMOUTH_TEST_TIME_SCALE, Objective-C exception, stack overflow, crash report, no-crash rule; src: TextMouthProductionTests/HostedTestIsolationSupport.swift, TextMouthProductionTests/ObjCExceptionTests.swift, TextMouthProductionTests/AudioEditRenderingTests+WideSamples.swift, TextMouthProductionTests/MarkdownDepthLimitTests.swift, TextMouthProductionTests/ExportDocumentWalkerNestingTests.swift, Scripts/agents/run-on-runner.py, TextMouthProductionTests/StackProbe.swift, TextMouthProductionTests/FFmpegHelperHostileFileTests.swift; status: incomplete; issues: B20 -->

- A test that crashes the test host when the code it checks is broken runs on GitHub's runner only, because a crash on the user's Mac puts macOS's crash report on their screen, and on a runner it is only a failed run.
  Such a test raises an Objective-C exception on purpose with only the code under test to catch it, or fills a thread's stack with a pattern to measure how much of it a walk of a deep tree uses.
- `TestMachine.skipUnlessGitHubRunner(_:)` (HostedTestIsolationSupport.swift) is the one way to keep it off the user's Mac: the test calls it first, and it skips with the reason it is given anywhere but on a runner.
  It keys on `TEXTMOUTH_TEST_TIME_SCALE`, which `Scripts/agents/run-on-runner.py` sets for every test host it starts and nothing sets on the Mac (`TestMachine.isGitHubRunner`).
  In the iPhone bundle, which shares the file and runs only on GitHub, it is always true.
- Its users: the two raising tests of `ObjCExceptionTests` and of `AudioEditRenderingTests+WideSamples`, the stack tests of `MarkdownDepthLimitTests` and `ExportDocumentWalkerNestingTests`, and `FFmpegHelperHostileFileTests`, which give the FFmpeg helper damaged media.
  The same tests run the helper's Debug-only `signalcheck` mode, which crashes it on purpose to test its signal guard, on GitHub only.
  The helper ends itself with _exit on a fatal signal, which should leave no crash report, but that is only tried on a runner.
  The type-select probe uses it too, though for a beep and not a crash.
  StackProbe (TextMouthProductionTests/StackProbe.swift) measures a walk's stack use instead of surviving an overflow: it runs the code on a thread of 8 MiB whose unused stack it filled with a pattern, and says how far the code wrote past a margin.
  A fix for a crash is shown by a break proof on GitHub: a scratch branch with the fix removed, sent by hand, never run on the Mac.
- **No test may let a real liblouis call be abandoned,** on any platform: liblouis is not thread-safe, and an abandoned call runs on beside the next test's call, which crashed a train's iPhone run with SIGSEGV.
  The test of the iPhone's abandonment sentence for braille waits for a stand-in for the liblouis call, a seam like FFmpeg's `openSession` (B20).

### Benchmarks of the performance work
<!-- id: benchmarks-performance-work; keys: opt-in benchmarks, timing tests, speed tests, Release build, TEST_RUNNER prefix; src: TextMouthProductionTests/ViewsAndWindowsBenchmarks.swift, TextMouthProductionTests/DuplicateFinderTests.swift, TextMouthProductionTests/TextPipelineBenchmarkTests.swift, TextMouthProductionTests/PersistenceCostTests.swift, TextMouthProductionTests/LibraryModelBenchmarkTests.swift, TextMouthProductionTests/SpeechPreparationBenchmarkSupport.swift, TextMouthProductionTests/SpeechEngineCreationTests.swift, TextMouthProductionTests/SpeechVoiceWarmUpTests.swift, TextMouthProductionTests/AudioEngineBehaviorTests.swift, TextMouthProductionTests/CompletionGenerationTests.swift -->

- The benchmarks of the performance work time what each change made faster and print their figures in the test log.
  They are opt-in, since they take minutes or need a run of their own, and each group runs when its variable is 1; xcodebuild hands a variable whose name starts with TEST_RUNNER_ to the test host without that prefix:
  - TEST_RUNNER_TEXTMOUTH_LARGE_BENCHMARKS: the speech-preparation benchmarks at the sizes too slow to time in every run, and four that time the system synthesizer, muted, and the first speech engine.
    Three of those four mean something only when each runs alone, named with -only-testing, in a process of its own.
  - TEST_RUNNER_TEXTMOUTH_VIEW_BENCHMARKS:
    - ViewsAndWindowsBenchmarks, which measure what a change of the library costs the list, what a playing reader costs its sheets, what a closed reader still holds, and how many test sandboxes the temporary folder holds, and
    - DuplicateFinderTests.testMeasureWhatAnAuthorScansResultsCost, which measures what Find Duplicate Books' results cost to show, every group at once and the first page.
  - TEST_RUNNER_TEXTMOUTH_BENCHMARKS: TextPipelineBenchmarkTests, which time the text pipeline's old and new code side by side.
    They run best in a Release build, as in `xcodebuild test -configuration Release ENABLE_TESTABILITY=YES -only-testing:TextMouthProductionTests/TextPipelineBenchmarkTests` with the rest of the usual arguments.
  - TEST_RUNNER_TEXTMOUTH_RENDER_BENCHMARK: what rendering a chapter's speech costs in memory and main-thread time.
    It takes about half a minute, and nothing is heard.
  - TEST_RUNNER_TEXTMOUTH_TRACK_CHANGE_BENCHMARK: how long an audiobook's next file takes to start playing, timed with silent files.
  - PersistenceCostTests and LibraryModelBenchmarkTests run in every run instead.
    They check what a change costs in counts that follow from the code alone, such as bytes written, file-system calls, and publishes of the library, never in time, which a busy Mac would change, and print their figures on lines beginning PERSISTENCE_COST: and PERFMODEL:.

### Tests of the audit's small runtime fixes
<!-- id: tests-audit-small-runtime-fixes; keys: timer tolerance, countdown timer, leading edge refresh, time remaining tally, speech position tick; src: TextMouthProductionTests/TimerCoalescingTests.swift, TextMouth/Services/SleepTimerService.swift, TextMouthProductionTests/ReaderRefreshLeadingEdgeTests.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouthProductionTests/TimeRemainingTallyTests.swift, TextMouth/ViewModels/TimeRemainingTally.swift, TextMouth/ViewModels/LiveReadingPositions.swift, TextMouthProductionTests/PlaybackLifecyclePolicyTests.swift, TextMouth/Services/SpeechService.swift -->

- The tests of the audit's small runtime fixes run in every run, with nothing heard and no waiting on a real clock:
  - `TimerCoalescingTests` (area `playback-end`) reads each loosened timer's tolerance, a tenth of its interval: the statistics checkpoint, the session lease, and the speech watchdog.
    It pins the sleep countdown's timer at no tolerance, which was already so, so that test guards against a later change and does not prove the fix.
    The test that does is `testTheSleepCountdownTickActsAtOnce`: firing the countdown's timer (`SleepTimerService._fireCountdownTimerForTesting()`) counts one second down in the same turn.
  - `ReaderRefreshLeadingEdgeTests` (area `playback-end`) gives the reader its own clock (`playbackUIRefreshNow`), so ten seconds of an audiobook's quarter-second cursor take a moment.
    It checks
    - that each of the 40 changes is shown on the main queue's next turn with no delayed work item (`delayedPlaybackUIRefreshCount` stays 0),
    - that a chapter and an offset set together are shown together,
    - that changes inside the interval wait out what is left of it and show the last, and
    - that a clock set back still refreshes within one interval.
  - `TimeRemainingTallyTests` (area `library`) checks
    - that the tally's figures equal a full addition's to the last bit with no live position, one, several, and after they go;
    - that the bar's spoken summary follows a live position;
    - that ten live updates of 1,500 books estimate ten books (`estimateCount`), not fifteen thousand;
    - that a changed list or speed is added up again; and
    - that `LiveReadingPositions.liveBookIDs` names the books with a live position as readers report and close.
  - `LookAheadLeadTests` (area `speech`) tests the look-ahead's lead and the long-pause watch as plain rules, with nothing rendered, spoken, or waited for: the lead's floor and growth, `isReached`, and `LongPauseWatch`'s delay, its end, and being watched again.
    `PreRenderedSpeechInvalidationTests` tests the reader's side: nothing renders short of the lead, crossing it asks once, a seek in asks once and a seek back keeps the render, a short chapter renders at once, and a long pause lets the audio go and keeps the speech.
  - A new stored field needs its key, its encoder line, its entry in StoredKeyScan's schema, and its place in the plain twin that `UnknownKeysTests` holds each hand-written encoder to; a setting added since v0.4.11 goes in `settingsAddedSince0411`.
  - The speech position tick (`publishRenderedPosition`) is tested in `PlaybackLifecyclePolicyTests`, through `SpeechService._setTextForTesting(_:)`, which gives the service a text without rendering any speech:
    - a position that did not move publishes nothing,
    - a stale generation publishes nothing, and
    - white space, a place past the end, and one before the start publish a range and no word.
  - The audio-engine tests skip on GitHub's runner, so only the Mac suite covers them.

### Reader shown state tests
<!-- id: reader-shown-state-tests; keys: shown state, reader announcements, sleep timer countdown, view body count, hand check; src: TextMouthProductionTests/ReaderShownStateTests.swift, TextMouth/ViewModels/ReaderShownState.swift, TextMouth/Views/ViewBodyCounter.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/Views/Reader/SleepTimerStatusLabel.swift, TextMouthProductionTests/AccessibilityTestSupport.swift -->

- `ReaderShownStateTests` (area `sheets`) tests the reader window's shown state (`ReaderShownState`):
  - `testTheStateEqualsWhatTheViewsBuildFromTheCursorAtEveryStep` walks the cursor and builds each label and value the views draw from the raw cursor, then compares them with what the shown state holds.
    `testAStepThatChangesASpokenLabelChangesTheState`, `testAStepThatChangesOnlyTheHeadingOrOnlyThePageIsAnnounced`, and `testABookmarkComingNearIsAnnounced` pin the steps a view would otherwise miss.
  - `testOnlyAChangeInWhatIsShownIsAnnounced` counts the reader's announcements, and `testMovesWithinWhatIsShownDrawNoView` counts view-body runs (`ViewBodyCounter`), so a move within what is shown draws none; `testBecomingKeyStillAnnouncesToTheViews` checks `windowBecameKey()`.
  - `testTheCountdownMovesEverySecondPlayingAndPaused` and `testTheCountdownLabelComesAndGoesWithTheTimer` check `SleepTimerStatusLabel` as the timer ticks, starts, and stops.
  - `testTheReadersOwnCountdownLabelsSpeakEachSecondPlayingAndPaused` reads the status row's and the playback bar's labels, "Sleep timer: 4:59 remaining", from the hosted views' accessibility tree.
    It skips (`skipUnlessSwiftUIExposesItsOwnElements()`) on this Mac and on GitHub, since SwiftUI builds its own elements only for an accessibility client such as VoiceOver.
    Only `testTheReadersCountdownLabelsAreDrawnByTheTimersOwnLabel`, which reads the two views' sources for `SleepTimerStatusLabel`, guards the production labels where it skips.
    So the countdown needs a hand check with VoiceOver: a 15-minute timer, both labels changing each second, playing and paused, and gone when the timer stops.

### A hosted failure with exit code 0
<!-- id: hosted-failure-exit-code-0; keys: host quit, system log, XCTest failure, own TextMouth running; src: -->

- A hosted test that fails with the message `The test runner exited with code 0` may be the user's own TextMouth starting beside the host, which shares its bundle identifier.
  Read the system log for `terminate:`, and run the class alone before calling it a fault; a run cut short by an ordinary quit the host received while frontmost is settled the same way.

### Tests in Spanish
<!-- id: tests-in-spanish; keys: SpanishLocalizationTests, SpanishUITests, Strings.pack, AppleLanguages, localization test, FR34; status: incomplete; issues: FR34, TL14; src: TextMouthProductionTests/SpanishLocalizationTests.swift, TextMouthiOSUITests/SpanishUITests.swift, TextMouthProductionTests/LanguagePackTests.swift, TextMouthiOSUITests/TextMouthUITestCase.swift, TextMouthProductionTests/AccessibilityTestSupport.swift, TextMouthProductionTests/RunLoopWaiting.swift -->

- The suite runs in English.
  `SpanishLocalizationTests` (the Mac app) reads the Spanish entries of the app's own `Strings.pack` by ID, and asks the engine for a line in Spanish (`InterfaceText.line(_:_:language:)`).
  It checks each pilot area's strings in Spanish, every plural string in its three categories, that no text is empty, and that a bookmark's number is never grouped.
- `SpanishUITests` (the iPhone interface tests, on GitHub) starts the app with `-AppleLanguages (es) -AppleLocale es_ES` and compares what VoiceOver is given, in order, with the catalog's Spanish.
  Each expected word has its English beside it, so a failure shows an English start at once.
  They check the Sleep Timer and Bookmarks sheets.
- `InterfaceTextShippedPackTests`, in both apps, compares every entry and lookup of the shipped pack with the catalog, plurals at 13 counts ([what the apps ship](localization.md#what-the-apps-ship)).
- `AccessibleControl.title` is a hosted control's accessibility title, which VoiceOver reads beside its label.
  A test can require it empty, because a hidden title that repeats the label is read twice ("Adjust minutes, Adjust minutes").
- `RunLoopWaiting.swift`, shared with the iPhone's unit tests, has `waitForMainQueueTurn()`, and `waitForMainQueueTurnAsync()` for a test that is `async`.
  Each returns once everything queued on the main queue before the call has run, with a limit, as `openBookIDs` follows a reader's registration a turn later.
  The async one suspends, since the blocking wait cannot run on the main actor there.

### Outside constants in tests
<!-- id: outside-constants-tests; keys: SDK constant, quit reason, wrong value pinned; src: -->

- A test takes an outside constant, such as a quit-reason keyword, from the SDK and not from the code it tests: a test and its code that pin the same wrong value both pass.

## The performance baselines
<!-- id: performance-baselines; keys: PerformanceBaselineTests, speed regression, performance tests; src: TextMouthProductionTests/PerformanceBaselineTests.swift -->

PerformanceBaselineTests keep what the performance work made faster from slipping back.
They measure a library and books generated to the size of the developer's, never your own library, and run in every run of the suite, in about half a minute.

### What the baselines measure
<!-- id: what-baselines-measure; keys: launch time, sort time, speech preparation, memory peak, 643-book library; src: TextMouthProductionTests/PerformanceBaselineTests.swift, TextMouthProductionTests/PerformanceBaselineFixtures.swift, TextMouthProductionTests/performance-substitutions.json -->

They measure:

- launch with a 643-book library: reading library.json, the startup repair, and finding the text caches that need rebuilding;
- the first sort of the library by File Size, and one derivation of the All Items list for each of the six sorts;
- one live reading position update, and the bytes one 30-second reading checkpoint writes for a book whose record is as large as the developer's largest;
- opening a 1 MB EPUB for the first time until the speech of its first chapter is prepared, and opening it again from the text TextMouth kept, and opening a 3-file audiobook until it has loaded;
- preparing the speech of a 1,000,000-character chapter with the developer's 16 substitution rules, which TextMouthProductionTests/performance-substitutions.json keeps a copy of;
- the most memory a 40,000-character chapter's rendered speech takes while it is built, and what it keeps;
- extracting the 1 MB EPUB's text;
- the processor time of one cloud refresh of a library outside the cloud;
- the main-thread time one reader publish costs the open Headings sheet.

### How the baselines judge
<!-- id: how-baselines-judge; keys: warning threshold, twice the baseline, median of five, busy Mac, load average, Mac15,12, recorded baselines; src: TextMouthProductionTests/PerformanceBaselineSupport.swift, TextMouthProductionTests/performance-baselines.json, Makefile, Scripts/check.sh -->

How they judge:

- Each number is the median of five runs, after one more that warms caches and is not counted.
  TextMouthProductionTests/performance-baselines.json holds each one's baseline, with the Mac model, build configuration, and date they were recorded on.
- A number more than twice its baseline is measured five times more, and the test fails only when the lower median is still more than twice its baseline.
  A number at 1.5 times its baseline or more prints a line beginning PERFORMANCE WARNING:, and one at half its baseline or less a line beginning PERFORMANCE NOTE:, since new baselines would tighten the check.
  Every number is printed on a line beginning PERFORMANCE:.
- The tests skip, printing PERFORMANCE SKIPPED: and why, while the Mac is busy (its one-minute load average above its number of cores), so other work cannot fail them, and on any Mac model or build configuration other than the baselines', where the numbers say nothing.
  With TEST_RUNNER_TEXTMOUTH_PERFORMANCE_STRICT=1 a busy Mac measures anyway: `make test PERFORMANCE_STRICT=1` sets it, and `make check` uses it.
  A baselines file that is missing or can't be read fails the tests rather than skipping them.

### Recording new baselines
<!-- id: recording-new-baselines; keys: make perf-baselines, PERFORMANCE_RECORD, rewrite baselines, quiet Mac; src: Makefile, Scripts/perf-baselines.sh, TextMouthProductionTests/performance-baselines.json, TextMouthProductionTests/PerformanceBaselineSupport.swift -->

Recording new baselines:

- After a deliberate change to what they measure, run `make perf-baselines` on an otherwise idle Mac, adding `TEST_DERIVED_DATA=<folder>` to build in a folder of your own.
  It runs the tests alone with TEST_RUNNER_TEXTMOUTH_PERFORMANCE_RECORD=1: each test waits, for up to five minutes, until the Mac is quiet, and once every number is measured the file is rewritten with this Mac's model and today's date.
- It prints each old and new number, keeps xcodebuild's output in build/perf-baselines.log, and ends with PASSED or FAILED.
  Nothing changes unless the whole run succeeds.
  Review the file's diff and commit it with the change it records.

## Testing on real cloud drives
<!-- id: testing-real-cloud-drives; keys: File Provider, evict, dataless file, cloud fetch, real drive, sync service; src: TextMouthProductionTests/CloudDriveIntegrationTests.swift, TextMouthProductionTests/CloudDriveTestSupport.swift, TextMouthProductionTests/CloudDriveTestSupportTests.swift, TextMouthProductionTests/LibraryCloudFetchTests.swift, TextMouthProductionTests/LibraryLaunchFilesTests.swift, TextMouth/Services/BookCloudStorageService.swift, research/CLOUD-STORAGE-MANUAL-TESTS-2026-10-03.md -->

CloudDriveIntegrationTests runs the cloud services against real sync services.
It is opt-in: its tests skip unless the TEXTMOUTH_CLOUD_TEST_ROOTS environment variable lists folders for them.

- Make a folder named TextMouth Cloud Tests in each drive to test, and list the folders' full paths, separated by colons. xcodebuild hands a variable to the test host when you set it with the prefix TEST_RUNNER_, as in:
  - `TEST_RUNNER_TEXTMOUTH_CLOUD_TEST_ROOTS="$HOME/Library/CloudStorage/Dropbox/TextMouth Cloud Tests" xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:TextMouthProductionTests/CloudDriveIntegrationTests`
- When any entry isn't the full path of an existing folder with that name inside a cloud drive, or is listed twice, the tests fail and use no folder at all.
  CloudDriveTestSupportTests checks these rules in every ordinary run.
- Each test works only inside a new folder of its own, writes small files of random bytes there (the small-library test uses the repository's TestData books), and deletes the folder when it ends, even after a failure.
  Nothing else on the drive is read or changed, and the app's library stays in the test sandbox.
  With TEST_RUNNER_TEXTMOUTH_CLOUD_TEST_KEEP_SMALL_LIBRARY=1, the small library stays on the drive, for the checks made by hand.
  A run moves about 36 MB up and 10 MB down for each drive.
- `testTheLibraryFetchBringsAnEvictedFileBackWhole` and `testTheLibraryFetchListsAnEvictedFolder` check the library's fetch from the cloud: a 12 MiB file is removed from the Mac, fetched, and read back with downloads refused, so a partial read can't pass, and a folder is removed and listed.
  LibraryCloudFetchTests and LibraryLaunchFilesTests cover the rest with a scripted cloud in every ordinary run.
- Against Dropbox, the tests showed that:
  - Download and removal requests work: a test book's files uploaded within 5 seconds, their downloads were removed at once, and they downloaded again within a second through TextMouth's book service.
  - A file whose download was removed reports its real size, and a clone made before the removal stays readable.
  - A package renamed into the drive, as an import puts a new book in place, syncs as one book, and a hidden folder syncs within 4 seconds.
  - Remove Download refuses a book whose new file hasn't finished uploading.
  - Progress is reported only at 0 and 100 percent for small files, and a file's modification time moves by up to 118 nanoseconds when it downloads again, which is why TextMouth compares the times of a text cache's files to the microsecond.
- TextMouth treats a book's package that iCloud Drive syncs whole as one item.
  Against iCloud Drive and Google Drive, the tests showed that:
  - iCloud Drive syncs a book's package as one item: the package carries the sync flags and the files inside it none, and a request to download or remove one of those files is refused as if the file didn't exist.
    Removing the package's download leaves the whole package in the cloud at once, nothing inside it can be looked up until it downloads again, and TextMouth's book service brought it back within a second.
    Google Drive syncs each file, as Dropbox does, though its package folders carry sync flags too.
  - iCloud Drive uploaded a test book within 10 seconds, and Google Drive within half a minute, since Google Drive waits 15 to 30 seconds before it starts uploading.
  - iCloud Drive publishes the progress of a package as a whole and none for the files inside it, and Google Drive each file's; on a quick download both reported only 0 and 100 percent.
  - Google Drive reports an evicted file's real size.
    iCloud Drive gives a file it downloads again a modification time in whole seconds, so a text book whose package came back has its files read once for their digests when it next opens, before its text cache is trusted.
    Google Drive moves the time by up to 107 nanoseconds, as Dropbox does.
  - On both, a clone made before a removal stays readable, a package renamed into the drive syncs as one book, a hidden folder syncs within half a minute, and Remove Download refuses a book whose new file hasn't finished uploading.
- [research/CLOUD-STORAGE-MANUAL-TESTS-2026-10-03.md](../../research/CLOUD-STORAGE-MANUAL-TESTS-2026-10-03.md) gives the commands for every drive and the matrix of checks to make by hand, with VoiceOver steps.
  That file covers what these tests can't reach: TextMouth's own screens and commands on a real drive, and a drive that is paused, signed out, or offline.
