import XCTest
@testable import TextMouth

/// This Mac's VoiceOver braille tables as the catalog's second source
/// (October 20, 2026): their stored values, the metadata rules both sources
/// share, the bundled tables' twins, the listings thinned when they would
/// say the same words, the codes, the regions shown only when needed, the
/// language list, and the words Book Info says.
///
/// The catalog's logic is tested on folders of small metadata-only files
/// made in each test's sandbox. The tests of the Mac's own tables read its
/// real folder and skip, saying why, on a Mac that has none. Nothing here
/// touches the real preferences store or plays sound.
final class MacBrailleTableCatalogTests: XCTestCase {

    // MARK: - Fixtures

    /// Writes a table file called `name` into `folder` with these header
    /// fields (`key: value`, written as "#+key:value"), then a rule line.
    private func writeTable(_ name: String, _ fields: [String], in folder: URL) throws {
        let header = fields.map { "#+\($0)" }.joined(separator: "\n")
        try (header + "\ninclude something.cti\n").write(
            to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8
        )
    }

    /// A table for the code and language tests: of `language`, named
    /// `displayName`, with `contraction`, from `source`.
    private func table(
        _ fileName: String,
        _ displayName: String,
        language: String = "de",
        contraction: Contraction = .no,
        grade: String? = nil,
        region: String? = nil,
        system: String = "",
        indexName: String? = nil,
        source: BrailleTableSource = .mac
    ) -> BrailleTable {
        BrailleTable(
            id: source.storedValue(ofFile: fileName), displayName: displayName, indexName: indexName,
            language: language, system: system, contraction: contraction, grade: grade, region: region
        )
    }

    /// Skips the test, saying why, when this Mac has no VoiceOver tables
    /// folder (an older macOS, or one where Apple moved it).
    private func requireThisMacsTables() throws -> BrailleTableCatalog.MacTables {
        guard let mac = BrailleTableCatalog.mac else {
            throw XCTSkip("This Mac has no VoiceOver braille tables at \(BrailleTableCatalog.macTablesFolder.path)")
        }
        return mac
    }

    // MARK: - Stored Values

    /// A bundled table is stored by its bare file name and a Mac table with
    /// "mac:" before it; the prefix is read back, and only a bare file name
    /// after it makes a Mac value.
    func testStoredValuesNameTheirSource() {
        XCTAssertEqual(BrailleTableSource.macPrefix, "mac:")
        XCTAssertEqual(BrailleTableSource.bundled.storedValue(ofFile: "en-ueb-g2.ctb"), "en-ueb-g2.ctb")
        XCTAssertEqual(BrailleTableSource.mac.storedValue(ofFile: "fr-bfu-g2.ctb"), "mac:fr-bfu-g2.ctb")
        XCTAssertTrue(BrailleTableSource.parse("en-ueb-g2.ctb") == (.bundled, "en-ueb-g2.ctb"))
        XCTAssertTrue(BrailleTableSource.parse("mac:fr-bfu-g2.ctb") == (.mac, "fr-bfu-g2.ctb"))
        // The prefix is matched exactly: another case is a bundled name.
        XCTAssertTrue(BrailleTableSource.parse("MAC:fr.ctb") == (.bundled, "MAC:fr.ctb"))

        let table = table("fr-bfu-g2.ctb", "French contracted braille")
        XCTAssertEqual(table.id, "mac:fr-bfu-g2.ctb")
        XCTAssertEqual(table.source, .mac)
        XCTAssertEqual(table.fileName, "fr-bfu-g2.ctb")

        for value in ["mac:fr-bfu-g2.ctb", "mac:es.tbl"] {
            XCTAssertTrue(BrailleTableSource.isMacValue(value), value)
        }
        for value in ["en-ueb-g2.ctb", "mac:", "mac:.hidden.ctb", "mac:../x.ctb", "mac:a/b.ctb", "mac:a,b.ctb", "MAC:x.ctb", ""] {
            XCTAssertFalse(BrailleTableSource.isMacValue(value), value)
        }
    }

