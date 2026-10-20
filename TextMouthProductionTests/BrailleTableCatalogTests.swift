import XCTest
@testable import TextMouth

/// The braille tables TextMouth offers, read from the tables' own metadata
/// (FMT21), the codes they make, the words that name them, and the setting
/// that chooses one. Nothing here touches the real preferences store or
/// plays sound.
@MainActor
final class BrailleTableCatalogTests: XCTestCase {

    // MARK: - The Bundled Catalog

    /// The four tables the app bundles are offered, in the order language,
    /// system (ebae before ueb), contraction, with the metadata their files
    /// give, and the helper can load every one.
    func testTheBundledCatalogOffersFourTablesInOrder() throws {
        let tables = BrailleTableCatalog.bundled
        XCTAssertEqual(tables.map(\.id), ["en-us-g1.ctb", "en_US.tbl", "en-ueb-g1.ctb", "en-ueb-g2.ctb"])
        guard tables.count == 4 else { return }

        XCTAssertEqual(tables[0].displayName, "English uncontracted braille as used in the U.S.")
        XCTAssertEqual(tables[1].displayName, "English contracted braille as used in the U.S.")
        XCTAssertEqual(tables[2].displayName, "Unified English uncontracted braille")
        XCTAssertEqual(tables[3].displayName, "Unified English contracted braille")
        XCTAssertEqual(tables.map(\.language), ["en", "en", "en", "en"])
        XCTAssertEqual(tables.map(\.system), ["ebae", "ebae", "ueb", "ueb"])
        XCTAssertEqual(tables.map(\.contraction), [.no, .full, .no, .full])
        XCTAssertEqual(tables.map(\.grade), ["1", "2", "1", "2"])
        XCTAssertEqual(tables[3].indexName, "English, unified, contracted")

        let work = try makeSandboxDirectory("BrailleCatalogCheck")
        for table in tables {
            XCTAssertNoThrow(try BrailleTranslator.check(table: table.id, workingIn: work), table.id)
        }
    }

    /// The default table is bundled, and a table is found by its file name.
    func testTheDefaultTableIsBundledAndFoundByName() {
        XCTAssertEqual(BrailleTableCatalog.defaultTableID, "en-ueb-g2.ctb")
        XCTAssertEqual(BrailleTableCatalog.table(withID: "en-ueb-g2.ctb")?.system, "ueb")
        XCTAssertNil(BrailleTableCatalog.table(withID: "nonsense.ctb"))
        // An included file is in the folder but is not offered.
        XCTAssertNil(BrailleTableCatalog.table(withID: "en-ueb-chardefs.uti"))
    }

    // MARK: - Codes and Words

    /// The tables make two codes, each with an uncontracted and a
    /// contracted table, named as the listener hears them.
    func testTheCodesAndTheirWords() {
        let codes = BrailleTableCatalog.bundledCodes
        XCTAssertEqual(codes.map(\.id), ["en/ebae", "en/ueb"])
        XCTAssertEqual(codes.map(\.name), ["English Braille, American Edition", "Unified English Braille"])
        for code in codes {
            XCTAssertEqual(code.tables.map(\.contraction), [.no, .full], code.id)
            XCTAssertEqual(code.tables.map(\.contractionLabel), ["Uncontracted (Grade 1)", "Contracted (Grade 2)"], code.id)
        }
        XCTAssertEqual(codes.last?.tables.map(\.id), ["en-ueb-g1.ctb", "en-ueb-g2.ctb"])
        XCTAssertEqual(BrailleTableCatalog.languageName("en"), Locale.current.localizedString(forLanguageCode: "en"))
        XCTAssertEqual(BrailleTableCatalog.languageName("zz-not-a-language"), "zz-not-a-language")

        XCTAssertEqual(
            BrailleTableCatalog.description(ofTableID: "en-ueb-g2.ctb"),
            "Unified English Braille, contracted (Grade 2)"
        )
        XCTAssertEqual(
            BrailleTableCatalog.description(ofTableID: "en-us-g1.ctb"),
            "English Braille, American Edition, uncontracted (Grade 1)"
        )
        XCTAssertEqual(BrailleTableCatalog.description(ofTableID: "en-xx.ctb"), "en-xx.ctb")
        if let table = BrailleTableCatalog.table(withID: "en_US.tbl") {
            XCTAssertEqual(BrailleTableCatalog.code(of: table)?.id, "en/ebae")
        } else {
            XCTFail("en_US.tbl is not bundled")
        }
    }

