import Foundation
import XCTest
@testable import TextMouth

// Tests of the tables that write braille only (FR40, the user's decision of November 24, 2026): liblouis marks some tables
// `direction: forward`, which write braille from print and cannot read a braille file back. Exporting braille offers them on
// both platforms, and reading a braille file never does; the Mac judges VoiceOver's older tables by the newer release's marks;
// a book or a setting that already names one keeps working.
//
// Shared with the iPhone's unit bundle (project.yml); the Mac's own parts are under `#if os(macOS)`.

final class BrailleTablePrintOnlyTests: XCTestCase {
    // MARK: - Fixtures

    /// The header of a literary table in `language`, optionally marked `direction`.
    private func header(language: String, name: String, direction: String? = nil, locale: Bool = false) -> String {
        "#+type:literary\n#+\(locale ? "locale" : "language"):\(language)\n#-display-name: \(name)\n"
            + (direction.map { "#+direction:\($0)\n" } ?? "")
    }

    /// A small pack with a table of each direction, a wrapper of the print-only one that also includes a plain file, and the
    /// release's directions in its index.
    private func directionsPack() throws -> BrailleTablePack {
        var bytes = BrailleTablePackBytes(
            groups: [["two.ctb", "print.ctb"], ["wrapper.tbl", "common.cti"]],
            files: [
                "two.ctb": header(language: "fr", name: "French braille") + "letter a 1\n",
                "print.ctb": header(language: "de", name: "German braille", direction: "forward") + "letter a 1\n",
                "wrapper.tbl": header(language: "de", name: "German wrapper") + "include print.ctb\ninclude common.cti\n",
                "common.cti": "letter b 12\n",
            ]
        )
        bytes.damageIndex = { $0["f"] = ["print.ctb"] }
        return try BrailleTablePack(data: bytes.data())
    }

