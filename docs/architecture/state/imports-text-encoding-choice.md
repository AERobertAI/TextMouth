# Imports: choosing the encoding
<!-- id: imports-choosing-encoding; keys: charset, code page, mojibake, wrong encoding, TextEncodingChoices, strict decoding; src: -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## Choosing the encoding
<!-- id: choosing-encoding; keys: mojibake, charset, code page, re-read, TextEncodingOption, Shift JIS, Big5, strict decoding; src: TextMouth/Models/TextEncodingChoice.swift, TextMouth/Models/TextEncodingRecord.swift, TextMouth/Parsers/TextEncodingByteGrammar.swift, TextMouth/Parsers/TextFileDecoder.swift, TextMouth/Parsers/TextEncodingGuesser.swift, TextMouth/Parsers/TextEncodingCatalog.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift, TextMouthProductionTests/TextEncodingChoiceDecoderTests.swift, TextMouthProductionTests/TextEncodingChoiceTests.swift -->

Choosing the encoding (encodingchoice): the listener's way to mend a wrong or missed guess, from Book Information's Text Encoding pop-up (the sheet and its model, in [Windows](windows-sheets.md); the re-read, in [Text caches](text-caches-rereads-edits.md)).
What is here is what the options and the decoder do with a choice.

- The options: TextEncodingChoices (Models/TextEncodingChoice.swift) lists them as TextEncodingOption values:
  - .automatic (automaticName, "Automatic"),
  - then .encoding("utf-8") (TextFileDecoder.utf8Identifier; UTF-8 is not in the catalog, which holds what a guess can name),
  - then each name of TextEncodingCatalog.entries once, in the catalog's order, by the identifier of the first entry that has the name (compared by its TextEncodingCatalog.Label, never by the localized text it shows) and named as the catalog names it, Windows-1252 first.
  - The catalog gives Shift JIS, GBK, Big5, and EUC-KR two entries each, Windows' variant and the standard it extends, so one option stands for both:
    - identifiers(of:) lists every entry of an option's name in the catalog's order,
    - LibraryViewModel.validatedChoice(of:for:) tries them in turn until one reads every byte, and
    - the book records the identifier that did, so a Big5 file with 碁 as Windows writes it (0xF9 0xD6, which Big5 itself lacks) is read and recorded as cp950.
  - TextEncodingChoices.option(forIdentifier:) and option(for:) go the other way, from what a book records, or what a reading was made in, to the option that names it.
  - They give nil for UTF-16, UTF-32, and an encoding an HTML file declares that the catalog lacks, which the pop-up then lists as an item of its own.

### The strict reading and the byte grammar
<!-- id: strict-reading-byte-grammar; keys: strictlyDecodedText, byte grammar, malformed bytes, TextEncodingByteGrammar, Foundation faults, replacement character; src: TextMouth/Parsers/TextFileDecoder.swift, TextMouth/Parsers/TextEncodingByteGrammar.swift, TextMouth/Parsers/TextEncodingGuesser.swift, TextMouthProductionTests/TextEncodingChoiceDecoderTests.swift -->

- The strict reading: TextFileDecoder.strictlyDecodedText(_:in:) reads data in an encoding with every byte belonging to a character the encoding defines and none dropped or replaced, and gives nil when one does not.
  - Windows-1252 and the encodings read as it (windows1252Equivalents) take every byte (windows1252Text(_:));
  - UTF-8 is String(data:encoding:), which refuses every malformed sequence;
  - a multi-byte encoding's bytes must first keep to its grammar (next); and
  - any other is Foundation's, which refuses a byte the encoding does not define, with a result holding U+FFFD refused too, since none of these encodings defines a byte as it.
  The strict reading is not the guesser's rule, which also asks the text to write back to the same bytes, because that refuses valid text with two codes for one character, as Windows writes 髙 in CP932 (0xFB 0xFC, which Foundation writes back as 0xEE 0xE0).
  A listener who chooses Shift JIS must be able to read it.
