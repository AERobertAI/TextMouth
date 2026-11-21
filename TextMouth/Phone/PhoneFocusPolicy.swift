import Foundation

/// Where VoiceOver's focus goes as the reader's screen arrives: Play, without
/// ever pulling focus from under a listener who has moved.
///
/// VoiceOver reports its own landings and the listener's alike, so the policy
/// goes by where focus lands (the engineering review's F17, with the user's
/// review, finding 11):
/// - At 0.35 seconds after arrival, it posts `.screenChanged` with Play.
/// - Once focus has been on Play, even once, it stops for good: any later move
///   is the listener's.
/// - A landing on any of the reader's controls but Play is the listener's, and
///   stops it for good.
/// - A landing elsewhere, the system's Back button or the title, where
///   VoiceOver wanders by itself, stops nothing. If by 1.2 seconds focus has
///   reached neither Play nor another control, it posts `.layoutChanged` with
///   Play, once.
/// - At 3 seconds it stops, whatever happened.
///
/// A plain value with the time handed in, so a test drives it with numbers.
struct PhoneFocusPolicy: Equatable, Sendable {
    /// What the screen posts, both with Play as the element.
    enum Action: Equatable, Sendable {
        /// `UIAccessibility.Notification.screenChanged`, with its sound.
        case postScreenChanged
        /// `UIAccessibility.Notification.layoutChanged`, quieter.
        case postLayoutChanged
    }

    /// When the first post is due, in seconds after arrival.
    static let screenChangedDelay: TimeInterval = 0.35
    /// When the second post is due, if focus has reached no control.
    static let layoutChangedDelay: TimeInterval = 1.2
    /// When the policy stops, whatever happened.
    static let stopAfter: TimeInterval = 3

    /// When the screen arrived, by the caller's clock.
    let arrival: TimeInterval
    /// Whether the policy has stopped for good.
    private(set) var isFinished = false
    /// Whether `.screenChanged` was posted.
    private var postedScreenChanged = false
    /// Whether `.layoutChanged` was posted.
    private var postedLayoutChanged = false

    /// A policy for a screen that arrived at `arrival`.
    init(arrivedAt arrival: TimeInterval) {
        self.arrival = arrival
    }

    /// VoiceOver's focus landed on `control`, or, given nil, somewhere that is
    /// not one of the reader's controls.
    mutating func focusLanded(on control: PhoneControlKind?) {
        if control != nil {
            isFinished = true
        }
    }

    /// What to post at `time`, by the caller's clock: at most one action a
    /// call, and nothing once the policy has stopped.
    mutating func action(at time: TimeInterval) -> Action? {
        guard !isFinished else { return nil }
        let elapsed = time - arrival
        if elapsed >= Self.stopAfter {
            isFinished = true
            return nil
        }
        if !postedScreenChanged {
            guard elapsed >= Self.screenChangedDelay else { return nil }
            postedScreenChanged = true
            return .postScreenChanged
        }
        if !postedLayoutChanged, elapsed >= Self.layoutChangedDelay {
            postedLayoutChanged = true
            return .postLayoutChanged
        }
        return nil
    }

    /// When to call `action(at:)` next, by the caller's clock, or nil once the
    /// policy has stopped.
    var nextCheck: TimeInterval? {
        guard !isFinished else { return nil }
        if !postedScreenChanged { return arrival + Self.screenChangedDelay }
        if !postedLayoutChanged { return arrival + Self.layoutChangedDelay }
        return arrival + Self.stopAfter
    }
}
