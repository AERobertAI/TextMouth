# An audit of TextMouth's size, memory, and processing (November 13, 2026)

You are `optaudit`, a Fable auditor, at the user's own request. You change no code on any branch that will be merged. First read `common.md` beside this brief and follow it, except that you make no feature branch: make throwaway branches `audit/<name>` from local main for measurements (never merged, never pushed).

## The user's words

On November 13, 2026:

> "at some point I would like a Fable agent if possible to go through and do an audate to find optimization points for the app again in reducing app size (its fine right now but I would like it if we could get it under 20 mb again or even 15 mb without loosing anything) and run time playing memory and processing ineffencentcies in the code, a bigger model like Fabel I think could find more of these."

"Without losing anything" is the rule: no feature, format, voice, table, or behavior may go, and nothing the user hears or VoiceOver reads may change.

## What is known

- **November 9's measurement** (`build/orchestrator/macsize/macsize-report.md`, with its link map `base-TextMouth.map` beside it): the Release executable is 22,737,216 bytes, `__TEXT` 21.07 MB, code (`__text`) 18.86 MB. The largest objects are SwiftSoup 2.98 MB (13%), swift-markdown 0.62 MB, LibraryView 0.36 MB, FileImportService 0.27 MB, LibraryViewModel+Migration 0.25 MB, AddFeedSheet 0.23 MB, BookTextEditing 0.22 MB, DiagnosticLog 0.22 MB, ZIPFoundation 0.19 MB. The `Phone/` folder adds 59 KB. The braille helper is 186 KB. `make check` holds the app under 25 MB. Main has grown since; measure it again.
- The playback path is described in `docs/architecture/reading-a-book.md` and `docs/architecture/state/media-playback.md`; the reader in `docs/architecture/state/reader.md`. `TextMouth/Views/ViewBodyCounter.swift` counts SwiftUI body evaluations for tests. `docs/developer/testing.md` describes the performance baselines.

## What you may run

- **Release builds of variants**, each through the lock: `python3 -I /Users/roberteggleston/programming/ai/claude/swift/TextMouth/Scripts/agents/run_locked.py optaudit <command>`, with a build folder of your own under `build/orchestrator/optaudit/` (pass `-derivedDataPath`; `LD_GENERATE_MAP_FILE=YES` gives a link map, and `LD_MAP_FILE_PATH` must not be set, since every target's link shares it). Before you report, unregister each app you built: `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <its path>`. Never `make install`. One build at a time; about 14 GB of disk is free, so check `df -h /` before each build and stop building under 6 GB.
- **Hosted tests** of your own, on a throwaway branch, only through the build train or a GitHub run of your own tree, never with sound (no test plays aloud).
- **Never** run TextMouth against the user's library, play anything aloud, or attach a profiler to the user's own TextMouth.

## Part A: size

For each candidate, build it and give the measured bytes saved (executable and bundle), what it could change in behavior, and how a test would prove it changes nothing. At least:
- the optimization level: `-Osize` for the app and for each package, against `-O`;
- link-time optimization, and whatever the Swift toolchain in this Xcode offers for whole-module and cross-module optimization;
- dead stripping, stripping of symbols and Swift's own metadata (`STRIP_STYLE`, `STRIP_SWIFT_SYMBOLS`, `DEPLOYMENT_POSTPROCESSING`), and what Release already does;
- `SWIFT_REFLECTION_METADATA_LEVEL`: find every reliance on reflection before you count it as safe (an enum's case name in a log, a stored key, or a test, through `String(describing:)`, `"\(value)"`, `Mirror`, or `dump`), since one change would alter what is saved or logged;
- what makes the largest of TextMouth's own objects large (generic specialization, SwiftUI view bodies, string tables, inlined code), and what would shrink each without changing it;
- SwiftSoup: everything TextMouth uses it for, what macOS's own `libxml2` HTML parser or `XMLParser` would need to replace it with the same output, the bytes saved, and the risk (every reader's output is pinned by golden tests: name them);
- the bundle's resources: assets, sounds, braille tables, the helper.

## Part B: memory and processing while a book plays

Read the playback path end to end, for a text book (speech, direct and rendered) and an audiobook, with the reader window open and with it closed, and with VoiceOver's announcements. Find, with evidence (file and line), an estimate of the cost, and how to measure it:
- **memory:** what a playing reader holds and how often it is copied (the chapters as `Substring`s of the cache, speech text, rendered audio buffers, highlight ranges, images, caches that never shrink);
- **processing:** the reader's refresh (it runs as often as every 0.12 s), SwiftUI body evaluations per word or per refresh, Combine publishers that fire for every position update, string work done again for each update, logging that builds strings no one reads, JSON saves while playing, timers that keep running in a paused or closed window, and work on the main actor that could leave it;
- **energy:** wake-ups per second while playing and while paused.

Where a hosted measurement settles a guess (body counts per minute of playback with sound off, allocations during a chapter's preparation), describe the test that would show it, and run it if you can do so within these rules.

## Part C: the fixes, ranked

The heart of the report: the 15 to 25 changes worth making, best first, each ready to be a Sonnet worker's brief: the files and line ranges, the mechanism of the fix, the measured or estimated gain, the risk, the tests that must pass and the new test that pins the gain, and which fixes touch the same files. Mark which need the user's yes (for instance replacing SwiftSoup), and which can go ahead today.

## Your report

Write the full audit to `build/orchestrator/optaudit/audit-report.md` (as long as it needs). Your final message is its summary, 60 lines at most: the size measured today; each Part A candidate's measured saving; the top ten Part B and Part C findings; the disk you added; what you couldn't measure. Save the summary also as `build/orchestrator/nov13/optaudit-report.md`.