    /// The setting keeps a Mac value, even one this Mac has not got, so an
    /// import refuses it by name; a malformed Mac value reads as the default.
    func testTheSettingKeepsAMacValue() throws {
        let defaults = try isolatedDefaults()
        defaults.set("mac:no-such-table-on-any-mac.ctb", forKey: "brailleTable")
        XCTAssertEqual(BraillePreferences.table.read(from: defaults), "mac:no-such-table-on-any-mac.ctb")
        defaults.set("mac:../escape.ctb", forKey: "brailleTable")
        XCTAssertEqual(BraillePreferences.table.read(from: defaults), "en-ueb-g2.ctb")
        defaults.set("mac:", forKey: "brailleTable")
        XCTAssertEqual(BraillePreferences.table.read(from: defaults), "en-ueb-g2.ctb")
    }

    // MARK: - Which Files Are Offered

    /// Both sources share one set of rules: a literary table of six dots or
    /// none is offered; an eight-dot table, a computer one, and an included
    /// file are not; a table with no system is offered with an empty one;
    /// liblouis's older `locale` gives a language and its region; and the
    /// Mac's tables carry its prefix.
    func testTheMetadataRules() throws {
        let folder = try makeSandboxDirectory("MacBrailleRules")
        let base = ["type:literary", "contraction:no", "grade:1"]
        try writeTable("six.utb", base + ["display-name:Six braille", "language:fr", "dots:6"], in: folder)
        try writeTable("none.ctb", base + ["display-name:No dots braille", "language:fr", "system:bfu"], in: folder)
        try writeTable("eight.utb", base + ["display-name:Eight braille", "language:fr", "dots:8"], in: folder)
        try writeTable("comp.utb", ["type:computer", "contraction:no", "display-name:Computer braille", "language:fr", "dots:6"], in: folder)
        try writeTable("spanish.tbl", base + ["display-name:Spanish uncontracted braille", "locale:es"], in: folder)
        try writeTable("swiss.tbl", base + ["display-name:Swiss braille", "locale:de-CH"], in: folder)
        try writeTable("latin.utb", base + ["display-name:Latin braille", "language:akk-Latn"], in: folder)
        try writeTable("starred.utb", base + ["display-name:Starred braille", "language:he", "region:*-IL"], in: folder)
        try "include nothing\n".write(to: folder.appendingPathComponent("chars.uti"), atomically: true, encoding: .utf8)

        let tables = BrailleTableCatalog.tables(in: folder, source: .mac)
        XCTAssertEqual(
            Set(tables.map(\.id)),
            ["mac:six.utb", "mac:none.ctb", "mac:spanish.tbl", "mac:swiss.tbl", "mac:latin.utb", "mac:starred.utb"]
        )
        func found(_ id: String) throws -> BrailleTable { try XCTUnwrap(tables.first { $0.id == id }, id) }
        XCTAssertEqual(try found("mac:six.utb").system, "")
        XCTAssertEqual(try found("mac:none.ctb").system, "bfu")
        XCTAssertEqual(try found("mac:spanish.tbl").language, "es")
        XCTAssertNil(try found("mac:spanish.tbl").region, "a locale that is only a language names no region")
        XCTAssertEqual(try found("mac:swiss.tbl").language, "de")
        XCTAssertEqual(try found("mac:swiss.tbl").region, "de-CH")
        XCTAssertEqual(try found("mac:latin.utb").language, "akk")
        XCTAssertEqual(try found("mac:latin.utb").region, "akk-Latn", "liblouis's default region is the language tag")
        XCTAssertNil(try found("mac:starred.utb").region, "a region pattern names no one region")

        // The same folder read as bundled gives bare stored values.
        XCTAssertTrue(BrailleTableCatalog.tables(in: folder).allSatisfy { $0.source == .bundled })
    }

