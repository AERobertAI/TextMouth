# Brief: the last small fixes before the install (October 23, 2026)

You are `polish020`, an Opus agent, on the branch `fix/polish020`. TextMouth is a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display. The user will install the result as their stable version.

## Fix these, each a small commit with its test
They come from the outside review of team stable020: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/review-stable020-report.md`. Read it first.
1. **Finding 2, a DAISY heading lost.** DAISY 2.02 can now drop a heading such as "IV", "XII.", "I", "1984", or "1, 2, 3." under a page label like "5": `looksLikeAPageNumber` (`MarkdownPageMarker.swift:114`) and the "label contains text" check (`:103`), with `DAISYParser.swift:793` marking it read.
   - Narrow the rule, so that a fragment is dropped only when it is the page's own label: the same text as the label, ignoring case, spaces, and a trailing period, or the label's Roman or Arabic twin ("V" for "5", "5" for "V").
   - Apply the same narrowing to EPUB page-break elements, where "Mix" or "Civil" now read as Roman numerals.
   - Test each example above, both ways.
2. **Finding 1, Delete Folder and kept rows.** Delete Folder's Delete Everything sends the packages of kept rows (books a later TextMouth added, kept by V03) to the Trash, or deletes them with Trash off, while its question counts only shown books (`LibraryViewModel+FolderManagement.swift:148, 164`).
   - Leave a kept row's package where it is, and keep the folder if anything remains in it.
   - Say so in the question, in a sentence pinned by a test, for example: "It also holds N books a newer TextMouth added, which are kept."
3. **Finding 5, chapter lengths.** Use the precise-timing asset options in the chapter-marker reader too (`metadataAsset`, `AudioPlaybackService.swift:1606`, with the length read at :1638), through the same helper ST06 added (DRY). Test it as ST06's test does.
4. **Finding 4, a comment.** Correct the comment at `AudioPlaybackService.swift:1602` that says `AsyncBridge` has no timeout, and say in it that abandoned AVFoundation work can keep running.
5. **V05, re-reads without the byte compare.** Read the TODO's V05 item in the main checkout: `grep -n "V05 —" /Users/roberteggleston/programming/ai/claude/swift/TextMouth/TODO-2026-09-04.md`, then by line range. It is required before any future page-reader bump, and it is cheap now. Build it as written, with its tests.

## Rules
- **Setup.** Your worktree is made from main. Run `git checkout -b fix/polish020 main`. Register on the board as `polish020`, and build only through the wrapper (`run-area.py`).
- **Commits.** Each message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Comment the code as the surrounding code is commented.
- **Tests:**
  - no traps, no sounds, no `~/.TextMouth`, no `UserDefaults.standard`;
  - a hosted accessibility test calls `skipUnlessHostedWindowsExposeAccessibility()` first.
- **Disk.** Check for 4 GB free before a build, and delete your build folder at the end, unregistering its app first with `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <folder>/Build/Products/Debug/TextMouth.app`.
- **Paths.** Use literal paths in every `rm`.
- **Budget.** The user set tonight's line at 5% of the week left, so the usage rule's "low" status does not stop you. Use no subagents, and keep it lean.
- **At the end,** in one `run-area.py` invocation, run every class you touched, plus the DAISY and EPUB page tests, `PagesUpgradeTests`, `TextPipelineGoldenTests`, the folder-management and library-index classes, and `OnDiskContractTests`. Also run `make lint-tests LINT_BASE=main`. The orchestrator runs the full suite at the merge.
- **Never** push or merge into main.

## The report (at most 20 lines)
- Each commit.
- The exact counts and the lint result.
- Any new words a listener hears.
