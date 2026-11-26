import XCTest
@testable import TextMouth

/// The table an export on the iPhone starts from (FR31, FR40): the Braille setting's, when an export list has it, and the
/// default, with the Mac's sentence saying so, when none does.
///
/// The iPhone has no folder of the Mac's tables, so the Mac's test for a gone table cannot say what happens here
/// (`BrailleExportWriterTests` runs its half on both). A table the setting names that the pack lacks used to start the export
/// all the same, and fail at translation with a refusal by name; now the export starts from the default table.
final class PhoneBrailleExportOptionsTests: XCTestCase {
    /// A table of the iPhone's pack that reads and writes braille, as the pack names its file.
    private let packTable = "fr-bfu-g2.ctb"

    /// The options an export starts with when the Braille setting holds `stored`.
    private func options(whenTheSettingIs stored: String) -> BrailleExportOptions {
        BraillePreferences.$tableForImports.withValue(stored) { BrailleExportOptions.standard() }
    }

    /// A pack table named bare is kept as it is, with nothing replaced.
    func testATableOfThePackIsKept() {
        let options = options(whenTheSettingIs: packTable)

        XCTAssertEqual(options.table, packTable)
        XCTAssertNil(options.replacedTable)
    }

    /// A Mac's value for a table the pack has is kept as the Mac stored it, and shown as that table, in the words the Braille
    /// code row uses for the bare value.
    func testAMacValueOfATableThePackHasIsKeptAndShownAsThatTable() {
        let stored = "mac:\(packTable)"

        let options = options(whenTheSettingIs: stored)

        XCTAssertEqual(options.table, stored, "the value was changed")
        XCTAssertNil(options.replacedTable, "a table the pack has was replaced")
        XCTAssertEqual(PhoneSettingsModel.brailleTableValue(stored), PhoneSettingsModel.brailleTableValue(packTable))
        XCTAssertEqual(PhoneSettingsModel.brailleTableSelection(stored), packTable)
        XCTAssertNotEqual(
            PhoneSettingsModel.brailleTableValue(stored), stored,
            "the row would say the stored file name, not the table in words"
        )
    }

    /// A table that only writes braille is one an export offers, so a setting that names it is kept.
    func testATableThatOnlyWritesBrailleIsKept() throws {
        let printOnly = try XCTUnwrap(
            BrailleTableCatalog.exportCodes.lazy.flatMap(\.tables).first { $0.isPrintOnly },
            "the pack holds no table that only writes braille"
        )

        let options = options(whenTheSettingIs: printOnly.id)

        XCTAssertEqual(options.table, printOnly.id)
        XCTAssertNil(options.replacedTable)
    }

    /// A Mac's value for a table the pack lacks, and a bare name the pack lacks, are replaced by the default table, with the
    /// stored value kept as `replacedTable`, which is what the options' sentence names; the braille file characters stay.
    func testATableNoExportListHasIsReplacedByTheDefault() {
        for stored in ["mac:no-such-table-on-any-mac.ctb", "no-such-table-in-the-pack.ctb"] {
            let options = BraillePreferences.$fileCodeForImports.withValue(BrailleFileCode.eurobraille.id) {
                self.options(whenTheSettingIs: stored)
            }

            XCTAssertEqual(options.table, BrailleTableCatalog.defaultTableID, stored)
            XCTAssertEqual(options.replacedTable, stored, stored)
            XCTAssertEqual(options.fileCode, .eurobraille, "the default table's options lost the file characters for \(stored)")
        }
    }

    /// The sentence says which table could not be used, by the name the setting gave, and which table the export starts
    /// from; choosing another table in the rows forgets it.
    func testTheSentenceNamesTheTableAndTheDefault() {
        let stored = "no-such-table-in-the-pack.ctb"
        var options = options(whenTheSettingIs: stored)

        let sentence = BrailleExportWording.startsFromDefault(replacing: stored)

        XCTAssertTrue(sentence.contains("no-such-table-in-the-pack.ctb"), sentence)
        XCTAssertTrue(sentence.contains(BrailleTableCatalog.description(ofTableID: BrailleTableCatalog.defaultTableID)), sentence)
        XCTAssertEqual(options.replacedTable, stored)
        options.table = packTable
        XCTAssertNil(options.replacedTable)
    }
}
