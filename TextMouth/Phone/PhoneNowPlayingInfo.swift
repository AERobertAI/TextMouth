import Foundation
import MediaPlayer

/// What the reader adds to a book's title and author for the lock screen: how
/// fast it plays, and an audiobook chapter's clock.
///
/// The heading being read, which the spec gives the album's place, is left out
/// of the first version (the engineer's review, F31): the system hears of the
/// book only at a play, a pause, or a move, so a heading shown there would go
/// stale as the book read on.
struct PhoneNowPlayingDetails: Equatable, Sendable {
    /// An audiobook chapter's clock, in seconds. Speech has none at first, since
    /// any figure would be an estimate (the iPhone interface spec).
    struct ChapterTime: Equatable, Sendable {
        /// How far into the chapter the book is.
        let elapsed: TimeInterval
        /// How long the chapter is.
        let duration: TimeInterval
    }

    /// The speed in use as a multiplier: an audiobook's, or 1 for speech, whose
    /// words per minute are no multiplier of anything.
    let speed: Double
    /// An audiobook chapter's clock, or nil.
    let chapterTime: ChapterTime?

    /// Before a reader has said anything, and for speech.
    static let none = PhoneNowPlayingDetails(speed: 1, chapterTime: nil)
}

/// The words and numbers the lock screen, Control Center, and AirPods show for
/// a book, from plain inputs (the iPhone interface spec, "The lock screen,
/// Control Center, and AirPods").
///
/// Apple: "You don't have direct control over what information the system
/// displays." These are the app's choice of words; the layout is the system's.
struct PhoneNowPlayingInfo: Equatable, Sendable {
    /// The book's title.
    let title: String
    /// The book's author, or nil with none to say.
    let artist: String?
    /// The speed in use, or 0 when paused. A paused item has rate 0
    /// (`MPNowPlayingInfoCenter.h:88-101`), and on iOS the lock screen takes its
    /// play or pause state from this and from the session, not from
    /// `playbackState`, which the header says "only applies on macOS".
    let rate: Double
    /// The speed in use, playing or paused: if 1.5 is the listener's normal
    /// speed, the header says the default rate is 1.5 too.
    let defaultRate: Double
    /// How far into the chapter the book is, within its duration; nil for
    /// speech. The system extrapolates it from the rate
    /// (`MPNowPlayingInfoCenter.h:83-86`).
    let elapsedTime: TimeInterval?
    /// The chapter's length; nil for speech, and for a chapter with no length.
    let duration: TimeInterval?

    /// What the lock screen shows for a book.
    ///
    /// - Parameters:
    ///   - title: The book's title.
    ///   - author: The book's author.
    ///   - isPlaying: Whether the book plays; false while it's paused.
    ///   - details: What the reader adds.
    init(title: String, author: String, isPlaying: Bool, details: PhoneNowPlayingDetails) {
        self.title = title
        artist = author.isEmpty ? nil : author

        // A speed that isn't a positive number can't be shown as one: the
        // system would take 0 for paused.
        let speed = details.speed.isFinite && details.speed > 0 ? details.speed : 1
        rate = isPlaying ? speed : 0
        defaultRate = speed

        if let time = details.chapterTime, time.duration.isFinite, time.duration > 0 {
            duration = time.duration
            let elapsed = time.elapsed.isFinite ? time.elapsed : 0
            elapsedTime = min(max(0, elapsed), time.duration)
        } else {
            duration = nil
            elapsedTime = nil
        }
    }

    /// This, in the keys of `MPNowPlayingInfoCenter.nowPlayingInfo`
    /// (`MPMediaItem.h`, `MPNowPlayingInfoCenter.h`).
    var systemDictionary: [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: defaultRate,
        ]
        if let artist { info[MPMediaItemPropertyArtist] = artist }
        if let elapsedTime { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime }
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        return info
    }
}
