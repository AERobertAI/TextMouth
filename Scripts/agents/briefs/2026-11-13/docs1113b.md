# The second documentation pass of November 13, 2026: Leading articles and the per-window sleep timer

You are `docs1113b`, a Sonnet documentation worker. You edit only Markdown: `README.md`, `ARCHITECTURE.md`, and the pages under `docs/`. You build nothing and run no tests. Follow `common.md` beside this brief for the rules (they bind you, except that this brief allows these Markdown edits).

## Start

- Your branch is `docs/1113b`, made at the integration branch, which holds both features: `git switch -c docs/1113b integrate/1113`, and check `git merge-base --is-ancestor 9e3f550d1 HEAD && echo ok` (the sleep timer's merge).
- Read each page before you change it, and match its voice: plain sentences, a VoiceOver user as the reader, names of types and functions as the code has them. Check every sentence against the code on your branch.

## What to document, from these reports (main checkout, `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/nov13/`)

1. **Leading articles** (`feature/title-articles`): `articles-report.md` ("Documentation needed"), `articlesfix-report.md` ("Docs"), and the TODO entry (search `TODO-2026-09-04.md` for "A Leading articles setting"). Pages: `docs/user/settings.md` (the Titles section and its pop-up, the three choices and their sentences, the languages, folder names kept as written, `leadingArticles` in config.json), `docs/user/library-window.md` (letter navigation in each choice; the inverted rows; the rotors; search finds a title as written or shown), `docs/architecture/state/preferences.md`, `library-index.md`, `windows.md`, `feeds.md`, and `docs/developer/testing.md` (the probe runs only on request, through the `type_select_probe` request flag; `LibraryTypeSelectBehaviorTests`).
2. **The per-window sleep timer** (`feature/window-sleep-timer`): `wintimer-report.md` ("Documentation needed") and `wintimerfix-report.md` ("Docs"). Pages: `docs/user/reader-windows.md` (each window has its own timer; a book changed in place keeps it; a new window takes it once its book loads; Restart acts in the key window; the media gesture acts on the book being heard; closing a window stops only its own timer; two windows' sheets can be open), both sleep-timer entries of `docs/architecture/state/timers-and-statistics.md` (owner: each window's timer and `SleepTimerRegistry`; `take`; the routing; `sheet(for:)`; the registry's copy of the last duration, its run-out mark by book, its retention rule, `timerChanges`; drop `forgetLastOwner`; add `SleepTimerRegistry.swift` and `BookReaderWindowView.swift` to the files), `windows.md` (`ReaderWindowContent` and `WindowSleepTimerHolder`), and `reader.md` (the window's timer goes with a move; the "could not be opened" sentence skipped if any window's timer changed).

## The changelog

Don't edit `docs/user/changelog.md` (the orchestrator does). At the end of your final message, give one to four plain sentences for the changelog's 0.4.7 section about the sleep timer, for a listener.

## Commits and report

- One commit per feature, each ending with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Your final message is the report, at most 30 lines: the branch, its tip, its commits, the pages changed, any report sentence you found untrue, and the changelog sentences.
