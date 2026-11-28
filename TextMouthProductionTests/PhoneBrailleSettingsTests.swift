import Foundation
import XCTest
@testable import TextMouth

// The iPhone's Braille section of Settings (FR32): what its rows say and what its list of tables offers, as plain decisions
// the Mac's test host runs (`PhoneSettingsModel`); the screen itself is tested on the iPhone (BrailleSettingsUITests).
// Shared with the iPhone's unit bundle (project.yml).

@MainActor
final class PhoneBrailleSettingsTests: XCTestCase {
    // MARK: - Fixtures

    /// A table for a code's list, made as the catalog makes one from a header.
    private func table(
        _ id: String, _ displayName: String, language: String, system: String = "", contraction: Contraction, grade: String?,
        printOnly: Bool = false
    ) -> BrailleTable {
        BrailleTable(
            id: id, displayName: displayName, indexName: nil, language: language, system: system, contraction: contraction,
            grade: grade, isPrintOnly: printOnly
        )
    }

    /// The codes of a handful of tables in English, French, and German.
    private func codes() -> [BrailleCode] {
        BrailleTableCatalog.codes(of: [
            table("de-g1.ctb", "German partially contracted braille", language: "de", contraction: .partial, grade: "1"),
            table("fr-bfu-g2.ctb", "French contracted braille", language: "fr", contraction: .full, grade: "2"),
            table("en-ueb-g1.ctb", "Unified English uncontracted braille", language: "en", system: "ueb", contraction: .no, grade: "1"),
            table("en-ueb-g2.ctb", "Unified English contracted braille", language: "en", system: "ueb", contraction: .full, grade: "2"),
            table("fr-bfu-g1.ctb", "French uncontracted braille", language: "fr", contraction: .no, grade: "1"),
        ])
    }

    // MARK: - The Table List

