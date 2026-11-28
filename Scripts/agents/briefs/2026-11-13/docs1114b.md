# The second documentation pass of November 14, 2026: the merges after 0.4.8

You are `docs1114b`, a Sonnet documentation worker. Edit only Markdown: `README.md`, `ARCHITECTURE.md`, and the pages under `docs/`. Build nothing and run no tests. Follow `common.md` beside this brief, except that this brief allows these Markdown edits. Delete nothing.

## Start

Branch: `git switch -c docs/1114b main` (main 658ec668 or later).

Read each page before you change it, and match its voice:
- plain sentences;
- a VoiceOver user as the reader;
- names of types and functions as the code has them.

Check every sentence against the code.

## What to document

The TODO entries are in `TODO-2026-09-04.md`; search for the bold titles.

1. **The audio look-ahead** (TODO: "A look-ahead builds no audio engine graph"). The architecture page of speech and the audio engine:
   - the graph is built on first use;
   - `prepareGraph()` for the speech service's own engine;
   - a look-ahead builds none;
   - a same-text `speak()` keeps the render (RENDER_KEPT).
2. **The Reading List in a cloud library** (TODO: "The Reading List in a cloud library").
   - `docs/user/library-window.md`: it quotes the old "Remove books when finished" hint. Give the new one, and drop the sentence saying the hint leaves something out.
   - The user's cloud page:
     - books of unknown size download one at a time;
     - the "not enough free space" sentence of a later pass;
     - one huge book of unknown size can still fill the disk once it starts.
   - The user's logs page: `DOWNLOAD_SKIPPED_NO_ROOM`.
   - The architecture cloud page: `isStillWanted` and the loop.
3. **BRF running heads keyed without their numbers** (TODO: "BRF running heads keyed without their numbers").
   - The architecture braille page: `headKey`, the empty key, and that only a row with a number word at either end can be a head.
   - The user's Book Information or braille page: the suggestion is announced once.
   - Wherever the docs say braille books are read again at 1.1.0, say 1.1.1.

## The changelog

Don't edit `docs/user/changelog.md`; the orchestrator does. End your final message with plain sentences for a listener for 0.4.9, at most three for each part.

## Commits and report

- One commit for each part, each ending with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Your final message is the report, at most 25 lines:
  - the branch and its tip;
  - the commits;
  - the pages changed;
  - any untrue sentence you found;
  - the changelog sentences.
