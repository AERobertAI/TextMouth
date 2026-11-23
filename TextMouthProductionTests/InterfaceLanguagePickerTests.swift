import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Tests of the Interface Language picker (FR39): its choices and their words, what a change does and announces, the
/// Mac's group hosted in a window, a live switch reaching the views and the menu bar, and the iPhone's Settings rows.
///
/// Every test that switches puts System back when it ends, and every store is a sandboxed one: no test writes the real app
/// domain, whose `AppleLanguages` the installed app reads.
@MainActor
final class InterfaceLanguagePickerTests: XCTestCase {
    // MARK: - Support

    /// A new, empty sandboxed store for this test, which puts System back when the test ends, whatever it switched to.
    private func makeStoreRestoringSystem() -> InterfaceLanguageStore {
        let preferences = SandboxedPreferences("languagePicker")
        addTeardownBlock {
            InterfaceLanguage.choose(.system, store: InterfaceLanguageStore(preferences))
            preferences.discard()
        }
        return InterfaceLanguageStore(preferences)
    }

    /// The label of the choice for `code`.
    private func label(of code: String, in options: [InterfaceLanguageOption]) throws -> String {
        try XCTUnwrap(options.first { $0.choice == .language(code) }, "no choice for \(code)").label
    }

    // MARK: - The choices

    func testTheChoicesAreSystemThenEveryLanguage() {
        let options = InterfaceLanguagePicker.options(interfaceLanguage: "en", systemLanguage: "en")
        XCTAssertEqual(options.count, 26)
        XCTAssertEqual(options.first?.choice, .system)
        XCTAssertEqual(Set(options.dropFirst().map(\.choice)), Set(PluralRules.categories.keys.map { InterfaceLanguageChoice.language($0) }))
        XCTAssertEqual(Set(options.map(\.id)).count, 26, "no choice twice")
    }

    func testSystemIsNamedWithTheLanguageItGives() {
        XCTAssertEqual(InterfaceLanguagePicker.options(interfaceLanguage: "en", systemLanguage: "en").first?.label, "System (English)")
        XCTAssertEqual(InterfaceLanguagePicker.options(interfaceLanguage: "en", systemLanguage: "es").first?.label, "System (Español)")
        XCTAssertEqual(InterfaceLanguagePicker.options(interfaceLanguage: "ja", systemLanguage: "ar").first?.label, "System (العربية)")
        // Under hosted tests System gives English, whatever this Mac speaks.
        XCTAssertEqual(InterfaceLanguagePicker.options().first?.label, "System (English)")
    }

    /// Each language by its own name, then by its name in the interface language.
    func testALanguageIsNamedByItsOwnNameAndThenInTheInterfaceLanguage() throws {
        let english = InterfaceLanguagePicker.options(interfaceLanguage: "en", systemLanguage: "en")
        XCTAssertEqual(try label(of: "es", in: english), "Español, Spanish")
        XCTAssertEqual(try label(of: "de", in: english), "Deutsch, German")
        XCTAssertEqual(try label(of: "ja", in: english), "日本語, Japanese")
        XCTAssertEqual(try label(of: "ar", in: english), "العربية, Arabic")
        XCTAssertEqual(try label(of: "en", in: english), "English", "the same name twice is said once")

        let spanish = InterfaceLanguagePicker.options(interfaceLanguage: "es", systemLanguage: "es")
        XCTAssertEqual(try label(of: "en", in: spanish), "English, Inglés")
        XCTAssertEqual(try label(of: "de", in: spanish), "Deutsch, Alemán")
        XCTAssertEqual(try label(of: "es", in: spanish), "Español")
    }

    /// Someone who cannot read the interface language finds their own by its own name, first in every label.
    func testEveryLabelBeginsWithTheLanguagesOwnName() throws {
        for interface in ["en", "ar", "zh-Hans", "ja"] {
            let options = InterfaceLanguagePicker.options(interfaceLanguage: interface, systemLanguage: "en")
            for code in PluralRules.categories.keys {
                let own = InterfaceLanguagePicker.ownName(of: code)
                XCTAssertTrue(try label(of: code, in: options).hasPrefix(own), "\(code) in \(interface)")
                XCTAssertFalse(own.isEmpty)
                // No invisible isolate, which would defeat type-select and could show on a braille display.
                XCTAssertFalse(try label(of: code, in: options).unicodeScalars.contains { (0x2066...0x2069).contains($0.value) }, "\(code) in \(interface)")
            }
        }
    }

