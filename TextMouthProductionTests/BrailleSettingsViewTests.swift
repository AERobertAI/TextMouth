import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The Braille tab of Settings (FMT21): the tab itself, its four pop-ups
/// (the language, the braille code, and its contraction, the language since
/// October 20, 2026; and the braille file characters, braillecodes) with
/// their labels and hints, what they show and store, this Mac's tables taken
/// only once their check passes, and every sentence it speaks. Each test's
/// settings live in a sandboxed preferences store and a config.json of the
/// test's own; nothing touches the real ones. The
/// hosted tests show the bundled codes unless they say otherwise, so their
/// pop-ups list the same items on any Mac.
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

    /// The window is wide enough for eleven tabs: 860 points, since the
    /// Library tab joined the ten on October 30, 2026 (780 until then).
    func testTheWindowIsWideEnoughForElevenTabs() {
        XCTAssertEqual(SettingsView.windowSize.width, 860)
    }

    // MARK: - The Pop-ups

    /// The four pop-ups are found by their labels, with their hints exactly,
    /// in reading order. The fourth, the braille file characters, says the
    /// chosen code's name as its value: "North American Braille ASCII,
    /// Braille file characters, pop-up button".
    func testThePopUpsAreLabelledAndHinted() throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        try withBrailleTab(settings: makeSettings()) { hosting, _ in
            let controls = accessibleControls(in: hosting)
            let language = try control(labelled: "Language", in: controls)
            XCTAssertEqual(language.hint, "The language of the braille code TextMouth reads braille files with and writes braille in.")
            let code = try control(labelled: "Braille code", in: controls)
            XCTAssertEqual(code.hint, "The braille code TextMouth reads braille files with and writes braille in.")
            let contraction = try control(labelled: "Contraction", in: controls)
            XCTAssertEqual(
                contraction.hint,
                "Whether that code's braille is contracted. Contracted braille writes common words and letter groups in fewer cells."
            )
            let fileCode = try control(labelled: "Braille file characters", in: controls)
            XCTAssertEqual(
                fileCode.hint,
                "How a BRF or BRL file writes each braille cell as a character. Most files use North American Braille ASCII."
            )
            XCTAssertEqual(fileCode.role, .popUpButton)
            XCTAssertEqual(fileCode.element.accessibilityValue() as? String, "North American Braille ASCII")
            XCTAssertEqual(
                controls.filter { $0.role == .popUpButton }.map(\.label),
                ["Language", "Braille code", "Contraction", "Braille file characters"]
            )
        }
    }

    /// With the default setting, the language shown is English, the code
    /// Unified English Braille, and the contraction Contracted (Grade 2).
    func testTheDefaultShowsUnifiedEnglishBrailleContracted() throws {
        try withBrailleTab(settings: makeSettings()) { hosting, _ in
            let (language, code, contraction) = try popUps(in: hosting)
            XCTAssertEqual(language.titleOfSelectedItem, english)
            XCTAssertEqual(code.titleOfSelectedItem, "Unified English Braille")
            XCTAssertEqual(contraction.titleOfSelectedItem, "Contracted (Grade 2)")
        }
    }

    /// The code pop-up offers each bundled code by name.
    func testTheCodePopUpOffersTheBundledCodes() throws {
        try withBrailleTab(settings: makeSettings()) { hosting, _ in
            let (language, code, _) = try popUps(in: hosting)
            XCTAssertEqual(language.itemTitles, [english])
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
                let (_, _, contraction) = try popUps(in: hosting)
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
            let (_, code, _) = try popUps(in: hosting)
            let american = try XCTUnwrap(code.itemTitles.firstIndex(of: "English Braille, American Edition"))
            code.menu?.performActionForItem(at: american)
            XCTAssertTrue(waitUntil { settings.brailleTable == "en_US.tbl" }, "choosing the code kept \(settings.brailleTable)")
            XCTAssertEqual(BraillePreferences.table.read(from: defaults), "en_US.tbl")

            // The pop-ups follow: the contraction is still Contracted.
            XCTAssertTrue(waitUntil {
                hosting.layoutSubtreeIfNeeded()
                // Not `popUps(in:)`, which asserts: a redraw in between may
                // show fewer pop-ups for a moment, and the wait retries.
                guard let (_, code, contraction) = self.popUpTriple(in: hosting) else { return false }
                return code.titleOfSelectedItem == "English Braille, American Edition"
                    && contraction.titleOfSelectedItem == "Contracted (Grade 2)"
            }, "the pop-ups did not follow the new code")

            let (_, _, contraction) = try popUps(in: hosting)
            let uncontracted = try XCTUnwrap(contraction.itemTitles.firstIndex(of: "Uncontracted (Grade 1)"))
            contraction.menu?.performActionForItem(at: uncontracted)
            XCTAssertTrue(waitUntil { settings.brailleTable == "en-us-g1.ctb" }, "choosing the contraction kept \(settings.brailleTable)")
            XCTAssertEqual(BraillePreferences.table.read(from: defaults), "en-us-g1.ctb")
        }
    }

    /// A broken bundle (no codes) shows the sentence that says so in place
    /// of the pop-ups; a bundle with codes shows the pop-ups.
    func testNoCodesShowTheSentenceInPlaceOfThePopUps() {
        XCTAssertEqual(
            BrailleSettingsView.Content.of(codes: []),
            .noTables("TextMouth found no braille tables in its bundle."))
        XCTAssertEqual(BrailleSettingsView.Content.of(codes: [code("a", [table("a-g1", .no)])]), .choices)
        XCTAssertEqual(BrailleSettingsView.Content.of(codes: BrailleTableCatalog.bundledCodes), .choices)
    }

    /// With no codes the tab draws no pop-up.
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

    // MARK: - The Braille File Characters (braillecodes)

    /// The fourth pop-up lists the import's choices, the two seven-bit codes,
    /// by name, in the catalog's order, with North American Braille ASCII
    /// chosen when nothing is stored: Unicode braille patterns are recognized
    /// by a file's bytes, never chosen for an import (review finding 4).
    func testTheBrailleFileCharactersPopUpListsTheSevenBitCodes() throws {
        try withBrailleTab(settings: makeSettings()) { hosting, _ in
            let fileCode = try fileCodePopUp(in: hosting)
            XCTAssertEqual(fileCode.itemTitles, [northAmerican, eurobraille])
            XCTAssertEqual(fileCode.titleOfSelectedItem, northAmerican)
        }
    }

    /// The rows after the table pop-ups come in this reading order: the
    /// code's caption, then the braille file characters pop-up and its own
    /// caption, so neither caption is heard as the other's (review finding
    /// 7); with no tables, the caption alone.
    func testTheBrailleFileCharactersFollowTheCodesCaption() {
        XCTAssertEqual(
            BrailleSettingsView.trailingRows(for: .choices),
            [.caption, .fileCodePopUp, .fileCodeCaption, .guessSwitch, .guessCaption]
        )
        XCTAssertEqual(BrailleSettingsView.trailingRows(for: .noTables(BrailleSettingsWording.noTables)), [.caption])
    }

    /// Choosing Eurobraille stores its id, in the preferences store and in
    /// config.json, and leaves the table alone.
    func testChoosingEurobrailleStoresItsID() throws {
        let defaults = try isolatedDefaults()
        let url = try makeConfigFileURL()
        let service = ConfigService(fileURL: url)
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(), initializeServices: false, userDefaults: defaults, configService: service
        )
        XCTAssertEqual(settings.brailleFileCode, "ascii-na")
        try withBrailleTab(settings: settings) { hosting, _ in
            let fileCode = try fileCodePopUp(in: hosting)
            let item = try XCTUnwrap(fileCode.itemTitles.firstIndex(of: eurobraille))
            fileCode.menu?.performActionForItem(at: item)
            XCTAssertTrue(waitUntil { settings.brailleFileCode == "ascii-eurobraille" }, "choosing the code kept \(settings.brailleFileCode)")
            XCTAssertEqual(BraillePreferences.fileCode.read(from: defaults), "ascii-eurobraille")
        }
        XCTAssertEqual(settings.brailleTable, "en-ueb-g2.ctb")
        service.flushScheduledSave()
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(saved?["brailleFileCode"] as? String, "ascii-eurobraille")
    }

    /// A stored Eurobraille shows chosen when the tab opens.
    func testAStoredCodeShowsChosenWhenTheTabOpens() throws {
        let defaults = try isolatedDefaults()
        BraillePreferences.fileCode.write("ascii-eurobraille", to: defaults)
        try withBrailleTab(settings: makeSettings(defaults: defaults)) { hosting, _ in
            XCTAssertEqual(try fileCodePopUp(in: hosting).titleOfSelectedItem, eurobraille)
        }
    }

    // MARK: - This Mac's Tables in the Pop-ups

    /// With a language of this Mac's beside English, the language pop-up
    /// lists English first; the code pop-up lists only the shown language's
    /// codes.
    func testTheLanguagePopUpListsEnglishFirst() throws {
        try withBrailleTab(settings: makeSettings(), codes: codesWithAFixtureMacLanguage()) { hosting, _ in
            let (language, code, _) = try popUps(in: hosting)
            XCTAssertEqual(language.itemTitles, [english, french])
            XCTAssertEqual(language.titleOfSelectedItem, english)
            XCTAssertEqual(code.itemTitles, ["English Braille, American Edition", "Unified English Braille"])
        }
    }

    /// Choosing a Mac table whose check fails takes nothing: the setting
    /// keeps its table, the pop-ups return to it, and VoiceOver hears the
    /// table's name and why. The fixture's table is on no Mac, so its check
    /// finds it gone without running the helper.
    func testARefusedMacTableIsNotTakenAndVoiceOverHearsWhy() throws {
        let defaults = try isolatedDefaults()
        let settings = try makeSettings(defaults: defaults)
        var heard: [String] = []
        let previousPoster = VoiceOverAnnouncer.poster
        VoiceOverAnnouncer.poster = { announcement, _ in heard.append(announcement.message) }
        defer { VoiceOverAnnouncer.poster = previousPoster }
        let expected = "TextMouth can't use this Mac's table \u{201C}Fixture French contracted braille\u{201D}: this Mac no longer has it."

        try withBrailleTab(settings: settings, codes: codesWithAFixtureMacLanguage()) { hosting, _ in
            let (language, _, _) = try popUps(in: hosting)
            let frenchItem = try XCTUnwrap(language.itemTitles.firstIndex(of: french))
            language.menu?.performActionForItem(at: frenchItem)
            XCTAssertTrue(waitUntil(timeout: 5) { heard.contains(expected) }, "VoiceOver heard \(heard)")
            XCTAssertEqual(settings.brailleTable, "en-ueb-g2.ctb")
            XCTAssertEqual(BraillePreferences.table.read(from: defaults), "en-ueb-g2.ctb")
            XCTAssertTrue(waitUntil {
                hosting.layoutSubtreeIfNeeded()
                guard let (language, code, contraction) = self.popUpTriple(in: hosting) else { return false }
                return language.titleOfSelectedItem == self.english && code.titleOfSelectedItem == "Unified English Braille"
                    && contraction.titleOfSelectedItem == "Contracted (Grade 2)"
            }, "the pop-ups did not return to the table in use")
        }
    }

    /// Choosing French on this Mac takes its contracted table, keeping the
    /// contraction, once the real check passes, and stores it with the Mac
    /// prefix, in the preferences store and in config.json.
    func testChoosingThisMacsFrenchTakesItOnceItsCheckPasses() throws {
        try XCTSkipIf(BrailleTableCatalog.table(withID: "mac:fr-bfu-g2.ctb") == nil,
                      "This Mac does not offer its French contracted table (\(BrailleTableCatalog.macTablesFolder.path))")
        let defaults = try isolatedDefaults()
        let url = try makeConfigFileURL()
        let service = ConfigService(fileURL: url)
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(), initializeServices: false, userDefaults: defaults, configService: service
        )
        try withBrailleTab(settings: settings, codes: BrailleTableCatalog.offeredCodes) { hosting, _ in
            let (language, _, _) = try popUps(in: hosting)
            XCTAssertEqual(language.itemTitles.first, english)
            let frenchItem = try XCTUnwrap(language.itemTitles.firstIndex(of: french))
            language.menu?.performActionForItem(at: frenchItem)
            XCTAssertTrue(waitUntil(timeout: 10) { settings.brailleTable == "mac:fr-bfu-g2.ctb" }, "the table is \(settings.brailleTable)")
            XCTAssertTrue(waitUntil {
                hosting.layoutSubtreeIfNeeded()
                guard let (language, code, contraction) = self.popUpTriple(in: hosting) else { return false }
                return language.titleOfSelectedItem == self.french && code.titleOfSelectedItem == "French braille"
                    && contraction.titleOfSelectedItem == "Contracted (Grade 2)"
            }, "the pop-ups did not show French")
        }
        service.flushScheduledSave()
        XCTAssertEqual(BraillePreferences.table.read(from: defaults), "mac:fr-bfu-g2.ctb")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(saved?["brailleTable"] as? String, "mac:fr-bfu-g2.ctb")
    }

    /// The pop-ups check a chosen table in the folder the environment gives
    /// (review F7): given a folder under a plain file, where no working
    /// folder can be made, the check says so, where a check in the real
    /// temporary directory would find the fixture's table gone instead.
    func testTheCheckWorksInTheFolderTheEnvironmentGives() throws {
        let settings = try makeSettings()
        var heard: [String] = []
        let previousPoster = VoiceOverAnnouncer.poster
        VoiceOverAnnouncer.poster = { announcement, _ in heard.append(announcement.message) }
        defer { VoiceOverAnnouncer.poster = previousPoster }
        let file = try makeSandboxDirectory("BrailleTabCheckRoot").appendingPathComponent("plain.txt")
        try "not a folder".write(to: file, atomically: true, encoding: .utf8)
        let expected = "TextMouth could not check this Mac's table \u{201C}Fixture French contracted braille\u{201D}: "
            + "TextMouth could not make a folder to check it in. Choose it again to try once more."

        try withBrailleTab(settings: settings, codes: codesWithAFixtureMacLanguage(), checkRoot: file) { hosting, _ in
            let (language, _, _) = try popUps(in: hosting)
            language.menu?.performActionForItem(at: try XCTUnwrap(language.itemTitles.firstIndex(of: french)))
            XCTAssertTrue(waitUntil(timeout: 5) { heard.contains(expected) }, "VoiceOver heard \(heard)")
        }
        XCTAssertEqual(settings.brailleTable, "en-ueb-g2.ctb")
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

    /// Choosing a language takes the table of its code that holds the
    /// default table, else of its first code, keeping the contraction where
    /// it can; a language with no codes gives none.
    func testTheTableChosenForALanguage() throws {
        let english = try XCTUnwrap(BrailleTableCatalog.languages(of: BrailleTableCatalog.bundledCodes).first)
        // English's first code is the American one, but the default's code wins.
        XCTAssertEqual(BrailleSettingsChoice.table(in: english, matching: table("x-g1", .no))?.id, "en-ueb-g1.ctb")
        XCTAssertEqual(BrailleSettingsChoice.table(in: english, matching: nil)?.id, "en-ueb-g2.ctb")
        let other = BrailleLanguage(id: "xx", name: "X", codes: [code("x/one", [table("x-g1", .no), table("x-g2", .full)])])
        XCTAssertEqual(BrailleSettingsChoice.table(in: other, matching: table("y-g1", .no))?.id, "x-g1")
        XCTAssertNil(BrailleSettingsChoice.table(in: BrailleLanguage(id: "zz", name: "Z", codes: []), matching: nil))
    }

    // MARK: - The Wording

    /// Each sentence the tab speaks, pinned exactly.
    func testEveryWordingConstantIsPinned() {
        XCTAssertEqual(BrailleSettingsWording.tabTitle, "Braille")
        XCTAssertEqual(BrailleSettingsWording.sectionHeader, "Braille")
        XCTAssertEqual(BrailleSettingsWording.languageLabel, "Language")
        XCTAssertEqual(
            BrailleSettingsWording.languageHint,
            "The language of the braille code TextMouth reads braille files with and writes braille in."
        )
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
        XCTAssertEqual(BrailleSettingsWording.fileCodeLabel, "Braille file characters")
        XCTAssertEqual(
            BrailleSettingsWording.fileCodeHint,
            "How a BRF or BRL file writes each braille cell as a character. Most files use North American Braille ASCII."
        )
        XCTAssertEqual(
            BrailleSettingsWording.caption,
            "TextMouth reads braille files (BRF, BRL, and PEF) with this code, and exports braille with it unless you choose another in the Export dialog. A book keeps the code it was imported with."
        )
        XCTAssertEqual(
            BrailleSettingsWording.fileCodeCaption,
            "TextMouth reads BRF and BRL files you add from now on with these characters; a file of Unicode braille patterns is recognized by itself. The Export dialog starts a BRF with them. A book keeps the characters it was imported with, which Book Information can change."
        )
        XCTAssertEqual(BrailleSettingsWording.noTables, "TextMouth found no braille tables in its bundle.")
    }

    /// The sentence that says where the chosen table comes from, for a
    /// bundled table, a Mac one with and without a known version, and a Mac
    /// one this Mac no longer has.
    func testTheSourceSentences() {
        XCTAssertEqual(
            BrailleSettingsWording.source(ofTable: "en-ueb-g2.ctb", isOffered: true, macLiblouisVersion: "3.34.0"),
            "The chosen table is built into TextMouth (liblouis 3.39.0)."
        )
        XCTAssertEqual(
            BrailleSettingsWording.source(ofTable: "mac:fr-bfu-g2.ctb", isOffered: true, macLiblouisVersion: "3.34.0"),
            "The chosen table is one of this Mac's VoiceOver braille tables (liblouis 3.34.0)."
        )
        XCTAssertEqual(
            BrailleSettingsWording.source(ofTable: "mac:fr-bfu-g2.ctb", isOffered: true, macLiblouisVersion: nil),
            "The chosen table is one of this Mac's VoiceOver braille tables."
        )
        XCTAssertEqual(
            BrailleSettingsWording.source(ofTable: "mac:fr-bfu-g2.ctb", isOffered: false, macLiblouisVersion: "3.34.0"),
            "This Mac no longer has the chosen table, \u{201C}mac:fr-bfu-g2.ctb\u{201D}; choose another."
        )
    }

    /// The sentence VoiceOver hears for each refusal of a chosen Mac table.
    func testTheRefusalSentences() {
        let name = "Greek braille"
        XCTAssertEqual(
            BrailleSettingsWording.refusal(ofTableNamed: name, because: .doesNotLoad),
            "TextMouth can't use this Mac's table \u{201C}Greek braille\u{201D}: it does not load in TextMouth's liblouis 3.39.0."
        )
        XCTAssertEqual(
            BrailleSettingsWording.refusal(ofTableNamed: name, because: .writesEightDots),
            "TextMouth can't use this Mac's table \u{201C}Greek braille\u{201D}: it writes eight-dot braille, and TextMouth uses six-dot braille only."
        )
        XCTAssertEqual(
            BrailleSettingsWording.refusal(ofTableNamed: name, because: .gone),
            "TextMouth can't use this Mac's table \u{201C}Greek braille\u{201D}: this Mac no longer has it."
        )
        XCTAssertEqual(
            BrailleSettingsWording.refusal(ofTableNamed: name, because: .helperFailed),
            "TextMouth could not check this Mac's table \u{201C}Greek braille\u{201D}: the braille helper failed. Choose it again to try once more."
        )
    }

    // MARK: - Fixtures

    /// English and French in the user's own language, as the language
    /// pop-up names them.
    private var english: String { Locale.current.localizedString(forIdentifier: "en") ?? "en" }
    private var french: String { Locale.current.localizedString(forIdentifier: "fr") ?? "fr" }

    /// Two braille file codes as the braille file characters pop-up names
    /// them, pinned here rather than read from the catalog.
    private let northAmerican = "North American Braille ASCII"
    private let eurobraille = "Eurobraille, six-dot (German-speaking countries)"

    /// The bundled codes and a French code of this Mac's whose tables no Mac
    /// has: an uncontracted and a contracted one.
    private func codesWithAFixtureMacLanguage() -> [BrailleCode] {
        let tables = ["no": "Fixture French uncontracted braille", "full": "Fixture French contracted braille"]
            .sorted { $0.key > $1.key }
            .map { contraction, name in
                BrailleTable(
                    id: "mac:fixture-fr-\(contraction).ctb", displayName: name, indexName: nil, language: "fr",
                    system: "", contraction: Contraction(rawValue: contraction) ?? .no, grade: nil
                )
            }
        return BrailleTableCatalog.bundledCodes + BrailleTableCatalog.codes(of: tables)
    }

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

    /// Hosts the tab, showing `codes`, at the Settings window's size, waits
    /// until its four pop-ups are drawn, and passes the hosting view to
    /// `body`. A Mac table chosen there is checked with verdicts of the
    /// test's own, in a working folder made in `checkRoot` (a sandbox folder
    /// of its own when nil), given through the environment, so neither
    /// depends on when SwiftUI calls the pop-ups' bindings (review R8).
    private func withBrailleTab(
        settings: SettingsViewModel,
        codes: [BrailleCode] = BrailleTableCatalog.bundledCodes,
        checkRoot: URL? = nil,
        _ body: (NSView, SettingsViewModel) throws -> Void
    ) throws {
        let context = BrailleTableCheckContext(
            verdicts: MacBrailleTableCheck.Verdicts(),
            temporaryRoot: try checkRoot ?? makeSandboxDirectory("BrailleTabCheck")
        )
        let view = BrailleSettingsView(codes: codes)
            .environment(\.brailleTableCheck, context)
            .environmentObject(settings)
            .frame(width: SettingsView.windowSize.width, height: SettingsView.windowSize.height)
        try withHostedView(
            view,
            size: NSSize(width: SettingsView.windowSize.width, height: SettingsView.windowSize.height),
            until: { self.descendants(of: $0, as: NSPopUpButton.self).count == 4 }
        ) { hosting in
            try body(hosting, settings)
        }
    }

    /// The language, code, and contraction pop-ups: the first three of the
    /// four, in reading order, by position (the fourth, the last, is the
    /// braille file characters, `fileCodePopUp(in:)`).
    private func popUps(in hosting: NSView) throws -> (language: NSPopUpButton, code: NSPopUpButton, contraction: NSPopUpButton) {
        let found = drawnPopUps(in: hosting)
        return (try XCTUnwrap(found.first), try XCTUnwrap(found.dropFirst().first), try XCTUnwrap(found.dropFirst(2).first))
    }

    /// The braille file characters pop-up: the fourth in reading order,
    /// after the language, code, and contraction.
    private func fileCodePopUp(in hosting: NSView) throws -> NSPopUpButton {
        try XCTUnwrap(drawnPopUps(in: hosting).dropFirst(3).first)
    }

    /// Every pop-up the tab drew, in reading order, failing the test unless
    /// all four are drawn.
    private func drawnPopUps(in hosting: NSView) -> [NSPopUpButton] {
        let found = descendants(of: hosting, as: NSPopUpButton.self)
        // A failure, not a skip: the tab must draw all four pop-ups.
        XCTAssertEqual(found.count, 4, "expected four pop-ups")
        return found
    }

    /// The same three pop-ups as `popUps(in:)`, or nil unless all four are
    /// drawn, with no assertion: for a `waitUntil` condition, which is asked
    /// again until it holds and must not record a failure on the way.
    private func popUpTriple(in hosting: NSView) -> (language: NSPopUpButton, code: NSPopUpButton, contraction: NSPopUpButton)? {
        let found = descendants(of: hosting, as: NSPopUpButton.self)
        guard found.count == 4 else { return nil }
        return (found[0], found[1], found[2])
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
