import Foundation
import XCTest
@testable import TextMouth

// Tests of the person's file of own interface lines (FR39 phase 10, steps 2 and 5): reading and checking it against the
// pack, line by line, and the one writer behind Edit Interface Text… and Export Interface Text….
//
// Shared with the iPhone's unit bundle (project.yml), with the helpers of `InterfaceTextTests.swift`. Everything here is
// pure: the files are bytes in memory, the pack is made in memory, and no hostile text reaches Foundation's formatter
// (the check parses it and refuses it first).

// MARK: - Support

/// Tables made in memory that also hold notes, as the shipped pack does.
private struct NotedTables: InterfaceTextTables {
    let inner: InterfaceTextMemoryTables
    let noteOf: [String: String]

    func idList() throws -> InterfaceTextIDList { try inner.idList() }
    func entries(language: String) throws -> [InterfaceTextEntry] { try inner.entries(language: language) }
    func notes() throws -> [String] { inner.ids.map { noteOf[$0] ?? "" } }
}

/// The pack the tests read against: a plain line, a plural line, a line with two arguments (a string and a number), a line
/// with a literal percent sign, and a line of no arguments that holds a lone `%`.
private let overridesLines: [String: [String: String]] = [
    "common.sleepTimer": ["en": "Sleep Timer", "es": "Temporizador de apagado", "fr": "Minuterie"],
    "common.countMinutes": [
        "en": pluralEntry("%lld minute", "%lld minutes"),
        "es": pluralEntry("un minuto", "%lld de minutos", "%lld minutos"),
        "fr": pluralEntry("%lld minute", "%lld de minutes", "%lld minutes"),
    ],
    "feed.opening": ["en": "Opening %@, part %lld", "es": "Abriendo %@, parte %lld"],
    "sync.progress": ["en": "%lld%% done", "es": "%lld%% hecho"],
    "sale.banner": ["en": "Save 50%", "es": "Ahorra 50%"],
]

/// The notes of the lines above.
private let overridesNotes = ["common.sleepTimer": "The sleep timer's title.", "feed.opening": "%@ is a feed's title."]

/// A reference for `language` over the pack above.
private func makeReference(language: String = "es") throws -> InterfaceTextReference {
    let tables = NotedTables(inner: InterfaceTextMemoryTables(lines: overridesLines), noteOf: overridesNotes)
    let engine = InterfaceTextEngine(tables: tables, report: { _ in })
    return try XCTUnwrap(engine.reference(language: language))
}

/// The bytes of a file holding `lines` for `language`.
private func fileData(_ lines: [String: Any], language: String = "es", version: Any? = 1) throws -> Data {
    var root: [String: Any] = ["languages": [language: ["lines": lines]]]
    if let version { root["version"] = version }
    return try JSONSerialization.data(withJSONObject: root)
}

/// The outcome of a file holding `lines` for `language`.
private func readOutcome(of lines: [String: Any], language: String = "es") throws -> InterfaceTextOverridesOutcome {
    InterfaceTextOverridesFile.read(try fileData(lines, language: language), reference: try makeReference())
}

/// The one reason a lone line is ignored for, failing the test when it applies or is left alone.
private func reason(
    of line: [String: Any], id: String = "common.sleepTimer", language: String = "es",
    file: StaticString = #filePath, line number: UInt = #line
) throws -> InterfaceTextIgnoredReason? {
    let result = try readOutcome(of: [id: line], language: language)
    XCTAssertEqual(result.inUse.count + result.ignored.count + result.unchanged, 1, file: file, line: number)
    return result.ignored.first?.reason
}

// MARK: - The base rule

final class InterfaceTextOverridesFileTests: XCTestCase {
    /// A line whose text differs from its base is the person's own: it applies, in the language it is under.
    func testALineChangedFromItsBaseApplies() throws {
        let result = try readOutcome(of: ["common.sleepTimer": ["text": "Temporizador", "base": "Temporizador de apagado"]])

        XCTAssertEqual(result.lines, ["es": ["common.sleepTimer": .plain("Temporizador")]])
        XCTAssertEqual(result.inUse, [.init(language: "es", id: "common.sleepTimer")])
        XCTAssertEqual(result.ignored, [])
        XCTAssertNil(result.fileProblem)
    }

    /// A line left as it was never applies, so it keeps taking each update's better wording.
    func testALineLeftAloneNeverApplies() throws {
        let result = try readOutcome(of: ["common.sleepTimer": ["text": "Temporizador de apagado", "base": "Temporizador de apagado"]])

        XCTAssertEqual(result.lines, [:])
        XCTAssertEqual(result.unchanged, 1)
        XCTAssertEqual(result.inUse, [])
        XCTAssertEqual(result.ignored, [])
    }

    /// A line with no base (written by hand, or copied from someone else's Export) applies in full.
    func testALineWithNoBaseApplies() throws {
        let result = try readOutcome(of: ["common.sleepTimer": ["text": "Temporizador de apagado"]])

        XCTAssertEqual(result.lines["es"]?["common.sleepTimer"], .plain("Temporizador de apagado"))
        XCTAssertEqual(result.unchanged, 0)
    }

