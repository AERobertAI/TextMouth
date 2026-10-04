import Foundation

// MARK: - A Stretch of Audio

/// A stretch of an audio file as an edit names it: from `start` to `end`
/// seconds on the audio as the edits before it left the file (FR04).
///
/// Seconds keep edits readable in edits.json and independent of the file's
/// sample rate; the timeline turns each time into a whole sample frame of
/// the audio being edited, so an edit lands on the same sample however
/// often the list is applied (`AudioEditTimeline`).
struct AudioTimeRange: Codable, Hashable, Sendable {
    /// Where the stretch begins, in seconds.
    var start: TimeInterval
    /// Where it ends, in seconds: the first moment after it.
    var end: TimeInterval

    init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    /// How long the stretch lasts, in seconds.
    var duration: TimeInterval { end - start }

    /// Whether the stretch can be edited at all: both ends finite, the start
    /// at or after the beginning, and the end after the start. Whether it
    /// fits inside the audio is the timeline's check, which knows the
    /// audio's length.
    var isWellFormed: Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start
    }
}

// MARK: - A Punch-In's Audio

/// The replacement audio of a punch-in: a take kept in the book's package
/// (`AudioEditPackage.takesFolder`) and the stretch of it that replaces the
/// edited range.
struct AudioEditTake: Codable, Hashable, Sendable {
    /// The take's path inside the package, such as
    /// "audioEdits/takes/6F1C….caf".
    var file: String
    /// The stretch of the take used, in seconds from the take's start: all
    /// of it unless the window trimmed the take's lead-in or tail.
    var range: AudioTimeRange
}

// MARK: - The Edit

/// One change to an audio file of a book (FR04): the unit the edit list
/// records, undoes, and redoes. Every time in an edit is a time on the audio
/// as the edits before it left it, so a list applies in order.
///
/// An edit is small and serializable, as edits.json stores it: the audio it
/// changes is never copied into it. A punch-in's replacement is a take kept
/// in the package, which the edit names; a filter is its chain in ffmpeg's
/// syntax, rendered again from the original whenever the list is applied.
enum AudioEdit: Hashable, Sendable {
    /// Removes everything before `to` seconds.
    case trimStart(to: TimeInterval)
    /// Removes everything from `at` seconds to the end.
    case trimEnd(at: TimeInterval)
    /// Removes the range; what follows it closes up.
    case cut(AudioTimeRange)
    /// Takes the range out and puts it back at `to` seconds, a time on the
    /// audio before the move, outside the range.
    case move(AudioTimeRange, to: TimeInterval)
    /// Inserts `duration` seconds of silence at `at` seconds.
    case insertSilence(at: TimeInterval, duration: TimeInterval)
    /// Replaces the range with a stretch of a take (punch-in). The take may
    /// be longer or shorter than the range it replaces.
    case replace(AudioTimeRange, with: AudioEditTake)
    /// Inserts a stretch of a take at `at` seconds, moving what follows on:
    /// a paste of audio copied or cut, or a recording inserted where nothing
    /// is selected.
    case insert(at: TimeInterval, with: AudioEditTake)
    /// Sets a chapter marker titled `title` at `at` seconds, or renames the
    /// marker already there.
    case setChapter(at: TimeInterval, title: String)
    /// Removes the chapter marker at `at` seconds.
    case removeChapter(at: TimeInterval)
    /// Runs the range, or the whole file when it is nil, through `chain`, a
    /// filter chain in ffmpeg's filtergraph syntax (`AudioFilterChain`).
    case filter(chain: String, range: AudioTimeRange?)
    /// Changes the level of the range, or of the whole file when it is nil,
    /// by `decibels`.
    case gain(decibels: Double, range: AudioTimeRange?)

    /// Whether the edit changes the sound itself rather than only the
    /// chapter markers laid over it.
    var changesAudio: Bool {
        switch self {
        case .setChapter, .removeChapter:
            return false
        case .trimStart, .trimEnd, .cut, .move, .insertSilence, .replace, .insert, .filter, .gain:
            return true
        }
    }

    /// The take a punch-in or an insertion uses, or nil for every other
    /// edit: what keeps a take in the package
    /// (`AudioEditHistoryStore.removeUnusedTakes`).
    var take: AudioEditTake? {
        switch self {
        case .replace(_, let take), .insert(_, let take):
            return take
        default:
            return nil
        }
    }
}

// MARK: - edits.json

