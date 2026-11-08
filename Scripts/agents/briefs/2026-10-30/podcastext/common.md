# Team `podcastext`: what every worker does (October 30, 2026)

You are a worker of team `podcastext` (lead: `podcastext-lead`, channel `team:podcastext`). Read, in this order and nothing else unless your brief sends you there:
1. `Scripts/agents/briefs/2026-10-30/teams-common.md`, the sections "The worker's part", "Rules for everyone", "The board", "Builds", and "Lessons every brief applies". This page overrides it where they differ.
2. Your own brief, beside this page.
3. `TextMouth/Models/TimedText.swift` (the team's shared cue model, written by the lead; about 230 lines): never change it without asking the lead on the board first.

## The feature, in two sentences
FMT23 gives an audiobook a transcript from a WebVTT (.vtt) or SubRip (.srt) file instead of transcribing it, on any macOS, and exports a transcript in either format. FMT25 fetches a podcast episode's own transcript and chapters (Podcasting 2.0) beside its download, so a downloaded episode has text and headings at once.

## Settled for the whole team
- A transcript from outside replaces nothing silently. It is kept in the one transcript store (`transcript.json`, `TranscriptStore`) as recognition's transcripts are, and records where it came from (task `store` adds `TranscriptSource`).
- Third-party text is data: every size and count read from a file is bounded (`TimedTextLimits`), no link in it is followed, and nothing that does not parse is used. No log line ever holds a transcript's words or a full address (a host alone, as `FeedHost.of` gives it).
- A transcript or chapters file running more than 5 seconds past the end of its audio is refused (`TimedTextLimits.pastTheEndMarginMilliseconds`).

## Building and testing: one build folder, one build at a time
The team keeps ONE build folder, shared by every worker in turn, and at most one of its builds runs at a time. So every build or test run of yours goes through the team's lock, with the team's folder, like this (one command, started in the background with `run_in_background: true`; you are told when it ends; never poll it more than every 4 minutes, and never in a sleep loop):

    bash /Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/oct30/podcastext-build.sh <your slug> <TestClass> <TestClass> ...

That script (read it: 70 lines) takes the team's lock (`/tmp/textmouth-podcastext-build.lock`), checks the disk, runs `Scripts/test/run-area.py` with the team's folder (`/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-podcastext`), and then, still holding the lock, deletes the folder (Launch Services first, through `run-area.py --clean`) unless another podcastext build is already waiting for it. Since 19:45 (the orchestrator's disk rule) it replaces the `lockf ... run-area.py` command this page gave first; a build already waiting with that command may finish as it is.

- Waiting for the lock, then for a build slot, is normal. The first build in the folder after another worker's is a full build of your worktree: about 10 minutes.
- `run-area.py` prints the result lines and the log's path (its log is `/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-area-<your slug>.log`). A change must add no Swift warning: it prints a WARNING line for each.
- **Never delete the team's build folder yourself, and never pass `--clean`:** the script does it under the lock, where no other podcastext build can be using it. You have no build folder of your own to remove.
- **Disk (the orchestrator's rule, 19:41, eased at 23:13):** the script refuses to build (exit status 3, a line beginning `DISK:`) with less than 3 GB available while the team's folder exists, or 4 GB when it must make it (the orchestrator's rule of 23:13). Then post to `podcastext-lead` and wait with `python3 .claude/skills/agent-bbs/scripts/bbs.py watch <slug> --timeout 600`, and run the script again. Only two builds run at once on this Mac now: waiting for a slot is normal.
- Run only the test classes your brief names, never the whole suite (the lead runs it).
- A new source or test file needs `/opt/homebrew/bin/xcodegen generate`, and `TextMouth.xcodeproj/project.pbxproj` committed with the change. xcodegen may swap the destinations of the two "Licenses" copy phases in that file; that is harmless.
- Before you report, run `make lint-tests LINT_BASE=team/podcastext` (and `make lint-a11y LINT_BASE=team/podcastext` if you added a control, `make lint-ogg LINT_BASE=team/podcastext` if you added a call that opens audio). Fix what they report in your lines.
- Every `rm` names a literal path, never a shell variable (`rm -rf "$X"` waits for the user's approval for hours).

## Commits
- Small and focused; each with its tests. Each message ends with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` (tonight's workers run on Opus, so this replaces the Sonnet line in teams-common.md).
- Fold the board into your commit: `git commit -F <file> && python3 .claude/skills/agent-bbs/scripts/bbs.py post <slug> --tag commit --topic "$(git log -1 --format='%h %s')"`.

## Tests
- New test classes go in `TextMouthProductionTests/`, one class per file, `@MainActor final class ...: XCTestCase` where the code under test is on the main actor (plain `final class` otherwise), with a comment on the class and every test.
- No test may trap: no force unwrap, no unguarded subscript (`XCTUnwrap`, `first`, `indices.contains`), no over-fulfilled expectation. No test plays sound, records, or touches `~/.TextMouth`.
- A test that uses a file of `TestData/format-samples/` copies it first: `try copyOfFormatSample("vtt/tone4.vtt")` (`TextMouthProductionTests/FormatSampleFixtures.swift`).
- Audiobooks for tests: `let world = try makeIntegrationWorld("Label")`, then `try world.makeSilentAudioBook(title:trackDurations:)` (tracks "01.wav", "02.wav" in a "Tracks" folder) or `try world.makeSilentAudioFileBook(title:duration:)` (one file) (`TextMouthProductionTests/IntegrationTestSupport.swift:150-260`). Transcripts: `TranscriptFixtures` (`TextMouthProductionTests/TranscriptTestSupport.swift:7-122`), whose `transcript(of:sentences:)` fingerprints a book's real files.
- Wording a listener hears is pinned by a test, exactly.
- A failing existing test means stop and ask your lead (teams-common.md, worker's part, item 6).

## The board
`bbs` means `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree's root.
- Register, joining the team: `bbs register <slug> --role "ONE LINE" --branch <branch> --team podcastext --files <the files your brief lets you edit>`.
- Your lead made a task for you; move it as you go: `bbs task move <slug> <id> working`, then `review` when you report. `bbs tasks --team podcastext` lists them with their ids.
- Ask your lead with `bbs post <slug> --to podcastext-lead --topic "..."` and wait with `bbs watch <slug> --timeout 240`.
- Finish: `bbs post <slug> --to podcastext-lead --topic "done: <branch>"`, then `bbs release <slug> --all`.
