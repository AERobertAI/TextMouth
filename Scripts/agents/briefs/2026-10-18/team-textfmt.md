# Team textfmt: RTF, Word 97-2003 and its template, OpenDocument, web archives, SSML, and DTBook

Read `Scripts/agents/briefs/2026-10-18/teams-common.md` first: it is the pattern you follow, and it stands in for AGENTS.md. You are the lead, `textfmt-lead`, on branch `team/textfmt` made from `main`. Your workers' briefs go in `Scripts/agents/briefs/2026-10-18/textfmt/`.

## What the user asked (in their words)

October 17: "for text I am especially interested in adding rtf, dot, .doc, and braille .brf / .brl files". October 18: "go ahead and send some teams to work on implementing the easy sets of formats, maybe choose 5-10 to start with or to do and pollish today if possible". Their answer to the research's question 1 (textutil, with headings found from font sizes): "Do this for now, I would personally like the ability to keep bold and other formatting if possible for non heading text in case one day we might want to add the ability to speak differently formatted text like with a different pitch or something." And to question 18: Markdown stays the internal base of every text book.

## Your items, in order of priority

Each has an entry in `TODO-2026-09-04.md` (`grep -n "FMT13 —" TODO-2026-09-04.md`, and so on) and a section in `FORMATS-RESEARCH-2026-10-17.md`. Read those, and no other part of either document.
1. **FMT13: RTF, RTFD, Word 97-2003 .doc and its template .dot, ODT, OTT, and WordML, through Apple's `textutil`.** Research sections 2.1 to 2.4, 2.6, and 2.7. This is the user's own wish, and it comes first.
2. **FMT01: .dotx, .docm, and .dotm through TextMouth's own Word reader.** Section 2.5.
3. **FMT03: Safari web archives (.webarchive).** Section 2.7.
4. **FMT07: SSML files, imported as text.** Section 6.5.
5. **FMT04: a DTBook file on its own (.xml), and a NIMAS package.** Section 2.8.

The samples are in `TestData/format-samples/<folder>/` (rtf, rtfd, doc, dot, dotx, docm, dotm, odt, ott, wordml, webarchive, ssml, dtbook), listed in `samples.tsv` with their sources.

## What every item must do

