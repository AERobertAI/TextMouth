import Foundation

/// The edited audio of one file, laid out in time (FR04): stretches of
/// sound, one after another, each taken from a source, and the chapter
/// markers over them. It is what applying an edit list to the audio the
/// edits start from gives, and what a preview plays and a render writes
/// (`AudioEditComposition`).
///
/// Every position is a whole sample frame at the timeline's rate, the rate
/// of the audio the edits start from, so applying a list lands every edit on
/// the same sample however often it is done. An edit's times, in seconds,
/// are turned into frames by rounding to the nearest one (`frame(at:)`).
///
/// The edits that only rearrange sound (trims, cuts, moves, silence,
/// punch-ins, chapter markers) are applied here, as pure changes to the
/// value. A filter or a gain change needs its stretch rendered through the
/// chain first, which a processor does (`AudioEditProcessing`); the
/// processed sound becomes a stretch of its own.
///
/// Chapter markers follow the sound:
///
/// - A marker before an edited range stays where it is; one after it moves
///   by the change in length.
/// - A marker at the start of a range that is replaced, processed, or where
///   sound is inserted stays at that start, so the new sound belongs to its
///   chapter. A move is the exception when the moved sound brings a marker
///   of its own at its start: that marker takes the place, and the one there
///   follows its own sound.
/// - Markers inside a removed range move to where it was, the last of them
///   winning, since the sound there now is what followed that marker; inside
///   a processed or replaced range they move to the same proportion of the
///   new sound; inside a moved range they move with it.
/// - A marker left at the very end of the audio has no sound and is dropped.
struct AudioEditTimeline: Equatable, Sendable {
    /// Where a stretch's sound comes from.
    enum Source: Hashable, Sendable {
        /// The audio the edits start from: the original, or, without one,
        /// the book's file as last rendered.
        case base
        /// A punch-in's take, by its path inside the book's package.
        case take(String)
        /// Silence.
        case silence
        /// Sound processed by a filter chain or a gain change, by the name
        /// of the file the processor rendered it into.
        case processed(String)
    }

    /// One stretch of sound.
    struct Segment: Hashable, Sendable {
        /// Where its sound comes from.
        var source: Source
        /// Where in its source it starts, in frames at the timeline's rate;
        /// always 0 for silence.
        var sourceStart: Int64
        /// How long it lasts, in frames at the timeline's rate.
        var length: Int64
    }

    /// One chapter marker.
    struct Chapter: Hashable, Sendable {
        /// Where the chapter starts, in frames.
        var frame: Int64
        /// The chapter's title.
        var title: String
    }

    /// Frames per second: the rate of the audio the edits start from.
    let sampleRate: Double
    /// The stretches of sound, in the order they play.
    private(set) var segments: [Segment]
    /// The chapter markers, in order, at most one at each frame and none at
    /// or after the end.
    private(set) var chapters: [Chapter]

    /// The audio the edits start from, unedited: `frames` frames of the base
    /// source at `sampleRate`, with the markers `chapters`.
    init(sampleRate: Double, baseFrames: Int64, chapters: [Chapter] = []) {
        self.sampleRate = sampleRate
        segments = baseFrames > 0 ? [Segment(source: .base, sourceStart: 0, length: baseFrames)] : []
        self.chapters = chapters
        normalizeChapters()
    }

    /// FMT43's spoken chapters, each rendered into a file of its own in a
    /// scratch folder, joined into one: `files` played whole, one after
    /// another, each a stretch of `.processed` sound by its plain name in
    /// that folder, `frames` long at `sampleRate`, with a chapter marker at
    /// the start of each file that has a title. A file of no frames (or
    /// fewer) has no sound to mark, so it is left out, its marker with it,
    /// rather than leaving that marker on the next file's first frame. The
    /// markers are then put in order as every timeline's are.
    init(sampleRate: Double, joining files: [(name: String, frames: Int64, title: String?)]) {
        var segments: [Segment] = []
        var chapters: [Chapter] = []
        // Where the next file starts: the frames of every file before it.
        var start: Int64 = 0
        for file in files where file.frames > 0 {
            if let title = file.title {
                chapters.append(Chapter(frame: start, title: title))
            }
            segments.append(Segment(source: .processed(file.name), sourceStart: 0, length: file.frames))
            start += file.frames
        }
        self.sampleRate = sampleRate
        self.segments = segments
        self.chapters = chapters
        normalizeChapters()
    }

    /// A timeline of exactly `segments`, without markers: a stretch handed
    /// to a processor (`excerpt(_:)`).
    private init(sampleRate: Double, segments: [Segment]) {
        self.sampleRate = sampleRate
        self.segments = segments
        chapters = []
    }