    /// The same rule for plural forms: changed from `basePlural` applies, equal never does, and none applies.
    func testPluralLinesFollowTheSameRule() throws {
        let forms = ["one": "un minuto", "many": "%lld de minutos", "other": "%lld minutos"]
        var changed = forms
        changed["other"] = "%lld min"

        let result = try readOutcome(of: [
            "common.countMinutes": ["plural": changed, "basePlural": forms],
        ])
        XCTAssertEqual(result.lines["es"]?["common.countMinutes"], .plural(["un minuto", "%lld de minutos", "%lld min"]))

        XCTAssertEqual(try readOutcome(of: ["common.countMinutes": ["plural": forms, "basePlural": forms]]).unchanged, 1)
        XCTAssertEqual(try readOutcome(of: ["common.countMinutes": ["plural": changed]]).inUse.count, 1)
    }

    /// A line left alone is not examined, so a line an update retired or reshaped is not reported to someone who never
    /// touched it: its ID, its language, and its shape may all be out of date.
    func testALineLeftAloneIsNotReportedWhateverIsWrongWithIt() throws {
        let result = try readOutcome(of: [
            "retired.line": ["text": "x", "base": "x"],
            "common.countMinutes": ["text": "%s", "base": "%s"],
        ])

        XCTAssertEqual(result.unchanged, 2)
        XCTAssertEqual(result.ignored, [])
    }

    /// Lines are kept by language, so a file may hold several, and each line is judged in its own.
    func testSeveralLanguagesInOneFile() throws {
        let root: [String: Any] = [
            "version": 1,
            "languages": [
                "es": ["lines": ["common.sleepTimer": ["text": "Temporizador"]]],
                "fr": ["lines": ["common.sleepTimer": ["text": "Minuteur"]]],
                "xx": ["lines": ["common.sleepTimer": ["text": "Kronos"]]],
            ],
        ]

        let result = InterfaceTextOverridesFile.read(try JSONSerialization.data(withJSONObject: root), reference: try makeReference())

        XCTAssertEqual(result.lines["es"]?["common.sleepTimer"], .plain("Temporizador"))
        XCTAssertEqual(result.lines["fr"]?["common.sleepTimer"], .plain("Minuteur"))
        XCTAssertEqual(result.ignored.map(\.reason), [.unknownLanguage])
        XCTAssertEqual(result.ignored.map(\.key.language), ["xx"])
    }

    /// Two keys that name one language (`es` and `es-MX`) with the same line: the first, in order of the keys, is in use once,
    /// and the other is ignored and says it is shadowed; the line is not listed twice as in use.
    func testTwoKeysNamingOneLanguageDoNotCollideSilently() throws {
        let root: [String: Any] = ["version": 1, "languages": [
            "es": ["lines": ["common.sleepTimer": ["text": "Uno"]]],
            "es-MX": ["lines": ["common.sleepTimer": ["text": "Dos"], "feed.opening": ["text": "Abriendo %@ (%lld)"]]],
        ]]

        let result = InterfaceTextOverridesFile.read(try JSONSerialization.data(withJSONObject: root), reference: try makeReference())

        XCTAssertEqual(result.lines["es"]?["common.sleepTimer"], .plain("Uno"))
        XCTAssertEqual(result.lines["es"]?["feed.opening"], .plain("Abriendo %@ (%lld)"))
        XCTAssertEqual(result.inUse.map(\.id), ["common.sleepTimer", "feed.opening"], "no line is listed twice")
        XCTAssertEqual(result.ignored.map(\.reason), [.shadowed])
        XCTAssertEqual(result.ignored.first?.key, InterfaceTextOverridesOutcome.Key(language: "es-MX", id: "common.sleepTimer"))
        XCTAssertEqual(result.ignored.first?.carriedLanguage, "es")
    }

    // MARK: - The rules of a line

    func testAnUnknownLanguageIsIgnored() throws {
        XCTAssertEqual(try reason(of: ["text": "Kronos"], language: "tlh"), .unknownLanguage)
    }

    func testAnUnknownIDIsIgnored() throws {
        XCTAssertEqual(try reason(of: ["text": "Hola"], id: "common.sleeptimer"), .unknownID)
        XCTAssertEqual(try reason(of: ["text": "Hola"], id: ""), .unknownID)
    }

    func testTextForAPluralLineIsIgnored() throws {
        XCTAssertEqual(try reason(of: ["text": "%lld minutos"], id: "common.countMinutes"), .textForPluralLine)
    }

    func testPluralFormsForAPlainLineAreIgnored() throws {
        XCTAssertEqual(try reason(of: ["plural": ["one": "a", "many": "b", "other": "c"]]), .pluralForPlainLine)
    }

    func testAShapeThatIsNotALineIsIgnored() throws {
        XCTAssertEqual(try reason(of: [:]), .noText)
        XCTAssertEqual(try reason(of: ["text": "a", "plural": ["other": "b"]]), .bothTextAndPlural)
        XCTAssertEqual(try reason(of: ["text": 5]), .notALine)
        XCTAssertEqual(try reason(of: ["text": ["one": "a"]]), .notALine)
        XCTAssertEqual(try reason(of: ["plural": "a"]), .notALine)
        XCTAssertEqual(try reason(of: ["plural": ["one": 1]]), .notALine)
        let notAnObject = try readOutcome(of: ["common.sleepTimer": "Hola"])
        XCTAssertEqual(notAnObject.ignored.map(\.reason), [.notALine])
    }

