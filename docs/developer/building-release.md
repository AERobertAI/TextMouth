# Release builds
<!-- id: building-release; keys: Release, size settings, SIZE_PROFILE, make release, make install, golden tests; src: Scripts/size_settings.py, Makefile, Scripts/test/release-goldens.sh -->

Part of [TextMouth's documentation](../../README.md).

How a Release build is made smaller, which builds take which settings, and how the golden tests check the optimizer's output.

## The Release size settings
<!-- id: release-size-settings; keys: size_settings.py, SIZE_SETTINGS, SWIFT_LTO, LLVM_LTO, GCC_OPTIMIZATION_LEVEL, conditional-runtime-records, internalize-at-link, reflection names; src: Scripts/size_settings.py, Makefile, Scripts/ios/app-size.py, Scripts/agents/tests/test_size_settings.py, TextMouthProductionTests/ReflectionNamesTests.swift, research/SWIFT-SIZE-FLAGS-2026-11-23.md -->

`Scripts/size_settings.py` holds the compiler and linker settings that make a Release build smaller, defined once.
- **How a build takes them.**
  - The Makefile's `SIZE_SETTINGS` runs the script for a Release build only, and `make build` gives its words to `xcodebuild` on the command line, as it does `SMALL_CODE`, so they reach every target and every Swift package, which project.yml cannot.
  - `make check` and `make install` build through `make build`.
  - `Scripts/ios/app-size.py build` takes the same list from `size_settings.settings()` for the iPhone app's device build, through `Scripts/ios/iphone_release.py`, so `make ios-size`, `make check`'s iPhone step, and `make install-ios` (light unless given `SIZE_PROFILE=full`) have them too.
- **The profiles.**
  Full link-time optimization's link takes several GB of memory for some minutes, which can freeze a Mac with 8 GB, so a build takes the settings by its profile, `SIZE_PROFILE`:
  - `full`, every setting: `make install` and `make release`, the app that ships;
  - `light`, only `GCC_OPTIMIZATION_LEVEL=z`, the one setting that costs no memory at link time (the frontend flags were tested only with full link-time optimization);
  - `auto`, the default: full on GitHub Actions, which sets `GITHUB_ACTIONS=true`, and light on a Mac, for `make build`, `make check`, `make ios-size`, and the golden tests.
  Give another on the command line, as in `make install SIZE_PROFILE=light`.
  The script refuses a profile it does not know, and the build then stops rather than go without the settings.
  `python3 -I -B Scripts/size_settings.py --which` prints the profile a build would take, and `make check` prints it before the sizes.
- **Debug does not take them.**
  `make debug`, and the build the tests run on, keep Debug's own settings.
- **What each saves,** as `research/SWIFT-SIZE-FLAGS-2026-11-23.md` measured them:
  - `SWIFT_LTO=YES`: full link-time optimization of the Swift code, packages included, so the optimizer sees the whole program and drops what nothing reaches; the largest saving, for a longer link;
  - `LLVM_LTO=YES`: the same for the C code (LAME, liblouis, the braille helper);
  - `GCC_OPTIMIZATION_LEVEL=z`: `-Oz` for the C code, the smallest, a little slower;
  - `-conditional-runtime-records`: leaves out a runtime record (a protocol conformance, a type) that nothing refers to;
  - `-internalize-at-link`: makes public symbols internal at link time so the optimizer may drop them, which is safe because nothing links against the app's public symbols.
  The two flags are one `OTHER_SWIFT_FLAGS` setting, each passed as `-Xfrontend FLAG`; the study measured them as a pair.
- **Reflection names stay.**
  The script sets no `SWIFT_REFLECTION_METADATA_LEVEL`, since `without-names` would make `"\(error)"` and `String(describing:)` show only a type's name, and debug-log lines and problem reports print errors and cases that way.
  The three places that store or log a case's name write it out anyway (`PhoneImportQuestion.Choice.id`, `AudioEditError.caseName`, `RecordingCaptureError`'s description), and `ReflectionNamesTests` pins them.
  The level `none` is rejected in the study: SwiftUI finds a view's dynamic properties through reflection.
