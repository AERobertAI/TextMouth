import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The Braille tab of Settings (FMT21): the tab itself, its two pop-ups
/// (the braille code and its contraction) with their labels and hints, what
/// they show and store, and every sentence it speaks. Each test's settings
/// live in a sandboxed preferences store and a config.json of the test's
/// own; nothing touches the real ones.
@MainActor
final class BrailleSettingsViewTests: XCTestCase {

    // MARK: - The Tab

    /// The tab comes right after Text, is named Braille, has a symbol that
    /// exists, and scrolls as a whole like every tab but Text.
    func testTheTabFollowsTextAndScrolls() throws {
        let tabs = SettingsTab.allCases
        let text = try XCTUnwrap(tabs.firstIndex(of: .text))
        XCTAssertEqual(tabs.firstIndex(of: .braille), text + 1)
        XCTAssertEqual(SettingsTab.braille.title, "Braille")
        XCTAssertEqual(SettingsTab.braille.systemImage, "hand.point.up.braille")
        XCTAssertNotNil(NSImage(systemSymbolName: SettingsTab.braille.systemImage, accessibilityDescription: nil))
        XCTAssertTrue(SettingsTab.braille.scrollsAsAWhole)
    }

    /// The window is wide enough for ten tabs: 780 points.
    func testTheWindowIsWideEnoughForTenTabs() {
        XCTAssertEqual(SettingsView.windowSize.width, 780)
    }

    // MARK: - The Pop-ups