    // MARK: - Hostile placeholders

    /// A hostile line is ignored with a reason, and its text is only ever parsed by the specifier check: none of these
    /// reaches Foundation's formatter, where a `%s`, a `%n`, or an argument that is not there would crash or read memory.
    func testHostileSpecifiersAreIgnored() throws {
        let hostile: [(text: String, id: String, reason: InterfaceTextIgnoredReason)] = [
            ("Hola %s", "feed.opening", .unsupportedSpecifier),
            ("Hola %n", "feed.opening", .unsupportedSpecifier),
            ("%d minutos", "sync.progress", .unsupportedSpecifier),
            ("%.2f", "sync.progress", .unsupportedSpecifier),
            ("%lld%", "sync.progress", .unsupportedSpecifier),
            ("100%", "sync.progress", .unsupportedSpecifier),
            ("%99$@", "feed.opening", .placeholdersDiffer),
            ("%0$@", "feed.opening", .unsupportedSpecifier),
            ("%123$@", "feed.opening", .unsupportedSpecifier),
            ("Abriendo %5$@, parte %2$lld", "feed.opening", .placeholdersDiffer),
            ("Abriendo %@, parte %@", "feed.opening", .placeholdersDiffer),
            ("Abriendo %lld, parte %lld", "feed.opening", .placeholdersDiffer),
            ("Abriendo %@", "feed.opening", .placeholdersDiffer),
            ("Abriendo %@, parte %lld y %lld", "feed.opening", .placeholdersDiffer),
            ("Abriendo %1$@, parte %lld", "feed.opening", .mixedPlaceholders),
            ("Abriendo %@, parte %2$lld", "feed.opening", .mixedPlaceholders),
            ("Abriendo %1$@ %2$lld %1$lld", "feed.opening", .placeholdersDiffer),
            ("%lld hecho", "sync.progress", .percentSignsDiffer),
            ("%lld%%%% hecho", "sync.progress", .percentSignsDiffer),
            ("Hecho %%", "sync.progress", .placeholdersDiffer),
            ("Parte %2$lld", "feed.opening", .placeholdersDiffer),
            ("Abriendo %-5@, parte %lld", "feed.opening", .unsupportedSpecifier),
            ("Abriendo %5@, parte %lld", "feed.opening", .unsupportedSpecifier),
            ("Abriendo %*d, parte %lld", "feed.opening", .unsupportedSpecifier),
            ("Abriendo %.3@, parte %lld", "feed.opening", .unsupportedSpecifier),
            ("Abriendo %@, parte %lld, 100%\u{301}", "feed.opening", .unsupportedSpecifier),
            ("Hola %@", "common.sleepTimer", .placeholdersDiffer),
            ("Hola %%", "common.sleepTimer", .percentSignsDiffer),
        ]
        for item in hostile {
            XCTAssertEqual(try reason(of: ["text": item.text], id: item.id), item.reason, "\(item.text) in \(item.id)")
        }
    }

    /// A line may reorder its placeholders with positions, and may say its literal percent sign.
    func testPlaceholdersMayMoveWithPositions() throws {
        let result = try readOutcome(of: [
            "feed.opening": ["text": "Parte %2$lld: abriendo %1$@"],
            "sync.progress": ["text": "Hecho: %lld%%"],
        ])

        XCTAssertEqual(result.ignored, [])
        XCTAssertEqual(result.inUse.count, 2)
    }

    /// A line of no arguments that holds a lone `%` in its English ("Save 50%") is never given to the formatter, so
    /// neither is the person's text for it.
    func testALoneSignInTheEnglishOfANoArgumentLineIsAllowed() throws {
        let result = try readOutcome(of: ["sale.banner": ["text": "¡Ahorra 50% hoy!"]])

        XCTAssertEqual(result.ignored, [])
        XCTAssertEqual(result.lines["es"]?["sale.banner"], .plain("¡Ahorra 50% hoy!"))
    }

    // MARK: - Hostile forms

    func testEmptyFormsAreIgnored() throws {
        XCTAssertEqual(try reason(of: ["text": ""]), .emptyForm)
        XCTAssertEqual(try reason(of: ["text": "  \n\t "]), .emptyForm)
        XCTAssertEqual(try reason(of: ["plural": ["one": "", "many": "%lld", "other": "%lld"]], id: "common.countMinutes"), .emptyForm)
    }

    func testControlCharactersAreIgnoredExceptLineFeedAndTab() throws {
        XCTAssertEqual(try reason(of: ["text": "a\u{0}b"]), .controlCharacter)
        XCTAssertEqual(try reason(of: ["text": "a\rb"]), .controlCharacter)
        XCTAssertEqual(try reason(of: ["text": "a\u{1B}[0mb"]), .controlCharacter)
        XCTAssertEqual(try reason(of: ["text": "a\u{1}b"]), .controlCharacter)
        XCTAssertEqual(try reason(of: ["text": "a\u{7F}b"]), .controlCharacter)
        XCTAssertNil(try reason(of: ["text": "a\nb\tc"]))
    }

