# testkit/areas: fill `Scripts/test/areas.conf` with every hosted test class

Slug `testkit-areas`. Branch `testkit/areas`, made from `team/testkit` AFTER `testkit/runner` was integrated (`Scripts/test/run-area.py` exists on the branch you start from; if it does not, stop and tell `testkit-lead`). Python and data only: **you build nothing**.

## Why

`run-area.py feeds bookmarks` runs the hosted tests of named areas in one xcodebuild. The runner is done; `Scripts/test/areas.conf` holds three samples. Your job is the real list: every runnable test class in `TextMouthProductionTests/` in at least one area, so that `python3 Scripts/test/run-area.py --unassigned` prints nothing, and so that a person can think "I changed the sleep timer" and run `run-area.py playback-end` and get the right tests.

## Method

1. Read the header of `Scripts/test/areas.conf` (the format) and `run-area.py -h`. `python3 Scripts/test/run-area.py --unassigned` lists the classes still to place; `--list` shows the areas.
2. Write a throwaway classifier in the scratchpad (not committed) that assigns classes by name and file prefix to areas, run it, then place the rest by hand. When a class name does not say its subject, read the first doc-comment lines above the class (`grep -n -B6 "^final class Name" file | head`), nothing more. Do not read test bodies.
3. Write the result into `areas.conf`, grouped and ordered by area, classes sorted inside each area. Keep the format's header comment.

## Areas

These names are required (the user and the orchestrator will type them): `feeds`, `reading-list`, `playback-end`, `speech`, `audio`, `import`, `reader-text`, `headings`, `bookmarks`, `library`, `sheets`, `settings`, `shortcuts`, `storage`, `transcripts`, `recording`. What each holds:

- `feeds`: feed parsing, refreshing, downloading, the feed item index, feed UI, OPML, folders of feeds, Delete Feed, unsubscribe.
- `reading-list`: the reading list model, its reader behavior, its view.
- `playback-end`: end of book behaviors (Stop, Loop, Continue to Next Book), finished books, the sleep timer, continuing, autoplay requests, playback lifecycle at the end.
- `speech`: speech service, preparation and caches, the markup guard, refusals, rendering, symbol and substitution rules, voice catalog and warm-up.
- `audio`: audio playback and engine, filters, export, manifests, media commands and the now-playing center, audio ZIP classification, route monitoring, MP3 encoding.
- `import`: importing any format (EPUB, DOCX, PDF, DAISY, ZIP, TMB, folders, Ogg conversion), staging, import progress and decisions, parsers and their fidelity, text pipeline goldens and benchmarks.
- `reader-text`: the reader's text, reading position/text anchors/place relocation, text caches, text encoding, search, Where Am I.
- `headings`: headings, vocabulary, announcements of headings, skipped headings.
- `bookmarks`: bookmarks and their keyboard access and placement.
- `library`: the library model, index persistence and recovery, sorting, folders, moves and removals, cloud library, book info.
- `sheets`: sheet views and windows (book info, export, metadata, import decision, speech refusal, transcription sheets, window routing and focus).
- `settings`: preferences, config files and sync, settings views, data directory preferences, logs settings.
- `shortcuts`: keyboard shortcuts, key handling, menu keys, double-press, shortcut files.
- `storage`: data directory move/migration/availability, storage generations, storage status, persistence failure reporting, multi-Mac safety.
- `transcripts`: transcription, transcript model/cleanup/edit/accuracy.
- `recording`: the recording window, service, input choice, permission, save, quit, and recovery. (The audio editor is its own area, `editor`.)

Add areas where the above leave a class badly placed (suggested: `editor`, `cloud`, `accessibility`, `performance`, `places`, `stats`, `logs`, `windows`, `pdf`, `ogg`, `unicode`), at most 30 areas in all, each with 3 or more classes. A class may be in two areas when it truly serves both (at most two). Performance and benchmark classes go to `performance` (and say in its description that they are load-sensitive and skip on a busy Mac).

## Rules

- Every runnable class is in at least one area; no helper (a class with no tests) is listed; a name appears once per area.
- The descriptions are one line each, plain words, saying what a person changes when they run the area.
- Do not edit `run-area.py` or `testkit.py` (a bug in them is a finding for the lead: post it with `--file`).

## Checks (all must hold; none builds)

    python3 Scripts/test/run-area.py --selftest
    python3 Scripts/test/run-area.py --unassigned        # prints only the count line, "0 unassigned"
    python3 Scripts/test/run-area.py --list
    python3 Scripts/test/run-area.py all --dry-run | wc -c    # the command line is long and fine; it must not be refused

Report the number of classes, the number of areas, and the five biggest areas with their class counts.

## Commit

One commit: `Assign every hosted test class to an area`. Then the report (at most 15 lines).
