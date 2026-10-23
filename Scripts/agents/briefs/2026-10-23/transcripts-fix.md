# Brief: the transcripts review's fixes (October 23, 2026)

You are `transcripts-fix`, a Sonnet agent, working on `team/transcripts` itself (4b6d67b1). TextMouth is a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display.

## Why
A fresh Opus review of team/transcripts judged it safe to install, but asked for two cheap fixes first, plus several small ones. Its whole report is `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/review-transcripts-report.md`: read it first. The team's report is `transcripts-lead-report.md` beside it.

## Fix these, each a small commit with its test
1. **Review item 1.** Retranscribing a book whose content.md is only in iCloud throws away the finished transcription, because install refuses afterwards (`TranscriptInstallation.swift:84`, with `TranscriptionSheetModel.swift:287`). Check content.md, and transcript.json, before transcribing begins: the sheet then says the book must be downloaded first, and Retranscribe is unavailable. Pin the sentence. Reuse the existing failure sentence, "The book's text is only in iCloud, so TextMouth leaves it as it is. Download the book, then try again.", or one in its style.
2. **Review item 2.** The loader's rewrite of content.md (`TranscriptTextLoader.swift:220`, with `TranscriptEdit.swift:104`) never tells a running Edit Text session, so the 1.1.0 rewrite is taken as the user's edit: "Text updated" is spoken, and the transcript is marked edited. Have the rewrite reset the session's baseline, as text books do through `textRebuilt`. Test it with a session open on a transcribed book whose text is rewritten: no edit is taken, and nothing is spoken.
3. **Review item 5.** Command-F on a transcribed book whose text is not shown says "Transcribe it first, with Transcribe Audio." Say instead why its text is not shown (only in iCloud, stale, or held by a refused edit), using the wording that already exists for each case where it can. Never name a command the book does not offer.
4. **Review item 6** (`MarkdownLiteral.swift:136`). `<` is escaped only before an ASCII letter, `/`, `!`, or `?`, so an email autolink such as `<12345@example.com>` or `<+44@x.co>` loses its brackets. In the minimal form, escape `<` wherever it could open an autolink or HTML: simplest, always. Test it through swift-markdown.
5. **Review item 7** (`MarkdownExportWriter.swift:276`). A plain run ending in `!` directly before a link is written as `Wow![here](<…>)`, which is an image. Escape that `!`, and test it.
6. **Review item 8** (`MarkdownLiteral.swift:218`, `guardingLineStart`). A line that is just `:-`, `-:`, or `:-:` (a table delimiter row) after a hard break turns the paragraph into a table. Guard such a line, and test it.
7. **Review item 9.** `TranscriptSearchTests.swift:106-108` and `:336-338` index right after an `XCTAssertEqual` on the count. Guard them, so a regression fails instead of crashing the run.

Leave review items 3 (a half-written install) and 4 (a feed episode's re-download with different audio) as follow-ups in your report.

## Rules
- **Setup.** Your worktree is made from main. Run `git checkout team/transcripts`, which no other worktree holds. Register on the board as `transcripts-fix`, and build only through the wrapper (`run-area.py`).
- **Commits.** Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Comment the code as the surrounding code is commented.
- **Tests:** no traps, no sounds, no `~/.TextMouth`, no `UserDefaults.standard`, and never the real speech model.
- **Disk.** It is shared with team stable020: check for 4 GB free before your build, and delete your build folder after, unregistering its app first with `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <folder>/Build/Products/Debug/TextMouth.app`.
- **Paths.** Use literal paths in every `rm`.
- **Budget.** The user set tonight's line at 5% of the week left, so the usage rule's "low" status does not stop you. Use no subagents.
- **At the end,** in one `run-area.py` invocation, run the classes you touched, plus `TranscriptTextTests`, `MarkdownExportWriterTests`, `TranscriptSearchTests`, `BookTextEditTests`, and the transcription and export areas. Also run `make lint-tests LINT_BASE=main`.
- **Never** push or merge into main.

## The report (at most 15 lines)
- Each commit.
- The exact counts and the lint result.
- Any new words a listener hears.
