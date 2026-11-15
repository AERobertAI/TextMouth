# Writing docs and memory files

TextMouth's docs have two kinds of reader: the user, who reads alone with VoiceOver and a braille display, and coding agents, who pay for every token they read.
So a page is short, says what is true now, and can be found by a search.
The user does not review docs: a second agent or a script checks every line an agent writes.

## Every page

1. Say what is true now.
   Dates, quotes, and the stories behind rules go in the logs (see Where documents live, below).
2. Check every command, path, and type name you write.
   Delete what you can't verify.
3. Don't restate what the code, `--help`, or the file tree shows: point to the code with a section marker.
4. No sales words, no emoji, and no table for something that is a list.
5. Length follows the size of the thing.
6. Spend words on why something is so and on what will bite; skip the feature tour.
7. Each fact has one home, and other pages link to it.
8. When behaviour changes, edit the section that describes it; never append a paragraph that contradicts it.
   Delete a sentence the moment it is false.

## Memory files

These are the files agents load to work: `CLAUDE.md`, `AGENTS.md`, briefs, and notes.

1. Keep a line only if deleting it would cause a mistake.
2. Record only what the repository can't tell: commands that aren't obvious, constraints, and traps.
3. Write the instruction, then at most one clause of reason.
4. Put only universal rules in a file every session loads (`CLAUDE.md`, `AGENTS.md`), and task material in pages read on demand.
5. When a rule is ignored, rewrite or prune it; don't add a louder copy.
6. Delete a stale entry when you notice it.

## Layout

- One topic per heading, and no two headings alike in a page.
- One sentence per line.
- A line is at most 300 characters, a section at most 40 lines, and a page at most 40 kB.
- `AGENTS.md` is at most 12 kB, and `CLAUDE.md` at most 3 kB.
- An index line is a link and at most 12 words.
- Code identifiers go in backticks.

## Section markers

Each section of a reference page starts with one marker line under its heading:

    <!-- id: epub-headings; keys: EPUB, nav document, NCX; src: TextMouth/Parsers/EPUBParser.swift -->

- `id`: unique across all the docs, lowercase with hyphens, so a section can be named without its page.
- `keys`: at most 8 search words a reader might use that the text doesn't, such as a type, a menu command, or another name for the thing.
- `src`: the repository paths of the code the section describes, separated by commas, so a section leads to its code and a changed file leads back to its sections.
  Every path must exist.

## Where documents live

- `docs/user`, `docs/developer`, `docs/architecture`, `docs/agents`: the reference pages, indexed by `README.md` and `ARCHITECTURE.md`.
- `research/`: research, plans, designs, and specs, each dated and kept as written. They are a record, not a reference.
- The logs, where dates belong:
  - `TODO-2026-09-04.md`: every merge, and the open items;
  - `AGENT-NOTES-2026-10-04.md`: what agents left unverified;
  - `docs/agents/history.md`;
  - `docs/user/changelog.md`.
- `humanQuestions/`: questions for the user, and their answers. It is not in git.

## Tools

The `doc-library` skill (`.claude/skills/doc-library/`) finds a section by keyword, type, or code path. It also shows one section and checks the rules above.
Until it exists, search with `git grep`.
