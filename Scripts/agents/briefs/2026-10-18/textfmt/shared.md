# Team textfmt: what every worker shares (October 18, 2026)

Read this, "The worker's part" and "Rules for everyone" of `Scripts/agents/briefs/2026-10-18/teams-common.md`, and your own brief. Nothing else unless your brief names it. Your lead is `textfmt-lead`; the team is `textfmt` (channel `team:textfmt`).

## What the team builds

New text formats for TextMouth, a native macOS text-to-speech and audiobook player whose user is blind and uses VoiceOver and a braille display: RTF, RTFD, Word 97-2003 .doc and .dot, OpenDocument .odt and .ott, and Word 2003 XML (WordML) through Apple's `/usr/bin/textutil` in a watched child process (FMT13); .dotx, .docm, and .dotm through TextMouth's own Word reader (FMT01); Safari web archives (FMT03); SSML files as text (FMT07); and a DTBook .xml file on its own (FMT04). Markdown is the base of every text book: each format becomes HTML or Markdown that `HTMLToMarkdownConverter` (`TextMouth/Parsers/HTMLToMarkdownConverter.swift`) and the Markdown parser read as they read every other format.

The work comes in waves. The first wave's tasks each build one piece in files of its own, with unit tests; later tasks wire the pieces into `BookFormat`, the import, and the reader. Never wire your piece into a file your brief does not name.

## What is already on the team branch

- `TextMouth/Parsers/DocumentByteLimit.swift`: `DocumentByteLimit.standard` (64 MB), `DocumentByteLimit.current` (a `@TaskLocal` a test binds smaller with `DocumentByteLimit.$current.withValue(_:operation:)`), `DocumentByteLimit.check(byteCount:)`, and `DocumentByteLimit.contents(of:)`, which refuses an empty file with `FileImportError.noTextToRead` ("This file has no text to read.") and one past the limit with `DocumentTooLargeError` ("This document holds more than 64 MB, the most TextMouth reads from one document."), before reading it. Every reader of the team takes its bytes through it. A detached task does not inherit the task-local, so check sizes before any `AsyncBridge` or `Task.detached` hop.
- `TextMouthProductionTests/FormatSampleFixtures.swift`, an `XCTestCase` extension: `formatSampleURL(_:)`, `copyOfFormatSample(_:named:)` (copies a sample, file or folder, into a sandbox folder removed at teardown, optionally under another name), `importedForTest(_:)` (imports through `FileImportService.importFileWithReport` and removes the package at teardown), `openedContent(of:)` (what the reader shows, through `BookContentAnalysisService.load`), `headingLines(of:)` ("level: text" per heading), and `allText(of:)`. Use them; do not write your own copies.

## The samples

`TestData/format-samples/<folder>/`, listed with their sources in `samples.tsv`. They came partly from outside, so they are untrusted input. A test copies a sample into its own sandbox folder (`copyOfFormatSample`) before it reads or imports it, and never changes the samples' folder.

| Folder | Files |
| --- | --- |
| rtf | headings.rtf, word-list-table.rtf, word-styles.rtf (headings-source.html is the HTML the others were made from) |
| rtfd | headings.rtfd (TXT.rtf only), with-image.rtfd (TXT.rtf and Attachment.png) |
| doc | headings.doc, libreoffice-tdf104239_chapterNumbering.doc (real Word: Heading 1 to 6), libreoffice-tdf81705_outlineLevel.doc |
| dot | headings-synthetic.dot (template bit set), libreoffice-tdf120761_zOrder.dot |
| dotx, docm, dotm | headings-synthetic.* and one real LibreOffice file each |
| odt, ott | handwritten.odt (real text:h), headings.odt; handwritten.ott |
| wordml | headings.wordml (WordML; imports only under an .xml name) |
| webarchive | headings.webarchive |
| ssml | passage.ssml (holds an emphasis element on purpose) |
| dtbook | harbour-standalone.xml, nimas-style-package/ (harbour-nimas.opf, harbour-dtbook.xml) |

## Building and testing

- Build and test only with `python3 Scripts/test/run-area.py <ClassNames>` (read its `-h`; pass `--derived-data /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-<your slug>` and `--log` to a file in the session's scratchpad named with your slug), started in the background, checked no more often than every 4 minutes. Set `BBS_AGENT=<your slug>` in its environment.
- A new Swift file (app or tests) needs `/opt/homebrew/bin/xcodegen generate`, and the regenerated `TextMouth.xcodeproj/project.pbxproj` committed with it.
- Run your brief's classes, then `make lint-tests LINT_BASE=team/textfmt` before you report, and say both results in your report.
- Python tools write no bytecode (`sys.dont_write_bytecode = True`); edit files in place with Python or `gsed -i`, never two heredocs on one command line.

## Rules the team adds

- **Never read a .doc, RTF, ODT, or WordML file with `NSAttributedString`, `NSTextStorage`, or WebKit in TextMouth's own process**, in the app or a test: a hang or crash in Apple's readers must cost a child process. Tests read such files only through the code under test.
- **Your own XML readers resolve no external entity** (`shouldResolveExternalEntities = false`, as `PackageSAXParser` sets it) and nothing anywhere loads from the network.
- **Every sentence a listener hears is pinned by a test, word for word.** A refusal reads as the existing ones do: `ImportFailure` puts "Could not import “<file name>”. <Step> failed: " before your error's sentence, so your sentence never names the file, a hidden file, or a path.
- **Comment every type, function, and non-obvious block** in the style of the files around you: what it is for and why, in plain sentences.
- **Do not touch** `WatchedProcess.swift`, `OggAudioConverter.swift`, `OggHeaderReader.swift`, `FileImportService+Ogg.swift`, `FileImportService+Packages.swift`, `AudioMediaProbe.swift`, `AudioBookParser.swift`, `AudioManifest*.swift`, or the `.audio` case of `BookFormat` and its doc comment: team audiofmt owns them. Never reformat a line you do not change.
- Commit messages: a subject line under 72 characters in the imperative, a body saying why, and the trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
