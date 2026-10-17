import Foundation

// The operations a playback fuzz test applies to a reader, and the seeded
// generator that chooses them (TODO P09). Pure values, no reader and no
// run loop: a seed names one sequence on any Mac, so a failure printed with
// its seed is reproduced exactly (`PlaybackFuzzTests`).

// MARK: - The Generator

/// A bounded draw for the seeded generator `SplitMix64` (ImportFuzzMutator),
/// whose whole state is one 64-bit number, so a seed names a sequence on any
/// Mac.
extension SplitMix64 {
    /// A number in `0..<bound`, or 0 when `bound` is not positive. Drawn here,
    /// with a plain remainder, rather than by the standard library's
    /// `Int.random(in:using:)`, whose method of choosing may change between
    /// Swift releases and so change what a seed names. The remainder's tiny
    /// bias is of no matter to a fuzzer.
    mutating func below(_ bound: Int) -> Int {
        bound > 0 ? Int(next() % UInt64(bound)) : 0
    }
}

/// What the generator needs to know of a book to seek inside it: how many
/// UTF-16 units each chapter's text holds.
struct PlaybackBookShape: Equatable {
    /// The length of each chapter's text, in reading order.
    let chapterLengths: [Int]

    /// Three chapters of different lengths, for tests of the generator.
    static let sample = PlaybackBookShape(chapterLengths: [500, 40, 12_000])
}

// MARK: - The Operations

/// One thing a listener, the system, or time does to a reader.
enum PlaybackOperation: Equatable, CustomStringConvertible {
    case play
    case pause
    case toggle
    case stop
    case skipForward
    case skipBackward
    /// Jump to `offset` units into chapter `chapter`.
    case seek(chapter: Int, offset: Int)
    case nextHeading
    case previousHeading
    /// Choose the `choice`th installed voice (modulo how many there are).
    case changeVoice(choice: Int)
    case changeSpeed(faster: Bool)
    /// Let the main run loop run for `milliseconds`.
    case run(milliseconds: Int)
    /// The AirPods go back in their case: the default output changes.
    case routeLost
    /// The AirPods connect again.
    case routeBack
    /// A Pause from the AirPods or the media keys.
    case mediaPause
    /// A Play from the AirPods or the media keys.
    case mediaPlay
    /// Mark the pre-rendered speech stale, as an output-route change does.
    case invalidateRenders
    /// Start a sleep timer that will not expire during a test.
    case sleepTimerSet(minutes: Int)
    case sleepTimerCancel

    /// The kinds of operation, which a sequence is drawn from. A kind named
    /// more than once in a list is chosen more often.
    enum Kind: CaseIterable {
        case play, pause, toggle, stop, skipForward, skipBackward, seek
        case nextHeading, previousHeading, changeVoice, changeSpeed, run
        case routeLost, routeBack, mediaPause, mediaPlay, invalidateRenders
        case sleepTimerSet, sleepTimerCancel
    }

    /// Every kind once, with Play and the run loop twice more: a book that
    /// never plays shows little, and one that never has time to play shows
    /// less.
    static let defaultKinds: [Kind] = Kind.allCases + [.play, .play, .run, .run]

    /// An operation of `kind`, with its parameters drawn from `generator`.
    /// A seek lands inside `shape`: in a chapter that exists, at an offset
    /// before its end.
    static func make(
        _ kind: Kind,
        shape: PlaybackBookShape,
        using generator: inout SplitMix64
    ) -> PlaybackOperation {
        switch kind {
        case .play: return .play
        case .pause: return .pause
        case .toggle: return .toggle
        case .stop: return .stop
        case .skipForward: return .skipForward
        case .skipBackward: return .skipBackward
        case .seek:
            // A book with no chapters has nowhere to seek: chapter 0, offset 0.
            let chapter = shape.chapterLengths.isEmpty
                ? 0 : generator.below(shape.chapterLengths.count)
            let length = shape.chapterLengths.indices.contains(chapter) ? shape.chapterLengths[chapter] : 0
            return .seek(chapter: chapter, offset: generator.below(length))
        case .nextHeading: return .nextHeading
        case .previousHeading: return .previousHeading
        case .changeVoice: return .changeVoice(choice: generator.below(8))
        case .changeSpeed: return .changeSpeed(faster: generator.below(2) == 0)
        case .run:
            // 50 to 200 ms in steps of 50: long enough for a callback to
            // arrive, short enough to keep a sequence quick.
            return .run(milliseconds: 50 * (1 + generator.below(4)))
        case .routeLost: return .routeLost
        case .routeBack: return .routeBack
        case .mediaPause: return .mediaPause
        case .mediaPlay: return .mediaPlay
        case .invalidateRenders: return .invalidateRenders
        case .sleepTimerSet: return .sleepTimerSet(minutes: 30 * (1 + generator.below(3)))
        case .sleepTimerCancel: return .sleepTimerCancel
        }
    }

    /// The operations of the sequence `seed` names: `length` of them, each
    /// of a kind drawn from `kinds`. The same arguments give the same
    /// sequence on any Mac.
    static func sequence(
        seed: UInt64,
        length: Int,
        kinds: [Kind] = defaultKinds,
        shape: PlaybackBookShape = .sample
    ) -> [PlaybackOperation] {
        guard !kinds.isEmpty, length > 0 else { return [] }
        var generator = SplitMix64(seed: seed)
        return (0..<length).map { _ in
            // The kind is drawn first, so a kind's parameters never shift
            // the kinds that follow it.
            let kind = kinds[generator.below(kinds.count)]
            return make(kind, shape: shape, using: &generator)
        }
    }

    /// A sequence as a failure message prints it, so it can be read back and
    /// rerun: `seed=17 [play, run 0.1, seek ch1@120]`.
    static func describe(seed: UInt64, _ operations: [PlaybackOperation]) -> String {
        "seed=\(seed) [\(operations.map(\.description).joined(separator: ", "))]"
    }

    /// The operation as a short phrase, stable between releases.
    var description: String {
        switch self {
        case .play: return "play"
        case .pause: return "pause"
        case .toggle: return "toggle"
        case .stop: return "stop"
        case .skipForward: return "skip forward"
        case .skipBackward: return "skip back"
        case .seek(let chapter, let offset): return "seek ch\(chapter)@\(offset)"
        case .nextHeading: return "next heading"
        case .previousHeading: return "previous heading"
        case .changeVoice(let choice): return "voice \(choice)"
        case .changeSpeed(let faster): return faster ? "faster" : "slower"
        case .run(let milliseconds): return String(format: "run %.2f", Double(milliseconds) / 1_000)
        case .routeLost: return "route lost"
        case .routeBack: return "route back"
        case .mediaPause: return "media pause"
        case .mediaPlay: return "media play"
        case .invalidateRenders: return "invalidate renders"
        case .sleepTimerSet(let minutes): return "sleep \(minutes)"
        case .sleepTimerCancel: return "sleep cancel"
        }
    }
}
