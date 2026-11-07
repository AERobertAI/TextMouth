# Task `legacy`: the legacy scenarios that test their own arithmetic test the app instead

Slug `tests-legacy`, branch `tests/legacy` from `team/tests`. Read `_common.md` beside this file first. The audit is `build/orchestrator/oct30/tests-audit-vacuous.md` in the main checkout (findings V03-V11, with file and line for each); this brief settles every choice it left open.

The 18 legacy scenario files under `TextMouthTests/Sources/Tests/` are compiled into the hosted test target (`project.yml` 328-350) and run through `TextMouthProductionTests/LegacyScenarioHarness.swift`, whose helpers (`assertEqual`, `assertTrue`, `assertGreater`) throw on failure (lines 46-68) and whose runners assert each file's scenario count (110-354). A scenario cannot skip. Keep the legacy syntax in these files.

## Changes
`TextMouthTests/Sources/Tests/IntegrationTests.swift` (scenarios run from `LegacyIntegrationScenarioTests`, harness lines 266-276):
1. V03, "Reading stats: session tracking accumulates per-book and daily time" (833-861): it simulates the service and asserts its own sums. DELETE it; `ReadingStatsServiceTests.testDailyAndPerBookTotalsAlwaysAddUpToTheGrandTotal` checks the real service.
2. V04, "EPUB parse → heading lookup finds correct heading for position" (604-625): replace the silent `guard allHeadings.count >= 2 else { print(...); return }` with `try assertGreater(allHeadings.count, 1, "alice.epub lost its headings")`, and the scenario's own closure with the app's lookup, `ReaderViewModel.currentHeading(in: allHeadings, chapterIndex:characterOffset:)` (`ReaderViewModel+Navigation.swift` 1092); assert the heading's `id` it finds. Read today's value once to pick the expected heading.
3. V05, "Skipped headings: chapter text excludes skipped heading content" (747-767): DELETE it, keeping one line elsewhere only if the identifier format is pinned nowhere else: `grep -rn '"0-56-2-Section B"\|headingID\|Heading.id' TextMouthProductionTests | head` first; if no test pins the `Heading.id` format, add `try assertEqual(content.allHeadings[2].id, "0-56-2-Section B")` to the nearest scenario that already parses that document.
4. V06, "Bookmarks across chapters sort and navigate correctly" (688-717): delete the scenario's own sort and its three assertions (701-708), keep the numbering assertions (710-713), and rename it "Bookmarks across chapters are numbered in the order added".
5. V07, two heading scenarios over sample.md (112-134 and 933-946): before each loop, `try assertEqual(content.allHeadings.count, <exact count>)`; read the count once (sample.md has seven ATX headings at lines 1, 5, 11, 25, 29, 33, 37; confirm whether the title counts).
6. V08, "Substitution: offset mapping preserves position tracking through multiple rules" (337-357): add the mapping it names: `let t = MainActor.assumeIsolated { TextSubstitutionService(rules: rules).transform(originalText) }`, find "meeting" in `t.modifiedText`, and assert `t.offsetMap.toOriginal(<its UTF-16 offset>)` equals the UTF-16 offset of "meeting" in `originalText` (`TextSubstitutionService.swift` 174, `OffsetMap.swift` 128).
7. Lower the Integration inventory at `LegacyScenarioHarness.swift` line 272 by the number of scenarios deleted (36 to 34).

`TextMouthTests/Sources/Tests/BugRegressionTests.swift`:
8. V09, "normalizeMarkdownWhitespace trims trailing whitespace from lines" (260-269): replace the loop with `try assertEqual(result, "Hello\nWorld")` (confirm the input gives exactly that; `ParserUtilities.swift` 88-115).

`TextMouthTests/Sources/Tests/BookmarkToggleTests.swift`:
9. V10, "Toggle at empty position adds, toggle again at same position removes" (411-429): delete the two `bookmarks.count` assertions that count the scenario's own append and removal; keep the two `nearbyBookmark` assertions. Rename it "nearbyBookmark finds a bookmark at the position and none once it is gone".

`TextMouthTests/PDFIntegrationTests.swift`:
10. V11: DELETE the file. It is a stand-alone `xcrun swift` script compiled by nothing (not in `project.yml` or the project), tests PDFKit and Vision directly without importing TextMouth, and hard-codes the main checkout. `LegacyPDFParserTests`, `PDFPageLabelTests`, and `DocumentGoldenTests` read the same PDFs through the app's parser. Say so in the commit.

## Proof
For each changed scenario, break the code it now calls and see `LegacyIntegrationScenarioTests`, `LegacyBugRegressionScenarioTests`, or `LegacyBookmarkToggleScenarioTests` fail naming it: `ReaderViewModel.currentHeading` returning `headings.first` (V04); the Markdown parser dropping headings (V07); `toOriginal` returning its argument (V08); `normalizeMarkdownWhitespace` returning `""` (V09). Restore each. One build can carry several breaks at once, since each fails its own scenario.

## Classes to run
`LegacyIntegrationScenarioTests LegacyBugRegressionScenarioTests LegacyBookmarkToggleScenarioTests` (check the exact class names in `LegacyScenarioHarness.swift`). Commits: one per file (the PDF script's deletion on its own). Touch no other file but line 272 of the harness.
