# Task `codetype`: the braille file code type, its catalog, and the samples' golden test

Team `braillecodes`, lead `braillecodes-lead`. Your slug is `braillecodes-codetype`, your branch `braillecodes/codetype`, made from `team/braillecodes`. Read `Scripts/agents/briefs/2026-10-30/teams-common.md`, "The worker's part", first, and follow it.

## Background (read only what is named here)

A BRF or BRL braille file writes each six-dot cell as one character. TextMouth knows one such code, North American Braille ASCII, fixed in `TextMouth/Parsers/BrailleCells.swift` lines 14-67 (`asciiByDots`, `dotsByASCII`, `cell(forASCII:)`, `ascii(for:)`). The team is making the code a choice: a catalog of three codes, North American Braille ASCII (the default, and what every book that records no code is read as), Eurobraille six-dot (German-speaking Europe), and Unicode braille patterns. The design is `BRAILLE-CODES-RESEARCH-2026-10-25.md`, section 8.2 and Appendix A; you need nothing else from it. This task builds the type and the catalog and changes no behaviour: no reader, writer, setting, or book uses a code other than North American yet (later tasks do).

The lead vendored three liblouis 3.39.0 display tables, unchanged, into `Vendor/liblouis/tables` (commit b04c8ce9): `en-us-brf.dis`, `de-eurobrl6.dis`, `de-eurobrl6u.dis`. The folder is copied whole into the app at `Contents/Resources/liblouis/tables`, which a test reaches as `BrailleTranslator.Tool.helper.tablesFolder` (see `BrailleTranslatorTests.swift` line 280).

## Commit 1, before you change anything: the samples' golden test

The user's text must never change silently: every BRF and BRL book imported so far must read exactly as before. Write `TextMouthProductionTests/BrailleSampleGoldenTests.swift`, class `BrailleSampleGoldenTests`, and record its digests on the branch as you made it, before any other change.

1. The samples, with the table each is read with: `brf/grade2-short.brf` with `en-ueb-g2.ctb`; `brf/pride-and-prejudice-ch1-grade1.brf`, `brf/wrapped-titles.brf`, and `brl/pride-and-prejudice-ch1-grade1.brl` with `en-ueb-g1.ctb`.
2. `testTheListNamesEveryBRFAndBRLSample`: the files of `TestData/format-samples/brf` and `.../brl` whose extension is `brf` or `brl` (any case) are exactly the list. Reach the folders with `formatSampleURL(_:)` (`TextMouthProductionTests/FormatSampleFixtures.swift`), and only list them; never write there.
3. `testEveryBRFAndBRLSampleReadsAsRecorded`: for each sample, import a copy (`copyOfFormatSample(_:)`, then `importedForTest(_:).book`, which removes the package at teardown) with its table bound (`BraillePreferences.$tableForImports.withValue(table) { ... }`), then take three digests with `TextPipelineFixtures.digest`: content.md's bytes (`Data(contentsOf: MarkdownCacheService.cacheURL(for: book))`); the reading (`TextPipelineFixtures.digest(of: opened.content.chapters, index: opened.index)`, where `opened = try BookContentAnalysisService.load(book: book)`); and the Markdown read without pages (`MarkdownCacheService.extractedMarkdown(for: book, includesPages: false)`). Compare each with a `private static let` dictionary keyed by the sample's path. A sample with no record, or one that cannot be imported, fails by name with the digests found, and the others are still compared: copy the shape of `compareWithRecordedOutput` in `TextPipelineGoldenTests.swift` lines 161-180.
4. Capture and restore the library index around each test with `LibraryIndexSandbox`, as `BrailleImportTests.swift` lines 12-29 do.
5. Record: run the class once with empty dictionaries, take the digests from the failure messages, fill them in, and run it again until it passes. The class's doc comment says the digests were recorded on `team/braillecodes` before any change for braille file codes (at the commit your branch starts from), and that a later change that alters them is a change of what a listener hears, to be justified, never re-recorded to pass.
6. `/opt/homebrew/bin/xcodegen generate`; commit the test with `project.pbxproj`.

## Commit 2: the type and the catalog

New file `TextMouth/Parsers/BrailleFileCode.swift`. Comment every type, property, and function. The shapes, with these names:

```swift
/// One seven-bit, six-dot braille file code's table ...
struct SevenBitBrailleTable: Equatable, Sendable {
    /// The byte the code writes for each six-dot cell, at the cell's dot value 0 to 63
    /// (dot 1 counts 1, dot 6 counts 32): 64 distinct printable ASCII bytes, the blank cell's first.
    let bytes: [UInt8]
    /// For each of the 256 byte values, the dot value of the cell it is read as, or 0xFF for none.
    private let dotsByByte: [UInt8]
    init(characters: String, readingAliases: [UInt8: UInt8])
    func dots(forByte byte: UInt8) -> UInt8?
    func byte(forDots dots: UInt8) -> UInt8
    func cell(forByte byte: UInt8) -> Unicode.Scalar?
    func byte(forCell cell: Unicode.Scalar) -> UInt8?
    static let northAmerican: SevenBitBrailleTable
    static let eurobraille: SevenBitBrailleTable
}

/// How a BRF or BRL file writes each braille cell as a character ...
struct BrailleFileCode: Identifiable, Hashable, Sendable {
    enum Kind: Equatable, Sendable {
        case sevenBit(SevenBitBrailleTable)
        case unicodePatterns
    }
    let id: String
    let name: String
    let characterName: String
    let kind: Kind
    var sevenBitTable: SevenBitBrailleTable? { get }
    static let northAmerican: BrailleFileCode
    static let eurobraille: BrailleFileCode
    static let unicode: BrailleFileCode
    static let all: [BrailleFileCode]
    static let defaultCode: BrailleFileCode
    static func code(withID id: String) -> BrailleFileCode?
    static func code(forStored stored: String?) -> BrailleFileCode?
}
```

Behaviour, item by item:

