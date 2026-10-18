# Documentation pass docs18: the October 18 format merges

You are `docs18`, a documentation agent. You build nothing and run no tests. Your current directory is your own git worktree of the TextMouth repository, a native macOS text-to-speech and audiobook player.

## Setup

Your worktree starts at `origin/main`, which is far behind local `main`. First run `git checkout -b docs/oct18 main`, then check that `git merge-base --is-ancestor cfa0241d HEAD` succeeds.

## The task

Document the merges of October 18 in the documentation pages, from the wording their teams left and from the merged code:
- `README.md` and `ARCHITECTURE.md`, which are indexes: change them only where an index line becomes false or a new page needs a line;
- the pages under `docs/`: `docs/user` for the person using the app, `docs/developer`, and `docs/architecture`.

Edit no other file. Make one commit per documented merge:
1. **Now: team/textfmt** (merge fcb30520). Its notes are under "## From the textfmt team" in `AGENT-NOTES-2026-10-04.md`; find the line with `grep -n "^## From the" AGENT-NOTES-2026-10-04.md`, then read the section with `sed -n`. Its wording is below.
2. **Later: team/audiofmt.** It has not merged yet. When it has, the orchestrator sends you a message with its merge hash and wording. Until then, leave every audio passage as it is. That includes the Ogg sentence "so it stays about the same size and sounds no worse" in `docs/user/what-textmouth-reads.md`, which the audio commit corrects.

After commit 1, send your report (the form is at the end) and stop.

## How to write

- **Check each sentence against the merged code before you place it.** A quick `grep` of the label, number, or sentence is enough. Where the wording below and the code differ, the code wins: fix the sentence and say so in your report.
- **Correct what the merge made false.** For example, a page may say that TextMouth reads Word documents only as .docx, or that an .xml file is never imported.
- **Match each page's style and level of detail.**
  - The user is blind and reads these pages with VoiceOver and a braille display.
  - Write plain, exact sentences. Use headings and lists that navigate well, and nothing that relies on sight.
  - Quote the words a listener hears exactly, in the pages' own quotation marks (“ ”).
- **Say each fact once.** Put it on the page where it belongs, and link to it from the others.
- **Keep the run lean.** Read files by line range, put several patterns in one `grep`, and make independent calls in one response.
- **Usage.** Read only the "5-hour session" and "Weekly (all models)" windows of `python3 ~/.claude/skills/claude-usage-left/scripts/claude_usage.py --brief`; "Weekly (Fable)" does not apply. Stop and report if "Weekly (all models)" falls to 66% left.
- **Rules.**
  - Never push, and never merge into `main`.
  - Each commit message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
  - Write Markdown only.

## Commit 1: team/textfmt (FMT13, FMT01, FMT03, FMT07, FMT04)

### What landed

**New formats read as text books.** Each becomes Markdown, as every other text book does, so it reopens, searches, and keeps its place, bookmarks, and skipped headings like any of them.

- **Read by Apple's textutil** (`TextutilDocumentReader`, `TextutilConverter`, `TextutilHTMLStructure`, `TextutilSourceCheck`):
  - formats:
    - rich text (.rtf);
    - rich text with attachments (.rtfd, a package the Finder shows as one file; it imports as one book);
    - Word 97-2003 documents (.doc) and templates (.dot);
    - OpenDocument text (.odt) and its templates (.ott);
    - Word 2003 XML (.xml).
  - **A watched child process.** textutil runs in a separate process that TextMouth watches, never inside TextMouth: a hang or crash in Apple's readers costs that process, never the app or the import.
    - It is stopped after 30 seconds plus one second for each million bytes, at more than 1 GB of memory, or at processor time four times the time allowed (`TextutilConverter.limits(forBytes:)`).
    - It loads nothing a document links to (`-noload`) and fetches nothing from the network.
    - It runs once for each import, and the book's title and author come from that same run.
    - Cancel stops it; the import then ends as cancelled, with no alert.
  - **Headings come from font sizes and bold.**
    - The body size is the commonest size, counted by characters.
    - A paragraph of at most 120 characters that is larger than the body, or bold on its own when most of the body is not bold, becomes a heading.
    - Its level comes from its size's rank, in at most six levels.
    - Text in table cells and list items never becomes a heading.
  - **Bold and italic** in body text are kept as emphasis, as in the other text formats, and their marks are never spoken.
  - **Pictures and Word fields.** Pictures are silent. A Word field's instruction is never read; its visible result is.
  - **Content decides, not the extension.**
    - A file whose content is RTF is read as RTF, whatever its extension.
    - A .doc that is really HTML or Word 2003 XML is read as what it is: HTML by TextMouth's own HTML reader.
