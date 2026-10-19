# Charter: team `export` (October 19, 2026)

Read `teams-common.md` beside this file first. You are `export-lead` (Opus), on `team/export`.

## The request, in the user's words
- Tonight: "Go ahead and try working on the braille reading features tonight. and the export feature".
- On October 17, when the user first asked for formats: "allow "exporting" any book (text or audio) to any other support format".
- The research's questions (`FORMATS-RESEARCH-2026-10-17.md`): read only section 7, from line 373 to the line before "### 7.5", and nothing else of it. The answer that bears on you:
  - Q21, the order of text export formats ("EPUB 3, then DOCX and RTF, with HTML along the way (it comes first, as the base) and PDF last"): "Yes, I thought markdown was the base, has that changed?"
  - It has not. Every writer starts from the book's `content.md`, the Markdown every text book becomes. HTML is the first writer made from it, not a new base. Say so in the code's comments where the walker is defined.

## Your items (`TODO-2026-09-04.md`: read only the lines `grep -n -E "^- \[ \] \*\*FMT(18|19) " TODO-2026-09-04.md` prints)
- **FMT18:** export with conversion. A Convert to choice in the Export dialog, a job runner, and HTML first, through TextMouth's own walker of `content.md`.
- **FMT19:** RTF with real outline levels, and Word 97-2003 (.doc) through Apple's writer.

FMT43 (speech to audio) is not yours tonight. Design the Convert to choice and the job runner so that an audio kind can gain one later (FMT30, FMT43), but build no audio conversion.

## Decisions already made (settled; do not reopen them, and say each in the code's comments where it applies)

### The dialog and the runner (FMT18)
1. **Where the dialog's code is.** Read these first, by line range:
   - `TextMouth/Services/BookExportService.swift` (861 lines; `BookExportKind` at about line 15);
   - `TextMouth/ViewModels/BookExportModel.swift` (378);
   - `TextMouth/Views/Export/BookExportSheet.swift` (162) and `BookExportPresentation.swift` (97);
   - `TextMouth/Models/BookExportWording.swift` (237).
2. **Each text kind that can convert gains a Convert to choice.** Today's "Text as Markdown" stays the default, so an export made as before gives the same file.
   - The choices are Markdown, HTML, RTF, and "Word 97-2003 (.doc)".
   - It is a picker beside the kind's checkbox, offered only while that kind is checked, with a label, a hint, and a spoken value.
   - Team `braille` adds BRF and PEF later, through item 6's interface.
   - Exporting several books gives each its own converted file, named as today's export names them. A name never replaces an existing file.
3. **The job runner.** A conversion runs off the main thread, one book at a time, under the dialog's existing progress ("progress(done:total:)") and Stop. A stopped export removes its half-written file.
   - VoiceOver hears each finish and each failure, in sentences pinned by tests, in the dialog's existing style (`finished(_:folderName:)`, `failureSentence(_:)`).
   - A conversion that fails names the book and why, and the other books still export.

### The walker and HTML (FMT18)
4. **One walker of `content.md`,** with swift-markdown 0.9.0 (already a package of the app, `project.yml` lines 24 to 26). It turns the book's Markdown into a small document model that every text writer reads. DRY: no writer parses Markdown itself.
   - **What the model holds:**
     - headings with their level, text, and a unique id;
     - paragraphs, as inline runs of plain text, emphasis, strong, code, and links (text and address);
     - ordered and unordered lists, with their items and nesting depth;
     - block quotes, code blocks, thematic breaks, tables (rows of cells, as text), and images as their alternative text.
   - **What it leaves out:** `content.md`'s own marker lines (read `TextMouth/Services/MarkdownCacheService.swift` and the Markdown export's code to learn their form: "a marker line before each chapter") never reach the output. Hand edits the user made reach it as the book reads them.
   - **Team `braille`** will turn headings, paragraphs, and list items into braille, so a block's plain text (its runs joined) must be one call away.
   - **Names that never change.** In your report, and in a note at `Scripts/agents/briefs/2026-10-19/export/interface-for-braille.md` (a brief-like note, allowed), give the model's type, its walker's entry point, and the writer interface (item 6). Team `braille` codes against them.
