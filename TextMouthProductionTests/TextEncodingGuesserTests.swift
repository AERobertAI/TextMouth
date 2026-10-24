import XCTest
@testable import TextMouth

/// The guess at the encoding of a text file whose bytes name none (FMT16):
/// Mac Roman, Central European, Cyrillic, Greek, Hebrew, Arabic, Thai,
/// Japanese, Chinese, and Korean text is found, text that Windows-1252 reads
/// correctly is never guessed away from it, and a file that cannot be told
/// from its bytes is left to the default.
final class TextEncodingGuesserTests: XCTestCase {

    // MARK: - Helpers

    /// `text` written as a file in the encoding named `name`: the bytes, and
    /// the text they hold, less the characters the encoding cannot write.
    private func file(_ text: String, inEncodingNamed name: String) throws -> (bytes: Data, text: String) {
        let encoding = try XCTUnwrap(TextEncodingFixtures.encoding(named: name), name)
        let written = TextEncodingFixtures.writable(text, in: encoding)
        let bytes = try XCTUnwrap(written.data(using: encoding, allowLossyConversion: false), name)
        return (bytes, written)
    }

    /// The first paragraph of the fixtures in `language`.
    private func paragraph(in language: String) throws -> String {
        try XCTUnwrap(TextEncodingFixtures.paragraphs.first { $0.language == language }, language).text
    }

    // MARK: - Prose in Its Own Encoding

    /// A paragraph of prose is read back exactly in each encoding a file in
    /// its language is saved in, with one exception that is the point: a
    /// file Windows-1252 reads correctly (Windows-1252 itself, ISO Latin 1)
    /// is not guessed at.
    func testEveryFixtureParagraphIsReadRightInEachOfItsEncodings() throws {
        for paragraph in TextEncodingFixtures.paragraphs {
            for name in paragraph.encodings {
                let (bytes, text) = try file(paragraph.text, inEncodingNamed: name)
                let context = "\(paragraph.language) in \(name)"
                let guess = TextEncodingGuesser.guess(bytes)
                if TextEncodingFixtures.defaultEncodings.contains(name) {
                    XCTAssertNil(guess, context)
                    XCTAssertEqual(TextFileDecoder.windows1252Text(bytes), text, context)
                } else {
                    XCTAssertEqual(guess?.text, text, context)
                }
            }
        }
    }

    /// The guesser names the encodings the brief is about: Mac Roman, Central
    /// European, and Cyrillic files are named by their encodings, and
    /// Windows-1251 is not mistaken for KOI8-R or the other way round.
    func testTheMainEncodingsAreNamedForWhatTheyAre() throws {
        let cases: [(language: String, encoding: String, identifier: String)] = [
            ("French", "macintosh", "macintosh"),
            ("German", "macintosh", "macintosh"),
            ("English", "macintosh", "macintosh"),
            ("Czech", "windows-1250", "windows-1250"),
            ("Polish", "iso-8859-2", "iso-8859-2"),
            ("Russian", "windows-1251", "windows-1251"),
            ("Russian", "koi8-r", "koi8-r"),
            ("Russian", "cp866", "cp866"),
            ("Russian", "iso-8859-5", "iso-8859-5"),
            ("Ukrainian", "koi8-u", "koi8-u"),
            ("French in Latin 9", "iso-8859-15", "iso-8859-15"),
            ("Greek", "windows-1253", "windows-1253"),
            ("Turkish", "windows-1254", "windows-1254"),
            ("Hebrew", "windows-1255", "iso-8859-8"),
            ("Thai", "windows-874", "cp874"),
            ("Japanese", "euc-jp", "euc-jp"),
        ]
        for (language, encoding, identifier) in cases {
            let (bytes, _) = try file(paragraph(in: language), inEncodingNamed: encoding)
            XCTAssertEqual(TextEncodingGuesser.guess(bytes)?.identifier, identifier, "\(language) in \(encoding)")
        }
    }

    // MARK: - The Sample Files