    // MARK: - Plural categories

    func testPluralFormsMustBeExactlyTheLanguagesCategories() throws {
        // Spanish: one, many, other.
        XCTAssertEqual(try reason(of: ["plural": ["one": "a", "other": "%lld"]], id: "common.countMinutes"), .wrongPluralForms)
        XCTAssertEqual(
            try reason(of: ["plural": ["one": "a", "many": "%lld", "other": "%lld", "zero": "%lld"]], id: "common.countMinutes"),
            .wrongPluralForms
        )
        XCTAssertEqual(try reason(of: ["plural": ["uno": "a", "many": "%lld", "other": "%lld"]], id: "common.countMinutes"), .wrongPluralForms)
        XCTAssertEqual(try reason(of: ["plural": [String: String]()], id: "common.countMinutes"), .wrongPluralForms)
    }

    /// A `one` form may leave the number out where it means exactly 1 ("un minuto"); French's covers 0, so its form may not.
    func testOnlyAOneFormThatMeansExactlyOneMayDropTheNumber() throws {
        XCTAssertNil(try reason(of: ["plural": ["one": "un minuto", "many": "%lld de minutos", "other": "%lld minutos"]], id: "common.countMinutes"))
        XCTAssertEqual(
            try reason(of: ["plural": ["one": "une minute", "many": "%lld de minutes", "other": "%lld minutes"]], id: "common.countMinutes", language: "fr"),
            .placeholdersDiffer
        )
        XCTAssertEqual(
            try reason(of: ["plural": ["one": "%lld minuto", "many": "minutos", "other": "%lld minutos"]], id: "common.countMinutes"),
            .placeholdersDiffer,
            "a form other than one must show the number"
        )
    }

    // MARK: - English that changed

    /// A line in use whose `english` is not the line's English now still applies, and is listed.
    func testALineWhoseEnglishChangedStillAppliesAndIsListed() throws {
        let result = try readOutcome(of: [
            "common.sleepTimer": ["text": "Temporizador", "english": "Sleep Timer (old)"],
            "feed.opening": ["text": "Abriendo %@ (%lld)", "english": "Opening %@, part %lld"],
            "common.countMinutes": [
                "plural": ["one": "un min", "many": "%lld de min", "other": "%lld min"],
                "english": ["one": "%lld minute", "other": "%lld mins"],
            ],
        ])

        XCTAssertEqual(result.inUse.count, 3)
        XCTAssertEqual(result.outdatedEnglish.map(\.id), ["common.countMinutes", "common.sleepTimer"])
    }

    // MARK: - The whole file

    func testAFileThatIsNotJSONIsIgnoredWhole() throws {
        let reference = try makeReference()
        for text in ["not json", "{\"version\": 1,", "[]", "5", "\"text\""] {
            let result = InterfaceTextOverridesFile.read(Data(text.utf8), reference: reference)
            XCTAssertNotNil(result.fileProblem, text)
            XCTAssertEqual(result.lines, [:], text)
        }
        XCTAssertEqual(InterfaceTextOverridesFile.read(Data("not json".utf8), reference: reference).fileProblem, .notJSON)
        XCTAssertEqual(InterfaceTextOverridesFile.read(Data("[]".utf8), reference: reference).fileProblem, .notThisShape)
    }

    func testAFileThatIsNotThisShapeIsIgnoredWhole() throws {
        let reference = try makeReference()
        let shapes: [[String: Any]] = [
            [:],
            ["version": 1],
            ["version": 1, "languages": []],
            ["version": 1, "languages": ["es": "lines"]],
            ["version": 1, "languages": ["es": [:]]],
            ["version": 1, "languages": ["es": ["lines": []]]],
            // One good language does not rescue a file with a bad one.
            ["version": 1, "languages": ["es": ["lines": ["common.sleepTimer": ["text": "x"]]], "fr": 5]],
        ]
        for shape in shapes {
            let result = InterfaceTextOverridesFile.read(try JSONSerialization.data(withJSONObject: shape), reference: reference)
            XCTAssertEqual(result.fileProblem, .notThisShape, "\(shape)")
            XCTAssertEqual(result.lines, [:], "\(shape)")
        }
    }

    func testAnUnknownVersionIsIgnoredWholeAndAMissingOneIsRead() throws {
        let lines: [String: Any] = ["common.sleepTimer": ["text": "Temporizador"]]

        XCTAssertEqual(InterfaceTextOverridesFile.read(try fileData(lines, version: 2), reference: try makeReference()).fileProblem, .unknownVersion)
        XCTAssertEqual(InterfaceTextOverridesFile.read(try fileData(lines, version: "1"), reference: try makeReference()).fileProblem, .unknownVersion)
        let hand = InterfaceTextOverridesFile.read(try fileData(lines, version: nil), reference: try makeReference())
        XCTAssertNil(hand.fileProblem)
        XCTAssertEqual(hand.inUse.count, 1)
    }

    func testAnEmptyFileIsNoLinesAndNoProblem() throws {
        let reference = try makeReference()
        XCTAssertEqual(InterfaceTextOverridesFile.read(Data(), reference: reference), .empty)
        XCTAssertEqual(InterfaceTextOverridesFile.read(Data(" \n\t\r\n".utf8), reference: reference), .empty)
    }

