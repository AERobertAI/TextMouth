# The agents' history

Part of [working on TextMouth with coding agents](../../AGENTS.md).

This page holds the status sections of earlier campaigns, newest first, and then the stories behind the rules of AGENTS.md and CLAUDE.md.
AGENTS.md keeps only the latest status.

## Where things stood on November 13, 2026

- Main is version 0.4.7, tagged `v0.4.7` (unpushed), with everything the user asked for at midnight that day: Search Library (Option-Command-F; a plain search under a second on their 737-book library, from a search store in Caches prepared in the background after launch), Leading articles (Settings > Library > Titles, three choices, MARC 21's articles in eleven languages), each reader window's own sleep timer (the cause of the "stuck" timer: a second reader opened beside the first showed the app's one shared timer), the Reading List's Remove books when finished and Keep these books on this Mac, batches A, B, C, and F of the TODO's triage (`build/orchestrator/nov13/triage-report.md`), the iPhone unit tests on GitHub, and a Release app compiled for size: 19.5 MB against 23.55 MB, with `make check` failing above 20 MB and a new `make release-goldens`.
  Every DAISY book is read again once at the first launch.
  The user still runs 0.4.2.
  Records in the TODO; the running log, briefs, and reports in `build/orchestrator/nov13/` and `Scripts/agents/briefs/2026-11-13/`; questions in `humanQuestions/2026-11-13.md`.
- Every branch went review (Opus for the large and the data-touching, Sonnet for small batches), then a fix round, then a narrow Sonnet check, then a Mac full suite on `integrate/1113`, then a fast-forward of main.
  Every review found real problems, among them a blocker (batch B's nesting refusal swallowed by a `try?`), a random DAISY file order under a launch re-read, and a timer registry that let go too early.
- Not done: the audit's runtime fixes (`build/orchestrator/optaudit/audit-report.md`, C3, C4, C6 to C9, C11, C12, C16, C17), which waited for the timer merge; `Book` held by reference (821 KB, question 6); the triage's batches D, E, and G to K, and the formats FMT34 and FMT24; the local-first library's Phase 0 (`research/LOCAL-FIRST-LIBRARY-RESEARCH-2026-11-13.md`), which waits for the user.
- Lessons of that day, which hold for any campaign:
  - Never search from `/` or the home folder: an agent's `find /` walked Downloads, Documents, Music, and the cloud drives and put macOS privacy prompts on the user's screen.
  - GitHub's Mac build cache can go stale (trains failed to link symbols their sources held); deleting the Mac caches (`gh api -X DELETE .../actions/caches?key=...`) fixed it.
  - Always type-check the tests before a train: a remote train does not rebuild without a branch that fails to compile, so one compile error leaves every branch of it untested.
  - Don't end each agent with a full suite on GitHub: each holds the one TestBuild lane 30 to 40 minutes (the iPhone job), and every train waits behind it.
    One broad train, then the orchestrator's Mac suite at the merge.
  - The API's Cloudflare 403 ("Please run /login") stopped agents twice, passing; resume them.
    A lead near a million tokens met it again on resume: take over its last steps instead.
  - Subagents often can't write outside their worktrees: save their reports from their final messages.
  - Tests that pin a machine's timing fail on another machine: a search speed limit tuned on the runner, and AppKit's type-select wait (under 1.0 s on this Mac, 1.2 to 1.3 on the runner).
    Pin margins every Mac meets.

## Where things stood on November 11, 2026

- Main is version 0.4.6, tagged `v0.4.6`.
  It is 0.4.5 plus the End of heading fix (`fix/end-of-heading-silent-start`), which the iPhone interface tests found.
  Full suite 11,987 tests, 81 skipped, 0 failures; `make build` (Release) succeeded, signed with the TextMouth Developer certificate, 23 MB, with no compiler warning.
  The user still runs 0.4.2.
- GitHub's main is still 05327665 (0.4.4), and the tags are only on this Mac.
- Main also holds `ci/ios-ui-tests` (no version change).
  GitHub's iPhone job runs the 33 interface tests (35 since `ci/ios-unit-tests`): 11 press Play or type, only where `TEXTMOUTH_UI_SOUND` is 1.
  Only `Scripts/agents/run-ios-ui-tests.py` sets it, and it refuses to run anywhere but on a GitHub runner.
  Mac suite 11,986 tests, 81 skipped, 0 failures (one fewer than 0.4.6: `testTheSearchTextIsWhatTheVariableHolds` went with `TEXTMOUTH_SEARCH_IN_BOOK`); on GitHub, run 43032983986 ran all 33 interface tests and skipped none, so the guard lets a runner through.
  32 passed; `SearchUITests.testTheSearchSheetPassesTheAudit` failed on 4 Dynamic Type findings the 3 runs before had not had, and the Mac shards' one failure was the known `LibrarySessionLeaseTests` flake.
- Pushing main switches the workflow guard on.
  `humanQuestions/2026-11-11.md` asks the user to push main, then the tags.
- `ci/ios-unit-tests` (the same day) moved the rest of the iPhone testing to GitHub:
  - The iPhone job runs the 19 unit tests (`TextMouthiOSTests`, no sound) and the interface tests in one `xcodebuild` run (`run-ios-ui-tests.py`).
    The summary, the join, a train's result, and `run_suite.py --remote` count each bundle apart, name a failed test with its bundle, and a bundle that gives back fewer results than its classes hold fails the job.
    The Mac verdict is untouched.
    No workflow file changed.
  - `PlaybackUITests.testAnEndOfHeadingTimerSetAtTheCoverPlaysOnAndNamesItsStop` proves 0.4.6's fix: on a proof branch with the merge's changes under `TextMouth/ViewModels/` taken out (never merged), it failed with the old symptom (run 43048443160).
  - The Search sheet's audit now reports Dynamic Type without failing it.
    The sheet's text does grow: `LargeTextUITests.testTheSearchSheetHoldsAtTheLargestText` measures it at the default and the largest size (run 43041108180).
  - With this, nothing of the iPhone testing needs the simulator runtime on this Mac; see the branch's report.
- Lessons of that day, which hold for any campaign:
  - Tests that act as a person does find what tests of the parts miss.
    The first iPhone test to set End of heading at a book's opening found a bug that the Mac's unit tests had never met.
  - Two pushes to TestBuild seconds apart can cancel each other's run.
    GitHub registers a run a few seconds after its push, so an idle check alone can't see it.
    `ci/ios-ui-tests` adds a lock that every push from this Mac holds until its run appears.
  - GitHub's API allows 5,000 calls an hour for the whole account, shared by every agent and tool.
    `github_run.py` already polls a run, so a second `gh run watch` on it only costs calls: five extra watchers and the other agents' polls used the hour's calls on November 11, and the sender of a run died on the 403 with the run still going (its results are still there to download afterward).
    Start no watcher beside a sender, and wait with a local check.
  - Code that asks where Play will start must not prepare speech to find out.
    Play's own waiting path exists so that a long chapter is never prepared on the main actor.

## Where things stood on November 10, 2026

- Main is version 0.4.5, tagged `v0.4.5`; 0.4.3 and 0.4.4 are tagged too, and the user still runs 0.4.2.
  It holds `ci/suite-clean`, which made the full suite clean on GitHub, with three fixes in the app:
  - the voice listing (`VoiceCatalog`) and the audio decoding check (`AudioMediaProbe`) left Swift's concurrency pool, each with a deadline (10 and 60 seconds);
  - Cancel is heard during the XML guard's scan of a large part.
    Full suite 11,975 tests, 81 skipped, 0 failures; `make build` (Release) succeeded, signed, 23 MB, with no warning.
- GitHub's main is 05327665 (0.4.4), which the user pushed at 00:59 on November 10.
  Until they push main with `tests.yml`, the workflow guard is off.
  The tags are only on this Mac, and every tagged commit up to v0.4.4 is on GitHub.
- Trains leave on request.
  `build-train.py loop --remote --soon 5` sends one 5 minutes after the first waiting request, and it takes 3 to 4 minutes on GitHub.
  A push to TestBuild waits for the run in front of it.
- The GitHub full suite ran clean three times in a row, in 13 to 16 minutes.
  It still fails now and then on a one-off test, so the Mac's `run_suite.py` stays the merge gate.
- Every GitHub run builds the iPhone app, and since the `ci/ios-ui-tests` branch (November 10) a full suite, the phone area, or a request naming an interface test class also runs its interface tests (`TextMouthiOSUITests`) there, in an iPhone 17 simulator, pressing Play and typing.
  The user withdrew the old rule against both in the simulator; it was the orchestrator's rule, not theirs.
  The new rule: a test that presses Play or types makes sound, so it runs only where `TEXTMOUTH_UI_SOUND` is 1, which `Scripts/agents/run-ios-ui-tests.py` alone sets on the runner; on this Mac those tests skip, saying why.
  A failed interface test fails the iPhone job and never the Mac tests' verdict.
  In the last three full suites, the 33 tests took 14.3 to 23.6 minutes of xcodebuild, the step (with the simulator's set-up, 3.6 to 7.0 minutes) 19.4 to 27.1 minutes, and the iPhone job 28.7 to 40.1 minutes, so the iPhone job is the longest of a full run (29 to 40 minutes against 14 before; the runners differ by a factor of 1.6); a request for the phone area pays it too.
  The interface tests' compile errors are found by a GitHub run, or by `swiftc -typecheck` against the iPhone Simulator SDK (see Type-checks and tests in `docs/developer/testing.md`).
- Lessons of that day, which hold for any campaign:
  - A test that hangs only on a 3-core runner can be the app blocking a thread of Swift's concurrency pool.
    The spindumps Xcode keeps for a test past its allowance showed it.
    Blocking work, such as listing voices or decoding with `AVAssetReader`, runs on dispatch queues, with deadlines.
  - A deadline's timer must not hold what it guards.
    The merge's narrow check found every probe's asset held for a minute after its answer.
  - Rebalanced shards change which classes share a test host, and that brings out order dependencies that a fixed order hid.
  - Keep the user's rules apart from the orchestrator's.
    A rule the orchestrator wrote into briefs was later passed off as the user's.

## Where things stood on November 9, 2026

- Main is version 0.4.3, tagged `v0.4.3`:
  - the KF8 follow-ups (`.mobi` at 1.1.0);
  - unmarked UTF-16 and UTF-32, and linked book folders (plain text at 1.0.1, HTML at 1.0.4);
  - the transcripts' follow-ups;
  - the iPhone's audit findings (unshipped).
    Full suite 11,905 tests: 11,818 passed, 81 skipped, 5 expected failures, and 1 interrupted when the user's own TextMouth started beside the host.
    That class passed alone 3 times.
    `make build` (Release) succeeded.
- Every version from v0.2.0 is tagged (Versions in `docs/developer/building.md`); pushing tags is the user's.
- The repository is public at `github.com/AERobertAI/TextMouth`, with `origin` at `git@github.com:AERobertAI/TextMouth.git`.
  The orchestrator, its train, and the `ci` agent may push to the `TestBuild` branch only, for GitHub Actions; every other push stays the user's.
- The tools gained four things:
  - `run_locked.py`, `run_suite.py`, and `copy_phases.py` in `Scripts/agents/`;
  - `make generate` through `regenerate-project.py`, so `make install` leaves no noise;
  - trains that take back a branch left out only for a conflict;
  - `make typecheck-tests`, the step before every train request.
- Then main went to version 0.4.4, tagged `v0.4.4`, after midnight.
  It holds the quit fix (`fix/quit-while-held`: a quit asked again never hangs, a second Command-Q never cuts held work off, a log out still waits) and the iPhone's Search in Book (`ios/search-1109`, unshipped).
  Full suite 11,962 tests, 93 skipped, 0 failures; the Release build compiled, and only its signing failed, with the login keychain locked after midnight.
- Then `ci/github-actions` merged (20c38b46): trains and full suites on GitHub Actions.
- The user's line for the day is 45% of the week left; nothing new starts until the work under way is done.
- Lessons of that day, which hold for any campaign:
  - Never put a deliberate break on the build train: it tests every request in one tree, and two scratch branches with fixes broken on purpose failed other agents' classes.
    Prove a break with a harness through `run_locked.py`.
  - A hosted test failing with "The test runner exited with code 0" may be the user's own TextMouth starting beside the host, which shares its bundle identifier.
    Read the system log for `terminate:`, and run the class alone before calling it a fault.
  - Outside reviews found three faults no train could.
    A decoder rule that would have turned valid text into garbage on the launch re-read.
    A chapter rule that could cut a chapter in two.
    A quit-reason keyword that would have cancelled log outs.
    Every test and probe of the last had pinned the same wrong keyword: a test should take an outside constant from the SDK, not from the code it tests.
  - Test files that don't compile cost an hourly train each: `make typecheck-tests REF=<commit>` finds them first.

## Where things stood on November 8, 2026

- Main is version 0.4.2: spoken-audio export (M4B, M4A, or MP3 in a chosen voice, a chapter at each heading), transcripts that come with podcasts and audiobooks, symbols in `.docx` and Word 2003 XML documents, the markup guard's large stack, so a book nested however deeply can't crash TextMouth, and KF8 Kindle books (`.azw3`, and the KF8 half of a `.mobi`).
  Full suite 11,853 tests, 81 skipped, 0 failures, the iPhone interface's included; `make typecheck-ios` 0 errors, 0 warnings.
  At the first launch, `.docx` and `.wordml` books are read again once (1.3.0), and `.mobi` books once (1.0.0).
- The iPhone interface (`ios/lead-1108`) is on main too, unshipped: it ran in the simulator for the first time that morning, its Mac tests pass, and after its fix round (`ios/fix-c-1108`: one placement for every sheet's buttons, after the title, and full-contrast text) 17 of its 22 XCUITests pass; the five left are audit findings, three with no known cause.
  Since 07:20, at the user's word, a train leaves every hour and heavy jobs run one after the other (see Builds go through the build train).
  The hand checks and the one question 0.4.2 leaves, listening while a spoken-audio export runs, are in `humanQuestions/2026-11-08.md`.
- Lessons of that day, which hold for any campaign:
  - `make typecheck-mac`, `make typecheck-ios`, and `make typecheck-tests` check HEAD's commit as it was when they started (`git archive`), not the working tree.
    Commit first, and start them again after later commits.
  - A clean textual merge of `project.pbxproj` can still leave out a branch's new file when the branch never listed it and relied on the train's regeneration.
    Run `Scripts/agents/regenerate-project.py` after every merge, clean or not.
  - `git merge-tree --write-tree` and `git commit-tree` scout a chain of merges for conflicts without touching the working tree.
  - Told to use a train's wait for reviewing their own diff, agents found before the train what it would have cost an hour to learn from it: two near-identical scans to share and tests that could trap the host (KF8), and a backup file compiled into the test bundle (iPhone).
  - A narrow check of each branch on Sonnet, from one shared brief (`Scripts/agents/briefs/2026-11-08/verify-common.md`), took 2 to 18 minutes and found what the fix rounds had missed: two guards no test pinned, a policy test too loose to fail, and a measurement that settled less than its report said.

## Where things stood on November 7, 2026

- Main is version 0.4.1: the follow-up sweep, the reader follow-ups, EPUB 3 export, Word 6 and Word 95 documents with symbols read by their font, and the markup guard, which closes three ways a damaged or crafted book, web page, or feed could crash TextMouth.
  Full suite 10,631 tests, 78 skipped, 0 failures; `make typecheck-ios` 0 errors, 0 warnings.
  At the first launch, `.doc` books are read again once (1.3.0), and `.docx` and `.wordml` books once (1.2.0).
- Not on main yet, each with a review and a fix round behind it: speech export (`speechexport/finish`), podcast transcripts and chapters (`podcast/finish`, which merges after speech export), DOCX symbols (`readers/docx-symbols`), KF8 Kindle books (`readers/azw3`, which merges main and routes KF8 through the guard next), and the guard's large-stack parse (`fix/markup-guard-stack`).
  The iPhone interface (`ios/interface`) has its spec and nine slices; the iOS 26.0.1 simulator is now installed, so it can run for the first time.
  The running log is `build/orchestrator/followups1105/agents.md`; the questions left with the user are in `humanQuestions/2026-11-06.md` and `2026-11-07.md`.
- Lessons of that day, which hold for any campaign:
  - The model's safeguards can stop an agent that searches for inputs that defeat a security check, on Sonnet and on Opus alike.
    When that happens, don't do the agent's work yourself, and don't hand the case to another agent: make the defence not depend on the search (here, a stack big enough for any tree the size limit allows).
  - A branch under every reader trains the import and feeds areas, not only its own classes: the guard's trains passed while a MOBI test it changed never ran, and only the full suite caught it.
  - `make bump-patch` and `make set-version` regenerate the project through `Scripts/agents/regenerate-project.py`, which keeps the copy-files phases in their old order.
    Check with `git diff --stat` that only `project.yml` and the `MARKETING_VERSION` lines of the project changed.
  - Stamp the running log from the clock (`build/orchestrator/followups1105/logline.py`), never from an estimate.

## Where things stood on November 6, 2026

- Main is version 0.4.0: the one policy for every document reader, OpenDocument and Word 2003 XML, and DRM-free KFX, after 0.3.2's removal of the page commands and a library in the cloud that fetches its files and opens by itself.
  Full suite 10243 tests, 78 skipped, 0 failures.
- The record is in the TODO, under "One policy for every document reader".
  The questions left with the user are in `humanQuestions/2026-11-06.md`.
- Lessons of that night, which hold for any campaign:
  - Every first review found blockers, and every fix round's verification found something.
    Keep review, fix, and verify as separate steps.
  - Private train copies of a branch tangle with other agents' commits.
    When branches conflict, make one shared base early (`--base`), and have agents request their real branches.
  - A hang in a test holds every agent, as a trap does: the train now kills a host that writes nothing for 15 minutes, and every wait in a test takes a limit.
  - Never wrap `make typecheck-*` in another hold of the heavy lock: they take it themselves.
  - Every `rm` uses a literal or relative path, never a variable, substitution, glob, or built path: the user's rule, and it goes in every agent's prompt.
  - A subagent may be refused writes outside its worktree.
    Let its final message be its report, and save it from there.

## Where things stood on November 4, 2026

**November 3 and 4: iOS phase 0.**

- **The request.**
  On the morning of November 3 the user asked how hard an iOS port would be.
  The answer is `research/IOS-PORT-RESEARCH-2026-11-03.md`: one repository, a second app target compiled from the same sources, with eleven questions in `humanQuestions/2026-11-03.md`.
  That evening they asked: "please try spending the night with well reviewed sonnet agent teams and the pooled contribution scheduled builds to try conducting the first phase and fixing all IOS errors without changing MacOS behavior if possible."
- **How it ran.**
  - The orchestrator (Opus) laid a foundation on `integrate/ios-phase0`: the `TextMouthiOS` target, `TextMouth/Platform/{macOS,iOS}/`, the platform aliases, `make typecheck-ios` and `typecheck-mac` (SwiftPM, so no 10 GB iOS platform download), `make mac-projection`, and the heavy-work lock.
  - Five Sonnet teams split the census's 817 errors by file: shell, a11y, engine, media, and xml (briefs `Scripts/agents/briefs/2026-11-03/`, reports in `build/orchestrator/ios0/`).
    Every worker's work was accepted as written.
  - A Sonnet outside review read each team branch.
    The xml review found a real iOS hang (fixed).
  - An Opus review read every Mac change against main and found none that changes what the Mac does.
- **Merged into main** (fast-forward to cb7cc4c6): the iOS target compiles and links (strict check BUILD SUCCEEDED, 0 errors) and the Mac compiles what it did.
  Suite: 9322 tests, 75 skipped, 1 failure (the braille memory reading, which passed alone).
  No version bump, since nothing changed for the Mac's user.
  Docs: `docs/ios-phase0`.
- **Next:** phase 1, the first iPhone reader, after the user's answers to questions 1 to 4 and 6 and the iOS platform download.
  The phase 1 follow-ups are in the TODO.

**Lessons of November 3 and 4:**
- **The compiler is the census.**
  A search for `import AppKit` missed half the work, since SwiftUI brings AppKit's names in.
  Files that import AppKit without using it show no census error, and two were left unwrapped.
  Check strict mode, or list the bare imports, before the end.
- **Shared signatures cross teams.**
  Most messages between teams were one signature (`NSWindow` to `PlatformWindow`) that one team's file declared and another's called.
  The orchestrator picked those single commits onto the integration branch at once, so the other team could rebase.
- **A trial merge before the reviews finish** found the last two errors while the reviews ran.
- **The projection tool** turned "no Mac behavior change" into a mechanical check.
  Its global pool of moved lines could hide a deletion: match whole blocks (a follow-up).

## Where things stood on November 1, 2026

**November 1, version 0.2.5.**
On the morning of November 1 the user asked that a reader window go on to the next book in place instead of opening a new window, with Next and Previous for a folder's or feed's items and "a global setting for the behavior of moving from book to book for windows and a local one for feeds and folders".
At about 09:50 they added: "the sleeping timer in particular I would like to move still running to the new book without a new window opening."
- **How it ran.**
  - One Sonnet agent, `nextbook`, built it (design `research/NEXTBOOK-WINDOW-RESEARCH-2026-11-01.md`, briefs `Scripts/agents/briefs/2026-11-01/`).
  - Three Opus reviews and three Sonnet verifications each found real problems, mostly in the sleep timer's hand-over, and six fix rounds closed them.
    The orchestrator read the last round itself (reports in `build/orchestrator/nextbook/`, gitignored).
  - The user's questions 1 to 18 are in `humanQuestions/2026-11-01.md`.
- **Merged into main:**
  - **`feature/nextbook-window` (aad1fab9).**
    - A reader window shows the next book in place: the scene's `$bookID` changes, and `.id(bookID)` gives the same window a new reader.
    - The Playback tab's "Open the next book in" (`nextBookWindow`), and a feed's or folder's own choice in Feed Info and Folder Settings.
    - Next in Folder and Previous in Folder, in the Navigate menu.
    - A running sleep timer goes on with listening: the shared service holds it for the next book until that book's reader takes it.
  - **`docs/nextbook` (ff328b9a)** and **version 0.2.5** (4d72a43c).

**October 30 to November 1.**
On Friday evening, October 30, before the Saturday 08:00 reset, the user lifted the usage limit for the night ("treat it as no limit") and asked: "Please try working through any remaining todos and unfinished work that doesn't require me, improve the tests and look for bugs", with a new feature, customizable Library views.
- **How it ran.**
  - Four teams worked through the night, every agent on Opus (`Scripts/agents/briefs/2026-10-30/`).
  - A triage agent read the TODO and the code for open items (`build/orchestrator/oct30/triage-report.md`, gitignored).
  - Outside Opus reviews read the views, braille, and bug hunt branches, and each found real problems.
    Every one was fixed and checked by a Sonnet verifier.
  - The branches were merged on `integrate/oct30`, and one full suite ran there through the build train (train 1031-1800).
    Main was fast-forwarded to it on November 1 (3769130e).
- **Merged into main:**
  - **`team/views` (71f22891).**
    Customizable Library views.
    - The categories became views of one system, in a View pop-up ("Library view"), with a new Feeds view.
    - A Library tab in Settings orders the views and shows each Always, When Applicable, or Hidden.
    - The user can make views of their own, each a filter and a sort.
    - Go to View reaches the first nine views (Command-1 to Command-9).
    - An Opus review's 15 findings were fixed.
    - The design is `research/LIBRARY-VIEWS-RESEARCH-2026-10-30.md`.
      Its 16 questions to the user are in `humanQuestions/2026-10-30.md`; the build follows their recommended answers.
  - **`team/braillecodes` (0b523829).**
    Braille file characters, chosen in the Braille tab, Export, and Book Information: North American Braille ASCII, Eurobraille six-dot, and Unicode braille patterns.
    Nine review findings were fixed.
  - **`team/bughunt` (d1a1a602).**
    - About 40 bugs found by five Opus reviews and the triage were fixed.
    - Its outside review found seven data problems, fixed in `bughunt/datafix`.
    - Its HTML depth guard changed the words of deeply nested books, so it was reverted (`bughunt/revert-htmldepth`).
      Redoing it is a follow-up.
  - **`team/tests` (090bce28).**
    Eleven load-sensitive tests made deterministic, vacuous tests made to fail, and new tests for risky code.
    These tests found four app bugs, which were fixed.
  - **`docs/oct31` (6fabf93f)** and **version 0.2.4** (6116fbb5).
- **Paused and not merged.**
  These teams started before the integration and must rebase onto main:
  - `team/podcastext`: FMT23 and FMT25, SRT and WebVTT transcripts and a podcast's own transcript and chapters;
  - `team/speechexport`: FMT43, speech to audio.

  `team/fixes30` was never launched: the triage's batches A to C, charter `Scripts/agents/briefs/2026-10-30/team-fixes.md`.

**October 25 (after midnight).**
On the evening of October 24 the user asked for FMT16's follow-up: "Go ahead and do the reopening with a different encoding … can it be set in the info screen for a book with the current one seleted in the popup?"
One Opus agent built it (`Scripts/agents/briefs/2026-10-24/encodingchoice.md`).
One Opus reviewer found a wrong-text bug and four risks, then verified the first fix round and found four more gaps; both rounds were fixed.
It was merged on `integrate/encoding-choice` after a green full suite, and main was fast-forwarded (b835fa79).
Merged into main:
- **`formats/encoding-choice` (7b5375b9 and 0b1bf8dd).**
  - Book Information's Text Encoding row is a pop-up, with the encoding the book is read in selected and how it was decided.
  - Choosing another reads the file again in it, strictly.
    Places move with their words, an edit is kept as a copy, and the book stays busy throughout (a quit waits through the shared quit hold).
  - A failure puts the old text back.
    `textEncodingSource` records a choice.
- **`docs/encoding-choice` (c4d8ae8e)** and **version 0.2.3** (b835fa79).

**October 24.**
At 02:25 ET on Saturday, with 13% of the week left before the 08:00 reset, the user asked: "Are there any more formats or bugs / todos you could work on? ... I want you to use as much as possible".
Five agents worked on branches (`Scripts/agents/briefs/2026-10-24/`).
The week ran out at 04:43, and they resumed after the reset.
An independent Opus reviewer read each branch, and every one had real bugs, which its author fixed and a verifier checked.
The branches were merged on `integrate/oct24`, one full suite ran there, and main was fast-forwarded to it (c7958b3c).
Merged into main:
- **`pages/polish` (cedc79ef).**
  The pages follow-ups:
  - Go to Page's words, and Return on a repeated label;
  - heading labels without page-break numbers, so the EPUB and HTML page readers are at 1.0.1;
  - PDF grouped labels;
  - Page left out of the bar's pickers for a book without pages.
- **`pages/braille` (bd9bc748).**
  PG12 (braille pages) and PG13 (plain text form feeds), each with its own page-reader line (V07).
- **`braille/reading` (d8d2a3d7).**
  - EBAE emphasis is read where it is certain, with a safety net that keeps liblouis's words.
  - EBAE export stays plain.
  - Contracted UEB reads "people", not "p", before a terminator.
- **`fix/replace-existing` (7a2e503e).**
  ST04's carry-over: Replace Existing keeps the old copy's ID, places, bookmarks, settings, folder, reading-list place, and transcript.
  The new copy is committed before the old one goes.
- **`fix/pages-oct24` (2370465e).**
  Go to Page takes its reasons from the pages, and a BRF whose only form feeds are at its edges counts as having none.
- **`docs/oct24b` (723052e4)** and **version 0.2.2** (c7958b3c).
- **`formats/encodings` (1cf19935, with docs `docs/fmt16`, 7335f088): FMT16.**
  - At import, TextMouth guesses the encoding of a text file that names none, only when the Windows-1252 reading proves wrong.
    The guess is recorded with the book and named in Book Information.
  - It was held back from the first integration after one fix round still turned some Western text into other encodings.
  - The user then asked for its check ("Just do the check now").
    After a second fix round and a one-line book-ID check, it merged on `integrate/fmt16`, after its own full suite.

**October 23.**
The user asked for four things before installing: transcript work, a review of transcription for bugs, a plan of the breaking changes to make before the official install, and a changelog with a daily version policy ("I want to install the new version with it as stable as you can make it").
Friday's line was 95% of the week used, before Saturday's 08:00 reset.
Merged into main:
- **`team/transcripts` (fec4de73).**
  - A feed episode's transcript can be edited and cleaned up.
  - Search in Book (Command-F) searches a transcript by time, with Go Back (Command-[).
  - Markdown exports escape only what Markdown needs, and a transcript's content.md is at layer 1.1.0.
  - Retranscribe Audio… names the command once a book has a transcript.
  - Two reviews' fifteen findings were fixed.
- **`release/changelog` (447a8c01).**
  `docs/user/changelog.md`, and the daily version policy ("Versions" in building.md; `make bump-patch` and `make bump-minor`).
- **`research/plan020` (737e641f).**
  `research/PLAN-0.2.0-2026-10-23.md`, and the TODO's section "Before the official 0.2.0 install" (ST01 to ST10, V01 to V07).
- **`team/stable020` (8aa0c690).**
  ST01 to ST10, V02 (`OnDiskContractTests`), and V03 (a library a later version wrote opens).
- **`fix/polish020` (cf7862f6).**
  Narrower page-label rule, Delete Folder keeping a newer version's books, precise chapter timing, and V05.
- **`docs/oct23` (712f5507), with V01.**
- **The version is 0.2.1** (5485d559): the daily bump.

**October 21.**
The user asked for three things: fix the failing test ("send a team to see if its a real problem"), carry text formatting through braille, and pages across formats as a navigation unit, "the feature set implemented first today".
Today's line was 30% of the week left.
Merged into main:
- **`fix/reader-load-race` (825a3f23).**
  The race was real: a book moved while a reader opened it was called damaged.
  A moving package is now noted, and the reader waits and reloads, in cloud libraries too.
- **`braille/emphasis` (b4ca969e).**
  Helper protocol 2 carries emphasis both ways where liblouis reads it back: UEB, but not EBAE or most of this Mac's tables.
- **`team/pages` (77e798a0).**
  - A `<!-- page: LABEL -->` marker in content.md.
  - Page as a navigation unit, with Go to Page…, and the page on the reader screen and in Where Am I?.
  - Pages for EPUB, PDF, DOCX, DAISY text, and textutil's formats.
  - B12 (a finished Edit Text change is kept by automatic re-reads) and B13 (textutil's joined words).
  - **PG09's launch re-read of existing books** was merged switched off, since its Opus review found it unsafe for the live library.
- **`pages/pg16` (5f38016b).**
  It is now safe and on: a byte-for-byte compare, a stopped batch recognised, and a differing book with no edit on record copied (`content.md.edited-<UTC>`) before it gains pages.
  Two Opus reviews.
- **`release/version` (0587b7c4).**
  Version 0.2.0, `Scripts/set-version.sh` and `make set-version`, the beta procedure ("Versions" in building.md), and the user's What's new page (renamed the changelog, `docs/user/changelog.md`, on October 23).
- **Research and documentation:** `research/pages` (3c7d43b1), and the documentation pass `docs/oct21` (5c8a2a07).

**October 19 and 20.**
On October 19 the user asked: "Go ahead and try working on the braille reading features tonight. and the export feature, for the braille I want it possible to have multiple braille tables and contracted and uncontracted settings and use the library.
(see how much it increases app size)".
Two teams worked on it, each an Opus lead with Sonnet workers (`Scripts/agents/briefs/2026-10-19/`), and fresh Opus reviewers read every branch before its merge.
Merged into main:
- `team/export` (0db62a38): FMT18 and FMT19.
  The Export dialog's Convert to picker offers Markdown, HTML, RTF, and Word 97-2003.
  One swift-markdown walker of content.md feeds every writer.
  Every exported file is made in a scratch folder and moved in with an exclusive rename.
  12 review findings were dealt with.
- `team/braille` (3996434d): FMT20, FMT21, and FMT22.
  - liblouis 3.39.0 runs in the TextMouthBraille helper, with four English tables and a Braille tab.
  - TextMouth reads BRF, BRL, and PEF, and writes BRF and PEF from Export.
  - 26 review findings over two rounds were fixed.
    The app grew about 0.6 MB, to about 19.75 MB.
- `team/mactables` (b5fffa42, then e7461fe1).
  A Language pop-up offers this Mac's VoiceOver liblouis tables (3.34.0, read in place), each measured and checked before first use, beside the built-in English ones.
  16 findings over two reviews were dealt with.
- Documentation passes: `docs/oct19` (c77c9cf4), `docs/oct19b` (bc5ef365), and `docs/oct20` (077b4e1e).

**State at the end:**
- **Main's suite:** **9301 tests, 75 skipped, 0 failures**, on `feature/nextbook-window` merged with main's code in train 1101-1800, the same tree as main's merge (aad1fab9).
  Only the documentation merge and the 0.2.5 bump followed.
- **Not installed yet:** the user's installed build is still 0.1.1 (fb46ea6e).
  The first launch of 0.2.x reads every text book again for pages, safely (PG16), braille and plain text books included (V07).
- **Questions:**
  - `humanQuestions/2026-11-01.md` holds 18, on the next-book window.
    The user said yes to 9 to 11.
    1 to 8 and 13 to 18 are built as recommended and unanswered.
    12, whether Next in Reading List should follow the list's direction, is open, and nothing was built for it.
  - `humanQuestions/2026-10-30.md` holds 21.
    Questions 1 to 20 (views and braille) were built with their recommended answers.
    Question 21, whether Delete After Import may delete a ZIP holding files that were not imported, is open, and nothing was built for it.
  - That file also lists 20 older questions still open in `2026-10-10-evening.md` and `2026-10-12.md`.
  - `humanQuestions/2026-10-23.md` holds four: the escaping (V06) comes after the install; V03 is built and V04 is not; the rehearsal on a copy of the library needs the user's yes; the install's version follows the policy.
- **Pending with the user:** the push and install, now of 0.2.5, with the hand checks of the next-book window (the timer through a slow iCloud download, Command-W just after "Starting", focus in a switched window); the rm-hook offer; and whether and when to resume the paused teams.
- **The next candidates:**
  - the next-book window's follow-ups in the TODO (questions 12 and 18);
  - the October 30 follow-ups in the TODO, the HTML depth guard first;
  - the paused teams and `team/fixes30`;
  - the tests team's five unrun briefs (`Scripts/agents/briefs/2026-10-30/tests/`);
  - reading the first launch's `PAGES_UPGRADE_SUMMARY` once the user installs;
  - V06 in the first update after the install.

**Lessons of November 1:**
- **An agent that says it is waiting has stopped.**
  At 15:34 the `nextbook` agent wrote that it was waiting on two trains and ended its turn.
  Both results sat unread until 17:47.
  When an agent's work goes to the train, the orchestrator starts a background waiter on `build/orchestrator/train/results/<agent>.md`, which exits when the result is written.
- **A delayed closure can carry a test's fixtures past its teardown.**
  A move asks for its book half a second after saying so, and holds its reader, with the test's settings, until then.
  A test that ended within the config's 250 ms save delay left a save that ran after its sandbox was removed.
  The failure sentence then landed in the next test, which records every announcement.
  A fixture that removes a folder at teardown writes any waiting save first, in a teardown block added after the folder's (2f3674d2).
- **Every review round found something.**
  Each of the six rounds was answered by a fix and a check.
  The sleep timer's hand-over was where most of the problems lay.

**Lessons of October 30 to November 1:**
- **Opus everywhere spent the week.**
  - All 76 agents ran on Opus, and the 5-hour limit stopped them at about 20:45 and 02:20.
  - The window came back at 03:20, but nothing ran until 12:06, nearly nine hours lost; see "Lessons that cost time".
  - The user then asked for Sonnet.
- **The machine.**
  - **Memory.**
    Eight gigabytes cannot take the agents' builds beside the user's own apps.
    At 12:41 on October 31 a build of about 2.5 GB left 64 MB free and the Mac froze.
    The forced restart killed every agent and background task and emptied the session's scratch folder.
    Keep the orchestrator's scripts in `build/orchestrator/` or in the repository.
  - **The build train fixed it.**
    The trains that followed ran one build at a time, with two jobs, and the Mac did not freeze again.
- **The disk** fell from 12 GB to 1 GB several times, taken by the teams' build folders (3 to 4 GB each), swap, and the system icon cache (3,517 entries by 01:51 on October 31).
  By November 1 the icon cache was down to 174 entries.
- **Every outside review found real problems again:**
  - 15 in views and 9 in braille;
  - in the bug hunt, seven data problems and a depth guard that changed a book's words.

  The 17:30 train on October 31 failed four tests, for two causes:
  - the removal marker's key list, pinned by the bug hunt, lacked the braille branch's new key, which only the merged tree could show;
  - `train/base` held an older commit of views than the integration branch, one without its fix of the editor's fit test.
    Once an integration branch exists, point `train/base` at it.
- **An unnoticed result.**
  The final suite passed at 18:17 on October 31.
  Nothing woke the orchestrator, since the board watcher wakes it only for questions, and the result sat unread until 01:50 on November 1.

**Lessons of October 24:**
- **Every branch needed a fix round.**
  All five reviews found real bugs, two of them data loss or changed words, and the verifications after the fixes found new bugs in three branches.
  Plan review, fix, and verify for each branch.
- **Integrate on a branch.**
  A fresh integration branch from main, merging only verified branches, keeps main installable throughout, and a branch that fails verification (FMT16) is simply left out.
- **A guarantee by construction beats fuzz and patch.**
  Braille's safety net uses liblouis's reading whenever the pass's words differ from it.
- **Narrow verifiers.**
  A fresh Opus verifier, given the review report and the fix range, cost less than resuming a large reviewer.
- **After the weekly reset,** a SendMessage to each stopped agent resumed it with its uncommitted work intact.
  Resumed long-context agents are costly: 3% of the new week went in 10 minutes.
- **Every prompt needs the live-library rule.**
  The pages reviewer copied two of the user's books to /tmp because its prompt lacked it.
- **zsh's `status` is read-only.**
  A background script that assigns `status=$?` dies after the suite and reports a failure; use another name.

**Lessons of October 23:**
- **Two teams in parallel.**
  Two teams, each with an in-team Opus reviewer and then an outside Opus review of its branch, found real bugs both times.
  The outside reviews' fixes were small enough for one Sonnet or Opus agent each.
- **Trial merges.**
  `git merge-tree --write-tree --name-only main <branch>` shows whether two teams' overlapping branches conflict, before merge-chain commits anything.
- **Disk.**
  Two teams building at once on about 11 GB free fell to 3 GB.
  A shared disk budget across teams, at most two builds in all, would have been better than two builds per team.
- **The version policy:** bump once at the day's end with `make bump-patch`, and complete the changelog's section yourself.
  XcodeGen may need several runs before only the version lines change.

**Lessons of October 21:**
- **A review of the whole branch is worth its cost for anything that rewrites the live library.**
  The pages review found the launch re-read unsafe (heading-only edits invisible to its check, kept books unprotected afterwards, an interrupted batch turned into false edits), and switching it off let the rest ship.
- **A fix to a shared writer needs the golden and heading-annotation classes in its targeted run.** pagesfix's marker change passed 388 tests and failed three others at the merge, and merge-chain had already committed the merge. main was reset to its parent (local and unpushed), and the branch was fixed and merged again.
- **Disk.**
  It hit 0 GB at 04:44, with six workers and two other agents building on about 6 GB, and every shell call failed.
  Run one build at a time when under 10 GB free, and delete build/DerivedData-main right after each merge suite: an idle one blocked the pages team for 45 minutes.
- **Untracked fixtures.**
  TestData zips that only the main checkout has (the DAISY audio books, the transcription fixtures) are missing from worktrees, so goldens that read them are first checked at the merge.
- **merge-chain** must be started with the Bash tool's background mode.
  A shell `&` worked once, but gave no notice when it ended.

**Lessons of October 19 and 20:**
- **A login expiry** stops every agent and watcher silently; the usage monitor exits with "AUTH PROBLEM".
  After the user logs in, a SendMessage to each agent id resumes it, and workers came back with their uncommitted work intact.
- **A restart of the user's Claude Code session** makes the old session's agents unresumable ("No transcript found"), and the session's scratchpad goes with it.
  Agents should therefore commit small and often.
  The orchestrator keeps its working files in the repository's gitignored `build/orchestrator/`, and a fresh agent finishes from the branches.
- **Review fix rounds earned their own reviews:**
  - the braille round's heading fix split multi-line titles on real books (98 of 233 Pride and Prejudice titles);
  - one mactables fix failed English exports of text holding braille characters;
  - another dropped five languages.

  Have fix rounds measure on real samples, and review them before or right after the merge.
- **Libraries' success codes are not proof.** liblouis reports success when its output fills on an escape, so check the room left.
  A check run shorter than the watchdog's poll proves nothing about a table's memory.
- **Strictness has a cost.**
  A strict up-front check can cost more than it saves: refusing every table that writes @ in eight dots would have cost 19 languages, while refusing each book by name loses nothing silently.
- **A pre-merge full suite** in the lead's worktree, run while the review runs, finds full-suite-only failures early.
  Run in a worktree, it skips three TranscriptionFixtureTests, whose TestData zips are untracked.
- **XcodeGen 2.45.3** orders copy-files phases differently on each run. merge-chain then regenerates and commits the project, which is harmless.
- **Pacing.**
  On October 20 the user, seeing their usage page on track, approved of the pacing and raised the day's line to 55% used.

**Lessons of October 18:**
- **The Opus review of a whole team branch paid for itself:** in each branch it found serious bugs that the team's own tests had passed.
- **Measure on real samples** where a fix changes what a listener hears.
- **Disk:** each team builds one worker at a time, a worker deletes its build folder after its last build, and a merge suite starts only with 3 GB free.
- **Messages:** a message sent with SendMessage reaches an agent at its next tool call; a question on the board can go unseen.

**Lessons of the October 16 and 17 Sonnet teams:**
- Sonnet leads did as well as Opus ones at these brief sizes.
- **Name the policy tests in a brief:**
  - a brief that adds an `@unchecked Sendable` type, a `nonisolated(unsafe)` variable, or a log tag names `UncheckedConcurrencyPolicyTests` and `LogContentPolicyTests`;
  - one that adds a shortcut action names the legacy scenarios and `KeyboardReachabilityTests`;
  - one that adds a field to `Book` names `ContentAnalysisMergeTests`.
- Workers build with `python3 Scripts/test/run-area.py`.
  A rebase conflict in `project.pbxproj` is settled by `make generate`, and new classes are placed in `Scripts/test/areas.conf` (`--unassigned`).
- Two conflicting team branches are merged in a scratch worktree, and main is fast-forwarded once green.
- Three teams that build, plus agents that do not, is the ceiling for the build slots.

## Where things stood on October 13, 2026

Main holds the record of the REV16 fixes, then, from the evening:
- the Ogg and Nothing Imported fix (9528b7a5, suite 6124 tests, 64 skipped, 0 failures, no Swift warnings), done by the orchestrator directly: a ZIP of Ogg tracks imports as one audiobook, and a ZIP import that brings nothing in says so in the library's alert;
- the documentation reorganized into docs/ (this file's older status sections are in `docs/agents/history.md`), with the audiobook manifest's full reference at `docs/user/audiobook-manifest.md`;
- FR15, FR16, and FR17 in the TODO, with the user's answers from `humanQuestions/2026-10-13.md`.
- the REV16 fixes' documentation pass (100db7a5).

- FR15, the manifest's tracks list, group headings, and pauses between tracks (e2ab40d9, October 14, suite 6192 tests, 64 skipped, 0 failures), by agent `manifesttracks`, with its documentation.

- FR17, Edit Manifest, the title and author kept in the manifest, the audio editor's fix, and Import Folder… (5d9caee3, October 14, suite 6221 tests, 67 skipped, 0 failures), by agent `editmanifest`, with its documentation.

- FR18, a manifest edited outside TextMouth taken as Edit Manifest takes a save, with a one-time pass keeping earlier hand edits (1744021a, October 14, suite 6230 tests, 67 skipped, 0 failures), by agent `outsideedits`, with its documentation.

- B07, the playback watchdog, memory guard, and sound effects off the main thread (d7f4f527, suite 6259 tests, 67 skipped, 0 failures), by agent `playbackwatch`; and B06, Ogg audio converted to AAC at import and once for the library (70a74208, suite 6284 tests, 64 skipped, 0 failures), by agent `oggtoaac`, after Apple's Vorbis decoder locked up in AVPlayer on October 14 and took the Mac down (see the TODO's B06 and B07).
  Never play Ogg through Apple's players in any test or experiment.

B08, rendered speech's crash when the audio output stops cycling, was fixed the same evening (32dc2036, suite 6293 tests, 67 skipped, 0 failures) by a Sonnet agent the orchestrator reviewed.
No agent is in flight.

**Pending:**
- the user's answers in `humanQuestions/2026-10-12.md` (13 small choices);
- the user's push and install.
  Main is far ahead of origin/main, and agents' worktrees start at origin/main.

The weekly window stood at 20% left; the user's floor is about 10%.

## Where things stood on October 7, 2026 (evening)

Main at the docs merge b165940c and its record, suite 4857 tests, 54 skipped, 0 failures, no Swift warnings (after the text-field keys merge; the documentation passes ran no suite).
The orchestrator ran on Opus 5.5 and every agent on Opus.
Merged that evening, each recorded in the TODO with its agent's notes in `AGENT-NOTES-2026-10-04.md` under "Agent notes, October 7, 2026 (evening)": the afternoon's documentation pass (5d6227cb), a feed's counts and its folder's row (9ae7becc), the reading list (01197eb1) and reading a book from it (9a61278d; FR09 done), four follow-ups (cb134bb1: #1290, #1291, #1308, #1296), the speech refusal follow-ups (6b78bd4c), ZIP import progress (f2b39d7f; FR10's first half), the keys a focused text field keeps (5b137a63; B03), the evening's documentation pass (b165940c), and two design notes, `research/FEED-ITEMS-RESEARCH-2026-10-07.md` (FR11) and `research/KEYBOARD-SHORTCUTS-RESEARCH-2026-10-07.md` (FR12).
Two read-only reviewers read every line of the afternoon's five merges first; the TODO's REV07 entry lists each finding and where it went.
Pending: the user's answers to the ten questions ending each design note (all recommended yes), then FR11's and FR12's builds in the branches the notes plan; the queued briefs `editbaselines.md` and `finishedbook.md` in `Scripts/agents/briefs/2026-10-07/`; an unbriefed bundle of REV07's Speak Info items and cleanups; B04 (the user's Shift-Command-B on two actions; a config.json workaround awaits the user's yes) and the Shift-Command-T clash (#1451); FR10's feed-download half after FR11's second branch.
The merge chain's one red run that evening was a test host that received an ordinary quit while it was the frontmost app (no crash); xcodebuild restarted the rest and the interrupted class passed alone, which is how such a run is settled.
The installed app was still the October 5 build until the user pushes and installs.

**Later that night.**
The user answered every question in `humanQuestions/2026-10-07-evening.md`, and a second batch merged: the editor save baselines (afde34e4), a finished book's controls (377edc97; its merge chain's suite failed four tests under another suite's load, each passing alone or on a quiet Mac), and FR12's branch A, the record of the shortcuts the user edited (094dd885, which ends B04); main's suite counts 4943 tests, 70 skipped, 0 failures.
FR11's design addendum (`research/FEED-ITEMS-ADDENDUM-2026-10-07.md`, 7c78d8af) measured and recommends the user's layout, a package per feed item in a folder of the feed's own with the feed's own index; its six questions wait in `humanQuestions/2026-10-07-late.md`.
Work stopped there at 30 percent of the weekly all-models window left, the user's line.
Next: those answers, then FR11's five branches; FR12's branches B, C, D, and E; B05; a documentation pass for the second batch (the wording is in the agent notes); the `FeedUIAddFeedTests` stray-save leak; FR10's feed half after FR11's choice branch.

## Where things stood on October 7, 2026

Main at 1059a8ed, suite 4687 tests, 56 skipped, 0 failures.
Merged that day: the EPUB author reading and the versioned metadata refresh (3d52c08b), the Unopened category (1790ae21), hand-edited metadata flags (065ec6a0), the speech markup guard (aec5c91b), the AirPods rewind after a finished book (f5273ba2), and Speak Info (33219144), each recorded in the TODO with its FR or B entry ticked.
Pending for the next session: the documentation pass for those five afternoon branches (every README and ARCHITECTURE sentence is in `AGENT-NOTES-2026-10-04.md` under "Agent notes, October 7, 2026"); the reading list, FR09, from `Scripts/agents/briefs/2026-10-07/readinglist-core.md` and then a reader branch; the FR03 follow-ups and FR10 in the TODO's October 7 section; the small follow-ups #1290 (ReaderView passes `handEdits:`), #1291 (an import sets `.noneSinceImport`), #1308 (the reader takes `onSpeechRefused`).
The usage stop of October 7: the weekly Fable window reached 10% because the task agents ran on Fable; the rule above fixes that.
The installed app was still the October 5 build (fe84085b) until the user pushed and installed.

## Where things stood on October 4, 2026

Main held, all with green suites: the cloud data directory (FR02), the performance work (PERF01 to PERF33), Swift 6, the smaller app and its size guard, recording and the audio editor (FR04), transcription with its cleanup command (FR05), the feed reader (FR03), Export and Edit Text, and the AirPods fix.
The evening's four polish branches are on main too, each merged after a green suite on the merged tree: `fix/reader-polish-october-4` (6308e97b), `fix/audio-editor-polish` (5a9176df), and the two that were in flight when the weekly budget ran out, `feature/feed-search-and-polish` (eeb8a0b5: podcast search, JSON Feed, resume data at quit, video re-import, failures reported, Stats by kind) and `feature/recording-polish-and-mp3` (b5a6dd75: recovered takes, quit asks, readers pause, exported originals, LAME MP3 as a vendored C target), after which the suite on main counted 4535 tests, 50 skipped, 0 failures.
No feature branch is in flight; `docs/october-4-wave-4` describes the four in README.md and ARCHITECTURE.md.
The user's open decisions: P07 (the end-of-book position), P08 (the audiobook jump time convention), and merging what two Macs wrote.

## The stories behind the rules

The date, the incident, and the user's words behind a rule that AGENTS.md or CLAUDE.md now states without them.

- **The message board:** It was used for every task since October 2: well over a thousand messages by October 4.
- **Pushing main and its tags:** Since November 14, 2026 the orchestrator pushes main and its version tags to GitHub, and only at a version bump it judges a fairly stable release.
  The user: "You have permission to push to main and tags I say when you increment the release number to a fairly stable release".
  The project CLAUDE.md carried the same authorization, dated November 14, 2026.
- **The workflow guard:** Once main held `test-build.yml` (since that first push, 0.4.10), `github_run.py`'s workflow guard was on.
- **No iPhone simulator on this Mac:** The user also allowed deleting the iPhone simulator runtime once the iPhone tests ran wholly on GitHub; it was deleted on November 14, 2026 (7.5 GB).
- **The usage override:** The user set the override as standing for the night before the weekly reset (Saturdays at 8:00 a.m. Eastern).
  On October 10, 2026 they said: "please don't warry about the weekly reset and have a full set of agents going and work until the limit runs out, everything can just be resumed without issue in the new week...
  and remember this for Friday nights / Saturday mornings before the usage resets".
  On such a night the orchestrator kept three builders and the non-building agents going until the limit ran out.
- **Branching from local main:** An agent's worktree (`isolation: "worktree"`) starts at origin/main, which can be far behind local main (1,081 commits on October 12, 2026).
  So every brief has its agent make its branch from local main or a team branch, by name.
- **Builds through the wrapper, before the build train:** Task agents built and tested only through `.claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh`, one build of their own at a time, with a build folder of their own outside the repository.
  The command:
  `xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-<slug>"`.
  `-jobs 4` holds a clean build's peak memory to about 1.9 GB, against 2.6 GB at Xcode's default of eight jobs, for 13 seconds more (69 to 82 seconds, measured October 12, 2026; compiling is about a minute of a full run, the tests about eleven).
  The wrapper holds one of three machine-wide slots (the Mac has 8 GB of memory) under `/tmp/textmouth-build-slots` (or `BUILD_SLOT_ROOT`).
  While iterating an agent added `-only-testing:TextMouthProductionTests/<Class>`, several classes per run; a full run compiled the app and took seven to eight minutes.
  Hosted tests run inside the real app against a sandbox under the temporary directory and never join the system's media session.
  Before reporting, an agent deleted its build folder after unregistering its app.
  The build train replaced all of this on October 31, 2026, and trains moved to GitHub Actions on November 9, 2026.
- **The commit trailer:** Each commit message ended `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`, or the attribution the session's own instructions gave.
- **Notices before a full suite:** An agent posted a `build` notice on the board before a full suite, while agents built on their own; trains made the notice unnecessary.
- **The shared scratchpad:** On October 9, 2026 one agent's commit-message files were overwritten by another's after use.
- **The live board:** A changed copy of `bbs.py` ran against the live board on October 12, 2026, which created the new tables early (harmlessly).
- **A permission prompt on `rm`:** Claude Code asks before an `rm` through a shell variable.
  On October 18, 2026 a team lead's `rm -f "$D/$out"` in a throwaway test loop waited five hours while its team stood still.
  Every `rm`, in a brief or the orchestrator's own commands, takes literal paths.
- **A revert:** Reverting a commit also takes away the helpers it added: on October 31, 2026 a revert removed the test helper `onWorkerSizedStack`, which other tests used, and the next build failed.
- **The hosted view that chased its width:** A macOS form in the columns style made its window chase it until AppKit raised "more Update Constraints in Window passes than there are views in the window".
  The test host ended with a crash dialog the user saw, twice on October 10, 2026.
- **The AirPods:** A test host that joined the system's media session took the user's AirPods.
  It never does now, but a branch older than that fix still can until it rebases.
- **The braille rule claim:** A reviewer said UEB writes 6-N and 6-Y, and the user, a braille reader, knew UEB had dropped ation and ally (BANA's UEB FAQ).
  It was November 13, 2026.
- **`SIGN_APP=true`:** Two agents' `make check` runs held the heavy lock for an hour each, waiting on the login keychain (November 14, 2026).
- **Times from `date`:** The orchestrator's log ran up to 5.5 hours ahead of the clock and told the user the reset was near when it was five hours away (November 14, 2026).
- **The 20-agent limit:** On October 30, 2026 two leads built most of their tasks themselves because they could not launch workers.
- **A spent usage window:** On October 31, 2026 the 5-hour window reset at 03:20 and every agent stood still until 12:06.
- **The Executed line:** Main was fast-forwarded once on the Executed line of a run with "1 failure (0 unexpected)" and taken back within a minute.
- **Disk under 8 GB:** The disk reached 2.7 GB free during measurements on November 14, 2026.
- **Where things stand, written on November 14, 2026.** Main was at 0.4.10, with `v0.4.9` at 8918f4ee and `v0.4.8` at 82e68c0d, all three tags unpushed (main itself was pushed that day), and the user still ran 0.4.2.
  The Release app was 18.3 MB (18,291,664 bytes; 0.4.9 was 19.6 MB).
  The BRF fixes from the user's Life of Pi: running heads left out (keyed without their numbers), print page change lines, chapter rows as headings, title and author from the braille title page, and the English Braille, American Edition suggestion announced once.
  All 13 "St."/"Still." places in Life of Pi read as its EPUB does (checked by the orchestrator, read-only).
  The Reading List's cloud follow-ups: unknown sizes one at a time, books left out logged.
  The braille code guess at import (the Braille tab's switch, Keep This Code) was kept through Replace Existing.
  Every merge went review, then a fix round, then often a check, then a Mac full suite on `integrate/1113`, then a fast-forward.
- **The lessons of that night (November 14, 2026), which hold for any campaign.** A reviewer said UEB writes 6-N and 6-Y; two agents' `make check` runs held the heavy lock for an hour each without `SIGN_APP=true`; main was fast-forwarded once on the Executed line and taken back within a minute.
  A branch that adds a test file must commit the regenerated project, since trains regenerate it and never notice when it's missing.
  The orchestrator's log ran up to 5.5 hours ahead of the clock and told the user the reset was near when it was five hours away.
  The disk reached 2.7 GB free during measurements.
- **CLAUDE.md's merge and push authorization:** the orchestrator's push of main and its version tags at a version bump it judges a fairly stable release has been in CLAUDE.md since November 14, 2026.
  The merge authorization (`git merge --no-ff` after a green full suite, each merge recorded in the TODO) is older.
  The parenthetical also said "task agents never push except to `TestBuild` through the train tools, and installing stays the user's", and pointed to "The user's standing rules" in AGENTS.md.
- **CLAUDE.md's Start here:** it listed the project's documents (writing-docs.md, README.md, ARCHITECTURE.md, the TODO, AGENT-NOTES, `research/`), the message board with its build wrapper `build-slot-with-bbs.sh`, `merge-chain.sh` and `extract-report.py`.
  It also gave the `*.md` gitignore rule and the `humanQuestions/` rule.
  AGENTS.md's Start here holds them now, and the orchestrator's tools are in orchestrator.md.

## From Imports: audio

- Package track scans: the formats a package's scans leave out (the page's coreAudioExtensions) are the formats added on October 18, 2026.

## From Imports: braille tables and the translator

- The helper's protocol 2 (header line, emphasis codes) came on October 21, 2026.
- The reading passes (read_braille through the pass of the code the table writes its emphasis in) came on October 24, 2026.
- Review E1 of October 21, 2026 found that read_ueb's liblouis read the cells just before a terminator as if they could not end a word.
- The EBAE fix pass (`fix_ebae_cells`) came on November 13, 2026, after the user's Life of Pi BRF showed what contracted EBAE's table misreads.
- The measurement in the comment above the guess's constants was made on November 14, 2026.
- BrailleEbaeFixesTests was new with the EBAE fix pass.
- BrailleEmphasisReadingTests changed its seeded BANA test to treat µ and m alike and to leave out the sentences liblouis alone misreads with "±", and its symbol sentences no longer glue µ to a letter.

## From Imports: braille files

- The three rules of layout (running heads, print-page change lines, chapter rows) came on November 13, 2026, with the user's Life of Pi BRF, a 2003 Australian EBAE transcription.
- BrailleTitlePage (a BRF's title and author from its title page) came on November 13, 2026.
- The braille page reader's version "1.1.0" dates from November 13, 2026 and shipped in 0.4.8; "1.1.1" dates from November 14, 2026.

## From Imports: DAISY 3 books

- DAISY 3 books of several DTBook files, and SMIL clocks, came on November 13, 2026.
- DAISYParser.parseTime: "500ms" used to read as no time.

## From Imports: duplicates

- The unanswered-duplicate marker (DuplicateQuestionMarker) came on October 31, 2026.
- Answering off the main actor (answerImportDecisionOffMain, replaceExistingOffMain) came on November 13, 2026.

## From Imports: Kindle books

- Kindle KFX books (FMT52) came on November 5 and 6, 2026.
- Kindle MOBI 6 books (FMT42) came on November 4, 2026.
- KF8 (FMT48) came on November 8, 2026.
- The continuation rule's measurement on the real books (the last chapters and licences of Pride and Prejudice, Moby Dick, and The Yellow Wallpaper) was made on November 9, 2026.

## From Imports: DOCX, OpenDocument, and Word 2003 XML

- The own readers of OpenDocument text and Word 2003 XML (FMT27 and FMT53) came on November 5 and 6, 2026.

## From Imports: rich text and Word documents

- The own readers of rich text, Word 97-2003, OpenDocument text, and Word 2003 XML (FMT47, FMT27, FMT53) came from November 4 to 6, 2026.

## From Imports: choosing the encoding

- The measurement of Foundation's readers of several encodings, on macOS 26.3, was made on October 24, 2026.

## From Imports: text in other encodings

- CP437, CP850, and Mac Central European joined the catalog on November 13, 2026.

## From Imports: documents textutil reads

- V03, which keeps a row this TextMouth cannot read as it was read, dates from October 23, 2026.
- ImportedBook.originalKeptNotice was named rtfdOriginalKeptNotice until October 31, 2026.
- docx (with .dotx, .docm, and .dotm) joined formatsRefusedWhenBlank on November 13, 2026.

## From Imports

- The announcement rule for a ZIP batch that found no new book (the library's alert instead) dates from October 13, 2026.
- Packages and originals (isBookPackage, the package handling of importFiles and importZip) dates from October 31, 2026.
- Limits of what a file claims (EPUBParser.readingXML, withNCX) dates from October 31, 2026.
- The Word documents joined formatsRefusedWhenBlank on November 13, 2026.
