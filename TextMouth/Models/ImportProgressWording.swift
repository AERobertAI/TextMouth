import Foundation

/// The words of the imports under way (FR10), kept in one place so the
/// Library window's import overlay, VoiceOver, and the tests say the same
/// thing.
enum ImportProgressWording {
    /// The import overlay's title, which VoiceOver reads first.
    static let title = "Importing Books"
    /// What the overlay's count counts, after the books done of the total:
    /// "3 of 10 books processed". A book skipped as a duplicate, or one
    /// that failed, is processed too.
    static let itemNoun = "books processed"
    /// What the overlay says as a ZIP import starts, before its archive is
    /// opened.
    static let startingArchive = "Extracting archive..."

    // MARK: - The Overlay's Lines

    /// The books done of the total, as the overlay's count says it:
    /// "3 of 10 books processed".
    static func count(done: Int, of total: Int) -> String {
        CountWording.progress(done, of: total, itemNoun)
    }

    /// How far the extraction of the archive named `archive`, the archive
    /// imported or one found inside it, has got: "Extracting “Library
    /// Export.zip”: 37 of 120 items...".
    static func extracting(archive: String, done: Int, total: Int) -> String {
        "Extracting “\(archive)”: \(done) of \(total) items..."
    }

    /// The book a ZIP batch is importing and the step it is at: "Book 3 of
    /// 100: “Moby Dick.epub”, reading its text". `name` is the book's file,
    /// or a DAISY book's folder, as the archive names it.
    static func book(_ name: String, number: Int, of total: Int, step: ImportStep) -> String {
        "Book \(number) of \(total): “\(name)”, \(self.step(step))"
    }

    /// `step` as the phrase that follows a book's name: the words a failure
    /// names the step by (`ImportStep.activity`), begun in lowercase, as in
    /// "reading its text" or "copying it into the library".
    static func step(_ step: ImportStep) -> String {
        let activity = step.activity
        return activity.prefix(1).lowercased() + activity.dropFirst()
    }

    // MARK: - What VoiceOver Reads

    /// What VoiceOver reads for the overlay: the title, then each line it
    /// shows, as sentences: "Importing Books: 2 of 100 books processed. Book
    /// 3 of 100: “Moby Dick.epub”, reading its text." Empty lines are left
    /// out, and with none the title is read alone.
    static func spokenStatus(_ lines: [String]) -> String {
        let shown = lines.filter { !$0.isEmpty }
        guard !shown.isEmpty else { return title }
        return "\(title): " + shown.map(sentence).joined(separator: " ")
    }

    /// `line` ending as a sentence: with a period, unless it already ends
    /// in one, or in the ellipsis of a line still under way.
    private static func sentence(_ line: String) -> String {
        line.hasSuffix(".") ? line : line + "."
    }
}