    func testAFileLargerThanAnyRealOneIsIgnoredWhole() throws {
        let big = Data(repeating: 0x20, count: InterfaceTextOverridesFile.largestSize + 1) + Data("{}".utf8)
        XCTAssertEqual(InterfaceTextOverridesFile.read(big, reference: try makeReference()).fileProblem, .tooLarge)
    }

    // MARK: - Never reaches the formatter

    /// Even a hostile line that was handed to the engine directly (past the file's check) shows English: the engine checks
    /// the person's line against the call's own arguments, once more, at each lookup.
    func testTheEngineRefusesAHostileLineOfItsOwn() {
        let engine = makeInterfaceTextEngine(overridesLines, log: InterfaceTextReportLog())
        engine.setOverrides(["es": ["feed.opening": .plain("Abriendo %s %n %5$@")]])

        XCTAssertEqual(
            interfaceLine(engine, "feed.opening", "Opening \("Atlas"), part \(number: 2)"),
            "Opening Atlas, part 2"
        )
    }

    /// The lines that apply reach a lookup, and a line left alone keeps the pack's text.
    func testAppliedLinesWinAtALookupAndOthersKeepThePacksText() throws {
        let result = try readOutcome(of: [
            "common.sleepTimer": ["text": "Temporizador", "base": "Temporizador de apagado"],
            "feed.opening": ["text": "Abriendo %@, parte %lld", "base": "Abriendo %@, parte %lld"],
            "common.countMinutes": ["plural": ["one": "1 min", "many": "%lld de min", "other": "%lld min"]],
        ])
        let engine = makeInterfaceTextEngine(overridesLines, log: InterfaceTextReportLog())
        engine.setOverrides(result.lines)
        let count = 5

        XCTAssertEqual(interfaceLine(engine, "common.sleepTimer", "Sleep Timer"), "Temporizador")
        XCTAssertEqual(interfaceLine(engine, "feed.opening", "Opening \("Atlas"), part \(number: 2)"), "Abriendo Atlas, parte 2")
        XCTAssertEqual(interfaceLine(engine, "common.countMinutes", "\(number: count) minutes"), "5 min")
    }

    // MARK: - The writer

    /// Edit's fill makes the file with the language's every line as the pack has it, each with the same value as `base`,
    /// its English, and its note.
    func testFillMakesTheFileWithEveryLineAndItsBase() throws {
        let reference = try makeReference()

        let data = try XCTUnwrap(InterfaceTextOverridesWriter.filled(existing: nil, reference: reference))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(root["version"] as? Int, 1)
        let lines = try XCTUnwrap(((root["languages"] as? [String: Any])?["es"] as? [String: Any])?["lines"] as? [String: [String: Any]])
        XCTAssertEqual(Set(lines.keys), Set(overridesLines.keys))
        let timer = try XCTUnwrap(lines["common.sleepTimer"])
        XCTAssertEqual(timer["text"] as? String, "Temporizador de apagado")
        XCTAssertEqual(timer["base"] as? String, "Temporizador de apagado")
        XCTAssertEqual(timer["english"] as? String, "Sleep Timer")
        XCTAssertEqual(timer["note"] as? String, "The sleep timer's title.")
        XCTAssertNil(lines["sync.progress"]?["note"], "a line with no note writes none")
        let minutes = try XCTUnwrap(lines["common.countMinutes"])
        XCTAssertEqual(minutes["plural"] as? [String: String], ["one": "un minuto", "many": "%lld de minutos", "other": "%lld minutos"])
        XCTAssertEqual(minutes["basePlural"] as? [String: String], minutes["plural"] as? [String: String])
        XCTAssertEqual(minutes["english"] as? [String: String], ["one": "%lld minute", "other": "%lld minutes"])
        XCTAssertNil(minutes["text"])
        XCTAssertNil(timer["changed"])
    }

    /// What the fill wrote is read back as every line left alone: nothing applies, nothing is ignored.
    func testAFilledFileAppliesNothing() throws {
        let reference = try makeReference()
        let data = try XCTUnwrap(InterfaceTextOverridesWriter.filled(existing: nil, reference: reference))

        let result = InterfaceTextOverridesFile.read(data, reference: reference)

        XCTAssertNil(result.fileProblem)
        XCTAssertEqual(result.inUse, [])
        XCTAssertEqual(result.ignored, [])
        XCTAssertEqual(result.unchanged, overridesLines.count)
    }

