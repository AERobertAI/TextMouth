# Imports: text in other encodings
<!-- id: imports-text-other-encodings; keys: charset, code page, mojibake, garbled text, TextFileDecoder, TextEncodingGuesser, plain text; src: -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## Text files in other encodings
<!-- id: text-files-other-encodings; keys: charset, code page, mojibake, garbled text, wrong letters, Text Encoding pop-up; src: TextMouth/Parsers/TextFileDecoder.swift, TextMouth/Parsers/TextEncodingGuesser.swift, TextMouth/Models/TextEncodingRecord.swift, TextMouth/Models/TextEncodingChoice.swift, TextMouth/Models/Book.swift -->

Text files in other encodings (FMT16): a plain text, Markdown, or HTML book whose bytes name no encoding is read in the one TextMouth guesses when the file is imported, and in that one ever after, where every such file was read as Windows-1252 before.
Book.textEncoding names the guess; a book with none is read as it always was.
The listener can choose the encoding instead (encodingchoice, [Choosing the encoding](imports-text-encoding-choice.md)): Book.textEncoding then names the choice, and Book.textEncodingSource says it was chosen.

### The steps
<!-- id: steps; keys: BOM, UTF-16LE, UTF-16BE, UTF-32, meta charset, DecodedText, NUL bytes, decode order; src: TextMouth/Parsers/TextFileDecoder.swift, TextMouth/Parsers/TextEncodingGuesser.swift, TextMouthProductionTests/TextFileDecoderTests.swift -->

The steps: TextFileDecoder.decode(_:fileName:format:policy:) finds the encoding of a file's bytes in this order (decodeBytes), and finishes the text the same way whatever the encoding: a leading U+FEFF is removed, and every line ending becomes a line feed.

0. The listener's choice, before everything the bytes say of themselves (encodingchoice): when the policy is .chosen(identifier), chosenText(_:identifier:fileName:) reads the whole file in that encoding alone.
   So a byte-order mark, valid UTF-8, and an HTML declaration settle nothing, and its basis is chosen.
   The read is strict (strictlyDecodedText(_:in:), [Choosing the encoding](imports-text-encoding-choice.md)): a byte the encoding does not define throws TextEncodingError.invalidForChosenEncoding, naming the file and the encoding as a listener hears it.
   An identifier that is neither UTF-8 (utf8Identifier, "utf-8") nor the catalog's throws unknownChosenEncoding.
   Neither goes to the fallback, so a choice is never read as something else.
   The leading U+FEFF is removed, and the line endings made line feeds, as for every reading.
1. A byte-order mark, for UTF-8, UTF-16, or UTF-32 (byteOrderMarks).
   Bytes after a UTF-16 or UTF-32 mark that are not valid in it throw TextEncodingError.invalidForMarkedEncoding.
   Bytes after a UTF-8 mark that are not valid UTF-8 go to the fallback (step 7) whatever the policy, and are never guessed.
