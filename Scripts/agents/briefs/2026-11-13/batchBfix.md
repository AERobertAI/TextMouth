# The fix round of `fix/batch-b-parser-safety` (November 13, 2026)

You are `batchBfix`, a Sonnet worker. You fix what the Opus review of batch B asked for, on its branch. First read `common.md` beside this brief and follow it.

## Start

- In your worktree: `git switch fix/batch-b-parser-safety`, and check `git log -1 --format=%h` prints `49e9aea73`. Its worker has finished and its folder is gone.
- Read in the main checkout (`/Users/roberteggleston/programming/ai/claude/swift/TextMouth/`): the review `build/orchestrator/nov13/batchB-review.md` (findings 1 to 6, the answers, "Where I stopped"); the report `build/orchestrator/nov13/batchB-report.md`; the batch brief `Scripts/agents/briefs/2026-11-13/batch-common.md` and items 1, 8, 24, 25, 30 in section 1 of `build/orchestrator/nov13/triage-report.md`.
- swift-markdown and swift-cmark are checked out, read-only, in the main checkout's `build/DerivedData/SourcePackages/checkouts/`. Never search from `/` or the home folder.

## The work, one commit each, each with a test that fails without it

1. **Finding 1, the blocker** (`MarkdownCacheService.swift:766-767, 778-783`): the nesting refusal must never be swallowed.
   - `writeCache`'s parse throws, so an import of a too-deep file is refused with the guard's sentence and writes nothing (no content.md left behind);
   - in `parseMultiChapterMarkdown`, a refused chapter is never dropped: it keeps its raw text (as the reader would show it unparsed), and the refusal is logged once (name `LogContentPolicyTests` if you add a log tag), so Edit Text, a rebuild, the pages re-read, and the exports never commit for a shorter text, and Edit Text's "holds no chapter with anything in it" is said only when that is true.
   - Test through `generateCacheContent` and `parseMultiChapterMarkdown`, with plainly deep inputs only (never search for inputs that get past the count).
2. **Finding 2** (`DAISYParser.swift:569-576`): a DAISY 3 book's DTBook files are read in one fixed order every launch: the order the SMIL spine's text references give them, else the manifest's document order, never a dictionary's. This goes in the same 1.0.1 bump, so the next launch's re-read finds each book in its true order. Add the two-file test with a SMIL spine the review asks for; it must fail on a dictionary's order (run it several times in one test, or compare against the spine).
3. **Finding 3** (`MarkdownNestingTests.swift:145-149, 90-96`): each test proves the layer it names: about 200 `>` in the marker line's rest so only the count can refuse, or bind `deepestTree = .max` where the walk's limit would answer first.
4. **Findings 5 and 6:** `MarkdownParser.swift:26` names the walk's real limit (`PlainTextExtractor.deepestTree`, 272); `PageReaderVersions.swift:71-76` says every stamped DAISY book is read again once (and only multi-file books with a wordless page change).

Leave finding 4 (inline nesting, which predates the branch) for a follow-up; say in your report what the review's cmark-iterator bound would take.

## Finish

`make typecheck-tests REF=<commit>` before each train (always), one last train with the areas `import,analysis,feeds` and every class you touched (the golden classes too), and report as `common.md` says (if writes outside your worktree are refused, your final message is the report; otherwise save it as `build/orchestrator/nov13/batchBfix-report.md`), with each finding: what you changed, its test, and whether breaking it fails the test.
