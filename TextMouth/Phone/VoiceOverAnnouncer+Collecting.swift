import Foundation

extension VoiceOverAnnouncer {
    /// Runs `body`, and returns every announcement it made instead of posting
    /// them, oldest first: the phone sorts what a move said
    /// (`PhoneMoveFeedback`) before anything is heard, since a move's own words
    /// would talk over the book.
    ///
    /// Only what `body` announces as it runs is collected: the poster is
    /// swapped around that one synchronous call and put back in a `defer`,
    /// thrown errors included. Words announced later, such as those waiting for
    /// a sheet to close or a timer's end, are posted as ever. `announce` itself
    /// does not change, so neither does the Mac.
    @discardableResult
    static func collectingAnnouncements(during body: () throws -> Void) rethrows -> [VoiceOverAnnouncement] {
        var collected: [VoiceOverAnnouncement] = []
        let previous = poster
        poster = { announcement, _ in collected.append(announcement) }
        defer { poster = previous }
        try body()
        return collected
    }
}
