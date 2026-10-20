# Brief: braille tables from this Mac (October 20, 2026)

You are `mactables`, an Opus agent, on the branch `team/mactables`. TextMouth is a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display; braille is the feature they care most about.

## The request, in the user's words
- October 19: "for the braille I want it possible to have multiple braille tables and contracted and uncontracted settings and use the library."
- Then: "Is there a way to provide a selector for downloading tables from a list? Iether from the Mac or the other library tables?"
- And: "I gree to keep English as default."
- `humanQuestions/2026-10-19.md` (gitignored, so read it in the main checkout, `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/humanQuestions/2026-10-19.md`) records question 4 and its recommended answer, which this brief builds: offer the Mac's own braille tables in the Braille tab.

## What exists (merged today, 3996434d)
- **liblouis 3.39.0** runs only in the `TextMouthBraille` helper (`TextMouthBraille/main.c`, modes check, forward, and back). `BrailleTranslator` is its only caller. The helper changes into the tables folder and loads a table by its bare name, then works in /var/empty. It accepts only the tables the catalog offers.
- **The tables.** `BrailleTableCatalog` offers four bundled English tables from their own metadata. The setting is `BraillePreferences`, mirrored in config.json as `brailleTable`. `BrailleTablePickers` is the pop-up view that both the Braille tab (`BrailleSettingsView`) and Export's braille options share.
- **Books.** A braille book keeps its import table in `Book.brailleTable`, and Remove from Library Only's marker carries it too.
- **The record.** The team's notes are under "## From the braille team" in `AGENT-NOTES-2026-10-04.md` (in the main checkout), and the charter is `Scripts/agents/briefs/2026-10-19/team-braille.md`.

## What the Mac has
- **Where.** VoiceOver's own liblouis tables are at `/System/Library/ScreenReader/BrailleTables/LiblouisBrailleTranslator.brailletable/Contents/Resources/liblouis/tables`. On this Mac (macOS 26.3) there are 485 files, from liblouis 3.34.0, unmodified, under LGPL 2.1. The bundle's `Contents/Resources/LiblouisBrailleTables.plist` says so in `OpenSourceVersion`.
- **Trust.** The folder is world-readable on the sealed system volume. Apple's braille-table API (`AXBrailleTable`) lists none of these tables to TextMouth, but the files can be read.
- **Metadata,** counted by line: 272 tables with `#+language:`, 241 with `#+type:`, 145 with `#+contraction:`, 144 with `#+grade:`, 134 with `#+dots:`, 69 with `#+system:`, and 242 with `#-display-name:`. 72 tables say both `#+type: literary` and `#+dots: 6`.

## Decisions (settled; do not reopen them, and say each in the code's comments where it applies)
1. **Built in and default.** English stays built in and the default, as now: UEB contracted, with the four bundled tables unchanged. Existing settings, books, and config.json values need no migration.
2. **The Mac's tables are a second source,** read in place: never copied, never changed, never downloaded.
   - If the folder is missing, as on an older macOS or after Apple moves it, TextMouth offers only the bundled tables, with no error.
   - Record the folder's liblouis version from the plist when it is there.
3. **Which tables are offered:** literary tables, six-dot only.
   - Offer a table whose metadata says `type: literary` and `dots: 6`. Also offer one whose metadata says `type: literary` with no `dots` line, but only once a check translation of a short sample (decision 5) shows six-dot cells only.
   - Never offer computer braille, math tables, eight-dot tables, or include-only files.
   - Where the Mac has a bundled table's twin, the bundled one wins, and only one is listed.
4. **The selector.** `BrailleTablePickers` gains a "Language" pop-up before "Braille code" and "Contraction", in the Braille tab and in Export's options alike (DRY).
   - **The language list:** English first, then every other language with an offered table, in alphabetical order of the language's name in the user's own language (`Locale.current.localizedString(forIdentifier:)`). A region, such as "German (Switzerland)", is shown only when needed to tell two tables apart.
   - **The code list:** "Braille code" lists that language's systems by their own display names, and "Contraction" lists that code's tables, as now.
   - **Words:** every control has a label, a spoken value, and a hint, and the keyboard can reach it. The tab says in one sentence where the chosen table comes from, built into TextMouth or this Mac's VoiceOver tables, with that liblouis version.
