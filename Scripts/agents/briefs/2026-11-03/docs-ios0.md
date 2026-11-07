# Documentation pass for iOS phase 0 (November 4, 2026)

You are `docs-ios0`, a documentation agent with no build. Make your branch with `git checkout -b docs/ios-phase0 main`: your worktree may start on another commit, so name `main`. You edit only README.md, ARCHITECTURE.md, and the pages under `docs/`. Make one commit per topic below, each ending `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`, and run no build or test.

## What merged

Main is at cb7cc4c6 or later, with `integrate/ios-phase0` fast-forwarded into it on November 4. Its record is the TODO entry that begins "**iOS phase 0: the iOS app target compiles and links**" in `TODO-2026-09-04.md`: read that entry, and nothing else of the TODO. The design is `IOS-PORT-RESEARCH-2026-11-03.md`, sections "How one codebase builds both apps" and "A plan in phases". The pattern the teams followed is `Scripts/agents/briefs/2026-11-03/ios0-common.md`. The five teams' reports, the five reviews, and the final review are in `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/ios0/` (gitignored; read them there by absolute path): `*-lead-report.md`, `review-*.md`.

## What to document

1. **docs/developer/building.md.**
   - The iOS target `TextMouthiOS`: what it compiles, that Xcode builds it only once its iOS platform is downloaded (about 10 GB, Xcode > Settings > Components, or `xcodebuild -downloadPlatform iOS`), and that until then `make typecheck-ios` compiles and links it.
   - The three make targets, `typecheck-ios` (with `CENSUS=1`), `typecheck-mac`, and `mac-projection` (`BASE=`, `DIFF=1`), with what each prints and where its results go (`build/typecheck/results/`).
   - The heavy-work lock they share with the build train.
   - The version line, now a setting group both apps share, which `make set-version`, `bump-patch`, and `bump-minor` still change on its one line.
2. **A new architecture page, `docs/architecture/platforms.md`, "The two apps and the platform folders":**
   - one source folder for both apps;
   - `TextMouth/Platform/macOS/` and `TextMouth/Platform/iOS/`, and the shared files directly in `TextMouth/Platform/` (PlatformTypes, PlatformApplication, PlatformControlStyles);
   - the five kinds of Mac change, the iOS stand-ins and `IOSUnavailable`;
   - the portable XML tree (XMLDocument on iOS) and its differential tests;
   - what iOS does now, and what phase 1 starts from.

   Link it from ARCHITECTURE.md's index, and from README.md's developer section where it fits.
3. **Paths that moved.** Every page under docs/architecture that names a moved file by its old path gets the new one. The list is `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/ios0/moved-files.txt`, old path then new. The pages that name one are in docs/architecture/: parts-of-the-app.md, shared-helpers.md, known-duplication.md, and state/{windows, transcription, text-caches, recordings, reader, preferences, media-playback, logs, imports, feeds, exports, data-directory, audio-edits}.md.
   - Change only the path, unless a sentence says where a file is and is now wrong.
   - In parts-of-the-app.md, the source folders list gains the Platform folders, and TextMouthApp's place is `Platform/macOS/App/TextMouthApp.swift`.
4. **docs/developer/testing.md.** `PortableXMLDifferentialTests`, in the import and feeds areas, compares the portable XML tree with Foundation's on 104 documents. MacBrailleTableCheckTests' memory reading can miss three short runs, so a failure of that test alone is rerun on its class.
5. **docs/agents/working-with-agents.md**, if it describes building: agents type-check with `make typecheck-ios` and `make typecheck-mac` under the heavy-work lock, test through the build train, and wait for a result with `Scripts/agents/wait-for-result.py`.

**Nothing for docs/user/.** Nothing changed for the person using TextMouth on the Mac, and there is no new version, so the changelog gets no entry.

## How to write

Match the pages' own style:
- plain sentences, present tense;
- names of Swift types and files in backticks where the page uses them;
- lists rather than tables (the user reads with VoiceOver and braille);
- no claims the merged code or the reports do not support.

Keep each page's other text as it is.

## Rules

- Never read, copy, or write anything under `~/.TextMouth`.
- Edit no file outside README.md, ARCHITECTURE.md, and docs/.
- The user is asleep: ask nothing.

Your final message is a report of at most 15 lines:
- the branch;
- each commit's hash and subject;
- the pages changed;
- anything in the reports you found contradictory, or could not place.
