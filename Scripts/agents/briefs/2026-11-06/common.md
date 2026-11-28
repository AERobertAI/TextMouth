# Friday night agents: what every agent shares (November 6, 2026)

The week's usage resets on Saturday morning, and the user's standing wish is that what is left before a reset gets used. Work carefully: nothing here is urgent, and a branch left unfinished at a stop simply resumes later.

## Read first

Read `Scripts/agents/briefs/2026-11-04/readers-common.md`. It stands in for AGENTS.md. Its rules on builds, tests, the board, and safety on hostile files all hold, with these changes:

- **Your base is `main`,** version 0.4.0 (0813bcf0), full suite 10243 tests, 78 skipped, 0 failures, `make typecheck-ios` 0 errors. Not `core/own-readers`.
- **TextMouth's own readers are already on, on the Mac too,** for RTF, Word 97-2003, OpenDocument, Word 2003 XML, MOBI 6, and KFX. Tests that pin textutil's own reading bind `OwnDocumentReaders.$forcesTextutil`.
- **The policy for what a reader reads** is in `Scripts/agents/briefs/2026-11-05/common.md`: read what a person sees in the document's ordinary view, in reading order. Read its table if your work touches what a format reads. Its "Versions" section also holds: a change to what a format reads raises that format's line in `PageReaderVersions` and the tests that pin it, so its books are read again once. Name the differences when you record a golden again, in the commit message and your report.
- **The train** runs on the half hour with `--base main`, and pools every agent's branch.
- **Usage:** do not check it. Commit small and often, so a stop loses nothing.

## Rules that have tightened

- **Every `rm` takes a literal or relative path,** never a variable, a command substitution, a glob, or a path built at run time. To clear a folder, write its path out, or `cd` to a folder you made and use a relative name. This is the user's rule, for your scripts too.
- **Never read, stat, or copy the user's live library:** `~/.TextMouth`, anything under `~/Library/CloudStorage/`, or any data directory the settings name.
- **No test may hang.** Every wait in a test has a limit. An `await` without one, on the main actor, stopped every agent for 90 minutes on November 6. The train's watchdog now kills a test that writes nothing for 15 minutes.
- **No test may trap.** A trap in a test host puts a Problem Report on the user's screen. No test may play sound, record from a microphone, or touch Ogg through Apple's frameworks.
- **Heavy work takes the lock.** A throwaway `swiftc` harness, or a converter over many files, runs under `python3 -I build/orchestrator/followups1105/run_locked.py <name> ...`. Never wrap `make typecheck-*` in that: they take the lock themselves, and wrapping them deadlocks it. The Mac has 8 GB of memory.
- **Downloaded files are untrusted:** each in a new folder of its own, with any Python that reads them run as `python3 -I -B`, and your scripts kept elsewhere. A file enters the repository only with a line in `samples.tsv` naming a licence fit to publish: public domain, CC0, MIT, Apache-2.0, or MPL-2.0. If you can't name one, it stays out.
- **Forbidden to read:** the code of calibre, KindleUnpack, libmobi, LibreOffice, antiword, catdoc, wvWare, odfpy, and any other GPL or LGPL project. Their test documents are data, and allowed.

## Who else is working tonight

Each on its own branch, and claims are on the board:
- `word95`: `readers/word95`, `readers/word95-switch`: `TextMouth/Parsers/WordDocument*.swift`, `.doc`'s line, and `TestData/format-samples/doc6/`.
- `azw3`: `readers/azw3`: `TextMouth/Parsers/MOBI*.swift` and new KF8 files.
- `readerfollow`: `readers/followups-1106`: DOCX, Word 2003 XML, `MarkdownMarkerWriter`, the XML guard, the iOS plist.
- `epubexport`: `export/epub3`: `TextMouth/Services/Export/` and the Export dialog.
- `sweep`: `fix/followup-sweep`: older small bugs, anywhere but the files above.

The lines in `PageReaderVersions` and `samples.tsv` may conflict at merge. The orchestrator resolves those, so don't merge each other's branches to avoid them. For a problem in a file another agent owns, post a `finding` on the board and leave the file alone.

## When you're unsure

Ask the orchestrator with `SendMessage` to `main` if you have it, else a `question` on the board, and carry on with the safest choice in the meantime. Ask nothing of the user.

## What follows you

An independent Opus review reads your branch, and then a verifier. Every first review so far has found blockers, usually where a test passed for the wrong reason, so prove your tests: break the code on purpose and see them fail, for the risky ones at least. Check real files and say how many, because real files decide.

## Your report

Your final message is the report, because writes outside your worktree may be refused. Try to save it as well, at `build/orchestrator/followups1105/<slug>-report.md` in the main checkout. Follow the list at the end of `readers-common.md`, at most 40 lines, and add a plain paragraph on what the user gets. Name the documentation each change needs, page by page: you edit no `*.md` file.

Commit messages end: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`
