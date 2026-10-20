# Team braille: what every worker's brief shares (October 19, 2026)

Your lead is `braille-lead`. Your brief names your slug, branch, files, and tests; this page holds what all of them share. Read "The worker's part" of `Scripts/agents/briefs/2026-10-19/teams-common.md` too (lines 39 to 63), and nothing else of it.

## The repository
- TextMouth, a native macOS text-to-speech and audiobook player, in Swift 6 with complete concurrency checking. Its user is blind and reads with VoiceOver and a braille display: every sentence you write that the app speaks is heard, so it must be plain, exact, and pinned by a test.
- The team branch is `team/braille`. Make your branch from it, as your brief says.
- **Shared types, already on the team branch:** `TextMouth/Parsers/BrailleCells.swift` (read all of it, about 130 lines). `BrailleCells` converts North American Braille ASCII to and from Unicode braille cells (`cell(forASCII:)`, `ascii(for:)`, `isPattern`, `usesEightDots`, `blank`, `spaced`). `BrailleBlock` is a heading (level), a paragraph, or a list item (depth), with braille or print text. Use them; do not redefine either.
- **Braille in TextMouth is Unicode braille patterns.** A cell is one `Unicode.Scalar` from U+2800 (the blank cell, between words) to U+283F for six-dot cells. A row or a paragraph is a `String` of such cells. Never use an ASCII space inside braille: the blank cell is U+2800.
- **The samples** are in `TestData/format-samples/` (read `samples.tsv` lines 49 to 55 for what each holds):
  - `brf/pride-and-prejudice-ch1-grade1.brf`: Grade 1 UEB, 40 cells by 25 lines, CR LF, one form feed, two pages, braille page numbers `#A` and `#B` on line 25 of each page, a centered title on line 1 and a centered heading on line 3 (each followed by a blank line), then 12 paragraphs in cells 3 and 1; the 7th paragraph runs from page 1 onto page 2.
  - `brf/pride-and-prejudice-ch1.txt`: its print text, blocks separated by blank lines: the title, the heading, and the 12 paragraphs.
  - `brl/pride-and-prejudice-ch1-grade1.brl`: the same braille unformatted, one block per line (title, heading, 12 paragraphs), CR LF.
  - `pef/pride-and-prejudice-ch1-grade1.pef`: the same pages as PEF 2008-1 (Unicode braille rows, blank rows as `<row/>`).
  - `brf/grade2-short.brf`, `grade2-short.txt`, `grade2-short-contractions.txt`: three Grade 2 sentences, each its own line starting in cell 1, on one page whose line 25 holds `#A`.
  - They are untrusted input. A test copies a sample into its own folder first (`copyOfFormatSample("brf/...")`, in `TextMouthProductionTests/FormatSampleFixtures.swift`) and never changes the samples' folder. `makeSandboxDirectory("Label")` (in `HostedTestIsolationSupport.swift`) gives a test a new, empty folder that is removed when the test ends.

## Building and testing
- Build and test only with `BBS_AGENT=<slug> python3 Scripts/test/run-area.py <ClassName> <ClassName> ...`, run in the background (`run_in_background`), and look at it no more than every 4 minutes. It builds in its own folder, `/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-<slug>`, and prints only the result, ending PASSED or FAILED. Run only the classes your brief names.
- **Before each build:**
  - `df -g /System/Volumes/Data` must show at least 4 GB available; if it does not, post to `braille-lead` and wait.
  - At most two braille workers build at a time. Run `python3 .claude/skills/agent-bbs/scripts/bbs.py agents --active-within 30` and count the agents named `braille-...` whose activity is "building". If two are, wait (`bbs watch <slug> --timeout 240`) and look again.
- **A new file** (Swift source or test) needs `/opt/homebrew/bin/xcodegen generate` before the build, and the regenerated `TextMouth.xcodeproj/project.pbxproj` committed with the file.
- **After your last build:** `BBS_AGENT=<slug> python3 Scripts/test/run-area.py --clean` (it unregisters the build folder's app and deletes the folder).
- **Before you report:** `make lint-tests LINT_BASE=team/braille` must pass, and your result line must show no new Swift warning.
- Never write an `rm` whose path is a shell variable; write literal paths. The Mac's `sed` is GNU sed (`gsed -i`, or edit with your tools).

## Code
- Comment every type, function, and non-obvious block, in plain sentences. Name the TODO item (FMT20, FMT21, FMT22) in each new type's comment.
- Keep code DRY: if the shared types or an existing helper does it, call it.
- Every value read from a file is untrusted: bound every count, length, and index before you use it, and never subscript without a check.
- Tests must not trap: no force unwrap (`XCTUnwrap` instead), no unguarded subscript (`XCTAssertEqual(array.count, n)` first, then `guard array.count == n else { return }`), no expectation fulfilled twice.
- Commit messages: a subject line in the imperative, a body saying what and why, and the last line `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. One logical change per commit.
- Edit no `*.md` file, and no file your brief does not name. A problem elsewhere is a finding: `bbs post <slug> --tag finding --to braille-lead --file <path> --topic "..."`.