- **Word templates and macro documents** (.dotx, .docm, .dotm): read by TextMouth's own Word reader, as a .docx is, and listed as Word documents. No part of a macro project is read, and no macro ever runs.
- **Safari web archives** (.webarchive, `WebArchiveReader`):
  - Only the archive's main page is read, through the HTML path (or the text path for a text page), so its headings, lists, and tables read as in an HTML book.
  - Its pictures, scripts, style sheets, and frames, and every address it names, are never read, decoded, or fetched. WebKit is not used.
  - A page labelled ISO-8859-1 or ASCII is read as Windows-1252, the rule `TextFileDecoder` uses everywhere.
- **SSML files** (.ssml, `SSMLReader`):
  - They are read as text: the markup is removed, and the paragraphs and sentences are kept.
  - A `sub` element's alias is read in place of its written text: `<sub alias="World Wide Web Consortium">W3C</sub>` reads "World Wide Web Consortium" (question 1 in `humanQuestions/2026-10-18.md`, built as recommended).
  - The text of `desc`, `meta`, `metadata`, and `lexicon` elements is left out.
  - An `audio` element's sound file is never read or fetched.
  - A break, a change of voice, or a sentence's start keeps the words on either side of it apart.
  - The file is never given to the speech engine as SSML: `AVSpeechUtterance(ssmlRepresentation:)` ignores the book's rate and crashed on an emphasis element during the research.
- **DTBook and NIMAS** (`XMLDocumentSniffer`, `DAISYParser+DTBookHeadParser`):
  - A DTBook file on its own (.xml) imports as a book; so does a NIMAS package.
  - One check reads the start of every .xml file and names its kind: a DTBook goes to the DAISY reader, and Word 2003 XML goes to textutil.
  - Any other XML is refused by name.
