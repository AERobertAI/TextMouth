# bughunt fix A: take the HTML depth work off team/bughunt (October 31, 2026)

You are `bughunt-revert` (Sonnet). Read `../teams-common.md` ("The worker's part", "Rules for everyone", "Builds") first; it stands in for AGENTS.md. Work on branch `bughunt/revert-htmldepth`, made from `team/bughunt` (at 2fd75730) by name: `git checkout -b bughunt/revert-htmldepth team/bughunt`.

## Why
An outside review of the bug hunt's parser changes (`/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/oct30/review-bughunt-parsers.md`) found that the new HTML depth guard changes the words of ordinary books:
- Any chapter nesting more than 32 levels deep is read as flattened words: its headings, links, pages and alt text are lost, and hidden text is read.
- Sloppy but ordinary HTML can count as deep and be read as one paragraph.
- Two of the crash paths it was meant to close are still open.

The user's library holds about 730 EPUBs, which must read exactly as on main. So the depth work comes off the branch tonight, unchanged on main, and is redone later from that review.

## What to do
1. Revert these four commits, newest first, each as its own `git revert` commit whose message says why (cite the review file):
   - 006f7263 Read a feed title nested past SwiftSoup's reach as its words
   - 516281b1 Read markup nested past SwiftSoup's reach as its words alone
   - 39a448a3 Read how deep markup nests before SwiftSoup parses it
   - 215711a0 Read HTML nested thousands deep without overflowing the stack
2. Settle conflicts so that the HTML reading code (`TextMouth/Parsers/HTMLReadingText.swift`, `HTMLToMarkdownConverter.swift`) and the feed call sites (`FeedTextConverter.swift`, `FeedDiscovery.swift`, `FeedEpisodeImporter.swift`) read exactly as on `main` for these paths. Check with:
   - `git diff main team/bughunt -- <those files>` before;
   - `git diff main HEAD -- <those files>` after. It must show no HTML-depth change left.
   Keep every other bug-hunt fix: the NCX, navigation, DAISY NCC and PDF walks without recursion (80361ef0, 599977c0, fcd9f3de, ad6e88a3), which the review found sound, stay exactly as they are. If a revert touches their tests (30a739f7 mentions navdepth's deep tests that deepparse lowered), restore those tests to navdepth's own version.
3. Remove `HTMLNestingTests` from `Scripts/test/areas.conf` if the class is gone, and keep `2fd75730`'s other change (the duplicate marker pin).
4. Optional, only if small (a few lines on main's own path) and safe: the review's finding 7, a processing instruction such as `<? echo 1 ?>` that crashes SwiftSoup's XML parser. Fix it in the path main uses, with the review's test. If it needs the reverted scanner, leave it as a follow-up.

## Test
One run, through the build wrapper as `teams-common.md` says, of:
- every HTML, EPUB, feed-text and golden class (`grep -rln "HTMLReadingText\|HTMLToMarkdown\|FeedTextConverter\|EPUBParser" TextMouthProductionTests`);
- `LegacyParserAndHashTests`;
- the `feeds` area.

Only one build runs on the whole Mac at a time, so wait your turn. `df -g /System/Volumes/Data` must show at least 4 GB free before you make a build folder. Delete the folder after the run (lsregister -u first, literal paths).

## Report (at most 15 lines)
Your branch, your commits, the exact `Executed` line, what you could not do, and whether finding 7 was fixed.