    /// A table with no grade says only how far it contracts.
    func testLabelsWithoutAGrade() {
        func table(_ contraction: Contraction) -> BrailleTable {
            BrailleTable(id: "x.ctb", displayName: "X", indexName: nil, language: "en", system: "xyz",
                         contraction: contraction, grade: nil)
        }
        XCTAssertEqual(table(.no).contractionLabel, "Uncontracted")
        XCTAssertEqual(table(.full).contractionLabel, "Contracted")
        XCTAssertEqual(table(.partial).contractionLabel, "Partly contracted")
    }

    // MARK: - Header Rules

    /// Fields are read as liblouis reads them: only before the first line
    /// that is neither blank nor a comment; "#--" lines and plain comments
    /// are not fields; a colon needs no space after it; keys are
    /// lowercased; inner white space is made one space; the first of two
    /// values wins.
    func testHeaderRules() {
        let header = """
        # liblouis: a plain comment: not a field
        #-- name: a double-dash line
        #-Display-Name:   Some   \t spaced\u{20}  name  \r
        \r
        #+grade:2
        #+LANGUAGE: en
        #+grade: 9
        #+ spaced key: no
        #+nocolon
        #+empty:
        include other.cti
        #+system: late
        """
        let fields = BrailleTableCatalog.metadata(fromHeader: header)
        XCTAssertEqual(fields["grade"], "2", "no space after the colon, and the first value wins")
        XCTAssertEqual(fields["language"], "en", "keys are lowercased")
        XCTAssertEqual(fields["display-name"], "Some spaced name", "inner white space is made one space")
        XCTAssertNil(fields["system"], "a field after the first rule line was read")
        XCTAssertNil(fields["name"], "a #-- line was read as a field")
        XCTAssertNil(fields["spaced key"])
        XCTAssertNil(fields["nocolon"])
        XCTAssertNil(fields["empty"])
        XCTAssertEqual(fields.count, 3)
        XCTAssertEqual(BrailleTableCatalog.metadata(fromHeader: ""), [:])
    }

