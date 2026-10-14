# Testing TextMouth

Part of [TextMouth's documentation](../../README.md).

## The hosted test suite

The tests are one XCTest bundle, TextMouthProductionTests, hosted by the app itself: Xcode launches TextMouth.app and runs the tests inside it, so they exercise the real code through `@testable import TextMouth`. New tests belong in TextMouthProductionTests/. The files under TextMouthTests/Sources/Tests are older scenario groups that project.yml lists one by one.

A process hosting tests never touches your data. When the XCTestConfigurationFilePath environment variable is set, as XCTest sets it, TextMouth keeps its data directory, this Mac's own folders (its Logs folder, its folders in Application Support, and its caches), and its preferences in a sandbox folder named TextMouthTests- followed by the process number, in the temporary directory. In that process, VoiceOver announcements made through the app's announcer are recorded instead of spoken, macOS is never asked for the microphone unless you run the microphone test (below), and a test that leaves a reader window open fails. That process also takes no part in the system's media session: it never registers for the commands of headphones and media keys, nor tells the system it is playing, so a suite running while you listen can't take those commands from the TextMouth you are listening to. Nor does it reach the network: its feed connections refuse every request, the feed tests answer theirs from a stub server of their own, and the feed engine never refreshes, downloads, or deletes anything by itself there. Nor does that process post a notification, or ask permission for one.

Each run deletes its sandbox as it finishes, and, as it starts, deletes in the background the sandboxes that earlier runs left behind, such as one that crashed. The system reuses process numbers, so a sandbox counts as left behind once no process with its number is running, or the one running started more than an hour after the sandbox was made. With TEST_RUNNER_TEXTMOUTH_KEEP_SANDBOX=1, a run keeps its sandbox for you to look inside, with a KEPT-SANDBOX.txt file in it that keeps later sweeps away; a later run given the same process number moves it aside, adding -kept- and a short suffix to its name. Delete a kept sandbox when you are done with it.

- `make test` runs the whole suite. It runs `swift run` in TextMouthTests/, whose small runner calls:
  - With `TEST_DERIVED_DATA=<folder>`, as in `make test TEST_DERIVED_DATA=build/DerivedData`, the runner builds in that folder, counted from the repository root, instead of Xcode's default DerivedData folder.
  - `xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- Every target compiles in the Swift 6 language mode: `project.yml` sets `SWIFT_VERSION` to `6.0` for the whole project, beside `SWIFT_STRICT_CONCURRENCY` set to `complete`, and TextMouthTests/Package.swift builds the test runner in the same mode, so Xcode, `make build`, `make test`, and `make check` all report the same diagnostics, and a data race the compiler can find is an error. The mode also checks at run time that main-actor code called from Objective-C, such as a closure handed to a framework callback, runs on the main thread, and stops the app if it does not. The project's coding agents run the suite without parallel testing and with a build folder of their own; the `SWIFT_STRICT_CONCURRENCY=complete` in their command is redundant, and harmless:
  - `xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete -derivedDataPath /tmp/TextMouth-DerivedData`
- To run one test class, add `-only-testing:TextMouthProductionTests/` followed by the class name, such as `-only-testing:TextMouthProductionTests/CountWordingTests`.
- A full run compiles the app and takes four to five minutes. Some tests skip in an ordinary run:
  - Opt-in tests that need a copied book or a library to profile, set up as TextMouthTests/README.md describes. That file also explains the playback profiling script, Scripts/profile-production-playback.sh.
  - Tests that read the accessibility structure SwiftUI builds, which it builds only while an assistive client such as VoiceOver is running.
  - Tests that read, through accessibility, the AppKit controls SwiftUI draws in a hosted window, such as steppers, sliders, and pop-up buttons, in a session that exposes none of them. Each run looks once, at a stepper of its own, and where it finds none exposed, every such test skips with one message, "This session exposes no accessibility elements for the AppKit controls in a hosted window", and the test log has one HOSTED_ACCESSIBILITY_UNAVAILABLE line. Where the controls are exposed, as on the development Mac, a control missing from a view, or left without its label, still fails its test.
  - The bookmark keyboard tests, which need Keyboard navigation turned on in System Settings.
  - The microphone test, which records about three seconds, with a pause, from this Mac's default microphone, and runs only with TEST_RUNNER_TEXTMOUTH_MICROPHONE=1; its first run may show macOS's microphone prompt. Every other recording test uses a stand-in microphone and an answer of its own to the permission question, so the suite never shows the prompt.
  - The real-drive tests, which run only when you name folders on cloud drives for them (see Testing on real cloud drives).
  - The transcription tests that use this Mac's own speech recognizer (TranscriptionFixtureTests), which run only on macOS 26 or later, on a Mac that can run the recognizer, with the English speech model installed, and in a checkout whose TestData holds the two untracked DAISY audio ZIPs; each transcribes one short file. With TEST_RUNNER_TEXTMOUTH_TRANSCRIPTION_LONG=1 they also transcribe both books whole, about a minute and a half more. No test downloads a speech model.
  - The measurement behind TRANSCRIPT-CLEANUP-RESEARCH-2026-10-04.md (TranscriptAccuracyMeasurementTests), which runs only when `TEST_RUNNER_TEXTMOUTH_TRANSCRIPT_MEASUREMENT` names a folder, on a Mac that can transcribe, with the English speech model installed, and takes minutes. It measures the recognizer on the two DAISY audio ZIPs a checkout keeps, against their books' text, and on each audio file in the folder's audio folder, named as in `audio/<text>--<voice>.m4a` (or .wav, .caf, or .aiff), against `texts/<text>.txt`, the text it was made from. It keeps each transcript in the folder's transcripts folder, so a second run doesn't transcribe again, and writes measurement.md, the document's tables, and differences.json, every difference with its confidences and context. `TEST_RUNNER_TEXTMOUTH_TRANSCRIPT_MEASUREMENT_LOCALE=en-US,en-GB` measures in both Englishes. It downloads and plays nothing.
  - The two tests that need an installed ffmpeg, which TextMouth looks for in Homebrew's and MacPorts' folders and along PATH: one that writes MP3 through it, the route MP3 takes only should the LAME built in fail to start, and one that runs every premade filter preset through it and through TextMouth's own filters and compares them. They skip on a Mac without ffmpeg.
  - The opt-in benchmarks of the performance work (below).
  - The performance baselines tests, while the Mac is busy, and on a Mac model or in a build configuration other than their baselines' (see The performance baselines).
- GitHub's macOS runner, where `make check` runs for every push to main and every pull request (see [The make check gate](building.md#the-make-check-gate)), skips more tests than the development Mac. There SwiftUI builds no accessibility structure, a hosted window exposes none of its AppKit controls to accessibility, and keyboard navigation is off, so the three kinds of test above that read accessibility or need keyboard navigation skip rather than fail, as do the opt-in tests and benchmarks, and the performance baselines tests, whose baselines belong to the development Mac's model.
- The benchmarks of the performance work of October 3, 2026, time what each change made faster and print their figures in the test log. They are opt-in, since they take minutes or need a run of their own, and each group runs when its variable is 1; xcodebuild hands a variable whose name starts with TEST_RUNNER_ to the test host without that prefix:
  - TEST_RUNNER_TEXTMOUTH_LARGE_BENCHMARKS: the speech-preparation benchmarks at the sizes too slow to time in every run, and four that time the system synthesizer, muted, and the first speech engine. Three of those four mean something only when each runs alone, named with -only-testing, in a process of its own.
  - TEST_RUNNER_TEXTMOUTH_VIEW_BENCHMARKS: ViewsAndWindowsBenchmarks, which measure what a change of the library costs the list, what a playing reader costs its sheets, what a closed reader still holds, and how many test sandboxes the temporary folder holds, and DuplicateFinderTests.testMeasureWhatAnAuthorScansResultsCost, which measures what Find Duplicate Books' results cost to show, every group at once and the first page.
  - TEST_RUNNER_TEXTMOUTH_BENCHMARKS: TextPipelineBenchmarkTests, which time the text pipeline's old and new code side by side, best in a Release build, as in `xcodebuild test -configuration Release ENABLE_TESTABILITY=YES -only-testing:TextMouthProductionTests/TextPipelineBenchmarkTests` with the rest of the usual arguments.
  - TEST_RUNNER_TEXTMOUTH_RENDER_BENCHMARK: what rendering a chapter's speech costs in memory and main-thread time. It takes about half a minute, and nothing is heard.
  - TEST_RUNNER_TEXTMOUTH_TRACK_CHANGE_BENCHMARK: how long an audiobook's next file takes to start playing, timed with silent files.
  - PersistenceCostTests and LibraryModelBenchmarkTests run in every run instead. They check what a change costs in counts that follow from the code alone, such as bytes written, file-system calls, and publishes of the library, never in time, which a busy Mac would change, and print their figures on lines beginning PERSISTENCE_COST: and PERFMODEL:.

## The performance baselines

PerformanceBaselineTests keep what the performance work of October 3, 2026 made faster from slipping back. They measure a library and books generated to the size of the developer's, never your own library, and run in every run of the suite, in about half a minute. They measure:

- launch with a 643-book library: reading library.json, the startup repair, and finding the text caches that need rebuilding;
- the first sort of the library by File Size, and one derivation of the All Items list for each of the six sorts;
- one live reading position update, and the bytes one 30-second reading checkpoint writes for a book whose record is as large as the developer's largest;
- opening a 1 MB EPUB for the first time until the speech of its first chapter is prepared, and opening it again from the text TextMouth kept, and opening a 3-file audiobook until it has loaded;
- preparing the speech of a 1,000,000-character chapter with the developer's 16 substitution rules, which TextMouthProductionTests/performance-substitutions.json keeps a copy of;
- the most memory a 40,000-character chapter's rendered speech takes while it is built, and what it keeps;
- extracting the 1 MB EPUB's text;
- the processor time of one cloud refresh of a library outside the cloud;
- the main-thread time one reader publish costs the open Headings sheet.

How they judge:

- Each number is the median of five runs, after one more that warms caches and is not counted. TextMouthProductionTests/performance-baselines.json holds each one's baseline, with the Mac model, build configuration, and date they were recorded on.
- A number more than twice its baseline is measured five times more, and the test fails only when the lower median is still more than twice its baseline. A number at 1.5 times its baseline or more prints a line beginning PERFORMANCE WARNING:, and one at half its baseline or less a line beginning PERFORMANCE NOTE:, since new baselines would tighten the check. Every number is printed on a line beginning PERFORMANCE:.
- The tests skip, printing PERFORMANCE SKIPPED: and why, while the Mac is busy (its one-minute load average above its number of cores), so other work cannot fail them, and on any Mac model or build configuration other than the baselines', where the numbers say nothing. With TEST_RUNNER_TEXTMOUTH_PERFORMANCE_STRICT=1 a busy Mac measures anyway: `make test PERFORMANCE_STRICT=1` sets it, and `make check` uses it. A baselines file that is missing or can't be read fails the tests rather than skipping them.

Recording new baselines:

- After a deliberate change to what they measure, run `make perf-baselines` on an otherwise idle Mac, adding `TEST_DERIVED_DATA=<folder>` to build in a folder of your own. It runs the tests alone with TEST_RUNNER_TEXTMOUTH_PERFORMANCE_RECORD=1: each test waits, for up to five minutes, until the Mac is quiet, and once every number is measured the file is rewritten with this Mac's model and today's date.
- It prints each old and new number, keeps xcodebuild's output in build/perf-baselines.log, and ends with PASSED or FAILED. Nothing changes unless the whole run succeeds. Review the file's diff and commit it with the change it records.
- The baselines recorded on October 3, 2026, on the development Mac (a Mac15,12: Apple M3, 8 cores, 8 GB), in a Debug build, each the median of five runs:
  - Launch with 643 books: 134.252 milliseconds.
  - First sort by File Size: 26.243 milliseconds.
  - One list derivation, in milliseconds: Title 4.221, Author 4.453, Date Added 1.090, Last Opened 2.893, File Size 2.811, Manual Order 4.230.
  - One live reading position update: 145.621 microseconds.
  - One 30-second checkpoint: 851 bytes.
  - Opening the 1 MB EPUB to its first chapter's speech, the first time: 207.571 milliseconds; again, from its kept text: 11.799 milliseconds.
  - Opening the 3-file audiobook: 4.539 milliseconds.
  - Speech for the 1,000,000-character chapter with the 16 rules: 235.522 milliseconds.
  - Rendered speech of a 40,000-character chapter: 43.358 megabytes at its peak, 43.354 megabytes kept.
  - Extracting the 1 MB EPUB: 1,193.865 milliseconds.
  - One cloud refresh of a local library: 0.178 milliseconds of processor time.
  - One reader publish to the Headings sheet: 1.652 milliseconds of main-thread time.

## Testing on real cloud drives

CloudDriveIntegrationTests runs the cloud services against real sync services. It is opt-in: its tests skip unless the TEXTMOUTH_CLOUD_TEST_ROOTS environment variable lists folders for them.

- Make a folder named TextMouth Cloud Tests in each drive to test, and list the folders' full paths, separated by colons. xcodebuild hands a variable to the test host when you set it with the prefix TEST_RUNNER_, as in:
  - `TEST_RUNNER_TEXTMOUTH_CLOUD_TEST_ROOTS="$HOME/Library/CloudStorage/Dropbox/TextMouth Cloud Tests" xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:TextMouthProductionTests/CloudDriveIntegrationTests`
- When any entry isn't the full path of an existing folder with that name inside a cloud drive, or is listed twice, the tests fail and use no folder at all. CloudDriveTestSupportTests checks these rules in every ordinary run.
- Each test works only inside a new folder of its own, writes small files of random bytes there (the small-library test uses the repository's TestData books), and deletes the folder when it ends, even after a failure. Nothing else on the drive is read or changed, and the app's library stays in the test sandbox. With TEST_RUNNER_TEXTMOUTH_CLOUD_TEST_KEEP_SMALL_LIBRARY=1, the small library stays on the drive, for the checks made by hand. A run moves about 36 MB up and 10 MB down for each drive.
- On October 3, 2026, every test passed against Dropbox, which showed that:
  - Download and removal requests work: a test book's files uploaded within 5 seconds, their downloads were removed at once, and they downloaded again within a second through TextMouth's book service.
  - A file whose download was removed reports its real size, and a clone made before the removal stays readable.
  - A package renamed into the drive, as an import puts a new book in place, syncs as one book, and a hidden folder syncs within 4 seconds.
  - Remove Download refuses a book whose new file hasn't finished uploading.
  - Progress is reported only at 0 and 100 percent for small files, and a file's modification time moves by up to 118 nanoseconds when it downloads again, which is why TextMouth compares the times of a text cache's files to the microsecond.
- Later that day, after TextMouth learned to treat a book's package that iCloud Drive syncs whole as one item, every test passed against iCloud Drive and Google Drive too. Dropbox, whose files each carry their own flags, was not run again. The runs showed that:
  - iCloud Drive syncs a book's package as one item: the package carries the sync flags and the files inside it none, and a request to download or remove one of those files is refused as if the file didn't exist. Removing the package's download leaves the whole package in the cloud at once, nothing inside it can be looked up until it downloads again, and TextMouth's book service brought it back within a second. Google Drive syncs each file, as Dropbox does, though its package folders carry sync flags too.
  - iCloud Drive uploaded a test book within 10 seconds, and Google Drive within half a minute, since Google Drive waits 15 to 30 seconds before it starts uploading.
  - iCloud Drive publishes the progress of a package as a whole and none for the files inside it, and Google Drive each file's; on a quick download both reported only 0 and 100 percent.
  - Google Drive reports an evicted file's real size. iCloud Drive gives a file it downloads again a modification time in whole seconds, so a text book whose package came back has its files read once for their digests when it next opens, before its text cache is trusted; Google Drive moves the time by up to 107 nanoseconds, as Dropbox does.
  - On both, a clone made before a removal stays readable, a package renamed into the drive syncs as one book, a hidden folder syncs within half a minute, and Remove Download refuses a book whose new file hasn't finished uploading.
- CLOUD-STORAGE-MANUAL-TESTS-2026-10-03.md, in the same folder as this file, gives the commands for every drive and the matrix of checks to make by hand, with VoiceOver steps, for what these tests can't reach: TextMouth's own screens and commands on a real drive, and a drive that is paused, signed out, or offline.