    /// A folder with its property list gives its tables and its liblouis
    /// version; no property list gives no version; no folder gives nothing,
    /// with no error.
    func testAMacFolderAndItsVersion() throws {
        let root = try makeSandboxDirectory("MacBrailleFolder")
        let folder = root.appendingPathComponent("tables", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeTable("fr.ctb", ["type:literary", "contraction:full", "display-name:French contracted braille", "language:fr"], in: folder)
        let plist = root.appendingPathComponent("Tables.plist")
        try PropertyListSerialization.data(fromPropertyList: ["OpenSourceVersion": "3.34.0"], format: .xml, options: 0)
            .write(to: plist)

        let found = try XCTUnwrap(BrailleTableCatalog.macTables(in: folder, propertyList: plist))
        XCTAssertEqual(found.tables.map(\.id), ["mac:fr.ctb"])
        XCTAssertEqual(found.liblouisVersion, "3.34.0")
        XCTAssertNil(BrailleTableCatalog.macTables(in: folder, propertyList: root.appendingPathComponent("none.plist"))?.liblouisVersion)
        XCTAssertNil(BrailleTableCatalog.macTables(in: root.appendingPathComponent("missing"), propertyList: plist))
        // A file where the folder should be is no folder.
        XCTAssertNil(BrailleTableCatalog.macTables(in: plist, propertyList: plist))
    }

    // MARK: - Twins and Listings

    /// Where the Mac has a bundled table's file, the bundled one wins and the
    /// Mac's is left out; the Mac's other tables follow the bundled ones.
    func testABundledTableWinsOverItsMacTwin() {
        let bundled = [table("en-ueb-g2.ctb", "Unified English contracted braille", language: "en", contraction: .full,
                             system: "ueb", source: .bundled)]
        let mac = [
            table("en-ueb-g2.ctb", "Unified English contracted braille", language: "en", contraction: .full, system: "ueb"),
            table("fr-bfu-g2.ctb", "French contracted braille", language: "fr", contraction: .full),
        ]
        XCTAssertEqual(BrailleTableCatalog.merged(bundled: bundled, mac: mac).map(\.id), ["en-ueb-g2.ctb", "mac:fr-bfu-g2.ctb"])
    }

    /// Tables of one language that share a code name make one code, whatever
    /// their systems; a code's tables are in contraction order; of two that
    /// would be listed with the same words, the bundled one, else the first
    /// by file name, is kept.
    func testCodesShareANameAndThinListingsWithTheSameWords() {
        let tables = [
            table("no.tbl", "Norwegian grade 3 contracted braille", language: "no", contraction: .full, grade: "3"),
            table("no-no-g3.ctb", "Norwegian grade 3 contracted braille", language: "no", contraction: .full, grade: "3"),
            table("ga.tbl", "Irish contracted braille", language: "ga", contraction: .full, grade: "2"),
            table("ga-g2.ctb", "Irish contracted braille", language: "ga", contraction: .full, grade: "2", system: "INBAF"),
            table("de-g1-detailed.ctb", "German partially contracted braille with indication of capitals", contraction: .partial),
            table("de-g0-detailed.utb", "German uncontracted braille with indication of capitals", grade: "0"),
            // A bundled table and a Mac one with the same words: the bundled
            // one is kept, though the Mac's file name sorts first.
            table("a-twin.ctb", "Unified English contracted braille", language: "en", contraction: .full, grade: "2",
                  system: "ueb"),
            table("z-own.ctb", "Unified English contracted braille", language: "en", contraction: .full, grade: "2",
                  system: "ueb", source: .bundled),
        ]
        let codes = BrailleTableCatalog.codes(of: tables)
        XCTAssertEqual(codes.map(\.id), [
            "no/Norwegian grade 3 braille", "ga/Irish braille",
            "de/German braille with indication of capitals", "en/Unified English Braille",
        ])
        XCTAssertEqual(codes.map { $0.tables.map(\.id) }, [
            ["mac:no-no-g3.ctb"], ["mac:ga-g2.ctb"],
            ["mac:de-g0-detailed.utb", "mac:de-g1-detailed.ctb"], ["z-own.ctb"],
        ])
        XCTAssertEqual(codes[2].tables.map(\.contractionLabel), ["Uncontracted (Grade 0)", "Partly contracted"])
        XCTAssertEqual(codes.map(\.name).last, "Unified English Braille")
    }

    /// One system holding two standards makes two codes, each told apart by
    /// its name, as the Mac's Danish 1993 and 2022 tables are.
    func testTwoStandardsOfOneSystemAreTwoCodes() {
        let tables = [
            table("da-dk-g16.ctb", "Danish 6-dot uncontracted braille (2022 standard)", language: "da", grade: "1", system: "ddp"),
            table("da-dk-g26.ctb", "Danish 6-dot contracted braille (2022 standard)", language: "da", contraction: .full,
                  grade: "2", system: "ddp"),
            table("da-dk-g16_1993.ctb", "Danish 6-dot uncontracted braille (1993 standard)", language: "da", grade: "1",
                  system: "ddp"),
        ]
        let codes = BrailleTableCatalog.codes(of: tables)
        XCTAssertEqual(codes.map(\.name), ["Danish 6-dot braille (2022 standard)", "Danish 6-dot braille (1993 standard)"])
        XCTAssertEqual(codes.map { $0.tables.count }, [2, 1])
    }

    // MARK: - Regions

    /// A region is shown only when needed to tell two tables apart: German
    /// tables of Germany and Switzerland with the same words are listed under
    /// "German" and "German (Switzerland)", while Swahili tables that all
    /// name Kenya are listed under Swahili alone.
    func testARegionIsShownOnlyWhenNeeded() {
        let tables = [
            table("de-g2.ctb", "German contracted braille", contraction: .full),
            table("de-ch-g2.ctb", "German contracted braille", contraction: .full, region: "de-CH"),
            table("de-ch-g0.ctb", "German basic braille", region: "de-CH"),
            table("sw-ke-g1.utb", "Swahili uncontracted braille", language: "sw", region: "sw-KE"),
            table("sw-ke-g2.ctb", "Swahili grade 2 contracted braille", language: "sw", contraction: .full, region: "sw-KE"),
        ]
        XCTAssertEqual(BrailleTableCatalog.languagesNeedingRegions(in: tables), ["de"])
        let languages = BrailleTableCatalog.languages(of: BrailleTableCatalog.codes(of: tables))
        let names = Dictionary(uniqueKeysWithValues: languages.map { ($0.id, $0.name) })
        XCTAssertEqual(names["de"], Locale.current.localizedString(forIdentifier: "de"))
        XCTAssertEqual(names["de-CH"], Locale.current.localizedString(forIdentifier: "de-CH"))
        XCTAssertEqual(names["sw"], Locale.current.localizedString(forIdentifier: "sw"))
        XCTAssertNil(names["sw-KE"])
        // Each Swiss table is listed under the Swiss entry.
        XCTAssertEqual(languages.first { $0.id == "de-CH" }?.codes.flatMap(\.tables).map(\.id), ["mac:de-ch-g2.ctb", "mac:de-ch-g0.ctb"])
    }

    // MARK: - Languages

    /// English comes first, then the other languages in the alphabetical
    /// order of their names in the user's own language; each keeps its
    /// codes in order.
    func testEnglishFirstThenAlphabetical() {
        let tables = [
            table("sv.ctb", "Swedish contracted braille", language: "sv", contraction: .full),
            table("en-ueb-g2.ctb", "Unified English contracted braille", language: "en", contraction: .full, system: "ueb",
                  source: .bundled),
            table("de.ctb", "German contracted braille", contraction: .full),
            table("en_GB.tbl", "English contracted braille as used in the U.K.", language: "en", contraction: .full),
            table("af.ctb", "Afrikaans contracted braille", language: "af", contraction: .full),
        ]
        let languages = BrailleTableCatalog.languages(of: BrailleTableCatalog.codes(of: tables))
        XCTAssertEqual(languages.first?.id, "en")
        XCTAssertEqual(languages.first?.codes.map(\.name), ["Unified English Braille", "English braille as used in the U.K."])
        let others = languages.dropFirst().map(\.name)
        XCTAssertEqual(others, others.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertEqual(Set(languages.dropFirst().map(\.id)), ["af", "de", "sv"])
    }

    /// A language the system names is named so; one it cannot name, as
    /// Classical Hebrew, is named by its tables' index name, else by its code.
    func testLanguageNames() {
        XCTAssertEqual(BrailleTableCatalog.languageName("fr"), Locale.current.localizedString(forIdentifier: "fr"))
        XCTAssertEqual(BrailleTableCatalog.languageName("de-CH"), Locale.current.localizedString(forIdentifier: "de-CH"))
        // "hbo" has no name in the system's own data; its index name begins
        // with the language.
        let hebrew = table("hbo.utb", "Classical Hebrew braille", language: "hbo", contraction: .partial,
                           indexName: "Hebrew, classical, IHBC")
        let languages = BrailleTableCatalog.languages(of: BrailleTableCatalog.codes(of: [hebrew]))
        let expected = Locale.current.localizedString(forIdentifier: "hbo") ?? "Hebrew"
        XCTAssertEqual(languages.map(\.name), [expected])
        XCTAssertEqual(BrailleTableCatalog.languageName("zz-not-a-language"), "zz-not-a-language")
        XCTAssertEqual(BrailleTableCatalog.languageName("zz", indexName: " , "), "zz")
    }

    // MARK: - Words

    /// Book Info and Speak Info say a Mac table's code, its contraction, and
    /// its language; a bundled table's words are as before.
    func testTheWordsOfATable() {
        let french = table("fr-bfu-g2.ctb", "French contracted braille", language: "fr", contraction: .full, grade: "2",
                           system: "bfu")
        XCTAssertEqual(
            BrailleTableCatalog.description(of: french, language: "French"),
            "French braille, contracted (Grade 2), in French"
        )
        let partial = table("de-g1-detailed.ctb", "German partially contracted braille with indication of capitals",
                            contraction: .partial)
        XCTAssertEqual(
            BrailleTableCatalog.description(of: partial, language: "German"),
            "German braille with indication of capitals, partly contracted, in German"
        )
        XCTAssertEqual(
            BrailleTableCatalog.description(ofTableID: "en-ueb-g2.ctb"),
            "Unified English Braille, contracted (Grade 2)"
        )
        // A Mac table no Mac has is named by its stored value.
        XCTAssertEqual(BrailleTableCatalog.description(ofTableID: "mac:no-such-table.ctb"), "mac:no-such-table.ctb")
    }

    // MARK: - This Mac's Own Tables

    /// The real folder: its version is recorded; French contracted, a German
    /// table, and Spanish are offered with their prefix; no Mac table has a
    /// bundled table's file name; every Mac table offered is literary and of
    /// six dots or none; and the language list begins with English.
    func testThisMacOffersItsTables() throws {
        let mac = try requireThisMacsTables()
        XCTAssertFalse(mac.liblouisVersion?.isEmpty ?? true, "the Mac's property list names no liblouis version")

        let offered = Set(BrailleTableCatalog.offeredTables.map(\.id))
        for id in ["mac:fr-bfu-g2.ctb", "mac:de-g1-detailed.ctb", "mac:es.tbl"] {
            XCTAssertTrue(offered.contains(id), "\(id) is not offered")
        }
        let bundledFiles = Set(BrailleTableCatalog.bundled.map(\.fileName))
        let macTables = BrailleTableCatalog.offeredTables.filter { $0.source == .mac }
        XCTAssertFalse(macTables.isEmpty)
        XCTAssertTrue(macTables.allSatisfy { !bundledFiles.contains($0.fileName) })
        for table in macTables {
            let fields = BrailleTableCatalog.metadata(ofTableAt: BrailleTableCatalog.macTablesFolder.appendingPathComponent(table.fileName))
            XCTAssertEqual(fields["type"]?.lowercased(), "literary", table.id)
            XCTAssertTrue(fields["dots"] == nil || fields["dots"] == "6", table.id)
        }
        // The bundled tables come first and are unchanged.
        XCTAssertEqual(Array(BrailleTableCatalog.offeredTables.prefix(4)).map(\.id), BrailleTableCatalog.bundled.map(\.id))
        let languages = BrailleTableCatalog.languages(of: BrailleTableCatalog.offeredCodes)
        XCTAssertEqual(languages.first?.id, "en")
        XCTAssertGreaterThan(languages.count, 1)

        // A Mac table is found by its stored value and named with its language.
        let french = try XCTUnwrap(BrailleTableCatalog.table(withID: "mac:fr-bfu-g2.ctb"))
        XCTAssertEqual(french.contraction, .full)
        let frenchName = try XCTUnwrap(Locale.current.localizedString(forIdentifier: "fr"))
        XCTAssertEqual(
            BrailleTableCatalog.description(ofTableID: "mac:fr-bfu-g2.ctb"),
            "French braille, contracted (Grade 2), in \(frenchName)"
        )
        // A Mac twin of a bundled table is not offered by its Mac value.
        XCTAssertNil(BrailleTableCatalog.table(withID: "mac:en-ueb-g2.ctb"))
    }
}
