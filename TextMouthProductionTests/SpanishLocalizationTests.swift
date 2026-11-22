import XCTest
@testable import TextMouth

/// The Spanish of the pilot's areas (FR35) as the built Mac app carries it: the sleep timer, bookmarks, and the
/// Reading List are in the app's `es.lproj`, plural forms included, and a line asked for in Spanish reads its Spanish.
///
/// The suite runs in English, so this reads Spanish the two ways that work inside the test host: the compiled files of
/// `es.lproj` in the app bundle, whose keys are the lines' IDs since the catalog is keyed by ID (FR39 phase 7), and
/// TextMouth's own engine, `InterfaceText.line(_:_:language:)`, which reads the pack with the language it is given.
final class SpanishLocalizationTests: XCTestCase {
    /// The app the tests run in, whose bundle carries the compiled catalog.
    private var app: Bundle { Bundle.main }

    /// The app's Spanish table of `kind` ("strings" or "stringsdict") as a dictionary, or a failure that names the
    /// bundle and the localizations it has.
    private func spanishTable(_ kind: String) throws -> [String: Any] {
        let url = try XCTUnwrap(
            app.url(forResource: "Localizable", withExtension: kind, subdirectory: nil, localization: "es"),
            "No es.lproj/Localizable.\(kind) in \(app.bundlePath); its localizations: \(app.localizations)"
        )
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any], "\(url.path) is not a property list")
    }

    /// The app carries Spanish beside English, its development language.
    func testTheAppCarriesSpanish() {
        XCTAssertTrue(app.localizations.contains("es"), "The app's localizations: \(app.localizations)")
        XCTAssertEqual(app.developmentLocalization, "en")
    }

    /// `es.lproj` holds each area's strings with their Spanish: a heading, a label, a hint, and an announcement of
    /// each, every plural string in the `.stringsdict` with its three Spanish categories, and no empty text.
    func testSpanishHoldsTheAreasStrings() throws {
        let strings = try spanishTable("strings")
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
        for (id, spanish) in expected where strings[id] as? String != spanish {
            wrong.append("\(id): \(strings[id].map { "\($0)" } ?? "missing"), not \(spanish)")
        }
        XCTAssertTrue(wrong.isEmpty, "es.lproj/Localizable.strings:\n" + wrong.joined(separator: "\n"))
        let empty = strings.filter { ($0.value as? String)?.isEmpty ?? true }.map(\.key)
        XCTAssertTrue(empty.isEmpty, "Empty Spanish text ships for: \(empty)")

        // The tables are keyed by ID: every key is an ID (two to four lower camel case segments), never English text, so a
        // fragment of an English sentence has no entry of its own (finding 3 of the review: "Downloading the next
        // episodio: ..." read half Spanish).
        let notIDs = strings.keys.filter { $0.range(of: "^[a-z][A-Za-z0-9]*(\\.[a-z][A-Za-z0-9]*){1,3}$", options: .regularExpression) == nil }
        XCTAssertTrue(notIDs.isEmpty, "es.lproj holds keys that are not IDs: \(notIDs.sorted().prefix(10))")
        // The Spanish never says este Mac, which is Spain's: this Spanish is Latin American (esta Mac).
        XCTAssertTrue(strings.values.compactMap { $0 as? String }.filter { $0.contains("este Mac") }.isEmpty)

        let plurals = try spanishTable("stringsdict")
        for id in ["common.countMinutes", "sleepTimerView.setTimerLabel", "readingList.addTitle", "readingList.addedAnnouncement.already"] {
            let entry = plurals[id] as? [String: Any]
            let forms = entry?.values.compactMap { $0 as? [String: Any] }.first
            XCTAssertEqual(
                Set(["one", "many", "other"]).subtracting(forms?.keys.map { $0 } ?? []), [],
                "\(id) lacks Spanish plural forms in es.lproj/Localizable.stringsdict: \(String(describing: entry))"
            )
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
