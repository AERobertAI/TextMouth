# Imports: DAISY 3 books
<!-- id: imports-daisy-3-books; keys: DAISY, DTBook, talking book, OPF, SMIL; src: -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## DAISY 3 books of several DTBook files
<!-- id: daisy-3-books-several-dtbook; keys: talking book, NCX, wordless page, reading order, audio clip, WebArchiveReader, SSMLReader, page markers; src: TextMouth/Parsers/DAISYParser.swift, TextMouth/Parsers/DAISYParser+TextExtraction.swift, TextMouth/Parsers/DAISYParser+SMILParser.swift, TextMouth/Parsers/DAISYParser+OPFParser.swift, TextMouth/Parsers/DAISYParser+Audio.swift, TextMouth/Models/PageReaderVersions.swift, TextMouth/Parsers/TextutilDocumentReader.swift, TextMouth/Parsers/WebArchiveReader.swift, TextMouth/Parsers/BookParser.swift, TextMouth/Parsers/SSMLReader.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/Feeds/FeedTextConverter.swift -->

DAISY 3 books of several DTBook files, and SMIL clocks: DAISYParser reads the package's DTBook files in one fixed order, orderedDTBookPaths(of:opfPath:in:), the same on every launch since pages are numbered through that order:

1. the spine's own DTBook items, in spine order, when the spine lists any; else
2. the order the spine's SMIL files point at them, by the src of their text elements (DAISYSMILParser.parseTextReferences(), a conformant DAISY 3 spine lists SMIL files), then any DTBook no SMIL file points at, in the manifest's order; else
3. the manifest's document order, DAISYOPFResult.manifestOrder, which keeps the order the OPF lists the items in (an ID listed twice where it first appears), never the manifest dictionary's, whose order changed from one launch to the next.

A SMIL file that is missing or damaged orders nothing, so the files it would have pointed at come last, and a single file has no order to find, so no SMIL file is read.
DTBookToMarkdownConverter(pagesBefore:) takes the number of pages the files before it read, and DTBookConversion.pagesRead hands it on, so a page that holds no words is numbered by its place in the whole book (1, 2, then 3, 4, not 1, 2, 1, 2).
DAISY has its own page reader version, PageReaderVersions.current(for: .daisy) "1.0.1" (it shared "1.0.0" with PDF), so every stamped DAISY book is read again once at the next launch (see [Text caches and content indexes](text-caches.md)).
DAISYParser.parseTime reads a SMIL timecount, a number with ms, min, h, or s ("500ms" is 0.5, "2min" 120, "1h" 3,600), as well as "npt=38.228s", "0:02:43.650", and plain seconds.
Clips are measured at import, so only a DAISY book imported again gains the times, and no text changes, so no version was raised for it.
A web page named .doc (TextutilDocumentReader.extract), a web archive (MainPage.markdown(includesPages:)), and SSML honour includesPages: false, so a read "without pages" gives the text written before pages (PG09).
With pages, which every written cache has, the output is as before, so no book is read again.
FeedTextConverter has no pages flag and stays as it is, since dropping page-break numbers would make a feed article read a page number's text ("One 12two").