    /// Sorted by the own names, whatever the interface language is.
    func testTheLanguagesAreSortedByTheirOwnNames() {
        let owns = PluralRules.categories.keys
        for interface in ["en", "es", "ar"] {
            let sorted = InterfaceLanguagePicker.options(interfaceLanguage: interface, systemLanguage: "en").dropFirst()
            let names = sorted.compactMap { option -> String? in
                if case .language(let code) = option.choice { return InterfaceLanguagePicker.ownName(of: code) }
                return nil
            }
            XCTAssertEqual(names.count, owns.count)
            for (first, second) in zip(names, names.dropFirst()) {
                let order = first.compare(second, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: Locale(identifier: "en"))
                XCTAssertNotEqual(order, .orderedDescending, "\(first) before \(second) in \(interface)")
            }
        }
        // The order does not depend on the interface language.
        XCTAssertEqual(
            InterfaceLanguagePicker.options(interfaceLanguage: "en", systemLanguage: "en").map(\.choice),
            InterfaceLanguagePicker.options(interfaceLanguage: "ru", systemLanguage: "en").map(\.choice)
        )
    }

    func testTheOptionOfAChoice() {
        let options = InterfaceLanguagePicker.options(interfaceLanguage: "en", systemLanguage: "en")
        XCTAssertEqual(InterfaceLanguagePicker.option(for: .system, in: options)?.label, "System (English)")
        XCTAssertEqual(InterfaceLanguagePicker.option(for: .language("fr"), in: options)?.label, "Français, French")
        XCTAssertNil(InterfaceLanguagePicker.option(for: .language("xx"), in: options))
    }

    // MARK: - The words

    func testTheGroupsWords() {
        XCTAssertEqual(InterfaceLanguagePickerWording.title, "Interface Language")
        XCTAssertEqual(
            InterfaceLanguagePickerWording.hint,
            "Chooses the language of TextMouth's menus, windows, and messages. The change applies at once."
        )
        XCTAssertEqual(InterfaceLanguagePickerWording.launchNote, "Some of macOS's own words change the next time TextMouth opens.")
    }

    // MARK: - A change

    /// A change saves the choice, swaps the state, and announces the new language by its own name, in that language.
    func testAChangeSavesSwitchesAndAnnounces() throws {
        let store = makeStoreRestoringSystem()
        let before = VoiceOverAnnouncer.recordedAnnouncements.count

        let state = InterfaceLanguagePicker.apply(.language("es"), store: store, region: "US")
        XCTAssertEqual(state, InterfaceLanguage.State(language: "es", locale: Locale(identifier: "es_US")))
        XCTAssertEqual(InterfaceLanguage.current, state)
        XCTAssertEqual(store.storedLanguages(), ["es"])
        XCTAssertEqual(VoiceOverAnnouncer.recordedAnnouncements.count, before + 1)
        // The catalog's Spanish for "Interface language: %@": the announcement is spoken in the language switched to.
        XCTAssertEqual(VoiceOverAnnouncer.recordedAnnouncements.last?.message, "Idioma de la interfaz: Español")

        InterfaceLanguagePicker.apply(.system, store: store)
        XCTAssertEqual(InterfaceLanguage.current.language, "en")
        XCTAssertNil(store.storedLanguages())
        XCTAssertEqual(VoiceOverAnnouncer.recordedAnnouncements.last?.message, "Interface language: System (English)")
    }

    /// The group's pop-up lists, after a switch, the names in the new interface language.
    func testTheOptionsFollowTheLanguageInUse() throws {
        let store = makeStoreRestoringSystem()
        InterfaceLanguage.choose(.language("es"), store: store, region: "US")
        let options = InterfaceLanguagePicker.options()
        XCTAssertEqual(try label(of: "de", in: options), "Deutsch, Alemán")
    }