5. **Checked before it is used.** When a Mac table is chosen, in Settings or in Export's options, TextMouth checks it off the main thread with the helper's check mode, plus a short forward translation for decision 3.
   - Nothing else waits for the check.
   - **A table that fails** is not taken. The pop-up returns to the previous choice, and VoiceOver hears a sentence naming the table and why. Draft: “TextMouth can't use this Mac's table “<display name>”: <reason>.” Pin the final words in tests.
   - Results are cached for the session.
   - **At import or export,** a Mac table that now fails, or is gone, is refused by name, as an unknown table is now.
6. **The helper and the source.**
   - The helper loads a Mac table from inside the Mac's folder, by bare name, exactly as it does the bundle's.
   - It never mixes the two folders, so a table's includes come from its own liblouis version.
   - Only catalog tables are accepted, from either source. Keep L1's comma safety and L2's catalog check.
   - Any change to `main.c` gets the same memory care as before: bounded buffers, and no shell.
7. **Stored values.**
   - A Mac table is stored with a source prefix, such as `mac:fr-bfu-comp6.utb`, in the setting, in config.json, in `Book.brailleTable`, and in the removal marker.
   - Bundled tables keep their bare names.
   - A build from before this branch reads a `mac:` value as an unknown table, and refuses it by name.
   - Name the prefix in one place (DRY).
8. **Books.** A book imported with a Mac table keeps it. If a macOS update removes or changes that table, the book keeps its text, and a rebuild that needs the table fails by name and keeps the old content.md, as for any table no longer available. Book Information and Speak Info name a Mac table's code and language.
9. **Tests.**
   - **Hermetic by default.** The catalog's logic (metadata, filtering, twins, language names, ordering, stored values) uses a fixture folder of small metadata-only files made in the test's sandbox.
   - **Real Mac tables:** tests that compile them use the real system folder when it is there, and skip with a reason when it is not. Pick three: a contracted French, a German, and a Spanish table, if the Mac has them.
   - **Never** write outside a sandbox, touch `~/.TextMouth`, or read `UserDefaults.standard`.
   - Hosted accessibility tests first call `skipUnlessHostedWindowsExposeAccessibility()`.
   - No test may trap or play a sound.
10. **Size.** The app must not grow beyond a few KB of code.

## How to work
- **Setup.** Your worktree is made from main. Run `git checkout -b team/mactables main`.
- **The board.** Register on the message board as `mactables` (`python3 -I .claude/skills/agent-bbs/scripts/bbs.py protocol` prints the protocol), and build only through its wrapper, which `Scripts/test/run-area.py` uses.
- **Workers.** Do the work yourself, or with at most two Sonnet workers, each with a brief that settles every type, sentence, and test (the October 19 lesson). The week is at about 54% left, and today's line is 45%: start no worker below 48%.
- **Commits.** Make small focused commits, each with its tests, and comment the code as the surrounding code is commented. Each commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` (a worker's ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`).
- **Disk.** Check for at least 4 GB free before a build. Delete build folders when done, unregistering their app first with `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <folder>/Build/Products/Debug/TextMouth.app`.
- **Paths.** Use literal paths in every `rm`, never a shell variable.
- **Tests to run at the end, in one `run-area.py` invocation:**
  - the braille, import, and export areas;
  - BookFormatTests, SettingsTabFitTests, ContentAnalysisMergeTests, LibraryOnlyRemovalTests, ConfigSyncTests, KeyboardReachabilityTests, and LogContentPolicyTests (if you add a log tag);
  - your new classes, placed in the braille area of `Scripts/test/areas.conf`.

  Also run `make lint-tests LINT_BASE=main` and `make lint-a11y LINT_BASE=main`. Do not run the full suite; the orchestrator runs it at the merge.
- **Never** push, merge into main, or touch `~/.TextMouth`.

## The report (your final message, at most 50 lines)
- The branch's head, and each commit with its subject.
- The decisions you made beyond these.
- **What the Mac offers:** how many tables in how many languages, which were refused at the check, and why.
- The run's exact "Executed N tests…" line, and the lint results.
- Every new sentence, label, hint, and value a listener hears.
- What you could not verify, and the follow-ups.
- A README sentence, and a TODO sentence.