- The byte grammar: TextEncodingByteGrammar (Parsers/TextEncodingByteGrammar.swift) says which byte sequences make the characters of each multi-byte encoding of the catalog:
  - .sequences, the bytes that stand alone and the lead bytes that begin a character of two, three, or four bytes with the bytes that may follow, or
  - .iso2022JP, which switches character sets with escape sequences (isWellFormedISO2022JP(_:requiringAShift:), which the guesser asks too).
  TextEncodingByteGrammar.grammarsByIdentifier pairs each grammar with the identifiers of the catalog it reads.
  TextEncodingByteGrammar.of(_:) finds an encoding's grammar by the String.Encoding Foundation reads it with, nil for an encoding of one byte to a character, and admits(_:) says whether every byte belongs to a character and none is cut off at the end.
  TextEncodingChoiceDecoderTests pins that every multi-byte encoding of the catalog has one.
- Why it exists: Foundation's readers of several of these encodings let malformed bytes through, as measured on macOS 26.3.
  EUC-JP and GB 2312 read a byte that cannot follow a lead byte as though its top bit were set, so the letter after it is taken into another character.
  Shift JIS reads 0x7F after a lead byte as 0x80.
  EUC-JP reads its single shift 0x8E before any byte.
  ISO-2022-JP reads bytes above ASCII as Latin 1, and a cut-off escape sequence as the escape and its letters.
  GB 18030 reads a lone 0x80 as the euro sign.
  Checking the bytes against the grammar first refuses all of these.
- What no grammar can mend, since which characters an encoding defines is Foundation's to say:
  - EUC-JP's JIS X 0212 characters (the single shift 0x8F and two bytes) are refused, left out of the eucJP grammar because Foundation takes the last of the three bytes for the start of another character, so "Le café." with é so written reads "Le café窺";
  - the euro sign in Big5 and CP950 (0xA3 0xE1) and in EUC-KR and CP949 (0xA2 0xE6), and Big5-HKSCS's characters (0x87 0x40 and up), even through Core Foundation's own big5-hkscs, are refused by Foundation's reader;
  - CP950's 0xA2 0xCC reads as 十 followed by U+F87F, a private-use character that a braille display shows; and
  - a GB 18030 file holding a literal U+FFFD is refused by the replacement-character check.

### What a book is read in now
<!-- id: read-in-now; keys: TextEncodingReading, TextEncodingRowState, Book Information row, offersTextEncodingChoice, in the cloud; src: TextMouth/Models/TextEncodingChoice.swift, TextMouth/Models/TextEncodingRecord.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/Models/Book.swift, TextMouthProductionTests/TextEncodingChoiceTests.swift -->

- What a book is read in now: TextEncodingReading (Models/TextEncodingChoice.swift) has
  - init?(record:), from the book's record without its file, with the basis chosen or guessed and nil when the record names no encoding;
  - init(decoded:), from a reading of the file, which maps DecodedText.Basis (chosen, byteOrderMark, unmarkedUnicode, validUTF8, declaration to declared, recorded and guess to guessed, fallback to defaultEncoding); and
  - current(of:access:), which asks the record first (Book.recordedTextEncodingRecord()) and then reads the file with the book's policy, never downloading it.
    A file only in the cloud is TextEncodingRowState.unknown with TextEncodingWording.inCloudValue, and one that cannot be read unreadableValue.
  TextEncodingWording.describe(name:basis:) words a reading, the notes being guessNote, chosenNote, byteOrderMarkNote, unmarkedUnicodeNote, declaredNote, and defaultNote, and valid UTF-8 having none.
  Book.offersTextEncodingChoice says which books have the pop-up.
  A plain text, Markdown, or HTML book (usesTextFileDecoder) that is not a feed's item and either has a sourceFilePath, which an import notes (text typed in, a recording, and a book added back from its removal marker have none), or records an encoding or a decision about one.
- Tests: listed in [Tests of the decoder](imports-text-encodings.md).