    // MARK: - The Mac's group in a window

    /// The group hosted in a window of a fixed size: the pop-up lists the choices, says its label and hint, and a switch of
    /// language words the choices again in place: the view is not rebuilt (it appears once, and its own state stays).
    func testTheGroupShowsTheChoicesAndFollowsASwitch() throws {
        let store = makeStoreRestoringSystem()
        let appearances = AppearanceCounter()
        let view = Form {
            InterfaceLanguageSettingsSection(choice: .system)
                .onAppear { appearances.count += 1 }
        }
        .frame(width: 450, height: 300)

        try withHostedView(
            view,
            size: NSSize(width: 450, height: 300),
            until: { !self.descendants(of: $0, as: NSPopUpButton.self).isEmpty }
        ) { hosting in
            let popUp = try XCTUnwrap(self.descendants(of: hosting, as: NSPopUpButton.self).first)
            XCTAssertEqual(popUp.itemTitles.count, 26)
            XCTAssertEqual(popUp.itemTitles.first, "System (English)")
            XCTAssertEqual(popUp.titleOfSelectedItem, "System (English)")
            XCTAssertTrue(popUp.itemTitles.contains("Deutsch, German"), "\(popUp.itemTitles)")
            let appearedOnce = appearances.count

            // The switch, as the picker's own change makes it, applied to this process.
            InterfaceLanguage.choose(.language("es"), store: store, region: "US")
            let reworded = self.waitUntil(timeout: 5) {
                hosting.layoutSubtreeIfNeeded()
                return self.descendants(of: hosting, as: NSPopUpButton.self).first?.itemTitles.contains("Deutsch, Alemán") == true
            }
            XCTAssertTrue(reworded, "the pop-up's choices were not worded again")
            let after = self.descendants(of: hosting, as: NSPopUpButton.self).first
            XCTAssertEqual(after?.itemTitles.count, 26)
            XCTAssertEqual(appearances.count, appearedOnce, "the group was not rebuilt: nothing appeared again")
        }
    }

    /// The pop-up speaks its label and its hint, and says the chosen language as its value.
    func testThePopUpSpeaksItsLabelAndHint() throws {
        let view = Form { InterfaceLanguageSettingsSection(choice: .language("fr")) }
            .frame(width: 450, height: 300)
        try withHostedControls(view) { controls in
            let popUp = try control(labelled: "Interface Language", in: controls)
            XCTAssertEqual(popUp.role, .popUpButton)
            XCTAssertEqual(popUp.hint, InterfaceLanguagePickerWording.hint)
            XCTAssertEqual(popUp.element.accessibilityValue() as? String, "Français, French")
        }
    }

    // MARK: - The menu bar

    /// After a switch the menu bar's titles are the new language's, and the visibility rules still find each menu by its
    /// title in the language now in use.
    func testTheMenuBarFollowsASwitch() throws {
        let store = makeStoreRestoringSystem()
        let titles = [MenuWording.library, MenuWording.playback, MenuWording.navigate, MenuWording.bookmarks, MenuWording.book]
        guard let mainMenu = NSApp.mainMenu, titles.allSatisfy({ title in mainMenu.items.contains { $0.title == title } }) else {
            throw XCTSkip("This host's menu bar does not hold the context menus yet")
        }

        InterfaceLanguage.choose(.language("es"), store: store, region: "US")
        let spanish = [MenuWording.library, MenuWording.playback, MenuWording.navigate, MenuWording.bookmarks, MenuWording.book]
        XCTAssertNotEqual(spanish, titles)
        let reworded = waitUntil(timeout: 5) {
            let items = Set(NSApp.mainMenu?.items.map(\.title) ?? [])
            return spanish.allSatisfy { items.contains($0) }
        }
        XCTAssertTrue(reworded, "the menu bar still has \(NSApp.mainMenu?.items.map(\.title) ?? [])")

        // Each context menu is found by its new title, so the manager can still hide and show it.
        let found = NSApp.mainMenu?.items.map(\.title).filter { MenuVisibilityManager.allContextMenuTitles.contains($0) } ?? []
        XCTAssertEqual(Set(found), Set(spanish))

        InterfaceLanguage.choose(.system, store: store)
        let restored = waitUntil(timeout: 5) {
            let items = Set(NSApp.mainMenu?.items.map(\.title) ?? [])
            return titles.allSatisfy { items.contains($0) }
        }
        XCTAssertTrue(restored)
    }

