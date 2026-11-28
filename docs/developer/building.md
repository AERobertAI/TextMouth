# Building TextMouth
<!-- id: building-textmouth; keys: Makefile, make, xcodebuild, XcodeGen; src: Makefile, project.yml -->

Part of [TextMouth's documentation](../../README.md).

## What you need
<!-- id: what-you-need; keys: prerequisites, requirements, jq, iOS platform download, downloadPlatform, signing identity; src: project.yml, Makefile, Scripts/check.sh, Scripts/make-signing-identity.sh, .github/actions/setup-xcode/action.yml -->

- A Mac with macOS 14 or later runs TextMouth.
  Development uses macOS 26 and Xcode 26.0.1, the version the continuous-integration job selects.
- XcodeGen generates TextMouth.xcodeproj from project.yml.
  Install it with `brew install xcodegen`; the development Mac and CI use version 2.45.3.
- `make check` reads the package pins with jq, which macOS 15 and later include as /usr/bin/jq.
- Xcode builds the iOS app, TextMouthiOS, only once its iOS platform is downloaded: about 10 GB, from Xcode > Settings > Components, or with `xcodebuild -downloadPlatform iOS`.
  Until then `make typecheck-ios` compiles and links the iOS app without it (see [The iOS app](building-ios.md)).
  Nothing else on this page needs the iOS platform.
- Recording needs macOS's microphone permission, which macOS keeps from one build to the next only while the builds are signed with the same certificate: run `make signing-identity` once on each Mac you build on (see Make targets).

## Make targets
<!-- id: make-targets; keys: Makefile, make help, targets, .PHONY; src: Makefile -->

Run these from the repository root:

### Building, installing, and signing
<!-- id: building-installing-signing; keys: make build, make install, make uninstall, SMALL_CODE, Release, dSYM, atos, codesign; src: Makefile, project.yml, Scripts/keep-installed-dsym.sh, Scripts/make-signing-identity.sh, TextMouthBraille/main.c -->

- `make build` regenerates the project and builds the Release app as build/TextMouth.app, about 22 MB light on a Mac and 18 MB with every size setting (see [The Release size settings](building-release.md#the-release-size-settings)):
  - without the code coverage Xcode's scheme gathers for tests;
  - with code nothing reaches left out;
  - and with its symbols stripped into build/DerivedData/Build/Products/Release/TextMouth.app.dSYM, which the next Release build replaces.

  The Release build is compiled for size.
  The app's own code takes `-Osize` from project.yml's Release settings.
  The two Swift packages (ZIPFoundation and swift-cmark) take it from the Makefile's command line (the `SMALL_CODE` variable, Release only, so `make debug` keeps Debug's level), since project.yml cannot reach the packages.
  So does the vendored SwiftSoup library, whose template in project.yml also sets it in Release (SWIFT_OPTIMIZATION_LEVEL: -Osize).
  The build asks for whole-module mode only for SwiftSoup; for the rest it would make the app 1.15 MB larger.
  The executable is linked without an export trie (`LD_EXPORT_SYMBOLS: NO`, Release only), because nothing links against the app.
  The Makefile's command line also gives a Release build the size settings of `Scripts/size_settings.py`'s profile (see [The Release size settings](building-release.md#the-release-size-settings)).
  That is light on a Mac, and every setting for `make install`, `make release`, and every build on GitHub Actions.
  A build made from Xcode's own window gives the packages neither `-Osize` nor those, as it drops no coverage either, since only the Makefile's command line does any of the three.
  `make check` and `make install` build through `make build`, so both get it.
  The app includes LAME 3.100's MP3 encoder, which project.yml builds from Vendor/lame as a static library the app links, about 0.13 MB of it (see [Third-party code](third-party-code.md)).
  It includes the TextMouthBraille helper too, a command-line program of TextMouth's own, in TextMouthBraille/main.c, that links liblouis 3.39.0, which project.yml builds from Vendor/liblouis as a static library only the helper links.
  The iPhone app links its own build, liblouis_iOS, and runs it in the app.
  The app copies the helper into Contents/MacOS, about 0.15 MB, and the licence files of LAME and liblouis into Contents/Resources/Licenses, about 0.07 MB; the build phase "Pack braille tables" packs its braille tables into Contents/Resources/BrailleTables.pack.
  Xcode's header map is off (USE_HEADERMAP: NO) for LAME, liblouis, and the helper: it lists every header of the project under its bare name, and it handed liblouis LAME's config.h, so each of them finds its own through its search paths.
  The full build log is build/xcodebuild-Release.log.
  It then signs build/TextMouth.app with this Mac's TextMouth Developer identity, when it has one, so that macOS keeps the app's microphone permission from one build to the next, and prints the app's designated requirement.
  Without one, the app keeps the ad hoc signature Xcode gave it, and a note says so.
  The build products in build/DerivedData stay as Xcode made them.
- `make debug` builds the Debug configuration instead.
- `make run` and `make open` build the app and open it.
- `make release` builds the app as it ships, with every size setting, into build/TextMouth.app without installing it; its link takes several GB of memory, so on a Mac with 8 GB quit other heavy apps first, as it says before it starts.
- `make install` builds the app as `make release` does, copies it to /Applications, registers it so it appears in Open With menus, and keeps the build's dSYM in build/installed-dSYMs as `TextMouth-<build number>-<UUID>.app.dSYM`, keeping those of the last five installs only.
  `make uninstall` removes the app and leaves the dSYMs; `make clean` removes them with the rest of build/.
- A crash report from the installed app gives TextMouth's own frames as offsets, such as TextMouth + 0x372e00, because the Release app's symbols are stripped.
  The build number (CFBundleVersion) and TextMouth's UUID in the report name the dSYM `make install` kept for that build in build/installed-dSYMs, which turns the offsets back into functions, files, and lines.
  `atos -o build/installed-dSYMs/TextMouth-<build number>-<UUID>.app.dSYM/Contents/Resources/DWARF/TextMouth -arch arm64 -l <TextMouth's load address in the report> <address>`.
- `make signing-identity`, once on each Mac, makes that identity: a self-signed code-signing certificate named TextMouth Developer, valid for 20 years, with its key in the login keychain, where codesign may use it without asking.
  Run again, it says the identity is there and changes nothing.
  It asks for no password and sets no trust, so Keychain Access lists the certificate as not trusted, which signing doesn't need.
  Keep the certificate: a new one changes the app's designated requirement, and macOS asks for the microphone once more.
  When codesign can't use the key, as over SSH with the login keychain locked, `make build` fails and says so; run `security unlock-keychain ~/Library/Keychains/login.keychain-db`, then build again.

### Tests, lints, and the gate
<!-- id: tests-lints-gate; keys: make test, make test-area, lint-tests, lint-a11y, lint-ogg, make check, check-selftest, perf-baselines; src: Makefile, Scripts/test/run-area.py, Scripts/test/trap-lint.py, Scripts/test/test-diff.py, Scripts/test/a11y-lint.py, Scripts/test/ogg-lint.py, Scripts/check.sh, Scripts/check-selftest.sh, Scripts/perf-baselines.sh, Scripts/test/release-goldens.sh, .claude/skills/doc-library/scripts/doclib.py -->

- `make test` runs the hosted test suite (see [The hosted test suite](testing.md)).
  `make test-area AREAS="feeds bookmarks"` runs only the hosted tests of some areas or classes, in one build, and `make lint-tests`, `make lint-a11y`, and `make lint-ogg` check the lines a branch adds, without building; [Reusable test tools](testing-tools.md) describes them.
- `make lint-l10n` checks that no Swift file has more interface text outside an `InterfaceText.line` call than `Scripts/l10n/scan-baseline.json` records for it, and the `make l10n-*` targets run the catalog's tools (see [Localizing TextMouth's code](localization.md)).
- `make lint-docs` checks that no doc page has more violations of the rules in docs/agents/writing-docs.md than `.claude/skills/doc-library/lint-baseline.json` records for it, without building; `.claude/skills/doc-library/SKILL.md` describes the tool.
- `make check` runs the reproducibility gate, which also reports the Release app's size.
  `make check-selftest` tests the gate and the scripts around it in seconds, without building; The make check gate, below, lists what it covers.
- `make release-goldens` runs the golden tests against a Release build (see [The Release golden tests](building-release.md#the-release-golden-tests)), once before a release.
- `make perf-baselines` records new performance baselines after a deliberate change, as [The performance baselines](testing.md) describes.

### The project, versions, and packages
<!-- id: project-versions-packages; keys: make generate, xcodegen, project.pbxproj, copy-files phases, bump-patch, bump-minor, Package.resolved, update-packages; src: Makefile, project.yml, Scripts/agents/regenerate-project.py, Scripts/agents/copy_phases.py, Scripts/set-version.sh -->

- `make generate` regenerates TextMouth.xcodeproj from project.yml.
  Run it after adding or removing a source or test file, and commit the changed project file with that file.
  XcodeGen 2.45.3 writes the app target's five copy-files phases (liblouis's tables and the licence folders of liblouis, LAME, foliate-js, and SwiftSoup) in a different order on each run, though the order changes nothing in the build.
  So `make generate` runs `Scripts/agents/regenerate-project.py`, which runs xcodegen and then puts the phases back in the order the git index has, when they mean the same thing.
  Only real changes stay: files added, moved, or removed.
  If the phases changed in meaning, or git has no copy of the project to compare with (as in a source archive), it keeps xcodegen's whole project and says so on the console.
  `make build`, `make install`, `make set-version`, and the two bumps all regenerate this way.
  A rebase conflict in `project.pbxproj` is settled by running `make generate` again and committing its result.
- `make bump-patch` raises the app's PATCH version by one (0.2.0 to 0.2.1), and `make bump-minor` raises its MINOR version by one and sets PATCH to 0 (0.2.3 to 0.3.0); each changes the version in project.yml, regenerates the project, and commits nothing (see Versions, below).
- `make set-version VERSION=0.2.0` sets a version you name, in the same way (see Versions, below).
- `make resolve-packages` resolves the Swift packages exactly as Package.resolved pins them, and `make update-packages` resolves them again after a deliberate version change.
- SwiftSoup 2.13.9 is not a Swift package: it is vendored in `Vendor/SwiftSoup`, and the static library targets SwiftSoup and SwiftSoup_iOS of project.yml compile it for each app.
  `Scripts/vendor/swiftsoup/make_vendor.py` writes its sources from the release with attribute edits only (see `Vendor/SwiftSoup/README.md`, which also says how to upgrade it), and `Scripts/vendor/swiftsoup/test_make_vendor.py` runs in `make check-selftest`.

### Type-checks and the other targets
<!-- id: type-checks-other-targets; keys: typecheck-ios, typecheck-mac, typecheck-tests, mac-projection, check-ios-plist, make xcode, make clean; src: Makefile, Scripts/ios/typecheck.py, Scripts/ios/mac-projection.py, Scripts/ios/sync-info-plist.py -->

- `make typecheck-ios` compiles and links the app's committed sources for iOS, as the iOS app compiles them, with SwiftPM and the iOS SDK Xcode includes, and `make typecheck-ios CENSUS=1` counts every AppKit use left in them.
  `make typecheck-mac` does the same for the Mac, `make typecheck-tests` adds the Mac's hosted tests, and `make typecheck-ios-tests` compiles the iPhone's unit and interface tests for iOS (`make typecheck-tests-census` counts which Mac tests compile there).
  `make mac-projection BASE=main` shows what a branch changes in the code the Mac compiles, and with `DIFF=1` prints every line it changes.
  Each is described under [The iOS app](building-ios.md).
- `make check-ios-plist` fails when the iOS app's `TextMouth/Platform/iOS/Info.plist` is not what `Scripts/ios/sync-info-plist.py` writes from the Mac's `TextMouth/Resources/Info.plist`.
  Run `python3 -I Scripts/ios/sync-info-plist.py` after changing the Mac's plist, then commit both (see [The two apps and the platform folders](../architecture/platforms.md)).
- `make ios-size` builds the iPhone app for a device under the heavy-work lock and measures it (see [The iPhone app's size](building-ios.md)).
- `make install-ios` builds the iPhone app signed and installs it on your own iPhone, with no Xcode window; the one-time steps are under [Installing on your own iPhone](building-ios.md#installing-on-your-own-iphone).
- `make xcode` regenerates the project and opens it in Xcode.
- `make clean` removes the build products.
- `make help` lists these targets.

## The FFmpeg build
<!-- id: ffmpeg-build; keys: FFmpeg, build.py, libtmffmpeg.a, Build FFmpeg, FFmpegLibrary, tmff-cc, configure, patches; src: Scripts/vendor/ffmpeg/build.py, Scripts/vendor/ffmpeg/test_build.py, Scripts/vendor/ffmpeg/patches/, project.yml, Scripts/check.sh, Scripts/ios/typecheck.py; status: incomplete; issues: FU01 -->

FFmpeg is not in the repository.
The targets FFmpeg and FFmpeg_iOS (the template FFmpegLibrary of project.yml) each run a build phase, Build FFmpeg, which calls `Scripts/vendor/ffmpeg/build.py --xcode`.
They then merge the result, `libtmffmpeg.a`, into the library they link, which the helper TextMouthFFmpeg and, for the iPhone, the app link.

- **What it builds** is FFmpeg 9.0.2, pinned by its URL, SHA-256, and size, for arm64 alone, as static libraries (libavformat, libavcodec, libswresample, and libavutil).
  Only the demuxers, decoders, and parsers the import reads are built (research/FFMPEG-MINIMAL-RESEARCH-2026-11-16.md), under the LGPL 2.1 or later.
  `--enable-small` is off: it decoded 6% to 27% slower to save about 0.6 MB.
- **It downloads from** ffmpeg.org first, then FFmpeg's GitHub archive of the tag n9.0.2, which has a SHA-256 of its own.
  The two trees differ only in files the tag's archive holds and the release lacks (git's own) and one file the release holds (VERSION); a comment in build.py names each.
  GitHub does not promise an archive's bytes: if they change, that source fails its pin and ffmpeg.org still serves.
  A file that matches no pin is never built.
- **The patches** are five upstream commits, kept unchanged in `Scripts/vendor/ffmpeg/patches/` and pinned by SHA-256 in `PATCHES`, are applied in order, with no fuzz, to the unpacked release, and are part of every build's key.
  Drop them when 9.0.3 holds them (FU01).
- **The shared folder** holds the release's archive and its unpacked, patched source, once for every checkout and build folder of a Mac, in `build/ffmpeg/` of the main checkout (git's common directory names it, from any worktree):
  - `download/` holds the tarballs;
  - `source/<key>/ffmpeg-<version>/` holds the release unpacked and patched once, where the key is of the release's SHA-256 and the patches, so a changed list of patches unpacks afresh, beside the old one.
  FFmpeg is built outside its source, so the shared source is only read: a second build folder unpacks and downloads nothing, which saves about 102 MB (12 MB of archive and 90 MB of source) for each.
  A lock is held while one build unpacks, and the lock is looked at again inside, so two checkouts never unpack over each other.
  An archive or source an older build kept in its own work folder is taken over once.
  Where the shared folder can't be written, or there is no git checkout, the same names are under the work folder instead.
  The archive is hashed once.
- **The work folder** is `$OBJROOT/FFmpeg`, inside DerivedData, so GitHub's cache keeps it:
  - `build-<platform>-<key>/` holds configure and make;
  - `<platform>/include` and `<platform>/lib/libtmffmpeg.a` are what the targets read, with `build.json` and `key` written last.
  The script deletes nothing: it writes fixed folders and replaces only its own published files.
- **A build again** happens when the key changes; it holds the pin, the configure line, the platform, the script's RECIPE number, the compiler's version, and the patches.
  A build with the same key ends in 0.16 s; a cold build took about 34 s on the development Mac and 1.5 to 2 minutes on a GitHub runner.
- **No path of this Mac** is in the result: the compiler is a wrapper, `tmff-cc`, that maps the work folder and the shared source away.
  The build fails when `strings` finds a home folder, checkout, temporary folder, or work folder in the archive or the headers, and `make check` repeats the test on the app.
- **Clang modules are off** (`CLANG_ENABLE_MODULES: NO`) for FFmpeg's C: the FFmpegLibrary template and the TextMouthFFmpeg target.
  With them on, Xcode precompiles the session's headers as modules of the target's own, and a restored runner cache can claim a module it lacks ("module file ... not found"); the objects are the same either way.
- **The type-check** (`make typecheck-ios`) builds no FFmpeg: its package links a C stand-in for the session's functions (`Scripts/ios/typecheck.py`), written against the session's real header, and a test in `test_typecheck.py` fails when the header gains or loses a function the stand-in lacks.
- `python3 -I -B Scripts/vendor/ffmpeg/build.py --readme` writes the notice both apps ship, and `test_build.py` (in `make check-selftest`) tests the script without downloading.

## The Mac app's size
<!-- id: mac-app-size; keys: app size, 30 MB limit, 40 MB strict limit, Osize, linker map, LD_GENERATE_MAP_FILE, SwiftSoup; src: Scripts/check.sh, project.yml, Makefile, Scripts/agents/run_locked.py, TextMouth/Views/Library/LibraryView.swift -->

The user's real limit for the Mac app is 30 MB, and 40 MB a strict one; the 20 MB of before was a target to optimize under.
`make check` warns above 30 MB and fails the app above 40 MB (see The make check gate, below).
The FFmpeg helper took the Release app from 18.5 MB (version 0.5.0) to 21.0 MB (21,008,340 bytes), 2.5 MB of it the helper; the iPhone app is measured by `make ios-size` (see [Building TextMouthiOS for the simulator](building-ios.md)).
Compiling the app and its packages for size (`-Osize`, and no export trie; see Make targets, above) brought the Release app from 23,545,276 bytes to 18,983,332 bytes, 19.0 MB, its executable from 22,820,048 to 18,258,016 bytes, in 35 files, measured by `make check`.
Vendoring SwiftSoup then brought the Release app to 17,888,466 bytes.
The price was slower HTML parsing at import, about 4 ms more for each megabyte of EPUB, since the SwiftSoup package parsed 43% slower at `-Osize`.
The vendored copy, compiled as one module at `-Osize`, is smaller and faster than the package was (`Vendor/SwiftSoup/README.md`).
Ten benchmarks (HTML to Markdown, Markdown parsing, speech preparation, sorting, JSON, the offset map, and an EPUB read) gave identical results with `-O` and `-Osize` and ran 2% to 10% slower.
Under 15 MB is out of reach of build settings; the size audit names the code changes that remain.
Two more settings would save 82,736 bytes (mergeable traps, which would make crash reports lose line detail within a function) and 95,472 bytes (`-no_function_starts`, which would make `sample` and Activity Monitor lose function boundaries without the dSYM); both wait for the user's yes.
The pieces below are what a measurement of the Release build showed at commit e0ea3b9d, before that work.

- **The totals.**
  - The Release executable, `TextMouth.app/Contents/MacOS/TextMouth`, was 22.7 MB (22,737,216 bytes), and the whole bundle about 23 MB.
  - The braille helper is 186 KB of the bundle.
- **The largest pieces.**
  - SwiftSoup is 3.0 MB, 13% of the executable and the largest single piece.
  - Of the app's own files, `LibraryView` is the largest at 0.36 MB.
- **The iPhone's code costs little.**
  - `TextMouth/Phone/` is compiled into the Mac app too.
    The linker strips what the Mac never reaches, and 59 KB stays, 0.27% of the executable.
  - Leaving `Phone/` out would save at most that, and would give up the Mac's tests of it in a Release build.
    So it is not left out.
- **How the sizes were found.**
  - The linker's own map lists every object and its bytes.
    Ask for it with `LD_GENERATE_MAP_FILE=YES` alone, with `xcodebuild` and its own derived-data folder, under `run_locked.py` (see [Building TextMouthiOS for the simulator](building-ios.md)).
  - Do not set `LD_MAP_FILE_PATH` on the command line.
    Every target's link shares that one path, and Xcode stops with "Multiple commands produce" the one map file.
    With `LD_GENERATE_MAP_FILE=YES` alone, Xcode writes one map for each target, in the build's `Intermediates.noindex` folder.
  - The measurement used `Scripts/agents/run_locked.py`, since a Release build is heavy work.

## Versions
<!-- id: versions; keys: MARKETING_VERSION, semantic version, beta, release tag, changelog; src: Scripts/set-version.sh, project.yml, Makefile -->

TextMouth is in beta, which will last a long time, so its version is `0.MINOR.PATCH`.
MAJOR stays 0 until the user calls TextMouth released (1.0).
The rules for raising the version are the user's:

### The rules for raising the version
<!-- id: rules-raising-version; keys: bump, PATCH, MINOR, git tag, backward compatible, changelog entry; src: Scripts/set-version.sh, Makefile -->

- **PATCH** goes up by 1 for each day on which main gains bug fixes or small backward-compatible features.
  That is one bump per day, made after the day's last merge, before the user's next install.
- **MINOR** goes up by 1, with PATCH back to 0, for any change that is not backward compatible:
  - a TextMouth one version older cannot open the library;
  - every book is read again (a cache-format change);
  - a stored format changes;
  - a setting, shortcut, or file is removed or renamed.

  A day that has such a change bumps MINOR instead of PATCH.
- **Each bump** adds a dated section to the top of the [Changelog](../user/changelog.md), with one plain sentence per change.
  A MINOR section says first what an older TextMouth can no longer do with the library.
- **The orchestrator** makes the bump, with the script below: `make bump-patch` or `make bump-minor`, committed on its own and recorded in the TODO.
- **Each version is tagged** `vX.Y.Z`, with an annotated tag on the commit the user is to install: `git tag -a v0.4.3 <commit> -m "TextMouth 0.4.3 (November 9, 2026)"`.
  The orchestrator makes it with the bump.
  - A merge that joins the version afterwards, as in the second open case below, moves the tag to that merge, but only while the tag is unpushed.
    A pushed tag stays, and the merge waits for the next version.
  - The orchestrator pushes the tags with main, only at a version bump it judges a fairly stable release (`AGENTS.md`, The user's standing rules): `git push origin --tags`.
  - The tags v0.2.0 to v0.4.2 are each at its version's bump commit.
    The exception is v0.4.2, at e0ea3b9d, the build the user installed, since 0.4.2 took in the KF8 merge after its bump.
    The numbers before 0.2.0 ("1.0", then "0.1.1") came before the beta's rules and have no tags.
- **Two cases the rules leave open.**
  A day with neither bug fixes nor small features gets no bump.
  A change that merges after its day's bump, on the same day, joins that day's section and leaves the version as it is, unless it is not backward compatible: then bump MINOR from the day's version (0.2.1 to 0.3.0), in a section of its own.

### The version script
<!-- id: version-script; keys: set-version.sh, --selftest, CFBundleShortVersionString, CURRENT_PROJECT_VERSION, CFBundleVersion, build number; src: Scripts/set-version.sh, project.yml, Makefile, Scripts/check-selftest.sh -->

The script, Scripts/set-version.sh:

- The version is `MARKETING_VERSION` in project.yml, which Info.plist reads as `CFBundleShortVersionString`.
  It sits, with `CURRENT_PROJECT_VERSION`, in the `appVersion` setting group, which the Mac app and the iOS app both take, so one number versions both apps; it is still one line, and the script changes that line.
  Change it with the script, never by hand.
- `make bump-patch` (`Scripts/set-version.sh --patch`) raises PATCH by one, 0.2.0 to 0.2.1.
  `make bump-minor` (`Scripts/set-version.sh --minor`) raises MINOR by one and sets PATCH to 0, 0.2.3 to 0.3.0.
  Each works the new version out of project.yml, adding one to a number digit by digit so that none can overflow, and neither changes MAJOR.
- `make set-version VERSION=0.2.0` (`Scripts/set-version.sh 0.2.0`) sets a version you give, for a deliberate jump such as 1.0.0 when the user calls TextMouth released.
  The script accepts only MAJOR.MINOR.PATCH, three whole numbers without leading zeros, and refuses a version that is not later than the current one, comparing each number as a number, so 0.10.0 is later than 0.9.0.
  A bump goes the same way once its version is worked out, so it meets the same checks.
- It changes nothing in project.yml but the value of that one setting, regenerates the project the way `make generate` does, so that TextMouth.xcodeproj follows and shows only the version's lines, and prints the old and new versions.
  If the regeneration fails, it puts project.yml back as it was.
  It commits nothing: commit project.yml with the regenerated project, in a commit that does nothing else.
  It ends by reminding you to add the dated section to the changelog, which it does not write.
  After a bump, check with `git diff --stat` that only `project.yml` and the `MARKETING_VERSION` lines of the project changed.
- The build number, `CFBundleVersion`, is not set by hand or by that script.
  `make build` stamps each build with the UTC time as YYYYMMDDHHMMSS, which is unique and increasing, and `make install` names the dSYM it keeps for the build by it (see Make targets, above).
  The `CURRENT_PROJECT_VERSION` of 1 in project.yml is only what a build gets when it does not come from the Makefile, such as the hosted tests' build.
- `Scripts/set-version.sh --selftest` tests the script in seconds, on a copy of project.yml in a temporary folder and with stand-ins for xcodegen and for the regeneration script, without building; `make check-selftest` runs it.
  Its cases cover both bumps (carries such as 0.2.9 to 0.2.10, numbers beyond 64 bits, and a project.yml whose version cannot be read) and the Makefile's version targets.

## The make check gate
<!-- id: make-check-gate; keys: check.sh, reproducible build, APP_SIZE_LIMIT_MB, APP_SIZE_WARNING_MB, SIGN_APP, check-selftest, --without-tests, dry run; src: Scripts/check.sh, Scripts/check-selftest.sh, Scripts/make-signing-identity.sh, Scripts/agents/run-on-runner.py, .github/workflows/check.yml, .github/workflows/tests.yml, project.yml, Makefile, Scripts/ios/app-size.py -->

**Reproducible builds and `make check`.**
TextMouth locks its Swift packages deliberately: `project.yml` requires an exact version of each direct dependency, and the committed `TextMouth.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` pins every exact revision, including the transitive swift-cmark.
SwiftSoup is vendored and has no pin (see Make targets, above).
Run `make check` before merging.
- It regenerates the project and checks the interface text catalog (`make l10n-check`, which builds no app);
- resolves packages strictly from `Package.resolved` (failing if anything would change);
- builds Release and runs the hosted test suite, with the performance baselines tests measuring even on a busy Mac;
- and fails on any Swift warning in either build, about concurrency or anything else, naming the first five.

It also reports the size of the Release app it built, build/TextMouth.app, the app `make install` copies, counted as Finder counts it (the sizes of its files, a megabyte being a million bytes), as in "build/TextMouth.app is 17.9 MB (17,888,466 bytes), within the 30 MB limit".
It warns, without failing, above 30 MB and fails above 40 MB, limits set once, as APP_SIZE_WARNING_MB and APP_SIZE_LIMIT_MB in Scripts/check.sh, which `app-size.py` reads for the iPhone app too ([the gate's step](#the-iphone-app-in-the-gate)).
It fails when either app ships a table of Apple's, or a `.lproj` folder without its `InfoPlist.strings` ([what the apps ship](localization.md#what-the-apps-ship)).
It fails when either app does not hold exactly one BrailleTables.pack in its resources, within BRAILLE_PACK_LIMIT_BYTES (the iPhone's) or MAC_BRAILLE_PACK_LIMIT_BYTES (the Mac's), or holds a raw liblouis table.
A raw table is a `liblouis/tables` folder, or a `.ctb`, `.cti`, `.utb`, `.uti`, `.tbl`, `.dis`, or `.dic` file anywhere (`require_braille_pack` in Scripts/check.sh; see [Braille table pack](../architecture/state/braille-table-pack.md#building-the-pack)).
Its Release build runs `make build SIGN_APP=:`, so the app keeps Xcode's ad hoc signature and the gate never asks for the keychain (`make install` builds and signs its own app).
It repeats, once each, the PERFORMANCE WARNING: and PERFORMANCE SKIPPED: lines those tests print; neither kind fails the gate, since a number more than twice its baseline has already failed its test.
Both builds start from scratch: the gate first removes `build/DerivedData/Build` and `TextMouthTests/.build`, keeping the package checkouts, because xcodebuild prints a file's warnings only when it compiles that file.
It prints one line per step and ends with PASSED or FAILED, with full logs in `build/check/` and the Release build's in `build/xcodebuild-Release.log`.
On the development Mac the hosted suite's tests alone take about 30 minutes.
To upgrade a package, change its version in `project.yml`, run `make update-packages`, review the `Package.resolved` diff, run `make check`, and commit both files.
GitHub Actions runs the gate's checks in two sets of jobs side by side (`.github/workflows/check.yml`, on macOS 26 with Xcode 26.0.1, for every push to main and every pull request).
The `gate` job runs `make check CHECK_ARGS=--without-tests` (`Scripts/check.sh --without-tests`: steps 1 to 3, the project, the pins, and the Release build with its warnings and size).
The `suite` job runs the hosted suite through `.github/workflows/tests.yml`, the shared jobs a push to `TestBuild` uses, dealt out among 4 parallel shards.
It runs only for a push and for a pull request from this repository, not from a fork, because it starts 5 macOS jobs and GitHub runs 5 at once.
It asks for a build from nothing (`"cold": true`, since xcodebuild prints a file's warnings only when it compiles that file) and no Swift warning in it (`"no_warnings": true`, which `run-on-runner.py` checks with the same pattern as `check.sh`).
One machine could not finish the whole suite in the old job's 60-minute limit (run 42765562754 was cancelled at it); the shards finish it in about 20 minutes cold.

### The gate's self-test
<!-- id: make-check-selftest; keys: check-selftest, dry run, CHECK_ARGS, gate tests, stand-ins; src: Scripts/check-selftest.sh, Scripts/check.sh, Scripts/make-signing-identity.sh, Makefile -->

`make check-selftest` and `make check CHECK_ARGS=--dry-run` test the gate itself in seconds.
`make check-selftest` also tests:
- the baseline-recording script;
- the storage drill script's verdicts (see [Reusable test tools](testing-tools.md));
- the version script (see Versions, above);
- the Python tools in `Scripts/test` (see [Reusable test tools](testing-tools.md)), the l10n tools (`Scripts/l10n/tests`: the catalog, the scanner, the sync, the pack, the merge driver), and the pack tools (`Scripts/packs/tests`: the container's writer and the braille-table builder);
- the vendored SwiftSoup's script, `Scripts/vendor/swiftsoup/test_make_vendor.py`, the FFmpeg build script's tests (`Scripts/vendor/ffmpeg/test_build.py`), and the iPhone size tool's (`app-size.py --selftest`);
- the policy test that no tracked file holds a path of one Mac (see [Working with agents](../agents/working-with-agents.md)), and the issue tracker's tests (`.claude/skills/issue-library/tests`), which work only in temporary folders;
- that `make build` builds without code coverage and with `-Osize` while `make debug` does not;
- that `make release-goldens` names its settings and golden classes;
- that `make install` keeps the dSYMs, running install and uninstall in a sandbox folder, never /Applications;
- and the signing script, Scripts/make-signing-identity.sh, once for real, run twice against a throwaway keychain it creates unlocked, and otherwise with stand-ins for security and codesign, so it never asks for a password or touches the login keychain.

### The iPhone app in the gate
<!-- id: make-check-iphone-size; keys: ios-size, app-size.py, check.sh, without-tests, GITHUB_ACTIONS, TL05; src: Scripts/check.sh, Scripts/ios/app-size.py -->

Still in step 3 it builds the iPhone app for a device (`app-size.py build`, about 8 minutes the first time and 1 after, in `build/ios-size-DerivedData`, always an absolute folder) and holds it to the same two limits, a warning above 30 MB and a failure above 40 MB.
That step runs under `--without-tests` too, since the release gate runs `make check --without-tests`; only a GitHub runner (`GITHUB_ACTIONS=true`) skips it, with a line saying so, because the trains measure the iPhone app there.
`TEXTMOUTH_CHECK_SIMULATE_FAILURE=ios-size` fails that step on purpose.

## What the GitHub suite is not
<!-- id: what-github-suite-not; keys: runner-skips.conf, TestMachine.timeScale, strict_performance, PerformanceBaselineSupport, hostile file tests; src: Scripts/agents/runner-skips.conf, Scripts/agents/run-on-runner.py, TextMouthProductionTests/KF8HostileFileTests.swift, TextMouthProductionTests/MOBIHostileFileTests.swift, TextMouthProductionTests/HostedTestIsolationSupport.swift, TextMouthProductionTests/PerformanceBaselineSupport.swift -->

**What the suite on GitHub is not, compared with step 4 of `make check` on this Mac.**
It is weaker in four ways, and only `make check` here is the full gate:
- The 14 tests of `Scripts/agents/runner-skips.conf` are left out, as on `TestBuild`, so no job on GitHub runs them.
- The limits of `KF8HostileFileTests` and `MOBIHostileFileTests` are multiplied by 2.5 (`TestMachine.timeScale`, which only `run-on-runner.py` sets).
- The performance baselines run on no GitHub machine.
  The request says `"strict_performance": true`, which hands `TEST_RUNNER_TEXTMOUTH_PERFORMANCE_STRICT=1` to the test host as `make test PERFORMANCE_STRICT=1` does.
  But the baselines tests run only on the Mac model they were recorded on (`PerformanceBaselineSupport`) and skip on any other, so on a runner they check nothing.
  The old single job behaved the same way.
- xcodebuild in the shards is not given `-onlyUsePackageVersionsFromResolvedFile` (only `make test` is), so the pin check at the end of the gate covers the gate's machine only.

A plain `make check` on this Mac still runs all four steps in one go.
`make check-selftest` covers `--without-tests`.
