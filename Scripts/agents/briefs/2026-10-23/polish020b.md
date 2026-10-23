# Brief: two more safety fixes (October 23, 2026)

You are `polish020b`, an Opus agent, on the branch `fix/polish020b`. TextMouth is a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display. The user will install 0.2.1 as their stable version, and main has passed its release check (8460 tests, 0 failures). So each change here must be small, safe, and tested.

## Fix these, each a small commit with its test
1. **Abandoned audio reads must not pile up.** The context: stable020's ST07 gave `AsyncBridge` waits a time limit, but cannot stop AVFoundation work that ignores cancellation. On October 14 a hung Apple decoder grew TextMouth to 34 GB, and the Mac had to be reset. So a file that hangs AVFoundation, opened again or met again by a launch check, could start more stuck reads, each still running. The reviews' reports, `review-stable020-report.md`, finding 4, are in `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/`.
   - Fix: when a read of a file passes its limit, remember that file for the session, by its path, size, and modification date. Refuse every later AVFoundation read of it at once, with a sentence a listener understands, in the style of the existing limit message ("Reading the audio took longer than 5 minutes, so TextMouth stopped waiting for it."). For example: "TextMouth stopped reading this audio earlier because it took too long, and won't try again until TextMouth is opened again."
   - Keep it in one place (DRY), next to `AsyncBridge`'s limits.
   - Test it with a stand-in read that never returns: the second read is refused at once, and no second read starts.
2. **A transcript and its text must never disagree after a failed write.** Install writes transcript.json before the text, so if writing the text or the content analysis then fails, transcript.json is already replaced (`TranscriptInstallation.swift:94`, `BookTextEditor.swift:168-177`). A Clean Up whose copy fails then says "Couldn't clean up…", yet its transcript.json is already cleaned. These are the review's item 3 and the docs agent's note, in `review-transcripts-report.md` and the transcripts reports in the same folder.
   - Fix: write the new transcript.json only once the text is written, or put the old one back when a later step fails. Choose whichever keeps the code simplest, and say why in a comment.
   - Test each failing step: the transcript, the text, and the edit session's baseline all stay as they were.

## Rules
- **Setup.** Your worktree is made from main. Run `git checkout -b fix/polish020b main`. Register on the board as `polish020b`, and build only through the wrapper (`run-area.py`).
- **Commits.** Each message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Comment the code as the surrounding code is commented.
- **Tests:** no traps, no sounds, no `~/.TextMouth`, no `UserDefaults.standard`, never the real speech model, and never a real Ogg decode.
- **Disk.** Check for 4 GB free before a build, and delete your build folder at the end, unregistering its app first with `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <folder>/Build/Products/Debug/TextMouth.app`.
- **Paths.** Use literal paths in every `rm`.
- **Budget.** The user set Friday's line at 5% of the week left, so the usage rule's "low" status does not stop you. Use no subagents, and keep it lean.
- **At the end,** in one `run-area.py` invocation, run every class you touched, plus the transcription area, the `AsyncBridge` and audio-analysis classes, `BookTextEditTests`, and `TranscriptTextTests`. Also run `make lint-tests LINT_BASE=main`.
- **Never** push or merge into main.

## The report (at most 15 lines)
- Each commit.
- The exact counts and the lint result.
- Any new words a listener hears.