2. UTF-16 and UTF-32 without a mark, recognized by the structure of their bytes (unmarkedUnicode(in:)), by four rules in this order, the first that names an encoding deciding.
   (a) UTF-16 in a Latin script (unmarkedUTF16Encoding(of:)): an even length, more than half the code units with a zero byte in one position, and none with a zero byte in the other; its text is taken as it is.
   (b) UTF-32 (unmarkedUTF32Encoding(of:)): a length of at least 8 bytes that is a whole number of code units, every unit with its top byte zero and the byte below it at most 0x10 in one byte order and not the other, and one unit not zero.
   (c) UTF-16 in an alphabet (UTF16ByteStatistics.isAlphabetic): at least 16 bytes, at least 8 code units with a nonzero high byte, 85% of those sharing one high byte of 0x03 to 0x06 (Greek, Cyrillic, Armenian and Hebrew, Arabic).
   (d) UTF-16 in any other script (isAnchoredByZeros): at least 8 code units with a nonzero high byte.
   It also needs at least 8 anchors, the units with a zero high byte and a low byte of ASCII text (tab, line feed, carriage return, 0x20 to 0x7E: a space, a digit, a line ending).
   The anchors must make up at least 90% of the units with a zero high byte, so that a few stray NULs in UTF-8 or 8-bit text, which make zero-high units of any low byte, show nothing.
   It allows at most one zero low byte for four zero high bytes (一 and 가 have one).
   It needs 15% of the units with a nonzero high byte to have a low byte of 0x80 or more.
   A byte order counts only when exactly one shows a rule, and the text of (b), (c), and (d) must read as text.
   (isPlausibleText: no control character but tab, line feed, form feed, and carriage return, no C1 control, noncharacter, private-use character, character in planes 4 to 13, replacement character, or unpaired surrogate).
   A reading that is not goes on to the next rule, (b) to (c) or (d) (a UTF-16 column of single characters, one to a line, passes (b) as UTF-32 in planes no text uses and reads right by (c) or (d)), and the bytes that no rule reads go on to the steps after.
   A book that recorded its encoding (EncodingPolicy.recorded), and a reader whose files are no book and have no version to raise (a web archive's page without an encoding name, a .doc that is really a web page: TextFileDecoder.Evidence.legacy), ask (a) alone, as every read did before.
   The legacy readers do not read an HTML file's ISO-2022-JP declaration either.
   Scripts at U+09xx to U+0Dxx are left out of (c), since their high bytes are 0x09, 0x0A, and 0x0D, the tab, line feed, and carriage return of a column of single characters.
   Chinese, Japanese, and Korean UTF-16 with no ASCII character in it reads in the same bytes as Shift JIS, GBK, or EUC text.
   Both are left to the steps after, since a missed recognition costs less than a wrong one.
   The rules were tried on 89 text samples of TestData in about 124,000 windows, and on the same sentences in more than 20 encodings in about 84,000, with no false positive, and again with one to four NULs put into the same windows at random places.
   (about 81,000 windows of TestData, 12,000 of the sentences in 14 encodings) (TextFileDecoderTests).
   It comes before UTF-8 because UTF-16 of ASCII text is valid UTF-8 too, and so is Cyrillic UTF-16, read as control characters.
   The basis is unmarkedUnicode.

### The steps after the unmarked Unicode rules
<!-- id: steps-after-unmarked-unicode; keys: ISO-2022-JP, declaration, valid UTF-8, fallback, Windows-1252, decodeBytes; src: TextMouth/Parsers/TextFileDecoder.swift, TextMouth/Parsers/TextEncodingGuesser.swift, TextMouthProductionTests/TextFileDecoderTests.swift -->

3. A file in a 7-bit encoding that the policy names, ISO-2022-JP (sevenBitText(_:policy:)), which comes before UTF-8 because such a file is valid UTF-8 too.
   Only the guessing policy, and the recorded policy for a book that recorded a 7-bit encoding, look for one, so a book from before FMT16 reads the file as UTF-8, as it always did, except an HTML file whose declaration names ISO-2022-JP (declaredSevenBitText(_:)).
   When it holds an escape and guessSevenBit(_:) finds it well formed with a shift into JIS X 0208, it is read in ISO-2022-JP with the basis declaration(label:) under every policy but a recorded one (3a in decodeBytes), the declaration being unreachable otherwise since the file is valid UTF-8.
   A declaration with no escape in the file, or with a truncated one, changes nothing.
4. Valid UTF-8.
5. For an HTML file alone (readsDeclarations), the encoding declared in its first 1,024 bytes (declaredEncodingLabel(in:)): the XML declaration's, else the first meta element's charset, passing over comments.
   ISO Latin 1 and ASCII read as Windows-1252 (windows1252Equivalents), as browsers read them.
   A label TextMouth does not know, or bytes that are not valid in the encoding, throw TextEncodingError (unsupportedDeclaredEncoding, invalidForDeclaredEncoding) and are never guessed; a label that names a Unicode encoding, which the bytes have already failed, leaves them to the next step.
6. The policy for bytes that name no encoding (settledText(_:policy:)): .recorded reads them in the recorded encoding, .guess asks TextEncodingGuesser.guess(_:), and .fallback leaves them to the next step.
7. The Windows-1252 fallback (fallbackText(_:)), which gives every byte a character (windows1252Text(_:)).

### The policy
<!-- id: policy; keys: Evidence, legacy reader, Basis, strict read, .m3u, .webarchive, .doc; src: TextMouth/Parsers/TextFileDecoder.swift, TextMouth/Models/TextEncodingRecord.swift, TextMouth/Parsers/TextEncodingGuesser.swift, TextMouth/Parsers/M3UPlaylist.swift, TextMouth/Parsers/WebArchiveReader.swift, TextMouth/Parsers/TextutilDocumentReader.swift -->

The policy: TextFileDecoder.EncodingPolicy is what a read does with bytes that name no encoding, and it keeps a book's text from changing under its reader.
- .fallback is the policy of a book with no recorded encoding and of every reader of a file that is no book (M3UPlaylist.read, WebArchiveReader, and the web page TextutilDocumentReader reads for a .doc that is really one).
- .guess is the policy of the import of a file the user chose.
- .recorded(identifier) is the policy of a book with a recorded encoding, and EncodingPolicy.forBook(recording:) chooses between it and .fallback.
- .chosen(identifier) is the policy of a book whose encoding the listener chose (TextEncodingRecord.policy gives it, from the record's source, in place of forBook(recording:)).
  It is not an answer to bytes that name no encoding, as the three before it are, but a reading that overrules whatever the bytes name, and that is strict.

A recorded identifier that the catalog does not know, or an encoding that the bytes are not valid in (a file changed since, or a record a later TextMouth wrote), leaves the bytes to the fallback.
A recorded 7-bit encoding is checked against the bytes again (TextEncodingGuesser.guessSevenBit(_:)), since Foundation's reader lets a changed file through.
DecodedText says what decided (its basis, TextFileDecoder.Basis), and guessedEncodingIdentifier is the catalog's identifier for a guess alone.

### Who guesses
<!-- id: who-guesses; keys: decidingEncoding, import, Import File, guess policy, Text Encoding pop-up, automatic re-read; src: TextMouth/Services/FileImportService.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift, TextMouth/Models/TextEncodingRecord.swift, TextMouthProductionTests/TextEncodingImportTests.swift -->

Who guesses: FileImportService.importFileWithReport, which sets guessingEncoding for publishReadableBook(_:from:run:...) and so for readableContent(of:run:...), which passes it on as decidingEncoding to MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(for:...).
The other is the listener's re-read as Automatic (LibraryViewModel.readTextAgain, in [Text caches](text-caches-rereads-edits.md)), which sets decidingEncoding on generateReportedCacheAnalyzeAndStamp itself.
No one else does.
The private MarkdownCacheService.encodingPolicy(of:decidingEncoding:) gives a read that decides .guess when the book records no encoding and no decision about one (TextEncodingRecord.isEmpty), and otherwise the policy of the row's own record.
Any other read gets book.recordedTextEncodingRecord().policy (see [Text caches](text-caches.md)).
So Open Book, Finder, the members of a ZIP, and a re-read as Automatic guess.
A TextMouth package, a feed's episode or article, a recording, text typed in with New from Text, a book added back, and every rebuild and migration of a book already in the library, a re-read in an encoding the listener chose included, do not guess.
(TextEncodingImportTests pins the members of a ZIP, text typed in, and a book added back.)

### The guess
<!-- id: guess; keys: Guess, heuristic, NSString, Foundation hint, mojibake, ranking, tie; src: TextMouth/Parsers/TextEncodingGuesser.swift, TextMouth/Parsers/TextEncodingCatalog.swift, TextMouth/Parsers/TextPlausibility.swift, TextMouthProductionTests/TextEncodingGuesserTests.swift -->

The guess: TextEncodingGuesser.guess(_:) returns a Guess, the catalog's entry and the whole file read in it, or nil, which leaves the Windows-1252 reading.
A missed guess costs less than a wrong one: the default is today's reading, while a guess that is wrong turns text that was right into text that is not, which the book keeps.

1. examinedBytes(of:) takes the sample: the lines that hold a byte of 0x80 or more, from the start, until sampleLimit (64 KiB) is gathered.
   A line ends at a line feed or a carriage return, which no multi-byte encoding the guess reads uses inside a character.
   A single line longer than four limits is cut after a byte that ends a character in all of them (lastByte(ofLineFrom:to:in:): a byte below 0x40 that is not a digit, since the digits are the second and fourth bytes of a four-byte GB 18030 character).
   A file with no such line, or whose sample is more than maximumControlByteShare (2 in 100) control characters other than white space and escape, is no text and is not guessed.
2. The sample is read as Windows-1252 and judged as Judging.windows1252, and in every catalog entry marked isAlwaysTried and the one entry Foundation's own guess names, judged as Judging.rival.
   Foundation's own guess is foundationHint(for:), from NSString.stringEncoding(for:encodingOptions:convertedString:usedLossyConversion:) through TextEncodingCatalog.entry(for:).
   The hint is none when Foundation names nothing, Windows-1252, or an encoding the catalog lacks.
   A reading with a replacement character is dropped.
3. The readings are ranked by their surprise, fewest first, a tie keeping the catalog's order.
   In that order each must pass, or give way:
   - Its disorder, the anomalies and the excess uppercase, may be at most the greater of 1 and 3 in 100 of its non-ASCII characters (maximumDisorderShare).
     A reading that fails is passed over for the next.
   - The default must be worse by at least minimumGain (3) surprises, its surprises must be at least minimumDefaultSurpriseShare (3 in 100) of its non-ASCII characters, and it must show that it is wrong (isGarbled(comparedTo:)).
     If it does not, there is no guess.
   - settle(on:among:hint:) must be able to call the reading.
     If it is a Hebrew reading (Windows-1255 or ISO 8859-8), or ties with one, there is a guess only when Foundation's guess names Hebrew, since Hebrew letters are bytes that every Cyrillic encoding reads as clean lowercase letters and Hebrew has no case to betray a wrong reading.
     No other reading with as few surprises may read differently, unless only two distinct readings tie and Foundation's pick is one of them; readings that read alike differ only in name, and the hint's name, else the catalog's first, is used.
     If it cannot be called, there is no guess.
   - The whole file, not only the sample, must decode in the encoding (decodedText(_:in:)) and encode back to exactly the same bytes (allowLossyConversion false).
     A reading that fails is passed over.

### ISO-2022-JP
<!-- id: iso-2022-jp; keys: ISO 2022-JP, 7-bit, Japanese mail, email, escape sequence, isSevenBit; src: TextMouth/Parsers/TextEncodingByteGrammar.swift, TextMouth/Parsers/TextEncodingGuesser.swift -->

ISO-2022-JP: guess(_:) cannot find it, since every byte is ASCII and the file is valid UTF-8, so guessSevenBit(_:) finds it by its structure, which TextEncodingByteGrammar.isWellFormedISO2022JP(_:requiringAShift:) checks as RFC 1468 defines it:
- only the escape sequences for ASCII, JIS Roman, JIS X 0201's half-width katakana, which Windows writes in mail, and JIS X 0208 (ESC ( B, ESC ( J, ESC ( I, ESC $ @, ESC $ B),
- pairs of bytes from 0x21 to 0x7E while in JIS X 0208,
- bytes up to 0x5F while in the katakana,
- a return to ASCII or JIS Roman before the end, and,
- for the guess (requiringAShift), at least one shift into JIS X 0208, since plain ASCII reads alike in every encoding.
  A file chosen to be read in ISO-2022-JP needs no shift.

Foundation's reader lets a truncated escape or a byte above ASCII through, so it does not decide.

### The judgment
<!-- id: judgment; keys: plausibility, garbled, mojibake, Script, language fit, Judging, heuristic; src: TextMouth/Parsers/TextPlausibility.swift, TextMouthProductionTests/TextPlausibilityTests.swift -->

The judgment: TextPlausibility(reading:judging:) counts three kinds of surprise over a reading's characters outside ASCII (the ASCII ones read alike in every encoding).

- Anomalies:
  - a C1 control character,
  - an unassigned character,
  - a symbol between two letters,
  - a capital directly after a lowercase letter when either is not ASCII (a case flip),
  - a word that mixes Latin letters with another script,
  - a combining mark that does not follow a letter of its own script, and
  - symbols that text rarely holds.
- Misfit letters: the non-ASCII letters outside the alphabet of the one language of its table that fits best (alphabets); for a script with no alphabets in the table, the letters of any other script than the commonest.
- Excess uppercase: the uppercase letters beyond 35 in 100 of the cased non-ASCII letters, counted from 8 cased letters on.
- surprise is their sum, with excess uppercase counted in a rival alone, and disorder is the anomalies and the excess uppercase.
- The two sides are judged unlike (Judging).
  The characters Windows-1252 has (¦ ¬ ¤ ¨ ¯ ¸ ˜, quotation marks and ellipses glued to a letter, accents that stand alone, and ƒ µ ª º taken as symbols, not letters) are ordinary in its own reading, since a writer typed them.
  They are anomalies in a rival, where they are what decoding made of other bytes.
  Mac Roman reads the bytes of Windows-1252's capitals Ü, É, and Ç as ‹, …, and «, so Windows-1252's "zeigeÜbersicht" read as Mac Roman is "zeige‹bersicht".
  Excess uppercase is no surprise in the Windows-1252 reading (headings in capitals, names, and identifiers such as "zeigeÜbersicht"), and an Irish accented capital after the h, n, or t that prefixes a word is no case flip there ("na hÉireann").
- isGarbled(comparedTo:) is the proof that the Windows-1252 reading is wrong, which more surprises than a rival is not: Western text is made of ordinary Windows-1252 characters, each standing singly in a plausible place.
  It holds when the reading has one of these:
  - three anomalies of at least two different characters (garblingAnomalies, garblingAnomalyCharacters);
  - five case flips (garblingCaseFlips);
  - misfit letters that are a fifth or more of its non-ASCII letters (misfitShareNeeded), at least ten of them when the non-ASCII letters are 8 in 100 of all the letters or more and at least six when they are half or more (misfitLettersNeeded).
    The rival's misfit letters must then be at most 2 in 100 of its non-ASCII letters (rivalMisfitShareAllowed).
- The same text is always judged alike.
  The commonest script decides how letters are judged (dominantScript(in:)), and of scripts with as many letters the first in Script.allCases wins, Latin first, where a dictionary's own order differs from one launch to the next.
  (TextPlausibilityTests calls it with dictionaries of 1 to 64 capacities).

### The encoding catalog
<!-- id: encoding-catalog; keys: Entry, IANA, charset, code page, cp1251, CP437, CP850, pop-up list; src: TextMouth/Parsers/TextEncodingCatalog.swift, TextMouth/Parsers/TextFileDecoder.swift, TextMouthProductionTests/TextEncodingCatalogTests.swift -->

The catalog: TextEncodingCatalog.entries lists every encoding the guess can name, in the order that settles a tie, each with its identifier, its String.Encoding, the name a listener hears (listed in [What TextMouth reads](../../user/reads-text-files.md)), isAlwaysTried, and isSevenBit.
Its name is `label.name`, in the interface language: TextEncodingCatalog.Label has one case for each name (Windows' variant and the standard it extends share one), so code compares labels, not text.
The identifier is the lowercase IANA name as Core Foundation spells it, such as windows-1251, koi8-r, macintosh, or cp932, which a book records and looks up again on every reading, so it never changes.
TextEncodingCatalog.row(_:_:tried:sevenBit:) makes an entry through TextFileDecoder.encoding(forLabel:) and leaves out one that this Mac's Core Foundation does not know.
Windows-1252 is in it, to be named, but is never tried or guessed: it is the default.
The always-tried entries are the ones Foundation's own guess reads wrongly (it named a Mac Roman file Windows-1251, a KOI8-R file ISO 8859-5, and short Hebrew Windows-1251).
Mac Roman, ISO 8859-15, Windows-1250, ISO 8859-2, Windows-1251, KOI8-R, KOI8-U, CP866, ISO 8859-5, Mac Cyrillic, and Windows-1255, Hebrew, which is read always so that the guess sees the tie it makes with a Cyrillic reading.
The others (Greek, Turkish, ISO 8859-8, Arabic, Baltic, Thai, and the Japanese, Chinese, and Korean entries) are read only when Foundation names them.
Where two encodings read a file alike the first is named (KOI8-R before KOI8-U, Windows-1250 before ISO 8859-2, Mac Roman before Mac Cyrillic).
TextEncodingCatalog.entry(forIdentifier:) finds an entry in any letter case, entry(for:) the first that reads with an encoding, and name(forIdentifier:) gives the identifier itself for one the catalog does not know, so nothing recorded is left unnamed.
The Text Encoding pop-up offers these entries too, with Windows-1252 among them ([Choosing the encoding](imports-text-encoding-choice.md)).

### The record
<!-- id: record; keys: LenientOptional, on-disk format, persistence, StoredBookRecord, Add Back, migration; src: TextMouth/Models/TextEncodingRecord.swift, TextMouth/Models/Book.swift, TextMouth/Models/BookInfo.swift, TextMouth/Models/LenientFields.swift, TextMouth/Models/RemovedFromLibraryMarker.swift, TextMouth/Services/FileImportService+Packages.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Parsers/TextFileDecoder.swift, TextMouthProductionTests/BookTextEncodingTests.swift, TextMouthProductionTests/OnDiskContractTests.swift -->

The record: Book.textEncoding holds the identifier of the guess or of the listener's choice, for a plain text, Markdown, or HTML book (BookFormat.usesTextFileDecoder), and Book.textEncodingSource (TextEncodingSource, Models/TextEncodingRecord.swift) who decided it:
- nil for the import, which is every book from before the listener could choose,
- chosen for an encoding the listener chose, and
- automatic for a re-read as Automatic, whose textEncoding is that reading's guess, or nil when it made none, a nil that is the listener's and never a row that lost its encoding.

TextEncodingRecord is the two as one value (identifier, source, isEmpty, isChosen, and policy, which is .chosen(identifier) for a choice and otherwise EncodingPolicy.forBook(recording:)), read and written through Book.textEncodingRecord and BookMetadata.textEncodingRecord.
So a row that holds either is never given half of a record's.
MarkdownCacheService.generateReportedCacheAnalyzeAndStamp sets a guess from GeneratedCache.guessedEncoding, which the cache read returns from DecodedText.guessedEncodingIdentifier.
It also takes the record's from the book's package (Book.recordedTextEncodingRecord()), for a row that has none when no guess is being made.
A choice is set by the re-read, which passes the record to saveContentAnalysis (Reading a book again in another encoding, in [Text caches](text-caches-rereads-edits.md)).
Both are kept in three files, each under keys named textEncoding and textEncodingSource that are written only when set, so a book with neither is exactly as before:

- The library row (library.json), read leniently (Book.init(from:), LenientFields.optionalValue), so a value that cannot be read decodes as none, and a source that cannot be read, as a later TextMouth's might be, decodes as the import's, so the encoding then reads as a guess.
- The package record (BookMetadata.textEncoding and textEncodingSource, in bookInfo.json), @LenientOptional (Models/LenientFields.swift) that decode a missing, null, or unreadable value as none, logged as a repair, without failing the record around it.
  Book.bookInfo(replacing:contentIndex:revisionFloor:decidingTextEncoding:) takes the two as one, by the rule in [Package records](package-records.md): a row that lost the encoding never erases it, and a row that lags behind a re-read never writes the old encoding back.
- The removal marker (RemovedFromLibraryMarker.textEncoding and textEncodingSource, the latter an @LenientOptional that never makes the marker unreadable), which FileImportService.reconstructedBook(inPackage:marker:folderPath:dateAdded:) gives back to a book of a format that reads text files.
  This is because the removal deletes bookInfo.json and a book rebuilt without it would be read by the fallback, and its text would change.
  The marker keeps no source path, so a book added back from a marker that recorded neither has no Text Encoding pop-up (Book.offersTextEncodingChoice).

### Reading the record
<!-- id: reading-record; keys: standing, ownStoredMetadata, dataless, iCloud, StoredBookRecord, analysis summary, library row; src: TextMouth/Models/Book.swift, TextMouth/Models/TextEncodingRecord.swift, TextMouth/Models/CloudStorageContract.swift, TextMouth/ViewModels/ContentAnalysisSummaryBuffer.swift -->

Book.recordedTextEncodingRecord() is what every reading asks: for a book of a format that reads text files, TextEncodingRecord.standing(row:recorded:) of the row's record and the package's stored one; for any other book, the row's.
The stored record stands whenever it holds a decision, else the row's does, else the stored one stands for a row that holds nothing.
The stored record is read without downloading (DatalessFiles.withoutDownloading) and counts only when it names this book (metadata.bookID == id): it is TextEncodingRecord.unrecorded when it names another book (as an old shared package's may), cannot be read, or is only in the cloud.
A row that lost the encoding, as a damaged value in library.json or an older TextMouth's save does, is so read in the record's, and takes it back:
- ContentAnalysisSummary carries the committed book's encoding and source to the row (init(committed:movedPlaces:)),
- a recovered summary takes them only from its own record and a text format (init(recovered:record:)), and
- apply(to:) gives them to a row that has no encoding and no decision, and to a row whose record holds the listener's own decision (a re-read writes it into the record with its new text before the row takes it).
  It otherwise never replaces an encoding the row holds (the rule is in [Package records](package-records.md)).

### Older builds
<!-- id: older-builds; keys: downgrade, older version, backward compatibility, data loss, TextMouth 0.2.2, unknown keys; src: -->

Older builds: a TextMouth from before the encoding's field (FMT16) drops it from the row, the record, and the marker whenever it saves them, and nothing in any can bring it back, so the next rebuild of that book's text reads Windows-1252, as before FMT16.
TextMouth 0.2.2 knows the encoding but not textEncodingSource, and drops the source in the same way, so a choice becomes a guess of the same encoding: the book is read as before, unless the choice overruled valid UTF-8, a byte-order mark, or an HTML declaration, and Book Information says "guessed".
A copy outside these files, such as a note in the package, would hold them; none is kept.

### The words
<!-- id: words; keys: VoiceOver, accessibility, label, wording, BookInfoFacts, Book Information row; src: TextMouth/Models/LibraryInfoWording.swift, TextMouth/Models/TextEncodingChoice.swift, TextMouth/Parsers/TextFileDecoder.swift, TextMouth/Views/Library/LibraryInfoRow.swift, TextMouthProductionTests/TextEncodingBookInfoTests.swift, TextMouthProductionTests/TextEncodingChoiceTests.swift -->

The words: Book.textEncodingDescription says the name of the recorded encoding (TextFileDecoder.chosenEncodingName(forIdentifier:): the catalog's name, "UTF-8", or the identifier itself for one the catalog does not know), then what decided it, ", guessed" or ", chosen".
(TextEncodingReading(record:).description, through TextEncodingWording.describe(name:basis:).)
It is nil for a book that records no encoding and for a format that does not read text files.
Speak Info says it from the row alone and never reads the file.
BookInfoFacts.textEncoding takes the description (Views/Library/LibraryInfoRow.swift).
LibraryInfoWording.fullParts(of:now:calendar:locale:) adds TextEncodingWording.speakInfoPart(_:), "Text encoding: Windows-1251 (Cyrillic), guessed", after the bookmarks, a braille book's code, and its braille file characters, and before the file size.
The brief summary never says it.
Book Information says it too, and what the file says of itself where the book records none, in its pop-up (the Text Encoding pop-up, in [Windows](windows-sheets.md)).
The label, TextEncodingWording.bookInfoLabel, is "Text Encoding", not "Read As", which can be spoken "reed as", the other way to say "read".
TextEncodingBookInfoTests pins the words of Speak Info, and TextEncodingChoiceTests those of the pop-up.

### Logs
<!-- id: text-encoding-logs; keys: DiagnosticLog, debug log, console, log tag, import event; src: TextMouth/Parsers/TextFileDecoder.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift, TextMouthProductionTests/LogContentPolicyTests.swift -->

Logs: TextFileDecoder.readDecodedText logs
- one import event for a read that guessed, `TEXT_ENCODING_GUESS: <file name>: read as windows-1251` (guessLogTag), once, since only the import guesses and a recorded read logs nothing, and
- one for a read by the fallback, `TEXT_ENCODING_FALLBACK: <file name>: decoded as Windows-1252` (fallbackLogTag), on every such read.

Neither holds any of the book's text, and LogContentPolicyTests pins both tags (see [Logs](logs.md)); a re-read in another encoding writes TEXT_ENCODING_CHANGED, pinned there too (Reading a book again in another encoding, in [Text caches](text-caches-rereads-edits.md)).

### Limits of the guess
<!-- id: limits-guess; keys: accuracy, false positive, measured, known limits, TextEncodingFixtures; src: TextMouth/Parsers/TextEncodingGuesser.swift, TextMouth/Parsers/TextEncodingCatalog.swift, TextMouth/Services/DuplicateReplacement.swift, TextMouthProductionTests/TextEncodingFixtures.swift -->

Limits, as the reviewers measured them on thousands of windows of real prose in 30 languages converted to the encodings each is written in, and on tens of thousands of Windows-1252 texts built to look odd:

- Left as Windows-1252:
  - texts too short for the oddities to be more than a few;
  - Hungarian, whose ő and ű Windows-1252 reads as õ and û, and French in ISO 8859-15, whose œ and € it reads as ½ and ¤, which differ from the right reading in a few letters that Windows-1252 text could hold (TextEncodingFixtures.Paragraph.leftToTheDefault pins both);
  - Croatian, Slovenian, and Latvian;
  - short Mac Roman sentences in Spanish, Portuguese, Italian, Dutch, Danish, and German;
  - and any encoding the catalog lacks.
    CP437, CP850, and Mac Central European joined the catalog as entries not always tried (row(_:_:tried:) without tried), so they are taken only when Foundation's own guess names them, and no stored book is read differently.
- Short Hebrew and Cyrillic texts: of 24 short Hebrew excerpts 16 are guessed right and 8 left alone, since Hebrew is called only when Foundation names it.
  Of 92 one-line notes and two-cue subtitles in Windows-1251 and Mac Cyrillic, 22 that an earlier round read right are left garbled: all lack ы, ь, and я, the bytes Windows-1255 cannot read, so its reading is as clean as the Cyrillic one and Foundation's pick is not Hebrew.
  A full paragraph still reads right.
- Identifiers: a file of near-ASCII code whose only non-ASCII letters are capitals inside lowercase names ("zeigeÜbersicht"), in an encoding other than Windows-1252, is left as Windows-1252.
  That is because its right reading holds a case flip for each capital and a rival may hold few anomalies (the disorder limit above).
  The error the other way remains for Windows-1252 code with five camelCase capitals of one letter, or three or more across two letters, whose Mac Roman reading is clean: "listarÕes()" reads "listar’es()".
  Ê (read as a no-break space), Š (as "ä"), Ž (as "é"), Œ, Õ, Ñ, and Ð are such capitals, and since a rival may hold one anomaly, "créerŒuvre" passes too.
  Identifiers inside ordinary French or Spanish prose stay Windows-1252, and the reviewer judged a real file losing this way unlikely.
- Wrong guesses are rare, not none: across 568 excerpts in 28 languages, 402 were guessed right, 1 wrong, and 165 left alone, and of two sets of random windows of real prose 4,090 and 4,088 were right and 120 and 103 wrong.
  Of 14,230 texts of code, notes, product names, headings in capitals, and short files in 8 languages, each drawing on a few accents, 2 (the identifiers that use only a French capital Œ) were guessed away from Windows-1252, where an earlier round guessed away 213.
- A wrong or lost guess is mended by choosing the encoding ([Choosing the encoding](imports-text-encoding-choice.md)).
  Replace Existing carries a chosen encoding over to the new copy under rules (DuplicateReplacement.textEncodingToReadAgain(replacing:with:), in [Replacing a duplicate](imports-duplicates.md)).
  Not done: an encoding an HTML file declares is still read by Foundation's lenient readers, since reading it strictly would change how old books read.
  Also not done: the place mover could keep an offset where a changed stretch is as long in both readings (T06).

### Tests of the decoder
<!-- id: files-tests-decoder; keys: tests, areas.conf, run-area.py, reader-text, TestData, txt-encodings, fixtures; src: TextMouth/Parsers/TextFileDecoder.swift, TextMouth/Parsers/TextEncodingGuesser.swift, TextMouth/Parsers/TextEncodingByteGrammar.swift, TextMouth/Parsers/TextPlausibility.swift, TextMouth/Parsers/TextEncodingCatalog.swift, TextMouth/Models/TextEncodingRecord.swift, TextMouth/Models/TextEncodingChoice.swift, TextMouth/Parsers/BookParser.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/BookContentAnalysisService.swift, TextMouth/Services/FileImportService.swift, TextMouth/Services/FileImportService+Packages.swift, TextMouth/ViewModels/ContentAnalysisSummaryBuffer.swift, TextMouth/Models/Book.swift, TextMouth/Models/BookInfo.swift, TextMouth/Models/LenientFields.swift, TextMouth/Models/RemovedFromLibraryMarker.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/Views/Library/LibraryInfoRow.swift, TextMouth/Views/Library/LibrarySheetViews.swift, Scripts/test/areas.conf, TextMouthProductionTests/TextEncodingGuesserTests.swift, TextMouthProductionTests/TextEncodingFixtures.swift, TextMouthProductionTests/SyntheticWesternText.swift, TextMouthProductionTests/SyntheticAccentedText.swift, TextMouthProductionTests/TextPlausibilityTests.swift, TextMouthProductionTests/TextEncodingCatalogTests.swift, TextMouthProductionTests/TextFileDecoderTests.swift, TextMouthProductionTests/TextEncodingChoiceDecoderTests.swift, TextMouthProductionTests/TextEncodingImportTests.swift, TextMouthProductionTests/BookTextEncodingTests.swift, TextMouthProductionTests/TextEncodingBookInfoTests.swift, TextMouthProductionTests/TextEncodingChoiceTests.swift, TextMouthProductionTests/TextEncodingRereadTests.swift, TextMouthProductionTests/TextEncodingPopUpTests.swift, TextMouthProductionTests/OnDiskContractTests.swift -->

- Tests: the reader-text, import, and library areas of Scripts/test/areas.conf (`python3 Scripts/test/run-area.py reader-text`, and so on).
  - TextEncodingGuesserTests:
    - reads every fixture paragraph (TextEncodingFixtures) back in each encoding it is saved in,
    - reads the 13 files of TestData/format-samples/txt-encodings (nine are guessed, and TextEncodingImportTests imports them all), and
    - checks that 1,500 seeded Western texts (SyntheticWesternText) and 1,500 seeded texts with accented capitals in names and headings (SyntheticAccentedText) are never guessed away;
  - TextPlausibilityTests, TextEncodingCatalogTests, TextFileDecoderTests (the policies and the log), and TextEncodingChoiceDecoderTests (a choice read strictly, the byte grammar, and the limits) are in reader-text;
  - TextEncodingImportTests is in import;
  - BookTextEncodingTests (the row, the record, the marker) and TextEncodingBookInfoTests (the words) are in library, with TextEncodingChoiceTests (the options, the readings, and the pop-up's words) and TextEncodingRereadTests (the re-read);
  - TextEncodingPopUpTests (the hosted pop-up) is in sheets; and
  - OnDiskContractTests pins the keys in the row and the record.