1. `SevenBitBrailleTable.init(characters:readingAliases:)`: `bytes` is the string's UTF-8; `dotsByByte[b]` is the index of `b` in `bytes`; then each alias byte takes its target's entry. No `precondition`, `fatalError`, or force unwrap: the two constants are pinned by tests instead.
2. `dots(forByte:)`: the entry, nil for 0xFF. `cell(forByte:)`: `Unicode.Scalar(0x2800 + dots)`. `byte(forDots:)`: `bytes` at `dots & 0x3F`, read safely (an index past `bytes` gives 0x20, the space; it never happens with the two constants). `byte(forCell:)`: nil unless the scalar is U+2800 to U+283F (use `BrailleCells.isPattern` and `usesEightDots`), else `byte(forDots:)` of its low six bits.
3. `northAmerican`: characters exactly today's `asciiByDots` literal, `#" A1B'K2L@CIF/MSP"E3H9O6R^DJG>NTQ,*5<-U8V.%[$+X!&;:4\0Z7(_?W]#Y)="#`; aliases 0x60...0x7E each to the byte 0x20 below it (today's lowercase rule, `cell(forASCII:)` lines 43-59). Keep the comment that it was verified against liblouis's `en-us-brf.dis`, now naming the test.
4. `eurobraille`: characters `#" a,b.k;l"cif|msp!e:h*o+r>djg`ntq'1?2-u(v$3960x~&<5/8)z={_4w7#y}%"#` (a space, then Appendix A's lowercase string from `de-eurobrl6.dis`, SBS Zürich, 2009); aliases: 0x41...0x5A each to the byte 0x20 above it (capitals read as the lowercase letters); `@ [ \ ] ^` (0x40, 0x5B, 0x5C, 0x5D, 0x5E) each to the byte 0x20 above it (`` ` { | } ~ ``), so the capitals form, `de-eurobrl6u.dis`, "sometimes" used in Switzerland, reads too; and DEL, 0x7F, to `_` (0x5F, dots 4-5-6), since the standard writes that cell as DEL and the table as `_` (its own comment says so). Say all this in comments.
5. The codes, exactly: `northAmerican` is id `ascii-na`, name `North American Braille ASCII`, characterName `braille ASCII`; `eurobraille` is id `ascii-eurobraille`, name `Eurobraille, six-dot (German-speaking countries)`, characterName `Eurobraille`; `unicode` is id `unicode`, name `Unicode braille patterns`, characterName `a Unicode braille pattern`, kind `.unicodePatterns`. `all` lists them in that order (the order every pop-up lists them). `defaultCode` is `northAmerican`. Document that ids are lowercase, permanent, and never reused (a corrected table gets a new id), since books, records, removal markers, and config.json will store them; that `characterName` ends the reader's refusal ("Line 3 holds “é”, which is not braille ASCII."); and that equality and hashing go by `id` alone (write `==` and `hash(into:)` by hand).
6. `code(withID:)`: the code of `all` with exactly that id (case matters), else nil. `code(forStored:)`: `defaultCode` for nil or an empty string (a book that records no code); the code for a known id; nil for any other, which a later task refuses by name and never reads as another code.
7. `BrailleCells` (lines 14-67): keep `asciiByDots`, `cell(forASCII:)`, and `ascii(for:)` with their signatures and behaviour, as forwards to `SevenBitBrailleTable.northAmerican` (`bytes`, `cell(forByte:)`, `byte(forCell:)`), and delete `dotsByASCII` and `firstPattern`/`lastSixDotPattern` only if nothing else in the file uses them (they are used by `isPattern`, `usesEightDots`, `sixDotPart`: keep what is used). Their doc comments say they are North American Braille ASCII always, for the tests' fixtures and anything that names cells by that mnemonic, and that a book's own code lives in `BrailleFileCode`. Change the type's doc comment (lines 14-15) to match. Seven test files use these three: none may need a change.
8. `TextMouth/Parsers/BraillePageAnalyzer.swift`, `printLabel(of:)`, line 892: read each cell with `SevenBitBrailleTable.northAmerican.byte(forCell:)` instead of `BrailleCells.ascii(for:)`, with a comment that the labels name dot patterns by North American Braille ASCII's mnemonic whatever a book's file code is (research section 8.7: the cells are what count, so a Eurobraille book's pages get the same labels). Update the doc comment's mention at lines 867-868. Nothing else in that file.

## Tests: `TextMouthProductionTests/BrailleFileCodeTests.swift`, class `BrailleFileCodeTests`

1. Each seven-bit table: 64 bytes, all distinct, each printable ASCII (0x20 to 0x7E); the blank cell's byte is the space.
2. Every cell round-trips: for dots 0..<64, `dots(forByte: byte(forDots: d)) == d`; for each byte b of `bytes`, `byte(forDots:)` of `dots(forByte: b)` is b (unwrap with `XCTUnwrap`, never `!`).
3. Aliases: North American 0x60...0x7E read as the byte 0x20 below; Eurobraille A to Z as a to z, `@[\]^` as `` `{|}~ ``, and 0x7F as `_` (dots 4-5-6, value 56); no alias byte is one of `bytes`.
4. No cell: 0x00...0x1F in both tables; 0x7F in North American; 0x80...0xFF in both. `byte(forCell:)` is nil for U+2840, U+28FF, and "A".
5. The vendored files, read from the app's tables folder (`BrailleTranslator.Tool.helper.tablesFolder`, via `XCTUnwrap`): a small parser in the test reads each `display` line, field 2 the character (`\s` the space, `\\` the backslash, `\xHHHH` a scalar by its hexadecimal code, otherwise the one character) and field 3 the dots (`0` the blank cell; digits 1 to 6, dot n counting 2^(n-1)); a dots field with any other character is skipped, as `de-eurobrl6.dis`'s `display \s a` is (the German tables' virtual-dot cell for the non-breaking space, no six-dot cell). Each file must give exactly 64 six-dot cells, each once. Then: for `en-us-brf.dis`, `northAmerican.bytes[dots]` is the file's character for all 64; for `de-eurobrl6.dis`, `eurobraille.bytes[dots]` is; for `de-eurobrl6u.dis`, `eurobraille.dots(forByte: character)` is the file's dots for all 64 (the capitals read through the aliases).
6. The two tables agree on exactly 31 of the 64 cells when compared with letters' case folded (the blank, the 26 letters, `#`, `&`, `-`, `_`) and differ on 33: the research's count, which proves why a wrong choice is silent.
7. The catalog: `all.map(\.id)` is `["ascii-na", "ascii-eurobraille", "unicode"]`; the three names and characterNames exactly as above; `defaultCode` is `northAmerican`; `code(withID:)` finds each and gives nil for `ASCII-NA` and `ascii-braillo-no-047-01`; `code(forStored:)` gives North American for nil and "", each code for its id, and nil for an unknown id; two codes are equal only when their ids are.

Run, through the wrapper: `BrailleFileCodeTests BrailleSampleGoldenTests BrailleCellsTests BraillePageAnalyzerTests BrailleFileReaderTests BrailleFileWriterTests BrailleLayoutTests BrailleBookPageTests`. Then `make lint-tests LINT_BASE=team/braillecodes`.

## Do not

- Touch the reader, the writer, `BrailleBookReader`, any book or record type, settings, or any `*.md` file.
- Edit `Scripts/test/areas.conf`: the lead places your new classes.
- Read anything under `~/.TextMouth`, or the Mac's own liblouis folder (`/System/Library/ScreenReader/...`).

## Builds

Your team builds one at a time. You may build as soon as you are ready: the lead has given you the team's build. When your last build ends, remove your build folder at once (the two commands under "Builds" in `teams-common.md`) and say so in your `done:` post.
