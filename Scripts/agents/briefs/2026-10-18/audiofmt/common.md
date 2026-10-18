# Team audiofmt: what every worker's brief shares (October 18, 2026)

Your lead is `audiofmt-lead`; the team branch is `team/audiofmt`. Read "The worker's part" and "Rules for everyone" in `Scripts/agents/briefs/2026-10-18/teams-common.md` (only those two sections and "Builds"), then your own brief. Read the code your brief names by line range; read nothing else unless you must.

## The October 14 rule (absolute)
On October 14, 2026, Apple's Vorbis decoder locked up inside AVPlayer, TextMouth reached 34 GB of memory, and the Mac had to be reset. Since then:
- **No source file of a format the import converts is opened by Apple's audio frameworks inside TextMouth's process**: no AVPlayer, AVPlayerItem, AVAudioPlayer, AVAudioFile, AVURLAsset, AVAssetReader, AudioFile, or ExtAudioFile, and no playability check. Such a file is read only by `/usr/bin/afconvert` or `/usr/bin/afinfo` in a child process under `WatchedProcess`, or by hand-written byte readers (`OggHeaderReader`).
- Only the converted file (AAC or Apple Lossless in .m4a) is probed (`AudioMediaProbe`) and played.
- **No test plays sound** or records from a microphone. Tests convert and probe tones in their own temporary folders. A hang or a failure is tested with a stand-in tool (`/bin/sleep`, `/bin/sh -c "exit 3"`), as `OggAfconvertTests` does.
- Never run an experiment beside a hung TextMouth. In a shell, `afinfo` and `afconvert` on the samples are fine.

## Samples
`TestData/format-samples/<folder>/` (listed in `samples.tsv`) and `TestData/audio/` hold tones, never speech. A test copies a sample into its own temporary folder before it uses it, and never changes the samples' folders.

## Building and testing
- Run your test classes, and only those, in ONE run, in the background: `BBS_AGENT=<slug> python3 Scripts/test/run-area.py <Class> <Class> ...` from your worktree root. It queues for a build slot (that wait is normal) and prints only the result. Wait for its notification; never poll in a sleep loop.
- A new test file needs `/opt/homebrew/bin/xcodegen generate`, with the regenerated `TextMouth.xcodeproj/project.pbxproj` in the same commit. So does a renamed or new app file.
- Before you report: `make lint-tests LINT_BASE=team/audiofmt` and `make lint-ogg LINT_BASE=team/audiofmt`, both clean (a hit you reviewed is excused with `// lint-ok: <reason>` on its line). A change adds no Swift warning.
- **Removing files.** Never `rm` through a shell variable: Claude Code then stops for the user's approval. Remove your build folder with `BBS_AGENT=<slug> python3 Scripts/test/run-area.py --clean`, and write any other `rm` with its literal path.
- The Mac's `sed` is GNU sed: use `gsed -i` or Python for in-place edits. Never put two heredocs on one command line. Use `git -C <path>` rather than `cd … &&`.

## Commits
One logical change per commit, with its tests. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Fold the board into it: `git commit -F <file> && python3 .claude/skills/agent-bbs/scripts/bbs.py post <slug> --tag commit --topic "$(git log -1 --format='%h %s')"`.

## Words a listener hears
The user is a VoiceOver and braille user. Every sentence the app shows or speaks is plain, complete, and pinned by a test, with file names in curly quotes as the existing messages have them.

## Stay in your lane
Edit no `*.md` file and no file your brief does not name. For a problem elsewhere, post a finding: `python3 .claude/skills/agent-bbs/scripts/bbs.py post <slug> --tag finding --file <path> --topic "..."`. A failing existing test means stop and ask your lead (`--to audiofmt-lead`); never edit or weaken an existing test unless your brief says that test's expectation changes.
