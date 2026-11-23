import XCTest
@testable import TextMouth

/// The Spanish of the pilot's areas (FR35) as the built app carries it: the sleep timer, bookmarks, and the Reading List
/// are in the app's `Strings.pack`, plural forms included, and a line asked for in Spanish reads its Spanish.
///
/// The suite runs in English, so this reads Spanish the two ways that work inside the test host: the pack's own Spanish
/// entries, by the lines' IDs (the apps ship no Apple table since FR39 phase 8), and TextMouth's own engine,
/// `InterfaceText.line(_:_:language:)`, which reads the pack with the language it is given.
final class SpanishLocalizationTests: XCTestCase {
    /// The app the tests run in, whose bundle carries the pack and lists its languages.
    private var app: Bundle { Bundle.main }

    /// The app's Spanish entries by ID, read from its `Strings.pack`: a text, a plural's forms in Spanish's category order
    /// (`one`, `many`, `other`), or nothing for an ID with no Spanish. Fails with what is missing.
    private func spanishEntries() throws -> [String: InterfaceTextEntry] {
        let pack = try XCTUnwrap(try InterfaceTextPack.inMainBundle(), "No Strings.pack in \(app.bundlePath)")
        XCTAssertTrue(pack.hasLanguage("es"), "The pack has no Spanish blob")
        let list = try pack.idList()
        let entries = try pack.entries(language: "es")
        XCTAssertEqual(entries.count, list.count)
        var found: [String: InterfaceTextEntry] = [:]
        for (position, entry) in entries.enumerated() { found[list.id(at: position)] = entry }
        return found
    }

    /// The text of a Spanish entry that is a plain text, or nil for a plural or no entry.
    private func plainText(_ entry: InterfaceTextEntry?) -> String? {
        if case .plain(let text)? = entry { return text }
        return nil
    }

    /// The app carries Spanish beside English, its development language.
    func testTheAppCarriesSpanish() {
        XCTAssertTrue(app.localizations.contains("es"), "The app's localizations: \(app.localizations)")
        XCTAssertEqual(app.developmentLocalization, "en")
    }

    /// The pack's Spanish holds each area's strings: a heading, a label, a hint, and an announcement of each, every
    /// plural string with its three Spanish categories, and no empty text.
    func testSpanishHoldsTheAreasStrings() throws {
        let entries = try spanishEntries()
        // ID (the line's permanent key) and its Spanish; the comment names where it comes from.
        let expected: [(id: String, spanish: String)] = [
            ("common.sleepTimer", "Temporizador de apagado"),  // SleepTimerView.title
            ("sleepTimerView.closeHint", "Vuelve al libro."),  // SleepTimerView.closeHint
            ("sleepTimerView.endOfHeadingLabel", "Detener al final de este encabezado"),  // SleepTimerView.endOfHeadingLabel
            ("readerViewModel.sleepTimerExpiredAnnouncement",
             "El temporizador de apagado terminó. Reproducción en pausa."),  // ReaderViewModel.sleepTimerExpiredAnnouncement
            ("common.bookmarks", "Marcadores"),  // BookmarkPanelView.title
            ("common.bookmarkValue", "Marcador %@"),  // Bookmark.name; the number is an identifier, so %@, not %lld
            ("bookmarkRow.hint", "Va a este marcador y cierra la lista."),  // BookmarkRow.hint
            ("readingList.orderName", "Orden de la lista de lectura"),  // ReadingListWording.orderName
            ("readingListReader.place", "Lista de lectura, libro %1$lld de %2$lld"),  // ReadingListReaderWording.place
            ("readingListReader.noNeighbor.next",
             "No hay ningún libro siguiente en la lista de lectura."),  // ReadingListReaderWording.noNeighbor
            ("sleepTimerView.resetTimerHint",
             "Reinicia el temporizador con su duración completa y reproduce el libro."),  // SleepTimerView.resetTimerHint
            ("readingList.keepBooksLabel", "Conservar estos libros en esta Mac"),  // the glossary's rule: esta Mac (Latin American)
            ("common.remove", "Eliminar"),  // PhoneBookmarksWording.removeButton: removing a bookmark deletes it
        ]
        var wrong: [String] = []
        for (id, spanish) in expected where plainText(entries[id]) != spanish {
            wrong.append("\(id): \(entries[id].map { "\($0)" } ?? "missing"), not \(spanish)")
        }
        XCTAssertTrue(wrong.isEmpty, "Strings.pack, Spanish:\n" + wrong.joined(separator: "\n"))

        // Every Spanish text of the pack: the plain texts, and each plural's forms.
        let texts = entries.values.flatMap { entry -> [String] in
            switch entry {
            case .absent: return []
            case .plain(let text): return [text]
            case .plural(let forms): return forms
            }
        }
        XCTAssertGreaterThan(texts.count, 3000, "Too few Spanish texts in the pack")
        XCTAssertTrue(texts.filter(\.isEmpty).isEmpty, "Empty Spanish text ships")
        // The Spanish never says este Mac, which is Spain's: this Spanish is Latin American (esta Mac).
        XCTAssertTrue(texts.filter { $0.contains("este Mac") }.isEmpty)

        // The pack is keyed by ID: every key is an ID (two to four lower camel case segments), never English text, so a
        // fragment of an English sentence has no entry of its own (finding 3 of the review: "Downloading the next
        // episodio: ..." read half Spanish).
        let notIDs = entries.keys.filter { $0.range(of: "^[a-z][A-Za-z0-9]*(\\.[a-z][A-Za-z0-9]*){1,3}$", options: .regularExpression) == nil }
        XCTAssertTrue(notIDs.isEmpty, "The pack holds keys that are not IDs: \(notIDs.sorted().prefix(10))")

        // The plural strings hold Spanish's three categories (`one`, `many`, `other`), in that order, each with a text.
        for id in ["common.countMinutes", "sleepTimerView.setTimerLabel", "readingList.addTitle", "readingList.addedAnnouncement.already"] {
            guard case .plural(let forms)? = entries[id] else {
                XCTFail("\(id) is not a plural entry in the Spanish of the pack: \(String(describing: entries[id]))")
                continue
            }
            XCTAssertEqual(PluralRules.categories["es"], ["one", "many", "other"])
            XCTAssertEqual(forms.count, 3, "\(id) lacks Spanish plural forms in the pack: \(forms)")
            XCTAssertTrue(forms.filter(\.isEmpty).isEmpty, "\(id) has an empty Spanish plural form")
        }
    }

