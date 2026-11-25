# Tests on GitHub Actions
<!-- id: tests-github-actions; keys: CI, hosted runner, macos-26, workflow, remote train; src: .github/workflows/test-build.yml, .github/workflows/tests.yml, Scripts/agents/github_run.py -->

Part of [TextMouth's documentation](../../README.md).

The build train and the orchestrator's full suite can build and test on GitHub's macOS runners instead of this Mac, so the user's Mac is free for its own work.
The repository is public (`github.com/AERobertAI/TextMouth`), the runners are free, and nothing runs there except for a push to the branch `TestBuild`.
[Building the iOS app](building-ios.md) (Builds on GitHub Actions) has the design; this page is for reading a run and knowing what a run cannot tell you.

## What runs where
<!-- id: what-runs-where; keys: CI, concurrency group, cancel-in-progress, queue, serialize pushes, typecheck; src: Scripts/agents/github_run.py, Scripts/agents/run_suite.py, .github/workflows/test-build.yml, .github/workflows/tests.yml, Scripts/agents/build-train.py, Makefile -->

- **On this Mac:** merging the requests, pushing, waiting, reading the result.
  A remote train takes no heavy-work lock and runs no iOS census (the run builds the iPhone app on GitHub instead).
  A push waits first for any run already on `TestBuild` to end (`github_run.py`, up to 125 minutes), because a newer push cancels the run before it; so a train, `run_suite.py --remote`, and a run sent by hand take turns, and none cuts off another's.
  Each push also holds one exclusive lock (`flock` on `textmouth-testbuild-push.lock` in the repository's git common folder, so every worktree shares it) from before its idle check until GitHub lists the run of its own commit, about 90 seconds at most.
  GitHub takes a few seconds to register a run, and a push whose idle check came in that gap found nothing, pushed, and cancelled the first.
  The train loop runs its own copy of the script until it is restarted, so a copy that was started before the lock was merged does not take it.
  A train leaves 5 minutes after the first waiting request.
- **On GitHub:** generating the project, building, and running the tests, in up to four jobs at once ("shards"), and, beside them, building the iPhone app and its two test bundles for the iOS Simulator and running them there:
  - the unit tests (`TextMouthiOSTests`) and
  - the interface tests (`TextMouthiOSUITests`, pressing Play and typing).

  The two bundles run in one `xcodebuild` run.
- **Still on this Mac:** the type-checks (`make typecheck-mac`, `make typecheck-ios`), the lints, `make check`, anything that needs the development Mac's voices, accessibility session, or signing identity, and the tests the runner leaves out (below).

## How a run goes
<!-- id: how-run-goes; keys: CI, matrix, workflow_call, build-for-testing, simulator, artifact, xcresult, xcodegen; src: Scripts/agents/run_suite.py, .github/workflows/tests.yml, .github/workflows/test-build.yml, .github/workflows/check.yml, Scripts/agents/class-times.json, Scripts/agents/plan_shards.py, Scripts/agents/run-on-runner.py, Scripts/agents/test_command.py, Scripts/test/run-area.py -->

1. **The request.**
   A train or a suite pushes a commit of the tree to test plus `.github/test-request.json`: `areas`, `classes`, `full`, and `shards`.
   The Mac chooses `shards` from the classes' times on the runner (`Scripts/agents/class-times.json`, one shard per 10 minutes of tests, 1 to 4); the full suite asks for 4.
2. **Plan** (Linux, seconds).
   `Scripts/agents/plan_shards.py` reads the request and says how many test jobs to start, and whether the iPhone build is wanted (`"ios": false` leaves it out) and whether the build starts from nothing (`"cold": true`).
   The jobs are in `.github/workflows/tests.yml`, which `test-build.yml` (a push to `TestBuild`) and `check.yml` (the gate on main) both call.
3. **Test** (macOS, one job per shard).
   - Each job restores the last run's build products from the cache,
   - restarts the audio service,
   - generates the project, and
   - runs its share of the classes through `Scripts/agents/run-on-runner.py`, which takes the same test command the train and `run_suite.py` use from `Scripts/agents/test_command.py` and adds a 2-minute limit for any one test and the tests left out.

   Each uploads its log and summary as `shard-results-N`.

### The iPhone job
<!-- id: run-iphone-job; keys: build-for-testing, simulator, iPhone 17, iOS 26.0.1, xcodebuild, downloadPlatform, ios-ui-summary; src: Scripts/agents/run-ios-build.py, project.yml; status: incomplete; issues: TL08 -->

4. **The iPhone app** (macOS, beside the shards).
   `Scripts/agents/run-ios-build.py` runs `xcodebuild build-for-testing` on the `TextMouthiOS` scheme for a generic iOS Simulator destination, naming the runner's own architecture (`ARCHS=arm64`).
   It compiles the app and its two test bundles, `TextMouthiOSTests` and `TextMouthiOSUITests`, without signing (the scheme's test action builds Debug, which is why the two unit tests inside `#if DEBUG` are there).
   The runner image's Xcode 26.0.1 lists the iOS SDKs but says "iOS 26.0 is not installed", so the job first downloads the platform (`xcodebuild -downloadPlatform iOS`, about 3 minutes).
   It uploads `ios-summary.txt`, `ios-errors.txt` (each error as `path:line:col: error: message`, repository-relative), and `ios.log`.
   A build that does not compile is a result, not a failure of the job.
   Before the build a stamp of the toolchain empties a restored module cache made on another runner image.
   A build that still fails with "has been modified since the module file" or "module file ... not found" is tried once more ([A cache made on another runner image](building-ios.md#a-cache-made-on-another-runner-image)).
   A "fatal error:" line with a file and line in front is not counted, so a missing header ends "no error line" (TL08).

### The iPhone tests
<!-- id: run-iphone-tests; keys: ios-ui-summary, ios_ui_tests, counts_by_bundle, PARALLEL_WORKERS, result bundle, keyboard preferences, NOT ASKED; src: Scripts/agents/run-ios-ui-tests.py, Scripts/agents/ios_ui_tests.py, TextMouthiOSUITests/ReaderUITests.swift, TextMouthiOSUITests/SearchUITests.swift, TextMouthiOSTests/PhoneValueRowTests.swift, TextMouthiOSUITests/TextMouthUITestCase.swift, project.yml -->

   - **The iPhone tests.**
     Then `Scripts/agents/run-ios-ui-tests.py` runs `TextMouthiOSTests` (the unit tests, 19 of its own and the Mac's shared ones) and `TextMouthiOSUITests` (the interface tests) with one `xcodebuild test-without-building`, in an iPhone 17 simulator on the iOS 26.0.1 runtime that the job downloaded.
     The platform download leaves an iPhone 17 ready, and the script makes one if it is missing.
     It does so when the request asks for them (`ios_ui_tests.py` decides):
     - every full suite,
     - a request for the area `phone` or `all`, or
     - a request that names a class of either bundle in `classes` (`ReaderUITests`, `SearchUITests`, `PhoneValueRowTests`, and so on; the Mac's runner moves those names aside, since `run-area.py` does not know them, and a request that names classes runs those classes alone, each in its own bundle).

     One run for both bundles saves xcodebuild's start-up, 2 to 2.7 minutes.
     `"ios": false` leaves the whole iPhone job out, and `"ios_ui": false` only the tests.
     Before the first test it sets the simulator's keyboard preferences, all four at once (the one-time swipe-typing page off, no prediction), and the job restarts the audio service as the shards do.
     The tests run in one simulator: two clones (`PARALLEL_WORKERS`) took no less time on the runner's three cores, and xcodebuild printed no failure message for a failed test then.
   - **Its results** are `ios-ui-summary.txt` and `ios-ui.log`.
     The summary holds:
     - the first line `iOS UI tests: PASSED`, `FAILED`, `NOT RUN` or `NOT ASKED`, which keeps its name though it is the verdict of both bundles;
     - the Executed line;
     - a `Unit tests (TextMouthiOSTests): N ran, S skipped, F failed` line and an `Interface tests (TextMouthiOSUITests): ...` line, or `not asked` for a bundle no asked class is in;
     - the simulator;
     - the minutes;
     - `FAILED Class.test (Bundle) at file:line: message` for each failed test, as the Mac's runs print them with the bundle added;
     - `Skipped Class.test: why`; and
     - `Reason:`.

     A test that began and has no outcome line, because the host app crashed in it or the time limit stopped the run there, is named as failed, "started and never finished".
     A failed run also uploads its result bundle (`ios-ui-result-bundle`, 3 days), with the screenshots and element trees the tests attached.
   - **A failed or missing iPhone test fails the iPhone job, and nothing else.**
     The script exits 1, the job turns red, and the later steps still run; the join keeps the Mac tests' verdict from `run-summary.txt`, which no iPhone test can change.
     A bundle that gives back fewer results than its asked classes hold (a unit test missing, or the whole unit bundle, though xcodebuild said it succeeded) fails the run too, with a reason that names the bundle.
     Each bundle's count is checked on its own, from the sources (`ios_ui_tests.counts_by_bundle`, which reads each folder's Swift files and subfolders as `project.yml` compiles them).
     The methods inside `#if DEBUG` count, and so do tests written with attributes (`@MainActor func testA()`) or in an extension of a test class.
     A Python test fails if any `func test` in either folder is left uncounted, which is how a test class that inherits another test class, not `XCTestCase` or `TextMouthUITestCase` itself, would show up, since the counter recognizes only those two parents.
     The run's page (`summary.md`), a train's result, and `run_suite.py --remote` show `iOS UI tests: ...`, the Executed line followed by how many unit tests and how many interface tests ran, `iOS UI test failures: N`, and each failed test.

### Collecting and reading the results
<!-- id: run-collect-results; keys: merge_shards, test-build-results, run-summary, artifact, summary.md, Run on GitHub; src: Scripts/agents/merge_shards.py, Scripts/agents/run_suite.py, Scripts/agents/github_run.py, Scripts/agents/build-train.py -->

5. **Collect** (Linux, seconds).
   `Scripts/agents/merge_shards.py` joins the shards (and the iPhone job's five files) into one `test-build-results` artifact:
   - `run-summary.txt` (the form `summarize` reads: the Executed line, each FAILED and ERROR line, a last line of PASSED or FAILED),
   - `run.log` (the shards' logs one after another),
   - `summary.md`,
   - `request.json`,
   - `ios-summary.txt`,
   - `ios-errors.txt`,
   - `ios.log`,
   - `ios-ui-summary.txt`, and
   - `ios-ui.log`.

   The run fails if any shard failed or reported nothing.
   The iPhone build never decides that: it is shown beside the verdict.
6. **The Mac** finds the run by its commit's SHA, waits for it (up to 125 minutes), downloads that artifact into the train's folder, and reports from it as for a local train.
   A lost connection is a missed poll, and the next train collects a run this one could not ([how](testing-tools.md#a-remote-train-and-a-lost-connection)).
   The result file of each agent carries
   - a line "Run on GitHub" with the run's link,
   - a line "iOS build of the merged tree on GitHub" with the iPhone build's verdict,
   - the iOS errors in the files its branch changes (as a Mac train's census listed them), and,
   - when the run was asked for the iPhone tests, a line "iPhone tests on GitHub" with their verdict, Executed line and the count of each bundle, and the failures in the iPhone test classes (unit or interface) the agent asked for.

   `run_suite.py --remote` prints the same verdicts, the files the errors are in with how many errors each holds, and each failed iPhone test, unit or interface, with its bundle.

## Reading a run
<!-- id: reading-run; keys: troubleshooting, failed run, cancelled run, artifact, retry, gh CLI; src: Scripts/agents/run_suite.py, Scripts/agents/build-train.py, .github/workflows/tests.yml -->

- **From the Mac:** the train's folder, `build/orchestrator/train/trains/<id>/`, holds `run.log`, `run-summary.txt`, `summary.md`, and `remote.json` (the run's link and minutes); a retry without a broken branch keeps each run's download in `remote-1`, `remote-2`.
  `run_suite.py --remote` writes the log to the LOG it was given.
- **By hand:** `gh run list -R AERobertAI/TextMouth --branch TestBuild`, then `gh run view <id>` for the jobs and `gh run download <id> -n test-build-results -D <new empty folder>` for the files.
  A shard's own files are the artifacts `shard-results-1` to `-4`, kept for two days; the joined one is kept five.
  The run's page also shows `summary.md`.
- **Counts:** a run's tests are counted from the log's own `Test Case` lines.
  The `Executed` line that xcodebuild closes with counts only the test host's last launch, so after a restart it understates (a shard that restarted 14 times said 967 tests with 2,882 results in its log).
- **The three kinds of failed run:** the tests failed (the files come back, and the verdict is FAILED); the run was cancelled, timed out, or never started (nothing is trusted, and a train puts its requests back in the queue); the push failed.
  Only the first is a result.

## What differs from this Mac
<!-- id: what-differs-from-this-mac; keys: coreaudiod, virtual machine, spindump, thread pool starvation, skip list, test timeout, no_skips; src: TextMouth/Parsers/AudioMediaProbe.swift, TextMouth/Services/VoiceCatalog.swift, TextMouthProductionTests/EpisodeDownloadContinuationTests.swift, TextMouthProductionTests/PreRenderedSpeechInvalidationTests.swift, TextMouthProductionTests/EndBehaviorMatrixTests.swift, TextMouth/Parsers/ParserUtilities.swift, TextMouthProductionTests/VoiceCatalogTests.swift, TextMouthProductionTests/ReadingListReaderTests.swift, TextMouthProductionTests/ImportProgressTests.swift, TextMouthProductionTests/RetainedPackageImportTests.swift, TextMouthProductionTests/PodcastChaptersHeadingsTests.swift, TextMouthProductionTests/PublishedFileProgressTests.swift, TextMouthProductionTests/ReaderAudioFailureTests.swift, Scripts/agents/run-on-runner.py, Scripts/agents/runner_settings.py, Scripts/agents/runner_diagnose.py, Scripts/agents/runner_audio_probe.py, Scripts/agents/runner_ax_probe.py, .github/workflows/tests.yml -->

The runner is a virtual machine: macOS 26.7.2 on arm64 (this Mac runs 26.3.1), no display session, no sound hardware that works, and no Accessibility permission.

- **Audio.**
  AudioQueue cannot start there ("_Start: Error (-4) getting reporterIDs"), though the machine lists an Apple Virtual Sound Device.
  Restarting `coreaudiod` before the tests (the workflow's "Restart the audio service" step) made the tests that read silent audio files run in a minute instead of waiting out their 5-minute limits.
  In the reading-list area, 101 tests took 63 seconds, and without the restart each of its tests waited 300 seconds.
  A virtual device installed from Homebrew did no better than the restart alone.
  Tests that decode audio hung once: the spindump of one (run 42856695469) shows `AudioMediaProbe.decodesSamples` in `-[AVAssetReaderTrackOutput copyNextSampleBuffer]`.
  With the job as it is now, `AVAssetReader` decodes in 0.06 to 0.15 s (a probe, request key `audio_probe`), so the hang has not been seen again, and 87 audio tests left the skip list.
  With every skip off, the 24 audio classes ran 598 tests in 183 s, and only the 2 `AudioEngineBehaviorTests` failed, since AudioQueue cannot start.
  The app still contains a hang (see The audio-decoding hang under Rules the runner's failures led to).
- **A blocked call in the concurrency pool starves the app.**
  Swift's pool has one thread for each core, and the runner has 3 or 4.
  `AVSpeechSynthesisVoice.speechVoices()` waits on a semaphore with no limit that the runner's speech service never signals, so three listings in pool tasks hold all three threads, and every other task of the process (a download's, a reader's, a test's) waits behind them.
  The spindumps of `EpisodeDownloadContinuationTests.testACancelAfterTheListenerPlayedAgainSaysNothing` and `PreRenderedSpeechInvalidationTests.testChangingThePunctuationPausesNeverPlaysTheOldPauses` showed it.
  They show "Workqueue exceeded cooperative thread limit", three threads in `VoiceCatalog.installedVoices()`.
  So did the first reading-list hang.
  The listing runs on one dispatch queue (`VoiceCatalogTests.testListingsThatNeverComeBackLeaveTheConcurrencyPoolFree`).
  `ReadingListReaderTests`, `EpisodeDownloadContinuationTests`, `PreRenderedSpeechInvalidationTests`, `EndBehaviorMatrixTests`, `ImportProgressTests` and `RetainedPackageImportTests` all pass with no skips.
- **Keyboard navigation** is off on a runner, so the tests that press Tab through a hosted window skipped.
  `Scripts/agents/runner_settings.py` runs `defaults write NSGlobalDomain AppleKeyboardUIMode -int 2` (what turning the setting on does) on a runner only, and 3 of the 4 `BookmarkKeyboardAccessTests` that skipped now run.
- **Probes** are request keys sent by hand with `github_run.py`; no train or suite sets them, and nothing they print is a verdict.
  `diagnose` times the machine, package resolution, a build with no change, and a leaf and a hub edit, and names the files recompiled (`runner_diagnose.py`).
  `audio_probe` asks whether audio decodes (`runner_audio_probe.py`), `ax_probe` whether a process can be an accessibility client (`runner_ax_probe.py`), and `parallel_workers` (2 or 3) runs the tests in clones of the test host.
  Parallel hosts ran 22 classes (553 tests) in 224 s against about 406 s in one, but their log is in Swift's "Test case 'X.y()' passed on 'My Mac (pid)'" form, which the readers of the train, the merge, and `run-area.py` do not count ("Executed 0 tests"), so they are not used.
- **The 2-minute limit.**
  `-test-timeouts-enabled` fails a test that passes its allowance; xcodebuild rounds the allowance up to a whole minute (its logs say "exceeded execution time allowance of 2 minutes"), so the runner sets 120 seconds, and then restarts the test host and goes on.
  One hung test costs about 2 minutes and not 5 (or all night: the first full run spent 80 minutes on 214 tests).
  The slowest test on this Mac takes 21 seconds.

### Tests left out
<!-- id: tests-left-out; keys: runner-skips.conf, skip list, no_skips, Not run on GitHub, accessibility tests, virtual machine; src: Scripts/agents/runner-skips.conf, Scripts/agents/runner_skips.py, Scripts/agents/run-on-runner.py, Scripts/agents/tests/test_run_on_runner.py, Scripts/agents/github_run.py, Scripts/agents/build-train.py, Scripts/test/run-area.py -->

- **Tests left out.**
  `Scripts/agents/runner-skips.conf` lists what the runner does not run: 14 entries, each one test, of about 12,470 tests.
  Each is `Class.testName  # reason`, and each reason says why the test cannot work on the runner and that it still runs on this Mac.
  The audio tests are no longer among them (see Audio under What differs from this Mac).
  The families that stay out:
  - `AudioEngineBehaviorTests` (2): AudioQueue cannot start there;
  - `OggAfconvertTests` and `OggAudioConverterTests` (1 each): they pass Ogg to Apple's decoders, which once locked up a Mac, so no run is allowed to exercise them;
  - `BookmarkKeyboardAccessTests` (1): with Keyboard navigation on, the focus never settles in a session with no active window;
  - `DocumentGoldenTests` (2): goldens recorded on this Mac's macOS, which another macOS draws differently;
  - `MetadataEditorBaselineTests` (3): they read labelled text fields through accessibility, and the runner exposes none;
  - `IntegrationPersistenceTests`, `MenuKeyShortcutTests`, `LibraryLaunchFilesTests`, and `RecordingSaveTests` (1 each): the flaky ones below.
  A request that says `"no_skips": true` (sent by hand with `github_run.py`; no train or suite sets it) runs with none of the skips, as a probe of which entries are still needed.
  The file is read strictly: a line that does not parse stops the job, and `test_run_on_runner.py` checks that each entry names a test of its own class, that its reason says the Mac still runs it, and that version control keeps the file.
  A run's `summary.md` says how many entries it left out.
- **What an agent is told about them.**
  A remote result has a line "Not run on GitHub, no verdict: X (reason)" for each class or test the agent asked for (its classes, and the classes of its areas) that the merged tree's skips file leaves out, so a PASSED verdict is never read as covering them.
  A request of only skipped classes pushes nothing and has no verdict.
  To run them on this Mac the orchestrator uses a local `python3 -I Scripts/agents/build-train.py run` (without `--remote`), which takes the heavy-work lock and builds here; `run-area.py` on its own does not take the lock.
- **Accessibility tests skip,** as they do on any session that exposes none (the HOSTED_ACCESSIBILITY_UNAVAILABLE and SWIFTUI_ELEMENTS_UNEXPOSED lines in the log).
  About 50 skip at run time with "no accessibility elements for the AppKit controls": the runner's hosted window exposes nothing, even to a trusted process (`AXIsProcessTrusted` is true and it finds 1 `AXGroup`, also with VoiceOver's Quickstart started), and no cause or fix was found.
  The 34 that say SwiftUI exposes its elements only to an accessibility client skip on this Mac too.
  A full run skips about 160 tests in all, the 14 entries among them.
- A test must not pin a limit that depends on a machine's speed: a search time tuned on the runner, and AppKit's type-select wait (under 1.0 s on this Mac, 1.2 to 1.3 s on the runner), each failed on the other machine.
  Pin margins every Mac meets.

## Time
<!-- id: time; keys: duration, how long, speed, performance, cache, bootstatus, simctl, minutes; src: TextMouthiOSUITests/TextMouthUITestCase.swift, .github/workflows/tests.yml, Scripts/agents/class-times.json, Scripts/agents/run-ios-ui-tests.py -->

Measured on the `macos-26` runner (Xcode 26.0.1).
The runs are listed in the report of the `cisuite` branch (`ci/suite-clean`); the numbers here are the ones that matter.

- **Build:** about 8 minutes from nothing, and about 2 minutes on a Mac job with the last run's products restored (the 640 MB cache restores in 15 to 20 seconds); the iPhone app builds in 3.5.
  Package resolution takes about 20 seconds, a rebuild with no change 8 to 11, and a one-file edit 40 to 45.
  The runner has 3 cores (M1) and 7 GB, and a free account runs 5 macOS jobs at once.
- **A few areas:** 8 to 10 minutes from the push to the downloaded results on a cold cache; a train of a few classes is 3 to 4 minutes on a warm one.
- **The full suite:** 12,468 tests took 26.3 minutes from the push to the downloaded results (run 43696270961, no failure): 3 Mac shards of 12.9, 13.8, and 14.9 minutes, and the iPhone job of 25.4.
  Before the file-time fix below it took 35.8: 4 shards of 12.0 to 14.5, and the iPhone job of 35.3.
  A train of 3 classes took 8.9 minutes (the Mac 3.6, the iPhone job 7.8), against 13.9 before.
  - A machine is ready 2 to 5 seconds after the job is queued, and setup (Xcode, XcodeGen, the cache) takes about 30 seconds.
  - **A cached build compiles only the files whose text changed.**
    `Scripts/agents/restore_mtimes.py` gives every tracked file a modification time taken from its own git blob hash, so the same text has the same time in every run, whichever run built the cached products.
    Before that, an unchanged file got one fixed time and a changed file kept its checkout time, which the cached build recorded and no later run could give back: a tree with nothing new recompiled 154 files, and a day's changes 1,562 (387 s).
    With 7 files changed, 4 compiled and the build took 109 s, and the full-suite iPhone build fell from 7.3 to 3.5 minutes.
    Putting the time back to one fixed value fails `test_the_same_text_has_the_same_time_whichever_run_it_is_checked_out_in`.
  - The shards are dealt out by the times in `class-times.json` (refreshed: 3 shards of about 574 seconds each, one shard per 600 seconds of tests).
  - **Building once and sharing the products** would not help: a build is now 2 to 3 minutes, and uploading and downloading the products would cost as much.
- **The iPhone job** (beside the shards): the platform download takes 3.4 to 4.9 minutes, the build 3.5 (7.3 before the file-time fix), and the simulator's set-up 5.8 (its first boot about 5.7), so it is on the longest path whenever it runs the interface tests.
  - **Three cuts** after run 43716590818, whose two jobs spent 11.6 and 8.2 minutes building and 3.6 and 3.4 setting up the simulator.
    The build names one architecture, since 1,086 files had been compiled twice; the keyboard settings are no longer written (the typing tests dismiss its first-use page).
    `Scripts/agents/ios-class-times.json` holds the interface classes' measured times (873 seconds, not 673), with `TARGET_SHARD_SECONDS` at 600, so the full suite stays two iPhone jobs (a third comes past 1,200 seconds of tests).
    The next full run took 26.2 minutes in all (34.1 before), its iPhone jobs 25.1 and 26.7.
  - **The interface tests add the most.**
    A launch of the app takes 10 to 15 seconds on the runner's three slow cores, and the tests wait for screens.
    The 35 interface tests took about 733 seconds, and the unit bundle's 1,979 tests (the Mac's shared test files among them) 71 seconds; the whole step took 17.5 minutes, 2.3 of them the simulator's set-up.
    So the interface tests, not the unit tests, are what to split, and the iPhone job is the longest of a full run.
    Two clones of the simulator took 17.1 minutes against 17.5 for one.
  - **Two cuts that were tried.**
    Looking with `exists` before a wait (`XCUIElement.appears(within:)`), the keyboard's one-time page checked with `exists`, and the timer test waiting for its value to change cost nothing and saved time.
    Starting the simulator while the app builds was tried and taken out: the runs that did it found `bootstatus` still waiting after 300 seconds, so did one with the change undone, and the next booted in 2.5 minutes; the cause is not known.
    A boot that never finishes stopped the interface tests of four runs (42976557216, 42979000712, 42982618359 and 43005173856), `bootstatus` printing "Waiting on BackBoard" for the whole 300 seconds.
    So the first boot is waited for 180 seconds; a device that has not booted by then is shut down, a new one is made and booted (300 seconds); and a boot that still does not finish is a failure whose message holds what `simctl` had printed and the booted devices.
  - **So a request for the phone area or a full suite waits for the iPhone job**, not for the shards.
    A request that names no interface test class and no phone area pays nothing.
- **What this Mac spends:** a merge, a push, and a wait.
  No build, no test host, no heavy-work lock.

## Rules the runner's failures led to
<!-- id: runner-failure-rules; keys: cancellation, hang, timeScale, time scale, deadline, flaky, race; src: TextMouth/Services/VoiceCatalog.swift, TextMouthProductionTests/HostedTestIsolationSupport.swift, TextMouthProductionTests/EpisodeDownloadContinuationTests.swift, TextMouthProductionTests/PreRenderedSpeechInvalidationTests.swift, TextMouthProductionTests/ReadingListReaderTests.swift, TextMouth/Parsers/AudioMediaProbe.swift, TextMouth/Parsers/XMLInputGuard.swift, TextMouth/Parsers/PackageSAXParser.swift, TextMouthProductionTests/VoiceCatalogTests.swift, TextMouthProductionTests/OfficeXMLGuardTests.swift, TextMouthProductionTests/OwnReaderCancellationTests.swift, TextMouthProductionTests/XMLInputGuardTests.swift, TextMouthProductionTests/KF8HostileFileTests.swift, TextMouthProductionTests/MOBIHostileFileTests.swift, TextMouthProductionTests/SpeechBufferSynthesizerTests.swift, TextMouthProductionTests/AudioEngineBehaviorTests.swift, Scripts/agents/run-on-runner.py -->

- **The voice listing never holds the concurrency pool:** `VoiceCatalog` lists voices on a queue of its own and on a thread of its own, so the pool is never held.
  Each catalog has its own queue, one listing at a time:
  - a listing replaced while it waits is skipped there,
  - a listing that has not returned after `listingDeadline` (10 seconds) is given up on and the queue goes on (so one hung listing cannot stop `VoiceCatalog.shared` from refreshing for the rest of the session), and
  - `waitUntilListed(limit: 15)` says whether it waited the listing out; the phone's voice sheet goes on with no voices when it did not.
  Proven by `VoiceCatalogTests.testListingsThatNeverComeBackLeaveTheConcurrencyPoolFree`.
  On this Mac's own code paths it is proven by `testAListingCancelledWhileItWaitsOnTheQueueIsSkipped`, `testAListingThatNeverReturnsIsGivenUpOnAndTheNextOneIsListed`, and `testWaitingForAListingThatDoesNotEndGivesUpAtItsLimit`.
- **A cancel is heard at once** (`OfficeXMLGuardTests.testCancelLandsInTheMiddleOfARead`, `OwnReaderCancellationTests.testCancelPartwayThroughALargeWordDocumentIsHeardAtOnce`).
  `XMLInputGuard`'s attribute-count scan of the whole part, which runs before the parser, asks every 4,096 start tags whether the import was cancelled.
  `XMLInputGuard.problem(throwingWhenCancelled:)`, which `PackageSAXParser.parseDocument()` uses, throws `ImportCancelled` for a scan it did not finish (it never answers nil for one, so a caller cannot forget to ask before it hands the part to a parser).
  `XMLInputGuardTests.testACancelledImportEndsTheGuardsScanAtOnceAndNoParserSeesThePart` measures the scan against the same scan uncancelled on the same machine, so it holds on both machines with no scale.
- **Timing tests that cannot compare the app with itself** (`KF8HostileFileTests`, `MOBIHostileFileTests`): their limits are multiplied by `TestMachine.timeScale`, which is 1 unless the runner's script sets `TEXTMOUTH_TEST_TIME_SCALE` (2.5, through `TEST_RUNNER_TEXTMOUTH_TEST_TIME_SCALE`).
  The development Mac sets nothing, so its limits are as written, and a value below 1 is read as 1.
  A request may carry `time_scale` to try another, from 1 to 10; anything else (a word, a truth value, 0.5, 1000) makes the run fail with its results written and no test run ("FAILED: the request's time_scale ...").
  A new timing test that has no uncancelled run of its own to compare with uses `TestMachine.allowed(seconds)`.
- **The audio-decoding hang** is contained, and the runner no longer shows it.
  `AudioMediaProbe`'s decode check (`AVAssetReader`'s `copyNextSampleBuffer`, which never returns on the runner's audio) runs on a dispatch queue and not in the pool, so a hung read takes one thread and not the tests after it.
  The probe waits for it at most `decodeDeadline` (60 seconds).
  `AudioMediaProbe.duration(of:decoding:deadline:)` takes the check and the deadline, so a test can hold it.
  Past the deadline the readers are told `cancelReading()` (whether that ends a hung read has not been seen: the hang cannot be made to happen on demand).
  The file passes on its header's length rather than being refused as damaged, since a read that is only slow must not make a book "damaged".
  A check that still does not return keeps one dispatch thread.
  Three tests with a held check prove it: the passed-in check decides, a hung check is given up on at the deadline, and more held checks than cores leave the pool free.
  The tests that read audio now run on the runner.
- **`SpeechBufferSynthesizerTests.testStopEndsAWriteAtOnce`** looks up a stand-in voice first, which takes longer on a cold runner, so it presses Stop only after the write has started.
  `testStopPressedBeforeTheWriteStartsEndsItWithNothingToStop` pins the other outcome.
- **A run that failed with no failed test** says why on its page: the function `unexplained_failure` in `Scripts/agents/run-on-runner.py`, which that script's `judge` calls, names the first ERROR line, else the first CRASH line, else that the log lacks `** TEST SUCCEEDED **`.

## Flaky or unexplained on the runner
<!-- id: flaky-unexplained-runner; keys: intermittent, flake, not retried, 503, rate limit, egress, network error; src: TextMouthProductionTests/IntegrationPersistenceTests.swift, TextMouthProductionTests/MenuKeyShortcutTests.swift, TextMouthProductionTests/LibraryLaunchFilesTests.swift, TextMouthProductionTests/RecordingSaveTests.swift, TextMouthProductionTests/IntegrationWindowRoutingTests.swift, TextMouthProductionTests/ContinueToNextBookTests.swift, TextMouthProductionTests/PreferenceStoreTests.swift, TextMouthProductionTests/MigrationStagingLeftoversTests.swift, TextMouthProductionTests/ReaderLifecycleAuditTests.swift, TextMouthProductionTests/NowPlayingOwnershipTests.swift, TextMouthProductionTests/HostedTestIsolationTests.swift, Scripts/agents/runner-skips.conf, Scripts/agents/github_run.py, Scripts/agents/merge_shards.py -->

These failed on the runner in some runs and not others, and nobody found the cause.
Xcode runs a failing test again, up to three tries in all (`RETRY_ARGUMENTS` in `Scripts/agents/test_command.py`, for the suite and the trains), and the run passes when one try does.
The result lists each test that needed a second try as RETRIED (`test_tries.py` reads them from the log), so one that fails now and then stays visible.
The ones named in the skip list are left out there, the others are expected now and then in a remote result, and one that appears twice in a row on a quiet change deserves a look on this Mac.
To prove a flaky test fixed, a request's `test_iterations` (2 to 100) runs every test that many times, on the Mac and on the iPhone, with Xcode's retry off so a second try cannot hide a failure (`Scripts/agents/test_command.py`, `run-on-runner.py`, `run-ios-ui-tests.py`).

- Rebalanced shards change which classes share a test host, and that brings out order dependencies that a fixed order hid.
- **Left out, cause not found:**
  - `IntegrationPersistenceTests.testReadOnlyDataDirectoryShowsTheFailedSaveUntilRetryWritesIt` and `MenuKeyShortcutTests.testTheMenusShowTheKeysInForceAndFollowAChange`: a wait of 5 seconds for the main queue or SwiftUI missed in 3 of 5 and 3 of 4 full runs.
    The diagnostic of run 42881292091 showed the failure recorded at once and published only after the wait, with a block queued afterwards running.
  - `LibraryLaunchFilesTests.testNoMoreThanEightLaunchFilesAreReadAtOnce`: an 8-second wait for queued reads missed in 2 of 12 runs.
  - `RecordingSaveTests.testSavingARecordingAddsItsBookToTheLibrary`: a file missing at the end, 2 of 6 runs.
  - `IntegrationWindowRoutingTests.testFinishedBookOpensOneReaderForTheNextBookWithNoLibraryWindow` and two ContinueToNextBookTests are left out because an audio book did not finish loading.
- **Explained and fixed:**
  - `LibraryFeedMoveToFolderTests` failed on a record save that belonged to another test: a Delete Download test made its own feed engine and stopped it only at teardown, so its last record writes landed after the folders were gone and were announced into the next test that records announcements.
    Every extra engine now comes from `FeedTestWorld.engine(_:on:)` (see [the hosted-test sandbox](../architecture/state/hosted-test-sandbox.md)).
  - `ReaderCloudDownloadTests` heard "Settings could not be saved: The folder config.json doesn't exist.": an earlier test's settings change left a save waiting 250 milliseconds, and its folders were deleted before it fired.
    Every settings service a test makes comes from `makeConfigService(fileURL:)` now, whose teardown drops the waiting save, and `ConfigTestWorldTeardownTests` fails for one made another way.
    The flake was never reproduced, before or after: a test shows the mechanism, and the train after the fix passed (see [the hosted-test sandbox](../architecture/state/hosted-test-sandbox.md)).
  - `LibrarySessionLeaseTests`: a lease ended during a refresh did not wait for the refresh's events; it waits for them now, up to 30 seconds, since the end needs a task-pool thread and the runner has three.
  - `BookManifestEditTests`' hand-edit test (Q16): a taken edit queued a write-back of the title it read, which could land on the test's next save; a take writes nothing back now (20 of 20 failed unfixed, run 44841797810; 2,450 of 2,450 passed, run 44843120549).
- **Not the tests:**
  - GitHub did not give one of the four shards a machine for 15 minutes in run 42867725014 ("The job was not acquired by Runner of type hosted even after multiple attempts": the join named the shard as having reported nothing, and the run failed with no test failed);
  - `xcodebuild -downloadPlatform iOS` failed once with "Unable to connect to simulator."
    (run 42887766443; it is now tried three times); and
  - a dropped connection to api.github.com ended a wait on the Mac (`github_run.py` now tries a failed call four times).

  A run that fails this way is no verdict on the tests: send it again.
  Also, after many downloads of the large result bundles (130 MB for each failed shard), GitHub answered "503 Egress is over the account limit" to `gh run download` for a while; the job logs stayed readable through `gh api repos/AERobertAI/TextMouth/actions/jobs/ID/logs`.
  Download a bundle only to look into a failure.

## Safety
<!-- id: safety; keys: security, permissions, token, secrets, pull request, fork, pinned actions, refspec; src: Scripts/agents/github_run.py, .github/workflows/test-build.yml, .github/workflows/tests.yml, .github/workflows/check.yml, .github/actions/setup-xcode/action.yml, Scripts/agents/tests/test_workflow.py, Scripts/agents/tests/test_github_run.py -->

The workflow reads the repository and nothing else: a read-only token, no secrets, GitHub's own actions pinned to commit hashes, and a trigger of a push to `TestBuild` alone, so a pull request or a fork starts no job.
`Scripts/agents/github_run.py` pushes only `<commit>:refs/heads/TestBuild` (with `--no-follow-tags`, so no tag goes with it), builds that refspec from a constant, makes the commit from tracked files with git's plumbing, and checks before it pushes:
- that no object the push would send, in the tip's tree or in the history behind it that origin does not have, has a path under `build/`, `humanQuestions/`, or `humanReports/` (names are read NUL-separated, so quoted ones are checked too);
- that, once `test-build.yml` is on origin's main (it is, so the guard is on), the tree's `.github/workflows/` and `.github/actions/` are the same as main's, so a merged branch cannot widen the workflow's permissions or add a step; and
- that origin's push URL is this repository's.

`.github/workflows/check.yml` (`make check`) runs for pushes to `main` and for pull requests, and not for `TestBuild`; a test keeps it so.
The workflow tests (`Scripts/agents/tests/test_workflow.py`) pin these rules for the three files (`test-build.yml`, the shared `tests.yml`, and the local action `setup-xcode`) and for the jobs `check.yml` calls them with:
- that `tests.yml` has no concurrency group of its own (one could cancel the caller's runs),
- that `check.yml` is in a group that is not `test-build`,
- that the request given as an input reaches a job only through the environment, and
- that every action is GitHub's own and pinned to a hash.

Workflow changes can be proved on `TestBuild` only for what `test-build.yml` shares with `check.yml`; the gate job and the call from `check.yml` itself run only for a push to main or a pull request.

The tests of all of this are in `Scripts/agents/tests`: the fake `gh`, the bare throwaway repository used as the push target, and the pretend clock mean none reaches GitHub or waits.