    /// A file that cannot be read has no metadata, and only the first
    /// 65,536 bytes of a file are read.
    func testMetadataOfAFile() throws {
        let folder = try makeSandboxDirectory("BrailleMetadataFile")
        XCTAssertEqual(BrailleTableCatalog.metadata(ofTableAt: folder.appendingPathComponent("missing.ctb")), [:])

        // A field after more than 65,536 bytes of comment is out of reach.
        let filler = String(repeating: "# filler\n", count: 8_000)
        let file = folder.appendingPathComponent("long.ctb")
        try ("#+language:en\n" + filler + "#+system:late\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(BrailleTableCatalog.metadata(ofTableAt: file), ["language": "en"])
    }

    // MARK: - Which Files Are Offered

    /// Writes a table file called `name` into `folder` with these header
    /// fields (`key: value`, written as "#+key:value"), then a rule line.
    private func writeTable(_ name: String, fields: [String], in folder: URL) throws {
        let header = fields.map { "#+\($0)" }.joined(separator: "\n")
        try (header + "\ninclude something.cti\n").write(
            to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8
        )
    }

    /// The fields of a table that is offered, for a test to change one of.
    private func offeredFields(replacing key: String? = nil, with value: String? = nil) -> [String] {
        var fields = [
            "type:literary", "display-name:Fine braille", "language:en",
            "system:fine", "contraction:full", "grade:2",
        ]
        if let key {
            fields.removeAll { $0.hasPrefix(key + ":") }
            if let value { fields.append("\(key):\(value)") }
        }
        return fields
    }

    /// A forward-only table, a non-literary one, one with no display name,
    /// and one with an unknown contraction are left out, as are included
    /// files and a stray file; a table that reads both ways, with the
    /// direction said or not, is offered.
    func testOnlyUsableTablesAreOffered() throws {
        let folder = try makeSandboxDirectory("BrailleOffered")
        try writeTable("a-forward.ctb", fields: offeredFields() + ["direction:forward"], in: folder)
        try writeTable("b-backward.ctb", fields: offeredFields() + ["direction:backward"], in: folder)
        try writeTable("c-math.ctb", fields: offeredFields(replacing: "type", with: "math"), in: folder)
        try writeTable("d-nameless.ctb", fields: offeredFields(replacing: "display-name", with: nil), in: folder)
        try writeTable("e-odd.ctb", fields: offeredFields(replacing: "contraction", with: "sometimes"), in: folder)
        try writeTable("f-no-language.ctb", fields: offeredFields(replacing: "language", with: nil), in: folder)
        try writeTable("g-no-system.ctb", fields: offeredFields(replacing: "system", with: nil), in: folder)
        try "just words\n".write(to: folder.appendingPathComponent("stray.txt"), atomically: true, encoding: .utf8)
        try "include nothing\n".write(to: folder.appendingPathComponent("chars.uti"), atomically: true, encoding: .utf8)
        try writeTable("h-both.ctb", fields: offeredFields() + ["direction:both"], in: folder)
        try writeTable("i-silent.ctb", fields: offeredFields(), in: folder)
        // A folder is never a table, even one named like one.
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("j-folder.ctb"), withIntermediateDirectories: false
        )

        XCTAssertEqual(BrailleTableCatalog.tables(in: folder).map(\.id), ["h-both.ctb", "i-silent.ctb"])
        XCTAssertEqual(BrailleTableCatalog.tables(in: folder.appendingPathComponent("nowhere")), [])
    }

    /// A partly contracted table is offered, labelled so, and sorted
    /// between the uncontracted and contracted ones of its code, whatever
    /// the file names; tables of other languages sort by language first.
    func testPartlyContractedTablesSortBetween() throws {
        let folder = try makeSandboxDirectory("BrailleSorted")
        func fields(_ contraction: String, language: String = "en") -> [String] {
            offeredFields(replacing: "contraction", with: contraction)
                .filter { !$0.hasPrefix("language:") } + ["language:\(language)", "grade:1"]
        }
        try writeTable("a-full.ctb", fields: fields("full"), in: folder)
        try writeTable("b-partial.ctb", fields: fields("partial"), in: folder)
        try writeTable("c-none.ctb", fields: fields("no"), in: folder)
        try writeTable("0-german.ctb", fields: fields("no", language: "de"), in: folder)

        let tables = BrailleTableCatalog.tables(in: folder)
        XCTAssertEqual(tables.map(\.id), ["0-german.ctb", "c-none.ctb", "b-partial.ctb", "a-full.ctb"])
        XCTAssertEqual(tables.first { $0.id == "b-partial.ctb" }?.contractionLabel, "Partly contracted")
    }

    /// A table of a system no code is written for makes a code named from
    /// its display name, without the words about contraction.
    func testAnUnknownSystemIsNamedFromItsFirstTable() throws {
        let folder = try makeSandboxDirectory("BrailleKlingon")
        let klingon = offeredFields(replacing: "display-name", with: "Klingon partially contracted braille")
            .filter { !$0.hasPrefix("system:") && !$0.hasPrefix("contraction:") }
        try writeTable("k.ctb", fields: klingon + ["system:xyz", "contraction:partial"], in: folder)

        let codes = BrailleTableCatalog.codes(of: BrailleTableCatalog.tables(in: folder))
        XCTAssertEqual(codes.map(\.name), ["Klingon braille"])
        XCTAssertEqual(codes.map(\.id), ["en/xyz"])

        // The other phrases, and a name that has none, are handled too.
        func name(_ displayName: String) -> String? {
            let table = BrailleTable(id: "t.ctb", displayName: displayName, indexName: nil, language: "en",
                                     system: "abc", contraction: .no, grade: nil)
            return BrailleTableCatalog.codes(of: [table]).first?.name
        }
        XCTAssertEqual(name("french uncontracted braille"), "French braille")
        XCTAssertEqual(name("Dutch contracted braille"), "Dutch braille")
        XCTAssertEqual(name("Welsh braille"), "Welsh braille")
    }