5. **HTML.** It is escaped XHTML that an XML parser accepts. It has:
   - `<!DOCTYPE html>`, the XHTML namespace, and `lang` and `xml:lang` from the book's language when it has one;
   - the book's title in `<title>` and in one `<h1>` only when `content.md` has none;
   - a contents list in a `<nav>` linking every heading by its id;
   - `h1` to `h6` with unique ids made from their text;
   - emphasis as `em` and `strong`, code as `code` and `pre`, and links with an `href` only for http, https, and mailto addresses (anything else becomes plain text);
   - images as their alternative text, never an `img` element pointing anywhere.
   - Escape `&`, `<`, `>`, and quotation marks in attributes. swift-markdown's `HTMLFormatter` does neither and drops heading ids, which is why TextMouth writes its own.
   - Tests pin exact output for a fixture and parse every output with `XMLParser`. Also: a heading text repeated three times gets three distinct ids, and `&`, `<`, and `>` in text and in a link's address are escaped.
6. **The writer interface.** A protocol, or an enum of conversions, with:
   - each writer's name as the picker says it, and its file extension;
   - its options, if any, with a SwiftUI view for them that the dialog shows under the picker when that writer is chosen (HTML and RTF have none tonight; braille's will have several);
   - a `write(document, options, to: URL)` that throws a sentence-shaped error.
   Adding a writer must be one new file and one registration line.

### RTF and .doc (FMT19)
7. **RTF from the walker.** It has:
   - a font table;
   - a style sheet with Normal and Heading 1 to 6, each heading carrying `\outlinelevelN` (level 0 for Heading 1) and also a larger size and bold, so readers that ignore styles (textutil, TextMouth's own FMT13 reader) still see headings;
   - emphasis as `\i` and `\b`;
   - every character above 127 as `\uN` with a `?` fallback, negative N for code points above 32767 as RTF requires, and characters above U+FFFF as their two UTF-16 halves;
   - `\`, `{`, and `}` escaped.
   - **Tests:**
     - pin the exact RTF for a fixture;
     - read the output back with `NSAttributedString` (its `.rtf` document type), and the text must match;
     - **a round trip through TextMouth's own reader:** import the exported RTF with `TextutilDocumentReader` (the textutil child process) in a test, and the headings must come back as headings, with the same levels for at least three levels.
   - The sample `TestData/format-samples/rtf/word-styles.rtf` shows the form to write.
8. **Word 97-2003 (.doc)** through `NSAttributedString`'s `.docFormat` writer, from an attributed string the walker builds (headings larger and bold).
   - The picker's hint says its headings are plain text in Word, for example: "Word 97-2003 document. Its headings are plain text, so Word's navigation pane does not list them."
   - Writing Word's binary format ourselves is not done.
   - Test: the output reads back with `NSAttributedString` (`.docFormat`) with the same text.

## Files and areas
- **Yours:**
  - every `BookExport*` file;
  - `TextMouth/Views/Export/`;
  - the new walker, the model, and the writers, under `TextMouth/Services/Export/` or a folder you name in your briefs;
  - their tests.
- **Team braille's:** liblouis, the braille readers and layout, the Braille settings tab, `BookFormat`, `XMLDocumentSniffer.swift`, `BookParser.swift`, `Info.plist`, and `project.yml`. You need none of them. If you must add a file to `project.yml`'s sources, say so on the board first; XcodeGen picks up new files in existing folders by itself.
- **Test classes:** your new ones, plus the existing export classes (`grep -ln "BookExport" TextMouthProductionTests/*.swift`), `KeyboardReachabilityTests` for the new picker, `LogContentPolicyTests` if you add a log tag, and the `sheets` area, which holds the export dialog's tests (`Scripts/test/areas.conf` line 403).

## The report
Teams-common's form, plus:
- the interface note's path;
- every new sentence, label, hint, and caption.
