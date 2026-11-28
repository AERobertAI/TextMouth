# Exports: a chapter nested too deeply
<!-- id: exports-deep-chapter; keys: nesting limit, FR24, Export as Written, as written, #5512, deep chapter; src: -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).
The walk and its writers are in [Exports](exports.md).

## The decision, the lines, and the question
<!-- id: export-deep-chapter-question; keys: ExportDeepChapterDecider, RawChapterLines, blocksAsWritten, ExportDeepChapterQuestioner, DeepChapterPrompt, ExportDeepChapterAlert, FR24; src: TextMouth/Services/Export/ExportDeepChapter.swift, TextMouth/Services/Export/ExportDocumentWalker.swift, TextMouth/Parsers/RawChapterLines.swift, TextMouth/Models/BookExportDeepChapterWording.swift, TextMouth/Platform/macOS/Views/Export/ExportDeepChapterAlert.swift, TextMouth/ViewModels/BookExportModel.swift, TextMouth/Services/BookExportService.swift -->

- The walk's decider: `Walk.blocks(ofSectionTitled:number:chaptersAfter:content:)` hands a chapter past the nesting limit to its ExportDeepChapterDecider, which answers `.writeAsWritten` or `.cancel`.
  `.cancel` throws CancellationError, so the export ends as Stop does: that book's text file is not written, no later file is, and the files already written stay.
  `.writeAsWritten` walks the chapter with `blocksAsWritten(of:)` instead, so no writer is handed any nesting.
  A chapter at the limit or under it is never asked about.
- RawChapterLines (Parsers) reads the chapter's lines without parsing them as Markdown:
  - a paragraph is the lines between blank lines, each trimmed of the spaces and tabs at its ends and joined by a line feed, a hard break in every writer;
  - a marker is a comment `MarkdownMarker.decode` reads, found anywhere in a line in one pass (a comment ends at its first "-->", and one that is no marker stays words);
  - a marker that begins a block is a place between blocks, any other a run of its own at its exact place, and the walk keeps either only where it keeps places;
  - words lose each backslash before an ASCII punctuation mark, and "&#xFEFF;" becomes U+FEFF, the one character reference MarkdownLiteral.escaped writes; no other reference is decoded.
  The reader's raw chapter and the Plain Text export take only the words, `RawChapterLines.readingText(of:)`, with a blank line between paragraphs and no marker or escape (B16).
  That moves the text offsets inside such a chapter: a saved place with words is carried by them (`PlaceRelocator`), and one saved before T06's anchors, with none, can land on other words.
- The question: BookExportService.export makes one ExportDeepChapterQuestioner for the whole export, so "every such chapter" holds for it alone, and gives each file a decider (`decider(for:filesAfter:)`; `textFileCounts(after:)` counts the text files still to walk).
  It asks again for each chapter until the answer is Export Every Such Chapter as Written, and offers that button when `filesAfter > 0 || chaptersAfter > 0`.
- BookExportModel's DeepChapterPrompt shows the question on the main actor while the export's thread waits (AsyncBridge.waitForResult).
  `put(_:through:over:unless:)` answers Cancel Export without asking when the export has stopped, and `stop()` calls the prompt's `dismiss()`.
  DeepChapterPrompting chooses it: `.standard` is the alert on the Mac and nobody on the iPhone, `.unavailable` is nobody (the refusal above, with its sentence), and `.custom` is a test's scripted prompt.
- ExportDeepChapterAlert (Platform/macOS) is an NSAlert whose words are BookExportDeepChapterWording's: Export as Written is the default button (Return), Cancel Export has Escape, and each button has a hint.
  It is a sheet on the Export dialog's window (`export(presentingFrom:)`, passed by BookExportSheet) when that is on screen and has no sheet, else a window of its own.
  The export's answer is resumed once, whichever of a button, `dismiss()`, and AppKit's completion comes first.
- On the iPhone the alert is `PhoneExportQuestion`, shown by the Export sheet (see [The Export sheet](../platforms-phone-interface.md#the-export-sheet)); `ExportDeepChapterWalkerTests` and `ExportDocumentWalkerNestingTests` are shared with the iPhone's unit bundle.
- Tests: ExportDeepChapterWalkerTests (the lines as written, with content.md as TextMouth writes it) and ExportDeepChapterExportTests (the decision, the question, the alert's buttons and presentation, and each format), none of which shows an alert.
