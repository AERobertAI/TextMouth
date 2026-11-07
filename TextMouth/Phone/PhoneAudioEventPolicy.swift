import Foundation

/// Why the audio route changed, in the audio session's own terms
/// (`AVAudioSession.RouteChangeReason`, `AVAudioSessionTypes.h:375-404`),
/// named here so that the policy, which uses no iOS-only API, is tested on the
/// Mac.
enum PhoneAudioRouteChangeReason: Equatable, Sendable, CaseIterable {
    /// The system gave no reason.
    case unknown
    /// A new output arrived, as when headphones are plugged in.
    case newDeviceAvailable
    /// The output in use went away, as when AirPods leave.
    case oldDeviceUnavailable
    /// The category changed, as `PhoneAudioSession.configure()` changes it.
    case categoryChange
    /// The route was overridden.
    case override
    /// The device woke from sleep.
    case wakeFromSleep
    /// No route suits the category.
    case noSuitableRouteForCategory
    /// The same ports, configured another way.
    case routeConfigurationChange
}

/// Something the system did to the iPhone's audio.
enum PhoneAudioEvent: Equatable, Sendable {
    /// An interruption began, and the system took the audio session away. The
    /// header's `routeDisconnected` reason (iOS 17, `AVAudioSessionTypes.h:602`)
    /// is one output's going, which arrives with a route change, in an order
    /// nothing states.
    case interruptionBegan(becauseRouteDisconnected: Bool)
    /// An interruption ended, with the system's word on whether to play on.
    case interruptionEnded(shouldResume: Bool)
    /// The audio route changed.
    case routeChanged(PhoneAudioRouteChangeReason)
    /// The speech engine stopped itself over a change of hardware format
    /// (`AVAudioEngineConfigurationChangeNotification`).
    case engineConfigurationChanged
    /// The system's media services restarted, and every audio object the app
    /// held is dead (Apple's QA1749).
    case mediaServicesReset
}

/// What the app does about an event.
enum PhoneAudioResponse: Equatable, Sendable {
    /// Nothing.
    case nothing
    /// The book counts as paused where it stopped, and the place is saved.
    case pauseAndSave
    /// The interruption that paused the book is over: it plays on.
    case resume
    /// The book's output went away as it played: it pauses through the Mac's
    /// own `pauseForAudioRouteChange()`, so that the Mac's rewind on resume
    /// applies, and the next Play starts cold.
    case pauseForLostRoute
    /// The output went away while the book was not playing: nothing to pause,
    /// but the next Play starts cold, on the output that's left.
    case noteLostRoute
    /// The next Play starts cold, on the output there is by then. Nothing
    /// changes now.
    case invalidateBackend
    /// A natural break: nothing is being heard, so the speech engine plays on
    /// from the place, with no chapter ended and no word lost.
    case restartFromPlace
    /// Everything that makes sound is made anew: the category is set again,
    /// the reader closes, and the same book opens again, paused at its place,
    /// since a reader's `close()` and `init` already let go of every audio
    /// object and make it afresh (the engineer's review, F26). Apple: "Don't
    /// restart playback, recording, or processing until the user initiates it."
    case rebuildAudioObjects
}

/// Decides, for each thing the system does to the iPhone's audio and for
/// whether the book counts as playing, what happens (the iPhone interface
/// spec, "What pauses and what resumes").
///
/// It keeps what a later event needs to know, and nothing more, so that each
/// answer can be tested on the Mac with no audio session. Every answer is
/// idempotent, since one disconnect gives both an interruption and a route
/// change, in an order `AVAudioSession.h:492-494` doesn't state: whichever comes
/// first pauses the book, the other finds it paused, and neither of them lets
/// the interruption's end play it on through the speaker.
struct PhoneAudioEventPolicy: Equatable, Sendable {
    /// How long, in seconds, the speech engine waits after a configuration
    /// change before it plays on. The change and the route change that caused
    /// it arrive in no stated order, and when the route change says the
    /// AirPods have gone, playing on would speak aloud through the speaker
    /// until it arrived. Nothing is heard meanwhile. A guess until a first
    /// run logs the order.
    static let engineRestartDelay: TimeInterval = 0.25

    /// Whether the book was playing when the interruption under way began, so
    /// that the interruption itself paused it, and no end, route loss, reset,
    /// activation, or Pause from the listener has since said it shouldn't play
    /// on. A book the listener had paused before a call never starts by itself
    /// as the call ends (the engineer's review, F24).
    private(set) var wasPlayingWhenInterrupted = false

    /// Whether the system has taken the audio away and not given it back:
    /// from an interruption's beginning or a media reset until the
    /// interruption's end, or until an activation succeeds, since "there is no
    /// guarantee that a begin interruption will have a corresponding end"
    /// (Apple's guide). While this holds, a speech synthesizer's cancel that
    /// the app didn't ask for is the interruption's doing, and no refusal of
    /// the text.
    private(set) var isInterrupted = false

    /// What happens on `event`.
    ///
    /// - Parameters:
    ///   - event: What the system did.
    ///   - bookCountsAsPlaying: Whether the book is playing, or about to,
    ///     as the reader counts it for the system's media commands.
    mutating func respond(to event: PhoneAudioEvent, bookCountsAsPlaying: Bool) -> PhoneAudioResponse {
        switch event {
        case .interruptionBegan(let becauseRouteDisconnected):
            isInterrupted = true
            if becauseRouteDisconnected {
                return respondToLostRoute(bookCountsAsPlaying: bookCountsAsPlaying)
            }
            guard bookCountsAsPlaying else { return .nothing }
            wasPlayingWhenInterrupted = true
            return .pauseAndSave

        case .interruptionEnded(let shouldResume):
            isInterrupted = false
            let plays = shouldResume && wasPlayingWhenInterrupted && !bookCountsAsPlaying
            wasPlayingWhenInterrupted = false
            return plays ? .resume : .nothing

        case .routeChanged(let reason):
            switch reason {
            case .oldDeviceUnavailable, .noSuitableRouteForCategory:
                // With no route for the category, nothing can be heard either.
                return respondToLostRoute(bookCountsAsPlaying: bookCountsAsPlaying)
            case .newDeviceAvailable, .wakeFromSleep, .routeConfigurationChange:
                return .invalidateBackend
            case .override, .categoryChange, .unknown:
                // Apple: media apps "should not" pause for an override. A
                // category change is this app's own, at launch and after a
                // media reset.
                return .nothing
            }

        case .engineConfigurationChanged:
            return bookCountsAsPlaying ? .restartFromPlace : .invalidateBackend

        case .mediaServicesReset:
            isInterrupted = true
            wasPlayingWhenInterrupted = false
            return .rebuildAudioObjects
        }
    }

    /// The listener paused during an interruption, as Siri's remote commands
    /// can: Apple's guide says to keep track of those, and the book then waits
    /// for Play when the interruption ends.
    mutating func listenerPaused() {
        wasPlayingWhenInterrupted = false
    }

    /// The session became active, so the audio is the app's again, whether or
    /// not the end of an interruption was ever told. A late end changes nothing.
    mutating func activationSucceeded() {
        isInterrupted = false
        wasPlayingWhenInterrupted = false
    }

    /// The output went away: the interruption that came with it, or came
    /// before it, can no longer play the book on, since that would be through
    /// the speaker. Apple's guide says to pause here, and only Play starts
    /// the book.
    private mutating func respondToLostRoute(bookCountsAsPlaying: Bool) -> PhoneAudioResponse {
        wasPlayingWhenInterrupted = false
        return bookCountsAsPlaying ? .pauseForLostRoute : .noteLostRoute
    }
}
