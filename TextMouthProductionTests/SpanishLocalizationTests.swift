import XCTest
@testable import TextMouth

/// The Spanish of the pilot's areas (FR35) as the built Mac app carries it: the sleep timer, bookmarks, and the
/// Reading List are in the app's `es.lproj`, plural forms included, and a string resource asked for in Spanish reads
/// its Spanish from there.
///
/// The suite runs in English, so this reads Spanish the two ways that work inside the test host (the localization
/// research of November 18, 2026): the compiled files of `es.lproj` in the app bundle, and a
/// `LocalizedStringResource` whose `locale` is Spanish. `String(localized:locale:)` is not used: its locale only
/// formats numbers, and it reads the English.
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
        // Key (the English, as the catalog holds it) and its Spanish; the comment names where it comes from.
        let expected: [(key: String, spanish: String)] = [
            ("Sleep Timer", "Temporizador de apagado"),  // SleepTimerView.title
            ("Returns to the book.", "Vuelve al libro."),  // SleepTimerView.closeHint
            ("Stop at the end of this heading", "Detener al final de este encabezado"),  // SleepTimerView.endOfHeadingLabel
            ("Sleep timer expired. Playback paused.",
             "El temporizador de apagado terminó. Reproducción en pausa."),  // ReaderViewModel.sleepTimerExpiredAnnouncement
            ("Bookmarks", "Marcadores"),  // BookmarkPanelView.title
            ("Bookmark %lld", "Marcador %lld"),  // Bookmark.name
            ("Goes to this bookmark and closes the list.", "Va a este marcador y cierra la lista."),  // BookmarkRow.hint
            ("Reading List Order", "Orden de la lista de lectura"),  // ReadingListWording.orderName
            ("Reading list, book %lld of %lld", "Lista de lectura, libro %1$lld de %2$lld"),  // ReadingListReaderWording.place
            ("No next book in the reading list.",
             "No hay un libro siguiente en la lista de lectura."),  // ReadingListReaderWording.noNeighbor
        ]
        var wrong: [String] = []
        for (key, spanish) in expected where strings[key] as? String != spanish {
            wrong.append("\(key): \(strings[key].map { "\($0)" } ?? "missing"), not \(spanish)")
        }
        XCTAssertTrue(wrong.isEmpty, "es.lproj/Localizable.strings:\n" + wrong.joined(separator: "\n"))
        let empty = strings.filter { ($0.value as? String)?.isEmpty ?? true }.map(\.key)
        XCTAssertTrue(empty.isEmpty, "Empty Spanish text ships for: \(empty)")

        let plurals = try spanishTable("stringsdict")
        for key in ["%lld minutes", "Set timer for %lld minutes", "Add %lld Books to Reading List", "%lld books were already in it."] {
            let entry = plurals[key] as? [String: Any]
            let forms = entry?.values.compactMap { $0 as? [String: Any] }.first
            XCTAssertEqual(
                Set(["one", "many", "other"]).subtracting(forms?.keys.map { $0 } ?? []), [],
                "\(key) lacks Spanish plural forms in es.lproj/Localizable.stringsdict: \(String(describing: entry))"
            )
        }
    }

    /// A string resource asked for in Spanish reads the catalog's Spanish: a plain text, a placeholder, and a plural
    /// in both its categories; asked for in English, the plural reads its English forms, which the catalog ships too.
    func testAResourceInSpanishReadsItsSpanish() {
        let spanish = Locale(identifier: "es")
        let english = Locale(identifier: "en")
        // Each key is one the app's own code uses (SleepTimerView.title, Bookmark.name, SleepTimerDuration.displayName).
        XCTAssertEqual(String(localized: LocalizedStringResource("Sleep Timer", locale: spanish)), "Temporizador de apagado")
        XCTAssertEqual(String(localized: LocalizedStringResource("Bookmark \(3)", locale: spanish)), "Marcador 3")
        XCTAssertEqual(String(localized: LocalizedStringResource("\(1) minutes", locale: spanish)), "1 minuto")
        XCTAssertEqual(String(localized: LocalizedStringResource("\(30) minutes", locale: spanish)), "30 minutos")
        XCTAssertEqual(String(localized: LocalizedStringResource("\(1) minutes", locale: english)), "1 minute")
        XCTAssertEqual(String(localized: LocalizedStringResource("\(30) minutes", locale: english)), "30 minutes")
    }
}
