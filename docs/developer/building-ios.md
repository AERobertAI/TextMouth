# Building the iOS app
<!-- id: building-ios-app; keys: TextMouthiOS, iPhone app, simulator, xcodebuild, typecheck; src: project.yml, Makefile -->

Part of [TextMouth's documentation](../../README.md).

## The iOS app
<!-- id: ios-app; keys: TextMouthiOS target, second app target, LAME_iOS, ObjCExceptionCatcher_iOS, Platform/iOS, scheme; src: project.yml, TextMouth.xcodeproj/xcshareddata/xcschemes/TextMouthiOS.xcscheme, TextMouth/Platform/iOS/Info.plist -->

project.yml defines two apps over one source folder.
`TextMouth` is the Mac app, which every other target and command on this page builds.
`TextMouthiOS` is the iOS app, added in phase 0 of the iOS port (see [The two apps and the platform folders](../architecture/platforms.md)):

- It compiles the TextMouth source folder less `TextMouth/Platform/macOS/` and the Mac's `TextMouth/Resources/`, so it compiles the files both apps share and `TextMouth/Platform/iOS/`.
- It is the product TextMouth, with the module name TextMouth, for iOS 26.0, and has a bundle identifier of its own, `com.textmouth.TextMouth.iOS`.
  It takes the same two Swift packages (ZIPFoundation and swift-markdown's Markdown), the vendored SwiftSoup through its own library target, SwiftSoup_iOS, and its own builds of the two C libraries it links, `LAME_iOS` and `ObjCExceptionCatcher_iOS`.
  The file project.yml defines each library, SwiftSoup included, once, as a target template, and builds it for each platform; the Mac targets' settings are as they were.
- It has no helper program, since iOS lets an app start none, and no braille helper or liblouis.
- It is the iPhone app: the Library, the reader, Settings, and importing, built from research/IOS-INTERFACE-SPEC-2026-11-07.md (see [The two apps and the platform folders](../architecture/platforms.md)).
  Nothing has run on a phone.
- Its scheme, `TextMouthiOS`, is committed.
  The Mac's schemes are still Xcode's own, so `-scheme TextMouth`, which `make build` and the tests use, builds the Mac app alone.
- Xcode builds it only once its iOS platform is downloaded (see [What you need](building.md)).
  Until then, `make typecheck-ios` is how its code is checked.
- Building it for the simulator is the next section.

## The type-check and projection targets
<!-- id: type-check-projection-targets; keys: typecheck-ios, typecheck-mac, typecheck-tests, mac-projection, CENSUS, SwiftPM probe package, build/typecheck; src: Scripts/ios/typecheck.py, Scripts/ios/mac-projection.py, Makefile, Scripts/agents/heavy_lock.py -->

The three make targets run the scripts in `Scripts/ios`.
They read a commit, so run them on committed work.
Each reads the commit as it was when it started (`Scripts/ios/typecheck.py` takes a `git archive` of it), not the working tree: commit first, and start the check again after a later commit.

- **`make typecheck-ios`** copies the committed sources of HEAD into a work folder of its own, writes a Swift package around them, and builds it with SwiftPM and the iOS SDK, for iOS 26.0, compiling the sources the iOS app compiles and linking the two C libraries.
  It never changes the repository.
  A clean run means the iOS app's sources compile and link; because it builds a package of its own and not the Xcode target, it does not test the target's build settings.
  It takes about two minutes once it has the lock.
  `CENSUS=1` reads each `import AppKit` as `import UIKit` in the copy, so that a file does not stop at "no such module 'AppKit'" and every AppKit name left in it is reported; it counts what is left, and is not what the app must pass.
  The run without it is the strict one.
- **`make typecheck-mac`** does the same for the Mac: the sources the Mac app compiles, built and linked in about two minutes, without xcodebuild or the hosted tests.
  It ends BUILD SUCCEEDED when the Mac app's code compiles and links.
- **`make typecheck-tests`** is `make typecheck-mac` with the Mac's hosted test target in the package.
  It copies the folder `TextMouthProductionTests` and the files `project.yml` lists for that target from `TextMouthTests/Sources/Tests` into one target of the probe package and builds it with `swift build --target TextMouthProductionTests`.
  It compiles the app and the tests, links no test bundle, and runs no test (SwiftPM link step for a test bundle fails with this Xcode toolchain, with unexpected input file plugins/testing, after every file has compiled, and that is not a test file error).
  An error in a listed file is reported under the file's repository path.
  `REF=<commit>` checks that commit (default HEAD) from any worktree, so an agent can check its branch before asking for a train.
  It has its own work folder (`build/typecheck/macos-tests/`), takes the heavy-work lock itself, and takes about four minutes when most test files compile again, six from a cold start, and seconds when nothing changed, after the wait for the lock.
  Never wrap it in `run_locked.py`.
- **`make mac-projection BASE=main`** compares, for each Swift file the Mac compiles that HEAD changes since BASE (`HEAD=` names another ref), what the Mac compiles of the old text and of the new.
  A file moved into `Platform/macOS`, Mac code wrapped in `#if os(macOS)`, and a platform alias or helper that is exactly the old type or expression on the Mac all count as unchanged.
  It prints the number of files changed, the number unchanged for the Mac, and the number with a real change, and with `DIFF=1` the lines that remain in each of those.
  It changes nothing and writes no file.
  It is for a change that must leave the Mac's behavior as it was: the aim is no real change, or only lines a reviewer can defend one by one.

The two type-checks print their result and write it to `build/typecheck/results/` in the main checkout, which git ignores, in a folder for each run, named by who ran it, the platform, the mode, the commit, and the time.
The folder holds `summary.md` (the result, the errors and warnings in the app, the link, the errors by file, and the kinds of error), `errors.txt`, `warnings.txt`, and `build.log`, and the last line of the output names it.
A run exits with status 0 when the build succeeded, 1 when it found errors, 2 when it could not set up, and 3 when the lock stayed busy for the whole wait.

## The heavy-work lock
<!-- id: heavy-work-lock; keys: heavy_lock.py, run_locked.py, lock folder, build train, 8 GB memory, run_suite.py; src: Scripts/agents/heavy_lock.py, Scripts/agents/run_locked.py, Scripts/agents/build-train.py, Scripts/agents/run_suite.py, Scripts/agents/tests/test_heavy_lock.py, Scripts/agents/tests/test_run_locked.py -->

**The heavy-work lock.**
The Mac has 8 GB of memory, and several builds at once freeze it, so one heavy job runs on it at a time.
The type-checks and the build train both take a lock (`Scripts/agents/heavy_lock.py`) before they start: a folder made with mkdir, build/orchestrator/heavy-lock in the main checkout, holding its owner's process ID, name, and start time.
A job that finds it held says whom it waits for and since when, and waits, a type-check by default up to three hours.
A lock whose owner has ended, from a crash or a killed agent, is taken over.
So a type-check started while the train builds waits for the train, and the reverse.
The build train waits first in line: while it waits, no other job takes the lock, even a free one, so the train goes next, and it never runs without the lock.
`Scripts/agents/tests` holds the tests of the lock, the train, `run_locked.py`, `run_suite.py`, `copy_phases.py`, and `regenerate-project.py`: `python3 -I -B -m unittest discover -s Scripts/agents/tests`.
They use temporary locks and folders, a fake command for the suite, and a stand-in for xcodegen, so none runs xcodebuild or touches the real lock.
The tests of the GitHub runs add a fake `gh`, a bare throwaway repository as the push target, and a pretend clock, so none reaches GitHub or waits.

## Builds on GitHub Actions
<!-- id: builds-github-actions; keys: TestBuild, test-build.yml, tests.yml, run-on-runner.py, github_run.py, shards, actions/cache, setup-xcode; src: .github/workflows/test-build.yml, .github/workflows/tests.yml, .github/workflows/check.yml, .github/actions/setup-xcode/action.yml, Scripts/agents/run-on-runner.py, Scripts/agents/test_command.py, Scripts/agents/run-ios-build.py, Scripts/agents/run-ios-ui-tests.py, Scripts/agents/github_run.py, Scripts/agents/build-train.py, Scripts/agents/run_suite.py, Scripts/agents/restore_mtimes.py, Scripts/agents/shard.py, Scripts/agents/plan_shards.py, Scripts/agents/merge_shards.py, Scripts/agents/runner-skips.conf -->

**Builds on GitHub Actions.**
The compiling and testing run on GitHub Actions, which spares this Mac's CPU.
The repository is public (`github.com/AERobertAI/TextMouth`), and free hosted runners are used.
- **What runs there.**
  `.github/workflows/test-build.yml` runs for a push to the branch `TestBuild`, and for nothing else: not a pull request, not a fork.
  It only calls `.github/workflows/tests.yml`, which holds the jobs and which `check.yml` calls too (so the repository has one way to run its suite on GitHub), and the local action `.github/actions/setup-xcode` holds the toolchain pins once.
  A job:
  - selects Xcode 26.0.1 on the `macos-26` image;
  - installs XcodeGen 2.45.3 (checked against its published digest);
  - runs `make generate`;
  - and then `Scripts/agents/run-on-runner.py`, which reads the request file `.github/test-request.json` in the pushed tree and runs what it names: areas and classes through `Scripts/test/run-area.py`, or the full suite.

  Both commands come from `Scripts/agents/test_command.py`, the one place the local train, `run_suite.py`, and the runner take them from.
  The app is not signed (`CODE_SIGNING_ALLOWED=NO`), as in every test run, since a runner has no signing identity.
  The job has a token that may only read, no secrets, GitHub's own actions pinned to full commit hashes, a limit of 100 minutes for each job (the runner script stops the tests at 80, so their results are still written), and one run at a time: a newer push cancels the older run.
  The shared workflow has four jobs: a Linux job that plans the shards, one macOS job per shard, a macOS job that builds the iPhone app and runs its interface tests, and a Linux job that joins the results.
  The iPhone job (`Scripts/agents/run-ios-build.py`) runs `xcodebuild build-for-testing` on the `TextMouthiOS` scheme for a generic iOS Simulator destination, which compiles the app and both of its test bundles (`TextMouthiOSTests` and `TextMouthiOSUITests`) without signing or running a test.
  It writes `ios-summary.txt`, `ios-errors.txt` (each error as `path:line:col: error: message`, repository-relative), and `ios.log`, and its errors are a result, not a failure: they never decide whether the tests passed.
  A request that says `"ios": false` leaves it out.
  Then `Scripts/agents/run-ios-ui-tests.py` runs the unit tests (`TextMouthiOSTests`, 19, which make no sound) and the interface tests (`TextMouthiOSUITests`) in one `xcodebuild` run, in an iPhone 17 simulator on the downloaded iOS 26.0.1 runtime.
  It does so when the request asks for them (every full suite, the phone area, or a class of either bundle).
  The interface tests press Play and type as a person does, which is why the iPhone tests run there and not here: no iPhone test of either bundle needs a simulator on this Mac.
  It writes `ios-ui-summary.txt` (the unit tests and the interface tests counted apart) and `ios-ui.log`.
  A failed or missing iPhone test fails the iPhone job and never the Mac tests' verdict (see [Tests on GitHub Actions](testing-github.md)).
### The Mac's push, the caches, and what to keep
<!-- id: github-mac-push-caches-keep; keys: github_run.py, TestBuild push, refspec, actions/cache, restore_mtimes.py, shards; src: Scripts/agents/github_run.py, Scripts/agents/build-train.py, Scripts/agents/run_suite.py, Scripts/agents/restore_mtimes.py, Scripts/agents/shard.py, Scripts/agents/plan_shards.py, Scripts/agents/merge_shards.py, .github/workflows/tests.yml, .github/workflows/test-build.yml -->

- **What the Mac does.**
  `build-train.py run --remote` (and `loop --remote`) merges the requests here, pushes the merged tree plus the request to `TestBuild` with `--force`, waits for that commit's run, and reads the result; `run_suite.py --remote COMMIT NAME LOG` does it for the full suite.
  `Scripts/agents/github_run.py` is the Mac's side:
  - it makes the commit with git's plumbing in a temporary index (no checkout is touched);
  - refuses a tree holding a path under `build/`, `humanQuestions/`, or `humanReports/`;
  - waits (up to 125 minutes, asking GitHub every 30 seconds) while a run is queued or going on `TestBuild`, because a newer push cancels the run before it;
  - and fails with a sentence naming that run, having pushed nothing, if it is still there then (the train puts its requests back, like any failed push);
  - pushes only `<commit>:refs/heads/TestBuild`;
  - finds the run by its SHA;
  - and downloads the artifact `test-build-results`.

  Nothing but `TestBuild` is ever pushed, and the commit holds only what git tracks.
- **Why a run is quick.**
  Three things keep it short.
  The build products are kept between runs with `actions/cache`.
  Each job restores the newest cache for this Xcode, and `Scripts/agents/restore_mtimes.py` gives every tracked file a time taken from its own git blob hash, so the same text has the same time in every run, whichever run built the products.
  A fresh checkout would otherwise make Xcode compile everything again.
  The manifest saved beside the products now only names the files that differ, for the run's page.
  A warm build took about 2 minutes against 8 cold (the cache is about 640 MB, and the first shard of each run saves it).
  To see where a job's minutes go, a request sent by hand may carry `diagnose`, `audio_probe`, `ax_probe`, or `parallel_workers` (see [Tests on GitHub Actions](testing-github.md)).
  A long request runs as up to four jobs side by side, each with its share of the test classes (`Scripts/agents/shard.py` deals them out by their times on the runner in `class-times.json`; `plan_shards.py` starts the jobs; `merge_shards.py` joins their results into the one artifact the Mac reads).
  And a test that waits for something the runner lacks fails after 2 minutes (xcodebuild rounds to the minute), or is left out (`Scripts/agents/runner-skips.conf`).
  [Tests on GitHub Actions](testing-github.md) has the details and the times.
  A cache can go stale: a train once failed to link symbols that its sources held.
  Deleting the Mac caches with `gh api -X DELETE repos/AERobertAI/TextMouth/actions/caches?key=<key>` fixed it.
- **What the user must keep.**
  Actions stays enabled for the repository; the workflow's token needs no setting.
  The workflow lives on `TestBuild` as pushed, so it works before it is merged into main; `gh run list --workflow` looks a file up on the default branch, which is why `github_run.py` finds the run by workflow name and commit instead.

## Building TextMouthiOS for the simulator
<!-- id: building-textmouthios-simulator; keys: xcodebuild, simctl, iPhone 17, DerivedData-ios.noindex, xcresult; src: project.yml, TextMouth.xcodeproj/xcshareddata/xcschemes/TextMouthiOS.xcscheme, Scripts/agents/run_locked.py, Scripts/agents/run-ios-ui-tests.py, TextMouth/Phone/PhoneLaunchRequest.swift -->

The simulator needs the iOS platform and the iPhone 17 simulator runtime that Xcode 26.0.1 installs.
This is how the iPhone team builds and runs the app there.

### The scheme, the build folder, and the device
<!-- id: scheme-build-folder-device; keys: TextMouthiOS.xcscheme, derivedDataPath, DerivedData-ios.noindex, Spotlight, iPhone 17 simulator; src: project.yml, TextMouth.xcodeproj/xcshareddata/xcschemes/TextMouthiOS.xcscheme -->

- **The scheme.**
  - `TextMouthiOS` is committed at `TextMouth.xcodeproj/xcshareddata/xcschemes/TextMouthiOS.xcscheme`.
    XcodeGen writes it from the `scheme:` block of the `TextMouthiOS` target in project.yml.
  - It runs both iOS test bundles, `TextMouthiOSTests` and `TextMouthiOSUITests` (see [Testing the iPhone app](testing-iphone.md)), and gathers no code coverage.
  - The scheme Xcode made by itself held only the UI tests, which is why this one is committed.
- **One build folder.**
  - Every simulator build puts its products in `build/DerivedData-ios.noindex`, with `-derivedDataPath build/DerivedData-ios.noindex`.
    The folder is in `build/`, which git ignores.
  - The name ends in `.noindex` so that Spotlight does not index it.
  - It was 792 MB after the first build and run.
  - It is not the Mac's `build/DerivedData`.
    The two never share a folder.
- **iPhone 17 only.**
  - Every run uses the iPhone 17 simulator, as in `-destination 'platform=iOS Simulator,name=iPhone 17'`.
    Make no new simulator devices.
  - The first boot of a device adds about 2.1 GB of disk.
    The iPhone 17's data is 2.5 GB in all.
  - The disk is tight, so these two costs count against the free space before a run.

### Running under the lock, and no clean builds
<!-- id: running-under-lock-no-clean; keys: run_locked.py, run_suite.py --remote, exit status 3, xcodebuild clean, TestBuild, heavy-work lock; src: Scripts/agents/run_locked.py, Scripts/agents/heavy_lock.py, Scripts/agents/run_suite.py, Scripts/agents/github_run.py -->

- **The heavy-work lock.**
  - Every simulator build or test run goes through `Scripts/agents/run_locked.py`.
    It takes the heavy-work lock (see The heavy-work lock, above), runs one command, and exits with the command's status: `python3 -I Scripts/agents/run_locked.py NAME COMMAND...`.
    NAME says who holds the lock.
  - It waits up to three hours for the lock, and exits with status 3 if it never gets it.
  - Run it with `python3 -I`, which leaves its folder out of the import path.
    It finds `heavy_lock.py` beside itself, so it works from any checkout or worktree, and every one shares the one lock in the main checkout.
  - `Scripts/agents/run_suite.py NAME LOG` does the same for the full hosted suite (`xcodebuild test` on the macOS destination), writing the log to LOG.
    It ends an xcodebuild that stays silent for three minutes after its last test, prints the log's Executed line, and exits 0 only when the log says every test passed.
    Run it from the checkout to test, as a background task.
  - `Scripts/agents/run_suite.py --remote COMMIT NAME LOG` runs that suite on GitHub's macOS runners instead (see Builds on GitHub Actions, above).
    It takes no heavy-work lock, since it loads this Mac with a push only.
    It writes the run's log to LOG and judges it the same way; status 4 means the push or the run failed, which says nothing about the tests.
    It also prints what the run's iPhone build made: its verdict, its error count, and the files the errors are in with how many each holds (the details are in `ios-errors.txt` in the folder `LOG.remote-N`); that never changes the exit status.
    It waits its turn twice: for a train of this Mac's to end (the train's lock), and then, in `github_run.py`, for any run still on `TestBuild`.
  - Never wrap `make typecheck-ios`, `make typecheck-mac`, or `make typecheck-tests` in it.
    They take the same lock themselves, and would wait on their own parent.
- **No clean builds.**
  - Never run `xcodebuild clean`, and never delete the build folder.
    The build is incremental, and a clean one compiles every file again, under the lock, on a Mac with 8 GB of memory.
  - Nobody deletes anything during an agent run, so the next build overwrites a stale build and does not clear it.

### A build and a test pass
<!-- id: build-test-pass; keys: build-for-testing, test-without-building, resultBundlePath, xcresult, parallel-testing-enabled; src: Scripts/agents/run_locked.py, Scripts/agents/run-ios-build.py, Scripts/agents/run-ios-ui-tests.py -->

- **A build.**
  - `build-for-testing` compiles the app and both test bundles without running them.
    Its command has this shape, run under `run_locked.py`: `xcodebuild build-for-testing -project TextMouth.xcodeproj -scheme TextMouthiOS -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData-ios.noindex`.
  - The repository does not record the command line the iPhone team used, so check this shape against `xcodebuild -help` before relying on it.
- **A test pass and its result bundle.**
  - A pass of the iPhone team's last round ran `xcodebuild test-without-building` after a `build-for-testing`, with the `TextMouthiOS` scheme, the one build folder, `-parallel-testing-enabled NO`, and `-resultBundlePath` naming a `.xcresult` bundle for the pass.
    The destination was the iPhone 17 simulator, named by its id.
  - **Give each pass a new result-bundle name** (`pass4.xcresult`, then `pass5.xcresult`).
    The round's report says `xcodebuild` wants a new name for each pass, and nobody deletes anything during a run, so an old bundle stays where it is.
    The exact message of a repeated name was not recorded.
  - The bundle holds each test's results, the screenshots, and the notes the audits keep (see [The audit and its accepted findings](testing-iphone-audit.md)).

### Installing, launching, and the launch variables
<!-- id: installing-launching-launch-variables; keys: simctl install, simctl launch, SIMCTL_CHILD_, TEXTMOUTH_UI_TEST, TEXTMOUTH_OPEN_AT_LAUNCH, screenshot; src: TextMouth/Phone/PhoneLaunchRequest.swift, TextMouthProductionTests/PhoneLaunchRequestTests.swift, project.yml -->

- **Installing and launching.**
  - The app's bundle identifier is `com.textmouth.TextMouth.iOS`, and the product is TextMouth.app.
  - `xcrun simctl install` puts the built app on the booted device, and `xcrun simctl launch` starts it.
    `xcrun simctl io booted screenshot FILE` takes a screenshot, and the app's log is the other way to see what it did.
  - Afterward run `xcrun simctl shutdown all`, since the Mac has 8 GB of memory.
- **The `SIMCTL_CHILD_` launch variables.**
  - `xcrun simctl launch` passes an environment variable to the app when its name starts with `SIMCTL_CHILD_`, and drops that prefix.
  - The app reads two variables, `TEXTMOUTH_UI_TEST` and `TEXTMOUTH_OPEN_AT_LAUNCH`, in Debug builds only.
    Both are described in PhoneLaunchRequest in [The two apps and the platform folders](../architecture/platforms.md).
    A Release build does not hold the type or the variable names, so no environment variable can steer it.
  - The placement probe's variable, `TEXTMOUTH_PROBE_SYSTEM_PLACEMENT`, is gone, with the probe test.
    Setting it now does nothing.
  - `SIMCTL_CHILD_TEXTMOUTH_UI_TEST=1` gives the launch a library of its own, in a sandbox.
    Without it, a run uses the simulator app's real container.
  - `SIMCTL_CHILD_TEXTMOUTH_OPEN_AT_LAUNCH=/absolute/path/to/book.epub` sends the app that file at launch, as another app would.
    The path must be absolute.
    The app copies the file and never moves or deletes the original.
  - Use a public-domain book from `TestData`, such as `TestData/alice.epub` (Project Gutenberg #11).

### Play, typing, and sound
<!-- id: play-typing-sound; keys: TEXTMOUTH_UI_SOUND, no sound tests, simulator audio, GITHUB_ACTIONS, speakers; src: Scripts/agents/run-ios-ui-tests.py -->

- **Do not press Play or type by hand, and run no sound test here.**
  The simulator plays through the Mac's speakers, which the user could hear at any hour, and the keyboard's clicks are sounds too.
  The interface tests that press Play or type run on GitHub's runners, where nobody listens, and so do the unit tests, which make no sound and so never skip.
  On this Mac the interface tests that make sound skip unless `TEXTMOUTH_UI_SOUND` is 1, and only `Scripts/agents/run-ios-ui-tests.py` sets it, which refuses to run anywhere but on a GitHub runner (see [Testing the iPhone app](testing-iphone.md)).
  Nothing records audio anywhere.