    // MARK: Time

    /// How many frames the audio lasts.
    var length: Int64 {
        segments.reduce(0) { $0 + $1.length }
    }

    /// How long the audio lasts, in seconds.
    var duration: TimeInterval {
        seconds(at: length)
    }

    /// The frame nearest `seconds`, unchecked against the audio's length; a
    /// time too large for any frame, or not a number, gives the largest or
    /// smallest frame, which every check then refuses, rather than trapping.
    func frame(at seconds: TimeInterval) -> Int64 {
        let frame = (seconds * sampleRate).rounded()
        guard frame.isFinite else { return frame > 0 ? .max : .min }
        return Int64(exactly: frame) ?? (frame > 0 ? .max : .min)
    }

    /// The time of `frame`, in seconds.
    func seconds(at frame: Int64) -> TimeInterval {
        Double(frame) / sampleRate
    }

    /// The chapter markers, as times in seconds with their titles.
    var chapterTimes: [(start: TimeInterval, title: String)] {
        chapters.map { (start: seconds(at: $0.frame), title: $0.title) }
    }

    /// Whether every stretch comes from the audio the edits start from, in
    /// order or not: only cuts, trims, and moves were applied, so the sound
    /// can be copied as it is stored (`AudioEditRenderer`).
    var isOnlyBase: Bool {
        segments.allSatisfy { $0.source == .base }
    }

    /// Whether the sound is exactly the audio the edits start from, from its
    /// beginning, and `baseFrames` long: no edit changed it, though chapter
    /// markers may have.
    func isUnchangedBase(baseFrames: Int64) -> Bool {
        segments == [Segment(source: .base, sourceStart: 0, length: baseFrames)]
    }

    // MARK: Applying Edits

    /// Applies `edit`, as the type describes. A filter or a gain change has
    /// its stretch rendered by `processor`.
    /// - Throws: `AudioEditError.invalidEdit` with a sentence saying why the
    ///   edit doesn't fit this audio; `.processingUnavailable` for a filter
    ///   or gain change without a processor; or the processor's error.
    mutating func apply(_ edit: AudioEdit, processor: (any AudioEditProcessing)?) async throws {
        switch edit {
        case .filter(let chain, let range):
            try await process(range, chain: chain, processor: processor)
        case .gain(let decibels, let range):
            guard decibels.isFinite, abs(decibels) <= Self.largestGain else {
                throw invalid("A volume change must be between -\(Int(Self.largestGain)) and +\(Int(Self.largestGain)) dB.")
            }
            try await process(range, chain: Self.gainChain(decibels), processor: processor)
        default:
            try applyRearranging(edit)
        }
    }

    /// The longest stretch one edit may insert, silence or a take, in
    /// seconds: a day, far beyond any recording, which keeps every length
    /// well inside what a count of frames can hold.
    static let longestInsertion: TimeInterval = 24 * 60 * 60

    /// The largest volume change one edit may make, in decibels either way:
    /// 96 dB is the whole range of 16-bit audio.
    static let largestGain = 96.0

    /// The filter chain a gain change of `decibels` is rendered with: ffmpeg's
    /// volume filter, so a gain change sounds the same through TextMouth's own
    /// filters and through ffmpeg.
    static func gainChain(_ decibels: Double) -> String {
        "volume=\(decibels)dB"
    }