    /// The 13 short files in TestData/format-samples/txt-encodings, each
    /// naming nothing: the nine that are not Windows-1252 read as the text
    /// they hold, and the two that Windows-1252 reads correctly are left to
    /// it. (The UTF-8 and UTF-16 files never reach the guesser.)
    func testTheSampleFilesAreReadRight() throws {
        let western = "Café au lait for the señor — naïve, “quoted” text with über-accents: à è ì ò ù ß.\n"
        let cases: [(file: String, text: String?)] = [
            ("mac-roman", western + "Second line: the price is EUR5 (not GBP5).\n"),
            ("windows-1250", "Příliš žluťoučký kůň úpěl ďábelské ódy.\nZażółć gęślą jaźń.\n"),
            ("iso-8859-2", "Příliš žluťoučký kůň úpěl ďábelské ódy.\nZażółć gęślą jaźń.\n"),
            ("windows-1251", "Съешь же ещё этих мягких французских булок, да выпей чаю.\nПаром отходит в семь.\n"),
            ("koi8-r", "Съешь же ещё этих мягких французских булок, да выпей чаю.\nПаром отходит в семь.\n"),
            ("shift-jis", "いろはにほへと ちりぬるを わかよたれそ つねならむ。\nフェリーは七時に出ます。\n"),
            ("euc-jp", "いろはにほへと ちりぬるを わかよたれそ つねならむ。\nフェリーは七時に出ます。\n"),
            ("big5", "天地玄黃，宇宙洪荒。\n渡輪七點開。\n"),
            ("gb18030", "天地玄黄，宇宙洪荒。\n渡轮七点开。\n"),
            // Windows-1252 reads these two correctly, so nothing is guessed.
            ("windows-1252", nil),
            ("iso-8859-1", nil),
        ]
        for (name, expected) in cases {
            let url = try formatSampleURL("txt-encodings/\(name).txt")
            let bytes = try Data(contentsOf: url)
            let guess = TextEncodingGuesser.guess(bytes)
            if let expected {
                XCTAssertEqual(guess?.text, expected, name)
            } else {
                XCTAssertNil(guess, name)
            }
        }
    }

    // MARK: - Text Windows-1252 Reads Right

    /// Genuine Windows-1252 and Latin 1 texts built to look odd to the
    /// guesser stay as they are: the acute accent typed as an apostrophe,
    /// units and symbols, capitals with accents, the names of many
    /// languages in one text, bullets between words, unspaced dashes,
    /// Spanish and German punctuation, and files of a word or two. Each was
    /// once or could have been read as something else by a rule that was
    /// too eager.
    func testTextThatWindows1252ReadsRightIsNeverGuessedAwayFromIt() throws {
        let texts = [
            "I don´t think they´re coming, and it´s getting late. Where´s the café? Let´s ask the waiter at the naïve little bar.",
            "The sample was heated to 25°C for 5 µs, then cooled; the area is 3 m² and the volume 2 m³. A tolerance of ±0.5 mm, 2×4 timber, and ¼ + ½ = ¾ of a cup. Prices: £10, ¥100, 50¢.",
            "Windows® and Office™ are trademarks of Microsoft©. Visit our store® for the best price™, with Café© and Naïve® products.",
            "ÉCOLE NORMALE SUPÉRIEURE. ÜBER ALLES. ÀÉÎÕÜ. ZÜRICH, MÜNCHEN, ÅRHUS, MÁLAGA. ¿QUÉ PASA? ¡OLÉ!",
            "« Où allez-vous ? » demanda-t-il. « À Paris, répondit-elle, pour y voir l’exposition des œuvres d’Émile. » Il était déjà tard ; ils se turent, et le train, à l’heure, quitta la gare d’Austerlitz.",
            "¿Cómo está usted? ¡Qué sorpresa! El niño comió piña en la montaña, y después, cansado, se fue a dormir. Mañana será otro día; ¿no cree?",
            "Er sagte: „Das Wetter ist schön“, und sie antwortete: „Ja, aber morgen soll es regnen.“ Die Straße war nass, der Käse teuer, und der Bürgermeister hielt eine lange Rede über die Wärme.",
            "References: Müller (1998), Gödel (1931), Poincaré (1902), Tschaïkovski, Søren Kierkegaard, Åse Berg, Bjørn Ås, Françoise Lefèvre, Núñez de Balboa, Sjöberg, Kuçuk. Also Brontë and Zoë.",
            "Home • About • Contact • Blog • Café • Shop — Welcome to our naïve little site… We’re open 9–5, Monday–Friday.",
            "The old man—tired, hungry, and cold—walked on; he never looked back—not once—until the road ended… “Enough,” he said.",
            "Résumé",
            "café au lait",
            "Zürich — 5 €",
            "È tardi, e la città è ormai silenziosa. Più tardi, forse, uscirò a fare due passi; perché no? Così, almeno, potrò pensare a quello che è successo ieri.",
            "Það var þriðjudagur og veðrið var gott. Hann fór út með hundinn sinn, og þau gengu lengi meðfram ánni. Ég held að hann hafi verið ánægður.",
            "The conference in Zürich featured talks by Müller, a French chef who served crème brûlée, jalapeño soufflé, and smörgåsbord with piñata cake. Naïve? Perhaps. Déjà vu: fiancée, résumé, façade, coöperate.",
            "<p>Café — “quotes” and ‘single’ — © 2024 • Terms</p>\n<p>Año nuevo — ¡feliz!</p>",
        ]
        for text in texts {
            for name in ["windows-1252", "iso-8859-1"] {
                let encoding = try XCTUnwrap(TextEncodingFixtures.encoding(named: name))
                // Some of these cannot be written in Latin 1; they are only tried where they can.
                guard let bytes = text.data(using: encoding, allowLossyConversion: false) else { continue }
                XCTAssertNil(TextEncodingGuesser.guess(bytes), "\(name): \(text.prefix(40))")
            }
        }
    }

