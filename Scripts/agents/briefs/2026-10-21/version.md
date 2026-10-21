# Brief: the version number, and a procedure for beta versions (October 21, 2026)

You are `version`, a Sonnet agent, on the branch `release/version`. TextMouth is a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display.

## The request, in the user's words
"maybe update the version number finally?, there should probabbly be a procedure for that in the beta versions anyway".

## What exists
- `project.yml` line 91 sets `MARKETING_VERSION: "0.1.1"`, unchanged for a long time, and line 92 sets `CURRENT_PROJECT_VERSION: "1"`.
- `Info.plist` reads both settings.
- The Makefile sets the build number at build time: `BUILD_NUMBER := $(shell date -u +"%Y%m%d%H%M%S")` (line 37), passed as `CURRENT_PROJECT_VERSION` (line 154).
- `make install` keeps each build's dSYM by build number in `build/installed-dSYMs`, as `docs/developer/building.md` says.

## Decisions (settled)
1. **The new version is 0.2.0.** It is the first change since 0.1.1, after months of merged work: new formats, Export's Convert to, braille, this Mac's braille tables, and pages.
2. **The beta procedure:**
   - The version is `0.MINOR.PATCH` until a 1.0. MINOR goes up when a merged feature set the user asked for reaches main; PATCH goes up for an install that holds fixes only.
   - The build number stays the UTC time stamp the Makefile makes, unique and increasing, which names each kept dSYM.
   - The orchestrator bumps the version before the user's next install whenever main holds user-visible changes since the last bump, and records it.
3. **A script:** `Scripts/set-version.sh <version>`.
   - It checks the form (`^[0-9]+\.[0-9]+\.[0-9]+$`).
   - It refuses a version not greater than the current one.
   - It changes only `MARKETING_VERSION` in `project.yml`, and runs `xcodegen generate`.
   - It prints the old and new versions.
   - It writes nothing else, and commits nothing.

   Give it a `--selftest`, run on a copy of `project.yml` in a temporary folder, and add that selftest to `make check-selftest`. Add a Makefile target, `make set-version VERSION=0.2.0`, and list it in `make help`.
4. **A page for the user,** `docs/user/whats-new.md`, linked from `README.md`'s index of user pages.
   - Its newest version comes first: "0.2.0 (October 21, 2026)", with one plain sentence per feature set. Write them from the TODO's merge entries since 0.1.1. The TODO is gitignored, so read it at `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TODO-2026-09-04.md`: `grep -n "^- \[x\] \*\*" TODO-2026-09-04.md`, then by line range.
   - Keep it to 15 to 25 lines, grouped under a few headings (Reading, Listening, Braille, Export, Library), in the pages' own style.
   - It must work well with VoiceOver and a braille display: headings and lists, nothing visual.
5. **The developer procedure:** a short "Versions" section in `docs/developer/building.md`, saying what decision 2 says and how to run the script. Add one line about it to `AGENTS.md`'s "How the orchestrator works" section, the bump before an install.
6. **Bump to 0.2.0** with the script, as its own commit.

## Rules
- **Setup.** Your worktree is made from main. Run `git checkout -b release/version main`.
- **Builds.** Do not build the app. The selftest needs no build.
- **Commits.** Small commits, each message ending with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Comment the script as the other scripts in `Scripts/` are commented.
- **Paths.** Use literal paths in every `rm`.
- **Never** push, merge into main, or touch `~/.TextMouth`.
- **At the end,** run `make check-selftest`, which builds nothing, and report its last lines.

## The report (your final message, at most 20 lines)
- Each commit.
- The script's usage.
- The whats-new page's headings.
- The selftest result.