    // MARK: - The Setting

    /// The setting reads as the default until a bundled table is stored,
    /// and a stored name no table has reads as the default.
    func testTheSettingReadsABundledTableElseTheDefault() throws {
        let defaults = try isolatedDefaults()
        XCTAssertEqual(BraillePreferences.table.key, "brailleTable")
        XCTAssertEqual(BraillePreferences.table.read(from: defaults), "en-ueb-g2.ctb")

        BraillePreferences.table.write("en-us-g1.ctb", to: defaults)
        XCTAssertEqual(defaults.string(forKey: "brailleTable"), "en-us-g1.ctb")
        XCTAssertEqual(BraillePreferences.table.read(from: defaults), "en-us-g1.ctb")

        defaults.set("nonsense.ctb", forKey: "brailleTable")
        XCTAssertEqual(BraillePreferences.table.read(from: defaults), "en-ueb-g2.ctb")
        defaults.set(42, forKey: "brailleTable")
        XCTAssertEqual(BraillePreferences.table.read(from: defaults), "en-ueb-g2.ctb")
    }

    /// A test chooses an import's table without writing the real store.
    func testAnImportTableCanBeBoundByATest() {
        BraillePreferences.$tableForImports.withValue("en-us-g1.ctb") {
            XCTAssertEqual(BraillePreferences.importTable(), "en-us-g1.ctb")
        }
        XCTAssertNil(BraillePreferences.tableForImports)
    }

    /// The table chosen in settings is saved to the store and to
    /// config.json and announced; a name no bundled table has changes
    /// nothing; an edit of config.json reaches the setting, and an edit
    /// naming no table leaves it.
    func testTheTableFollowsSettingsAndConfigJSON() throws {
        let defaults = try isolatedDefaults()
        let url = try makeConfigFileURL()
        let service = ConfigService(fileURL: url)
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: defaults,
            configService: service
        )
        var announced = 0
        let subscription = settings.objectWillChange.sink { announced += 1 }
        defer { subscription.cancel() }

        XCTAssertEqual(settings.brailleTable, "en-ueb-g2.ctb")
        settings.brailleTable = "en-us-g1.ctb"
        service.flushScheduledSave()

        XCTAssertEqual(settings.brailleTable, "en-us-g1.ctb")
        XCTAssertGreaterThan(announced, 0, "choosing a table announced nothing")
        XCTAssertEqual(defaults.string(forKey: "brailleTable"), "en-us-g1.ctb")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(saved?["brailleTable"] as? String, "en-us-g1.ctb")

        var before = announced
        settings.brailleTable = "nonsense.ctb"
        XCTAssertEqual(settings.brailleTable, "en-us-g1.ctb", "a name no table has was taken")
        settings.brailleTable = "en-us-g1.ctb"
        XCTAssertEqual(announced, before, "choosing the current table announced a change")

        var edit = service.config
        edit.brailleTable = "en_US.tbl"
        settings.applyConfigChanges(edit)
        XCTAssertEqual(settings.brailleTable, "en_US.tbl")
        XCTAssertGreaterThan(announced, before, "the edit of config.json announced nothing")

        before = announced
        edit.brailleTable = "nonsense.ctb"
        settings.applyConfigChanges(edit)
        XCTAssertEqual(settings.brailleTable, "en_US.tbl", "an unknown name in config.json was taken")
        edit.brailleTable = ""
        settings.applyConfigChanges(edit)
        XCTAssertEqual(settings.brailleTable, "en_US.tbl", "an empty name in config.json was taken")
    }
}