    /// A short file whose few accented letters fit several encodings alike
    /// is left to the default: a Mac Roman sentence of two accents reads as
    /// Central European, KOI8, or Mac Roman equally well.
    func testAFewAccentsThatFitSeveralEncodingsAreLeftAlone() throws {
        let (bytes, _) = try file("«Qui è sempre andata così»", inEncodingNamed: "macintosh")
        XCTAssertNil(TextEncodingGuesser.guess(bytes))
    }

    // MARK: - Nothing to Guess From

    /// A file with no byte above ASCII has nothing to guess from, and
    /// neither has an empty one.
    func testNothingIsGuessedFromBytesAllInASCII() {
        XCTAssertNil(TextEncodingGuesser.guess(Data()))
        XCTAssertNil(TextEncodingGuesser.guess(Data("Plain text, all ASCII.\nSecond line.\n".utf8)))
    }

    /// Bytes that are no text are not guessed at: pseudo-random bytes, a
    /// file of zeros with one accented byte, and Russian text with a tenth of
    /// its bytes replaced by control characters.
    func testBytesThatAreNoTextAreNotGuessed() throws {
        // A fixed pseudo-random sequence, so that the result is the same every run.
        var state: UInt64 = 0x2026_1024
        var random = Data()
        for _ in 0..<50_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            random.append(UInt8(truncatingIfNeeded: state >> 33))
        }
        XCTAssertNil(TextEncodingGuesser.guess(random))

        XCTAssertNil(TextEncodingGuesser.guess(Data(repeating: 0, count: 10_000) + Data([0xE9])))