    /// The manager hides and shows a menu bar whose titles are in the language now in use, and the bar's direction
    /// follows the language.
    func testTheManagerFindsMenusInTheNewLanguage() {
        let store = makeStoreRestoringSystem()
        InterfaceLanguage.choose(.language("ar"), store: store, region: "US")

        let menu = NSMenu()
        for title in [MenuWording.library, MenuWording.playback, MenuWording.navigate, MenuWording.bookmarks, MenuWording.book] {
            menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        }
        MenuVisibilityManager.applyVisibility(for: .library, to: menu)
        XCTAssertEqual(menu.items.map(\.isHidden), [false, true, true, true, true])
        MenuVisibilityManager.applyVisibility(for: .reader, to: menu)
        XCTAssertEqual(menu.items.map(\.isHidden), [true, false, false, false, false])
        MenuVisibilityManager.applyVisibility(for: nil, to: menu)
        XCTAssertTrue(menu.items.allSatisfy(\.isHidden))

        MenuVisibilityManager.applyLayoutDirection(of: menu, for: InterfaceLanguage.current)
        XCTAssertEqual(menu.userInterfaceLayoutDirection, .rightToLeft)
        MenuVisibilityManager.applyLayoutDirection(of: menu, for: InterfaceLanguage.state(forScope: "es"))
        XCTAssertEqual(menu.userInterfaceLayoutDirection, .leftToRight)
    }

    // MARK: - A text a model keeps

    /// The Record window's status sentence stays on screen, so a switch words it again; a finished sentence the model told
    /// (and announced) stays as it was.
    func testTheRecordWindowsStatusIsWordedAgainAfterASwitch() throws {
        let store = makeStoreRestoringSystem()
        let harness = try RecordingWindowHarness(test: self, remembered: TestMicrophones.usb.id)
        XCTAssertEqual(harness.model.status, "Ready to record from Studio Microphone.")

        InterfaceLanguage.choose(.language("es"), store: store, region: "US")
        let reworded = waitUntil(timeout: 5) { harness.model.status == "Listo para grabar con Studio Microphone." }
        XCTAssertTrue(reworded, "the status stayed: \(harness.model.status)")

        InterfaceLanguage.choose(.system, store: store)
        let english = waitUntil(timeout: 5) { harness.model.status == "Ready to record from Studio Microphone." }
        XCTAssertTrue(english, "the status stayed: \(harness.model.status)")
    }

    /// The import overlay's extraction line and the move sheet's notice are made when read, so they follow a switch.
    func testKeptSentencesFollowASwitch() {
        let store = makeStoreRestoringSystem()
        var state = ImportProgressState()
        state.receive(
            .extracting(archive: "a.zip", progress: ArchiveExtractionProgress(entriesDone: 1, entries: 2, bytesDone: 1, bytes: 2)),
            at: Date()
        )
        let english = state.message
        XCTAssertTrue(english.hasPrefix("Extracting “a.zip”"), english)
        InterfaceLanguage.choose(.language("es"), store: store, region: "US")
        XCTAssertTrue(state.message.hasPrefix("Extrayendo “a.zip”"), state.message)
        InterfaceLanguage.choose(.system, store: store)
        XCTAssertEqual(state.message, english)
    }

    // MARK: - System's behavior

    /// For anyone who never opens the picker, the language in use is System's: English under hosted tests, the choice is
    /// System, and the group shows "System (English)".
    func testSystemIsTodaysBehavior() {
        XCTAssertEqual(InterfaceLanguage.current, InterfaceLanguage.systemState())
        XCTAssertEqual(InterfaceLanguageStore().choice(), .system)
        XCTAssertEqual(MenuWording.library, "Library")
    }
}

/// Counts how often a view appeared, for a test that a switch does not rebuild it.
@MainActor
private final class AppearanceCounter {
    var count = 0
}
