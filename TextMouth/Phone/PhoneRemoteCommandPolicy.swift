import Foundation

/// Which of the system's media commands the iPhone offers, and what the lock
/// screen is told of them (the iPhone interface spec, "The lock screen, Control
/// Center, and AirPods").
///
/// The Mac enables Skip Forward and Skip Backward with fixed intervals of 30 and
/// 15 seconds, whatever the navigation unit, and a press moves by the unit. On
/// the lock screen a system button would then promise 15 seconds and move a
/// heading, so here those two exist only when the unit is a number of seconds,
/// with that number. Next and Previous Track, which the AirPods' double and
/// triple press are reported to send, skip by the unit always, as on the Mac.
///
/// A plain value, so that every answer is tested on the Mac.
struct PhoneRemoteCommandPolicy: Equatable, Sendable {
    /// Every command in `MPRemoteCommandCenter` (`MPRemoteCommandCenter.h`), so
    /// that none can be left enabled by being left out.
    enum Command: CaseIterable, Sendable {
        case play, pause, togglePlayPause
        case nextTrack, previousTrack
        case skipForward, skipBackward
        case changePlaybackPosition
        case stop, seekForward, seekBackward
        case changePlaybackRate, changeRepeatMode, changeShuffleMode
        case rating, like, dislike, bookmark
        case enableLanguageOption, disableLanguageOption
    }

    /// The seconds Skip Forward moves by, or nil when it is disabled.
    let skipForwardSeconds: Double?
    /// The seconds Skip Backward moves by, or nil when it is disabled.
    let skipBackwardSeconds: Double?

    /// The commands of a book whose units are `forward` and `backward`, which
    /// differ only when Settings keeps two units.
    init(forward: SkipUnit, backward: SkipUnit) {
        skipForwardSeconds = forward.seconds.map(Double.init)
        skipBackwardSeconds = backward.seconds.map(Double.init)
    }

    /// The commands of a book that moves by `unit` both ways.
    init(unit: SkipUnit) {
        self.init(forward: unit, backward: unit)
    }

    /// The commands before any book is open: targets are installed at launch,
    /// so that a Play can wake the app, and no unit promises anything yet.
    static let noBook = PhoneRemoteCommandPolicy(forward: .sentence, backward: .sentence)

    /// Whether `command` is enabled. `changePlaybackPosition` is optional in
    /// the spec's first version and left out of it: the lock screen's scrubber
    /// for an audiobook waits for a first run, which can show how VoiceOver
    /// reads it.
    func isEnabled(_ command: Command) -> Bool {
        switch command {
        case .play, .pause, .togglePlayPause, .nextTrack, .previousTrack:
            return true
        case .skipForward:
            return skipForwardSeconds != nil
        case .skipBackward:
            return skipBackwardSeconds != nil
        case .changePlaybackPosition, .stop, .seekForward, .seekBackward,
             .changePlaybackRate, .changeRepeatMode, .changeShuffleMode,
             .rating, .like, .dislike, .bookmark,
             .enableLanguageOption, .disableLanguageOption:
            return false
        }
    }

    /// The intervals the lock screen is told for `command`: the unit's seconds
    /// for an enabled skip command, and none for anything else.
    func preferredIntervals(for command: Command) -> [Double] {
        switch command {
        case .skipForward:
            return skipForwardSeconds.map { [$0] } ?? []
        case .skipBackward:
            return skipBackwardSeconds.map { [$0] } ?? []
        default:
            return []
        }
    }

    /// What a command does when no reader is open.
    enum NoReaderOutcome: Equatable, Sendable {
        /// The app opens the book last open, and plays it.
        case opensLastBook
        /// MediaPlayer is told there is nothing to act on.
        case noActionableItem
    }

    /// What `request` does with no reader open (the engineer's review, F9). A
    /// Play, or a press of the AirPods, which is a Toggle and can mean only Play
    /// with nothing playing, opens the last book when the app has a way to;
    /// anything else has no book to act on.
    static func noReaderOutcome(
        for request: RemoteMediaCommandRequest,
        canOpenLastBook: Bool
    ) -> NoReaderOutcome {
        switch request {
        case .play, .togglePlayPause:
            return canOpenLastBook ? .opensLastBook : .noActionableItem
        case .pause, .skipForward, .skipBackward, .nextTrack, .previousTrack:
            return .noActionableItem
        }
    }
}