    /// The pack stores a plural whose forms all read alike as one text (`pack.py`), but a line is plural by its English, so a
    /// fill and an Export write it as `plural` in every language, and read it back whole. The writer and the reader take
    /// the line's kind from the English entry, the one answer for every language.
    func testAPluralLineTheLanguageStoresAsOneTextIsStillPlural() throws {
        let tables = InterfaceTextMemoryTables(lines: [
            "a.count": ["en": pluralEntry("%lld item", "%lld item"), "ja": "%lld 件", "es": pluralEntry("un elemento", "%lld de elementos", "%lld elementos"), "ru": "%lld шт."],
            "a.page": ["en": "Page %lld", "ja": "%lld ページ"],
        ])
        let engine = InterfaceTextEngine(tables: tables, report: { _ in })
        let english = try XCTUnwrap(engine.reference(language: "en"))

        for language in ["en", "ja", "es", "ru"] {
            let reference = try XCTUnwrap(engine.reference(language: language))
            let fill = try XCTUnwrap(InterfaceTextOverridesWriter.filled(existing: nil, reference: reference))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: fill) as? [String: Any])
            let lines = try XCTUnwrap(((root["languages"] as? [String: Any])?[language] as? [String: Any])?["lines"] as? [String: [String: Any]])
            let names = try XCTUnwrap(PluralRules.categories[language])
            XCTAssertEqual(Set((lines["a.count"]?["plural"] as? [String: String] ?? [:]).keys), Set(names), language)
            XCTAssertNil(lines["a.count"]?["text"], language)
            XCTAssertNotNil(lines["a.page"]?["text"], language)

