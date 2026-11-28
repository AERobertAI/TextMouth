import XCTest

/// The pilot's areas in Spanish on the iPhone (FR35): the app started in Spanish (`-AppleLanguages (es)`, with
/// Spain's formats from `-AppleLocale es_ES`) shows and speaks the reader's Sleep Timer and Bookmarks sheets in the
/// String Catalog's Spanish. The reader's own controls and the sheets' titles are the iPhone's converted words
/// (FR34), so the sheets are opened by their Spanish names.
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

    /// Launches in Spanish into the reader, which is known by its Play button: "Reproducir" ("Play"), whose value
    /// reads "Cargando" ("Loading") until the book has loaded (Q17: waiting for the English "Play" timed out).
    func launchIntoTheSpanishReader() throws -> XCUIApplication {
        try launchIntoTheReader(arguments: Self.spanish, playLabel: "Reproducir", loadingValue: "Cargando")
    }

    /// The Sleep Timer, with no timer running, in the catalog's Spanish: reached through Book Actions, then in the
    /// sheet the New Timer heading, each preset's label, the custom minutes field's label, the stepper's label, the
    /// custom Set button's label, and the Stop At heading and buttons.
    func testTheSleepTimerSheetIsInSpanish() throws {
        let app = try launchIntoTheSpanishReader()
        // The Book Actions menu's item and the sheet's title are both "Sleep Timer" in Spanish, and Close is the
        // Mac's own localized word since the pilot's review (finding 4), so the sheet is not half English. The
        // menu itself is "Book Actions" (FR51).
        let elements = try openReaderSheet(
            "Temporizador de apagado", titled: "Temporizador de apagado", waitingFor: "Cerrar",
            under: "Acciones del libro", in: app
        )
        keepScreenshot(of: app, named: "Sleep Timer sheet in Spanish")
        assertOrder([
            "Temporizador de apagado", "Cerrar",  // "Sleep Timer", "Close"
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
        // SwiftUI's stepper is read on the iPhone as its label and two buttons, "Ajustar minutos, Disminución" and
        // "Ajustar minutos, Aumento" (iOS's own words, in Spanish too), none of which carries its value (train
        // 1118-1540), so its label is checked in the order above and its value is not read here.
        // The note under New Timer while no timer runs: "Pause playback after:".
        XCTAssertTrue(
            elements.contains { $0.label == "Pausar la reproducción después de:" },
            "No Spanish note under New Timer in: \(Self.describe(elements))"
        )
    }

    /// The Bookmarks sheet of a book with no bookmark, in the catalog's Spanish: Done, Add Bookmark, and the empty
    /// list's two sentences, the second naming Add Bookmark by its own Spanish title.
    func testTheBookmarksSheetIsInSpanish() throws {
        let app = try launchIntoTheSpanishReader()
        // The reader's button and the sheet's title are both "Bookmarks" in Spanish; Done is the sheet's own.
        let elements = try openReaderSheet("Marcadores", titled: "Marcadores", waitingFor: "OK", in: app)
        keepScreenshot(of: app, named: "Bookmarks sheet in Spanish")
        assertOrder([
            "Marcadores",  // "Bookmarks"
            "OK",  // "Done" (the review: Apple's Spanish shows OK; a native speaker decides)
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