- **Size cap.** Every one of these documents is refused beyond 64 MB (`DocumentByteLimit`, the same limit as a text file inside a book's archive).
- **In the Finder.** These formats are document types (`TextMouth/Resources/Info.plist`), so TextMouth is offered in the Finder's Open With menu for them. It is offered for every .xml file too. Like every other type but its own .tmb packages, they are at Alternate rank: TextMouth is never their default app (question 2, built as recommended).
- **An older TextMouth can't open the library.** The library stores each book's format by name, and new names were added (`BookFormat`: `rtf`, `rtfd`, `doc`, `odt`, `wordml`, `webarchive`, `ssml`).
  - A TextMouth built before this merge can't open a library that holds one of these books. It keeps the library's file untouched, saves a copy aside, and writes nothing to the library, so nothing is lost.
  - Check `LibraryPersistenceService.swift` around lines 1265 to 1345, and say this where the pages describe the library file and older versions, if they do.

### What a listener hears

Each refusal comes after the import's own words, as in “Could not import “Letter.doc”. Reading its text failed: …”. Check the step's words in the code (`ImportFailure`), and use the form the pages already use for refusals (`docs/user/adding-books.md`, around line 25).
- “This document holds more than 64 MB, the most TextMouth reads from one document.”
- “This file could not be read as a rich text document.” The same sentence names each of the other kinds: “a rich text document with attachments”, “a Word 97-2003 document”, “an OpenDocument text document”, and “a Word 2003 XML document”. After it comes “It may be damaged, or another kind of file.” Check the exact words in `TextutilConverter.swift` around line 75.
- “TextMouth stopped reading this document because …”, followed by the watchdog's reason (`WatchedProcess.KillReason.words`).
- “This document is protected by a password. Save a copy without the password, then import that copy.”
- “This XML file is neither a DTBook book nor a Word 2003 XML document, the kinds of XML file TextMouth reads.”
- “This web archive holds a file of the type “image/png”, not a web page or text, so it has nothing to read.” The type is the one the archive names.
- “This file is not a web archive TextMouth can read. It may be damaged, or another kind of file.”
- “This file is not SSML: it begins with the element “html”, not “speak”.”
- “This SSML file is damaged or incomplete: …”
- A blank DTBook, or an empty or blank .xml file: “This file has no text to read.”
- **An .rtfd's original is never deleted or offered for deletion,** since it is a folder. When “After Importing a Book” is set to delete the original or to ask each time, the import says “The original file was kept: it is a folder, and an import never deletes a folder.” Question 4 recommends keeping this; see `FileImportService.swift` around line 102.

### For the library and the debug log

- **Log tags.**
  - `TEXTUTIL_KILLED`: textutil was stopped at a limit.
  - `TEXTUTIL_FAILED`: textutil failed.
  - `IMPORT_CANCELLED`: an import was cancelled.
  - `TEXTUTIL_LEFTOVERS_SWEPT`: at launch, TextMouth stopped textutil processes that an earlier run left behind, and removed their working folders. This is `OrphanedConversionSweep+Textutil.swift`.
- **Where these belong.** `docs/user/where-your-library-lives.md` describes the Ogg converter's process and its sweep, around lines 87 to 89. Put textutil's process and its sweep beside them, without changing the Ogg sentences.

### Architecture (docs/architecture)

- **The path of a textutil format:**
  1. `TextutilSourceCheck`: the password check, and the check that the content is what the extension says.
  2. `TextutilConverter`: the watched child process.
  3. `TextutilHTMLStructure`: pictures, field instructions, bullet lists, and headings.
  4. `HTMLToMarkdownConverter`.
- **The pieces around it.**
  - `TextutilDocumentReader` is the entry point.
  - `XMLDocumentSniffer` routes each .xml file.
  - `WebArchiveReader` and `SSMLReader` hand HTML to the HTML path.
  - `DocumentByteLimit` caps them all.
  - The import's textutil output is kept in its staging folder, and removed with it.
- **Where it goes.** Find the page that owns importing and parsing (`ARCHITECTURE.md` lists the pages), and add only what a developer needs to find their way.

### Developer pages (docs/developer)

- **The document goldens** (`Scripts/test/update-goldens.sh`) now include the new formats' samples, except two held back in `TextPipelineFixtures.formatSamplesHeldBack`. The goldens are compared only on the same major macOS version.
- **The import fuzz.** Its sweep over the 21 new samples ran 351 cases with no violation.
- **`make-corpus.py`** has no generators for the new formats yet. That is a TODO follow-up.
- Say this only where those tools are documented.

### The team's own summary sentence (for README-level wording, if an index line needs it)

"TextMouth reads RTF and RTFD, Word 97-2003 (.doc and .dot), Word templates and macro documents (.dotx, .docm, .dotm, whose macros never run), OpenDocument text (.odt, .ott), Word 2003 XML, Safari web archives, SSML files as text, and DTBook .xml files. Apple's textutil reads RTF, Word 97-2003, OpenDocument, and Word 2003 XML in a separate process, and headings are found from font sizes and bold."

## Your report (at most 25 lines)

- The branch, and each commit's hash and subject, with the pages it changed.
- Every sentence you changed from this wording to match the code, and why.
- Any wording you could not place.
- Anything a page said that you found false and corrected.
