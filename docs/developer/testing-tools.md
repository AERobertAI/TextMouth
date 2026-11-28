# Reusable test tools
<!-- id: reusable-test-tools; keys: Scripts/test, selftest, test scripts, make check, xcodebuild; src: Scripts/test/, Makefile, Scripts/check-selftest.sh -->

Part of [TextMouth's documentation](../../README.md).

The scripts in `Scripts/test/` run part of the hosted suite, check what a branch adds to it, read its logs, and try the importers and the voices on documents and voices the suite doesn't hold.
They need only the Mac's own tools and Python 3, print their usage with `-h`, and never launch the app outside the test host that `xcodebuild` starts.
Among its checks, `make check-selftest` runs every Python tool's selftest, and the storage drill script's, in about 30 seconds, without building.
The times below leave out the build, which takes about 5 minutes when nothing is built yet, and longer while agents hold all three build slots.

## Load-sensitive tests made to wait
<!-- id: load-sensitive-tests-made-wait; keys: flaky, flakiness, timing, deadline, busy Mac, expectation, slow Mac; src: TextMouthProductionTests/BookSearchModelTests.swift, TextMouthProductionTests/FeedDownloadTests.swift, TextMouthProductionTests/StorageGenerationMoveTests.swift, TextMouthProductionTests/DataDirectoryMoveTests.swift, TextMouthProductionTests/ViewsAndWindowsReaderSheetTests.swift, TextMouthProductionTests/IntegrationSleepTimerTests.swift, TextMouthProductionTests/ContinueToNextBookTests.swift, TextMouthProductionTests/BookmarkKeyboardAccessTests.swift, TextMouthProductionTests/ReadingCheckpointTests.swift, TextMouthProductionTests/ShortcutConfigFileTests.swift, TextMouthProductionTests/PlaybackSettingsAuditTests.swift, TextMouthProductionTests/FeedUICommandsTests.swift -->

The tests in the first five bullets are not load-sensitive, each made to wait for the thing it checks rather than for a moment, and shown to fail when its app code is broken and to pass 5 to 20 times of 5 to 20 under a busy Mac:

- BookSearchModelTests.testCancelledSearchPublishesNothing and its sibling, whose fake now waits for the cancellation itself.
- FeedDownloadTests.testADownloadThatStopsPartwayGoesOnFromWhereItStopped, whose stub drops the connection only once the app has written the first half.
- StorageGenerationMoveTests and DataDirectoryMoveTests.testAMoveShowsItsProgressWhileItCopies: the cause was in the app, a reading-statistics save queued before a move that wrote during its copy, and the move now waits for it.
- ViewsAndWindowsReaderSheetTests' redraw count, which publishes until three in a row draw nothing and then counts, since SwiftUI compares a re-made sheet by == only after AttributeGraph has worked out its type off the main thread, which load starves.
- IntegrationSleepTimerTests, ContinueToNextBookTests, BookmarkKeyboardAccessTests, ReadingCheckpointTests, ShortcutConfigFileTests, PlaybackSettingsAuditTests, and FeedUICommandsTests.testCancelDownloadStopsIt, whose checks wait for their condition with 30-second deadlines that end when it holds.
- Still load-sensitive, by design: the performance baselines and the audiobook-open benchmark; five classes keep fixed warm-ups with the same risk.

## The build train
<!-- id: build-train; keys: train, queue, TestBuild, train/base, hung test, request, GitHub Actions, wait-for-result; src: Scripts/agents/build-train.py, Scripts/agents/wait-for-result.py, Scripts/agents/heavy_lock.py, Scripts/agents/github_run.py, Scripts/test/run-area.py, TextMouthProductionTests/ContentIndexValidationTests.swift -->

The build train, `Scripts/agents/build-train.py`, is how agents build.
Agents do not build on their own, since their builds froze the Mac.
An agent commits its work on its branch and asks the train to test it (`build-train.py request --agent SLUG --branch BRANCH [--classes A,B] [--areas x,y] [--note TEXT] [--now]`), and one scheduled build every hour, on the hour (`build-train.py loop`, or `run` for one), pools every waiting request.
A test that hangs doesn't hold the train: when a run writes nothing to its log for 15 minutes, the train kills its test host, which fails that test as a crash, and the run goes on with the tests after it.
That watches only the train's own copy of the app.

- `--ios-size` has the train's GitHub run also build the iPhone app for a device and report its size (see [Building TextMouthiOS](building-ios.md)).
- Each train merges the commit each request names, not the branch's newest, onto a shared base, `train/base`, in a worktree of its own.
  It builds once, in one build folder of its own that is kept between trains, so each build is incremental, with two jobs, which needs about half the memory.
  It runs the union of the classes and areas asked for, and posts each agent its result on the message board.
  A branch that conflicts with the base, or with a branch merged before it, is left out of that train, and its agent is told which files conflicted.
  An agent that commits a fix before the train leaves asks again, and the newest request for a branch wins.
  `status` shows the queue and what a running train is doing.
  A train starts only with at least 3 GB free on the data volume.
- A name in `--classes` may be `Class/testMethod`, of a Mac or an iPhone class: a Mac method goes to run-area, an iPhone method to the iPhone job as `-only-testing:<bundle>/Class/testMethod`, and the agent's result counts the failures of its own method.
- The train checks the test names, methods included, against the merged tree before the run, leaving out and reporting the names it does not know, since run-area.py refuses a whole run for one unknown name, so one agent's typo, or a file name given for a class, never sinks every agent's train.
  A request with names the main branch lacks gets a warning when it is queued.
- A train takes the machine-wide heavy-work lock before it merges anything, as the type-checks do (see [The heavy-work lock](building-ios.md#the-heavy-work-lock)).
  It waits for the lock first in line, so no other job takes it first, for up to 50 minutes, and never runs without it: a train that waited in vain leaves its requests queued for the next one and tells the orchestrator who held the lock.
  The requests are taken once the train has the lock, so those made while it waited go with it.
  After its tests it counts the iOS errors in the merged tree, as `make typecheck-ios CENSUS=1` does, and lists those in the files each branch changes.
  The agent waits for its result in the background with `python3 -I Scripts/agents/wait-for-result.py --agent SLUG`, which exits as soon as the agent's result is written, since an agent that ends its turn to wait is never woken.
  A hung test holds every agent's request for the 15 minutes (`HUNG_RUN_MINUTES` in `Scripts/agents/build-train.py`) before the train kills the test host, so every wait in a test takes a limit.
- A train can build and test on GitHub instead (`build-train.py run --remote`, `loop --remote`): it merges here, pushes the merged tree plus a request to the branch `TestBuild`, waits for the run, and reports from the log it downloads.
  It takes no heavy-work lock and runs no iOS census here: the run builds the iPhone app on GitHub and the result lists its errors by file.
  With `loop --remote --soon N` it leaves N minutes after a request instead of on the hour, and at once for a request made with `--now`, or as soon as the running train ends; the requests waiting then ride along, and a failed train's hold still applies.
  See [Tests on GitHub Actions](testing-github.md).
- A train pools every waiting branch, so a branch that is broken on purpose, to prove that a new test notices the break, breaks every other agent's result too: never queue one.
  Prove a test on a scratch copy of the committed sources instead (a SwiftPM copy run under the heavy-work lock with the real home patched out), one deliberate break at a time, and expect each test to fail with its break and pass without it.
- A test of a directory walk must not trust the order a volume lists a folder in.
  A symbolic link hid the folder listed right after it, and a fixture that assumed the listing put a link before a folder passed against the old code on one volume.
  So the fixture grows, folder by folder or link by link, until a link really is listed right before a folder, and fails loudly if it never is (`ContentIndexValidationTests`).

### A remote train and a lost connection
<!-- id: remote-train-lost-connection; keys: github_run.py, pending-run.json, lost_minutes, collected run, gh run download, missed poll, TL07; src: Scripts/agents/github_run.py, Scripts/agents/build-train.py, Scripts/agents/tests/test_remote_train.py -->

A remote train keeps its run when the Mac loses GitHub (a closed lid on battery does), since the run goes on, and may pass, without the Mac:

- **A lost connection is a missed poll.**
  A poll of `gh run view` that fails after its four tries does not end the wait: it goes on to the run's limit (125 minutes, by a clock that leaves out the Mac's sleep), and says when GitHub was lost and when it was back.
  The train's `remote.json` then holds `lost_minutes`.
- **The download tries again.**
  Only gh's own "no artifact" answers mean a run without results; any other failure that survives the tries fails the train, and is never read as a run with no results.
- **A run that was not collected is collected next time.**
  Once GitHub shows the run, the train writes its ID, commit, merged tree, and whole request to `pending-run.json` in its folder (`build/orchestrator/train/`), and empties the record when the results are in hand.
  The next train that sends the same tree and the same request collects that run's results instead of pushing again, at most 3 times.
  A record is ignored when its run was cancelled or is gone, and the result says the results are those of an earlier train's run.
- `run_suite.py --remote` has no record file, so a suite pushes again.
- A train that loses GitHub while it finds the run it pushed leaves no record: the next train waits for that run, then pushes again, which costs one run.

## Portable XML differential tests
<!-- id: portable-xml-differential-tests; keys: XMLDocument, PortableXMLDocument, differential, EPUB, OPML, iOS XML, knownDifferences; src: TextMouthProductionTests/PortableXMLDifferentialTests.swift, TextMouthProductionTests/PortableXMLCorpus.swift, TextMouth/Parsers/PortableXML.swift, TextMouth/Parsers/PortableXMLBuilder.swift, TextMouth/Platform/iOS/Parsers/XMLTree+iOS.swift -->

`PortableXMLDifferentialTests` (in the import and feeds areas) tests the portable XML tree that the iOS app reads EPUB, feed, and OPML files with (see [The two apps and the platform folders](../architecture/platforms.md)).
It compares that tree with Foundation's `XMLDocument` on 104 documents, each read strictly and tidied: the XML documents of the test EPUBs, the feed, OPML, and OPF fixtures, and 61 small documents in `PortableXMLCorpus`.
It fails on any difference that its `knownDifferences` does not list with the reason and evidence, and on a listed difference that has gone away.
`testEveryXPathTheReadersPassIsCompared` scans the four reader files for XPath strings and fails on one the comparison does not make; its floor on how many it finds is 4, since the EPUB reader's package, NCX, and page list moved to `XMLElementIndex`.

## Mac braille table check tests
<!-- id: mac-braille-table-check-tests; keys: peakResidentBytes, liblouis, braille helper, watchdog, flaky, peak memory, table check; src: TextMouthProductionTests/MacBrailleTableCheckTests.swift, TextMouth/Services/MacBrailleTableCheck.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift -->

`MacBrailleTableCheckTests` reads the memory of the braille helper it checks a table with.
The watchdog (`WatchedProcess`) takes one reading the moment the helper exists, before it waits one poll interval (1 ms), so a helper that ends at once is still measured.
Before that reading, a short run left a peak of 0 and `testFrenchGermanAndSpanishPassAndRoundTrip` failed at its `peakResidentBytes` assertion on a slow or starved machine (Q15).
`testAHelperThatEndsAtOnceIsStillMeasuredOnce` pins the reading, and a peak of 0 never sets or lowers a limit.
If that test fails again, rerun its class: `python3 -I Scripts/agents/build-train.py request --agent SLUG --branch BRANCH --classes MacBrailleTableCheckTests`.
If it fails again, run the same class on main, to show that the failure predates the change; any other test failing beside it is not this.

## Golden tests against a Release build
<!-- id: golden-tests-against-release-build; keys: release-goldens, Release, Osize, optimizer, miscompile, goldens, testability; src: Scripts/test/release-goldens.sh, Makefile, TextMouthProductionTests/TextPipelineGoldenTests.swift, TextMouthProductionTests/DocumentGoldenTests.swift, TextMouthProductionTests/MarkupGuardTests.swift, TextMouthProductionTests/PortableXMLDifferentialTests.swift, TextMouthProductionTests/ParserContentFidelityTests.swift, TextMouthProductionTests/ReflectionNamesTests.swift, Scripts/size_settings.py -->

Run the golden tests against a Release build with `make release-goldens` (`Scripts/test/release-goldens.sh`), once before a release, so that an optimizer miscompile cannot hide behind the Debug suite, which is the only build the ordinary suite tests.
[The Release golden tests](building-release.md#the-release-golden-tests) says which six classes it runs, how it builds them, and what it costs.
It builds with the size settings of `Scripts/size_settings.py`'s profile, light on a Mac and full on GitHub Actions, but `-internalize-at-link`, which no test bundle can link against.

## Run only some tests
<!-- id: run-only-some-tests; keys: test-area, AREAS, AREA_ARGS, areas.conf, run-area, --changed, --repeat, flaky test; src: Scripts/test/run-area.py, Scripts/test/areas.conf, Scripts/test/testkit.py, Makefile -->

Run only some tests: `python3 Scripts/test/run-area.py feeds bookmarks`, or `make test-area AREAS="feeds bookmarks"`, where `AREA_ARGS` passes options, as in `make test-area AREAS=feeds AREA_ARGS=--dry-run`.

- Each name is an area from `Scripts/test/areas.conf`, a test class, or one test method written `Class/testMethod`.
  The method must be a `func testX()` in the class's own file, and a typo is refused with the closest names.
  Classes and methods mix in one run, and a method whose class is also named runs once, with its class.
  The file has 34 areas, such as `feeds`, `bookmarks`, `export`, `braille`, `readers`, `playback-end`, and `shortcuts`, which between them place every hosted test class.
  A merge that adds test classes should place them: `--unassigned` lists the classes no area names, and ends "0 unassigned classes" when every class is placed.
- Name every area in one command.
  One `xcodebuild` runs them all, through the build-slot wrapper, so no registration on the agents' message board is needed (an agent sets `BBS_AGENT=<name>` to report to the board).
  Each launch of the test host leaves about 23 MB in a system cache only you can purge, so never run the areas one after another.
- While it runs nothing is printed; afterwards it prints one fact per line, ending with PASSED or FAILED and the time taken.
- `--changed` picks the classes whose file mentions a type declared in a file changed since the merge-base with `--base REF` (default `main`), and runs them; it is a heuristic, so run the area or `all` before a merge.
- `--repeat N` builds once, runs the classes and methods N times, and ends with a report of the tests that changed outcome, for a suspected flaky test.
- `--clean` unregisters the build folder's app and deletes the folder.
- `-h` lists the facts it prints, the exit statuses, and the other options.
- A small area takes a few seconds of tests.
  The whole suite, `all`, took about 16 minutes of test time when it was last measured.

## Check the lines a branch adds
<!-- id: check-lines-branch-adds; keys: lint-tests, lint-a11y, lint-ogg, LINT_BASE, linter, static check, Vorbis, Apple reader; src: Scripts/test/trap-lint.py, Scripts/test/test-diff.py, Scripts/test/a11y-lint.py, Scripts/test/ogg-lint.py, Scripts/test/difflint.py, Makefile, TextMouth/Services/ImportAudioConverter.swift -->

Check the lines a branch adds, without building, in seconds.
They compare against `main`; `LINT_BASE=REF` on the `make` line compares against another branch point.

- `make lint-tests` runs
  - `trap-lint.py`, which flags test lines that can crash the test host (a `try!`, a force unwrap, a literal subscript, a `.wait()`), play sound, record, or touch the real library, and
  - `test-diff.py`, which lists what the branch did to tests that already existed: removed, renamed, or moved a test, removed or changed an assertion, added a skip or an expected failure, raised a timeout, commented out test code, or changed a fixture.
- `make lint-a11y` runs `a11y-lint.py`, which flags SwiftUI lines that VoiceOver or the keyboard cannot use: a control with no VoiceOver label or action, a tap with no VoiceOver action, a drag with no keyboard alternative, and the like.
- `make lint-l10n` runs `scan.py lint`, which fails when a file has more interface text outside an `InterfaceText.line` call than `Scripts/l10n/scan-baseline.json` records, or any lookup into Apple's tables (see [Localizing TextMouth's code](localization.md#the-scanners-lint)).
  `make check` also runs `make l10n-check` on the catalog, as its first step.
- `make lint-ogg` runs `ogg-lint.py`, which flags new calls that open audio with an Apple reader (`AVURLAsset`, `AVAssetReader`, `AVAudioFile`, an `AVPlayer`, or `AudioFileOpenURL`).
  Each must refuse every format the import converts first (`ImportAudioConverter.isNeverDecodedInApp`; see [Reading a source's audio facts](../architecture/state/imports-audio.md#reading-a-sources-audio-facts)), and a new call of `isOgg(` is flagged too, since a guard of that name refuses Ogg alone.
  The lint's own selftest runs with the others in `make check-selftest`.
- `trap-lint.py`, `a11y-lint.py`, and `ogg-lint.py` report each finding as an error, which fails the run, or as one to review, which a person judges and which fails the run only with `--strict`; `test-diff.py` fails only with `--strict`, when it has any finding.
  A line already reviewed ends with `// lint-ok: <the reason>`, and the linters pass it; a `lint-ok` with no reason is not accepted.
  On those three linters, `--all` audits every line of the tree instead and exits 0, `--counts` with it prints only the counts, and `--rule NAME` shows one rule's hits.

## Read test logs
<!-- id: read-test-logs; keys: slowest, compare, flaky, xcodebuild log, test log, run.log; src: Scripts/test/test-logs.py -->

Read logs:

- `python3 Scripts/test/test-logs.py slowest LOG` lists the slowest tests of a log (`-n N` sets how many, 20 by default, and `--classes` adds the 10 slowest classes),
- `compare OLD NEW` lists what changed between two logs (a test now failing, new, gone, or slower, meaning it takes more than `--slower` seconds, 2 by default, and more than 1.5 times its old time), and
- `flaky LOG LOG...` lists the tests that differ in outcome or time across two or more logs.
- `compare` exits 1 when a test is now failing, is new and failing, or is gone.
- A 22 MB log takes under a second.

## Quitting while work is held
<!-- id: quitting-while-work-held; keys: terminate, terminateLater, kAEQuitReason, Quit Anyway, log out, Command-Q, probe, AppKit; src: TextMouth/App/QuitReason.swift, TextMouth/App/QuitRequest.swift, TextMouth/App/QuitHold.swift, TextMouth/App/QuitFinisher.swift, TextMouth/App/UnsavedChangesTermination.swift, Scripts/test/quit-while-held.py, Scripts/test/quit-while-held/main.swift, Scripts/test/quit-while-held/Stubs.swift, TextMouthProductionTests/QuitWhileHeldTests.swift, Scripts/agents/run_locked.py, Scripts/test/areas.conf -->

Quitting while work is held (0.4.4): what the hosted suite cannot do, because no test may quit the test host, `Scripts/test/quit-while-held.py` does in child processes of real AppKit.

- It builds the app's real `QuitRequest.swift`, `QuitReason.swift`, `QuitHold.swift`, and `QuitFinisher.swift` with the probe in `Scripts/test/quit-while-held/` (`Stubs.swift` and `main.swift`) into a program with no windows.
  Each case runs in a child process with a watchdog that ends it after 8 seconds.
  Nothing is shown, played, or written but the compiled probe, in `build/quit-while-held/`, overwritten each run.
- The 11 cases, 2 of them controls that undo the fix on purpose and must show the fault (printed as REPRODUCED):
  - `old-queue` (control): a held quit asked again with `terminate(nil)` from a main-queue block never gets its reply.
  - `ask-queue` and `ask-task`: the same hold, asked again through `QuitRequest.ask()` from a main-queue block and from a main-actor Task, replies, and the work ends first.
  - `old-second` (control): a second quit while a reply is pending quits at once and cuts the work off.
  - `second-timer`, `second-key`, and `second-dock`: a second quit while the work is finished is cancelled, says the same words again, and the work ends before TextMouth does.
    The three send it from a timer, from Command-Q through the Quit menu item, and as a real quit Apple event, which is the Dock's Quit.
  - `logout` and `logout-param`: the system ending the session, with the SDK's quit reason as an attribute and as a parameter, is answered later, not cancelled, with the work ended and the words said once.
  - `logout-during-quit`: a log out while the person's quit is being finished is answered later too, and replied to as the work ends.
  - `no-work`: with nothing to finish, the quit goes ahead at once.
- The log-out cases send the SDK's `kAEQuitReason`, never `QuitReason`'s own constant, so a wrong keyword fails them.
- The script also scans `TextMouth/` (the case `ask-sites`): a line that calls `terminate(`, names terminate in a `#selector`, or calls `exit(` or `_exit(` fails unless the same line contains `quit-ok:` and a reason.
  It does not find `forceTerminate()`, a `Selector("terminate:")` built from a string, `abort()`, or `kill(`.
  The hosted test `QuitWhileHeldTests.testNoSourceAsksAppKitToQuitExceptTheHelperAndTheMemoryGuard` uses the same pattern and checks that it matches samples.
  A line that starts with `//` is skipped.
  The scan runs only when every case runs, with no overlay, and `--no-sites` skips it.
- Run it under the heavy-work lock: `python3 -I Scripts/agents/run_locked.py NAME python3 -I Scripts/test/quit-while-held.py`.
  Names after the script run those cases only, `--log` prints each probe's log, and `--overlay DIR` builds with the files of DIR in place of the sources of the same names, which proves on a scratch copy that a case fails with its fix undone.
  Exit 0 means every case showed what it should, 1 one did not, and 2 a compile problem.

### Proof and the hosted side
<!-- id: quit-while-held-proof; keys: scratch overlay, flake, QuitWhileHeldTests, not tested; src: Scripts/test/quit-while-held.py, TextMouthProductionTests/QuitWhileHeldTests.swift -->

- Breaks proved on scratch overlays:
  - a direct `terminate` instead of the helper fails `ask-queue` and `ask-task`;
  - a quit left pending fails `second-timer`, `second-key`, `second-dock`, and `logout-during-quit`;
  - a repeated request that stays silent fails the three `second-*` cases;
  - a log out cancelled like any quit fails `logout` and `logout-param`; and
  - the keyword `'why '` in place of the SDK's `'why?'` fails `logout`, `logout-param`, and `logout-during-quit`.
- One known flake: in one full run the control `old-second` printed "NOT REPRODUCED ... the work never ran" and the script ended with one case not showing what it should.
  Run alone, it reproduced.
  The real cases and the scan passed in every run.
- The hosted side is `QuitWhileHeldTests` (24 tests, in the windows and storage areas of `Scripts/test/areas.conf`), which pins the decisions:
  - every ask goes through the helper;
  - the words;
  - the finisher cancelling, saying the words again, giving up after the longest wait, and keeping Quit Anyway;
  - the session end answered later, also during a held quit;
  - work that began during the wait;
  - counted phrases; and
  - the reason keyword, the reasons, and the 120-second power-off window.
- Nothing in it quits, shows a panel, or speaks.
- Not tested: a real log out or shut down from loginwindow, which sends the reason as an attribute or a parameter that the SDK header does not settle, and whether VoiceOver speaks the panel's announcement when TextMouth is not the front app.

## Documents to try
<!-- id: documents-try; keys: make-corpus, corpus-report, corpus, hazard, importers, sample documents, manifest; src: Scripts/test/make-corpus.py, Scripts/test/corpus-report.sh, TestData/format-samples/, TextMouthProductionTests/CorpusReportTests.swift, TextMouthProductionTests/CorpusRunner.swift, TextMouthProductionTests/CorpusReport.swift -->

Documents to try:

- `python3 Scripts/test/make-corpus.py [--out DIR] [--seed N] [--large]` writes 24 deterministic documents, in EPUB, DOCX, Markdown, text, HTML, and PDF, each valid but awkward in a way its file name says, about 66 KB in all, in seconds.
  A `corpus-manifest.json` beside them records each file's hazard and what it should show.
  `--large` adds three heavy files: a 5 MB Markdown file, a 3 MB text file of one line, and a 40-chapter EPUB.
  One seed makes the same files each time.
  It has no generator yet for rich text, Word 97-2003, OpenDocument, web archive, SSML, or DTBook files, whose samples are in `TestData/format-samples`.
  The FFmpeg import's audio samples have three scripts of their own, which need an installed ffmpeg and only make the files:
  They are `Scripts/make-form-change-sample.sh`, `make-big-frame-sample.sh`, and `make-bad-packet-samples.py`.
  [Formats only ffmpeg reads](testing-formats.md#formats-only-ffmpeg-reads) describes the samples.
- `Scripts/test/corpus-report.sh <folder> [report.md]` imports a copy of every file in a folder, searched recursively, and writes a Markdown report of what the importers made of each.
  For each file it gives its format, title, author, headings and their levels, text length, first lines, every warning or refusal, and a checksum of its reading text.
  The report is plain words, headings, and bullet lists, written to be read with VoiceOver and a braille display; whether the reading order is right is still for a person to judge.
  The folder is only read.
  Ogg audio, and a ZIP holding it, is never decoded, and its section says `skipped`.
  The report is rewritten after every file, so a crash leaves it complete up to the last file that finished.
  At most 200 files are read, each given 180 seconds (`TEXTMOUTH_CORPUS_MAX_FILES` and `TEXTMOUTH_CORPUS_FILE_SECONDS` change them).
  `report.md` must be outside the repository, which ignores `*.md` files; the default is `textmouth-corpus-report.md` in the temporary folder.
  It takes about 7 seconds of test time on TestData and 2 minutes on the generated corpus.

## Test matrices
<!-- id: test-matrices; keys: matrix, end of book, sleep timer, cells, windows, table, end behavior; src: TextMouthProductionTests/EndBehaviorMatrixTests.swift, TextMouthProductionTests/EndBehaviorMatrixAudioSupport.swift, TextMouthProductionTests/EndBehaviorMatrixChapteredTests.swift, TextMouthProductionTests/WindowsMatrixTests.swift -->

Matrices, always on, each with its table in its file's header comment:

- `EndBehaviorMatrixTests` pins what a book does when it ends, for each of
  - 4 end-of-book behaviors,
  - 5 kinds of content (text, single-file audio, chaptered audio, multi-file audio, and DAISY), and
  - 5 sleep timer states (none; End of book; End of heading; minutes still running at the end; minutes that ran out before it).

  100 cells, each with a test, 80 of them in this class and 20 in other classes that the table names.
  It takes about 52 seconds in a full run.
  Its audio cells still play a book out in real time, but
  - the book is saved 0.3 seconds short of its end (`offsetBeforeTheEnd(ofChapterOf:)`),
  - `waitForTheEndToSettle(of:reports:)` waits only for the player's reports that follow an end, and
  - `nextBookAsked(for:…)` waits for the ask of the next book only in a cell that expects one.
- `WindowsMatrixTests` pins what Book A keeps doing while Book B is edited, moved, closed, or timed, and while the Library windows close: 117 of the 120 cells (12 states of Book A by 10 things that happen to Book B or to the library), the other 3 being covered by older tests that its table names.
  It takes about 8 seconds.

## Keyboard reachability
<!-- id: keyboard-reachability; keys: shortcuts, default key, unboundActions, menu item, key collision, reachability; src: TextMouthProductionTests/KeyboardReachabilityTests.swift -->

Keyboard: `KeyboardReachabilityTests`, which takes under a second, checks

- that every action has a way in (a default key or a menu item, or an entry in its `unboundActions` list with the reason),
- that no two default keys collide where both act,
- that every menu item is an action or is accounted for,
- that every default key can be spoken, and
- that no default key is one the shortcut rules refuse.

## Playback fuzz
<!-- id: playback-fuzz; keys: fuzz, random operations, seed, P09, silent reader, TEXTMOUTH_PLAYBACK_FUZZ_SEED; src: TextMouthProductionTests/PlaybackFuzzTests.swift, TextMouthProductionTests/PlaybackFuzzOperations.swift, Scripts/test/run-area.py -->

Playback fuzz: `PlaybackFuzzTests` applies seeded random operations to a silent reader of each of three kinds of book, a text book, a one-file audiobook, and a three-file audiobook.
The operations are play, pause, seeks, skips, headings, voice and speed changes, route losses, media commands, stale renders, sleep timers, and time passing.
After each operation it checks what a listener depends on (P09 in TODO-2026-09-04.md).
Nothing is heard.
By default it runs 5 sequences of 30 operations for each kind, in about 37 seconds.
A failure's message starts with the seed, the step, and the operations so far, and the seed alone reruns the sequence.
For a long run: `python3 Scripts/test/run-area.py --classes PlaybackFuzzTests --env TEXTMOUTH_PLAYBACK_FUZZ_SEQUENCES=200 --env TEXTMOUTH_PLAYBACK_FUZZ_SEED=N`, which takes about 26 minutes; `TEXTMOUTH_PLAYBACK_FUZZ_LENGTH` sets the operations in a sequence.

## Opt-in sweeps
<!-- id: opt-sweeps; keys: voice sweep, import fuzz, storage drill, disk image, hdiutil, damaged books, voices, opt-in; src: Scripts/test/voice-sweep.sh, Scripts/test/import-fuzz.sh, Scripts/test/storage-drill.sh, Scripts/test/storage-drill-selftest.sh, Scripts/test/run-area.py, TextMouthProductionTests/VoiceSweepTests.swift, TextMouthProductionTests/VoiceSweepReport.swift, TextMouthProductionTests/ImportFuzzTests.swift, TextMouthProductionTests/ImportFuzzMutator.swift, TextMouthProductionTests/StorageDrillTests.swift, TextMouthProductionTests/DiskImageDrill.swift -->

Opt-in sweeps: each skips unless its script sets its environment variable, and each script runs its test class through `run-area.py`, which builds first.

- `Scripts/test/voice-sweep.sh [report.md]` renders one fixed sample with every voice installed on this Mac, offline, with the call the app uses (nothing is played or recorded), and writes a Markdown report of what each voice did.
  The report says whether it produced audio, how long the audio is, how long the render took, and whether the voice hung or refused.
  A watchdog stops a voice after 20 seconds (`TEXTMOUTH_VOICE_SWEEP_SECONDS`), and three timeouts in a row stop the sweep.
  `VOICE_SWEEP_LANGUAGE=en` keeps the voices whose language starts with it.
  On the development Mac, 181 voices took 73 seconds of tests, and the English ones 25.
- `Scripts/test/import-fuzz.sh [--seed N] [--docs a,b] [--pdf]` damages each book in TestData under 300 KB in seeded ways.
  The ways are truncated, emptied, bytes flipped, a window zeroed, removed, or doubled, random bytes added, a ZIP's ends corrupted, NULs or invalid UTF-8 put into text, a megabyte line, and deeply nested HTML.
  It imports every copy as the library does: 103 copies of 6 books, in 3 seconds of tests.
  It damages the format samples that are single files under 300 KB in the same ways, 21 of the 24 (the RTFD and NIMAS folder samples are left out, since a folder has no bytes to damage), taking rich text, SSML, and XML for text and the Word templates and OpenDocument files for ZIPs.
  A damaged copy keeps the sample's import name, the Word 2003 XML sample's being an .xml file, and `--docs` names such a sample by its path, as in `format-samples/rtf/headings.rtf`.
  It checks that each import finishes, refuses cleanly, or gives a book that loads, that a refused import leaves nothing behind, and that the damaged file is left alone.
  `--pdf` adds the two small PDFs.
  A crash of the test host is a finding, not a script failure; the script exits 1 when a case breaks one of those checks and 3 when the test host crashed or the sweep did not finish.
- `Scripts/test/storage-drill.sh` unplugs or fills a small disk image part-way through an import, a library save, and a data-directory move, checks by checksum that the original files and the previous library survive every reported failure, and says whether any image is left attached.
  About 20 seconds of tests.
  Each test makes a disk image of 3 to 16 MB in the test host's sandbox, in the temporary folder, and deletes it when the test ends.
  It never touches `~/.TextMouth`, the preferences, or any volume but its own images: the fill that makes a disk full writes only to an image's own mounted volume, and throws when the image is not attached.
  Its last line is the verdict.
  `Storage drill: PASSED` means at least one drill test ran and not every one skipped, none failed, and no image is left attached.
  `Storage drill: FAILED` means a test failed or an image is left attached.
  `Storage drill: NOT RUN: ...` means no drill test ran, as with `--dry-run`, `--list`, or `--clean`, or when every test skipped.
  It exits 0 only for PASSED, 1 for FAILED, and 2 for a setup error and for NOT RUN.
  `Scripts/test/storage-drill-selftest.sh`, which `make check-selftest` runs, tests those verdicts in a second, without building, with stand-ins for `run-area.py` and `hdiutil`.

## Measure listener-heard changes on real samples
<!-- id: measure-listener-heard-changes-real; keys: corpus, real samples, listener, synthetic text, documents folder; src: TextMouthProductionTests/CorpusReportTests.swift, TextMouthProductionTests/CorpusRunner.swift, Scripts/test/corpus-report.sh -->

Where a fix changes what a listener hears, measure it on real samples: a synthetic text can pass while a real book shows the difference (`CorpusReportTests` reports on a folder of documents).