        var (russian, _) = try file(paragraph(in: "Russian"), inEncodingNamed: "windows-1251")
        for index in stride(from: 0, to: russian.count, by: 10) { russian[index] = 0x01 }
        XCTAssertNil(TextEncodingGuesser.guess(russian))
    }

    /// UTF-8 text with a defect (a stray byte in it, or a last character cut
    /// short) is not guessed at: the reading it has always had stays, and no
    /// other encoding is named for text that is almost all UTF-8.
    func testUTF8TextWithADefectIsNotGuessed() throws {
        for language in ["French", "Russian", "Polish", "Greek", "Japanese", "Simplified Chinese", "Korean", "Hebrew"] {
            let utf8 = Data(try paragraph(in: language).utf8)
            var stray = utf8
            stray.insert(0xE9, at: stray.count / 2)
            XCTAssertNil(TextEncodingGuesser.guess(stray), "\(language): a stray byte")
            XCTAssertNil(TextEncodingGuesser.guess(utf8.dropLast()), "\(language): a cut last character")
        }
    }

    /// No byte is dropped or replaced to make a file fit: a Shift_JIS text
    /// with a byte that begins no character is read by no encoding, and so
    /// is not guessed.
    func testAFileNoEncodingReadsWholeIsNotGuessed() throws {
        var (japanese, _) = try file(paragraph(in: "Japanese"), inEncodingNamed: "shift_jis")
        japanese.insert(0xFF, at: japanese.count / 2)
        XCTAssertNil(TextEncodingGuesser.guess(japanese))
    }

    // MARK: - Large Files

    /// The whole file is read in the guessed encoding, though only some of
    /// it is examined: a long file with nothing but ASCII for megabytes and
    /// its Cyrillic text at the very end is found at the end, and read to
    /// the last byte; and a long file of ASCII with one accented byte at the
    /// end is left alone.
    func testALongFileIsGuessedFromTheLinesWithAccentedBytes() throws {
        let (russian, text) = try file(paragraph(in: "Russian"), inEncodingNamed: "windows-1251")
        let preamble = String(repeating: "A long line of plain ASCII that says nothing at all.\n", count: 80_000)
        XCTAssertGreaterThan(preamble.utf8.count, 4_000_000)
        let guess = try XCTUnwrap(TextEncodingGuesser.guess(Data(preamble.utf8) + russian))
        XCTAssertEqual(guess.identifier, "windows-1251")
        XCTAssertEqual(guess.text, preamble + text)

        XCTAssertNil(TextEncodingGuesser.guess(Data(preamble.utf8) + Data([0x0A, 0xE9, 0x0A])))
    }

    /// Text in an encoding with several megabytes of Cyrillic is guessed
    /// from the part examined and read whole, down to the last byte, and the
    /// reading writes back to the same bytes.
    func testALargeFileIsReadWholeAndWritesBackToTheSameBytes() throws {
        let (russian, text) = try file(paragraph(in: "Russian"), inEncodingNamed: "koi8-r")
        var large = Data()
        var expected = ""
        for _ in 0..<2_500 {
            large.append(russian)
            expected += text
        }
        XCTAssertGreaterThan(large.count, 1_000_000)
        let guess = try XCTUnwrap(TextEncodingGuesser.guess(large))
        XCTAssertEqual(guess.identifier, "koi8-r")
        XCTAssertEqual(guess.text, expected)
        XCTAssertEqual(guess.text.data(using: guess.encoding, allowLossyConversion: false), large)
    }

    /// A classic Mac OS file ends its lines with a carriage return alone, so
    /// it has no line feed to find lines by, and is examined all the same.
    func testALineEndedByACarriageReturnAloneIsExamined() throws {
        let (russian, text) = try file(paragraph(in: "Russian"), inEncodingNamed: "windows-1251")
        var classic = Data()
        var expected = ""
        for _ in 0..<40 {
            classic.append(russian)
            classic.append(0x0D)
            expected += text + "\r"
        }
        XCTAssertFalse(classic.contains(0x0A))
        let guess = try XCTUnwrap(TextEncodingGuesser.guess(classic))
        XCTAssertEqual(guess.text, expected)
    }

    /// A single line is examined whole up to four times the part examined,
    /// and cut beyond that where it splits no character, in a multi-byte
    /// encoding too: Shift_JIS on one line with no ASCII byte at all is read
    /// whole when it is under four times the part examined; one longer, with
    /// a space now and then, is cut at a space; and one longer with no ASCII
    /// byte has nowhere to be cut, and is left out, so nothing is guessed.
    func testALineLongerThanTheSampleIsCutWithoutSplittingACharacter() throws {
        let (japanese, text) = try file(paragraph(in: "Japanese"), inEncodingNamed: "shift_jis")
        let limit = TextEncodingGuesser.sampleLimit

        var solid = Data()
        var expectedSolid = ""
        for _ in 0..<200 {
            solid.append(japanese)
            expectedSolid += text
        }
        XCTAssertGreaterThan(solid.count, limit)
        XCTAssertLessThan(solid.count, 4 * limit)
        XCTAssertEqual(TextEncodingGuesser.guess(solid)?.text, expectedSolid)

        var spaced = Data()
        var expectedSpaced = ""
        for _ in 0..<800 {
            spaced.append(japanese)
            spaced.append(0x20)
            expectedSpaced += text + " "
        }
        XCTAssertGreaterThan(spaced.count, 4 * limit)
        XCTAssertEqual(TextEncodingGuesser.guess(spaced)?.text, expectedSpaced)

        var unbroken = Data()
        for _ in 0..<800 { unbroken.append(japanese) }
        XCTAssertGreaterThan(unbroken.count, 4 * limit)
        XCTAssertNil(TextEncodingGuesser.guess(unbroken))
    }

    // MARK: - Names and Repeatability

    /// Readings that read the same differ only in name: the catalog's first
    /// is used, so Russian text KOI8-R and KOI8-U read alike is named KOI8-R,
    /// while Ukrainian text, which only KOI8-U reads, is named KOI8-U.
    func testReadingsThatReadAlikeAreNamedByTheCatalogsOrder() throws {
        let (russian, _) = try file(paragraph(in: "Russian"), inEncodingNamed: "koi8-r")
        XCTAssertEqual(TextEncodingGuesser.guess(russian)?.identifier, "koi8-r")
        let (ukrainian, _) = try file(paragraph(in: "Ukrainian"), inEncodingNamed: "koi8-u")
        XCTAssertEqual(TextEncodingGuesser.guess(ukrainian)?.identifier, "koi8-u")
    }

    /// The same bytes always give the same guess.
    func testTheSameBytesGiveTheSameGuessEveryTime() throws {
        for (language, name) in [("French", "macintosh"), ("Czech", "windows-1250"), ("Russian", "koi8-r"), ("Japanese", "shift_jis")] {
            let (bytes, _) = try file(paragraph(in: language), inEncodingNamed: name)
            let first = TextEncodingGuesser.guess(bytes)
            XCTAssertNotNil(first, name)
            for _ in 0..<3 {
                XCTAssertEqual(TextEncodingGuesser.guess(bytes), first, name)
            }
        }
    }
}
