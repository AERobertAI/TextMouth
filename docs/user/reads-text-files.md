# What TextMouth reads: text, HTML, PDF, and web archive files
<!-- id: reads-text-files; keys: HTML, Markdown, TXT, PDF, Safari, SSML, encoding; src: TextMouth/Parsers/PlainTextParser.swift, TextMouth/Parsers/HTMLParser.swift, TextMouth/Parsers/MarkdownParser.swift, TextMouth/Parsers/PDFTextParser.swift -->

Part of [TextMouth's documentation](../../README.md).
Every format TextMouth reads, with how well each is tested, is in [the list of formats](formats-list.md).

## PDF files
<!-- id: pdf-files; keys: scanned image, OCR, Vision, text recognition, image-only page; src: TextMouth/Parsers/PDFTextParser.swift, TextMouth/Parsers/PDFTextRecognizer.swift, TextMouth/Parsers/PDFRecognitionPlan.swift, TextMouth/Parsers/PDFPageImageScanner.swift -->

- A page that holds only a scanned image is read with the Mac's own text recognition.

## Pictures of pages and comic book archives
<!-- id: pictures-comic-archives; keys: picture, photo, PNG, TIFF, CBZ, comic, ComicInfo.xml, text recognition; src: TextMouth/Parsers/PageImageReader.swift, TextMouth/Parsers/PageImageDecoder.swift, TextMouth/Parsers/PageImageArchive.swift, TextMouth/Parsers/PageImageText.swift, TextMouth/Models/PageImageWording.swift, TextMouth/Parsers/VisionTextRecognition.swift; status: incomplete; issues: DR14 -->

- A picture of a page (.png, .jpg, .jpeg, .heic, .heif, .tif, .tiff) is read with the Mac's own text recognition, and its words become the book.
  A TIFF of several pages gives a chapter for each page that has text.
- A comic book archive (.cbz, a ZIP of pictures) is read the same way, a chapter for each page, in the natural order of the file names ("page2" before "page10").
  Its ComicInfo.xml, when it has one, gives the title (or the series and number), the writer, which pages to leave out as deleted, the titles of cover pages, and bookmarks.
  A .cbr, which is a RAR archive, is not read.
- Text recognition reads the words on a page from top to bottom and left to right.
  It knows nothing of a comic's panels or speech balloons, so the words of a page of panels may come in another order than the story's.
- Every picture, TIFF page, and archive picture is a page of the book.
- The book's title is the file's name, unless ComicInfo.xml gives one.
- Transparent pictures are laid on white, and on black when nothing is found on white; a photo's orientation is applied.
- A picture that declares more than 100 megapixels is refused before it is decoded, and a book holds at most 2,000 pages.
  The Mac decodes a page at up to 16 megapixels, and the iPhone at up to 4.
- A comic book archive reads each page from the archive without unpacking it, and refuses a page file of more than 64 MB.
- Pictures among other files in a ZIP of books, in an audiobook's tracks, or in a DAISY archive are not books, and a ZIP holding only pictures imports nothing: rename it to .cbz to read it as a comic.
- Pictures and comic book archives need TextMouth 0.5.0 or later: an earlier TextMouth opens a library holding one without that book.

## HTML, Markdown, and plain text files
<!-- id: html-markdown-plain-text-files; keys: line endings, TXT, .md, .html, .htm, TextFileDecoder; src: TextMouth/Parsers/TextFileDecoder.swift, TextMouth/Parsers/PlainTextParser.swift, TextMouth/Parsers/HTMLParser.swift, TextMouth/Parsers/MarkdownParser.swift -->

- TextMouth reads HTML, Markdown, and plain text files, whatever their text encoding and line endings.

### Where a file's text encoding comes from
<!-- id: where-file-text-encoding-comes; keys: BOM, byte-order mark, ISO-2022-JP, meta charset, ISO Latin 1, strict UTF-8; src: TextMouth/Parsers/TextFileDecoder.swift, TextMouth/Parsers/TextEncodingByteGrammar.swift -->

- TextMouth takes a file's text encoding from the file where it can, using the first of these that applies:
  - A byte-order mark for UTF-8, UTF-16, or UTF-32.
  - UTF-16 or UTF-32 without a mark, found by the pattern of its bytes (since 0.4.3), as described in the next section.
  - For an HTML file that declares ISO-2022-JP (Japanese in 7-bit text) and holds its escape codes, that encoding, since such a file is valid UTF-8 too.
  - Bytes that are valid UTF-8.
  - For an HTML file, an encoding other than Unicode that its first 1,024 bytes declare, where ISO Latin 1 and ASCII are read as Windows-1252, as web browsers read them.

### UTF-16 and UTF-32 without a mark
<!-- id: utf-16-utf-32-without; keys: UTF-16LE, UTF-16BE, NUL bytes, no BOM, CJK, Devanagari; src: TextMouth/Parsers/TextFileDecoder.swift, TextMouth/Parsers/TextEncodingByteGrammar.swift, TextMouth/Parsers/TextPlausibility.swift; status: incomplete; issues: DR18, DR19 -->

- Since 0.4.3 TextMouth finds these by the pattern of their bytes:
  - UTF-16 in Latin letters, which shows in its zero bytes, as before;
  - UTF-32, in either byte order;
  - UTF-16 in Greek, Cyrillic, Armenian, Hebrew, or Arabic, from 16 bytes up;
  - UTF-16 in other scripts, such as Chinese, Japanese, or Korean, when the text also holds at least 8 ordinary characters (spaces, digits, or line ends).
- A reading counts only if the result is plain text.
  A few stray zero bytes in a UTF-8 or 8-bit file do not make it UTF-16.
- What it does not find:
  - UTF-16 in the scripts of India (Devanagari, Bengali, and the others near them).
  - Short Chinese, Japanese, or Korean UTF-16 with few spaces, digits, or line ends.
    In testing, a Chinese file needed about 46 characters and a Korean one about 28, and a Japanese file with only 5 spaces, digits, or line ends was not found.
  - Chinese, Japanese, or Korean UTF-16 with no such characters at all, whose bytes look the same as Shift JIS, GBK, or EUC text.
  - A file that is not found is read as one of the other encodings, with the wrong letters, or as Windows-1252.
- UTF-16 and UTF-32 have no item in the Text Encoding pop-up (see [The Library window](book-information.md)), so a file that is not found cannot be set right there.
  Save it as UTF-8, or in UTF-16 with a byte-order mark, and add it again.
- A book that recorded its encoding when you added it is read again in that encoding, and only UTF-16 in Latin letters can overrule it.
  A web archive's page that names no encoding is read as it was before.
  Your own choice in Text Encoding overrules all of this.
- The first time 0.4.3 opens, every plain text and HTML book is read again once, and your place follows its words.
  A book whose file reads as it did before has the same text.
  A Markdown book is read the new way when it is added, or when its text is built again, as Redo Text Extraction does.

### A file that none of these settles
<!-- id: file-that-none-these-settles; keys: Windows-1252, mojibake, Open Book, Finder, ZIP, feed article; src: TextMouth/Parsers/TextEncodingGuesser.swift, TextMouth/Parsers/TextFileDecoder.swift, TextMouth/Services/FileImportService.swift -->

- A file that none of these settles, because it is neither UTF-8, UTF-16, nor UTF-32 and names no encoding, was always read as Windows-1252, so a file in an encoding that Windows-1252 does not match, such as Mac Roman, Cyrillic, or Japanese, had the wrong letters.
- Since version 0.2.2, TextMouth guesses its encoding when you add the file with Open Book…, from Finder, or in a ZIP of books, and a book whose encoding it guessed is read in that encoding from then on.
- Only a file you add yourself is guessed at: a feed's article is read as it always was.

### The encodings TextMouth guesses among
<!-- id: encodings-textmouth-guesses-among; keys: code pages, Shift JIS, KOI8-R, TextEncodingCatalog, Mac Roman, Speak Full Info; src: TextMouth/Parsers/TextEncodingCatalog.swift, TextMouth/Models/TextEncodingChoice.swift, TextMouth/Models/LibraryInfoWording.swift -->

- TextMouth guesses among the encodings below.
- Book Information and Speak Full Info name the one it chose as written here, then "guessed", and one you chose the same way, then "chosen" (see [The Library window](book-information.md)).
- Windows-1252 is not among them: a file is read as Windows-1252 when no guess can be trusted, though you can choose it.
- The two DOS code pages and Mac Central European, added in version 0.4.7, are taken only when macOS's own guess names one of them.
  TextMouth does not try them itself, so a book already in the library is not read differently; the Text Encoding pop-up in Book Information offers all three for you to choose.
- The encodings, by script:
  - Western European: "Mac Roman (Western European)", "ISO 8859-15 (Western European)", "CP437 (US DOS)", and "CP850 (Western European DOS)".
  - Central European: "Windows-1250 (Central European)", "ISO 8859-2 (Central European)", and "Mac Central European".
  - Cyrillic: "Windows-1251 (Cyrillic)", "KOI8-R (Russian)", "KOI8-U (Ukrainian)", "CP866 (Russian DOS)", "ISO 8859-5 (Cyrillic)", and "Mac Cyrillic".
  - Greek: "Windows-1253 (Greek)" and "ISO 8859-7 (Greek)".
  - Turkish: "Windows-1254 (Turkish)" and "ISO 8859-9 (Turkish)".
  - Hebrew: "Windows-1255 (Hebrew)" and "ISO 8859-8 (Hebrew)".
  - Arabic: "Windows-1256 (Arabic)" and "ISO 8859-6 (Arabic)".
  - Baltic: "Windows-1257 (Baltic)" and "ISO 8859-13 (Baltic)".
  - Thai: "Windows-874 (Thai)".
  - Japanese: "Shift JIS (Japanese)", "EUC-JP (Japanese)", and "ISO 2022-JP (Japanese)".
    - ISO 2022-JP writes only 7-bit bytes, so it is valid UTF-8 too.
    - TextMouth looks for it, by its escape sequences, before it takes bytes for UTF-8.
  - Chinese: "GB 18030 (Simplified Chinese)", "GBK (Simplified Chinese)", "GB 2312 (Simplified Chinese)", and "Big5 (Traditional Chinese)".
  - Korean: "EUC-KR (Korean)".

### When TextMouth guesses
<!-- id: when-textmouth-guesses; keys: plausibility, capitals inside words, round trip, macOS guess, false positive; src: TextMouth/Parsers/TextEncodingGuesser.swift, TextMouth/Parsers/TextPlausibility.swift -->

- TextMouth guesses only when it can trust the guess more than Windows-1252, since a wrong guess turns text that was right into text that is not, which the book keeps, while a missed guess leaves a book as garbled as it was.
- You can mend either by choosing the book's encoding yourself (see Choosing the encoding, below).
- It examines the lines that hold a byte beyond plain ASCII, about 64 KB of them from the start, and takes a guess only when all of these hold:
  - The Windows-1252 reading shows that it is wrong:
    - It holds at least three characters that real writing almost never holds (symbols inside words, control characters, and the like), not all the same character.
    - Or it holds at least five capitals inside lowercase words.
    - Or a fifth or more of its letters beyond plain ASCII lie outside the alphabet of the one language that fits them best, where the other reading's letters fit one language.
  - Another encoding reads them clearly better, with almost nothing odd left.
    When other encodings read them as well but differently, the file stays Windows-1252, unless macOS's own guess names one of exactly two of them.
  - The whole file, not only the lines examined, reads in that encoding with no byte dropped or replaced, and writes back to exactly the same bytes.

### The same bytes give the same guess
<!-- id: same-bytes-give-same-guess; keys: deterministic, repeatable, same result; src: TextMouth/Parsers/TextEncodingGuesser.swift -->

- The same bytes always give the same guess.

### Files that stay Windows-1252
<!-- id: files-that-stay-windows-1252; keys: short texts, Hungarian, Croatian, Slovenian, Latvian, Hebrew, CP437, CP850; src: TextMouth/Parsers/TextEncodingGuesser.swift, TextMouth/Parsers/TextEncodingCatalog.swift -->

- Some files stay Windows-1252, as they were read before, until you choose their encoding (see Choosing the encoding, below):
  - Short texts, which show too little to guess from.
    A Cyrillic note of a line or two may stay garbled, though a paragraph of Cyrillic is read right.
  - Text in some languages: Hungarian, Croatian, Slovenian, and Latvian, and French saved in ISO 8859-15.
  - Short sentences in Mac Roman, in Spanish, Portuguese, Italian, Dutch, Danish, or German.
  - A file whose only accented letters are capitals inside program names, such as "zeigeÜbersicht", when it is not in Windows-1252: read right, those capitals look as odd as they do read wrong.
  - Hebrew text, which is guessed only when macOS's own guess names Hebrew, so a short Hebrew text may stay as it was.
  - A file in an encoding that is not listed above, or in CP437, CP850, or Mac Central European when macOS's own guess does not name it, since TextMouth does not try those three itself.

### A guess can be wrong
<!-- id: guess-can-be-wrong; keys: wrong letters, Book Information, Text Encoding pop-up, program code; src: TextMouth/Parsers/TextEncodingGuesser.swift, TextMouth/ViewModels/TextEncodingChoiceModel.swift -->

- A guess can still be wrong, most often for a text of only a few lines, and, rarely, for a Windows-1252 file of program code with several accented capitals inside its names, which can be read as Mac Roman.
- Book Information names the encoding a book was read in, so a book whose letters read oddly can be checked there, and set right there with its Text Encoding pop-up (see Choosing the encoding, below).

### Books already in your library
<!-- id: books-already-your-library; keys: TextEncodingRecord, record, re-read, Redo Text Extraction, no record; src: TextMouth/Models/TextEncodingRecord.swift, TextMouth/Services/MarkdownCacheService.swift -->

- A book already in your library keeps its text.
- TextMouth records a guess with the book when the book is added, and an encoding you choose when you choose it, and reads the book in it every time its text is built again, after an update or with Redo Text Extraction.
- A book added before then, and a book whose file named its encoding or read right as Windows-1252, has no record and is read as it always was (see [Where TextMouth keeps your library](book-packages.md)).

### Choosing the encoding
<!-- id: choosing-text-encoding; keys: Text Encoding pop-up, Automatic, strict decoding, JIS X 0212, Big5-HKSCS, GB 18030, refusal; src: TextMouth/Models/TextEncodingChoice.swift, TextMouth/Parsers/TextFileDecoder.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift, TextMouth/Models/LibraryInfoWording.swift -->

- The Text Encoding pop-up in Book Information reads a book's file again in the encoding you choose, or, with Automatic, as TextMouth reads a file you add.
- Use it for a book whose letters read oddly, whether the guess was wrong or missed.
- Its items, and every sentence it says, are under Text Encoding in [The Library window](book-information.md).
- A book you added from a file has it.
  Text you typed in with New from Text, a feed's article, and a book of another format do not.
- A chosen encoding is read whatever the file's bytes say of themselves: a byte-order mark, bytes that are valid UTF-8, and an HTML file's own declaration do not overrule it, since you choose it for a file that read wrong.
- It is read strictly: every byte must belong to a character of the encoding, and none is dropped or replaced.
  UTF-8 refuses a file that is not valid UTF-8, and an encoding of one byte to a character refuses a byte it leaves undefined, such as 0x98 in Windows-1251.
  Windows-1252 gives every byte a character, so it refuses nothing.
- A file that is not valid in the encoding chosen is refused, and nothing changes: not the book's text, its saved places, nor its record.
  The sentence names the book and the encoding (see Text Encoding in [The Library window](book-information.md)).
- Limits, since macOS's own readers decide which characters an encoding defines:
  - Characters of JIS X 0212 in EUC-JP, which it writes with the byte 0x8F before two bytes, are refused, because macOS reads them as other characters.
  - The euro sign in Big5 and in EUC-KR is refused.
  - Big5-HKSCS characters, the Hong Kong additions to Big5, are refused.
  - A GB 18030 file that holds the replacement character itself, U+FFFD, is refused.
  - In Big5 as Windows writes it, the two bytes 0xA2 0xCC are read as 十 followed by a character from a private-use area, which a braille display shows.
- A book recorded as read in an encoding this TextMouth does not know, as a choice made on a Mac that knows more encodings, or in a later TextMouth, can be, is refused when its text is read.
  "The file “Moby-Dick.txt” is set to be read as “x-cp1999”, a text encoding this version of TextMouth can't read.
  Choose another in Book Information."

## Safari web archives
<!-- id: safari-web-archives; keys: .webarchive, WebKit, main resource, subresources, property list; src: TextMouth/Parsers/WebArchiveReader.swift -->

- TextMouth reads Safari web archives (.webarchive).
- Only the archive's main page is read, as an HTML file is read (or a text file, for a text page), so its headings, lists, and tables read as in an HTML book.
- The archive's pictures, scripts, style sheets, and frames, and every address it names, are never read, decoded, or fetched, and WebKit is not used.

## SSML files
<!-- id: ssml-files; keys: .ssml, speak, sub alias, break, voice, lexicon, markup; src: TextMouth/Parsers/SSMLReader.swift -->

- TextMouth reads SSML files (.ssml) as text: the markup is removed, and the paragraphs and sentences are kept.
- A sub element's alias is read in place of its written text: `<sub alias="World Wide Web Consortium">W3C</sub>` reads "World Wide Web Consortium".
- The text of desc, meta, metadata, and lexicon elements is left out.
- An audio element's sound file is never read or fetched, and only the text inside the element is read.
- A break, a change of voice, or a sentence's start keeps the words on either side of it apart.
- The file is never given to the speech engine as SSML, which would ignore the speed you set.
- Its words are spoken in your voice at your speed, whatever voice, speed, or pitch the markup asks for.

## New from Text
<!-- id: new-from-text; keys: paste, type text, clipboard, importText; src: TextMouth/Services/FileImportService.swift, TextMouth/App/MenuCommands.swift -->

- TextMouth reads text you type or paste with New from Text.
