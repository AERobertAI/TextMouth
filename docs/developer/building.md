# Building TextMouth

Part of [TextMouth's documentation](../../README.md).

## What you need

- A Mac with macOS 14 or later runs TextMouth. Development uses macOS 26 and Xcode 26.0.1, the version the continuous-integration job selects.
- XcodeGen generates TextMouth.xcodeproj from project.yml. Install it with `brew install xcodegen`; the development Mac and CI use version 2.45.3.
- `make check` reads the package pins with jq, which macOS 15 and later include as /usr/bin/jq.
- Xcode builds the iOS app, TextMouthiOS, only once its iOS platform is downloaded: about 10 GB, from Xcode > Settings > Components, or with `xcodebuild -downloadPlatform iOS`. Until then `make typecheck-ios` compiles and links the iOS app without it (see The iOS app, below). Nothing else on this page needs the iOS platform.
- Recording needs macOS's microphone permission, which macOS keeps from one build to the next only while the builds are signed with the same certificate: run `make signing-identity` once on each Mac you build on (see Make targets).

## Make targets

Run these from the repository root:

- `make build` regenerates the project and builds the Release app as build/TextMouth.app, about 23 MB (see The Mac app's size, below): without the code coverage Xcode's scheme gathers for tests, with code nothing reaches left out, and with its symbols stripped into build/DerivedData/Build/Products/Release/TextMouth.app.dSYM, which the next Release build replaces. The app includes LAME 3.100's MP3 encoder, which project.yml builds from Vendor/lame as a static library the app links, about 0.13 MB of it (see [Third-party code](third-party-code.md)). It includes the TextMouthBraille helper too, a command-line program of TextMouth's own, in TextMouthBraille/main.c, that links liblouis 3.39.0, which project.yml builds from Vendor/liblouis as a static library only the helper links. The app copies the helper into Contents/MacOS, about 0.15 MB, liblouis's four braille tables into Contents/Resources/liblouis/tables, about 0.29 MB, and the licence files of LAME and liblouis into Contents/Resources/Licenses, about 0.07 MB. Xcode's header map is off (USE_HEADERMAP: NO) for LAME, liblouis, and the helper: it lists every header of the project under its bare name, and it handed liblouis LAME's config.h, so each of them finds its own through its search paths. The full build log is build/xcodebuild-Release.log. It then signs build/TextMouth.app with this Mac's TextMouth Developer identity, when it has one, so that macOS keeps the app's microphone permission from one build to the next, and prints the app's designated requirement; without one, the app keeps the ad hoc signature Xcode gave it, and a note says so. The build products in build/DerivedData stay as Xcode made them.
- `make debug` builds the Debug configuration instead.
- `make run` and `make open` build the app and open it.
- `make install` builds the app, copies it to /Applications, registers it so it appears in Open With menus, and keeps the build's dSYM in build/installed-dSYMs as TextMouth-<build number>-<UUID>.app.dSYM, keeping those of the last five installs only. `make uninstall` removes the app and leaves the dSYMs; `make clean` removes them with the rest of build/.
- A crash report from the installed app gives TextMouth's own frames as offsets, such as TextMouth + 0x372e00, because the Release app's symbols are stripped. The build number (CFBundleVersion) and TextMouth's UUID in the report name the dSYM `make install` kept for that build in build/installed-dSYMs, which turns the offsets back into functions, files, and lines: `atos -o build/installed-dSYMs/TextMouth-<build number>-<UUID>.app.dSYM/Contents/Resources/DWARF/TextMouth -arch arm64 -l <TextMouth's load address in the report> <address>`.
- `make signing-identity`, once on each Mac, makes that identity: a self-signed code-signing certificate named TextMouth Developer, valid for 20 years, with its key in the login keychain, where codesign may use it without asking. Run again, it says the identity is there and changes nothing. It asks for no password and sets no trust, so Keychain Access lists the certificate as not trusted, which signing doesn't need. Keep the certificate: a new one changes the app's designated requirement, and macOS asks for the microphone once more. When codesign can't use the key, as over SSH with the login keychain locked, `make build` fails and says so; run `security unlock-keychain ~/Library/Keychains/login.keychain-db`, then build again.
- `make test` runs the hosted test suite, described below. `make test-area AREAS="feeds bookmarks"` runs only the hosted tests of some areas or classes, in one build, and `make lint-tests`, `make lint-a11y`, and `make lint-ogg` check the lines a branch adds, without building; [Testing TextMouth](testing.md) describes them under Reusable test tools.
- `make check` runs the reproducibility gate, which also reports the Release app's size, and `make check-selftest` tests the gate, the baseline-recording script, `make install`'s dSYM keeping, and the signing script, all described below, and also the storage drill script, the version script (see Versions, below), and the Python tools in `Scripts/test` (see Reusable test tools in [Testing TextMouth](testing.md)).
- `make perf-baselines` records new performance baselines after a deliberate change, as The performance baselines describes below.
- `make generate` regenerates TextMouth.xcodeproj from project.yml. Run it after adding or removing a source or test file, and commit the changed project file with that file. XcodeGen 2.45.3 writes the app target's three copy-files phases (liblouis's tables and the two folders of licence files) in a different order on each run, though the order changes nothing in the build. So `make generate` runs `Scripts/agents/regenerate-project.py`, which runs xcodegen and then puts the phases back in the order the git index has, when they mean the same thing. Only real changes stay: files added, moved, or removed. If the phases changed in meaning, or git has no copy of the project to compare with (as in a source archive), it keeps xcodegen's whole project and says so on the console. `make build`, `make install`, `make set-version`, and the two bumps all regenerate this way.
- `make bump-patch` raises the app's PATCH version by one (0.2.0 to 0.2.1), and `make bump-minor` raises its MINOR version by one and sets PATCH to 0 (0.2.3 to 0.3.0); each changes the version in project.yml, regenerates the project, and commits nothing (see Versions, below).
- `make set-version VERSION=0.2.0` sets a version you name, in the same way (see Versions, below).
- `make resolve-packages` resolves the Swift packages exactly as Package.resolved pins them, and `make update-packages` resolves them again after a deliberate version change.
- `make typecheck-ios` compiles and links the app's committed sources for iOS, as the iOS app compiles them, with SwiftPM and the iOS SDK Xcode includes, and `make typecheck-ios CENSUS=1` counts every AppKit use left in them. `make typecheck-mac` does the same for the Mac, and `make typecheck-tests` adds the Mac's hosted tests. `make mac-projection BASE=main` shows what a branch changes in the code the Mac compiles, and with `DIFF=1` prints every line it changes. Each is described under The iOS app, below.
- `make check-ios-plist` fails when the iOS app's `TextMouth/Platform/iOS/Info.plist` is not what `Scripts/ios/sync-info-plist.py` writes from the Mac's `TextMouth/Resources/Info.plist`: run `python3 -I Scripts/ios/sync-info-plist.py` after changing the Mac's plist, then commit both (see [The two apps and the platform folders](../architecture/platforms.md)).
- `make xcode` regenerates the project and opens it in Xcode.
- `make clean` removes the build products.
- `make help` lists these targets.

## The Mac app's size

The user's target for the Mac app is 25 MB or less. `make check` fails the app only above its hard limit of 50 MB (see The make check gate, below). This is what a measurement of the Release build showed on November 9, 2026, at commit e0ea3b9d.

- **The totals.**
  - The Release executable, `TextMouth.app/Contents/MacOS/TextMouth`, is 22.7 MB (22,737,216 bytes), and the whole bundle is about 23 MB.
  - Both are under the 25 MB target, with about 2 MB to spare.
  - The braille helper is 186 KB of the bundle.
- **The largest pieces.**
  - SwiftSoup is 3.0 MB, 13% of the executable and the largest single piece.
  - swift-markdown is 0.6 MB.
  - Of the app's own files, `LibraryView` is the largest at 0.36 MB.
- **The iPhone's code costs little.**
  - `TextMouth/Phone/` is compiled into the Mac app too. The linker strips what the Mac never reaches, and 59 KB stays, 0.27% of the executable.
  - Leaving `Phone/` out would save at most that, and would give up the Mac's tests of it in a Release build. So it is not left out.
- **How the sizes were found.**
  - The linker's own map lists every object and its bytes. Ask for it with `LD_GENERATE_MAP_FILE=YES` alone, with `xcodebuild` and its own derived-data folder, under `run_locked.py` (see Building TextMouthiOS for the simulator, below).
  - Do not set `LD_MAP_FILE_PATH` on the command line. Every target's link shares that one path, and Xcode stops with "Multiple commands produce" the one map file. With `LD_GENERATE_MAP_FILE=YES` alone, Xcode writes one map for each target, in the build's `Intermediates.noindex` folder.
  - The measurement used `Scripts/agents/run_locked.py`, since a Release build is heavy work.

## The iOS app

project.yml defines two apps over one source folder. `TextMouth` is the Mac app, which every other target and command on this page builds. `TextMouthiOS` is the iOS app, added in phase 0 of the iOS port (see [The two apps and the platform folders](../architecture/platforms.md)):

- It compiles the TextMouth source folder less `TextMouth/Platform/macOS/` and the Mac's `TextMouth/Resources/`, so it compiles the files both apps share and `TextMouth/Platform/iOS/`.
- It is the product TextMouth, with the module name TextMouth, for iOS 26.0, and has the Mac app's bundle identifier. It takes the same three Swift packages (ZIPFoundation, SwiftSoup, and swift-markdown's Markdown) and its own builds of the two C libraries it links, `LAME_iOS` and `ObjCExceptionCatcher_iOS`. project.yml defines each library once, as a target template, and builds it for each platform; the Mac targets' settings are as they were.
- It has no helper program, since iOS lets an app start none, and no braille helper or liblouis.
- It is the iPhone app: the Library, the reader, Settings, and importing, built from IOS-INTERFACE-SPEC-2026-11-07.md (see [The two apps and the platform folders](../architecture/platforms.md)). It first ran in the iOS simulator on November 8, 2026. Nothing has run on a phone.
- Its scheme, `TextMouthiOS`, is committed. The Mac's schemes are still Xcode's own, so `-scheme TextMouth`, which `make build` and the tests use, builds the Mac app alone.
- Xcode builds it only once its iOS platform is downloaded (see What you need, above). Until then, `make typecheck-ios` is how its code is checked.
- Building it for the simulator is the next section.

The three make targets run the scripts in `Scripts/ios`. They read a commit, so run them on committed work.

- **`make typecheck-ios`** copies the committed sources of HEAD into a work folder of its own, writes a Swift package around them, and builds it with SwiftPM and the iOS SDK, for iOS 26.0, compiling the sources the iOS app compiles and linking the two C libraries. It never changes the repository. A clean run means the iOS app's sources compile and link; because it builds a package of its own and not the Xcode target, it does not test the target's build settings. It takes about two minutes once it has the lock. `CENSUS=1` reads each `import AppKit` as `import UIKit` in the copy, so that a file does not stop at "no such module 'AppKit'" and every AppKit name left in it is reported; it counts what is left, and is not what the app must pass. The run without it is the strict one.
- **`make typecheck-mac`** does the same for the Mac: the sources the Mac app compiles, built and linked in about two minutes, without xcodebuild or the hosted tests. It ends BUILD SUCCEEDED when the Mac app's code compiles and links.
- **`make typecheck-tests`** is `make typecheck-mac` with the Mac's hosted test target in the package: the folder `TextMouthProductionTests` and the files `project.yml` lists for that target from `TextMouthTests/Sources/Tests`, copied into one target of the probe package and built with `swift build --target TextMouthProductionTests`. It compiles the app and the tests, links no test bundle, and runs no test (SwiftPM link step for a test bundle fails with this Xcode toolchain, with unexpected input file plugins/testing, after every file has compiled, and that is not a test file error). An error in a listed file is reported under the file's repository path. `REF=<commit>` checks that commit (default HEAD) from any worktree, so an agent can check its branch before asking for a train. It has its own work folder (`build/typecheck/macos-tests/`), takes the heavy-work lock itself, and takes about four minutes when most test files compile again, six from a cold start, and seconds when nothing changed, after the wait for the lock. Never wrap it in `run_locked.py`.
- **`make mac-projection BASE=main`** compares, for each Swift file the Mac compiles that HEAD changes since BASE (`HEAD=` names another ref), what the Mac compiles of the old text and of the new. A file moved into `Platform/macOS`, Mac code wrapped in `#if os(macOS)`, and a platform alias or helper that is exactly the old type or expression on the Mac all count as unchanged. It prints the number of files changed, the number unchanged for the Mac, and the number with a real change, and with `DIFF=1` the lines that remain in each of those. It changes nothing and writes no file. It is for a change that must leave the Mac's behavior as it was: the aim is no real change, or only lines a reviewer can defend one by one.

The two type-checks print their result and write it to `build/typecheck/results/` in the main checkout, which git ignores, in a folder for each run, named by who ran it, the platform, the mode, the commit, and the time. The folder holds `summary.md` (the result, the errors and warnings in the app, the link, the errors by file, and the kinds of error), `errors.txt`, `warnings.txt`, and `build.log`, and the last line of the output names it. A run exits with status 0 when the build succeeded, 1 when it found errors, 2 when it could not set up, and 3 when the lock stayed busy for the whole wait.

**The heavy-work lock.** The Mac has 8 GB of memory, and on October 31, 2026 it froze under several builds at once, so one heavy job runs on it at a time. The type-checks and the build train both take a lock (`Scripts/agents/heavy_lock.py`) before they start: a folder made with mkdir, build/orchestrator/heavy-lock in the main checkout, holding its owner's process ID, name, and start time. A job that finds it held says whom it waits for and since when, and waits, a type-check by default up to three hours. A lock whose owner has ended, from a crash or a killed agent, is taken over. So a type-check started while the train builds waits for the train, and the reverse. The build train waits first in line: while it waits, no other job takes the lock, even a free one, so the train goes next, and it never runs without the lock. Until November 8, 2026 a train that had waited 20 minutes went on beside the job holding the lock; that day the user, finding that the builds took a lot of CPU, asked for them "one after the other". `Scripts/agents/tests` holds the tests of the lock, the train, `run_locked.py`, `run_suite.py`, `copy_phases.py`, and `regenerate-project.py`: `python3 -I -B -m unittest discover -s Scripts/agents/tests`. They use temporary locks and folders, a fake command for the suite, and a stand-in for xcodegen, so none runs xcodebuild or touches the real lock.

### Building TextMouthiOS for the simulator

The simulator needs the iOS platform and the iPhone 17 simulator runtime that Xcode 26.0.1 installs. This is how the iPhone team builds and runs the app there.

- **The scheme.**
  - `TextMouthiOS` is committed at `TextMouth.xcodeproj/xcshareddata/xcschemes/TextMouthiOS.xcscheme`. XcodeGen writes it from the `scheme:` block of the `TextMouthiOS` target in project.yml.
  - It runs both iOS test bundles, `TextMouthiOSTests` and `TextMouthiOSUITests` (see [Testing TextMouth](testing.md)), and gathers no code coverage.
  - The scheme Xcode made by itself held only the UI tests, which is why this one is committed.
- **One build folder.**
  - Every simulator build puts its products in `build/DerivedData-ios.noindex`, with `-derivedDataPath build/DerivedData-ios.noindex`. The folder is in `build/`, which git ignores.
  - The name ends in `.noindex` so that Spotlight does not index it.
  - It was 792 MB after the first build and run.
  - It is not the Mac's `build/DerivedData`. The two never share a folder.
- **iPhone 17 only.**
  - Every run uses the iPhone 17 simulator, as in `-destination 'platform=iOS Simulator,name=iPhone 17'`. Make no new simulator devices.
  - The first boot of a device adds about 2.1 GB of disk. The iPhone 17's data is 2.5 GB in all.
  - The disk is tight, so these two costs count against the free space before a run.
- **The heavy-work lock.**
  - Every simulator build or test run goes through `Scripts/agents/run_locked.py`. It takes the heavy-work lock (see The heavy-work lock, above), runs one command, and exits with the command's status: `python3 -I Scripts/agents/run_locked.py NAME COMMAND...`. NAME says who holds the lock.
  - It waits up to three hours for the lock, and exits with status 3 if it never gets it.
  - Run it with `python3 -I`, which leaves its folder out of the import path. It finds `heavy_lock.py` beside itself, so it works from any checkout or worktree, and every one shares the one lock in the main checkout.
  - `Scripts/agents/run_suite.py NAME LOG` does the same for the full hosted suite (`xcodebuild test` on the macOS destination), writing the log to LOG. It ends an xcodebuild that stays silent for three minutes after its last test, prints the log's Executed line, and exits 0 only when the log says every test passed. Run it from the checkout to test, as a background task.
  - Never wrap `make typecheck-ios`, `make typecheck-mac`, or `make typecheck-tests` in it. They take the same lock themselves, and would wait on their own parent.
- **No clean builds.**
  - Never run `xcodebuild clean`, and never delete the build folder. The build is incremental, and a clean one compiles every file again, under the lock, on a Mac with 8 GB of memory.
  - Nobody deletes anything during an agent run, so the next build overwrites a stale build and does not clear it.
- **A build.**
  - `build-for-testing` compiles the app and both test bundles without running them. Its command has this shape, run under `run_locked.py`: `xcodebuild build-for-testing -project TextMouth.xcodeproj -scheme TextMouthiOS -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData-ios.noindex`.
  - The repository does not record the command line the iPhone team used, so check this shape against `xcodebuild -help` before relying on it.
- **A test pass and its result bundle.**
  - A pass of the iPhone team's last round ran `xcodebuild test-without-building` after a `build-for-testing`, with the `TextMouthiOS` scheme, the one build folder, `-parallel-testing-enabled NO`, and `-resultBundlePath` naming a `.xcresult` bundle for the pass. The destination was the iPhone 17 simulator, named by its id.
  - **Give each pass a new result-bundle name** (`pass4.xcresult`, then `pass5.xcresult`). The round's report says `xcodebuild` wants a new name for each pass, and nobody deletes anything during a run, so an old bundle stays where it is. The exact message of a repeated name was not recorded.
  - The bundle holds each test's results, the screenshots, and the notes the audits keep (see [Testing TextMouth](testing.md)).
- **Installing and launching.**
  - The app's bundle identifier is `com.textmouth.TextMouth.iOS`, and the product is TextMouth.app.
  - `xcrun simctl install` puts the built app on the booted device, and `xcrun simctl launch` starts it. `xcrun simctl io booted screenshot FILE` takes a screenshot, and the app's log is the other way to see what it did.
  - Afterward run `xcrun simctl shutdown all`, since the Mac has 8 GB of memory.
- **The `SIMCTL_CHILD_` launch variables.**
  - `xcrun simctl launch` passes an environment variable to the app when its name starts with `SIMCTL_CHILD_`, and drops that prefix.
  - The app reads two variables, `TEXTMOUTH_UI_TEST` and `TEXTMOUTH_OPEN_AT_LAUNCH`, in Debug builds only. Both are described in PhoneLaunchRequest in [The two apps and the platform folders](../architecture/platforms.md). A Release build does not hold the type or the variable names, so no environment variable can steer it.
  - The placement probe's variable, `TEXTMOUTH_PROBE_SYSTEM_PLACEMENT`, is gone, with the probe test. Setting it now does nothing.
  - `SIMCTL_CHILD_TEXTMOUTH_UI_TEST=1` gives the launch a library of its own, in a sandbox. Without it, a run uses the simulator app's real container.
  - `SIMCTL_CHILD_TEXTMOUTH_OPEN_AT_LAUNCH=/absolute/path/to/book.epub` sends the app that file at launch, as another app would. The path must be absolute. The app copies the file and never moves or deletes the original.
  - Use a public-domain book from `TestData`, such as `TestData/alice.epub` (Project Gutenberg #11).
- **Never press Play.** The simulator plays through the Mac's speakers, which the user could hear at any hour. Nothing records audio, and nothing types, since the keyboard's clicks are sounds too.

## Versions

TextMouth is in beta, which will last a long time, so its version is `0.MINOR.PATCH`. MAJOR stays 0 until the user calls TextMouth released (1.0). The rules for raising the version are the user's, from October 23, 2026:

- **PATCH** goes up by 1 for each day on which main gains bug fixes or small backward-compatible features. That is one bump per day, made after the day's last merge, before the user's next install.
- **MINOR** goes up by 1, with PATCH back to 0, for any change that is not backward compatible:
  - a TextMouth one version older cannot open the library;
  - every book is read again (a cache-format change);
  - a stored format changes;
  - a setting, shortcut, or file is removed or renamed.

  A day that has such a change bumps MINOR instead of PATCH.
- **Each bump** adds a dated section to the top of the [Changelog](../user/changelog.md), with one plain sentence per change. A MINOR section says first what an older TextMouth can no longer do with the library.
- **The orchestrator** makes the bump, with the script below: `make bump-patch` or `make bump-minor`, committed on its own and recorded in the TODO.
- **Each version is tagged** `vX.Y.Z`, with an annotated tag on the commit the user is to install: `git tag -a v0.4.3 <commit> -m "TextMouth 0.4.3 (November 9, 2026)"`. The orchestrator makes it with the bump.
  - A merge that joins the version afterwards, as in the second open case below, moves the tag to that merge, but only while the tag is unpushed. A pushed tag stays, and the merge waits for the next version.
  - Pushing tags is the user's: `git push origin --tags`.
  - The tags v0.2.0 to v0.4.2 were added on November 9, 2026, each at its version's bump commit. The exception is v0.4.2, at e0ea3b9d, the build the user installed, since 0.4.2 took in the KF8 merge after its bump. The numbers before 0.2.0 ("1.0", then "0.1.1") came before the beta's rules and have no tags.
- **Two cases the rules leave open.** A day with neither bug fixes nor small features gets no bump. A change that merges after its day's bump, on the same day, joins that day's section and leaves the version as it is, unless it is not backward compatible: then bump MINOR from the day's version (0.2.1 to 0.3.0), in a section of its own.

The script, Scripts/set-version.sh:

- The version is `MARKETING_VERSION` in project.yml, which Info.plist reads as `CFBundleShortVersionString`. It sits, with `CURRENT_PROJECT_VERSION`, in the `appVersion` setting group, which the Mac app and the iOS app both take, so one number versions both apps; it is still one line, and the script changes that line. Change it with the script, never by hand.
- `make bump-patch` (`Scripts/set-version.sh --patch`) raises PATCH by one, 0.2.0 to 0.2.1. `make bump-minor` (`Scripts/set-version.sh --minor`) raises MINOR by one and sets PATCH to 0, 0.2.3 to 0.3.0. Each works the new version out of project.yml, adding one to a number digit by digit so that none can overflow, and neither changes MAJOR.
- `make set-version VERSION=0.2.0` (`Scripts/set-version.sh 0.2.0`) sets a version you give, for a deliberate jump such as 1.0.0 when the user calls TextMouth released. The script accepts only MAJOR.MINOR.PATCH, three whole numbers without leading zeros, and refuses a version that is not later than the current one, comparing each number as a number, so 0.10.0 is later than 0.9.0. A bump goes the same way once its version is worked out, so it meets the same checks.
- It changes nothing in project.yml but the value of that one setting, regenerates the project the way `make generate` does, so that TextMouth.xcodeproj follows and shows only the version's lines, and prints the old and new versions. If the regeneration fails, it puts project.yml back as it was. It commits nothing: commit project.yml with the regenerated project, in a commit that does nothing else. It ends by reminding you to add the dated section to the changelog, which it does not write.
- The build number, `CFBundleVersion`, is not set by hand or by that script. `make build` stamps each build with the UTC time as YYYYMMDDHHMMSS, which is unique and increasing, and `make install` names the dSYM it keeps for the build by it (see Make targets, above). The `CURRENT_PROJECT_VERSION` of 1 in project.yml is only what a build gets when it does not come from the Makefile, such as the hosted tests' build.
- `Scripts/set-version.sh --selftest` tests the script in seconds, on a copy of project.yml in a temporary folder and with stand-ins for xcodegen and for the regeneration script, without building; `make check-selftest` runs it. Its cases cover both bumps (carries such as 0.2.9 to 0.2.10, numbers beyond 64 bits, and a project.yml whose version cannot be read) and the Makefile's version targets.

## The make check gate

**Reproducible builds and `make check`.** TextMouth locks its Swift packages deliberately: `project.yml` requires an exact version of each direct dependency, and the committed `TextMouth.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` pins every exact revision, including the transitive swift-cmark. Run `make check` before merging. It regenerates the project, resolves packages strictly from `Package.resolved` (failing if anything would change), builds Release and runs the hosted test suite, with the performance baselines tests measuring even on a busy Mac, and fails on any Swift warning in either build, about concurrency or anything else, naming the first five. It also reports the size of the Release app it built, build/TextMouth.app, the app `make install` copies, counted as Finder counts it (the sizes of its files, a megabyte being a million bytes), as in "build/TextMouth.app is 15.4 MB (15,387,034 bytes), within the 50 MB limit", and fails when the app is larger than 50 MB, a limit set once, as APP_SIZE_LIMIT_MB in Scripts/check.sh. It repeats, once each, the PERFORMANCE WARNING: and PERFORMANCE SKIPPED: lines those tests print; neither kind fails the gate, since a number more than twice its baseline has already failed its test. Both builds start from scratch: the gate first removes `build/DerivedData/Build` and `TextMouthTests/.build`, keeping the package checkouts, because xcodebuild prints a file's warnings only when it compiles that file. It prints one line per step and ends with PASSED or FAILED, with full logs in `build/check/` and the Release build's in `build/xcodebuild-Release.log`. A run takes about seven minutes on the development Mac (2 minutes for the Release build, 5 for the tests). To upgrade a package, change its version in `project.yml`, run `make update-packages`, review the `Package.resolved` diff, run `make check`, and commit both files. `make check-selftest` and `make check CHECK_ARGS=--dry-run` test the gate itself in seconds, and `make check-selftest` also tests the baseline-recording script, the storage drill script's verdicts (see Reusable test tools in [Testing TextMouth](testing.md)), the version script (see Versions, above), that `make build` builds without code coverage, that `make install` keeps the dSYMs, running install and uninstall in a sandbox folder, never /Applications; and the signing script, Scripts/make-signing-identity.sh, once for real, run twice against a throwaway keychain it creates unlocked, and otherwise with stand-ins for security and codesign, so it never asks for a password or touches the login keychain. GitHub Actions runs the same gate (`.github/workflows/check.yml`) on macOS 26 with Xcode 26.0.1 for every push to main and every pull request.