    /// Applies `edit`, one that only rearranges sound or markers.
    /// - Throws: `AudioEditError.invalidEdit` when it doesn't fit, or
    ///   `.processingUnavailable` for a filter or a gain change.
    mutating func applyRearranging(_ edit: AudioEdit) throws {
        switch edit {
        case .trimStart(let to):
            let end = try point(to)
            guard end > 0 else { throw invalid("Trimming to the very start removes nothing.") }
            guard end < length else { throw invalid("A trim can't remove all of the audio.") }
            splice(0..<end, with: [])
        case .trimEnd(let at):
            let start = try point(at)
            guard start < length else { throw invalid("Trimming at the very end removes nothing.") }
            guard start > 0 else { throw invalid("A trim can't remove all of the audio.") }
            splice(start..<length, with: [])
        case .cut(let range):
            let frames = try frameRange(range)
            guard frames.lowerBound > 0 || frames.upperBound < length else {
                throw invalid("A cut can't remove all of the audio.")
            }
            splice(frames, with: [])
        case .move(let range, let to):
            try move(range, to: to)
        case .insertSilence(let at, let duration):
            let place = try point(at)
            guard duration.isFinite, duration > 0 else { throw invalid("Silence has to last longer than no time at all.") }
            guard duration <= Self.longestInsertion else { throw invalid("Silence can last at most a day.") }
            let frames = frame(at: duration)
            guard frames > 0 else { throw invalid("Silence has to last at least one sample.") }
            splice(place..<place, with: [Segment(source: .silence, sourceStart: 0, length: frames)])
        case .replace(let range, let take):
            let frames = try frameRange(range)
            splice(frames, with: [try segment(of: take)])
        case .insert(let at, let take):
            // Inserted like silence: a marker at the place stays before the
            // new sound, so it belongs to that marker's chapter.
            let place = try point(at)
            splice(place..<place, with: [try segment(of: take)])
        case .setChapter(let at, let title):
            let place = try point(at)
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw invalid("A chapter marker needs a title.") }
            guard place < length else { throw invalid("A chapter marker can't be at the very end of the audio.") }
            chapters.removeAll { $0.frame == place }
            chapters.append(Chapter(frame: place, title: trimmed))
            normalizeChapters()
        case .removeChapter(let at):
            let place = try point(at)
            guard chapters.contains(where: { $0.frame == place }) else {
                throw invalid("There's no chapter marker at \(AudioEditWording.duration(seconds(at: place))).")
            }
            chapters.removeAll { $0.frame == place }
        case .filter, .gain:
            throw AudioEditError.processingUnavailable
        }
    }

    /// Takes `range` out and puts it back at `to`, a time on the audio before
    /// the move, with the markers inside it.
    private mutating func move(_ range: AudioTimeRange, to: TimeInterval) throws {
        let frames = try frameRange(range)
        let place = try point(to)
        guard place <= frames.lowerBound || place >= frames.upperBound else {
            throw invalid("The place to move to is inside the range being moved.")
        }
        guard place != frames.lowerBound, place != frames.upperBound else {
            throw invalid("The audio is already at that place.")
        }
        let moved = excerpt(frames).segments
        let carried = chapters
            .filter { frames.contains($0.frame) }
            .map { Chapter(frame: $0.frame - frames.lowerBound, title: $0.title) }
        chapters.removeAll { frames.contains($0.frame) }
        splice(frames, with: [])
        let removed = frames.upperBound - frames.lowerBound
        let destination = place > frames.lowerBound ? place - removed : place
        splice(destination..<destination, with: moved, carrying: carried)
    }

    /// Renders `range`, or the whole audio when it is nil, through `chain`
    /// with `processor`, and puts the processed sound in its place.
    private mutating func process(
        _ range: AudioTimeRange?,
        chain: String,
        processor: (any AudioEditProcessing)?
    ) async throws {
        let frames = try range.map(frameRange) ?? 0..<length
        guard let processor else { throw AudioEditError.processingUnavailable }
        let processed = try await processor.process(excerpt(frames), chain: chain)
        guard processed.length > 0 else { throw invalid("The filter left no sound at all.") }
        splice(frames, with: [processed])
    }

    // MARK: Validation

    /// The frames of `range`, which must lie within the audio and hold at
    /// least one frame.
    func frameRange(_ range: AudioTimeRange) throws -> Range<Int64> {
        guard range.isWellFormed else { throw invalid("The range has to start before it ends.") }
        let start = frame(at: range.start)
        let end = frame(at: range.end)
        guard end <= length else {
            throw invalid("The range ends after the end of the audio, at \(AudioEditWording.duration(duration)).")
        }
        guard start < end else { throw invalid("The range is shorter than one sample.") }
        return start..<end
    }

    /// The frame of `seconds`, which must lie within the audio, its very end
    /// included.
    func point(_ seconds: TimeInterval) throws -> Int64 {
        guard seconds.isFinite, seconds >= 0 else { throw invalid("That isn't a time in the audio.") }
        let place = frame(at: seconds)
        guard place <= length else {
            throw invalid("That time is after the end of the audio, at \(AudioEditWording.duration(duration)).")
        }
        return place
    }

    /// The error refusing an edit, `reason` saying why.
    private func invalid(_ reason: String) -> AudioEditError {
        .invalidEdit(reason)
    }

    /// The stretch of sound `take` puts in the audio: a punch-in's
    /// replacement, or audio inserted, which must start before it ends,
    /// hold at least one sample, and last at most a day.
    private func segment(of take: AudioEditTake) throws -> Segment {
        guard take.range.isWellFormed else { throw invalid("The new audio's stretch has to start before it ends.") }
        let takeStart = frame(at: take.range.start)
        let takeLength = frame(at: take.range.end) - takeStart
        guard takeLength > 0 else { throw invalid("The new audio has to last at least one sample.") }
        guard take.range.duration <= Self.longestInsertion else { throw invalid("New audio can last at most a day.") }
        return Segment(source: .take(take.file), sourceStart: takeStart, length: takeLength)
    }

    // MARK: Stretches

    /// The stretch `range` of the sound, as a timeline of its own without
    /// markers: what a processor renders.
    func excerpt(_ range: Range<Int64>) -> AudioEditTimeline {
        var copy = self
        let start = copy.split(at: range.lowerBound)
        let end = copy.split(at: range.upperBound)
        return AudioEditTimeline(sampleRate: sampleRate, segments: Array(copy.segments[start..<end]))
    }

    /// Splits the stretch holding `frame` so that a stretch begins exactly
    /// there, and returns that stretch's index: the number of stretches when
    /// `frame` is the end.
    private mutating func split(at frame: Int64) -> Int {
        var position: Int64 = 0
        for (index, segment) in segments.enumerated() {
            if position == frame { return index }
            if frame < position + segment.length {
                let offset = frame - position
                let rest = segment.source == .silence ? 0 : segment.sourceStart + offset
                segments.replaceSubrange(index...index, with: [
                    Segment(source: segment.source, sourceStart: segment.sourceStart, length: offset),
                    Segment(source: segment.source, sourceStart: rest, length: segment.length - offset),
                ])
                return index + 1
            }
            position += segment.length
        }
        return segments.count
    }

    /// Puts `pieces` in place of `range`, an empty range for an insertion,
    /// and moves the markers as the type describes. `carried` are the markers
    /// moving with `pieces`, by their frames from its start.
    private mutating func splice(_ range: Range<Int64>, with pieces: [Segment], carrying carried: [Chapter] = []) {
        let oldLength = range.upperBound - range.lowerBound
        let newLength = pieces.reduce(0) { $0 + $1.length }
        let start = split(at: range.lowerBound)
        let end = split(at: range.upperBound)
        segments.replaceSubrange(start..<end, with: pieces)
        coalesce()

        // Moved sound with a marker of its own at its start takes the place
        // of a marker already at an insertion point.
        let carriedTakesThePlace = oldLength == 0 && carried.contains { $0.frame == 0 }
        chapters = chapters.map { chapter in
            var mapped = chapter
            let frame = chapter.frame
            if frame < range.lowerBound || (frame == range.lowerBound && !carriedTakesThePlace) {
                // Before the range, or at its start: it stays.
            } else if frame < range.upperBound {
                // Inside: the same proportion of the new sound, rounded
                // down, so it stays inside it; the range's start for a cut.
                let proportion = Double(frame - range.lowerBound) / Double(oldLength)
                mapped.frame = range.lowerBound + Int64((proportion * Double(newLength)).rounded(.down))
            } else {
                mapped.frame = frame - oldLength + newLength
            }
            return mapped
        } + carried.map { Chapter(frame: range.lowerBound + $0.frame, title: $0.title) }
        normalizeChapters()
    }

    /// Joins neighbouring stretches that continue one another in the same
    /// source, so a list that cuts and puts back sound plays from as few
    /// stretches as it can.
    private mutating func coalesce() {
        var joined: [Segment] = []
        for segment in segments where segment.length > 0 {
            if var last = joined.last, last.source == segment.source,
               segment.source == .silence || last.sourceStart + last.length == segment.sourceStart {
                last.length += segment.length
                joined[joined.count - 1] = last
            } else {
                joined.append(segment)
            }
        }
        segments = joined
    }

    /// Puts the markers in order, keeping, of several at one frame, the one
    /// that came last, and dropping any at or after the end.
    private mutating func normalizeChapters() {
        let end = length
        let ordered = chapters.enumerated()
            .sortedStably { ($0.element.frame, $0.offset) < ($1.element.frame, $1.offset) }
            .map(\.element)
        var kept: [Chapter] = []
        for chapter in ordered where chapter.frame >= 0 && chapter.frame < end {
            if let last = kept.last, last.frame == chapter.frame {
                kept[kept.count - 1] = chapter
            } else {
                kept.append(chapter)
            }
        }
        chapters = kept
    }
}

/// Renders a stretch of an edit timeline through a filter chain (FR04):
/// what applying a filter or a gain change needs, kept apart so the timeline
/// stays a value and its tests need no audio.
protocol AudioEditProcessing: Sendable {
    /// Renders `stretch` through `chain`, a filter chain in ffmpeg's syntax,
    /// into a file, and returns the stretch of processed sound standing for
    /// it: from 0, as long as the processed sound lasts at the stretch's
    /// rate.
    func process(_ stretch: AudioEditTimeline, chain: String) async throws -> AudioEditTimeline.Segment
}