    /// A line asked for in Spanish through the engine reads the catalog's Spanish: a plain text, a placeholder, and a plural
    /// in both its categories; asked for in English, the plural reads its English forms, which the pack ships too.
    func testALineInSpanishReadsItsSpanish() {
        // Each ID is one the app's own code uses (SleepTimerView.title, Bookmark.name, whose number is a String so its English holds %@, and SleepTimerDuration.displayName).
        XCTAssertEqual(InterfaceText.line("common.sleepTimer", "Sleep Timer", language: "es"), "Temporizador de apagado")
        XCTAssertEqual(InterfaceText.line("common.bookmarkValue", "Bookmark \(String(3))", language: "es"), "Marcador 3")
        XCTAssertEqual(InterfaceText.line("common.countMinutes", "\(number: 1) minutes", language: "es"), "1 minuto")
        XCTAssertEqual(InterfaceText.line("common.countMinutes", "\(number: 30) minutes", language: "es"), "30 minutos")
        XCTAssertEqual(InterfaceText.line("common.countMinutes", "\(number: 1) minutes", language: "en"), "1 minute")
        XCTAssertEqual(InterfaceText.line("common.countMinutes", "\(number: 30) minutes", language: "en"), "30 minutes")
    }

    /// A bookmark's number is an identifier, written as the old code wrote it: "Bookmark 12345", never grouped
    /// ("12,345", "12.345") by the region (finding 5 of the pilot's review). Every sentence that names one is checked,
    /// the iPhone's question included. A count, by contrast, stays grouped: that is the right English.
    func testABookmarksNumberIsNeverGrouped() {
        let bookmark = Bookmark(number: 12345, chapterIndex: 0, characterOffset: 0)
        XCTAssertEqual(bookmark.name, "Bookmark 12345")
        XCTAssertTrue(bookmark.accessibilityLabel(headingText: "The Battle").hasPrefix("Bookmark 12345, The Battle"))
        XCTAssertTrue(bookmark.accessibilityLabel(headingText: nil).hasPrefix("Bookmark 12345, added"))
        XCTAssertEqual(BookmarkPanelView.editTitle(number: 12345), "Edit Bookmark 12345")
        XCTAssertEqual(ReaderViewModel.bookmarkAddedAnnouncement(number: 12345), "Bookmark 12345 added")
        XCTAssertEqual(ReaderViewModel.bookmarkRemovedAnnouncement(number: 12345), "Bookmark 12345 removed")
        XCTAssertEqual(PhoneBookmarksWording.removeQuestion(number: 12345), "Remove Bookmark 12345?")
        for (button, english) in [(BookmarkCommand.goTo, "Go to bookmark 12345"),
                                  (.editNote, "Edit note for bookmark 12345"),
                                  (.delete, "Delete bookmark 12345")] {
            XCTAssertEqual(button.buttonLabel(forBookmarkNumber: 12345), english)
        }
    }

    /// The menus that hide by title (finding 1 of the pilot's review): the Bookmarks menu reads "Marcadores" in
    /// Spanish, so the reader's title set must hold it beside the English, or the menu stays over the Library. The
    /// English set is the four titles, unchanged, and the Library's set holds its own.
    @MainActor
    func testTheMenuVisibilitySetsHoldTheSpanishTitles() {
        let reader = MenuVisibilityManager.titles(for: MenuVisibilityManager.readerMenuWording, languages: ["es"])
        XCTAssertTrue(reader.contains("Marcadores"), "The reader's Spanish menu titles: \(reader.sorted())")
        // The English titles stay, since a menu with no translation shows its English.
        XCTAssertTrue(["Playback", "Navigate", "Bookmarks", "Book"].allSatisfy { reader.contains($0) })
        let library = MenuVisibilityManager.titles(for: MenuVisibilityManager.libraryMenuWording, languages: ["es"])
        XCTAssertTrue(library.contains("Library"), "The Library menu keeps its English title: \(library.sorted())")
        // With no other language the set is exactly the English titles.
        XCTAssertEqual(MenuVisibilityManager.titles(for: MenuVisibilityManager.readerMenuWording),
                       ["Playback", "Navigate", "Bookmarks", "Book"])
    }
}