            let read = InterfaceTextOverridesFile.read(fill, reference: english)
            XCTAssertEqual(read.ignored, [], language)
            XCTAssertEqual(read.unchanged, 2, language)
            let exported = InterfaceTextOverridesFile.read(InterfaceTextOverridesWriter.export(reference: reference, own: [:]), reference: english)
            XCTAssertEqual(exported.ignored, [], language)
            XCTAssertEqual(exported.inUse.count, 2, language)
        }
    }

    /// A line the pack has no text for in the language is filled with the English, its plural forms taken by name.
    func testALineTheLanguageLacksIsFilledWithTheEnglish() throws {
        // A pack with no Spanish at all, so every line falls back to its English.
        let tables = InterfaceTextMemoryTables(lines: [
            "a.plain": ["en": "Plain"],
            "a.count": ["en": pluralEntry("%lld item", "%lld items")],
        ])
        let engine = InterfaceTextEngine(tables: tables, report: { _ in })

        let data = try XCTUnwrap(InterfaceTextOverridesWriter.filled(existing: nil, reference: try XCTUnwrap(engine.reference(language: "es"))))
        let lines = try XCTUnwrap((((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["languages"] as? [String: Any])?["es"] as? [String: Any])?["lines"] as? [String: [String: Any]])

        XCTAssertEqual(lines["a.plain"]?["text"] as? String, "Plain")
        XCTAssertEqual(lines["a.count"]?["plural"] as? [String: String], ["one": "%lld item", "many": "%lld items", "other": "%lld items"])
    }

    /// A file that lacks the interface language gets it, and every other language stays exactly as it was.
    func testFillAddsTheLanguageAndKeepsTheOthers() throws {
        let existing: [String: Any] = [
            "version": 1,
            "comment": "mine",
            "languages": ["fr": ["lines": ["common.sleepTimer": ["text": "Minuteur"]]]],
        ]
        let reference = try makeReference(language: "es")

        let data = try XCTUnwrap(InterfaceTextOverridesWriter.filled(
            existing: try JSONSerialization.data(withJSONObject: existing), reference: reference
        ))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let languages = try XCTUnwrap(root["languages"] as? [String: Any])

        XCTAssertEqual(Set(languages.keys), ["es", "fr"])
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: languages["fr"] ?? [:], options: .sortedKeys),
            try JSONSerialization.data(withJSONObject: (existing["languages"] as? [String: Any])?["fr"] ?? [:], options: .sortedKeys)
        )
        XCTAssertEqual(root["comment"] as? String, "mine")
        XCTAssertEqual(root["version"] as? Int, 1)
    }

    /// What Edit leaves of the person's other content stays what it was: numbers stay numbers (`0.5`, a whole number past
    /// `Int`'s range, `true`), and another language's lines keep their content with the fields in the fixed order, `text`
    /// before `base` and the plural forms in the language's own order, though the person's editor had them the other way.
    func testFillKeepsTheOtherContentAsItWasAndInTheFixedOrder() throws {
        let existing = Data(#"""
        {"version": 1, "weight": 0.5, "big": 18446744073709551615, "flag": true, "nothing": null,
         "languages": {"fr": {"lines": {
           "common.sleepTimer": {"base": "Minuterie", "english": "Sleep Timer", "text": "Minuteur", "extra": 2.25},
           "common.countMinutes": {"basePlural": {"other": "b", "many": "b", "one": "b"}, "plural": {"other": "c", "many": "d", "one": "e"}}
         }}}}
        """#.utf8)

        let data = try XCTUnwrap(InterfaceTextOverridesWriter.filled(existing: existing, reference: try makeReference(language: "es")))
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.contains("\"weight\": 0.5"), text)
        XCTAssertTrue(text.contains("\"big\": 18446744073709551615"), text)
        XCTAssertTrue(text.contains("\"flag\": true"), text)
        XCTAssertTrue(text.contains("\"extra\": 2.25"), text)
        XCTAssertFalse(text.contains("\"0.5\""))
        let french = try XCTUnwrap(text.range(of: "\"fr\""))
        let textKey = try XCTUnwrap(text.range(of: "\"text\": \"Minuteur\"", range: french.upperBound..<text.endIndex))
        let baseKey = try XCTUnwrap(text.range(of: "\"base\": \"Minuterie\"", range: french.upperBound..<text.endIndex))
        XCTAssertTrue(textKey.lowerBound < baseKey.lowerBound, "text comes before base in a language Edit did not fill")
        let one = try XCTUnwrap(text.range(of: "\"one\": \"e\""))
        let many = try XCTUnwrap(text.range(of: "\"many\": \"d\""))
        let other = try XCTUnwrap(text.range(of: "\"other\": \"c\""))
        XCTAssertTrue(one.lowerBound < many.lowerBound && many.lowerBound < other.lowerBound, "French forms are in French's order")
        // And it is still the same JSON as it was for what was kept.
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(parsed["weight"] as? Double, 0.5)
    }

    /// The person's edits are theirs: a file that has the language is left as it is, so is one that is not JSON or not the
    /// file's shape (the person is mending it), and an empty file is filled.
    func testFillLeavesAFileThatHasTheLanguageOrIsBeingMended() throws {
        let reference = try makeReference()
        let hasIt = try fileData(["common.sleepTimer": ["text": "x"]])
        XCTAssertNil(InterfaceTextOverridesWriter.filled(existing: hasIt, reference: reference))
        XCTAssertNil(InterfaceTextOverridesWriter.filled(existing: try fileData([:]), reference: reference))
        XCTAssertNil(InterfaceTextOverridesWriter.filled(existing: Data("{ not json".utf8), reference: reference))
        XCTAssertNil(InterfaceTextOverridesWriter.filled(existing: Data("[1]".utf8), reference: reference))
        XCTAssertNil(InterfaceTextOverridesWriter.filled(existing: Data("{\"version\": 1}".utf8), reference: reference))
        XCTAssertNotNil(InterfaceTextOverridesWriter.filled(existing: Data(" \n".utf8), reference: reference))
    }

    /// A line is written with the field to edit first and its twin last (`text`, `english`, `note`, `base`), and plural forms
    /// in the language's own order (`one`, `many`, `other`), not alphabetically, so a screen reader meets `base` last.
    func testAFilledLineIsWrittenInAFixedOrder() throws {
        let reference = try makeReference()

        let text = String(decoding: try XCTUnwrap(InterfaceTextOverridesWriter.filled(existing: nil, reference: reference)), as: UTF8.self)

        func offset(_ needle: String, after start: String.Index? = nil) throws -> String.Index {
            let range = try XCTUnwrap(text.range(of: needle, range: (start ?? text.startIndex)..<text.endIndex), needle)
            return range.lowerBound
        }
        let timer = try offset("\"common.sleepTimer\"")
        let first = try offset("\"text\"", after: timer)
        let english = try offset("\"english\"", after: first)
        let note = try offset("\"note\"", after: english)
        let base = try offset("\"base\"", after: note)
        XCTAssertTrue(first < english && english < note && note < base)
        let minutes = try offset("\"common.countMinutes\"")
        let plural = try offset("\"plural\"", after: minutes)
        let one = try offset("\"one\"", after: plural)
        let many = try offset("\"many\"", after: one)
        let other = try offset("\"other\"", after: many)
        let basePlural = try offset("\"basePlural\"", after: other)
        XCTAssertTrue(plural < one && one < many && many < other && other < basePlural)
        XCTAssertTrue(text.hasPrefix("{\n  \"version\": 1,\n  \"languages\": {"), text.prefix(60).description)
    }

    /// An Export puts `changed` after the note, and the person's own line in the same order.
    func testAnExportedLineIsWrittenInAFixedOrderToo() throws {
        let reference = try makeReference()
        let text = String(decoding: InterfaceTextOverridesWriter.export(reference: reference, own: ["common.sleepTimer": .plain("Temporizador")]), as: UTF8.self)

        let timer = try XCTUnwrap(text.range(of: "\"common.sleepTimer\""))
        let note = try XCTUnwrap(text.range(of: "\"note\"", range: timer.upperBound..<text.endIndex))
        let changed = try XCTUnwrap(text.range(of: "\"changed\"", range: note.upperBound..<text.endIndex))
        let first = try XCTUnwrap(text.range(of: "\"text\"", range: timer.upperBound..<text.endIndex))
        XCTAssertTrue(first.lowerBound < note.lowerBound && note.lowerBound < changed.lowerBound)
    }

    /// Text with quotes, backslashes, line feeds, and non-ASCII letters is escaped as JSON needs and read back as it was.
    func testTheWritersEscapesReadBackExactly() throws {
        let tables = InterfaceTextMemoryTables(lines: ["a.line": ["en": "Say \"hi\"\\\n\tÜ 你好", "es": "Di \"hola\"\\\n\tÁ 世界 \u{1F600}"]])
        let engine = InterfaceTextEngine(tables: tables, report: { _ in })
        let reference = try XCTUnwrap(engine.reference(language: "es"))

        let data = try XCTUnwrap(InterfaceTextOverridesWriter.filled(existing: nil, reference: reference))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let line = try XCTUnwrap((((parsed["languages"] as? [String: Any])?["es"] as? [String: Any])?["lines"] as? [String: [String: Any]])?["a.line"])

        XCTAssertEqual(line["text"] as? String, "Di \"hola\"\\\n\tÁ 世界 \u{1F600}")
        XCTAssertEqual(line["english"] as? String, "Say \"hi\"\\\n\tÜ 你好")
    }

    /// A file whose version this TextMouth does not know is left as it is, whatever it holds.
    func testFillLeavesAFileOfAnUnknownVersion() throws {
        let reference = try makeReference()
        let other = Data(#"{"version": 2, "languages": {"fr": {"lines": {}}}}"#.utf8)

        XCTAssertNil(InterfaceTextOverridesWriter.filled(existing: other, reference: reference))
        XCTAssertTrue(InterfaceTextOverridesWriter.hasUnknownVersion(other))
        XCTAssertFalse(InterfaceTextOverridesWriter.hasUnknownVersion(Data(#"{"version": 1}"#.utf8)))
        XCTAssertFalse(InterfaceTextOverridesWriter.hasUnknownVersion(Data(#"{"languages": {}}"#.utf8)))
        XCTAssertFalse(InterfaceTextOverridesWriter.hasUnknownVersion(Data("not json".utf8)))
    }

    /// A language written as the rest of the app names one (`pt`, `zh`, `es-MX`) is a carried language; it applies under that
    /// language's name.
    func testALanguageKeyIsNamedAsTheRestOfTheAppNamesOne() throws {
        let result = try readOutcome(of: ["common.sleepTimer": ["text": "Temporizador"]], language: "es-MX")

        XCTAssertEqual(result.ignored, [])
        XCTAssertEqual(result.lines["es"]?["common.sleepTimer"], .plain("Temporizador"))
    }

    /// The same bytes every time, so two fills are alike and a file in a synced folder does not churn.
    func testTheWriterIsDeterministic() throws {
        let reference = try makeReference()

        XCTAssertEqual(
            InterfaceTextOverridesWriter.filled(existing: nil, reference: reference),
            InterfaceTextOverridesWriter.filled(existing: nil, reference: reference)
        )
        XCTAssertEqual(
            InterfaceTextOverridesWriter.export(reference: reference, own: [:]),
            InterfaceTextOverridesWriter.export(reference: reference, own: [:])
        )
    }

    /// Export writes every line as it now reads, the person's own in place of the pack's with `"changed": true`, each
    /// with its English and note, and no `base`.
    func testExportWritesTheLinesAsTheyReadNowWithTheOwnOnesMarked() throws {
        let reference = try makeReference()
        let own: [String: InterfaceTextEntry] = [
            "common.sleepTimer": .plain("Temporizador"),
            "common.countMinutes": .plural(["un min", "%lld de min", "%lld min"]),
        ]

        let data = InterfaceTextOverridesWriter.export(reference: reference, own: own)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let lines = try XCTUnwrap(((root["languages"] as? [String: Any])?["es"] as? [String: Any])?["lines"] as? [String: [String: Any]])

        XCTAssertEqual(Set(lines.keys), Set(overridesLines.keys))
        XCTAssertEqual(lines["common.sleepTimer"]?["text"] as? String, "Temporizador")
        XCTAssertEqual(lines["common.sleepTimer"]?["changed"] as? Bool, true)
        XCTAssertEqual(lines["common.sleepTimer"]?["english"] as? String, "Sleep Timer")
        XCTAssertEqual(lines["common.sleepTimer"]?["note"] as? String, "The sleep timer's title.")
        XCTAssertEqual(lines["common.countMinutes"]?["plural"] as? [String: String], ["one": "un min", "many": "%lld de min", "other": "%lld min"])
        XCTAssertEqual(lines["common.countMinutes"]?["changed"] as? Bool, true)
        XCTAssertEqual(lines["feed.opening"]?["text"] as? String, "Abriendo %@, parte %lld")
        XCTAssertNil(lines["feed.opening"]?["changed"])
        for (_, line) in lines {
            XCTAssertNil(line["base"])
            XCTAssertNil(line["basePlural"])
            XCTAssertNotNil(line["english"])
        }
    }

    /// An Export read back applies every line in full (it has no base), so someone who imports it gets all of it, and
    /// every text of the pack passes the file's own check, the Spanish `one` form that drops its number included.
    func testAnExportAppliesInFullWhenReadBack() throws {
        let reference = try makeReference()
        let data = InterfaceTextOverridesWriter.export(reference: reference, own: [:])

        let result = InterfaceTextOverridesFile.read(data, reference: reference)

        XCTAssertNil(result.fileProblem)
        XCTAssertEqual(result.ignored, [])
        XCTAssertEqual(result.inUse.count, overridesLines.count)
        XCTAssertEqual(result.outdatedEnglish, [])
        XCTAssertEqual(result.lines["es"]?["common.sleepTimer"], .plain("Temporizador de apagado"))
    }

    /// English can be exported and filled too: its lines are its own English.
    func testEnglishIsFilledFromItsOwnLines() throws {
        let reference = try makeReference(language: "en")

        let data = try XCTUnwrap(InterfaceTextOverridesWriter.filled(existing: nil, reference: reference))
        let result = InterfaceTextOverridesFile.read(data, reference: reference)

        XCTAssertEqual(result.unchanged, overridesLines.count)
        XCTAssertEqual(result.ignored, [])
    }
}