    /// Makes a folder of table files (a made-up VoiceOver folder) from `files`.
    private func folder(of files: [String: String]) throws -> URL {
        let folder = try makeSandboxDirectory("PrintOnlyFolder")
        for (name, text) in files { try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return folder
    }

    // MARK: - A pack

    /// A pack's tables of every direction are known, a wrapper that includes a print-only table of its language writes braille
    /// only too, and the tables for reading are those that read braille back.
    func testAPackKnowsEveryTableAndReadingTakesTheTwoWayOnes() throws {
        let pack = try directionsPack()
        XCTAssertEqual(pack.releaseDirections.printOnly, ["print.ctb"])
        let all = BrailleTableCatalog.allTables(in: pack)
        XCTAssertEqual(all.map(\.id).sorted(), ["print.ctb", "two.ctb", "wrapper.tbl"])
        XCTAssertEqual(all.filter(\.isPrintOnly).map(\.id).sorted(), ["print.ctb", "wrapper.tbl"])
        XCTAssertEqual(BrailleTableCatalog.tables(in: pack).map(\.id), ["two.ctb"])
    }

    /// A pack's index may name no directions (an older one): the tables are then judged by their own headers.
    func testAPackWithNoDirectionsJudgesByHeaders() throws {
        var bytes = BrailleTablePackBytes.sample()
        bytes.files["other.ctb"] = header(language: "yy", name: "Other braille", direction: "forward")
        let pack = try BrailleTablePack(data: bytes.data())
        XCTAssertTrue(pack.releaseDirections.printOnly.isEmpty)
        XCTAssertEqual(BrailleTableCatalog.allTables(in: pack).first { $0.id == "other.ctb" }?.isPrintOnly, true)
        XCTAssertFalse(BrailleTableCatalog.tables(in: pack).contains { $0.id == "other.ctb" })
    }

    /// A direction that is neither `both` nor `forward` is no table TextMouth offers, for reading or for export.
    func testAnotherDirectionIsNeverOffered() throws {
        var bytes = BrailleTablePackBytes.sample()
        bytes.files["other.ctb"] = header(language: "yy", name: "Other braille", direction: "backward")
        let pack = try BrailleTablePack(data: bytes.data())
        XCTAssertFalse(BrailleTableCatalog.allTables(in: pack).contains { $0.id == "other.ctb" })
    }

    /// The codes of tables of both directions list a two-way table before a print-only one of the same words, so reading's
    /// tables are never displaced from export's list.
    func testATwoWayTableIsNotDisplacedByAPrintOnlyTableOfTheSameWords() {
        func table(_ id: String, printOnly: Bool) -> BrailleTable {
            BrailleTable(
                id: id, displayName: "Plain braille", indexName: nil, language: "xx", system: "", contraction: .no, grade: "1",
                isPrintOnly: printOnly
            )
        }
        // The print-only table sorts first by name, and has the same words.
        let codes = BrailleTableCatalog.codes(of: [table("a-print.ctb", printOnly: true), table("b-two.ctb", printOnly: false)])
        XCTAssertEqual(codes.flatMap(\.tables).map(\.id), ["b-two.ctb"])
    }

    // MARK: - This Mac's tables, judged by the newer release

    #if os(macOS)
    /// VoiceOver's older tables are judged as the newer release judges the file names it has: macOS's `zh_CHN.tbl`, `cs.tbl`,
    /// `lv.tbl`, and `sl.tbl` lack the `direction: forward` the release gives them; a wrapper that includes a print-only table of
    /// its language, `zh_TW.tbl` (macOS's own `zh-tw.ctb` says forward), writes braille only too; `zh_HK.tbl`, whose table
    /// carries no mark in either, reads. A table is print-only when either source marks it so: `changed.ctb`, which the
    /// release marks and VoiceOver's copy does not, and `marked.ctb`, which VoiceOver's copy marks and the release calls
    /// two-way. When VoiceOver's liblouis is newer than the app's, its own headers decide: the release is not used, so
    /// `changed.ctb` reads and `marked.ctb` stays print-only.
    func testTheMacJudgesVoiceOversTablesByTheNewerRelease() throws {
        let files = [
            "cs.tbl": header(language: "cs", name: "Czech"), "cs-g1.ctb": "letter a 1\n",
            "lv.tbl": header(language: "lv", name: "Latvian"), "sl.tbl": header(language: "sl", name: "Slovenian"),
            "zh_CHN.tbl": header(language: "cmn-CN", name: "Chinese mainland", locale: true) + "include zh-chn.ctb\n",
            "zh_TW.tbl": header(language: "cmn-TW", name: "Taiwanese", locale: true) + "include zh-tw.ctb\ninclude braille-patterns.cti\n",
            "zh-tw.ctb": header(language: "cmn", name: "Taiwanese bopomofo", direction: "forward") + "letter a 1\n",
            "zh_HK.tbl": header(language: "yue-HK", name: "Cantonese", locale: true) + "include zh-hk.ctb\ninclude braille-patterns.cti\n",
            "zh-hk.ctb": header(language: "yue", name: "Cantonese braille") + "letter a 1\n",
            "braille-patterns.cti": "letter b 12\n",
            "changed.ctb": header(language: "xx", name: "Changed") + "letter a 1\n",
            "marked.ctb": header(language: "xx", name: "Marked", direction: "forward") + "letter a 1\n",
            "backwards.ctb": header(language: "xx", name: "Backwards", direction: "backward") + "letter a 1\n",
        ]
        let release = BrailleTablePack.ReleaseDirections(
            printOnly: ["cs.tbl", "lv.tbl", "sl.tbl", "zh_CHN.tbl", "changed.ctb"]
        )
        let tables = try folder(of: files)
        // The property lists are written in a folder of their own, made for this test, never beside it.
        let lists = try makeSandboxDirectory("PrintOnlyPropertyLists")
        /// The Mac's tables judged with a property list that names `version` (none: no property list).
        func judged(version: String?) throws -> BrailleTableCatalog.MacTables {
            var list = URL(fileURLWithPath: "/nonexistent/none.plist")
            if let version {
                list = lists.appendingPathComponent("tables-\(version).plist")
                try PropertyListSerialization.data(fromPropertyList: ["OpenSourceVersion": version], format: .xml, options: 0).write(to: list)
            }
            return try XCTUnwrap(BrailleTableCatalog.macTables(in: tables, propertyList: list, release: release))
        }
        // VoiceOver's liblouis is older than the app's, or unknown: the release's marks are added to the files' own.
        // A version that is no number ("unknown", "v3.34.0") is unknown, not newer: the release applies.
        for version in [nil, "3.34.0", "3.39.0", "unknown", "v3.34.0", "v9.0.0"] {
            let mac = try judged(version: version)
            let writesOnly = Set(mac.printOnly.map(\.id))
            XCTAssertEqual(writesOnly, [
                "mac:cs.tbl", "mac:lv.tbl", "mac:sl.tbl", "mac:zh_CHN.tbl", "mac:zh_TW.tbl", "mac:zh-tw.ctb", "mac:changed.ctb",
                "mac:marked.ctb",
            ], "VoiceOver \(version ?? "unknown")")
            let reading = Set(mac.tables.map(\.id))
            XCTAssertTrue(reading.isDisjoint(with: writesOnly))
            XCTAssertTrue(reading.isSuperset(of: ["mac:zh_HK.tbl", "mac:zh-hk.ctb"]), "\(reading)")
            XCTAssertFalse(reading.contains("mac:backwards.ctb"))
            XCTAssertFalse(writesOnly.contains("mac:backwards.ctb"))
        }
        // VoiceOver's liblouis is newer: its own headers decide, and the release's marks are not used.
        let newer = try judged(version: "3.40.0")
        XCTAssertEqual(Set(newer.printOnly.map(\.id)), ["mac:zh_TW.tbl", "mac:zh-tw.ctb", "mac:marked.ctb"])
        XCTAssertTrue(
            Set(newer.tables.map(\.id)).isSuperset(of: ["mac:changed.ctb", "mac:cs.tbl", "mac:lv.tbl", "mac:sl.tbl", "mac:zh_CHN.tbl"])
        )
        XCTAssertNil(BrailleTableCatalog.releaseDirections(judgingMacVersion: "3.40.0", of: release))
        for unknown in ["unknown", "v3.34.0", "v9.0.0", "", "\u{0663}.1"] {
            XCTAssertEqual(BrailleTableCatalog.releaseDirections(judgingMacVersion: unknown, of: release), release, unknown)
        }
        XCTAssertEqual(BrailleTableCatalog.releaseDirections(judgingMacVersion: "3.34.0", of: release), release)
        XCTAssertEqual(BrailleTableCatalog.releaseDirections(judgingMacVersion: nil, of: release), release)
    }

    /// VoiceOver's own folder, judged by the app's own release: the tables macOS's older copies leave unmarked are print-only,
    /// offered for export and never for reading, and the Mac's pack carries none of them.
    func testVoiceOversWrappersAreExportOnly() throws {
        try XCTSkipIf(BrailleTableCatalog.mac == nil, "This Mac has no VoiceOver braille tables")
        // A macOS whose liblouis is newer than the app's is judged by its own headers, not by the app's release.
        try XCTSkipIf(
            BrailleTableCatalog.releaseDirections(
                judgingMacVersion: BrailleTableCatalog.mac?.liblouisVersion, of: BrailleTablePack.ReleaseDirections(printOnly: [])
            ) == nil,
            "VoiceOver's liblouis is newer than the app's"
        )
        let wrappers = ["mac:cs.tbl", "mac:lv.tbl", "mac:sl.tbl", "mac:zh_CHN.tbl", "mac:zh_TW.tbl"]
        let present = wrappers.filter { BrailleTableCatalog.table(withID: $0) != nil }
        try XCTSkipIf(present.isEmpty, "This Mac's VoiceOver tables have none of the wrappers")
        for id in present {
            XCTAssertEqual(BrailleTableCatalog.table(withID: id)?.isPrintOnly, true, id)
            XCTAssertTrue(BrailleTableCatalog.exportTables.contains { $0.id == id }, "\(id) is not offered for export")
            XCTAssertFalse(BrailleTableCatalog.offeredTables.contains { $0.id == id }, "\(id) is offered for reading")
        }
        XCTAssertTrue(BrailleTableCatalog.bundledAll.allSatisfy { !$0.isPrintOnly }, "the Mac's pack carries only English tables that read back")
    }

    /// A bare value the Mac's pack lacks, which the iPhone stores (`fr-bfu-g2.ctb`), is kept by the setting and by a shared
    /// config.json when VoiceOver's folder has the file, and turns into nothing when neither has it.
    func testASharedConfigKeepsABareValueVoiceOverHas() throws {
        let bare = "fr-bfu-g2.ctb"
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: BrailleTableCatalog.macTablesFolder.appendingPathComponent(bare).path),
            "This Mac has no VoiceOver table \(bare)"
        )
        XCTAssertEqual(BrailleTableCatalog.storableValue(bare), bare)
        XCTAssertNil(BrailleTableCatalog.storableValue("no-such-table.ctb"))
        XCTAssertNil(BrailleTableCatalog.storableValue("../fr-bfu-g2.ctb"))
        XCTAssertNil(BrailleTableCatalog.storableValue(".fr-bfu-g2.ctb"))
        func decoded(_ table: String) throws -> ConfigService.AppConfig {
            try JSONDecoder().decode(ConfigService.AppConfig.self, from: Data(#"{"brailleTable": "\#(table)"}"#.utf8))
        }
        XCTAssertEqual(try decoded(bare).brailleTable, bare, "a config.json made on an iPhone lost its braille table")
        XCTAssertEqual(try decoded("mac:\(bare)").brailleTable, "mac:\(bare)")
        // A bare name this platform lacks is kept as the file has it, for the platform that has the table; never taken.
        XCTAssertEqual(try decoded("no-such-table.ctb").brailleTable, "no-such-table.ctb")
        XCTAssertEqual(try decoded("../fr-bfu-g2.ctb").brailleTable, "")
    }

    /// A table is a table, or none, under both spellings of its value: the Mac looks a bare value the pack lacks up as it
    /// looks a `mac:` value up, among the tables listed for reading or export. `ga.tbl`, `no.tbl`, `zh_HK.tbl`,
    /// `da-dk-g26l-lit.ctb`, and the three `da-dk-*_1993.ctb` tables were a table under one spelling and none under the other.
    func testBothSpellingsOfAValueFindTheSameTableOrNone() throws {
        try XCTSkipIf(BrailleTableCatalog.mac == nil, "This Mac has no VoiceOver braille tables")
        let listed = (BrailleTableCatalog.mac?.tables ?? []) + (BrailleTableCatalog.mac?.printOnly ?? [])
        let odd = ["ga.tbl", "no.tbl", "zh_HK.tbl", "da-dk-g26l-lit.ctb", "da-dk-g16_1993.ctb", "da-dk-g26_1993.ctb", "da-dk-g26l_1993.ctb"]
        let names = Set(listed.map(\.fileName)).union(odd.filter {
            FileManager.default.fileExists(atPath: BrailleTableCatalog.macTablesFolder.appendingPathComponent($0).path)
        })
        for name in names where BrailleTableCatalog.bundledAll.allSatisfy({ $0.id != name }) {
            let bare = BrailleTableCatalog.table(withID: name)
            let prefixed = BrailleTableCatalog.table(withID: "mac:\(name)")
            XCTAssertEqual(bare == nil, prefixed == nil, "\(name) is a table under one spelling only")
            XCTAssertEqual(bare?.displayName, prefixed?.displayName, name)
            XCTAssertEqual(bare?.isPrintOnly, prefixed?.isPrintOnly, name)
        }
    }

    /// A bare value the Mac's pack lacks is judged by its one file's header, never by the whole folder: decoding config.json
    /// runs on the main thread at every launch (review R3), so a folder of about 485 files is not read for it. Only the file
    /// named is read, once; a table of either direction is kept, an include or a file that is not there is refused, and a
    /// value the pack holds, a `mac:` value, or a malformed one reads nothing.
    func testABareValueIsJudgedByItsOwnFileAlone() throws {
        let folder = try makeSandboxDirectory("StorableOneFile")
        func write(_ name: String, _ text: String) throws {
            try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("fixture-two-way.ctb", "#+type:literary\n#+display-name:Fixture two-way braille\n#+language:fr\n")
        try write("fixture-print-only.ctb", "#+type:literary\n#+display-name:Fixture print-only braille\n#+language:fr\n#+direction:forward\n")
        try write("fixture-chardefs.uti", "# Characters only: no header of a table.\ndisplay 1 123456\n")
        try write("fixture-other-a.ctb", "#+type:literary\n#+display-name:Fixture A\n#+language:de\n")
        try write("fixture-other-b.ctb", "#+type:literary\n#+display-name:Fixture B\n#+language:de\n")
        // A wrapper of a file the folder lacks never loads (as Apple's is.tbl, whose include was left out), and one of a file
        // it has does.
        try write("fixture-wrapper-lacking.tbl", "#+type:literary\n#+display-name:Fixture lacking\n#+language:is\ninclude fixture-absent.cti\n")
        try write("fixture-wrapper-whole.tbl", "#+type:literary\n#+display-name:Fixture whole\n#+language:fr\ninclude fixture-chardefs.uti\n")

        var reads: [String] = []
        func storable(_ value: String) -> String? {
            BrailleTableCatalog.storableValue(value, in: folder) { url in
                reads.append(url.lastPathComponent)
                return BrailleTableCatalog.metadata(ofTableAt: url)
            }
        }
        XCTAssertEqual(storable("fixture-two-way.ctb"), "fixture-two-way.ctb")
        XCTAssertEqual(storable("fixture-print-only.ctb"), "fixture-print-only.ctb", "a print-only table stays for export")
        XCTAssertNil(storable("fixture-chardefs.uti"))
        XCTAssertNil(storable("fixture-gone.ctb"))
        XCTAssertEqual(reads, ["fixture-two-way.ctb", "fixture-print-only.ctb", "fixture-chardefs.uti"], "more than the named files were read")
        XCTAssertNil(storable("fixture-wrapper-lacking.tbl"), "a wrapper of a file the folder lacks is kept")
        XCTAssertEqual(storable("fixture-wrapper-whole.tbl"), "fixture-wrapper-whole.tbl")
        // The wrapper that lacks a file is refused before its header is read; the whole one is read.
        XCTAssertEqual(reads.suffix(2), ["fixture-chardefs.uti", "fixture-wrapper-whole.tbl"])

        reads = []
        for value in ["en-ueb-g2.ctb", "mac:fixture-two-way.ctb", "../fixture-two-way.ctb", ".fixture.ctb", "", "a,b.ctb"] {
            _ = storable(value)
        }
        XCTAssertEqual(reads, [], "a value that needs no file read one")
    }
    #endif

    // MARK: - The app's own choices

    /// Reading never offers a table that writes braille only and export offers it, on the platform's own tables: the iPhone's
    /// pack has the German, Thai, Korean, Vietnamese, Hebrew, and Persian ones among its 40-odd; the Mac's has none, and
    /// VoiceOver's are the Mac's.
    func testExportOffersWhatReadingNeverDoes() {
        XCTAssertFalse(BrailleTableCatalog.offeredTables.contains(where: \.isPrintOnly), "a print-only table is offered for reading")
        XCTAssertTrue(
            Set(BrailleTableCatalog.offeredTables.map(\.id)).isSubset(of: BrailleTableCatalog.exportTables.map(\.id)),
            "export lacks a table reading has"
        )
        let ids = Set(BrailleTableCatalog.exportTables.filter(\.isPrintOnly).map(\.id))
        XCTAssertTrue(ids.isDisjoint(with: BrailleTableCatalog.offeredTables.map(\.id)))
        #if os(iOS)
        // The iPhone reads no Mac tables, even in a simulator, where the host Mac's folder is visible at its own path.
        XCTAssertNil(BrailleTableCatalog.mac)
        XCTAssertFalse(BrailleTableCatalog.exportTables.contains { $0.source == .mac })
        let expected: Set = ["de-g1.ctb", "de-g2.ctb", "th-g2.ctb", "ko-g2.ctb", "vi-vn-g2.ctb", "he-IL.utb", "fa-ir-g1.utb", "cs.tbl", "zh_CHN.tbl"]
        XCTAssertTrue(expected.isSubset(of: ids), "missing from export: \(expected.subtracting(ids).sorted())")
        XCTAssertGreaterThan(ids.count, 30)
        #endif
        // The export codes are grouped as the reading ones are: every table is in a code of its language.
        for code in BrailleTableCatalog.exportCodes {
            XCTAssertFalse(code.tables.isEmpty, code.id)
            XCTAssertTrue(code.tables.allSatisfy { BrailleTableCatalog.table(withID: $0.id) != nil }, code.id)
        }
    }

    /// The numbers of tables each list offers on this platform, written to the test log for the report (it asserts only that the
    /// lists are not empty): the tables for reading, for export, the print-only ones among the export tables, and the app's pack.
    func testTheNumbersOfTablesOffered() {
        let platform: String
        #if os(iOS)
        platform = "iPhone"
        #else
        platform = "Mac"
        #endif
        let reading = BrailleTableCatalog.offeredTables
        let export = BrailleTableCatalog.exportTables
        let readingLanguages = BrailleTableCatalog.languages(of: BrailleTableCatalog.offeredCodes).count
        let exportLanguages = BrailleTableCatalog.languages(of: BrailleTableCatalog.exportCodes).count
        print(
            "BRAILLE_COUNTS \(platform): reading \(reading.count) tables in \(readingLanguages) languages; "
                + "export \(export.count) tables in \(exportLanguages) languages, \(export.filter(\.isPrintOnly).count) of them print-only; "
                + "the pack's \(BrailleTableCatalog.bundledAll.count) tables, \(BrailleTableCatalog.bundled.count) for reading"
        )
        XCTAssertFalse(reading.isEmpty)
        XCTAssertGreaterThanOrEqual(export.count, reading.count)
    }

    /// The folder a run reads: a table of the app's pack is read from the unpacked pack; a Mac's own table, and a bare value
    /// the pack lacks that VoiceOver has, from VoiceOver's folder, on the Mac only. The iPhone never falls back to a folder of
    /// the host, which a simulator sees at its own path: a table its pack lacks is refused.
    func testTheFolderARunReadsFollowsTheAppsOwnTables() throws {
        let work = BrailleTranslator.Tool.helper
        XCTAssertNotEqual(try work.tablesFolder("en-ueb-g2.ctb"), BrailleTableCatalog.macTablesFolder)
        #if os(iOS)
        XCTAssertThrowsError(try work.tablesFolder("mac:no-such-table-on-any-device.ctb"))
        XCTAssertThrowsError(try work.tablesFolder("no-such-table-on-any-device.ctb"))
        #else
        XCTAssertEqual(try work.tablesFolder("mac:no-such-table-on-any-device.ctb"), BrailleTableCatalog.macTablesFolder)
        XCTAssertThrowsError(try work.tablesFolder("no-such-table-on-any-device.ctb"))
        #endif
    }

    /// A book or a setting that already names a print-only table keeps working: the table is found, its value is stored as
    /// it is, a translation with it goes on, and a read of a book with it is never refused as an unknown table.
    func testATableAlreadyInUseKeepsWorking() throws {
        #if os(iOS)
        let stored = "de-g1.ctb"
        #else
        let stored = "mac:cs.tbl"
        try XCTSkipIf(BrailleTableCatalog.table(withID: stored) == nil, "This Mac has no VoiceOver table cs.tbl")
        #endif
        let table = try XCTUnwrap(BrailleTableCatalog.table(withID: stored))
        XCTAssertTrue(table.isPrintOnly)
        XCTAssertEqual(table.id, stored)
        XCTAssertEqual(BrailleTableCatalog.storableValue(stored), stored)
        XCTAssertFalse(BrailleTableCatalog.description(ofTableID: stored).isEmpty)
        let work = try makeSandboxDirectory("PrintOnlyInUse")
        XCTAssertNoThrow(try BrailleTranslator.check(table: stored, workingIn: work))
        XCTAssertNoThrow(try BrailleTranslator.translate(["abc"], table: stored, direction: .printToBraille, workingIn: work))
        let sample = try copyOfFormatSample("brf/grade2-short.brf")
        do {
            _ = try BrailleBookReader.markdown(of: sample, table: stored)
        } catch let failure as BrailleTranslator.Failure {
            XCTFail("the book was refused for its table: \(failure)")
        } catch {
            // Any other failure belongs to the reading of this sample, not to the table.
        }
    }

    /// A value stored as another platform spells it finds its table in the lists: the Mac reads an iPhone's bare
    /// `fr-bfu-g2.ctb` with VoiceOver's file, which the lists spell `mac:fr-bfu-g2.ctb`, and the iPhone reads a Mac's
    /// `mac:fr-bfu-g2.ctb` with its pack's table. The stored value stays as it was; the table, its words, and the Braille
    /// tab's sentence are the list's.
    func testAStoredValueSpelledOtherwiseFindsItsTable() throws {
        #if os(macOS)
        try XCTSkipIf(BrailleTableCatalog.table(withID: "mac:fr-bfu-g2.ctb") == nil, "This Mac has no VoiceOver table fr-bfu-g2.ctb")
        let (stored, listed) = ("fr-bfu-g2.ctb", "mac:fr-bfu-g2.ctb")
        #else
        let (stored, listed) = ("mac:fr-bfu-g2.ctb", "fr-bfu-g2.ctb")
        #endif
        XCTAssertEqual(BrailleTableCatalog.listedID(forStored: stored), listed)
        XCTAssertEqual(BrailleTableCatalog.listedID(forStored: listed), listed)
        // A Mac's value for a table the app's own pack has is that bundled table, whichever platform: the twin the lists keep.
        XCTAssertEqual(BrailleTableCatalog.listedID(forStored: "mac:en-ueb-g2.ctb"), "en-ueb-g2.ctb")
        for value in ["en-ueb-g2.ctb", "mac:no-such-table.ctb", "no-such-table.ctb", ""] {
            XCTAssertEqual(BrailleTableCatalog.listedID(forStored: value), value, "a value no list spells otherwise changed")
        }
        // The Braille tab's pop-ups and Export's find the table, and name it as the list does.
        XCTAssertEqual(BrailleSettingsChoice.table(ofStored: stored, in: BrailleTableCatalog.offeredCodes)?.id, listed)
        XCTAssertEqual(BrailleTableCatalog.description(ofTableID: stored), BrailleTableCatalog.description(ofTableID: listed))
        let sentence = BrailleSettingsWording.source(
            ofStored: stored, codes: BrailleTableCatalog.offeredCodes, macLiblouisVersion: "3.34.0"
        )
        #if os(macOS)
        // The Mac's own tab: VoiceOver's table, with its language in its words, never "built into TextMouth".
        XCTAssertTrue(sentence.contains("VoiceOver"), sentence)
        XCTAssertTrue(BrailleTableCatalog.description(ofTableID: stored).contains(", in "), BrailleTableCatalog.description(ofTableID: stored))
        #else
        XCTAssertTrue(sentence.contains("built into TextMouth"), sentence)
        #endif
    }

    /// The Braille tab says that a setting naming a print-only table writes braille only, in its own sentence, and says what it
    /// said before for every other table.
    func testTheBrailleTabSaysASettingWritesOnly() {
        XCTAssertEqual(
            BrailleSettingsWording.source(ofTable: "de-g1.ctb", isOffered: false, macLiblouisVersion: nil, writesOnly: true),
            "The chosen table only writes braille, so it is not offered for reading braille files; choose another."
        )
        XCTAssertEqual(
            BrailleSettingsWording.source(ofTable: "en-ueb-g2.ctb", isOffered: true, macLiblouisVersion: nil),
            "The chosen table is built into TextMouth (liblouis \(BrailleTableCatalog.bundledLiblouisVersion))."
        )
    }

    /// The tab's own wiring says it: what the tab asks for a stored value (`source(ofStored:codes:macLiblouisVersion:)`, which
    /// the tab calls with the codes it lists) is the writes-only sentence for a print-only table, which no code listed for
    /// reading holds, and the usual one for a table it lists.
    func testTheBrailleTabAsksForWritesOnlyOfAPrintOnlyValue() throws {
        #if os(iOS)
        let printOnly = "de-g1.ctb"
        #else
        let printOnly = "mac:cs.tbl"
        try XCTSkipIf(BrailleTableCatalog.table(withID: printOnly)?.isPrintOnly != true, "This Mac has no print-only VoiceOver table cs.tbl")
        #endif
        let codes = BrailleTableCatalog.offeredCodes
        XCTAssertFalse(codes.contains { $0.tables.contains { $0.id == printOnly } })
        let writesOnly = "The chosen table only writes braille, so it is not offered for reading braille files; choose another."
        XCTAssertEqual(BrailleSettingsWording.source(ofStored: printOnly, codes: codes, macLiblouisVersion: nil), writesOnly)
        XCTAssertNotEqual(BrailleSettingsWording.source(ofStored: "en-ueb-g2.ctb", codes: codes, macLiblouisVersion: nil), writesOnly)
        // The tab never says "built into TextMouth" of a bare value that no list has, such as one the app's pack lacks.
        let unlisted = BrailleSettingsWording.source(ofStored: "no-such-table.ctb", codes: codes, macLiblouisVersion: nil)
        XCTAssertFalse(unlisted.contains("built into TextMouth"), unlisted)
        XCTAssertTrue(unlisted.contains("no-such-table.ctb"), unlisted)
        // The Mac's value for a table the app's pack has reads as that table, built in, whatever platform shares it.
        XCTAssertTrue(
            BrailleSettingsWording.source(ofStored: "mac:en-ueb-g2.ctb", codes: codes, macLiblouisVersion: nil).contains("built into TextMouth")
        )
    }
}