    /// Both pop-ups are found by their labels, with their hints exactly.
    func testThePopUpsAreLabelledAndHinted() throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        try withBrailleTab(settings: makeSettings()) { hosting, _ in
            let controls = accessibleControls(in: hosting)
            let code = try control(labelled: "Braille code", in: controls)
            XCTAssertEqual(code.hint, "The braille code TextMouth reads braille files with and writes braille in.")
            let contraction = try control(labelled: "Contraction", in: controls)
            XCTAssertEqual(
                contraction.hint,
                "Whether that code's braille is contracted. Contracted braille writes common words and letter groups in fewer cells."
            )
        }
    }

    /// With the default setting, the code shown is Unified English Braille
    /// and the contraction Contracted (Grade 2).
    func testTheDefaultShowsUnifiedEnglishBrailleContracted() throws {
        try withBrailleTab(settings: makeSettings()) { hosting, _ in
            let (code, contraction) = try popUps(in: hosting)
            XCTAssertEqual(code.titleOfSelectedItem, "Unified English Braille")
            XCTAssertEqual(contraction.titleOfSelectedItem, "Contracted (Grade 2)")
        }
    }

    /// The code pop-up offers each bundled code by name, with no language
    /// grouping while there is only one language.
    func testTheCodePopUpOffersTheBundledCodes() throws {
        try withBrailleTab(settings: makeSettings()) { hosting, _ in
            let (code, _) = try popUps(in: hosting)
            XCTAssertEqual(code.itemTitles, ["English Braille, American Edition", "Unified English Braille"])
        }
    }

    /// The contraction pop-up offers exactly the two contractions each code
    /// has, whichever code is chosen.
    func testTheContractionPopUpOffersWhatTheChosenCodeHas() throws {
        let expected = ["Uncontracted (Grade 1)", "Contracted (Grade 2)"]
        for table in ["en-ueb-g2.ctb", "en_US.tbl"] {
            let settings = try makeSettings()
            settings.brailleTable = table
            try withBrailleTab(settings: settings) { hosting, _ in
                let (_, contraction) = try popUps(in: hosting)
                XCTAssertEqual(contraction.itemTitles, expected, "for \(table)")
            }
        }
    }

    /// Choosing English Braille, American Edition while contracted chooses
    /// its contracted table; then choosing Uncontracted chooses its
    /// uncontracted one. Each is stored.
    func testChoosingACodeAndAContractionStoresTheTable() throws {
        let defaults = try isolatedDefaults()
        let settings = try makeSettings(defaults: defaults)
        XCTAssertEqual(settings.brailleTable, "en-ueb-g2.ctb")
        try withBrailleTab(settings: settings) { hosting, _ in
            let (code, _) = try popUps(in: hosting)
            let american = try XCTUnwrap(code.itemTitles.firstIndex(of: "English Braille, American Edition"))
            code.menu?.performActionForItem(at: american)
            XCTAssertTrue(waitUntil { settings.brailleTable == "en_US.tbl" }, "choosing the code kept \(settings.brailleTable)")
            XCTAssertEqual(BraillePreferences.table.read(from: defaults), "en_US.tbl")

            // The pop-ups follow: the contraction is still Contracted.
            XCTAssertTrue(waitUntil {
                hosting.layoutSubtreeIfNeeded()
                guard let (code, contraction) = try? self.popUps(in: hosting) else { return false }
                return code.titleOfSelectedItem == "English Braille, American Edition"
                    && contraction.titleOfSelectedItem == "Contracted (Grade 2)"
            }, "the pop-ups did not follow the new code")

            let (_, contraction) = try popUps(in: hosting)
            let uncontracted = try XCTUnwrap(contraction.itemTitles.firstIndex(of: "Uncontracted (Grade 1)"))
            contraction.menu?.performActionForItem(at: uncontracted)
            XCTAssertTrue(waitUntil { settings.brailleTable == "en-us-g1.ctb" }, "choosing the contraction kept \(settings.brailleTable)")
            XCTAssertEqual(BraillePreferences.table.read(from: defaults), "en-us-g1.ctb")
        }
    }

    /// A broken bundle (no codes) shows no pop-ups, only the sentence that
    /// says so.
    func testNoCodesDrawNoPopUps() throws {
        let view = BrailleSettingsView(codes: [])
            .environmentObject(try makeSettings())
            .frame(width: 780, height: 540)
        // Nothing to wait for but a laid-out view, so ready at once.
        withHostedView(view, until: { _ in true }) { hosting in
            settleHostedView(hosting)
            XCTAssertTrue(descendants(of: hosting, as: NSPopUpButton.self).isEmpty)
        }
    }

    // MARK: - The Choices

    /// Choosing a code keeps the contraction when the code has it, else
    /// takes its full table, else its first.
    func testTheTableChosenForACode() {
        let g1 = table("a-g1", .no), partial = table("a-p", .partial), full = table("a-g2", .full)
        let both = code("a", [g1, full])
        XCTAssertEqual(BrailleSettingsChoice.table(in: both, matching: table("b-g1", .no))?.id, "a-g1")
        XCTAssertEqual(BrailleSettingsChoice.table(in: both, matching: table("b-g2", .full))?.id, "a-g2")
        // No partial table: the full one.
        XCTAssertEqual(BrailleSettingsChoice.table(in: both, matching: table("b-p", .partial))?.id, "a-g2")
        // No full table either: the first.
        XCTAssertEqual(BrailleSettingsChoice.table(in: code("c", [g1, partial]), matching: table("b-g2", .full))?.id, "a-g1")
        // No current table: the full one.
        XCTAssertEqual(BrailleSettingsChoice.table(in: both, matching: nil)?.id, "a-g2")
        XCTAssertNil(BrailleSettingsChoice.table(in: code("d", []), matching: g1))
    }

    /// Codes group by language in the order each language first appears.
    func testCodesGroupByLanguage() {
        let english = code("en/x", [table("en-x", .full)], language: "en")
        let german = code("de/y", [table("de-y", .full)], language: "de")
        let englishToo = code("en/z", [table("en-z", .full)], language: "en")
        let groups = BrailleSettingsChoice.languageGroups(of: [english, german, englishToo])
        XCTAssertEqual(groups.map(\.language), ["en", "de"])
        XCTAssertEqual(groups.map { $0.codes.map(\.id) }, [["en/x", "en/z"], ["de/y"]])
        XCTAssertEqual(BrailleSettingsChoice.languageGroups(of: []).count, 0)
    }

    // MARK: - The Wording

    /// Each sentence the tab speaks, pinned exactly.
    func testEveryWordingConstantIsPinned() {
        XCTAssertEqual(BrailleSettingsWording.tabTitle, "Braille")
        XCTAssertEqual(BrailleSettingsWording.sectionHeader, "Braille")
        XCTAssertEqual(BrailleSettingsWording.codeLabel, "Braille code")
        XCTAssertEqual(
            BrailleSettingsWording.codeHint,
            "The braille code TextMouth reads braille files with and writes braille in."
        )
        XCTAssertEqual(BrailleSettingsWording.contractionLabel, "Contraction")
        XCTAssertEqual(
            BrailleSettingsWording.contractionHint,
            "Whether that code's braille is contracted. Contracted braille writes common words and letter groups in fewer cells."
        )
        XCTAssertEqual(
            BrailleSettingsWording.caption,
            "TextMouth reads braille files (BRF, BRL, and PEF) with this code, and exports braille with it unless you choose another in the Export dialog. A book keeps the code it was imported with."
        )
        XCTAssertEqual(BrailleSettingsWording.noTables, "TextMouth found no braille tables in its bundle.")
    }

    // MARK: - Fixtures

    /// A settings model on a sandboxed store (the test's own, or `defaults`)
    /// and a config.json of the test's own.
    private func makeSettings(defaults: UserDefaults? = nil) throws -> SettingsViewModel {
        let store = try defaults ?? isolatedDefaults()
        return SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: store,
            configService: ConfigService(fileURL: try makeConfigFileURL())
        )
    }

    /// Hosts the tab at the Settings window's size, waits until both
    /// pop-ups are drawn, and passes the hosting view to `body`.
    private func withBrailleTab(
        settings: SettingsViewModel,
        _ body: (NSView, SettingsViewModel) throws -> Void
    ) throws {
        let view = BrailleSettingsView()
            .environmentObject(settings)
            .frame(width: SettingsView.windowSize.width, height: SettingsView.windowSize.height)
        try withHostedView(
            view,
            size: NSSize(width: SettingsView.windowSize.width, height: SettingsView.windowSize.height),
            until: { self.descendants(of: $0, as: NSPopUpButton.self).count == 2 }
        ) { hosting in
            try body(hosting, settings)
        }
    }

    /// The code pop-up and the contraction pop-up, in reading order.
    private func popUps(in hosting: NSView) throws -> (code: NSPopUpButton, contraction: NSPopUpButton) {
        let found = descendants(of: hosting, as: NSPopUpButton.self)
        // A failure, not a skip: the tab must draw both pop-ups.
        XCTAssertEqual(found.count, 2, "expected two pop-ups")
        return (try XCTUnwrap(found.first), try XCTUnwrap(found.last))
    }

    /// A table for the choice tests.
    private func table(_ id: String, _ contraction: Contraction) -> BrailleTable {
        BrailleTable(
            id: id, displayName: id, indexName: nil, language: "en", system: "x",
            contraction: contraction, grade: nil
        )
    }

    /// A code for the choice tests.
    private func code(_ id: String, _ tables: [BrailleTable], language: String = "en") -> BrailleCode {
        BrailleCode(id: id, language: language, system: "x", name: id, tables: tables)
    }
}
