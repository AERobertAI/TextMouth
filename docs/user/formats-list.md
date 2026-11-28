# Every format TextMouth reads, and how well
<!-- id: formats-list; keys: supported formats, file types, extensions, test levels, quality of support, iPhone; src: TextMouth/Models/Book.swift, TextMouth/Services/ImportAudioConverter.swift, TextMouth/Phone/PhoneImportRefusal.swift, TextMouth/Resources/Info.plist, TestData/format-samples/samples.tsv -->

Part of [TextMouth's documentation](../../README.md).

This list names every kind of file that TextMouth imports, in groups, with what it gets from each, whether the iPhone app reads it too, and how well it is tested.
The pages that begin "What TextMouth reads" describe each kind in detail, and each group below links to them (start with [What TextMouth reads](what-textmouth-reads.md)).
Adding a line: put it in its group, in the order name, extensions, what TextMouth gets, iPhone, level.

## How to read a line
<!-- id: formats-list-how-to-read; keys: Well tested, Tested with real files, Tested with made samples, Basic, test level; src: TextMouth/Models/Book.swift, TestData/format-samples/samples.tsv, TestData/golden, TestData/soup-corpus/manifest.tsv -->

Each line names the format and its extensions, then what TextMouth gets from it, then "iPhone", then its level.
The level is one of four, and it says how well tested a format is, not how good its reading is:

- Well tested: used every day by the developer, which is EPUB, HTML, and Markdown, and MP3 and M4B audiobooks.
- Tested with real files: tests read real-world files made by other people's programs, such as the files in `TestData/golden`, the Project Gutenberg and Standard Ebooks books, and the files taken from the LibreOffice, Apache POI, and libmobi test collections.
- Tested with made samples: tests read only small files made for them, or made on this Mac by another program from a source text.
  `TestData/format-samples/samples.tsv` says where each came from.
- Basic: the format imports, with few tests, or with limits that the line names.

"iPhone: yes" means the iPhone app imports the format with the same reader as the Mac.
"iPhone: no" means it refuses the file.

## Text files
<!-- id: formats-list-text-files; keys: TXT, Markdown, PDF, SSML, plain text; src: TextMouth/Parsers/PlainTextParser.swift, TextMouth/Parsers/MarkdownParser.swift, TextMouth/Parsers/PDFTextParser.swift, TextMouth/Parsers/SSMLReader.swift, TextMouth/Parsers/TextFileDecoder.swift -->

Details: [Text, HTML, and PDF files](reads-text-files.md) and [Pages](reads-pages-and-limits.md).

- Markdown (.md, .markdown): text, headings, lists, tables, emphasis, and pages where it holds page lines; iPhone: yes; Well tested.
- Plain text (.txt): text in any common encoding, which TextMouth recognizes or lets you choose, and pages from form feeds; no headings; iPhone: yes; Tested with real files.
- PDF (.pdf): text, headings from the PDF's outline and font sizes, pages with the PDF's page labels, and recognized text for a scanned page; iPhone: yes; Tested with made samples.
- SSML (.ssml): text, with the speech markup it holds, and no pages; iPhone: yes; Tested with made samples.
- Picture (.png, .jpg, .jpeg, .heic, .heif, .tif, .tiff): the words on the page, found by text recognition, with a chapter for each page of a TIFF that has text; iPhone: yes; Tested with made samples.
- Comic book archive (.cbz): the words on each picture, a chapter for each page, with the title, writer, and cover titles of its ComicInfo.xml; .cbr is not read; iPhone: yes; Tested with made samples.

## Web pages
<!-- id: formats-list-web-pages; keys: HTML, XHTML, Safari web archive, webarchive; src: TextMouth/Parsers/HTMLParser.swift, TextMouth/Parsers/WebArchiveReader.swift, TextMouth/Parsers/HTMLToMarkdownConverter.swift -->

Details: [Text, HTML, and PDF files](reads-text-files.md).

- HTML (.html, .htm, .xhtml): text, headings, lists, tables, emphasis, and pages from page-break marks; iPhone: yes; Well tested.
- Safari web archive (.webarchive): the archived page's text, read as HTML; iPhone: yes; Tested with made samples.

## Ebooks
<!-- id: formats-list-ebooks; keys: EPUB, Kindle, MOBI, AZW3, KF8, KFX, PRC, copy protection; src: TextMouth/Parsers/EPUBParser.swift, TextMouth/Parsers/MOBIParser.swift, TextMouth/Parsers/KF8Book.swift, TextMouth/Parsers/KFXParser.swift, TextMouth/Parsers/KFXError.swift, TextMouth/Parsers/MOBIError.swift -->

Details: [Kindle books](reads-kindle-books.md), and [Pages](reads-pages-and-limits.md).

- EPUB (.epub), versions 2 and 3: text, chapters and headings, page lists, title, author, and the rest of its metadata; iPhone: yes; Well tested.
- Kindle MOBI 6 and PalmDOC (.mobi, .prc, .azw): text, chapters, emphasis, title, and author; iPhone: yes; Tested with real files.
- Kindle KF8 (.azw3, or a .mobi that holds KF8), and a hybrid file that holds both: the same, and pages; iPhone: yes; Tested with real files.
- Kindle KFX (.kfx, .kfx-zip, .azw8): text, chapters, headings, pages, emphasis, lists, and tables; iPhone: yes; Tested with made samples.
- Kindle Create package (.kpf): refused with its own sentence, since TextMouth can't read it yet; iPhone: no.
- Copy-protected Kindle books, in any of the formats above, are refused and never read.

## Office documents
<!-- id: formats-list-office-documents; keys: Word, DOCX, DOC, RTF, RTFD, ODT, WordML, textutil; src: TextMouth/Parsers/DOCXParser.swift, TextMouth/Parsers/WordDocumentReader.swift, TextMouth/Parsers/RTFDocumentReader.swift, TextMouth/Parsers/ODTDocumentReader.swift, TextMouth/Parsers/WordMLDocumentReader.swift, TextMouth/Parsers/TextutilDocumentReader.swift; status: incomplete; issues: DR36 -->

Details: [What TextMouth reads: EPUB and word-processor documents](what-textmouth-reads.md).

- Word document and its templates and macro documents (.docx, .dotx, .docm, .dotm): text, headings from styles, lists, tables, notes, emphasis, and pages; no macro runs; iPhone: yes; Tested with real files.
- Word 97-2003 document and template (.doc, .dot): the same; iPhone: yes; Tested with real files.
- Word 6 and Word 95 document (.doc, .dot, told from Word 97-2003 by its bytes): the same, except headers, footers, and pictures; iPhone: yes; Tested with real files.
- Word 1 and Word 2 document (.doc): refused at once; iPhone: no.
- Word document older than Word 6 that is a compound file: read on the Mac by Apple's textutil, with headings guessed from font sizes; iPhone: no; Basic.
- Rich text (.rtf): text, headings, lists, tables, emphasis, and pages; iPhone: yes; Tested with real files.
- Rich text with attachments (.rtfd, a package): the text file TXT.rtf in it, with the attachments left alone; iPhone: yes; Tested with made samples.
- OpenDocument text (.odt): text, headings, lists, tables, notes, and pages; iPhone: yes; Tested with real files.
- OpenDocument text template (.ott): read as an .odt is; iPhone: yes; Tested with made samples.
- Word 2003 XML (.xml, known by its root element): text, headings, tables, and pages; iPhone: yes; Tested with made samples.
- Flat OpenDocument (.fodt) and OpenOffice 1.x (.sxw) files are not read.

## DAISY and braille books
<!-- id: formats-list-daisy-braille; keys: DAISY, DTBook, NIMAS, BRF, BRL, PEF, braille; src: TextMouth/Parsers/DAISYParser.swift, TextMouth/Parsers/XMLDocumentSniffer.swift, TextMouth/Parsers/BrailleBookReader.swift, TextMouth/Parsers/BrailleFileReader.swift; status: incomplete; issues: FR33 -->

Details: [DAISY and braille books](reads-daisy-and-braille.md).

- DAISY 2.02 and 3 book (a folder, a ZIP, ncc.html, a .opf package file, or .daisy): text, headings, pages, and the narration where it has audio; iPhone: yes; Tested with real files.
- DTBook on its own (.xml whose root element is dtbook) and a NIMAS package: text, headings, and pages, read as a DAISY book; iPhone: yes; Tested with made samples.
- BRF braille file (.brf): the text, translated back from braille by liblouis, in the braille code that TextMouth guesses or you choose, with pages; iPhone: yes, with the tables the app carries for many languages; Tested with made samples.
- BRL braille file (.brl): the same, with no pages, since it has no page layout; iPhone: yes, as BRF; Basic, since its layout was inferred from a guide and not checked against real files.
- PEF braille file (.pef): the same, with pages; iPhone: yes, as BRF; Tested with made samples.
- BARD braille book (a .bopf package with its BRF volumes, its folder, or its ZIP): one braille book, a heading for each volume, its title, author, and braille code from the package; iPhone: yes for the ZIP or the folder, not for a lone .bopf; Tested with real files.
- The iPhone reads braille books with the table chosen in the Braille section of its Settings, and has no Braille Code pop-up yet, and a book that needs one of a Mac's own tables the iPhone lacks is refused there (see [DAISY and braille books](reads-daisy-and-braille.md)).

## Audiobooks and other sound
<!-- id: formats-list-audio; keys: MP3, M4B, M4A, WAV, FLAC, Ogg, MP4, converted audio; src: TextMouth/Parsers/AudioBookParser.swift, TextMouth/Services/ImportAudioConverter.swift, TextMouth/Parsers/AudioContentSniffer.swift, TextMouth/Parsers/NeroChapterReader.swift; status: incomplete; issues: FMT55, Q13 -->

Details: [Audiobooks](reads-audiobooks.md).
Audio gets its title, author, and duration from its tags, and its chapters, where the file has them, as headings.

- MP3 (.mp3): chapters from ID3 chapter frames; iPhone: yes; Well tested.
- M4B audiobook (.m4b): chapters from its chapter track or a Nero list; iPhone: yes; Well tested.
- M4A (.m4a), AAC in MPEG-4: the same chapters; iPhone: yes; Tested with made samples.
- WAV (.wav, with RF64 and BWF): sound only; iPhone: yes; Tested with made samples.
- AIFF (.aiff, .aif) and FLAC (.flac): sound only; iPhone: yes; Tested with made samples.
- AAC stream (.aac) and Apple Lossless (.alac): sound only; iPhone: yes; Basic.
- Video (.mp4, .m4v, .mov): the sound alone, with chapters; a file whose sound is not AAC, Apple Lossless, or MP3 is converted first; iPhone: yes; Tested with made samples.
- Ogg (.ogg, .oga, .opus), holding Vorbis, Opus, or FLAC: converted to .m4a at import, and never played through Apple's players; iPhone: no; Tested with made samples.
- AC-3 (.ac3), E-AC-3 (.ec3, .eac3), MP2 (.mp2), AMR (.amr), 3GPP audio (.3gp), NeXT/Sun audio (.au), AIFC (.aifc), CAF (.caf), and Wave64 (.w64): converted to .m4a at import by afconvert; iPhone: no; Tested with made samples.
- MP1 (.mp1) and the alternative extensions .mpa, .snd, .awb, .3g2, and .3ga: converted the same way; iPhone: no; Basic.
- TTA (.tta), WavPack (.wv, with a .wvc correction file beside it), and Monkey's Audio (.ape, version 3.99 and later): read by TextMouth's own decoders and written as Apple Lossless in .m4a, with their tags; iPhone: yes; Tested with made samples.
- WMA (.wma, .asf), Speex (.spx), Musepack (.mpc, .mp+), WebM and Matroska audio (.webm, .weba, .mka), RealAudio (.ra, .rm, .rmvb), and the sound of .wmv, .avi, .flv, and .mkv videos: converted by the app's converter, keeping tags and chapters; iPhone: yes; Tested with made samples, not Musepack.
- Nothing needs installing for those: TextMouth carries the converter.
- Copy-protected audio (.aa, .aax, .aaxc, .m4p, and copy-protected ASF) is refused and never read.
- Chapters come from more than tags: CUE sheets (.cue, or one in a FLAC file), markers in WAV, AIFF, and CAF files, CHAPTER comments in Ogg files, and Audacity label files (.txt) beside a folder's audio.
- What a file holds decides, not its name, so an Ogg file named .m4a is converted all the same.

## Playlists, manifests, and packages
<!-- id: formats-list-playlists-packages; keys: M3U, M3U8, ZIP, manifest.json, folder of tracks, TextMouth package, tmb, Nero chapters; src: TextMouth/Parsers/M3UPlaylist.swift, TextMouth/Parsers/AudioManifest.swift, TextMouth/Parsers/AudioBookParser.swift, TextMouth/Services/FileImportService.swift -->

Details: [Audiobooks](reads-audiobooks.md), [The audiobook manifest](audiobook-manifest.md), and [Transcripts, feeds, and packages](reads-transcripts-and-feeds.md).

- M3U and M3U8 playlist (.m3u, .m3u8): one audiobook of the files it lists, a heading for each, in its order; iPhone: yes; Tested with made samples.
- PLS playlist (.pls) and XSPF playlist (.xspf): the same, PLS in the order of its file numbers and XSPF with the playlist's title naming the book; iPhone: yes; Tested with made samples.
- A .pls that is a pronunciation lexicon is refused as a playlist; Import Rules… on the Text tab in Settings reads it (see [Settings](settings.md)).
- CUE sheet (.cue): the audio files it names as one book, a heading for each track; iPhone: not checked; Tested with made samples.
- ZIP of audio tracks (.zip): one book with a heading for each track; iPhone: yes, except for tracks that need converting; Tested with made samples.
- manifest.json in such a ZIP: the book's name and author, the tracks' order and titles, groups, and pauses; iPhone: yes; Tested with made samples.
- Folder of audio files: one book of its tracks, in their order; iPhone: yes, except for tracks that need converting; Tested with made samples.
- DAISY audio book in a ZIP: one audiobook whose sections are headings; iPhone: yes; Tested with made samples.
- TextMouth package (.tmb): a book TextMouth already describes, with its place and bookmarks; iPhone: yes; Tested with made samples.

## Transcripts and captions
<!-- id: formats-list-transcripts; keys: WebVTT, SubRip, vtt, srt, podcast transcript, Attach Transcript, sidecar; src: TextMouth/Parsers/WebVTTReader.swift, TextMouth/Parsers/SubRipReader.swift, TextMouth/Parsers/PodcastTranscriptReader.swift, TextMouth/Parsers/PodcastChapters.swift, TextMouth/Services/TranscriptPairing.swift; status: incomplete; issues: DR24, DR25, DR27 -->

Transcripts are never books of their own: each attaches to an audiobook, from the Book menu or when it sits beside the audio at import (see [Transcribing an audiobook](transcribing.md)).
A transcript file chosen without its audio is refused.

- WebVTT (.vtt): timed text, with its speakers, and the first choice when a .srt sits beside it; iPhone: not checked; Tested with made samples.
- SubRip (.srt): timed text; iPhone: not checked; Tested with made samples.
- Podcasting 2.0 transcript (JSON), taken from a feed with its episode: timed text, a sentence at a time; iPhone: not checked; Tested with made samples.
- Podcasting 2.0 chapters (JSON), taken from a feed with its episode: chapters as headings; iPhone: not checked; Tested with made samples.
- TextMouth's own transcript (transcript.json), made by Transcribe Audio on macOS 26 and later: the iPhone has no Transcribe Audio; Tested with made samples.

## Feeds
<!-- id: formats-list-feeds; keys: RSS, Atom, JSON Feed, OPML, podcast, subscription; src: TextMouth/Services/Feeds/FeedParser.swift, TextMouth/Services/Feeds/JSONFeedParser.swift, TextMouth/Services/Feeds/FeedOPML.swift, TextMouth/Services/Feeds/FeedDiscovery.swift -->

Details: [Podcasts and article feeds](feeds.md).
A feed's episode becomes an audiobook, and its article an HTML book, so each is read as the format it is in this list.

- RSS 2.0 (.xml or an address): episodes and articles, with Apple's podcast elements and Podcasting 2.0's; iPhone: not checked; Tested with real files.
- Atom: the same; iPhone: not checked; Tested with real files.
- RSS 1.0: the same; iPhone: not checked; Tested with made samples.
- JSON Feed 1.0 and 1.1: the same; iPhone: not checked; Tested with made samples.
- A web page that names its feed: TextMouth finds the feed from it; iPhone: not checked; Tested with made samples.
- OPML (.opml), another feed reader's list of subscriptions: each feed subscribed; iPhone: not checked; Tested with made samples.
- A feed that is not well formed is repaired where it can be, and refused with a reason where it can't.

## What Export writes
<!-- id: formats-list-export; keys: Export, Convert to, BRF, PEF, RTF, WebVTT, SubRip; src: TextMouth/Services/BookExportService.swift, TextMouth/Services/Export/TextExportWriter.swift, TextMouth/Services/Export/TimedTextWriters.swift, TextMouth/Services/Export/BrailleExportWriters.swift, TextMouth/Services/SpeechExport/SpeechExportJob.swift -->

Details: [Exporting books](exporting-books.md), [braille](exporting-braille.md), [captions](exporting-captions.md), and [spoken audio](exporting-spoken-audio.md).

- A book's text, from the Convert to pop-up: Markdown, HTML, RTF, Word 97-2003 (.doc), EPUB 3, BRF, and PEF.
- A book's own files: the original file as it was imported, an audiobook's audio, and a recording's original take.
- A transcript: JSON and Markdown, any of the text writers above, WebVTT, and SubRip.
- A text book spoken aloud: M4B, M4A, or MP3, with a chapter for each heading.
- The audio editor saves AAC, MP3, Apple Lossless, WAVE, AIFF, and CAF (see [Editing audio](editing-audio.md)).
- Export writes no .docx, OpenDocument, PDF, or Kindle file.

## What TextMouth refuses
<!-- id: formats-list-refusals; keys: unsupported file format, refused, advice, Attach Transcript, protected, 64 MB, empty file; src: TextMouth/Services/FileImportService.swift, TextMouth/Parsers/KFXError.swift, TextMouth/Parsers/MOBIError.swift, TextMouth/Parsers/DocumentByteLimit.swift, TextMouth/Phone/PhoneImportRefusal.swift; status: incomplete; issues: FMT55 -->

Each refusal names the file and says what to do next (see [Adding books](import-progress-and-errors.md) for the sentences).

- A transcript (.vtt, .srt) chosen without its audio: import the audio, open the book, and choose Attach Transcript from the Book menu.
- Any other file whose extension is none of the above: "Unsupported file format", with the extension.
- For Pages, Keynote, Numbers, WordPerfect, Compiled HTML Help, DjVu, XPS, and RAR comic and archive files, and copy-protected audio, the refusal adds a sentence of advice (see [Adding books](import-progress-and-errors.md)).
- An .xml file that is not a DTBook, Word 2003 XML, or a PEF file; and a file with no text to read.
- A Kindle Create package (.kpf), a Kindle book that is copy-protected or has no flowing text, and a KFX part without its book: told apart, each with its own sentence.
- A Word 1 or Word 2 document, and a password-protected Word 97-2003 or OpenDocument file.
  A PDF, a Word (.docx) document, or a ZIP-based book with a password is added locked and asks for its password when opened ([Adding books](import-progress-and-errors.md)).
- A document, web archive, SSML file, DTBook, or Kindle book of more than 64 MB.
- On the iPhone, Ogg and the other converted audio, and a Word document older than Word 6.