    /// The tables are grouped by language as the Mac's tab groups its own, English first and then the rest by their names, each
    /// group headed by its language, and each choice reads as the code, how far it contracts, and its language, which is what
    /// VoiceOver says for its row.
    func testTheTablesAreGroupedByLanguageAndEachLabelNamesItsCodeGradeAndLanguage() {
        let groups = PhoneSettingsModel.brailleTableGroups(codes: codes())
        XCTAssertEqual(groups.map(\.title), ["English", "French", "German"])
        XCTAssertEqual(groups.map(\.id), ["en", "fr", "de"])
        XCTAssertEqual(groups.first?.choices.map(\.id), ["en-ueb-g1.ctb", "en-ueb-g2.ctb"])
        XCTAssertEqual(groups.first?.choices.map(\.label), [
            "Unified English Braille, uncontracted (Grade 1), in English",
            "Unified English Braille, contracted (Grade 2), in English",
        ])
        XCTAssertEqual(groups.dropFirst().first?.choices.map(\.label), [
            "French braille, uncontracted (Grade 1), in French", "French braille, contracted (Grade 2), in French",
        ])
        XCTAssertEqual(groups.last?.choices.map(\.label), ["German braille, partly contracted, in German"])
        let ids = groups.flatMap(\.choices).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "a table is listed twice")
        XCTAssertTrue(groups.flatMap(\.choices).allSatisfy(\.isEnabled))
    }

    /// With no code there is nothing to choose, and no empty group is made.
    func testNoCodesMakeNoGroups() {
        XCTAssertTrue(PhoneSettingsModel.brailleTableGroups(codes: []).isEmpty)
    }

    /// The app's own list offers every table it reads with, once, in groups that have a heading and tables, never a table that
    /// only writes braille, with the default table among them; the iPhone's has the languages of its whole pack.
    func testTheAppsOwnListOffersEveryTableItReadsWith() throws {
        let groups = PhoneSettingsModel.brailleTableGroups()
        XCTAssertFalse(groups.isEmpty)
        XCTAssertEqual(groups.first?.id, "en", "English comes first")
        for group in groups {
            XCTAssertNotNil(group.title, group.id)
            XCTAssertFalse(group.choices.isEmpty, group.id)
        }
        let ids = groups.flatMap(\.choices).map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertTrue(ids.contains(BrailleTableCatalog.defaultTableID))
        XCTAssertTrue(Set(ids).isSubset(of: BrailleTableCatalog.offeredTables.map(\.id)))
        XCTAssertFalse(ids.contains { BrailleTableCatalog.table(withID: $0)?.isPrintOnly == true }, "a table that only writes braille is offered for reading")
        let english = try XCTUnwrap(groups.first?.choices.first { $0.id == BrailleTableCatalog.defaultTableID })
        XCTAssertEqual(english.label, "Unified English Braille, contracted (Grade 2), in English")
        #if os(iOS)
        XCTAssertGreaterThan(groups.count, 20, "the iPhone's pack has the languages of liblouis")
        #endif
    }

    // MARK: - The Rows

    /// The Braille code row says the table in use as its value, in the words of its choice; a value no table has is said as it is.
    func testTheRowSaysTheTableInUse() {
        XCTAssertEqual(PhoneSettingsModel.brailleTableValue("en-ueb-g2.ctb"), "Unified English Braille, contracted (Grade 2), in English")
        XCTAssertEqual(PhoneSettingsModel.brailleTableValue("nothing-like-it.ctb"), "nothing-like-it.ctb")
    }

    /// A table a Mac shares as `mac:fr-bfu-g2.ctb` is the pack's `fr-bfu-g2.ctb` to the iPhone: its row is marked as the
    /// chosen one, and says its language as the choice does. On the Mac the same Mac value is its own, listed as it is.
    func testAMacValueMarksTheRowAndSaysItsLanguage() throws {
        #if os(macOS)
        try XCTSkipIf(BrailleTableCatalog.table(withID: "mac:fr-bfu-g2.ctb") == nil, "This Mac has no VoiceOver table fr-bfu-g2.ctb")
        #endif
        let stored = "mac:fr-bfu-g2.ctb"
        let listed = BrailleTableCatalog.listedID(forStored: stored)
        let rows = PhoneSettingsModel.brailleTableGroups().flatMap(\.choices)
        XCTAssertTrue(rows.contains { $0.id == listed }, "no row is marked for \(stored): the list holds no \(listed)")
        // The row the sheet marks as selected (the call the screen makes: its `selected:`) is one of the list's, exactly one.
        let selected = PhoneSettingsModel.brailleTableSelection(stored)
        XCTAssertEqual(rows.filter { $0.id == selected }.count, 1, "no row, or more than one, is marked for \(stored)")
        // The language's name as the app words it, in the interface language (not the system's).
        let french = try XCTUnwrap(InterfaceLanguage.current.locale.localizedString(forIdentifier: "fr"))
        XCTAssertTrue(PhoneSettingsModel.brailleTableValue(stored).hasSuffix(", in \(french)"), PhoneSettingsModel.brailleTableValue(stored))
        XCTAssertEqual(PhoneSettingsModel.brailleTableValue(stored), PhoneSettingsModel.brailleTableValue(listed))
        XCTAssertFalse(PhoneSettingsModel.brailleTableWritesOnly(stored))
    }

    /// A Mac's value for a table that only writes braille, `mac:cs.tbl`, is said to only write braille, so the row can say so
    /// as the Mac's tab does; no table for reading is.
    func testAPrintOnlyValueIsSaidToOnlyWriteBraille() throws {
        #if os(macOS)
        try XCTSkipIf(BrailleTableCatalog.table(withID: "mac:cs.tbl") == nil, "This Mac has no VoiceOver table cs.tbl")
        #endif
        XCTAssertTrue(PhoneSettingsModel.brailleTableWritesOnly("mac:cs.tbl"))
        XCTAssertFalse(PhoneSettingsModel.brailleTableWritesOnly("en-ueb-g2.ctb"))
        XCTAssertFalse(PhoneSettingsModel.brailleTableWritesOnly("nothing-like-it.ctb"))
    }

    /// The braille file characters are the two seven-bit codes an import may be set to, by name.
    func testTheFileCharactersAreTheCodesAnImportChoosesFrom() {
        let choices = PhoneSettingsModel.brailleFileCodeChoices
        XCTAssertEqual(choices.map(\.id), BrailleFileCode.importChoices.map(\.id))
        XCTAssertEqual(choices.map(\.label), BrailleFileCode.importChoices.map(\.name))
        XCTAssertGreaterThanOrEqual(choices.count, 2)
        for choice in choices {
            XCTAssertEqual(PhoneSettingsModel.brailleFileCodeName(choice.id), choice.label)
        }
        XCTAssertEqual(PhoneSettingsModel.brailleFileCodeName("ascii-no-such-code"), "ascii-no-such-code")
    }

    /// The section, its rows, its switch, and its caption say what the Mac's Braille tab says, in the Mac's words, with a
    /// caption of the iPhone's own.
    func testTheSectionsWordsAreTheMacsAndTheCaptionIsTheIPhones() {
        XCTAssertEqual(PhoneSettingsSection.braille.title, "Braille")
        XCTAssertEqual(PhoneSettingsRow.brailleTable.title, BrailleSettingsWording.codeLabel)
        // The row's hint says only reading: the iPhone writes no braille, unlike the Mac's pop-up (which reads and writes).
        XCTAssertEqual(PhoneSettingsRow.brailleTable.hint, "The braille code for reading braille files.")
        XCTAssertNotEqual(PhoneSettingsRow.brailleTable.hint, BrailleSettingsWording.codeHint)
        XCTAssertEqual(PhoneSettingsRow.brailleFileCode.hint, BrailleSettingsWording.fileCodeHint)
        let guess = PhoneSettingsSwitch.guessBrailleTable
        XCTAssertEqual(guess.title, "Guess the braille code of new books")
        XCTAssertEqual(guess.label, guess.title)
        XCTAssertEqual(guess.hint, BrailleSettingsWording.guessHint)
        XCTAssertEqual(
            PhoneSettingsWording.brailleCaption,
            "TextMouth reads braille files you add from now on with this code. A book keeps the code it was added with."
        )
    }

    /// The section sits after Reading and before Times, where Follow in Braille is.
    func testTheSectionComesAfterReading() throws {
        let sections = PhoneSettingsSection.allCases
        let reading = try XCTUnwrap(sections.firstIndex(of: .reading))
        XCTAssertEqual(sections[reading + 1], .braille)
        XCTAssertEqual(sections[reading + 2], .times)
    }

    // MARK: - Choosing

    /// A table chosen is the setting, in its own store, as the Mac's Braille tab sets it; one that no table has changes nothing,
    /// and the choice reads back as the row's value.
    func testAChoiceIsTheSettingAndSticks() throws {
        let preferences = makeSandboxedPreferences("phone-braille-settings")
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false, userDefaults: preferences)
        XCTAssertEqual(settings.brailleTable, BrailleTableCatalog.defaultTableID)
        let chosen = try XCTUnwrap(PhoneSettingsModel.brailleTableGroups().flatMap(\.choices).first { $0.id != BrailleTableCatalog.defaultTableID })
        settings.brailleTable = chosen.id
        XCTAssertEqual(settings.brailleTable, chosen.id)
        XCTAssertEqual(BraillePreferences.table.read(from: preferences), chosen.id, "the choice did not reach the setting imports read")
        XCTAssertEqual(PhoneSettingsModel.brailleTableValue(settings.brailleTable), chosen.label)
        settings.brailleTable = "no-such-table.ctb"
        XCTAssertEqual(settings.brailleTable, chosen.id)

        settings.brailleFileCode = BrailleFileCode.importChoices.last?.id ?? ""
        XCTAssertEqual(settings.brailleFileCode, BrailleFileCode.importChoices.last?.id)
        settings.guessesBrailleTable = false
        XCTAssertFalse(BraillePreferences.guessesTable.read(from: preferences))
    }
}