- **Turn one off.**
  - For one build, give the Makefile an empty list: `make build SIZE_SETTINGS=`.
  - For good, delete its entry from `SETTINGS` or `FRONTEND_FLAGS` in `Scripts/size_settings.py`, and both apps follow; `Scripts/agents/tests/test_size_settings.py` checks the list.
  - `python3 -I -B Scripts/size_settings.py --list --without NAME[,NAME]` prints the list less settings (by name) or flags (by flag), as the golden tests' build asks it (see below).
    A name it does not know, or any other argument, is refused with exit status 2, so a typo cannot leave a setting in; `--help` prints the usage.
- **Measure.**
  `make check` prints the Mac app's size and, in its iPhone step, the iPhone app's; `make ios-size` measures the iPhone app alone.
  On a Mac both are the light profile's; the trains' size builds and `make check` on GitHub Actions are full.

## The Release golden tests
<!-- id: release-golden-tests; keys: release-goldens, Osize, optimizer miscompile, ENABLE_TESTABILITY, GOLDEN_ARGS, lsregister; src: Scripts/test/release-goldens.sh, Scripts/test/run-area.py, Scripts/agents/run_locked.py, Makefile, project.yml, TextMouthProductionTests/TextPipelineGoldenTests.swift, TextMouthProductionTests/DocumentGoldenTests.swift, TextMouthProductionTests/MarkupGuardTests.swift, TextMouthProductionTests/PortableXMLDifferentialTests.swift, TextMouthProductionTests/ParserContentFidelityTests.swift -->

The ordinary suite tests a Debug build, and the Release app is compiled with `-Osize`, so an optimizer miscompile could change what a reader makes of a book without any test noticing.
`make release-goldens` (`Scripts/test/release-goldens.sh`) closes that gap.
Run it once before a release, and after any change to the build settings in project.yml, the Makefile's build rule, or `Scripts/size_settings.py`.
It builds the profile `auto`: on a Mac the light build; on GitHub Actions every setting but `-internalize-at-link`, though no workflow runs it there yet (TL22).

- **What it runs.**
  Six classes, through `Scripts/test/run-area.py`: `TextPipelineGoldenTests`, `DocumentGoldenTests` (the 57 files of `TestData/golden`), `MarkupGuardTests`, `PortableXMLDifferentialTests`, `ParserContentFidelityTests`, and `ReflectionNamesTests`.
- **What it builds.**
  The shipped configuration, Release with `-Osize` for the app and the packages and the profile's size settings, with only what a test host needs changed:
  - the size settings but `-internalize-at-link`, which the test bundle cannot link against, since it links against the app's symbols (nothing tests that flag but the app itself);
  - `ENABLE_TESTABILITY=YES`;
  - `LD_EXPORT_SYMBOLS=YES` (the shipped app has no export trie, and the test bundle links against the app's exports);
  - and `DEAD_CODE_STRIPPING=NO`, `DEPLOYMENT_POSTPROCESSING=NO`, and `STRIP_INSTALLED_PRODUCT=NO` (so the symbols the tests call stay).

  The compiled Swift code is the shipped code.
  What the tested binary lacks is the export trie, dead stripping, and stripping, which change no code.
- **What it costs.**
  The first run took 14 minutes 4 seconds, ran 129 tests with 0 failures and 0 skips, and its build folder took 1.5 GB.
  It plays no sound.
  When other agents work, run it through `Scripts/agents/run_locked.py`.
  Afterwards unregister the app it built with `lsregister -u` on `Build/Products/Release/TextMouth.app` in its derived-data folder.
- **Options.**
  `GOLDEN_ARGS` passes options to `run-area.py`: `make release-goldens GOLDEN_ARGS=--dry-run`.
  `make check-selftest` checks the dry-run command.