- **A book like any other.** It imports by Open Book…, by dragging it onto the Library, and by opening it from the Finder (the app's document types in `TextMouth/Resources/Info.plist`, around line 280, and `FileImportService.supportedTypes` at `FileImportService.swift:2043`). Its title and author come from the document where it names them, and from the file's name otherwise, as for the other formats (`FileImportService.swift:140-180`). It reopens, searches, and keeps its place, bookmarks, and skipped headings like any text book.
- **Markdown is the base.** Each format becomes Markdown through the pieces that exist. `HTMLToMarkdownConverter` (`TextMouth/Parsers/HTMLToMarkdownConverter.swift`) takes HTML, and `MarkdownCacheService` regenerates a book's Markdown from its kept original (`MarkdownCacheService.swift:405-435`), so headings, lists, and tables read as they do in the other formats. `BookParser.parse` (`BookParser.swift:10-35`) is the direct reader. Find every other `switch` over `BookFormat` with `grep -rn "case \.docx" TextMouth`.
- **A new `BookFormat` case is a stored raw value.** `BookFormat` (`TextMouth/Models/Book.swift:18`) is written into the library index by its raw value and decoded strictly (`Book.swift:345`). An older build that meets an unknown value cannot read the library: it keeps the file, quarantines a copy, and suspends index writes (`LibraryPersistenceService.swift:1265-1345`), so nothing is lost, but it cannot open the library. Rules:
  - Never change an existing raw value.
  - Formats that share a reader may share a case only where the listener loses nothing: Book Info names the format through `displayName`, so a .doc must not be called "Rich Text".
  - Your report names each case you added and why.
- **Apple's document readers run only in a child process.**
  - `/usr/bin/textutil` runs under `WatchedProcess.run` (`TextMouth/Services/WatchedProcess.swift:234`; see how `OggAudioConverter.convert` uses it, `OggAudioConverter.swift:286-355`).
  - It runs with a processor-time limit and a wall-clock limit sized to the file, and nothing of it is left running when TextMouth quits.
  - Never read a .doc, RTF, ODT, or WordML file with `NSAttributedString` in TextMouth's own process: a hang or crash in Apple's readers must cost a child process, never the app or the import.
  - Pass `-noload`, so textutil loads no subsidiary resource and fetches nothing from the network (check `man textutil`).
  - Give textutil the input format where an extension could lie.
  - Its output goes to a temporary file in the import's staging folder (`TextMouth/Services/ImportStaging.swift`), which is removed afterwards, also when the import fails or is cancelled.
  - Regenerating the Markdown of an existing book runs the same watched path, off the main thread, as DOCX's regeneration runs today (find where).
- **Your own readers** (web archive, SSML, DTBook, the .xml sniff) resolve no external entity and load nothing from the network. Each caps the bytes it reads and refuses beyond the cap with a sentence.
- **Refusals in the existing form.** An empty, unreadable, password-protected, or oversized file is refused as the empty EPUB and the empty Markdown file are refused today (`grep -rn "holds no text\|is empty\|empty" TextMouth/Services/FileImportService*.swift` to find the messages). The message names the file, never a hidden file or a path. Pin each message in a test.
- **Tests.**
  - Each sample imports with its headings and text, through the import path, from a copy in the test's own temporary folder.
  - Each refusal is tested, and so are the time limit (with a stand-in tool that hangs, as the Ogg tests do: `OggAfconvertTests`) and the staging cleanup.
  - Name in your briefs `BookFormatTests`, `ImportAndShortcutPolicyTests`, `IntegrationImportTests`, `ImportStagingTests`, `ImportFuzzTests`, `DOCXStructureTests`, `DOCXMalformedXMLTests` (FMT01), `DAISYPackageImportTests` and `DAISYMalformedXMLTests` (FMT04), the HTML converter's tests (`grep -l HTMLToMarkdownConverter TextMouthProductionTests/*.swift`), and `LogContentPolicyTests` and `UncheckedConcurrencyPolicyTests` wherever a log tag or an unchecked type is added.
- **Reusable test tools.** Add the new formats' samples to the document goldens (`Scripts/test/update-goldens.sh`, read its `-h`) and to the import fuzz's corpus (`Scripts/test/import-fuzz.sh`, `make-corpus.py`), if they take lists. That way, a later change to a reader shows up as a diff.

## Item notes

- **FMT13, headings from font sizes.** textutil's HTML gives every heading as a bold or larger paragraph, even from Word's heading styles and ODT's text:h (verified). Add one pass over textutil's HTML, before `HTMLToMarkdownConverter`, as research section 2.2 describes:
  - The body size is the commonest size by characters.
  - A short paragraph that is larger, or bold alone on its line, becomes a heading, its level by its size's rank, at most 6 levels.
  - Edge cases, each with a test: a document with no larger text (no headings, read as today's headingless text is); every paragraph bold; one huge decorative letter; text in table cells and list items, which never becomes a heading; a long bold paragraph, which stays a paragraph; and the real Word files in `doc/` with Heading 1 to 6.
- **FMT13, bold and italic in body text** (the user's answer). Find what the pipeline does with emphasis today: `HTMLToMarkdownConverter`, `DOCXParser+Converter.swift`, and how the reader and the speech treat Markdown emphasis.
  - If emphasis already survives as Markdown that is shown and never spoken as symbols, keep it for these formats in the same way.
  - If it survives nowhere, leave it out today, and report what keeping it would take.
  - The listener must never hear "asterisk".
- **FMT13, the others.** An .rtfd is a package: it imports as one book, never as a folder of files. A .dot reads exactly as a .doc. WordML is an .xml file whose root is `w:wordDocument`.
- **One .xml sniff** (FMT04 with FMT13): one function reads the start of an .xml file and names its kind: DTBook (root `dtbook`) goes to the DAISY reader, and WordML goes to the textutil path. Any other XML is refused by name, in the existing refusal form. `BookFormat.detect(from:)` (`Book.swift`, after line 70) already has special cases; put the sniff there or beside it, never by extension alone.
- **FMT04.** The DAISY reader already reads DTBook inside a DAISY 3 package, and in a ZIP or folder without an OPF: give it a one-file provider for a loose DTBook file. The NIMAS package (`dtbook/nimas-style-package/`) should import today: add the test, and fix it if it does not import.
- **FMT01.** Add the extensions where .docx is listed, and the document types with their UTIs (check what `UTType(filenameExtension:)` knows). Test that each sample opens with its headings and that no part of a macro project is read.
- **FMT03.** Read the archive with `PropertyListSerialization` (never WebKit). Take `WebMainResource` alone, its `WebResourceData` decoded by `WebResourceTextEncodingName`, and refuse a main resource that is not HTML or text. Ignore subframes and subresources. Hand the HTML to the HTML path.
- **FMT07.** An .ssml file becomes a text book, its markup removed and its paragraphs and sentences kept. It is never handed to the speech engine as SSML, nor as text with tags: `AVSpeechUtterance(ssmlRepresentation:)` crashed the research probe on every emphasis element, and `ssml/passage.ssml` holds that emphasis on purpose. Section 6.5 says what each element becomes (`sub`, `say-as`, `phoneme`, `break`, and `audio`, whose source is never fetched).

## Regions

You own:
- `Book.swift`'s `BookFormat`, except the `.audio` case's extension list and its doc comment, which team audiofmt owns;
- `BookParser.swift`, `MarkdownCacheService.swift`, `HTMLToMarkdownConverter.swift`, `HTMLParser.swift`, `DOCXParser*.swift`, `DAISYParser*.swift`, and `TextFileDecoder.swift`;
- in `FileImportService.swift`, the metadata `switch`, the text formats' dispatch, and the text entries of `supportedTypes`;
- the text formats' document types in `Info.plist`;
- new files for your readers and the textutil runner.

Team audiofmt owns `WatchedProcess.swift`, `OggAudioConverter.swift`, `OggHeaderReader.swift`, `FileImportService+Ogg.swift`, `FileImportService+Packages.swift`, `AudioMediaProbe.swift`, `AudioBookParser.swift`, `AudioManifest*.swift`, the import settings, and the audio entries in the shared files. You use `WatchedProcess.run` as it is; if you need it changed, post a finding to `audiofmt-lead` and agree who changes it. Both teams add lines to `Book.swift`, `FileImportService.swift`, `Info.plist`, and the test tools' lists:
- keep your additions in blocks of your own;
- never reformat a neighbour's line;
- the orchestrator settles any conflict at the merge.

No `*.md` file but your briefs: the user documents (`docs/user/what-textmouth-reads.md`, `adding-books.md`) are updated after the merge from your report.

## Your report

As `teams-common.md` says, and also:
- the cases you added to `BookFormat`;
- each item's number and whether it was done;
- the exact words of every new message a listener hears;
- textutil's times on the samples, and the limits you chose;
- what you found about bold and italic;
- questions for the user, each with a recommended answer;
- the sentences the user documents need.
