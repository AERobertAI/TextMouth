import XCTest

/// The pilot's areas in Spanish on the iPhone (FR35): the app started in Spanish (`-AppleLanguages (es)`, with
/// Spain's formats from `-AppleLocale es_ES`) shows and speaks the reader's Sleep Timer and Bookmarks sheets in the
/// String Catalog's Spanish. The reader's own controls and the sheets' titles belong to areas not converted yet, so
/// they stay English and the sheets are opened by their English names.
///
/// Each expected word is written here with the catalog key it comes from, so a failure names what VoiceOver was
/// given instead, in order: if the app came up in English, the order printed says so.
///
/// Nothing here makes sound: no timer is set (a preset starts the book) and nothing is typed, so these run anywhere,
/// though the iPhone tests run on GitHub's runners only.
@MainActor
final class SpanishUITests: TextMouthUITestCase {
    /// The launch arguments that start the app in Spanish, with Spain's formats.
    static let spanish = ["-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]

    /// The Sleep Timer sheet, with no timer running, in the catalog's Spanish: the New Timer heading, each preset's
    /// label, the custom minutes field's label, the stepper's label and its value with its unit, the custom Set
    /// button's label, and the Stop At heading and buttons.
    func testTheSleepTimerSheetIsInSpanish() throws {
        let app = try launchIntoTheReader(arguments: Self.spanish)
        // The reader's button, the sheet's title, and its Close button are the reader's words, still English.
        let elements = try openReaderSheet("Sleep Timer", titled: "Sleep Timer", waitingFor: "Close", in: app)
        keepScreenshot(of: app, named: "Sleep Timer sheet in Spanish")
        assertOrder([
            "Sleep Timer", "Close",
            "Nuevo temporizador",  // "New Timer"
            "Temporizador de 10 minutos",  // "Set timer for %lld minutes", other
            "Temporizador de 60 minutos",
            "Minutos personalizados",  // "Custom minutes"
            "Ajustar minutos",  // "Adjust minutes"
            "Temporizador de 30 minutos",  // the custom timer's Set, for its 30 minutes
            "Detener en",  // "Stop At"
            "Detener al final de este encabezado",  // "Stop at the end of this heading"
            "Detener al final del libro",  // "Stop at the end of the book"
        ], in: elements)
        // The stepper's value is the minutes with their unit, the plural "%lld minutes", other.
        let stepper = elements.first { $0.label == "Ajustar minutos" }
        XCTAssertEqual(stepper?.value, "30 minutos", "The stepper read: \(Self.describe(elements))")
        // The note under New Timer while no timer runs: "Pause playback after:".
        XCTAssertTrue(
            elements.contains { $0.label == "Pausar la reproducción después de:" },
            "No Spanish note under New Timer in: \(Self.describe(elements))"
        )
    }

    /// The Bookmarks sheet of a book with no bookmark, in the catalog's Spanish: Done, Add Bookmark, and the empty
    /// list's two sentences, the second naming Add Bookmark by its own Spanish title.
    func testTheBookmarksSheetIsInSpanish() throws {
        let app = try launchIntoTheReader(arguments: Self.spanish)
        // The reader's button and the sheet's title are the reader's words, still English; Done is the sheet's own.
        let elements = try openReaderSheet("Bookmarks", titled: "Bookmarks", waitingFor: "Hecho", in: app)
        keepScreenshot(of: app, named: "Bookmarks sheet in Spanish")
        assertOrder([
            "Bookmarks",
            "Hecho",  // "Done"
            "Agregar marcador",  // "Add Bookmark"
            "Aún no hay marcadores.…",  // "No bookmarks yet.", then the help, read as one element
        ], in: elements)
        // The help: "%@ adds one at the current position.", %@ being Add Bookmark's own title.
        XCTAssertTrue(
            elements.contains { $0.label.contains("Agregar marcador agrega uno en la posición actual.") },
            "No Spanish help under the empty list in: \(Self.describe(elements))"
        )
    }
}