/// An edit is written as one object naming its kind, with the fields that
/// kind uses, such as `{"kind": "cut", "start": 5, "end": 7}` or
/// `{"kind": "filter", "chain": "highpass=f=80", "start": 0, "end": 12.5}`.
/// A filter or gain over the whole file leaves out `start` and `end`.
extension AudioEdit: Codable {
    /// The kinds of edit, as edits.json names them.
    private enum Kind: String, Codable {
        case trimStart, trimEnd, cut, move, insertSilence, replace, insert, setChapter, removeChapter, filter, gain
    }

    /// The fields an edit can have.
    private enum CodingKeys: String, CodingKey {
        case kind, start, end, to, at, duration, take, title, chain, decibels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        /// The range the edit names by its `start` and `end` fields.
        func range() throws -> AudioTimeRange {
            AudioTimeRange(
                start: try container.decode(Double.self, forKey: .start),
                end: try container.decode(Double.self, forKey: .end)
            )
        }
        /// The range the edit names, or nil when it names none: the whole file.
        func optionalRange() throws -> AudioTimeRange? {
            container.contains(.start) || container.contains(.end) ? try range() : nil
        }
        switch try container.decode(Kind.self, forKey: .kind) {
        case .trimStart:
            self = .trimStart(to: try container.decode(Double.self, forKey: .to))
        case .trimEnd:
            self = .trimEnd(at: try container.decode(Double.self, forKey: .at))
        case .cut:
            self = .cut(try range())
        case .move:
            self = .move(try range(), to: try container.decode(Double.self, forKey: .to))
        case .insertSilence:
            self = .insertSilence(
                at: try container.decode(Double.self, forKey: .at),
                duration: try container.decode(Double.self, forKey: .duration)
            )
        case .replace:
            self = .replace(try range(), with: try container.decode(AudioEditTake.self, forKey: .take))
        case .insert:
            self = .insert(
                at: try container.decode(Double.self, forKey: .at),
                with: try container.decode(AudioEditTake.self, forKey: .take)
            )
        case .setChapter:
            self = .setChapter(
                at: try container.decode(Double.self, forKey: .at),
                title: try container.decode(String.self, forKey: .title)
            )
        case .removeChapter:
            self = .removeChapter(at: try container.decode(Double.self, forKey: .at))
        case .filter:
            self = .filter(chain: try container.decode(String.self, forKey: .chain), range: try optionalRange())
        case .gain:
            self = .gain(decibels: try container.decode(Double.self, forKey: .decibels), range: try optionalRange())
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        /// Writes `range`'s two ends, when there is a range.
        func encode(_ range: AudioTimeRange?) throws {
            guard let range else { return }
            try container.encode(range.start, forKey: .start)
            try container.encode(range.end, forKey: .end)
        }
        switch self {
        case .trimStart(let to):
            try container.encode(Kind.trimStart, forKey: .kind)
            try container.encode(to, forKey: .to)
        case .trimEnd(let at):
            try container.encode(Kind.trimEnd, forKey: .kind)
            try container.encode(at, forKey: .at)
        case .cut(let range):
            try container.encode(Kind.cut, forKey: .kind)
            try encode(range)
        case .move(let range, let to):
            try container.encode(Kind.move, forKey: .kind)
            try encode(range)
            try container.encode(to, forKey: .to)
        case .insertSilence(let at, let duration):
            try container.encode(Kind.insertSilence, forKey: .kind)
            try container.encode(at, forKey: .at)
            try container.encode(duration, forKey: .duration)
        case .replace(let range, let take):
            try container.encode(Kind.replace, forKey: .kind)
            try encode(range)
            try container.encode(take, forKey: .take)
        case .insert(let at, let take):
            try container.encode(Kind.insert, forKey: .kind)
            try container.encode(at, forKey: .at)
            try container.encode(take, forKey: .take)
        case .setChapter(let at, let title):
            try container.encode(Kind.setChapter, forKey: .kind)
            try container.encode(at, forKey: .at)
            try container.encode(title, forKey: .title)
        case .removeChapter(let at):
            try container.encode(Kind.removeChapter, forKey: .kind)
            try container.encode(at, forKey: .at)
        case .filter(let chain, let range):
            try container.encode(Kind.filter, forKey: .kind)
            try container.encode(chain, forKey: .chain)
            try encode(range)
        case .gain(let decibels, let range):
            try container.encode(Kind.gain, forKey: .kind)
            try container.encode(decibels, forKey: .decibels)
            try encode(range)
        }
    }
}
